# Project agent memory

## Architecture

PromptMeet is a meeting-assistant platform with two major modes:

**Web mode** (Vue 3 frontend + FastAPI backend + MySQL):
- Real-time transcription via OpenAI Whisper
- AI summarization via DeepSeek
- Screenshot OCR via Alibaba Cloud
- Notion/Feishu sync, email delivery

**macOS native mode** (SwiftUI/AppKit + FastAPI companion):
- ScreenCaptureKit + AVAudioEngine for system audio and mic capture
- Local `whisper.cpp` transcription (no audio upload)
- macOS Keychain for provider secrets (never serialized)
- Version 2 typed meeting timeline in JSON files
- Durable meeting records survive app restart for historical Q&A
- Fixed dark visual system only (no light appearance)

### Backend layers

| Layer | Location | Role |
| --- | --- | --- |
| API routes | `backend/api/` | HTTP and WebSocket endpoints |
| Services | `backend/services/` | Business logic, agents, persistence |
| Models | `backend/models/` | Pydantic data types |
| Processors | `backend/processors/` | MySQL, image, Whisper |

Desktop-mode services (`desktop_agent_service`, `desktop_storage`, `meeting_repository`, `context_builder`, `model_provider`, `prompt_builder`) activate when `PROMPTMEET_DESKTOP_MODE=1`.

### Swift layers

| Layer | Location | Role |
| --- | --- | --- |
| Domain | `Domain/` | `MeetingTimeline`, `MeetingState`, `CaptureState`, `BackendEvent`, `StoredMeeting` |
| Services | `Services/` | `MeetingStore`, `BackendClient`, `CompanionLauncher`, `KeychainStore`, `AIProviderConfiguration` |
| Views | `Views/` | `WorkspaceView`, `AIReaderView`, `HoverMeetingCardView`, `SettingsView`, `IslandRootView` |
| Capture | `Capture/` | ScreenCaptureKit, microphone, system audio, screenshot upload |
| Transcription | `Transcription/` | `whisper.cpp` CLI and server engines, model repository |
| Windows | `Windows/` | Island, workspace, settings, reader controllers |

## Build, test, and validate

### Python companion

```bash
cd backend
../build/desktop-python/bin/python3 -m pytest -q
```

### Swift native app

```bash
cd desktop-macos
swift test
swift build -c release
```

### macOS app bundle

```bash
./scripts/build-whisper-runtime.sh
./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
```

Skip Whisper rebuild on a cached runtime: `PROMPTMEET_SKIP_WHISPER_BUILD=1 ./scripts/build-macos-app.sh`.

### UI preview (no capture permissions needed)

```bash
cd desktop-macos
PROMPTMEET_UI_PREVIEW=workspace swift run PromptMeet
```

## Core invariants

- API keys live only in macOS Keychain (`com.promptmeet.desktop`) and process environment. Never in logs, responses, serialized state, or WebSocket payloads.
- Version 2 meeting records use atomic sibling-file writes. Malformed records are kept as `recovery_required`; legacy `desktop-sessions.json` is migrated on read, never deleted.
- Context assembly is per-question with a budget (default 8k tokens, 2k reserved for answer). Prompts use separate system, developer, and user roles.
- DeepSeek models are text-only. When selected context contains screenshot pixels, the prompt and answer metadata disclose the degradation truthfully.
- Each question gets its own request ID, immutable snapshot, and streaming state. Rapid concurrent questions finish independently without overwriting.
- `开始新会议` requires explicit confirmation when a meeting is active. Backend meeting creation precedes capture startup.
- Microphone and system audio remain independent source-tagged streams with meeting-relative timing. Permission or runtime failure in one source must not stop or relabel the other.
- Recording pause keeps the meeting active and its context available. Resume is transactional across the companion and native capture, and stop works while paused.
- Window selection only retains a screenshot target. Screenshot capture never opens the picker and repeated captures reuse the current valid target.
- Suggested-question generations are meeting-scoped, revisioned, cancellable, and durable. A stale generation must never overwrite newer or historical suggestions.

## Authoritative documentation

- [`docs/macos-meeting-agent.md`](docs/macos-meeting-agent.md) -- version 2 schema, context budget, screenshot flow, historical Q&A, migration, walkthrough limits
- [`README.md`](README.md) -- user-facing overview, quickstart, env config
- [`backend/models/meeting_context.py`](backend/models/meeting_context.py) -- canonical event and record types

## Maintaining this file

This file is authoritative project memory for agent sessions. Update it when:
- A new top-level service, model, or domain type is added or removed.
- A build, test, or validation command changes.
- A core invariant is added, removed, or materially altered.

Prefer short pointers to owner documents (`docs/`, module-level docstrings) over duplicating details here. When removing a fact, verify no stale reference remains in other documentation files.
