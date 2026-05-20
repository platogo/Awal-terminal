---
name: rust-core
description: Rust conventions for the core/ crate. Use when writing or modifying Rust code in core/.
---

# Rust Core Conventions

## Module Structure
- `core/src/lib.rs` — crate root, declares `pub mod ffi`, `pub mod io`, `pub mod terminal`
- `core/src/terminal/` — terminal emulation (screen, parser, cell, modes, ai_analyzer, recorder)
- `core/src/io/` — PTY management and write queue
- `core/src/ffi.rs` — all FFI exports (single file, never split)

## Rules
- All public types exposed to Swift MUST be defined in `ffi.rs` or re-exported there
- Enums exposed via FFI MUST use `#[repr(u8)]` or `#[repr(C)]`
- MUST run `cargo fmt` before committing (CI enforces `cargo fmt -- --check`)
- MUST pass `cargo clippy -- -W warnings` with zero warnings
- New modules MUST be declared in the parent `mod.rs`
- Dependencies MUST use major.minor version specs without patch (match existing style: `vte = "0.15"`, `libc = "0.2"`)
- Unsafe code MUST be confined to `ffi.rs` — internal modules use safe Rust
- Tests live in `#[cfg(test)] mod tests` at the bottom of each file
- The `ATSurface` struct is the opaque handle — all terminal state lives inside it

## Naming
- FFI functions: `at_surface_*` prefix (e.g., `at_surface_new`, `at_surface_destroy`)
- Internal types: standard Rust naming (PascalCase types, snake_case functions)
- C-exported enums: variants use ScreamingSnakeCase (cbindgen config in `core/cbindgen.toml`)

## Error Handling
- FFI functions MUST NOT panic — use `ref_or!` / `mut_ref_or!` macros for null checks
- Return `-1` or null for errors from FFI functions
- Internal code SHOULD use `Result<T, E>` — convert to C-friendly values at the FFI boundary

## Verification
- `just test-rust` MUST pass
- `just lint` MUST show zero warnings
- `just fmt` MUST produce no diff
