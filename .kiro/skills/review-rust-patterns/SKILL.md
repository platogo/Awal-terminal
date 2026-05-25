---
name: review-rust-patterns
description: Rust review patterns — FFI safety, platform APIs, memory, API stability. Use when reviewing Rust code.
---

# Review Rust Patterns

## FFI Safety
- Pointer dereference MUST happen after null check — never before
- `extern "C"` declarations for libc functions: verify the symbol exists on the target platform (macOS vs Linux)
- No `panic!` in FFI-exported functions — use error returns
- Shared references (`&T`) must not be created before exclusive references (`&mut T`) to the same data
- `unsafe` blocks outside the designated FFI module are a red flag

## Platform Availability
- `closefrom` — BSD/Solaris only, NOT on macOS
- `close_range` — Linux 5.9+ only
- `pidfd_open` — Linux 5.3+ only
- `memfd_create` — Linux 3.17+ only
- When in doubt: check if the function is in the `libc` crate for the target, or verify with `man` pages
- Prefer `#[cfg(target_os = "...")]` with fallback for platform-specific code

## Memory & Bounds
- Unbounded `Vec` or `HashMap` growth without a cap — flag if fed by external input
- URL/string storage: cap length to prevent single-entry memory abuse
- Eviction strategy: "stop inserting" is wrong; evict oldest entries to keep recent data useful
- Allocation in hot paths (called per-frame or per-keystroke) — suggest pre-allocation

## API Stability
- Public function signature changes are breaking — keep old signature as wrapper
- Adding required parameters to `pub fn` — use a builder, options struct, or default parameter via new method
- Removing or renaming `pub` items — flag as breaking change

## Concurrency
- `AtomicOrdering`: prefer `Relaxed` for counters/flags, `Acquire/Release` for synchronization
- Global statics with `AtomicU64::new(0)` + lazy init: verify the init race is benign (first-writer-wins is fine for thread ID)
- `std::thread::current().id().as_u64()` requires nightly — use `libc::pthread_self()` on stable

## Testing
- New behavior MUST have a test — flag if missing
- Changed public API MUST update or add tests
- Tests that manipulate internal state directly are acceptable for unit tests

## Red Flags
- `unsafe` with no safety comment explaining the invariant
- `unwrap()` / `expect()` in library code (not tests)
- `.ok()?` on `serde_json::from_value()` silently swallows type mismatches — log the error or use `map_err` to surface it. A single wrong field type (e.g., integer vs string) can silently break an entire code path.
- `String::from_utf8_unchecked` without prior validation
- `std::mem::transmute` without exhaustive justification
- Blocking I/O on async runtime threads
