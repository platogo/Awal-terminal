use std::io::BufRead;
use std::io::BufReader;
use std::process::ChildStdout;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use crate::acp::protocol::{
    InitializeResult, RawMessage, RequestPermissionParams, SessionNewResult, SessionPromptResult,
    SessionUpdate, SessionUpdateParams,
};

/// Events produced by the ACP reader thread.
pub enum AcpEvent {
    Initialized,
    SessionCreated(String),
    TextChunk(String),
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
    },
    PermissionRequest {
        request_id: u64,
        tool_call_id: String,
        tool_name: String,
        description: String,
        kind: Option<String>,
    },
    Error(String),
    ProcessExited(Option<i32>),
}

/// Spawn a reader thread that parses JSON-RPC messages from stdout and sends AcpEvents.
pub fn spawn_reader(
    stdout: ChildStdout,
    tx: mpsc::Sender<AcpEvent>,
    pending_methods: std::sync::Arc<std::sync::Mutex<std::collections::HashMap<u64, String>>>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            if line.is_empty() {
                continue;
            }
            let msg: RawMessage = match serde_json::from_str(&line) {
                Ok(m) => m,
                Err(e) => {
                    let _ = tx.send(AcpEvent::Error(format!("Parse error: {e}")));
                    continue;
                }
            };
            let event = parse_message(msg, &pending_methods);
            if let Some(ev) = event {
                if tx.send(ev).is_err() {
                    break;
                }
            }
        }
        let _ = tx.send(AcpEvent::ProcessExited(None));
    })
}

fn parse_message(
    msg: RawMessage,
    pending_methods: &std::sync::Mutex<std::collections::HashMap<u64, String>>,
) -> Option<AcpEvent> {
    // Server-to-client request: has both `id` and `method`
    if let (Some(id), Some(method)) = (msg.id, msg.method.as_ref()) {
        match method.as_str() {
            "session/request_permission" => {
                let params: RequestPermissionParams = serde_json::from_value(msg.params?).ok()?;
                return Some(AcpEvent::PermissionRequest {
                    request_id: id,
                    tool_call_id: params.tool_call_id,
                    tool_name: params.tool_name,
                    description: params.description,
                    kind: params.kind,
                });
            }
            _ => return None,
        }
    }

    if let Some(id) = msg.id {
        // This is a response to one of our requests
        let method = pending_methods.lock().ok()?.remove(&id)?;
        if let Some(err) = msg.error {
            return Some(AcpEvent::Error(format!("{}: {}", method, err.message)));
        }
        let result = msg.result?;
        match method.as_str() {
            "initialize" => {
                let _: InitializeResult = serde_json::from_value(result).ok()?;
                Some(AcpEvent::Initialized)
            }
            "session/new" => {
                let r: SessionNewResult = serde_json::from_value(result).ok()?;
                Some(AcpEvent::SessionCreated(r.session_id))
            }
            "session/prompt" => {
                let r: SessionPromptResult = serde_json::from_value(result).ok()?;
                Some(AcpEvent::TurnEnd {
                    stop_reason: r.stop_reason.unwrap_or_default(),
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
                SessionUpdate::AgentMessageChunk { content } => {
                    Some(AcpEvent::TextChunk(content.text))
                }
                SessionUpdate::ToolCall {
                    tool_call_id,
                    title,
                    kind,
                    status,
                } => Some(AcpEvent::ToolCall {
                    id: tool_call_id,
                    title,
                    kind,
                    status,
                }),
                SessionUpdate::ToolCallUpdate {
                    tool_call_id,
                    status,
                    content,
                } => Some(AcpEvent::ToolCallUpdate {
                    id: tool_call_id,
                    status,
                    content: content.map(|c| c.text),
                }),
                SessionUpdate::TurnEnd => Some(AcpEvent::TurnEnd {
                    stop_reason: "end_turn".to_string(),
                }),
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
}
