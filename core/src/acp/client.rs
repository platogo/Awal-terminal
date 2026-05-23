use std::collections::HashMap;
use std::io::Write;
use std::os::unix::io::RawFd;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use crate::acp::protocol::{
    ClientCapabilities, ClientInfo, ContentBlock, InitializeParams, JsonRpcRequest,
    JsonRpcResponseOut, SessionCancelParams, SessionCancelSubagentParams, SessionNewParams,
    SessionPromptParams, SessionResumeParams, SessionRewindParams,
};
use crate::acp::reader::{spawn_reader, AcpEvent};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpState {
    Initializing,
    Ready,
    Prompting,
    Dead,
    Recovering,
}

pub struct AcpClient {
    child: Option<Child>,
    stdin: std::io::BufWriter<Box<dyn Write + Send>>,
    rx: mpsc::Receiver<AcpEvent>,
    _reader_handle: JoinHandle<()>,
    pending_methods: Arc<Mutex<HashMap<u64, String>>>,
    tx: mpsc::Sender<AcpEvent>,
    next_id: u64,
    session_id: Option<String>,
    state: AcpState,
    cwd: String,
    kiro_path: String,
    resume_session_id: Option<String>,
    crash_count: u8,
    max_retries: u8,
    pgid: i32,
    engine: Option<String>,
    trust_tools: Option<String>,
    token_path: Option<String>,
}

impl AcpClient {
    /// Spawn kiro-cli acp and begin the initialize handshake.
    pub fn spawn(
        kiro_path: &str,
        cwd: &str,
        agent: Option<&str>,
        engine: Option<&str>,
        trust_tools: Option<&str>,
        token_path: Option<&str>,
    ) -> Result<Self, String> {
        let (child, stdin, rx, reader_handle, pending_methods, pgid, tx) =
            Self::spawn_process(kiro_path, cwd, agent, engine, trust_tools, token_path)?;

        let mut client = Self {
            child: Some(child),
            stdin: std::io::BufWriter::new(Box::new(stdin)),
            rx,
            _reader_handle: reader_handle,
            pending_methods,
            tx,
            next_id: 0,
            session_id: None,
            state: AcpState::Initializing,
            cwd: cwd.to_string(),
            kiro_path: kiro_path.to_string(),
            resume_session_id: None,
            crash_count: 0,
            max_retries: 3,
            pgid,
            engine: engine.map(|s| s.to_string()),
            trust_tools: trust_tools.map(|s| s.to_string()),
            token_path: token_path.map(|s| s.to_string()),
        };
        client.send_initialize()?;
        Ok(client)
    }

    /// Create an AcpClient that only writes to stdin. Reading is handled externally.
    pub fn writer_only(stdin_fd: RawFd) -> Result<Self, String> {
        use std::os::unix::io::FromRawFd;
        let stdin_file = unsafe { std::fs::File::from_raw_fd(stdin_fd) };
        let (tx, rx) = mpsc::channel();
        let pending_methods = Arc::new(Mutex::new(HashMap::new()));
        let reader_handle = thread::spawn(|| {});

        let mut client = Self {
            child: None,
            stdin: std::io::BufWriter::new(Box::new(stdin_file)),
            rx,
            _reader_handle: reader_handle,
            pending_methods,
            tx,
            next_id: 0,
            session_id: None,
            state: AcpState::Initializing,
            cwd: String::new(),
            kiro_path: String::new(),
            resume_session_id: None,
            crash_count: 0,
            max_retries: 0,
            pgid: 0,
            engine: None,
            trust_tools: None,
            token_path: None,
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

    /// Spawn kiro-cli acp and resume an existing session.
    pub fn spawn_and_resume(
        kiro_path: &str,
        cwd: &str,
        session_id: &str,
        engine: Option<&str>,
        trust_tools: Option<&str>,
        token_path: Option<&str>,
    ) -> Result<Self, String> {
        let mut client = Self::spawn(kiro_path, cwd, None, engine, trust_tools, token_path)?;
        client.resume_session_id = Some(session_id.to_string());
        Ok(client)
    }

    /// Non-blocking poll for the next event. Returns None if no event is available.
    pub fn poll_event(&mut self) -> Option<AcpEvent> {
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

    /// Attempt to respawn the process after a crash.
    pub fn respawn(&mut self) -> Result<(), String> {
        // Kill existing child if still alive
        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }

        self.crash_count += 1;
        let (child, stdin, rx, reader_handle, pending_methods, pgid, tx) = Self::spawn_process(
            &self.kiro_path,
            &self.cwd,
            None,
            self.engine.as_deref(),
            self.trust_tools.as_deref(),
            self.token_path.as_deref(),
        )?;

        self.child = Some(child);
        self.stdin = std::io::BufWriter::new(Box::new(stdin));
        self.rx = rx;
        self._reader_handle = reader_handle;
        self.pending_methods = pending_methods;
        self.tx = tx;
        self.next_id = 0;
        self.pgid = pgid;

        // Re-initialize — if we have a session_id, resume it after init
        if let Some(sid) = self.session_id.clone() {
            self.resume_session_id = Some(sid);
        }
        self.send_initialize()?;
        Ok(())
    }

    /// Kill the child process.
    pub fn kill(&mut self) {
        self.kill_process_group();
        self.state = AcpState::Dead;
    }

    // --- Private ---

    #[allow(clippy::type_complexity)]
    fn spawn_process(
        kiro_path: &str,
        cwd: &str,
        agent: Option<&str>,
        engine: Option<&str>,
        trust_tools: Option<&str>,
        token_path: Option<&str>,
    ) -> Result<
        (
            Child,
            std::process::ChildStdin,
            mpsc::Receiver<AcpEvent>,
            JoinHandle<()>,
            Arc<Mutex<HashMap<u64, String>>>,
            i32,
            mpsc::Sender<AcpEvent>,
        ),
        String,
    > {
        let mut cmd = Command::new(kiro_path);
        cmd.arg("acp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .current_dir(cwd);

        if let Some(name) = agent {
            cmd.args(["--agent", name]);
        }

        if let Some(eng) = engine {
            cmd.args(["--agent-engine", eng]);
        }

        if let Some(tools) = trust_tools {
            if tools == "all" {
                cmd.arg("--trust-all-tools");
            } else {
                cmd.args(["--trust-tools", tools]);
            }
        }

        if let Some(path) = token_path {
            cmd.args(["--token-path", path]);
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Failed to spawn kiro-cli: {e}"))?;

        let pgid = child.id() as i32;

        let stdout = child
            .stdout
            .take()
            .ok_or("Failed to capture stdout".to_string())?;
        let stdin = child
            .stdin
            .take()
            .ok_or("Failed to capture stdin".to_string())?;
        let stderr = child.stderr.take();

        let (tx, rx) = mpsc::channel();
        let pending_methods = Arc::new(Mutex::new(HashMap::new()));
        let reader_handle = spawn_reader(stdout, tx.clone(), pending_methods.clone());

        // Spawn stderr reader thread
        if let Some(stderr) = stderr {
            let stderr_tx = tx.clone();
            thread::spawn(move || {
                let reader = std::io::BufReader::new(stderr);
                use std::io::BufRead;
                for line in reader.lines() {
                    match line {
                        Ok(l) if !l.is_empty() => {
                            if stderr_tx.send(AcpEvent::Stderr(l)).is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                        _ => {}
                    }
                }
            });
        }

        Ok((child, stdin, rx, reader_handle, pending_methods, pgid, tx))
    }

    fn kill_process_group(&mut self) {
        // Send SIGTERM to the process group
        if self.pgid > 0 {
            unsafe {
                libc::killpg(self.pgid, libc::SIGTERM);
            }
        }
        if let Some(ref mut child) = self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

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
                self.crash_count = 0; // Reset on successful session
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

impl Drop for AcpClient {
    fn drop(&mut self) {
        self.kill_process_group();
    }
}
