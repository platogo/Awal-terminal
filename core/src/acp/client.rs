use std::collections::HashMap;
use std::io::Write;
use std::os::unix::io::RawFd;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

use crate::acp::protocol::{
    ClientCapabilities, ClientInfo, ContentBlock, InitializeParams, JsonRpcRequest,
    JsonRpcResponseOut, SessionCancelParams, SessionCancelSubagentParams, SessionNewParams,
    SessionPromptParams, SessionResumeParams, SessionRewindParams, TextContent,
};
use crate::acp::reader::AcpEvent;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpState {
    Initializing,
    Ready,
    Prompting,
    Dead,
    Recovering,
}

pub struct AcpClient {
    stdin: std::io::BufWriter<Box<dyn Write + Send>>,
    rx: mpsc::Receiver<AcpEvent>,
    pending_methods: Arc<Mutex<HashMap<u64, String>>>,
    tx: mpsc::Sender<AcpEvent>,
    next_id: u64,
    session_id: Option<String>,
    state: AcpState,
    cwd: String,
    resume_session_id: Option<String>,
    crash_count: u8,
    max_retries: u8,
}

impl AcpClient {
    /// Create an AcpClient that only writes to stdin. Reading is handled externally.
    pub fn writer_only(stdin_fd: RawFd) -> Result<Self, String> {
        use std::os::unix::io::FromRawFd;
        let stdin_file = unsafe { std::fs::File::from_raw_fd(stdin_fd) };
        let (tx, rx) = mpsc::channel();
        let pending_methods = Arc::new(Mutex::new(HashMap::new()));

        let mut client = Self {
            stdin: std::io::BufWriter::new(Box::new(stdin_file)),
            rx,
            pending_methods,
            tx,
            next_id: 0,
            session_id: None,
            state: AcpState::Initializing,
            cwd: String::new(),
            resume_session_id: None,
            crash_count: 0,
            max_retries: 0,
        };
        client.send_initialize()?;
        Ok(client)
    }

    /// Feed a line from stdout (called by Swift when it reads a line).
    pub fn feed_stdout_line(&mut self, line: &str) {
        use crate::acp::reader::parse_line;
        if let Some(event) = parse_line(line, &self.pending_methods) {
            self.handle_state_transition(&event);
            let _ = self.tx.send(event);
        }
    }

    /// Set the session ID to resume after initialization completes.
    pub fn set_resume_session_id(&mut self, session_id: &str) {
        self.resume_session_id = Some(session_id.to_string());
    }

    /// Set the working directory (sent in session/new and session/resume requests).
    pub fn set_cwd(&mut self, cwd: &str) {
        self.cwd = cwd.to_string();
    }

    /// Non-blocking poll for the next event. Returns None if no event is available.
    /// State transitions happen in feed_stdout_line, not here — poll only delivers events to Swift.
    pub fn poll_event(&mut self) -> Option<AcpEvent> {
        self.rx.try_recv().ok()
    }

    /// Current client state.
    pub fn state(&self) -> AcpState {
        self.state
    }

    /// Send a text prompt. Only valid when state is Ready.
    pub fn send_prompt(&mut self, text: &str) -> Result<(), String> {
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionPromptParams {
            session_id,
            prompt: vec![ContentBlock::Text(TextContent::new(text))],
        };
        self.send_request(
            "session/prompt",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )?;
        self.state = AcpState::Prompting;
        Ok(())
    }

    /// Cancel the current operation by sending session/cancel (notification, no response expected).
    pub fn cancel(&mut self) -> Result<(), String> {
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionCancelParams { session_id };
        self.send_notification(
            "session/cancel",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    /// Cancel a specific subagent by sending session/cancelSubagent.
    pub fn cancel_subagent(&mut self, subagent_id: &str) -> Result<(), String> {
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionCancelSubagentParams {
            session_id,
            subagent_id: subagent_id.to_string(),
        };
        self.send_request(
            "session/cancelSubagent",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    /// Rewind the session to the previous turn.
    pub fn send_rewind(&mut self) -> Result<(), String> {
        let session_id = self
            .session_id
            .clone()
            .ok_or("No active session".to_string())?;
        let params = SessionRewindParams { session_id };
        self.send_request(
            "session/rewind",
            Some(serde_json::to_value(&params).map_err(|e| e.to_string())?),
        )
    }

    /// Force-kill the child process (hard termination).
    pub fn force_kill(&mut self) {
        self.state = AcpState::Dead;
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
        self.write_response(&resp)
    }

    /// Respond to a fs/read_text_file request with file content or error.
    pub fn respond_fs_read(
        &mut self,
        request_id: u64,
        content: Result<String, String>,
    ) -> Result<(), String> {
        let resp = match content {
            Ok(text) => JsonRpcResponseOut {
                jsonrpc: "2.0",
                id: request_id,
                result: Some(serde_json::json!({ "content": text })),
                error: None,
            },
            Err(msg) => JsonRpcResponseOut {
                jsonrpc: "2.0",
                id: request_id,
                result: None,
                error: Some(crate::acp::protocol::JsonRpcErrorOut {
                    code: -32000,
                    message: msg,
                }),
            },
        };
        self.write_response(&resp)
    }

    /// Respond to a fs/write_text_file request.
    pub fn respond_fs_write(
        &mut self,
        request_id: u64,
        success: bool,
        error: Option<String>,
    ) -> Result<(), String> {
        let resp = if success {
            JsonRpcResponseOut {
                jsonrpc: "2.0",
                id: request_id,
                result: Some(serde_json::json!({ "success": true })),
                error: None,
            }
        } else {
            JsonRpcResponseOut {
                jsonrpc: "2.0",
                id: request_id,
                result: None,
                error: Some(crate::acp::protocol::JsonRpcErrorOut {
                    code: -32000,
                    message: error.unwrap_or_else(|| "Write failed".to_string()),
                }),
            }
        };
        self.write_response(&resp)
    }

    // --- Private ---

    fn write_response(&mut self, resp: &JsonRpcResponseOut) -> Result<(), String> {
        let line = serde_json::to_string(resp).map_err(|e| e.to_string())?;
        writeln!(self.stdin, "{line}").map_err(|e| format!("Write failed: {e}"))?;
        self.stdin
            .flush()
            .map_err(|e| format!("Flush failed: {e}"))?;
        Ok(())
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
        let _ = self.tx.send(AcpEvent::ProtocolLog(format!("→ {method}")));
        Ok(())
    }

    fn send_notification(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<(), String> {
        let notif = crate::acp::protocol::JsonRpcNotificationOut {
            jsonrpc: "2.0",
            method: method.to_string(),
            params,
        };
        let line = serde_json::to_string(&notif).map_err(|e| e.to_string())?;
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
                    let _ = self.send_resume(&sid);
                } else {
                    let _ = self.send_session_new();
                }
            }
            AcpEvent::SessionCreated(id) => {
                self.session_id = Some(id.clone());
                self.state = AcpState::Ready;
                self.crash_count = 0;
            }
            AcpEvent::TurnEnd { .. } => {
                self.state = AcpState::Ready;
            }
            AcpEvent::Cancelled => {
                self.state = AcpState::Ready;
            }
            AcpEvent::AuthRequired(_) => {
                self.state = AcpState::Dead;
            }
            AcpEvent::ProcessExited(_) => {
                if self.crash_count < self.max_retries {
                    self.state = AcpState::Recovering;
                } else {
                    self.state = AcpState::Dead;
                }
            }
            _ => {}
        }
    }
}
