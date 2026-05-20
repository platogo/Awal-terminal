---
name: commit-conventions
description: Commit message and PR conventions for Awal Terminal. Use when committing or creating PRs.
---

# Commit Conventions

## Rules
- MUST use imperative mood ("Add feature" not "Added feature")
- MUST NOT mention AI, Claude, or LLM in commit messages
- MUST NOT include `Co-Authored-By` trailer
- MUST run `just fmt` before committing Rust code
- SHOULD focus on **why**, not just what

## Pre-Commit Checklist
1. `just fmt` — format Rust code
2. `just test` — all tests pass
3. `just lint` — zero clippy warnings

## Documentation Updates
When a commit adds/removes/modifies user-facing features, MUST also update:
- `README.md` — Features table, keybindings, config example
- `docs/documentation.html` — website documentation
- `docs/index.html` — landing page feature cards (if major feature; keep card count as multiple of 3)

Do NOT update docs for internal refactors or bug fixes.

## Branch Workflow
- Fork and branch from `main`
- Open PR against `main`
- PR title: concise, under 70 characters
