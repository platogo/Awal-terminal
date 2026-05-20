---
name: ai-analyzer-architecture
description: Architecture of the AI output analyzer and component system. Use when modifying AI detection, folding, side panel, or component injection.
---

# AI Analyzer & Components Architecture

## Two-Layer Design
1. **Rust layer** (`core/src/terminal/ai_analyzer.rs`) — real-time pattern detection on terminal cell rows
2. **Swift layer** (`app/Sources/AwalTerminalLib/App/`) — component registry, injection, UI

## Rust: AiAnalyzer
- Lives inside `ATSurface` (field: `analyzer: AiAnalyzer`), processes screen + scrollback rows
- Detects `RegionType` variants: Normal, ToolUse, ToolOutput, CodeBlock, Thinking, Prompt, CostSummary, Diff, Separator
- Produces `OutputRegion` structs (start_row, end_row, type, collapsed, label, line_count)
- Exposed to Swift via FFI functions in `ffi.rs`
- Tool names list (`DEFAULT_TOOL_NAMES`) matches Claude Code's tool vocabulary

## Swift: AI Components System
Key files in `app/Sources/AwalTerminalLib/App/`:
- `AIComponentRegistry.swift` — central registry of all components (skills, rules, prompts, agents, MCP servers, hooks)
- `AIComponentInjector.swift` — injects matched components into AI sessions
- `ProjectDetector.swift` — detects project stack (language, framework, sub-stacks)
- `RegistryManager.swift` — syncs remote registries (git, localskills, local directory)
- `RegistryMappingResolver.swift` — maps non-standard registry structures via visual editor
- `ComponentSecurityScanner.swift` — scans components for security issues
- `HookApprovalStore.swift` — gate for hook execution with audit trail

## Swift: AI Side Panel
- `app/Sources/AwalTerminalLib/Window/AISidePanelView.swift` — displays token usage, costs, context window, file refs, git changes
- `app/Sources/AwalTerminalLib/App/TokenTracker.swift` — per-tab token/cost tracking
- Reads region data from Rust via FFI to render foldable sections

## Adding a New Region Type
1. Add variant to `RegionType` enum in `ai_analyzer.rs` (with `#[repr(u8)]`)
2. Add detection logic in `AiAnalyzer` methods
3. Expose any new FFI accessors in `ffi.rs`
4. Handle the new type in Swift side panel / folding UI

## Verification
- New region types MUST have unit tests in `ai_analyzer.rs`
- Component changes MUST pass `just test-swift`
