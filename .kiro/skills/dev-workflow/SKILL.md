---
name: dev-workflow
description: Development workflow for Awal Terminal. Use when creating branches, opening PRs, or running CI.
---

# Development Workflow

## Branch Naming

Branches MUST follow: `<type>/<short-description>`

Allowed types: `feat`, `fix`, `chore`, `docs`, `refactor`, `release`

Examples: `feat/hook-sandboxing`, `fix/toctou-race`, `docs/update-readme`

## Local Dev Loop

1. Create branch: `git checkout -b feat/my-feature`
2. Make changes
3. Verify Rust: `just test-rust` (always works locally)
4. Verify Swift build: `just build-app-debug` (build works without Xcode, tests need Xcode)
5. Format: `just fmt`
6. Commit (hooks auto-check format + lint + branch name)
7. Push: `git push -u origin <branch>`
8. Open PR: `gh pr create`

## CI Checks (GitHub Actions)

Two workflows run on every PR to `main`:

| Workflow | Jobs |
|----------|------|
| `ci.yml` | Rust tests, clippy, fmt check, Swift tests |
| `test.yml` | Rust tests, clippy, fmt check, Swift tests, universal release build |

All checks must pass before merge. CI runs on `macos-14` runners with Xcode pre-installed.

## Swift Tests Locally

Swift tests (`just test-swift`) require full Xcode.app installed. If unavailable, rely on CI. Rust tests always work with just the Rust toolchain.

## PR Conventions

- Target branch: `main`
- Title: concise, under 70 chars, imperative mood
- Description: summary of changes + what was tested
- Link related issues with `Closes #N`

## Commit Message Format

- First line: `<type>: <description>` (max 72 chars)
- Types: feat, fix, chore, docs, refactor, test, style, ci, perf
- Do not reference AI tools in commit messages (no AI, Claude, LLM, GPT, Co-Authored-By)

## Git Hooks (auto-installed via `.githooks/`)

| Hook | Checks |
|------|--------|
| pre-commit | `cargo fmt --check`, `cargo clippy -- -D warnings` |
| commit-msg | Message format, no AI mentions, conventional prefix |
| pre-push | Branch name matches allowed patterns |

Install hooks once after cloning: `bash .githooks/install.sh`
