use crate::acp::protocol::{
    ContentBlock, InitializeResult, PromptResponseWithCredits, RawMessage, RequestPermissionParams,
    SessionNewResult, SessionUpdate, SessionUpdateParams, StopReason, ToolCallStatus,
};

fn serde_str<T: serde::Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_default()
}

/// Events produced by the ACP reader thread.
pub enum AcpEvent {
    Initialized,
    SessionCreated(String),
    TextChunk(String),
    AgentThought(String),
    PlanUpdate {
        entries_json: String,
    },
    ImageContent {
        data: String,
        mime_type: String,
    },
    ToolCall {
        id: String,
        title: String,
        kind: Option<String>,
        status: String,
    },
    ToolCallUpdate {
        id: String,
        status: String,
        content: Option<String>,
    },
    TurnEnd {
        stop_reason: String,
        credits_used: Option<f64>,
    },
    Cancelled,
    PermissionRequest {
        request_id: u64,
        tool_call_id: String,
        tool_name: String,
        description: String,
        kind: Option<String>,
    },
    Error(String),
    ProcessExited(Option<i32>),
    /// Authentication required — message describes what's needed.
    AuthRequired(String),
    /// Server requests reading a file.
    FsReadRequest {
        request_id: u64,
        path: String,
    },
    /// Server requests writing a file.
    FsWriteRequest {
        request_id: u64,
        path: String,
        content: String,
    },
    /// Context window usage update.
    UsageUpdate {
        used_tokens: u64,
        context_window_size: u64,
        cost: Option<f64>,
        currency: Option<String>,
    },
    /// A subagent was spawned.
    SubagentSpawned {
        subagent_id: String,
        name: String,
        role: Option<String>,
        parent_session_id: Option<String>,
        depends_on: Vec<String>,
    },
    /// A subagent reported progress.
    SubagentProgress {
        subagent_id: String,
        phase: String,
        tokens_used: Option<u64>,
    },
    /// A subagent completed successfully.
    SubagentComplete {
        subagent_id: String,
        tokens_used: Option<u64>,
    },
    /// A subagent encountered an error.
    SubagentError {
        subagent_id: String,
        message: String,
    },
    /// stderr output from kiro-cli
    Stderr(String),
    /// Protocol diagnostic: "→ method" for sent, "← method" for received
    ProtocolLog(String),
    /// Kiro metadata: direct context percentage and optional credits.
    MetadataUpdate {
        context_percentage: f64,
        credits_used: Option<f64>,
    },
    /// Session info update (e.g. tab title).
    SessionInfoUpdate(String),
    /// Compaction status notification.
    CompactionStatus(String),
    /// Session list response (JSON array of sessions).
    SessionList(String),
    /// terminal/create request
    TerminalCreate {
        request_id: u64,
        session_id: String,
        command: String,
        args: Vec<String>,
        env: Vec<(String, String)>,
        cwd: Option<String>,
        output_byte_limit: Option<u64>,
    },
    /// terminal/output request
    TerminalOutput {
        request_id: u64,
        terminal_id: String,
    },
    /// terminal/wait_for_exit request
    TerminalWaitForExit {
        request_id: u64,
        terminal_id: String,
    },
    /// terminal/kill request
    TerminalKill {
        request_id: u64,
        terminal_id: String,
    },
    /// terminal/release request
    TerminalRelease {
        request_id: u64,
        terminal_id: String,
    },
    /// Config options received from session/new or config_option_update.
    ConfigOptionsReceived(String),
    /// Available commands update.
    AvailableCommands(String),
    /// MCP OAuth request — URL to open in browser.
    McpOAuthRequest(String),
}

/// Auth-related JSON-RPC error codes.
const AUTH_ERROR_CODES: &[i64] = &[-32001, -32002];

/// Keywords that indicate an auth failure in error messages.
const AUTH_KEYWORDS: &[&str] = &["auth", "unauthorized", "login", "credentials"];

fn is_auth_error(code: i64, message: &str) -> bool {
    if AUTH_ERROR_CODES.contains(&code) {
        return true;
    }
    let lower = message.to_lowercase();
    AUTH_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

/// Parse a single line of stdout into an AcpEvent.
pub fn parse_line(
    line: &str,
    pending_methods: &std::sync::Mutex<std::collections::HashMap<u64, String>>,
) -> Option<AcpEvent> {
    if line.is_empty() {
        return None;
    }
    let msg: RawMessage = match serde_json::from_str(line) {
        Ok(m) => m,
        Err(e) => {
            return Some(AcpEvent::ProtocolLog(format!(
                "Failed to parse JSON line: {e}"
            )));
        }
    };
    parse_message(msg, pending_methods)
}

fn parse_message(
    msg: RawMessage,
    pending_methods: &std::sync::Mutex<std::collections::HashMap<u64, String>>,
) -> Option<AcpEvent> {
    // Server-to-client request: has both `id` and `method`
    if let (Some(id), Some(method)) = (msg.id, msg.method.as_ref()) {
        match method.as_str() {
            "session/request_permission" => {
                let Some(params_val) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "request_permission id={id}: missing params"
                    )));
                };
                let params: RequestPermissionParams = match serde_json::from_value(params_val) {
                    Ok(p) => p,
                    Err(e) => {
                        return Some(AcpEvent::ProtocolLog(format!(
                            "request_permission id={id}: failed to parse: {e}"
                        )));
                    }
                };
                return Some(AcpEvent::PermissionRequest {
                    request_id: id,
                    tool_call_id: params.tool_call_id,
                    tool_name: params.tool_name,
                    description: params.description,
                    kind: params.kind,
                });
            }
            "fs/read_text_file" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "fs/read_text_file id={id}: missing params"
                    )));
                };
                let Some(path) = params.get("path").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "fs/read_text_file id={id}: missing or invalid 'path'"
                    )));
                };
                return Some(AcpEvent::FsReadRequest {
                    request_id: id,
                    path: path.to_string(),
                });
            }
            "fs/write_text_file" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "fs/write_text_file id={id}: missing params"
                    )));
                };
                let Some(path) = params.get("path").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "fs/write_text_file id={id}: missing or invalid 'path'"
                    )));
                };
                let Some(content) = params.get("content").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "fs/write_text_file id={id}: missing or invalid 'content'"
                    )));
                };
                return Some(AcpEvent::FsWriteRequest {
                    request_id: id,
                    path: path.to_string(),
                    content: content.to_string(),
                });
            }
            "terminal/create" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/create id={id}: missing params"
                    )));
                };
                let Some(command) = params.get("command").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/create id={id}: missing or invalid 'command'"
                    )));
                };
                let session_id = params
                    .get("sessionId")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let args = params
                    .get("args")
                    .and_then(|v| v.as_array())
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default();
                let env = params
                    .get("env")
                    .and_then(|v| v.as_object())
                    .map(|obj| {
                        obj.iter()
                            .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                            .collect()
                    })
                    .unwrap_or_default();
                let cwd = params.get("cwd").and_then(|v| v.as_str()).map(String::from);
                let output_byte_limit = params.get("outputByteLimit").and_then(|v| v.as_u64());
                return Some(AcpEvent::TerminalCreate {
                    request_id: id,
                    session_id,
                    command: command.to_string(),
                    args,
                    env,
                    cwd,
                    output_byte_limit,
                });
            }
            "terminal/output" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/output id={id}: missing params"
                    )));
                };
                let Some(terminal_id) = params.get("terminalId").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/output id={id}: missing or invalid 'terminalId'"
                    )));
                };
                return Some(AcpEvent::TerminalOutput {
                    request_id: id,
                    terminal_id: terminal_id.to_string(),
                });
            }
            "terminal/wait_for_exit" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/wait_for_exit id={id}: missing params"
                    )));
                };
                let Some(terminal_id) = params.get("terminalId").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/wait_for_exit id={id}: missing or invalid 'terminalId'"
                    )));
                };
                return Some(AcpEvent::TerminalWaitForExit {
                    request_id: id,
                    terminal_id: terminal_id.to_string(),
                });
            }
            "terminal/kill" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/kill id={id}: missing params"
                    )));
                };
                let Some(terminal_id) = params.get("terminalId").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/kill id={id}: missing or invalid 'terminalId'"
                    )));
                };
                return Some(AcpEvent::TerminalKill {
                    request_id: id,
                    terminal_id: terminal_id.to_string(),
                });
            }
            "terminal/release" => {
                let Some(params) = msg.params else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/release id={id}: missing params"
                    )));
                };
                let Some(terminal_id) = params.get("terminalId").and_then(|v| v.as_str()) else {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "terminal/release id={id}: missing or invalid 'terminalId'"
                    )));
                };
                return Some(AcpEvent::TerminalRelease {
                    request_id: id,
                    terminal_id: terminal_id.to_string(),
                });
            }
            _ => return None,
        }
    }

    if let Some(id) = msg.id {
        // This is a response to one of our requests
        let method = match pending_methods.lock() {
            Ok(mut map) => map.remove(&id)?,
            Err(_) => {
                return Some(AcpEvent::Error(
                    "Internal error: pending_methods lock poisoned".to_string(),
                ));
            }
        };
        if let Some(err) = msg.error {
            // Check if this is an auth error
            if is_auth_error(err.code, &err.message) {
                return Some(AcpEvent::AuthRequired(err.message));
            }
            return Some(AcpEvent::Error(format!("{}: {}", method, err.message)));
        }
        let Some(result) = msg.result else {
            return Some(AcpEvent::ProtocolLog(format!(
                "{method} id={id}: response has neither result nor error"
            )));
        };
        match method.as_str() {
            "initialize" => {
                let _: InitializeResult = match serde_json::from_value(result) {
                    Ok(r) => r,
                    Err(e) => {
                        return Some(AcpEvent::Error(format!(
                            "Failed to parse initialize response: {e}"
                        )));
                    }
                };
                Some(AcpEvent::Initialized)
            }
            "session/new" | "session/resume" => {
                let r: SessionNewResult = match serde_json::from_value(result) {
                    Ok(r) => r,
                    Err(e) => {
                        return Some(AcpEvent::Error(format!(
                            "Failed to parse session/new response: {e}"
                        )));
                    }
                };
                if let Some(opts) = r.config_options {
                    let json = serde_json::to_string(&opts).unwrap_or_default();
                    if let Ok(mut map) = pending_methods.lock() {
                        map.insert(u64::MAX, json);
                    }
                }
                Some(AcpEvent::SessionCreated(r.session_id))
            }
            "session/cancel" => None, // Ignore legacy cancel responses
            "session/list" => Some(AcpEvent::SessionList(
                serde_json::to_string(&result).unwrap_or_default(),
            )),
            "session/prompt" => {
                let r: PromptResponseWithCredits = match serde_json::from_value(result) {
                    Ok(r) => r,
                    Err(e) => {
                        return Some(AcpEvent::Error(format!(
                            "Failed to parse prompt response: {e}"
                        )));
                    }
                };
                if r.stop_reason == StopReason::Cancelled {
                    return Some(AcpEvent::Cancelled);
                }
                Some(AcpEvent::TurnEnd {
                    stop_reason: serde_str(&r.stop_reason),
                    credits_used: r.credits_used,
                })
            }
            _ => None,
        }
    } else if let Some(method) = msg.method {
        // This is a notification
        if method == "session/update" {
            let Some(params) = msg.params else {
                return Some(AcpEvent::ProtocolLog(
                    "session/update: missing params".to_string(),
                ));
            };
            let update: SessionUpdateParams = match serde_json::from_value(params) {
                Ok(u) => u,
                Err(e) => {
                    return Some(AcpEvent::ProtocolLog(format!(
                        "session/update: failed to deserialize: {e}"
                    )));
                }
            };
            match update.update {
                SessionUpdate::AgentMessageChunk { content } => match content {
                    ContentBlock::Text(tc) => Some(AcpEvent::TextChunk(tc.text)),
                    ContentBlock::Image(img) => Some(AcpEvent::ImageContent {
                        data: img.data,
                        mime_type: img.mime_type,
                    }),
                    _ => Some(AcpEvent::ProtocolLog(
                        "Unsupported content type in AgentMessageChunk".to_string(),
                    )),
                },
                SessionUpdate::AgentThoughtChunk { content } => match content {
                    ContentBlock::Text(t) => Some(AcpEvent::AgentThought(t.text)),
                    _ => None,
                },
                SessionUpdate::ToolCall(tc) => Some(AcpEvent::ToolCall {
                    id: tc.tool_call_id.0.to_string(),
                    title: tc.title,
                    kind: match tc.kind {
                        agent_client_protocol_schema::ToolKind::Other => None,
                        k => Some(serde_str(&k)),
                    },
                    status: serde_str(&tc.status),
                }),
                SessionUpdate::ToolCallUpdate(tcu) => {
                    let text = tcu.fields.content.as_ref().and_then(|items| {
                        items.iter().find_map(|item| match item {
                            agent_client_protocol_schema::ToolCallContent::Content(c) => {
                                match &c.content {
                                    ContentBlock::Text(tc) => Some(tc.text.clone()),
                                    _ => None,
                                }
                            }
                            _ => None,
                        })
                    });
                    let status = tcu.fields.status.unwrap_or(ToolCallStatus::Pending);
                    Some(AcpEvent::ToolCallUpdate {
                        id: tcu.tool_call_id.0.to_string(),
                        status: serde_str(&status),
                        content: text,
                    })
                }
                SessionUpdate::Plan(plan) => {
                    let json = serde_json::to_string(&plan).unwrap_or_default();
                    Some(AcpEvent::PlanUpdate { entries_json: json })
                }
                SessionUpdate::TurnEnd => Some(AcpEvent::TurnEnd {
                    stop_reason: "end_turn".to_string(),
                    credits_used: None,
                }),
                SessionUpdate::SubagentSpawned {
                    subagent_id,
                    name,
                    role,
                    parent_session_id,
                    depends_on,
                } => Some(AcpEvent::SubagentSpawned {
                    subagent_id,
                    name,
                    role,
                    parent_session_id,
                    depends_on: depends_on.unwrap_or_default(),
                }),
                SessionUpdate::SubagentProgress {
                    subagent_id,
                    phase,
                    tokens_used,
                } => Some(AcpEvent::SubagentProgress {
                    subagent_id,
                    phase,
                    tokens_used,
                }),
                SessionUpdate::SubagentComplete {
                    subagent_id,
                    tokens_used,
                } => Some(AcpEvent::SubagentComplete {
                    subagent_id,
                    tokens_used,
                }),
                SessionUpdate::SubagentError {
                    subagent_id,
                    message,
                } => Some(AcpEvent::SubagentError {
                    subagent_id,
                    message,
                }),
                SessionUpdate::UsageUpdate(u) => {
                    let (cost, currency) = u
                        .cost
                        .map(|c| (Some(c.amount), Some(c.currency)))
                        .unwrap_or((None, None));
                    Some(AcpEvent::UsageUpdate {
                        used_tokens: u.used,
                        context_window_size: u.size,
                        cost,
                        currency,
                    })
                }
                SessionUpdate::SessionInfoUpdate { title } => {
                    Some(AcpEvent::SessionInfoUpdate(title))
                }
                SessionUpdate::ConfigOptionUpdate { config_options } => {
                    let json = serde_json::to_string(&config_options).unwrap_or_default();
                    Some(AcpEvent::ConfigOptionsReceived(json))
                }
                SessionUpdate::AvailableCommandsUpdate { available_commands } => {
                    let json = serde_json::to_string(&available_commands).unwrap_or_default();
                    Some(AcpEvent::AvailableCommands(json))
                }
                SessionUpdate::CurrentModeUpdate { current_mode_id } => Some(
                    AcpEvent::ProtocolLog(format!("Mode changed: {current_mode_id}")),
                ),
                SessionUpdate::Unknown => None,
            }
        } else if method == "_kiro.dev/metadata" {
            let params = msg.params?;
            let pct = params
                .get("contextUsagePercentage")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let credits = params
                .get("meteringUsage")
                .and_then(|v| v.as_array())
                .and_then(|arr| arr.first())
                .and_then(|item| item.get("value"))
                .and_then(|v| v.as_f64());
            Some(AcpEvent::MetadataUpdate {
                context_percentage: pct,
                credits_used: credits,
            })
        } else if method == "_kiro.dev/compaction/status" {
            let params = msg.params?;
            let status = params
                .get("status")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string();
            Some(AcpEvent::CompactionStatus(status))
        } else if method == "_kiro.dev/mcp/oauth_request" {
            let params = msg.params?;
            let url = params.get("url").and_then(|v| v.as_str())?.to_string();
            Some(AcpEvent::McpOAuthRequest(url))
        } else if method == "_kiro.dev/mcp/server_initialized" {
            Some(AcpEvent::ProtocolLog("MCP server initialized".to_string()))
        } else {
            None
        }
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};

    #[test]
    fn parse_initialize_response() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(1, "initialize".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-01-01"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        assert!(matches!(event, AcpEvent::Initialized));
    }

    #[test]
    fn parse_session_new_response() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(2, "session/new".to_string());

        let msg: RawMessage =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-123"}}"#)
                .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SessionCreated(id) => assert_eq!(id, "sess-123"),
            _ => panic!("expected SessionCreated"),
        }
    }

    #[test]
    fn parse_text_chunk_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello world"}}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TextChunk(t) => assert_eq!(t, "Hello world"),
            _ => panic!("expected TextChunk"),
        }
    }

    #[test]
    fn parse_error_response() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(1, "initialize".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"bad request"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::Error(e) => assert!(e.contains("bad request")),
            _ => panic!("expected Error"),
        }
    }

    #[test]
    fn parse_permission_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"s1","toolCallId":"tc1","toolName":"write","description":"Write to /tmp/foo","kind":"write"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::PermissionRequest {
                request_id,
                tool_call_id,
                tool_name,
                description,
                kind,
            } => {
                assert_eq!(request_id, 42);
                assert_eq!(tool_call_id, "tc1");
                assert_eq!(tool_name, "write");
                assert_eq!(description, "Write to /tmp/foo");
                assert_eq!(kind.as_deref(), Some("write"));
            }
            _ => panic!("expected PermissionRequest"),
        }
    }

    #[test]
    fn parse_session_resume_response() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending
            .lock()
            .unwrap()
            .insert(3, "session/resume".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":3,"result":{"sessionId":"resumed-456"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SessionCreated(id) => assert_eq!(id, "resumed-456"),
            _ => panic!("expected SessionCreated from resume"),
        }
    }

    #[test]
    fn parse_session_cancel_response_ignored() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending
            .lock()
            .unwrap()
            .insert(4, "session/cancel".to_string());

        let msg: RawMessage =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":4,"result":{}}"#).unwrap();
        let event = parse_message(msg, &pending);
        assert!(event.is_none());
    }

    #[test]
    fn parse_auth_error_by_code() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(1, "initialize".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"session expired"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::AuthRequired(msg) => assert!(msg.contains("session expired")),
            _ => panic!("expected AuthRequired"),
        }
    }

    #[test]
    fn parse_auth_error_by_keyword() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(1, "session/new".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Unauthorized: please login"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        assert!(matches!(event, AcpEvent::AuthRequired(_)));
    }

    #[test]
    fn parse_fs_read_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":10,"method":"fs/read_text_file","params":{"path":"/tmp/test.txt"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::FsReadRequest { request_id, path } => {
                assert_eq!(request_id, 10);
                assert_eq!(path, "/tmp/test.txt");
            }
            _ => panic!("expected FsReadRequest"),
        }
    }

    #[test]
    fn parse_fs_write_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":11,"method":"fs/write_text_file","params":{"path":"/tmp/out.txt","content":"hello"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::FsWriteRequest {
                request_id,
                path,
                content,
            } => {
                assert_eq!(request_id, 11);
                assert_eq!(path, "/tmp/out.txt");
                assert_eq!(content, "hello");
            }
            _ => panic!("expected FsWriteRequest"),
        }
    }

    #[test]
    fn parse_subagent_spawned_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_spawned","subagentId":"sub-1","name":"researcher","role":"code-review","parentSessionId":"s1","dependsOn":["sub-0"]}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SubagentSpawned {
                subagent_id,
                name,
                role,
                parent_session_id,
                depends_on,
            } => {
                assert_eq!(subagent_id, "sub-1");
                assert_eq!(name, "researcher");
                assert_eq!(role.as_deref(), Some("code-review"));
                assert_eq!(parent_session_id.as_deref(), Some("s1"));
                assert_eq!(depends_on, vec!["sub-0"]);
            }
            _ => panic!("expected SubagentSpawned"),
        }
    }

    #[test]
    fn parse_subagent_progress_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_progress","subagentId":"sub-1","phase":"Analyzing files","tokensUsed":1500}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SubagentProgress {
                subagent_id,
                phase,
                tokens_used,
            } => {
                assert_eq!(subagent_id, "sub-1");
                assert_eq!(phase, "Analyzing files");
                assert_eq!(tokens_used, Some(1500));
            }
            _ => panic!("expected SubagentProgress"),
        }
    }

    #[test]
    fn parse_subagent_complete_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_complete","subagentId":"sub-1","tokensUsed":3200}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SubagentComplete {
                subagent_id,
                tokens_used,
            } => {
                assert_eq!(subagent_id, "sub-1");
                assert_eq!(tokens_used, Some(3200));
            }
            _ => panic!("expected SubagentComplete"),
        }
    }

    #[test]
    fn parse_subagent_error_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_error","subagentId":"sub-1","message":"timeout exceeded"}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SubagentError {
                subagent_id,
                message,
            } => {
                assert_eq!(subagent_id, "sub-1");
                assert_eq!(message, "timeout exceeded");
            }
            _ => panic!("expected SubagentError"),
        }
    }

    #[test]
    fn parse_agent_thought_chunk() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking..."}}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::AgentThought(t) => assert_eq!(t, "thinking..."),
            _ => panic!("expected AgentThought"),
        }
    }

    #[test]
    fn parse_plan_update() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"plan","entries":[{"content":"Step 1","priority":"high","status":"in_progress"}]}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::PlanUpdate { entries_json } => {
                assert!(entries_json.contains("Step 1"));
                assert!(entries_json.contains("in_progress"));
            }
            _ => panic!("expected PlanUpdate"),
        }
    }

    #[test]
    fn parse_unknown_session_update_no_panic() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"some_future_thing","data":"whatever"}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending);
        assert!(event.is_none());
    }

    #[test]
    fn parse_usage_update_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":5000,"size":200000,"cost":{"amount":0.05,"currency":"USD"}}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::UsageUpdate {
                used_tokens,
                context_window_size,
                cost,
                currency,
            } => {
                assert_eq!(used_tokens, 5000);
                assert_eq!(context_window_size, 200000);
                assert_eq!(cost, Some(0.05));
                assert_eq!(currency.as_deref(), Some("USD"));
            }
            _ => panic!("expected UsageUpdate"),
        }
    }

    #[test]
    fn parse_image_content_in_agent_message() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"base64data","mimeType":"image/png"}}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::ImageContent { data, mime_type } => {
                assert_eq!(data, "base64data");
                assert_eq!(mime_type, "image/png");
            }
            _ => panic!("expected ImageContent"),
        }
    }

    #[test]
    fn parse_prompt_response_cancelled_emits_cancelled_event() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending
            .lock()
            .unwrap()
            .insert(5, "session/prompt".to_string());

        let msg: RawMessage =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":5,"result":{"stopReason":"cancelled"}}"#)
                .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        assert!(matches!(event, AcpEvent::Cancelled));
    }

    // --- Integration tests: full message pipeline ---

    /// Helper: parse a JSON line through the full pipeline.
    fn parse_line(json: &str, pending: &Arc<Mutex<HashMap<u64, String>>>) -> Option<AcpEvent> {
        let msg: RawMessage = serde_json::from_str(json).ok()?;
        parse_message(msg, pending)
    }

    #[test]
    fn integration_full_session_lifecycle() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending.lock().unwrap().insert(1, "initialize".to_string());
        pending.lock().unwrap().insert(2, "session/new".to_string());
        pending
            .lock()
            .unwrap()
            .insert(3, "session/prompt".to_string());

        // 1. Initialize response
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-01-01","agentCapabilities":{"loadSession":true},"agentInfo":{"name":"kiro-cli","version":"1.5.0"}}}"#,
            &pending,
        ).unwrap();
        assert!(matches!(ev, AcpEvent::Initialized));

        // 2. Session/new response
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-abc123"}}"#,
            &pending,
        )
        .unwrap();
        match ev {
            AcpEvent::SessionCreated(id) => assert_eq!(id, "sess-abc123"),
            _ => panic!("expected SessionCreated"),
        }

        // 3. Text chunks
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-abc123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}}}"#,
            &pending,
        ).unwrap();
        match &ev {
            AcpEvent::TextChunk(t) => assert_eq!(t, "Hello "),
            _ => panic!("expected TextChunk"),
        }

        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-abc123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"}}}}"#,
            &pending,
        ).unwrap();
        match ev {
            AcpEvent::TextChunk(t) => assert_eq!(t, "world"),
            _ => panic!("expected TextChunk"),
        }

        // 4. Prompt response → TurnEnd
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","credits":0.05}}"#,
            &pending,
        )
        .unwrap();
        match ev {
            AcpEvent::TurnEnd {
                stop_reason,
                credits_used,
            } => {
                assert_eq!(stop_reason, "end_turn");
                assert_eq!(credits_used, Some(0.05));
            }
            _ => panic!("expected TurnEnd"),
        }
    }

    #[test]
    fn integration_tool_call_lifecycle() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        // 1. Tool call (pending)
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Read file","kind":"read","status":"pending"}}}"#,
            &pending,
        ).unwrap();
        match &ev {
            AcpEvent::ToolCall {
                id,
                title,
                kind,
                status,
            } => {
                assert_eq!(id, "tc-1");
                assert_eq!(title, "Read file");
                assert_eq!(kind.as_deref(), Some("read"));
                assert_eq!(status, "pending");
            }
            _ => panic!("expected ToolCall"),
        }

        // 2. Tool call update (in_progress)
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-1","status":"in_progress"}}}"#,
            &pending,
        ).unwrap();
        match &ev {
            AcpEvent::ToolCallUpdate {
                id,
                status,
                content,
            } => {
                assert_eq!(id, "tc-1");
                assert_eq!(status, "in_progress");
                assert!(content.is_none());
            }
            _ => panic!("expected ToolCallUpdate"),
        }

        // 3. Tool call update (completed with content)
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"file contents here"}}]}}}"#,
            &pending,
        ).unwrap();
        match ev {
            AcpEvent::ToolCallUpdate {
                id,
                status,
                content,
            } => {
                assert_eq!(id, "tc-1");
                assert_eq!(status, "completed");
                assert_eq!(content.as_deref(), Some("file contents here"));
            }
            _ => panic!("expected ToolCallUpdate"),
        }
    }

    #[test]
    fn integration_cancel_flow() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending
            .lock()
            .unwrap()
            .insert(3, "session/prompt".to_string());

        let ev = parse_line(
            r#"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}"#,
            &pending,
        )
        .unwrap();
        assert!(matches!(ev, AcpEvent::Cancelled));
    }

    #[test]
    fn integration_thought_chunk() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Let me analyze this..."}}}}"#,
            &pending,
        ).unwrap();
        match ev {
            AcpEvent::AgentThought(t) => assert_eq!(t, "Let me analyze this..."),
            _ => panic!("expected AgentThought"),
        }
    }

    #[test]
    fn integration_plan_update() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"plan","entries":[{"content":"Read the codebase","priority":"high","status":"completed"},{"content":"Implement changes","priority":"medium","status":"in_progress"}]}}}"#,
            &pending,
        ).unwrap();
        match ev {
            AcpEvent::PlanUpdate { entries_json } => {
                assert!(entries_json.contains("Read the codebase"));
                assert!(entries_json.contains("Implement changes"));
                assert!(entries_json.contains("completed"));
                assert!(entries_json.contains("in_progress"));
            }
            _ => panic!("expected PlanUpdate"),
        }
    }

    #[test]
    fn integration_subagent_lifecycle() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        // 1. Subagent spawned
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_spawned","subagentId":"sub-42","name":"code-reviewer","role":"review","parentSessionId":"s1","dependsOn":[]}}}"#,
            &pending,
        ).unwrap();
        match &ev {
            AcpEvent::SubagentSpawned {
                subagent_id,
                name,
                role,
                ..
            } => {
                assert_eq!(subagent_id, "sub-42");
                assert_eq!(name, "code-reviewer");
                assert_eq!(role.as_deref(), Some("review"));
            }
            _ => panic!("expected SubagentSpawned"),
        }

        // 2. Subagent progress
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_progress","subagentId":"sub-42","phase":"Reviewing files","tokensUsed":2000}}}"#,
            &pending,
        ).unwrap();
        match &ev {
            AcpEvent::SubagentProgress {
                subagent_id,
                phase,
                tokens_used,
            } => {
                assert_eq!(subagent_id, "sub-42");
                assert_eq!(phase, "Reviewing files");
                assert_eq!(*tokens_used, Some(2000));
            }
            _ => panic!("expected SubagentProgress"),
        }

        // 3. Subagent complete
        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"subagent_complete","subagentId":"sub-42","tokensUsed":4500}}}"#,
            &pending,
        ).unwrap();
        match ev {
            AcpEvent::SubagentComplete {
                subagent_id,
                tokens_used,
            } => {
                assert_eq!(subagent_id, "sub-42");
                assert_eq!(tokens_used, Some(4500));
            }
            _ => panic!("expected SubagentComplete"),
        }
    }

    #[test]
    fn integration_malformed_json_no_panic() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        // Invalid JSON
        assert!(parse_line("not json at all", &pending).is_none());

        // Partial JSON
        assert!(parse_line(r#"{"jsonrpc":"2.0","id":1"#, &pending).is_none());

        // Empty string
        assert!(parse_line("", &pending).is_none());

        // Valid JSON but missing required fields for any event
        assert!(parse_line(r#"{"foo":"bar"}"#, &pending).is_none());
    }

    #[test]
    fn integration_unknown_session_update_variant() {
        let pending = Arc::new(Mutex::new(HashMap::new()));

        let ev = parse_line(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"quantum_teleport","data":{"qubits":42}}}}"#,
            &pending,
        );
        assert!(ev.is_none());
    }

    #[test]
    fn parse_kiro_metadata_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"_kiro.dev/metadata","params":{"contextUsagePercentage":42.5,"meteringUsage":[{"value":1.25}]}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::MetadataUpdate {
                context_percentage,
                credits_used,
            } => {
                assert!((context_percentage - 42.5).abs() < f64::EPSILON);
                assert_eq!(credits_used, Some(1.25));
            }
            _ => panic!("expected MetadataUpdate"),
        }
    }

    #[test]
    fn parse_kiro_metadata_without_credits() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"_kiro.dev/metadata","params":{"contextUsagePercentage":80.0}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::MetadataUpdate {
                context_percentage,
                credits_used,
            } => {
                assert!((context_percentage - 80.0).abs() < f64::EPSILON);
                assert_eq!(credits_used, None);
            }
            _ => panic!("expected MetadataUpdate"),
        }
    }

    #[test]
    fn parse_session_info_update() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"session_info_update","title":"Implement auth flow"}}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SessionInfoUpdate(title) => assert_eq!(title, "Implement auth flow"),
            _ => panic!("expected SessionInfoUpdate"),
        }
    }

    #[test]
    fn parse_compaction_status_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"_kiro.dev/compaction/status","params":{"status":"in_progress"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::CompactionStatus(status) => assert_eq!(status, "in_progress"),
            _ => panic!("expected CompactionStatus"),
        }
    }

    #[test]
    fn parse_session_list_response() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        pending
            .lock()
            .unwrap()
            .insert(5, "session/list".to_string());

        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":5,"result":{"sessions":[{"sessionId":"s1","title":"Fix bug","createdAt":"2025-01-01T00:00:00Z"}]}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::SessionList(json) => {
                assert!(json.contains("s1"));
                assert!(json.contains("Fix bug"));
            }
            _ => panic!("expected SessionList"),
        }
    }

    #[test]
    fn parse_terminal_create_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":50,"method":"terminal/create","params":{"sessionId":"s1","command":"bash","args":["-c","echo hi"],"env":{"FOO":"bar"},"cwd":"/tmp","outputByteLimit":1024}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TerminalCreate {
                request_id,
                session_id,
                command,
                args,
                env,
                cwd,
                output_byte_limit,
            } => {
                assert_eq!(request_id, 50);
                assert_eq!(session_id, "s1");
                assert_eq!(command, "bash");
                assert_eq!(args, vec!["-c", "echo hi"]);
                assert_eq!(env, vec![("FOO".to_string(), "bar".to_string())]);
                assert_eq!(cwd.as_deref(), Some("/tmp"));
                assert_eq!(output_byte_limit, Some(1024));
            }
            _ => panic!("expected TerminalCreate"),
        }
    }

    #[test]
    fn parse_terminal_create_missing_command() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":51,"method":"terminal/create","params":{"sessionId":"s1"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        assert!(matches!(event, AcpEvent::ProtocolLog(_)));
    }

    #[test]
    fn parse_terminal_output_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":52,"method":"terminal/output","params":{"terminalId":"t-123"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TerminalOutput {
                request_id,
                terminal_id,
            } => {
                assert_eq!(request_id, 52);
                assert_eq!(terminal_id, "t-123");
            }
            _ => panic!("expected TerminalOutput"),
        }
    }

    #[test]
    fn parse_terminal_wait_for_exit_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":53,"method":"terminal/wait_for_exit","params":{"terminalId":"t-123"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TerminalWaitForExit {
                request_id,
                terminal_id,
            } => {
                assert_eq!(request_id, 53);
                assert_eq!(terminal_id, "t-123");
            }
            _ => panic!("expected TerminalWaitForExit"),
        }
    }

    #[test]
    fn parse_terminal_kill_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":54,"method":"terminal/kill","params":{"terminalId":"t-123"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TerminalKill {
                request_id,
                terminal_id,
            } => {
                assert_eq!(request_id, 54);
                assert_eq!(terminal_id, "t-123");
            }
            _ => panic!("expected TerminalKill"),
        }
    }

    #[test]
    fn parse_terminal_release_request() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","id":55,"method":"terminal/release","params":{"terminalId":"t-123"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        match event {
            AcpEvent::TerminalRelease {
                request_id,
                terminal_id,
            } => {
                assert_eq!(request_id, 55);
                assert_eq!(terminal_id, "t-123");
            }
            _ => panic!("expected TerminalRelease"),
        }
    }

    #[test]
    fn parse_terminal_output_missing_params() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage =
            serde_json::from_str(r#"{"jsonrpc":"2.0","id":56,"method":"terminal/output"}"#)
                .unwrap();
        let event = parse_message(msg, &pending).unwrap();
        assert!(matches!(event, AcpEvent::ProtocolLog(_)));
    }
}
