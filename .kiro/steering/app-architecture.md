# App Architecture

## Build Pipeline

- Rust core (`core/`) is a static library (`staticlib` + `lib`)
- `core/build.rs` uses cbindgen to generate `core/include/awalterminal.h`
- Swift app (`app/`) is an SPM package
- `CAwalTerminal` system library target imports the header via `module.modulemap`
- `AwalTerminalLib` links via unsafe linker flags (`-L ../core/target/... -lawalterminal`)
- `justfile` orchestrates: `build-core` → `build-app` → `scripts/bundle.sh`
- **Critical**: SwiftPM doesn't detect `.a` changes — must delete the Swift binary to force relink
- Universal build uses `lipo` to combine arm64 + x86_64 static libs

## Threading Model

- All FFI calls happen on the **main thread**
- `check_ffi_thread!()` macro in `core/src/ffi.rs` enforces single-thread access for ATSurface operations
- ACP FFI functions (`at_acp_*`) don't use `check_ffi_thread` — they're thread-safe via internal mpsc channel
- PTY reads: `DispatchSource.makeReadSource(fd, queue: .main)` → `at_surface_process_pty()`
- ACP reads: `DispatchSource.makeReadSource(fd, queue: .main)` → `at_acp_feed_line()`
- ACP polling: `DispatchSourceTimer(.main, 16ms)` → `at_acp_poll_event()`
- Process exit: `Process.terminationHandler` dispatches to `.main`

## Process Spawning

- PTY sessions: Rust `fork()+execvp()` via shell (`/bin/zsh -c "cd /path && command"`)
- ACP sessions: Swift `Process` (posix_spawn) — required because `fork()` is unsafe in multithreaded GUI apps
- GUI apps have minimal environment — must set `proc.environment` with augmented PATH
- Pipe fds must be set to `O_NONBLOCK` for DispatchSource to work
- Use `dup()` when passing pipe fds to Rust to avoid double-close with Swift Pipe

## Data Flow

```
PTY Mode:
  Rust fork+exec → PTY master fd (non-blocking)
  DispatchSource.readSource(.main) → at_surface_process_pty() → VT100 parse → Metal render

ACP Mode:
  Swift Process (posix_spawn) → stdout pipe fd (non-blocking)
  DispatchSource.readSource(.main) → buffer lines → at_acp_feed_line() → JSON-RPC parse → mpsc channel
  DispatchSourceTimer(.main, 16ms) → at_acp_poll_event() → Swift callbacks → UI update
```

## Key Directories

- `core/` — Rust static library (terminal emulator, ACP client, FFI)
- `core/src/acp/` — ACP protocol: client.rs (state machine + writes), reader.rs (parser), protocol.rs (types)
- `core/src/ffi.rs` — All C FFI exports
- `core/src/io/pty.rs` — PTY spawn and management
- `core/src/terminal/` — VT100 parser, screen buffer, scrollback
- `app/` — Swift SPM package (AppKit GUI)
- `app/Sources/AwalTerminalLib/App/` — App-level: ACPClient, ModelCatalog, AppConfig, TokenTracker
- `app/Sources/AwalTerminalLib/Terminal/` — TerminalView (Metal rendering, input, PTY)
- `app/Sources/AwalTerminalLib/Window/` — Window controller, status bar, side panel, tab management
- `scripts/` — bundle.sh, release scripts
- `.kiro/` — Skills, steering files, hooks

## Gotchas

- `protocolVersion` in ACP initialize response is an integer, not a string
- `kiro-cli` wrapper doesn't forward stdout properly for ACP — spawn `kiro-cli-chat` directly
- Token path for GUI apps: `~/.aws/sso/cache/kiro-auth-token-cli.json` (must pass `--token-path` explicitly)
- DispatchSource on a dup'd fd shares the same pipe — reading from one drains data for both
