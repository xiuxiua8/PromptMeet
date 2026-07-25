# macOS meeting agent

This document describes the durable macOS meeting-agent architecture, its reproduced baseline failure, and the commands used to validate it.

## User journey and reproduced baseline

The expected journey is:

1. Launch the native app and its local companion.
2. Start a meeting and receive transcript content.
3. Capture a window or display screenshot.
4. Ask a meeting-scoped question and receive a streamed answer with evidence sources.
5. End the meeting and quit the app.
6. Relaunch, open the retained meeting, and ask a follow-up whose answer is appended to that meeting.

The pre-change native path showed a live capture state before it had created a backend meeting. The observed evidence was:

| Category | Expected | Observed before the fix |
| --- | --- | --- |
| Initiating trigger | `开始新会议` creates durable context, then starts capture | Capture startup ran before backend meeting creation |
| Masking condition | UI state reflects both capture and meeting readiness | Local capture made the app appear live while the backend stayed disconnected |
| Visible symptom | Screenshot, summary, and question actions become available | Those actions remained disabled because there was no backend meeting ID |
| Server check | App-created meeting appears in backend health and history | Backend was healthy but reported no app-created active meeting |
| Disconfirming evidence | A server failure would reject direct creation too | Direct session creation succeeded, ruling out general backend startup failure |

The smallest causal counterfactual was to create and connect the durable backend meeting before audio capture. Capture failure now marks that record incomplete rather than losing the attempted meeting. A failed backend connection still permits local transcription, but the UI explicitly reports that AI-backed meeting actions are unavailable.

## Durable version 2 record

The Python companion is the owner of durable meeting data. The canonical types are in `backend/models/meeting_context.py`, and persistence is implemented by `backend/services/meeting_repository.py`.

Records are stored under:

```text
~/Library/Application Support/PromptMeet/
├── meetings/v2/<meeting-id>.json
└── assets/<meeting-id>/<asset-id>.<extension>
```

Each record has `schema_version: 2`, a meeting ID, lifecycle status, start and end times, optional title, and one chronological event array. Sequence numbers are assigned atomically per meeting. Event payloads are typed as:

- `lifecycle`
- `transcript`
- `screenshot`
- `screenshot_analysis`
- `user_question`
- `assistant_answer`
- `summary`

Every event includes provenance. Provider-backed events may also include provider, model, and request ID metadata. Answer events contain stable evidence references such as `M12`, vision-degradation state, and an inline failure state when generation fails.

Writes use a temporary sibling file followed by atomic replacement. A malformed version 2 file remains on disk and appears as a `recovery_required` item instead of being silently deleted. Missing screenshot bytes produce an unavailable preview and a 404 asset response while the timeline event and any analysis remain visible.

### Legacy migration

When `desktop-sessions.json` exists, the repository migrates each legacy entry on demand into a version 2 record. Existing version 2 files win, and the legacy source file is never removed or modified. Legacy transcript and summary data are retained with migration provenance. Records without an end time or summary become `incomplete` rather than being discarded.

## Context assembly and model boundaries

Answer generation is split across durable storage, event ingestion, context selection, prompt construction, provider access, and Swift UI projection. There is no global mutable conversation prompt.

The default answer budget is 8,000 estimated tokens with 2,000 reserved for the answer and up to 500 reserved for a concise derived summary of omitted older text. `backend/services/context_builder.py` ranks current-meeting evidence using question relevance, event-type value, and recency. It then restores chronological ordering before prompt construction. Relevant screenshot analyses keep their raw screenshot asset when the pair fits the budget.

Prompts have separate system, developer, and user messages. The user message preserves the exact question. The developer message contains the meeting ID, selected evidence, stable source labels, budget diagnostics, omitted-event count, and any derived summary. Question and answer history is selected only from the requested thread.

OpenAI models listed in the native provider catalog accept selected screenshot pixels as multimodal image parts. The listed DeepSeek models are text-only. When a selected context contains a screenshot but the provider has no vision capability, the prompt and durable answer metadata state that the model did not see the pixels. Screenshot analysis text remains derived evidence and is not described as equivalent to the image.

Each question has its own request ID, immutable meeting snapshot, streaming state, and durable answer event. Rapid questions can finish in any order without overwriting one another. Selecting another meeting changes which durable record is assembled, preventing cross-meeting evidence leakage.

## Native screenshot flow

1. The workspace requests the macOS 14 ScreenCaptureKit content-sharing picker.
2. The user selects one window or display. Cancellation and picker failure remain inline UI states.
3. The app captures a PNG without the cursor and uploads it to the active meeting.
4. The backend validates the media signature and size, saves the asset locally, and immediately appends and broadcasts a screenshot event.
5. A retained background task performs multimodal analysis. It appends either `completed`, `unsupported`, or `failed` analysis as a separate event.
6. The workspace shows a thumbnail or a missing-file placeholder, analysis state, and the screenshot at its chronological position.
7. Later live or historical questions may select both the raw asset and its analysis as meeting evidence.

## Provider settings and secrets

Provider and model identifiers are non-secret preferences. API keys are added, updated, checked for presence, and removed through macOS Keychain service `com.promptmeet.desktop`. The settings UI uses Keychain metadata to display only configured or not configured. It does not decrypt a key to render status.

Connection validation sends the transient value directly to the provider over HTTPS and reports only success or a sanitized HTTP status. The local companion reads the selected key from Keychain only when constructing its child-process environment. Raw keys are excluded from ordinary app state, serialized meeting data, backend events, descriptions, and logs.

## Tests and local validation

No real model credentials are required for the core lifecycle regression. The API-level fake covers create, transcript, screenshot, live question, end, repository restart, history replay, and historical follow-up:

```bash
cd backend
../build/desktop-python/bin/python3 -m pytest -q \
  tests/test_meeting_lifecycle_e2e.py \
  tests/test_context_builder.py \
  tests/test_meeting_repository.py \
  tests/test_model_provider.py \
  tests/test_secret_hygiene.py
```

Run the full backend and Swift suites plus packaging checks with:

```bash
cd backend
../build/desktop-python/bin/python3 -m pytest -q

cd ../desktop-macos
swift test
swift build -c release

cd ..
./build-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
```

For deterministic UI inspection without capture permissions or model credentials, launch a workspace projection:

```bash
cd desktop-macos
PROMPTMEET_UI_PREVIEW=workspace swift run PromptMeet
```

The release package check in `scripts/check-macos-package-inputs.sh` fails early when the desktop requirements, Info.plist, or third-party notices are absent.

### Native walkthrough evidence and limits

The packaged app was exercised with a lane-local home directory and fake OpenAI-compatible provider through the real 1100 by 720 workspace. The walkthrough verified meeting creation before capture, transcript event display, screenshot thumbnail and text-only capability warning, live streaming answer, durable stop, app relaunch, history selection, chronological replay, and a durable historical follow-up. Provider settings were inspected in the real native window and showed masked Keychain state plus truthful model capabilities.

Computer Use captures the macOS display through ScreenCaptureKit. While that observer was active, the machine provided no usable system-audio or microphone source to PromptMeet and hid the protected content-sharing selection overlay from automation. The meeting was therefore retained as incomplete first, the failed-state retry UI was checked, and the rest of the walkthrough injected fake transcript and PNG bytes through the same native backend endpoints used by the app. Automated Swift tests cover audio-source fallback and picker activation, while the API E2E covers screenshot persistence and analysis. No real user screenshot, recording, model credential, or Keychain value was retained.

PromptMeet currently uses an intentional fixed dark visual system in `VisualTokens.swift`; it does not expose a light appearance. The 1100-wide workspace and the fixed 650-wide settings window were visually checked. The workspace declares a 980 by 640 native minimum, but the automation driver could not drag the protected split view to that exact size, so minimum-size behavior remains covered by the native window constraints and layout tests rather than a second captured walkthrough.
