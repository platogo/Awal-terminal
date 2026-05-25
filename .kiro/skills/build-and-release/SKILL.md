---
name: build-and-release
description: Build system and release workflow. Use when building, bundling, or releasing Awal Terminal.
---

# Build & Release

## Build Commands (via justfile)
- `just run` — debug build + launch as .app bundle
- `just build` — release build (core + app)
- `just build-debug` — debug build (core + app)
- `just test` — run all tests (Rust + Swift)
- `just fmt` — format Rust code
- `just lint` — clippy lints (`cargo clippy -- -W warnings`)
- `just clean` — remove build artifacts
- `just header` — regenerate `core/include/awalterminal.h` via cbindgen
- `just bundle` — package release .app
- `just bundle-universal` — universal binary .app (arm64 + x86_64)
- `just coverage` — run tests with coverage reporting (requires `cargo-llvm-cov`)

## Build Order (dependency chain)
1. Rust core MUST build first (produces `libawalterminal.a` + regenerates `core/include/awalterminal.h`)
2. Swift app links against the static library

## Release Process
1. `just test` — MUST pass
2. Build universal: `cd app && swift build -c release --arch arm64 --arch x86_64`
3. Bundle: `scripts/bundle.sh universal`
4. Verify version: `plutil -p build/AwalTerminal.app/Contents/Info.plist | grep CFBundleShortVersionString`
5. Zip: `rm -f docs/AwalTerminal.zip && cd build && zip -r ../docs/AwalTerminal.zip AwalTerminal.app`
6. Commit zip, tag, push main + tag
7. `gh release create <tag> docs/AwalTerminal.zip --title "<tag>" --notes-file <changelog>`
8. Update Homebrew cask: version + sha256 in `homebrew-cask/awal-terminal.rb`

## CI (GitHub Actions, macos-14)
- `ci.yml` — Rust tests, clippy, fmt check; Swift tests
- `test.yml` — Rust tests + Swift tests + universal release build verification
- Both trigger on push/PR to main
- Note: `ci.yml` and `test.yml` have overlapping jobs; both run the full Rust + Swift test suite.

## Known Issues
- **SPM does not detect `.a` changes:** Swift Package Manager won't relink when only `libawalterminal.a` changes. The justfile deletes the Swift binary before `swift build` to force relinking (~1.7s). Without this, Rust code changes silently produce a stale binary.

## Red Flags
- Building Swift without building Rust first → linker errors
- Stale header after adding FFI functions → Swift compilation errors
- Forgetting `--arch arm64 --arch x86_64` for release → single-arch binary
