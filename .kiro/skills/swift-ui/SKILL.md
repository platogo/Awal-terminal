---
name: swift-ui
description: Swift/AppKit conventions for the app/ layer. Use when writing or modifying Swift code.
---

# Swift UI Conventions

## Architecture
- Pure AppKit (NSWindow, NSView, NSViewController) — no SwiftUI
- Metal rendering via `MetalRenderer` + `GlyphAtlas` for terminal content
- SwiftPM package with targets: `CAwalTerminal` (system library), `AwalTerminalLib`, `AwalTerminal` (executable)
- macOS 14+ minimum deployment target (`.macOS(.v14)` in Package.swift)

## Directory Layout (under `app/Sources/AwalTerminalLib/`)
- `App/` — application lifecycle, config, registries, stores, managers
- `Terminal/` — TerminalView and extensions (rendering, input, search, copy/paste, zoom)
- `Window/` — window controllers, panels, popovers, tab bar, status bar
- `Voice/` — voice input pipeline (capture, VAD, transcription, commands)
- `Splits/` — split pane container

## Rules
- TerminalView extensions MUST be in separate files named `TerminalView+Feature.swift`
- Window controllers MUST subclass NSWindowController; views MUST subclass NSView
- All FFI calls go through the `CAwalTerminal` module — import it where needed
- MUST NOT use force-unwraps (`!`) on FFI return values — check for nil/null
- New files MUST be placed in the correct subdirectory by concern
- Linked frameworks: AppKit, Metal, QuartzCore, AVFoundation, Speech (see Package.swift linkerSettings)

## Patterns
- Delegate pattern for view→controller communication
- NotificationCenter for cross-component events
- `AppConfig` singleton for reading `~/.config/awal/config.toml`
- Stores (ProfileStore, WorkspaceStore, WindowStateStore) persist to disk as JSON/plist

## Verification
- `just test-swift` MUST pass (requires Rust core built first via `just build-core-debug`)
- No SwiftUI imports — this is an AppKit app
