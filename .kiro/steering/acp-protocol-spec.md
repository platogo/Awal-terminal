# ACP Protocol Reference

> Source: https://agentclientprotocol.com | Kiro: https://kiro.dev/docs/cli/acp/
> Protocol Version: 1 (major version integer, incremented only on breaking changes)

## Overview

The Agent Client Protocol (ACP) standardizes communication between AI coding agents and client applications (editors/IDEs). It uses **JSON-RPC 2.0** over stdio, enabling any ACP-compatible agent to work with any ACP-compatible client.

### Design Philosophy

1. **MCP-friendly** — Built on JSON-RPC, reuses MCP types where possible
2. **UX-first** — Designed to solve UX challenges of interacting with AI agents
3. **Trusted** — Works when using a code editor to talk to a model you trust

### Architecture

- Client launches Agent as a subprocess
- Communication over stdin/stdout using JSON-RPC 2.0
- Each connection supports multiple concurrent sessions
- Bidirectional: Agent can make requests of the Client (e.g., permission requests, file access)
- Heavy use of notifications for real-time streaming updates

### Communication Model

- **Methods**: Request-response pairs (include `id`, expect result or error)
- **Notifications**: One-way messages (no `id`, no response expected)

### Conventions

- JSON object property keys: `camelCase`
- String discriminator values: `snake_case`
- All file paths MUST be absolute
- Line numbers are 1-based

### Message Flow

```
1. Initialization: Client → Agent: initialize
2. Authentication: Client → Agent: authenticate (if required)
3. Session Setup: Client → Agent: session/new or session/load
4. Prompt Turn:
   - Client → Agent: session/prompt
   - Agent → Client: session/update notifications (streaming)
   - Agent → Client: fs/*, terminal/* requests as needed
   - Turn ends with session/prompt response containing stopReason
```

## Initialization

The `initialize` method negotiates protocol version and capabilities.

### Request (Client → Agent)

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {
      "fs": {
        "readTextFile": true,
        "writeTextFile": true
      },
      "terminal": true
    },
    "clientInfo": {
      "name": "my-client",
      "title": "My Client",
      "version": "1.0.0"
    }
  }
}
```

### Response (Agent → Client)

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "result": {
    "protocolVersion": 1,
    "agentCapabilities": {
      "loadSession": true,
      "promptCapabilities": {
        "image": true,
        "audio": true,
        "embeddedContext": true
      },
      "mcpCapabilities": {
        "http": true,
        "sse": true
      },
      "sessionCapabilities": {
        "list": {},
        "resume": {},
        "close": {}
      },
      "auth": {
        "logout": {}
      }
    },
    "agentInfo": {
      "name": "my-agent",
      "title": "My Agent",
      "version": "1.0.0"
    },
    "authMethods": []
  }
}
```

### Version Negotiation

- Client sends latest version it supports
- Agent responds with same version if supported, otherwise latest it supports
- If Client doesn't support Agent's version, it SHOULD close the connection

### Client Capabilities

| Capability | Type | Description |
|---|---|---|
| `fs.readTextFile` | boolean | `fs/read_text_file` method available |
| `fs.writeTextFile` | boolean | `fs/write_text_file` method available |
| `terminal` | boolean | All `terminal/*` methods available |

### Agent Capabilities

| Capability | Type | Description |
|---|---|---|
| `loadSession` | boolean | `session/load` method available |
| `promptCapabilities.image` | boolean | Prompt may include images |
| `promptCapabilities.audio` | boolean | Prompt may include audio |
| `promptCapabilities.embeddedContext` | boolean | Prompt may include embedded resources |
| `mcpCapabilities.http` | boolean | Agent supports HTTP MCP transport |
| `mcpCapabilities.sse` | boolean | Agent supports SSE MCP transport (deprecated) |
| `sessionCapabilities.list` | object | `session/list` available |
| `sessionCapabilities.resume` | object | `session/resume` available |
| `sessionCapabilities.close` | object | `session/close` available |
| `auth.logout` | object | `logout` method available |

### Implementation Information

Both `clientInfo` and `agentInfo` take:
- `name` (string) — programmatic identifier
- `title` (string) — human-readable display name
- `version` (string) — implementation version

## Authentication

### Advertising Auth Methods

Agents advertise in `initialize` response:

```json
{
  "authMethods": [
    {
      "id": "agent-login",
      "name": "Agent login",
      "description": "Sign in using the agent's login flow"
    }
  ]
}
```

Default type is `"agent"` (Agent handles auth itself).

### authenticate (Client → Agent)

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "authenticate",
  "params": {
    "methodId": "agent-login"
  }
}
```

Response on success:
```json
{ "jsonrpc": "2.0", "id": 1, "result": {} }
```

### logout (Client → Agent)

Requires `agentCapabilities.auth.logout` capability.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "logout",
  "params": {}
}
```

Response: `{ "jsonrpc": "2.0", "id": 2, "result": {} }`

After logout, new sessions requiring auth will need `authenticate` again.

## Session Lifecycle

### session/new (Client → Agent)

Creates a new conversation session.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/new",
  "params": {
    "cwd": "/home/user/project",
    "mcpServers": [
      {
        "name": "filesystem",
        "command": "/path/to/mcp-server",
        "args": ["--stdio"],
        "env": [{ "name": "API_KEY", "value": "secret123" }]
      }
    ]
  }
}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "sessionId": "sess_abc123def456",
    "modes": { ... },
    "configOptions": [ ... ]
  }
}
```

Parameters:
- `cwd` (string, required) — absolute path, working directory for the session
- `mcpServers` (array) — MCP server configurations

### session/load (Client → Agent)

Requires `loadSession` capability. Resumes a previous session with full history replay.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/load",
  "params": {
    "sessionId": "sess_789xyz",
    "cwd": "/home/user/project",
    "mcpServers": []
  }
}
```

The Agent replays conversation history via `session/update` notifications (`user_message_chunk`, `agent_message_chunk`), then responds:
```json
{ "jsonrpc": "2.0", "id": 1, "result": null }
```

### session/resume (Client → Agent)

Requires `sessionCapabilities.resume`. Reconnects without replaying history.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/resume",
  "params": {
    "sessionId": "sess_789xyz",
    "cwd": "/home/user/project",
    "mcpServers": []
  }
}
```

Response: `{ "jsonrpc": "2.0", "id": 2, "result": {} }`

### session/list (Client → Agent)

Requires `sessionCapabilities.list`. Discovers existing sessions with optional filtering.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/list",
  "params": {
    "cwd": "/home/user/project",
    "cursor": "eyJwYWdlIjogMn0="
  }
}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "sessions": [
      {
        "sessionId": "sess_abc123def456",
        "cwd": "/home/user/project",
        "title": "Implement session list API",
        "updatedAt": "2025-10-29T14:22:15Z",
        "_meta": {}
      }
    ],
    "nextCursor": "eyJwYWdlIjogM30="
  }
}
```

Pagination: cursor-based. Missing `nextCursor` = end of results. Cursors are opaque tokens.

### session/close (Client → Agent)

Requires `sessionCapabilities.close`. Cancels ongoing work and frees resources.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/close",
  "params": {
    "sessionId": "sess_789xyz"
  }
}
```

Response: `{ "jsonrpc": "2.0", "id": 2, "result": {} }`

### session/cancel (Client → Agent, Notification)

Cancels an ongoing prompt turn. No response expected.

```json
{
  "jsonrpc": "2.0",
  "method": "session/cancel",
  "params": {
    "sessionId": "sess_abc123def456"
  }
}
```

### MCP Server Transport Types

**Stdio** (all agents MUST support):
```json
{ "name": "fs", "command": "/path/to/server", "args": ["--stdio"], "env": [] }
```

**HTTP** (requires `mcpCapabilities.http`):
```json
{ "type": "http", "name": "api", "url": "https://api.example.com/mcp", "headers": [{"name": "Authorization", "value": "Bearer token"}] }
```

**SSE** (requires `mcpCapabilities.sse`, deprecated):
```json
{ "type": "sse", "name": "events", "url": "https://events.example.com/mcp", "headers": [] }
```

## Prompt Turn

A prompt turn is a complete interaction cycle: user message → agent processing → response.

### session/prompt (Client → Agent)

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123def456",
    "prompt": [
      {
        "type": "text",
        "text": "Can you analyze this code for potential issues?"
      },
      {
        "type": "resource",
        "resource": {
          "uri": "file:///home/user/project/main.py",
          "mimeType": "text/x-python",
          "text": "def process_data(items):\n    for item in items:\n        print(item)"
        }
      }
    ]
  }
}
```

Parameters:
- `sessionId` (string, required) — session to prompt
- `prompt` (ContentBlock[], required) — content blocks restricted by prompt capabilities

### session/update (Agent → Client, Notification)

Agent streams output via notifications:

**Agent message chunk:**
```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": {
        "type": "text",
        "text": "I'll analyze your code..."
      }
    }
  }
}
```

**Tool call notification:**
```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "tool_call",
      "toolCallId": "call_001",
      "title": "Analyzing Python code",
      "kind": "other",
      "status": "pending"
    }
  }
}
```

### Turn End (session/prompt response)

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "stopReason": "end_turn"
  }
}
```

### Stop Reasons

| Reason | Description |
|---|---|
| `end_turn` | Model finished responding without requesting more tools |
| `max_tokens` | Maximum token limit reached |
| `max_turn_requests` | Maximum model requests in a single turn exceeded |
| `refusal` | Agent refuses to continue |
| `cancelled` | Client cancelled the turn |

### Cancellation

Client sends `session/cancel` notification. Agent MUST:
1. Stop all LLM requests and tool invocations ASAP
2. Send any pending updates before responding
3. Respond to original `session/prompt` with `stopReason: "cancelled"`

Client MUST respond to all pending `session/request_permission` with `"cancelled"` outcome.

### Session Update Types

| `sessionUpdate` value | Description |
|---|---|
| `agent_message_chunk` | Streaming text/content from the agent |
| `user_message_chunk` | User message replay (during session/load) |
| `tool_call` | New tool call reported |
| `tool_call_update` | Progress/result update for a tool call |
| `plan` | Agent execution plan |
| `available_commands_update` | Slash commands list update |
| `current_mode_update` | Mode change notification |
| `config_option_update` | Config option change |
| `session_info_update` | Session metadata update (title, etc.) |

## Content Types

Content blocks use the same structure as MCP's `ContentBlock`. They appear in prompts, agent messages, and tool call results.

### Text Content

All agents MUST support text in prompts.

```json
{ "type": "text", "text": "Hello, world!" }
```

### Image Content

Requires `promptCapabilities.image` for prompts.

```json
{
  "type": "image",
  "mimeType": "image/png",
  "data": "iVBORw0KGgoAAAANSUhEUgAAAAE..."
}
```

Fields: `data` (base64, required), `mimeType` (required), `uri` (optional), `annotations` (optional)

### Audio Content

Requires `promptCapabilities.audio` for prompts.

```json
{
  "type": "audio",
  "mimeType": "audio/wav",
  "data": "UklGRiQAAABXQVZFZm10IBAAAAAB..."
}
```

### Embedded Resource

Requires `promptCapabilities.embeddedContext` for prompts. Preferred way to include file context (e.g., @-mentions).

```json
{
  "type": "resource",
  "resource": {
    "uri": "file:///home/user/script.py",
    "mimeType": "text/x-python",
    "text": "def hello():\n    print('Hello, world!')"
  }
}
```

Resource can be text (`uri` + `text`) or blob (`uri` + `blob` base64).

### Resource Link

References to resources the Agent can access. All agents MUST support in prompts.

```json
{
  "type": "resource_link",
  "uri": "file:///home/user/document.pdf",
  "name": "document.pdf",
  "mimeType": "application/pdf",
  "size": 1024000
}
```

## Tool Calls

Tool calls represent actions the LLM requests the Agent to perform.

### Creating a Tool Call

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "tool_call",
      "toolCallId": "call_001",
      "title": "Reading configuration file",
      "kind": "read",
      "status": "pending",
      "content": [],
      "locations": [],
      "rawInput": {},
      "rawOutput": {}
    }
  }
}
```

### Tool Kinds

`read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `other` (default)

### Tool Call Status

`pending` → `in_progress` → `completed` | `failed`

### Updating a Tool Call

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "call_001",
      "status": "completed",
      "content": [
        {
          "type": "content",
          "content": { "type": "text", "text": "Analysis complete." }
        }
      ]
    }
  }
}
```

### Tool Call Content Types

**Regular content:**
```json
{ "type": "content", "content": { "type": "text", "text": "..." } }
```

**Diffs:**
```json
{
  "type": "diff",
  "path": "/home/user/project/src/config.json",
  "oldText": "{ \"debug\": false }",
  "newText": "{ \"debug\": true }"
}
```

**Terminal output:**
```json
{ "type": "terminal", "terminalId": "term_xyz789" }
```

### Tool Call Locations (Follow-Along)

```json
{ "path": "/home/user/project/src/main.py", "line": 42 }
```

### Requesting Permission

Agent → Client request before executing a tool:

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "session/request_permission",
  "params": {
    "sessionId": "sess_abc123def456",
    "toolCall": {
      "toolCallId": "call_001"
    },
    "options": [
      { "optionId": "allow-once", "name": "Allow once", "kind": "allow_once" },
      { "optionId": "reject-once", "name": "Reject", "kind": "reject_once" }
    ]
  }
}
```

Client response:
```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "outcome": { "outcome": "selected", "optionId": "allow-once" }
  }
}
```

Permission option kinds: `allow_once`, `allow_always`, `reject_once`, `reject_always`

Cancelled outcome (when turn is cancelled):
```json
{ "outcome": { "outcome": "cancelled" } }
```

## File System

Requires `fs.readTextFile` / `fs.writeTextFile` client capabilities.

### fs/read_text_file (Agent → Client)

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "fs/read_text_file",
  "params": {
    "sessionId": "sess_abc123def456",
    "path": "/home/user/project/src/main.py",
    "line": 10,
    "limit": 50
  }
}
```

Response:
```json
{ "jsonrpc": "2.0", "id": 3, "result": { "content": "def hello_world():\n    print('Hello!')\n" } }
```

Parameters: `sessionId` (required), `path` (required, absolute), `line` (optional, 1-based start), `limit` (optional, max lines)

### fs/write_text_file (Agent → Client)

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "fs/write_text_file",
  "params": {
    "sessionId": "sess_abc123def456",
    "path": "/home/user/project/config.json",
    "content": "{\n  \"debug\": true\n}"
  }
}
```

Response: `{ "jsonrpc": "2.0", "id": 4, "result": null }`

Client MUST create the file if it doesn't exist.

## Terminals

Requires `terminal` client capability. Allows Agents to execute shell commands in the Client's environment.

### terminal/create (Agent → Client)

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "terminal/create",
  "params": {
    "sessionId": "sess_abc123def456",
    "command": "npm",
    "args": ["test", "--coverage"],
    "env": [{ "name": "NODE_ENV", "value": "test" }],
    "cwd": "/home/user/project",
    "outputByteLimit": 1048576
  }
}
```

Response (immediate, doesn't wait for completion):
```json
{ "jsonrpc": "2.0", "id": 5, "result": { "terminalId": "term_xyz789" } }
```

Parameters: `sessionId` (required), `command` (required), `args` (optional), `env` (optional), `cwd` (optional, absolute), `outputByteLimit` (optional)

### terminal/output (Agent → Client)

Gets current output without waiting:
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "terminal/output",
  "params": { "sessionId": "sess_abc123def456", "terminalId": "term_xyz789" }
}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "output": "Running tests...\n✓ All tests passed\n",
    "truncated": false,
    "exitStatus": { "exitCode": 0, "signal": null }
  }
}
```

### terminal/wait_for_exit (Agent → Client)

Blocks until command completes:
```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "terminal/wait_for_exit",
  "params": { "sessionId": "sess_abc123def456", "terminalId": "term_xyz789" }
}
```

Response: `{ "jsonrpc": "2.0", "id": 7, "result": { "exitCode": 0, "signal": null } }`

### terminal/kill (Agent → Client)

Terminates command without releasing terminal:
```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "terminal/kill",
  "params": { "sessionId": "sess_abc123def456", "terminalId": "term_xyz789" }
}
```

Terminal remains valid for `output` and `wait_for_exit` after kill.

### terminal/release (Agent → Client)

Kills command (if running) and frees all resources. Terminal ID becomes invalid.
```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "terminal/release",
  "params": { "sessionId": "sess_abc123def456", "terminalId": "term_xyz789" }
}
```

Agent MUST release terminals when done. If embedded in a tool call, Client SHOULD continue displaying output after release.

## Agent Plan

Plans are execution strategies reported via `session/update`.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "plan",
      "entries": [
        { "content": "Analyze codebase structure", "priority": "high", "status": "pending" },
        { "content": "Identify refactoring targets", "priority": "high", "status": "in_progress" },
        { "content": "Create unit tests", "priority": "medium", "status": "completed" }
      ]
    }
  }
}
```

### Plan Entry Fields

- `content` (string, required) — human-readable task description
- `priority` (required) — `high`, `medium`, `low`
- `status` (required) — `pending`, `in_progress`, `completed`

### Updating Plans

Each update sends the COMPLETE list of entries. Client MUST replace the current plan entirely. Plans can evolve dynamically (entries added/removed/modified).

## Session Modes

> **Deprecated**: Use Session Config Options instead. Modes will be removed in a future version.

Agents provide modes they can operate in (e.g., ask, architect, code).

### Initial State (in session/new response)

```json
{
  "modes": {
    "currentModeId": "ask",
    "availableModes": [
      { "id": "ask", "name": "Ask", "description": "Request permission before changes" },
      { "id": "architect", "name": "Architect", "description": "Design without implementation" },
      { "id": "code", "name": "Code", "description": "Write and modify code" }
    ]
  }
}
```

### session/set_mode (Client → Agent)

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/set_mode",
  "params": {
    "sessionId": "sess_abc123def456",
    "modeId": "code"
  }
}
```

### current_mode_update (Agent → Client, Notification)

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "current_mode_update",
      "modeId": "code"
    }
  }
}
```

## Session Config Options

Preferred replacement for Session Modes. Flexible configuration selectors for agent sessions.

### Initial State (in session/new response)

```json
{
  "configOptions": [
    {
      "id": "mode",
      "name": "Session Mode",
      "description": "Controls how the agent requests permission",
      "category": "mode",
      "type": "select",
      "currentValue": "ask",
      "options": [
        { "value": "ask", "name": "Ask", "description": "Request permission before changes" },
        { "value": "code", "name": "Code", "description": "Full tool access" }
      ]
    },
    {
      "id": "model",
      "name": "Model",
      "category": "model",
      "type": "select",
      "currentValue": "model-1",
      "options": [
        { "value": "model-1", "name": "Model 1", "description": "Fastest" },
        { "value": "model-2", "name": "Model 2", "description": "Most powerful" }
      ]
    }
  ]
}
```

### ConfigOption Fields

- `id` (string, required) — unique identifier
- `name` (string, required) — human-readable label
- `description` (string, optional)
- `category` (string, optional) — semantic hint: `mode`, `model`, `thought_level`, or `_custom`
- `type` (string, required) — currently only `"select"`
- `currentValue` (string, required) — currently selected value
- `options` (ConfigOptionValue[], required) — available values

### Option Categories

| Category | Description |
|---|---|
| `mode` | Session mode selector |
| `model` | Model selector |
| `thought_level` | Reasoning level selector |
| `_*` | Custom categories (prefix with underscore) |

### session/set_config_option (Client → Agent)

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/set_config_option",
  "params": {
    "sessionId": "sess_abc123def456",
    "configId": "mode",
    "value": "code"
  }
}
```

Response returns COMPLETE config state (all options with current values). This allows dependent changes.

### config_option_update (Agent → Client, Notification)

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "config_option_update",
      "configOptions": [ ... ]
    }
  }
}
```

### Backwards Compatibility

During transition, agents SHOULD send both `configOptions` (with `category: "mode"`) and `modes`. Clients supporting config options SHOULD ignore `modes`.

## Slash Commands

Agents advertise commands users can invoke via `/command` syntax in prompts.

### Advertising Commands (Agent → Client, Notification)

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "available_commands_update",
      "availableCommands": [
        { "name": "web", "description": "Search the web", "input": { "hint": "query" } },
        { "name": "test", "description": "Run tests" },
        { "name": "plan", "description": "Create implementation plan", "input": { "hint": "description" } }
      ]
    }
  }
}
```

### AvailableCommand Fields

- `name` (string, required) — command name
- `description` (string, required) — what it does
- `input` (object, optional) — `{ hint: string }` for unstructured text input

### Running Commands

Commands are sent as regular prompts with `/` prefix:
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123def456",
    "prompt": [{ "type": "text", "text": "/web agent client protocol" }]
  }
}
```

Commands can be dynamically updated at any time during a session.

## Extensibility

### The `_meta` Field

All types include `_meta: { [key: string]: unknown }` for custom data. Available on requests, responses, notifications, and nested types.

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123def456",
    "prompt": [{ "type": "text", "text": "Hello" }],
    "_meta": {
      "traceparent": "00-80e1afed08e019fc1110464cfa66635c-7a085853722dc6d2-01",
      "zed.dev/debugMode": true
    }
  }
}
```

Reserved root-level `_meta` keys for W3C trace context: `traceparent`, `tracestate`, `baggage`.

**Rule**: MUST NOT add custom fields at root of spec-defined types. All names reserved for future versions.

### Extension Methods

Method names starting with `_` are reserved for custom extensions.

**Custom request:**
```json
{ "jsonrpc": "2.0", "id": 1, "method": "_zed.dev/workspace/buffers", "params": { "language": "rust" } }
```

If unrecognized, respond with: `{ "error": { "code": -32601, "message": "Method not found" } }`

**Custom notification:**
```json
{ "jsonrpc": "2.0", "method": "_zed.dev/file_opened", "params": { "path": "/home/user/editor.rs" } }
```

Unrecognized notifications SHOULD be ignored.

### Advertising Custom Capabilities

Use `_meta` in capability objects during initialization:

```json
{
  "agentCapabilities": {
    "loadSession": true,
    "_meta": {
      "zed.dev": { "workspace": true, "fileNotifications": true }
    }
  }
}
```

## Kiro Extensions

Kiro CLI extends ACP with `_kiro.dev/` prefixed methods. These are optional — clients that don't support them can safely ignore them.

### Slash Commands

| Method | Type | Description |
|---|---|---|
| `_kiro.dev/commands/execute` | Request | Execute a slash command |
| `_kiro.dev/commands/options` | Request | Get autocomplete suggestions for partial command |
| `_kiro.dev/commands/available` | Notification | Sent after session creation with available commands |

### MCP Server Events

| Method | Type | Description |
|---|---|---|
| `_kiro.dev/mcp/oauth_request` | Notification | OAuth URL when MCP server requires auth |
| `_kiro.dev/mcp/server_initialized` | Notification | MCP server finished initializing, tools available |

### Session Management

| Method | Type | Description |
|---|---|---|
| `_kiro.dev/compaction/status` | Notification | Progress when compacting conversation context |
| `_kiro.dev/clear/status` | Notification | Status when clearing session history |
| `_session/terminate` | Notification | Terminates a subagent session |

### Kiro Agent Capabilities

During initialization, Kiro advertises:
- `loadSession: true`
- `promptCapabilities.image: true`

### Kiro Session Updates

| Update Type | Description |
|---|---|
| `AgentMessageChunk` | Streaming text/content from the agent |
| `ToolCall` | Tool invocation with name, parameters, status |
| `ToolCallUpdate` | Progress updates for running tools |
| `TurnEnd` | Signals the agent turn has completed |

### Kiro ACP Usage

```bash
# Start as ACP agent
kiro-cli acp

# With specific agent config
kiro-cli acp --agent my-agent
```

### Editor Configuration

**JetBrains** (`~/.jetbrains/acp.json`):
```json
{
  "agent_servers": {
    "Kiro Agent": {
      "command": "/full/path/to/kiro-cli",
      "args": ["acp"]
    }
  }
}
```

**Zed** (`~/.config/zed/settings.json`):
```json
{
  "agent_servers": {
    "Kiro Agent": {
      "type": "custom",
      "command": "~/.local/bin/kiro-cli",
      "args": ["acp"],
      "env": {}
    }
  }
}
```

### Session Storage

Sessions persisted at: `~/.kiro/sessions/cli/`
- `<session-id>.json` — metadata and state
- `<session-id>.jsonl` — event log (conversation history)

### Logging

- macOS: `$TMPDIR/kiro-log/kiro-chat.log`
- Linux: `$XDG_RUNTIME_DIR/kiro-log/kiro-chat.log`
- Control: `KIRO_LOG_LEVEL=debug kiro-cli acp`

## Transport

### stdio (Required)

- Client launches Agent as subprocess
- Agent reads JSON-RPC from stdin, writes to stdout
- Messages delimited by newlines (`\n`), MUST NOT contain embedded newlines
- Messages MUST be UTF-8 encoded
- Agent MAY write to stderr for logging
- Agent MUST NOT write non-ACP content to stdout
- Client MUST NOT write non-ACP content to Agent's stdin

### Streamable HTTP (Draft)

In discussion, draft proposal in progress.

### Custom Transports

Implementations MAY use custom transports. Must preserve JSON-RPC message format and ACP lifecycle requirements. Should document connection establishment and message exchange patterns.

## Schema Reference

The full JSON Schema is available at: https://agentclientprotocol.com/api-reference/openapi.json

### Method Summary

| Method | Direction | Type | Description |
|---|---|---|---|
| `initialize` | Client → Agent | Request | Negotiate version and capabilities |
| `authenticate` | Client → Agent | Request | Authenticate with agent |
| `logout` | Client → Agent | Request | End authenticated state |
| `session/new` | Client → Agent | Request | Create new session |
| `session/load` | Client → Agent | Request | Load existing session (with replay) |
| `session/resume` | Client → Agent | Request | Resume session (no replay) |
| `session/list` | Client → Agent | Request | List available sessions |
| `session/close` | Client → Agent | Request | Close active session |
| `session/prompt` | Client → Agent | Request | Send user message |
| `session/cancel` | Client → Agent | Notification | Cancel ongoing turn |
| `session/set_mode` | Client → Agent | Request | Change agent mode |
| `session/set_config_option` | Client → Agent | Request | Change config option |
| `session/update` | Agent → Client | Notification | Stream updates |
| `session/request_permission` | Agent → Client | Request | Request tool permission |
| `fs/read_text_file` | Agent → Client | Request | Read file contents |
| `fs/write_text_file` | Agent → Client | Request | Write file contents |
| `terminal/create` | Agent → Client | Request | Create terminal |
| `terminal/output` | Agent → Client | Request | Get terminal output |
| `terminal/wait_for_exit` | Agent → Client | Request | Wait for command exit |
| `terminal/kill` | Agent → Client | Request | Kill terminal command |
| `terminal/release` | Agent → Client | Request | Release terminal resources |

### Known Agents

Kiro CLI, Claude Agent, Gemini CLI, Codex CLI, Augment Code, Cursor, GitHub Copilot, Goose, Junie (JetBrains), OpenCode, OpenHands, and many more.

### Known Clients

JetBrains IDEs, Zed, Neovim (CodeCompanion, avante.nvim), VS Code (ACP Client extension), Emacs (agent-shell.el), and many more.
