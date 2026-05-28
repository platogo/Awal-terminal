use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use agent_client_protocol_schema::{
    ContentBlock, Plan, StopReason, TextContent, ToolCall, ToolCallId, ToolCallStatus,
    ToolCallUpdate, ToolKind,
};

// --- JSON-RPC envelope types ---

#[derive(Serialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: &'static str,
    pub id: u64,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl JsonRpcRequest {
    pub fn new(id: u64, method: &str, params: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            method: method.to_string(),
            params,
        }
    }
}

#[derive(Deserialize)]
pub struct JsonRpcResponse {
    #[allow(dead_code)]
    pub jsonrpc: String,
    pub id: Option<u64>,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
}

#[derive(Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[allow(dead_code)]
    pub data: Option<Value>,
}

#[derive(Deserialize)]
pub struct JsonRpcNotification {
    #[allow(dead_code)]
    pub jsonrpc: String,
    pub method: String,
    pub params: Option<Value>,
}

// --- ACP-specific types ---

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeResult {
    #[allow(dead_code)]
    pub protocol_version: Option<Value>,
    #[allow(dead_code)]
    pub agent_capabilities: Option<Value>,
    #[allow(dead_code)]
    pub agent_info: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionNewParams {
    pub cwd: String,
    pub mcp_servers: Vec<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionNewResult {
    pub session_id: String,
    #[serde(default)]
    pub config_options: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCancelParams {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCancelSubagentParams {
    pub session_id: String,
    pub subagent_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRewindParams {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionResumeParams {
    pub session_id: String,
    pub cwd: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPromptParams {
    pub session_id: String,
    pub prompt: Vec<ContentBlock>,
}

/// Wrapper around SDK `PromptResponse` that includes kiro-specific `credits` field.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptResponseWithCredits {
    pub stop_reason: StopReason,
    #[serde(default, alias = "credits")]
    pub credits_used: Option<f64>,
    #[serde(default)]
    pub usage: Option<agent_client_protocol_schema::Usage>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdateParams {
    #[allow(dead_code)]
    pub session_id: String,
    pub update: SessionUpdate,
}

/// Combined session update enum: SDK-defined variants use SDK types,
/// kiro-specific variants (subagents, turn_end) are kept hand-rolled.
#[derive(Deserialize)]
#[serde(tag = "sessionUpdate", rename_all = "snake_case")]
pub enum SessionUpdate {
    AgentMessageChunk {
        content: ContentBlock,
    },
    AgentThoughtChunk {
        content: ContentBlock,
    },
    ToolCall(ToolCall),
    ToolCallUpdate(ToolCallUpdate),
    Plan(Plan),
    TurnEnd,
    SubagentSpawned {
        #[serde(rename = "subagentId")]
        subagent_id: String,
        name: String,
        role: Option<String>,
        #[serde(rename = "parentSessionId")]
        parent_session_id: Option<String>,
        #[serde(rename = "dependsOn")]
        depends_on: Option<Vec<String>>,
    },
    SubagentProgress {
        #[serde(rename = "subagentId")]
        subagent_id: String,
        phase: String,
        #[serde(rename = "tokensUsed")]
        tokens_used: Option<u64>,
    },
    SubagentComplete {
        #[serde(rename = "subagentId")]
        subagent_id: String,
        #[serde(rename = "tokensUsed")]
        tokens_used: Option<u64>,
    },
    SubagentError {
        #[serde(rename = "subagentId")]
        subagent_id: String,
        message: String,
    },
    UsageUpdate(agent_client_protocol_schema::UsageUpdate),
    SessionInfoUpdate {
        title: String,
    },
    ConfigOptionUpdate {
        #[serde(rename = "configOptions")]
        config_options: Value,
    },
    AvailableCommandsUpdate {
        #[serde(rename = "availableCommands")]
        available_commands: Value,
    },
    CurrentModeUpdate {
        #[serde(rename = "currentModeId")]
        current_mode_id: String,
    },
    #[serde(other)]
    Unknown,
}

// --- Permission request (server-to-client) ---

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCloseParams {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionListParams {
    pub cwd: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionListEntry {
    pub session_id: String,
    pub title: Option<String>,
    pub created_at: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestPermissionParams {
    pub session_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub description: String,
    pub kind: Option<String>,
}

// --- JSON-RPC notification (outgoing) ---

#[derive(Serialize)]
pub struct JsonRpcNotificationOut {
    pub jsonrpc: &'static str,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

// --- JSON-RPC response (outgoing) ---

#[derive(Serialize)]
pub struct JsonRpcResponseOut {
    pub jsonrpc: &'static str,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcErrorOut>,
}

#[derive(Serialize)]
pub struct JsonRpcErrorOut {
    pub code: i64,
    pub message: String,
}

// --- Incoming message parsing ---

/// A raw line from stdout can be either a response (has `id`) or a notification (has `method`, no `id`).
#[derive(Deserialize)]
pub struct RawMessage {
    pub id: Option<Value>,
    pub method: Option<String>,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
    pub params: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_initialize_request() {
        let params = serde_json::json!({
            "protocolVersion": 1,
            "clientCapabilities": { "fs": { "readTextFile": true, "writeTextFile": true }, "terminal": false },
            "clientInfo": { "name": "AwalTerminal", "version": "0.17.0" }
        });
        let req = JsonRpcRequest::new(1, "initialize", Some(params));
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"method\":\"initialize\""));
        assert!(json.contains("\"protocolVersion\":1"));
        assert!(!json.contains("\"protocolVersion\":\""));
        assert!(json.contains("\"clientCapabilities\":{\"fs\":{\"readTextFile\":true,\"writeTextFile\":true},\"terminal\":false}"));
    }

    #[test]
    fn deserialize_session_update_text_chunk() {
        let json = r#"{"sessionId":"abc","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        match params.update {
            SessionUpdate::AgentMessageChunk { content } => match content {
                ContentBlock::Text(tc) => assert_eq!(tc.text, "hello"),
                _ => panic!("expected Text content block"),
            },
            _ => panic!("expected AgentMessageChunk"),
        }
    }

    #[test]
    fn deserialize_session_update_turn_end() {
        let json = r#"{"sessionId":"abc","update":{"sessionUpdate":"turn_end"}}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        assert!(matches!(params.update, SessionUpdate::TurnEnd));
    }

    #[test]
    fn deserialize_session_update_tool_call() {
        let json = r#"{"sessionId":"abc","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"in_progress"}}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        match params.update {
            SessionUpdate::ToolCall(tc) => {
                assert_eq!(tc.tool_call_id.0.as_ref(), "t1");
                assert_eq!(tc.title, "Read file");
                assert_eq!(tc.kind, ToolKind::Read);
                assert_eq!(tc.status, ToolCallStatus::InProgress);
            }
            _ => panic!("expected ToolCall"),
        }
    }

    #[test]
    fn deserialize_response_with_error() {
        let json =
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.id, Some(1));
        let err = resp.error.unwrap();
        assert_eq!(err.code, -32600);
        assert_eq!(err.message, "Invalid request");
    }

    #[test]
    fn serialize_session_rewind_params() {
        let params = SessionRewindParams {
            session_id: "sess-123".to_string(),
        };
        let json = serde_json::to_value(&params).unwrap();
        assert_eq!(json["sessionId"], "sess-123");
        assert_eq!(json.as_object().unwrap().len(), 1);
    }

    #[test]
    fn sdk_content_block_text_roundtrip() {
        // Verify SDK ContentBlock serializes as {"type":"text","text":"..."}
        let block = ContentBlock::Text(TextContent::new("hello"));
        let json = serde_json::to_value(&block).unwrap();
        assert_eq!(json["type"], "text");
        assert_eq!(json["text"], "hello");

        // And deserializes back
        let parsed: ContentBlock = serde_json::from_value(json).unwrap();
        match parsed {
            ContentBlock::Text(tc) => assert_eq!(tc.text, "hello"),
            _ => panic!("expected Text"),
        }
    }

    #[test]
    fn deserialize_prompt_response_with_credits() {
        let json = r#"{"stopReason":"end_turn","credits":1.5}"#;
        let resp: PromptResponseWithCredits = serde_json::from_str(json).unwrap();
        assert_eq!(resp.stop_reason, StopReason::EndTurn);
        assert_eq!(resp.credits_used, Some(1.5));
    }

    #[test]
    fn deserialize_prompt_response_without_credits() {
        let json = r#"{"stopReason":"cancelled"}"#;
        let resp: PromptResponseWithCredits = serde_json::from_str(json).unwrap();
        assert_eq!(resp.stop_reason, StopReason::Cancelled);
        assert_eq!(resp.credits_used, None);
    }

    #[test]
    fn deserialize_unknown_session_update() {
        let json = r#"{"sessionId":"abc","update":{"sessionUpdate":"some_future_variant"}}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        assert!(matches!(params.update, SessionUpdate::Unknown));
    }

    #[test]
    fn serialize_session_prompt_params_wire_format() {
        let params = SessionPromptParams {
            session_id: "sess-1".to_string(),
            prompt: vec![ContentBlock::Text(TextContent::new("hello"))],
        };
        let json = serde_json::to_value(&params).unwrap();
        assert_eq!(json["sessionId"], "sess-1");
        // prompt field contains array of tagged content blocks
        let prompt = json["prompt"].as_array().unwrap();
        assert_eq!(prompt.len(), 1);
        assert_eq!(prompt[0]["type"], "text");
        assert_eq!(prompt[0]["text"], "hello");
    }
}
