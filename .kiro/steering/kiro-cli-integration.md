# Kiro CLI Integration

## Dual-Mode Architecture
1. **ACP Mode (preferred)** — spawns `kiro-cli acp` as subprocess, communicates via JSON-RPC 2.0 over stdin/stdout (newline-delimited). No PTY involved.
2. **PTY Mode (fallback)** — runs `kiro-cli chat` in a standard PTY. Used when ACP spawn fails or auth is required.

Routing: `ModelCatalog` sets `prefersACP: true` for Kiro → `TerminalView+Menu.swift` routes to `onACPLaunchRequested` → `TerminalWindowController.startACPSession()`. Fallback: `fallbackToPTY()` launches PTY mode.

## Protocol (ACP)
- JSON-RPC 2.0, one JSON object per line, protocol version `"2025-01-01"`
- Spawn: `kiro-cli acp [--agent NAME] [--model MODEL] [--agent-engine v1|v2|kas] [--trust-all-tools | --trust-tools LIST] [--token-path PATH]`
- Lifecycle: `initialize` → `session/new` (or `session/resume`) → `session/prompt` (repeating) → `session/cancel`
- Additional methods: `session/cancelSubagent`, `session/rewind`
- Streaming: `session/update` notifications with variants: `agent_message_chunk`, `tool_call`, `tool_call_update`, `turn_end`, `subagent_spawned`, `subagent_progress`, `subagent_complete`, `subagent_error`
- Server→Client requests: `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`
- Turn result: `{"stopReason": "end_turn", "credits": f64}` — wire field is `credits`, Rust aliases to `creditsUsed`
- Auth errors: codes -32001/-32002, also detected by keyword heuristics (`auth`, `unauthorized`, `login`, `credentials`)
- `session/new` params: `{"cwd": "...", "mcpServers": []}` (mcpServers reserved, currently empty)

## State Machine
```
Initializing → Ready ↔ Prompting
                ↓           ↓
            Dead ←── Recovering
```
Auth errors go directly to `Dead` → PTY fallback.

## Authentication

Three auth methods exist for kiro-cli:

| Method | Token Location | Notes |
|--------|---------------|-------|
| IAM Identity Center (IdC/SSO) | `~/.aws/sso/cache/kiro-auth-token-cli.json` | Created by `kiro-cli login`. File-based — can be passed via `--token-path` |
| Builder ID / Social login | Internal database (not a file) | Checked via `chat_cli::auth::social` / `chat_cli_v2::auth::social` |
| API Key (headless) | Environment variable or config | No file path needed |

**Critical**: GUI apps MUST pass `--token-path` explicitly for IdC/SSO users. The CLI normally resolves this from the shell environment, but macOS GUI apps don't inherit that context.

Resolution logic in `AppConfig.resolvedKiroTokenPath`:
1. If `kiro.token_path` is set in config.toml, use that
2. Otherwise, check if `~/.aws/sso/cache/kiro-auth-token-cli.json` exists and use it
3. If neither, pass nil (let kiro-cli try its own resolution)

## ACP Spawn Environment

macOS GUI apps (launched via Finder, Dock, or Spotlight) do NOT inherit:
- Shell PATH — `binary_path` MUST be an absolute path or the "Locate kiro-cli…" file picker triggers
- Shell environment variables — token discovery that relies on env vars will fail
- Working directory — explicitly passed as `cwd` parameter

This means:
- `--token-path` must be passed explicitly (kiro-cli can't find it via env-based discovery)
- The binary path must be absolute (e.g. `/Users/YOU/.local/bin/kiro-cli`)
- HOME is available (inherited from launchd), so `~/.aws/...` paths resolve correctly via `FileManager`

## Layer Map

| Layer | Location | Responsibility |
|-------|----------|----------------|
| Rust protocol | `core/src/acp/protocol.rs` | All JSON-RPC types (serde) — this IS the spec |
| Rust client | `core/src/acp/client.rs` | State machine, spawn, crash recovery |
| Rust reader | `core/src/acp/reader.rs` | Background stdout parsing → `AcpEvent` |
| Rust diff | `core/src/acp/diff.rs` | Unified diff parser for hunk accept/reject |
| FFI | `core/src/ffi.rs` | 19 `at_acp_*` functions |
| Swift wrapper | `app/Sources/AwalTerminalLib/App/ACPClient.swift` | Polling (16ms timer, 100 events/tick), callbacks |
| Controller | `app/Sources/AwalTerminalLib/Window/TerminalWindowController.swift` | Session lifecycle, UI wiring, fallback |
| Session persistence | `app/Sources/AwalTerminalLib/App/SessionManager.swift` | Save/resume metadata |
| Agent discovery | `app/Sources/AwalTerminalLib/App/AgentStore.swift` | Scans `~/.kiro/agents/*.json` |
| Subagent tracking | `app/Sources/AwalTerminalLib/App/SubagentState.swift` | DAG for Mission Control |
| File changes | `app/Sources/AwalTerminalLib/App/AgentChangesTracker.swift` | File change tree |
| Cost tracking | `app/Sources/AwalTerminalLib/App/TokenTracker.swift` | Credits → USD display |
| Tool call UI | `app/Sources/AwalTerminalLib/Window/ToolCallCardView.swift` | Structured cards |
| Permission UI | `app/Sources/AwalTerminalLib/Window/PermissionApprovalView.swift` | Approve/deny dialog |
| Diff review UI | `app/Sources/AwalTerminalLib/Window/DiffReviewController.swift` | Hunk-level accept/reject |

## FFI Event Codes
0=Initialized, 1=SessionCreated, 2=TextChunk, 3=ToolCall, 4=ToolCallUpdate, 5=TurnEnd, 6=Error, 7=ProcessExited, 8=PermissionRequest, 9=Cancelled, 10=AuthRequired, 11=FsReadRequest, 12=FsWriteRequest, 13=SubagentSpawned, 14=SubagentProgress, 15=SubagentComplete, 16=SubagentError, 17=Stderr, 18=ProtocolLog

## Configuration
`~/.config/awal/config.toml` `[kiro]` section: `binary_path`, `default_agent`, `agent_engine`, `trust` (all|safe|none), `trusted_tools`, `permission_timeout`, `credit_cost_usd`, `token_path`.

## Known Gotchas
- macOS GUI apps do NOT inherit shell PATH — `binary_path` MUST be absolute or the "Locate kiro-cli…" file picker triggers
- ACP sessions have no PTY CWD — MUST use `acpProjectPath` for tab titles and working directory display
- Credits ≠ tokens — `TokenTracker` MUST special-case Kiro (no input/output token split)
- Wire field is `credits` but Rust deserializes as `creditsUsed` (serde alias) — don't confuse the two
- `fallbackToPTY()` MUST NOT re-trigger ACP routing (causes infinite recursion — see PR #68)
- `ATAcpEvent.text2` is tab-separated metadata — parsing MUST validate split count before indexing
- Process is placed in own process group (`setpgid(0,0)`) — termination uses `killpg(SIGTERM)`
- No standalone protocol spec exists — `core/src/acp/protocol.rs` IS the source of truth
- `--token-path` is required for IdC/SSO users when spawning from a GUI app

## Verification
- `just test-rust` — ACP protocol serialization and reader unit tests
- `just test-swift` — TokenTracker, SessionManager tests
- Manual: spawn ACP session → verify tool calls render → test crash recovery (kill kiro-cli process) → verify auto-resume
- Manual: test auth failure → verify PTY fallback launches without recursion
- Manual: verify IdC/SSO auth works by checking `--token-path` is passed in process args
