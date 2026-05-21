use std::collections::HashMap;
use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::acp::protocol::{
    ClientCapabilities, ClientInfo, ContentBlock, InitializeParams, JsonRpcRequest,
    SessionNewParams, SessionPromptParams,
};
use crate::acp::reader::{spawn_reader, AcpEvent};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpState {
    Initializing,
    Ready,
    Prompting,
    Dead,
}

pub struct AcpClient {
    child: Child,
    stdin: std::io::BufWriter<std::process::ChildStdin>,
    rx: mpsc::Receiver<AcpEvent>,
    _reader_handle: JoinHandle<()>,
    pending_methods: Arc<Mutex<HashMap<u64, String>>>,
    next_id: u64,
    session_id: Option<String>,
    state: AcpState,
    cwd: String,
    pending_error: Option<AcpEvent>,
}

impl AcpClient {
    /// Spawn kiro-cli acp and begin the initialize handshake.
    pub fn spawn(kiro_path: &str, cwd: &str) -> Result<Self, String> {
        let mut child = Command::new(kiro_path)
            .arg("acp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .current_dir(cwd)
            .spawn()
            .map_err(|e| format!("Failed to spawn kiro-cli: {e}"))?;

        let stdout = child
            .stdout
            .take()
            .ok_or("Failed to capture stdout".to_string())?;
        let stdin = child
            .stdin
            .take()
            .ok_or("Failed to capture stdin".to_string())?;

        let (tx, rx) = mpsc::channel();
        let pending_methods = Arc::new(Mutex::new(HashMap::new()));
        let reader_handle = spawn_reader(stdout, tx, pending_methods.clone());

        let mut client = Self {
            child,
            stdin: std::io::BufWriter::new(stdin),
            rx,
            _reader_handle: reader_handle,
            pending_methods,
            next_id: 0,
            session_id: None,
            state: AcpState::Initializing,
            cwd: cwd.to_string(),
            pending_error: None,
        };
        client.send_initialize()?;
        Ok(client)
    }

    /// Non-blocking poll for the next event. Returns None if no event is available.
    pub fn poll_event(&mut self) -> Option<AcpEvent> {
        if let Some(err) = self.pending_error.take() {
            return Some(err);
        }
        match self.rx.try_recv() {
            Ok(event) => {
                self.handle_state_transition(&event);
                Some(event)
            }
            Err(_) => None,
        }
    }

    /// Current client state.
    pub fn state(&self) -> AcpState {
        self.state
    }

    /// Send a text prompt. Only valid when state is Ready.
    pub fn send_prompt(&mut self, text: &str) -> Result<(), String> {
        if self.state != AcpState::Ready {
            return Err("Cannot send prompt: client is not in Ready state".to_string());
        }
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionPromptParams {
            session_id,
            prompt: vec![ContentBlock {
                content_type: "text".to_string(),
                text: text.to_string(),
            }],
        };
        self.send_request(
            "session/prompt",
            Some(serde_json::to_value(params).unwrap()),
        )?;
        self.state = AcpState::Prompting;
        Ok(())
    }

    /// Cancel the current operation by killing the child process.
    pub fn cancel(&mut self) -> Result<(), String> {
        self.kill();
        Ok(())
    }

    /// Kill the child process.
    pub fn kill(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.state = AcpState::Dead;
    }

    fn send_initialize(&mut self) -> Result<(), String> {
        let params = InitializeParams {
            protocol_version: "2025-01-01".to_string(),
            client_capabilities: ClientCapabilities {},
            client_info: ClientInfo {
                name: "AwalTerminal".to_string(),
                version: "0.17.0".to_string(),
            },
        };
        self.send_request("initialize", Some(serde_json::to_value(params).unwrap()))
    }

    fn send_session_new(&mut self) -> Result<(), String> {
        let params = SessionNewParams {
            cwd: self.cwd.clone(),
            mcp_servers: vec![],
        };
        self.send_request("session/new", Some(serde_json::to_value(params).unwrap()))
    }

    fn send_request(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<(), String> {
        self.next_id += 1;
        let id = self.next_id;
        let req = JsonRpcRequest::new(id, method, params);
        self.pending_methods
            .lock()
            .unwrap()
            .insert(id, method.to_string());
        let line = serde_json::to_string(&req).map_err(|e| e.to_string())?;
        writeln!(self.stdin, "{line}").map_err(|e| format!("Write failed: {e}"))?;
        self.stdin
            .flush()
            .map_err(|e| format!("Flush failed: {e}"))?;
        Ok(())
    }

    fn handle_state_transition(&mut self, event: &AcpEvent) {
        match event {
            AcpEvent::Initialized => {
                // Auto-send session/new after initialize succeeds
                if let Err(e) = self.send_session_new() {
                    self.state = AcpState::Dead;
                    self.pending_error = Some(AcpEvent::Error(format!("session/new failed: {e}")));
                }
            }
            AcpEvent::SessionCreated(id) => {
                self.session_id = Some(id.clone());
                self.state = AcpState::Ready;
            }
            AcpEvent::TurnEnd { .. } => {
                self.state = AcpState::Ready;
            }
            AcpEvent::ProcessExited(_) => {
                self.state = AcpState::Dead;
            }
            _ => {}
        }
    }
}

impl Drop for AcpClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
