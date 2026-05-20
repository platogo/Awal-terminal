---
name: ffi-bridge
description: FFI bridge patterns between Rust core and Swift UI. Use when adding or modifying cross-boundary APIs.
---

# FFI Bridge Patterns

## How It Works
1. Rust exports `#[no_mangle] pub extern "C" fn` in `core/src/ffi.rs`
2. `cargo build` triggers `build.rs` → cbindgen generates `core/include/awalterminal.h`
3. Swift imports via `CAwalTerminal` systemLibrary (module.modulemap points to the header)
4. Swift links `libawalterminal.a` (debug or universal-release, see Package.swift linkerSettings)

## Adding a New FFI Function

### Rust side (`core/src/ffi.rs`)
- MUST use `#[no_mangle] pub extern "C" fn at_surface_*` naming
- MUST use `check_ffi_thread!` macro at entry (debug builds verify single-thread access)
- MUST use `ref_or!` / `mut_ref_or!` macros for pointer parameters
- Strings: accept `*const c_char`, return `*mut c_char` (caller frees with `at_string_free`)
- Arrays: return via out-pointer + length parameter pattern
- Opaque types: return `*mut T`, caller passes back; freed by dedicated `_destroy` function

### Swift side
- Call functions directly from `CAwalTerminal` module (no wrapper needed for simple calls)
- MUST free returned strings with `at_string_free()`
- MUST free returned opaque pointers with their `_destroy` function
- MUST NOT hold FFI pointers across threads unless documented as thread-safe

## Thread Safety
- All `at_surface_*` calls for a given surface MUST happen on the same thread
- Debug builds enforce this via `thread_check` module in `ffi.rs` (asserts on violation)
- The main thread owns all surfaces (driven by display link / timer)

## Verification
- After adding FFI functions: `just build-core-debug` to regenerate header
- Verify the function appears in `core/include/awalterminal.h`
- `just test` MUST pass (both Rust and Swift)
