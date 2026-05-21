use std::collections::HashMap;
use std::io::Write;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::acp::protocol::{
    ClientCapabilities, ClientInfo, ContentBlock, InitializeParams, JsonRpcRequest,
    JsonRpcResponseOut, SessionCancelParams, SessionNewParams, SessionPromptParams,
    SessionResumeParams,
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
    resume_session_id: Option<String>,
}

impl AcpClient {
    /// Spawn kiro-cli acp and begin the initialize handshake.
    pub fn spawn(kiro_path: &str, cwd: &str, agent: Option<&str>) -> Result<Self, String> {
        let mut cmd = Command::new(kiro_path);
        cmd.arg("acp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .current_dir(cwd);
        if let Some(name) = agent {
            cmd.args(["--agent", name]);
        }
        let mut child = cmd
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
            resume_session_id: None,
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
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )?;
        self.state = AcpState::Prompting;
        Ok(())
    }

    /// Cancel the current operation by sending session/cancel.
    pub fn cancel(&mut self) -> Result<(), String> {
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionCancelParams { session_id };
        self.send_request(
            "session/cancel",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    /// Force-kill the child process (hard termination).
    pub fn force_kill(&mut self) {
        self.kill();
    }

    /// Get the active session ID.
    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    /// Send session/resume instead of session/new.
    pub fn send_resume(&mut self, session_id: &str) -> Result<(), String> {
        let params = SessionResumeParams {
            session_id: session_id.to_string(),
            cwd: self.cwd.clone(),
        };
        self.send_request(
            "session/resume",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    /// Spawn kiro-cli acp and resume an existing session.
    pub fn spawn_and_resume(kiro_path: &str, cwd: &str, session_id: &str) -> Result<Self, String> {
        let mut client = Self::spawn(kiro_path, cwd, None)?;
        client.resume_session_id = Some(session_id.to_string());
        Ok(client)
    }

    /// Send a permission response back to kiro-cli.
    pub fn send_permission_response(
        &mut self,
        request_id: u64,
        approved: bool,
    ) -> Result<(), String> {
        let resp = JsonRpcResponseOut {
            jsonrpc: "2.0",
            id: request_id,
            result: Some(serde_json::json!({ "approved": approved })),
            error: None,
        };
        let line = serde_json::to_string(&resp).map_err(|e| e.to_string())?;
        writeln!(self.stdin, "{line}").map_err(|e| format!("Write failed: {e}"))?;
        self.stdin
            .flush()
            .map_err(|e| format!("Flush failed: {e}"))?;
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
        self.send_request(
            "initialize",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    fn send_session_new(&mut self) -> Result<(), String> {
        let params = SessionNewParams {
            cwd: self.cwd.clone(),
            mcp_servers: vec![],
        };
        self.send_request(
            "session/new",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
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
                // If resuming, send session/resume; otherwise send session/new
                if let Some(sid) = self.resume_session_id.take() {
                    if let Err(e) = self.send_resume(&sid) {
                        self.state = AcpState::Dead;
                        self.pending_error =
                            Some(AcpEvent::Error(format!("session/resume failed: {e}")));
                    }
                } else {
                    if let Err(e) = self.send_session_new() {
                        self.state = AcpState::Dead;
                        self.pending_error =
                            Some(AcpEvent::Error(format!("session/new failed: {e}")));
                    }
                }
            }
            AcpEvent::SessionCreated(id) => {
                self.session_id = Some(id.clone());
                self.state = AcpState::Ready;
            }
            AcpEvent::TurnEnd { .. } => {
                self.state = AcpState::Ready;
            }
            AcpEvent::Cancelled => {
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
