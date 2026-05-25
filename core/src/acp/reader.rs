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
            eprintln!("[ACP reader] failed to parse line: {e}");
            return None;
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
                let params: RequestPermissionParams = match serde_json::from_value(msg.params?) {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!("[ACP] Failed to parse permission request: {e}");
                        return None;
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
                let params: serde_json::Value = msg.params?;
                let path = params.get("path")?.as_str()?.to_string();
                return Some(AcpEvent::FsReadRequest {
                    request_id: id,
                    path,
                });
            }
            "fs/write_text_file" => {
                let params: serde_json::Value = msg.params?;
                let path = params.get("path")?.as_str()?.to_string();
                let content = params.get("content")?.as_str()?.to_string();
                return Some(AcpEvent::FsWriteRequest {
                    request_id: id,
                    path,
                    content,
                });
            }
            _ => return None,
        }
    }

    if let Some(id) = msg.id {
        // This is a response to one of our requests
        let method = pending_methods.lock().ok()?.remove(&id)?;
        if let Some(err) = msg.error {
            // Check if this is an auth error
            if is_auth_error(err.code, &err.message) {
                return Some(AcpEvent::AuthRequired(err.message));
            }
            return Some(AcpEvent::Error(format!("{}: {}", method, err.message)));
        }
        let result = msg.result?;
        match method.as_str() {
            "initialize" => {
                let _: InitializeResult = match serde_json::from_value(result) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("[ACP] Failed to parse initialize result: {e}");
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
                        eprintln!("[ACP] Failed to parse session/new result: {e}");
                        return Some(AcpEvent::Error(format!(
                            "Failed to parse session/new response: {e}"
                        )));
                    }
                };
                Some(AcpEvent::SessionCreated(r.session_id))
            }
            "session/cancel" => None, // Ignore legacy cancel responses
            "session/prompt" => {
let r: PromptResponseWithCredits = match serde_json::from_value(result) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("[ACP] Failed to parse session/prompt result: {e}");
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
            let params = msg.params?;
            let update: SessionUpdateParams = serde_json::from_value(params).ok()?;
            match update.update {
                SessionUpdate::AgentMessageChunk { content } => match content {
                    ContentBlock::Text(tc) => Some(AcpEvent::TextChunk(tc.text)),
                    ContentBlock::Image(img) => Some(AcpEvent::ImageContent {
                        data: img.data,
                        mime_type: img.mime_type,
                    }),
                    _ => {
                        eprintln!("[ACP] Unsupported content type in AgentMessageChunk");
                        None
                    }
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
                SessionUpdate::Unknown => None,
            }
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello world"}}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"subagent_spawned","subagentId":"sub-1","name":"researcher","role":"code-review","parentSessionId":"s1","dependsOn":["sub-0"]}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"subagent_progress","subagentId":"sub-1","phase":"Analyzing files","tokensUsed":1500}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"subagent_complete","subagentId":"sub-1","tokensUsed":3200}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"subagent_error","subagentId":"sub-1","message":"timeout exceeded"}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking..."}}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"plan","entries":[{"content":"Step 1","priority":"high","status":"in_progress"}]}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"some_future_thing","data":"whatever"}}"#,
        )
        .unwrap();
        let event = parse_message(msg, &pending);
        assert!(event.is_none());
    }

    #[test]
    fn parse_usage_update_notification() {
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let msg: RawMessage = serde_json::from_str(
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"usage_update","used":5000,"size":200000,"cost":{"amount":0.05,"currency":"USD"}}}"#,
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
            r#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","sessionUpdate":"agent_message_chunk","content":{"type":"image","data":"base64data","mimeType":"image/png"}}}"#,
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
}
