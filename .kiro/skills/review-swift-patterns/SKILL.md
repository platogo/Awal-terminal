---
name: review-swift-patterns
description: Swift/AppKit review patterns — security, platform APIs, UI, error handling. Use when reviewing Swift code.
---

# Review Swift Patterns

## Filesystem Security
- `attributesOfItem` followed by separate read/write — TOCTOU race. Use `FileHandle` with byte limit.
- Predictable filenames (timestamps) in shared directories — use `UUID().uuidString`
- File creation without `O_CREAT | O_EXCL` in paths where symlink attacks are possible
- `String(contentsOf:)` without size check — local DoS via large files
- Symlinks: `attributesOfItem` returns link attributes, but `String(contentsOf:)` follows the target

## Process Execution
- String interpolation in `sandbox-exec` profiles — injection risk. Validate/reject: `"`, `(`, `)`, `\`, control chars
- Missing `"--"` before user-controlled paths in process arguments
- `Pipe()` + `waitUntilExit()` without reading the pipe — deadlock if buffer fills (~64KB)
- Timeout via semaphore is complex; prefer `DispatchQueue.asyncAfter` + `process.isRunning` check
- GUI apps have minimal environment — always set `proc.environment` with augmented PATH when spawning child processes. Use `ProcessInfo.processInfo.environment` as base and prepend the binary's directory.
- `dup()` pipe fds before passing to Rust FFI — prevents double-close when both Swift Pipe and Rust File own the same fd.
- `DispatchSource.makeReadSource` on pipe fds requires `O_NONBLOCK` — set via `fcntl(fd, F_SETFL, flags | O_NONBLOCK)`.
- Never `dup()` + `read()` a pipe fd that another reader (DispatchSource) is consuming — both share the same pipe buffer, reads from one drain data for the other.

## Concurrency & Locking
- `NSLock` is exclusive (mutex) — NOT a reader-writer lock
- Serial queue for file R/M/W is correct; don't over-serialize
- `[weak self]` in async closures that outlive the object — verify self is checked before use

## Error Handling
- `completion?(false, nil)` — callers may treat nil error as success. Return a typed error.
- `compactMap { try? ... }` silently drops failures — log errors in security-relevant paths
- Fallback-to-dangerous on error (e.g., paste raw content when file creation fails) — retry or fail safely
- `guard let window = ... else { return }` without user feedback — show alert or use fallback

## UI (AppKit)
- Labels with dynamic content: verify `lineBreakMode = .byWordWrapping` + `maximumNumberOfLines = 0`
- Add leading/trailing constraints (not just centerX) for wrapping labels
- Case-insensitive comparison for hostnames, URLs, file extensions (`.lowercased()`)
- `UserDefaults` keys: use static constants, not string literals

## API Design
- URL validation: use `URL(string:)` + check `host`/`scheme`/`path` — not string prefix matching
- Completion handlers: always distinguish success from failure (don't overload nil)

## Testing
- New user-facing behavior needs test coverage
- Config/defaults changes need a test verifying the new behavior
- Tests that read real user files (`~/.config/...`) are flaky — use temp directories

## Red Flags
- Force-unwrap (`!`) on FFI return values or optional chains
- `DispatchQueue.main.sync` from the main thread (deadlock)
- `NSWorkspace.shared.open(url)` without validating the URL first
- `Timer.scheduledTimer` without invalidation path (leak)
