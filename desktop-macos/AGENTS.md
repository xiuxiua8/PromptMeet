# Project agent memory

The authoritative project memory for PromptMeet lives at the repository root:
`../AGENTS.md` (also symlinked as `../CLAUDE.md`). It covers the macOS app's
architecture, build/test/validate commands, and core invariants.

## Desktop-specific quick reference

- SwiftPM package: `swift build`, `swift test`, `swift build -c release`.
- Lint: `swiftlint lint` (config in `.swiftlint.yml`). The generated
  `SimplifiedChineseMapping.swift` data table is exempt from length rules.
- Live engine regression (skipped unless enabled): see the
  `PROMPTMEET_LIVE_WHISPER_TESTS` section in `../AGENTS.md`.
- UI preview without capture permissions:
  `PROMPTMEET_UI_PREVIEW=workspace swift run PromptMeet`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
