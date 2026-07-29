# macOS meeting agent

This document describes the durable macOS meeting-agent architecture, its reproduced baseline failure, and the commands used to validate it.

## User journey and reproduced baseline

The expected journey is:

1. Launch the native app and its local companion.
2. Start a meeting and receive transcript content.
3. Confirm the independent “我” microphone and “会议” system-audio source states.
4. Select a screenshot window once, then capture it without reopening the picker.
5. Pause and resume recording without ending the meeting.
6. Ask a meeting-scoped question and receive a streamed answer with evidence sources.
7. End the meeting and quit the app.
8. Relaunch, open the retained meeting, and ask a follow-up whose answer is appended to that meeting.

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
- `suggestions`

Every event includes provenance. Provider-backed events may also include provider, model, and request ID metadata. Answer events contain stable evidence references such as `M12`, vision-degradation state, and an inline failure state when generation fails. Summary events are append-only revisions with the source event IDs, highest covered source revision, trigger, and active-minute milestone so the latest result is clear without erasing audit history.

Writes use a temporary sibling file followed by atomic replacement. A malformed version 2 file remains on disk and appears as a `recovery_required` item instead of being silently deleted. Missing screenshot bytes produce an unavailable preview and a 404 asset response while the timeline event and any analysis remain visible.

### Legacy migration

When `desktop-sessions.json` exists, the repository migrates each legacy entry on demand into a version 2 record. Existing version 2 files win, and the legacy source file is never removed or modified. Legacy transcript and summary data are retained with migration provenance. Records without an end time or summary become `incomplete` rather than being discarded.

## Context assembly and model boundaries

Answer generation is split across durable storage, event ingestion, context selection, prompt construction, provider access, and Swift UI projection. There is no global mutable conversation prompt.

The default answer budget is 8,000 estimated tokens with 2,000 reserved for the answer and up to 500 reserved for a concise derived summary of omitted older text. `backend/services/context_builder.py` ranks current-meeting evidence using question relevance, event-type value, and recency. It then restores chronological ordering before prompt construction. Relevant screenshot analyses keep their raw screenshot asset when the pair fits the budget.

Prompts have separate system, developer, and user messages. The user message preserves the exact question. The developer message contains the meeting ID, selected evidence, stable source labels, budget diagnostics, omitted-event count, and any derived summary. Question and answer history is selected only from the requested thread.

The configured OpenAI-compatible endpoint receives selected screenshot pixels as multimodal image parts. The listed DeepSeek models are text-only. When a selected context contains a screenshot but the provider has no vision capability, the prompt and durable answer metadata state that the model did not see the pixels. If an OpenAI-compatible endpoint explicitly rejects image input, PromptMeet retries once on the same endpoint and model without pixels, marks the answer as degraded, and records screenshot analysis as unsupported with `vision_used=false`. Screenshot analysis text remains derived evidence and is not described as equivalent to the image.

Each question has its own request ID, immutable meeting snapshot, streaming state, and durable answer event. Rapid questions can finish in any order without overwriting one another. Selecting another meeting changes which durable record is assembled, preventing cross-meeting evidence leakage.

## Native audio capture and recording activity

`CaptureState.swift` keeps meeting phase separate from recording activity and exposes the microphone and system-audio lifecycle independently. Microphone authorization distinguishes not determined, authorized, denied, restricted, unavailable hardware, and runtime failure. Permission is requested only when the user starts or explicitly retries capture. Denied and restricted states provide a route to the matching System Settings privacy pane.

`设置 → 采集` persists whether future meetings include the local microphone. The meeting-start surface shows the effective choice. When disabled, the coordinator excludes the microphone source before permission resolution, so it does not request permission, start `AVAudioEngine`, or publish a microphone failure. The setting does not alter existing source-tagged evidence and does not affect system audio, screenshots, AI conversation, summaries, or tasks.

The app bundle supplies both `NSMicrophoneUsageDescription` and the hardened-runtime `com.apple.security.device.audio-input` entitlement. `scripts/check-macos-package-inputs.sh` treats the entitlement file as a required package input, and `scripts/build-macos-app.sh` applies it during signing.

Microphone PCM is always semantic source `microphone` and renders as `我`. System audio is source `system` and renders as `会议`. The coordinator never mixes the streams. Every source-tagged chunk carries capture time and a monotonic meeting-relative millisecond offset through HTTP headers. The companion writes a separate `.pcm` file and JSON metadata sidecar per chunk. Transcripts retain the same source and meeting offset through live WebSocket events, version 2 persistence, history replay, evidence labels, and question context.

After the backend meeting is created and connected, the app marks native recording active and prebinds the transport before starting protected native sources. This prevents an active system source from producing unbound chunks while microphone permission is pending. If every native source fails, recording is stopped again and the durable attempt is marked incomplete.

One source may remain active when the other is denied, unavailable, or fails at runtime. Pausing stops every currently active native source, suspends transport, discards unfinished preview audio, and appends a durable lifecycle event while the meeting stays active. Resume first restores the companion state, then restarts previously active sources. If native restart fails, the companion is rolled back to paused. Stop is valid while paused. After app relaunch, prior meeting data remains durable, but protected audio capture is inactive until a new explicit user action.

## Native screenshot flow

1. `选择窗口` requests the macOS 14 ScreenCaptureKit content-sharing picker and permits a single window target.
2. The selected filter is retained with a visible selected or invalid state. Selection does not capture or upload pixels.
3. `截图` never presents the picker. It immediately captures the retained target as a cursor-free PNG and uploads it to the active meeting.
4. Repeated screenshot actions reuse the target. No selection produces `请先选择窗口`; a disappeared target remains visibly invalid until reselection.
5. Screen Recording authorization is requested only from the explicit selection or capture action. Denial provides a System Settings recovery action.
6. The backend validates the media signature and size, saves the asset locally, and immediately appends and broadcasts a screenshot event.
7. A retained background task performs multimodal analysis. It appends either `completed`, `unsupported`, or `failed` analysis as a separate event.
8. The workspace shows capture progress, a thumbnail or missing-file placeholder, analysis state, and the screenshot at its chronological position.
9. Later live or historical questions may select both the raw asset and its analysis as meeting evidence.

## Suggested-question freshness

`猜你想问` refresh is event-driven after meaningful transcript, screenshot analysis, summary, task, and completed-answer context. Swift applies a 350 millisecond debounce, deduplicates semantic context tokens, increments a meeting-scoped context revision, and cancels any pending debounce before requesting the next generation. Each request includes a generation UUID and revision.

The companion cancels the prior in-flight model task for that meeting and checks the latest generation before broadcasting or persisting a result. Swift performs the same generation and revision check before reducing an event, so an older response cannot replace newer suggestions. Only exactly three unique non-empty questions are accepted atomically. Loading, cancellation, empty or partial results, transient failure, and view refresh never erase the last accepted set. Accepted suggestions are version 2 timeline events and restore with their historical meeting.

## Workspace projection and Markdown

The workspace projects chronological meeting evidence on the left: source-attributed transcript, screenshots, screenshot analysis or failure, and generated summary or task evidence. User questions and assistant answers are excluded from that input projection and remain durably paired on the right conversation surface. The removed `参与讨论` item is not a meeting input event.

Assistant answers and generated narrative evidence use the native Markdown renderer in `MarkdownDocument.swift` and `MarkdownTextView.swift`. It supports headings, emphasis, ordered and unordered lists, quotes, inline and fenced code, and safe HTTP(S) links. Partial streaming fences render as stable code blocks, unsafe link destinations are stripped while preserving text, and the AppKit text view keeps selection, copy, wrapping, accessibility, and dark-theme contrast.

## Active-time summary and task milestones

`MeetingAutomationScheduler.swift` uses active recording time, not wall-clock polling. The default cadence fires at 5 minutes, 10 minutes, and every 5 active minutes thereafter. Settings persist off, 3, 5, or 10-minute cadence choices. Pause time does not count, a long suspension advances to only the latest crossed milestone, and each milestone fires at most once. A model request is skipped when no meaningful meeting input revision has changed.

Each accepted generation produces both a structured summary and actionable tasks in one append-only summary event. Capture continues while the workspace reports waiting, generating, completed, no-action, failed, and manual retry states.

## Provider settings and secrets

Provider, Base URL, model identifier, and explicit vision capability are typed non-secret preferences. The configuration inventories five token-spending workflows independently: conversation answers, suggested questions, summaries and tasks, screenshot analysis, and live translation. Each workflow selects DeepSeek or OpenAI-compatible plus a manual non-empty model identifier. Existing single-provider settings migrate into workflow selections without changing Keychain credentials. New DeepSeek selections use the project's established `deepseek-chat` default. Validation does not impose a model-name prefix, so provider-scoped future or custom identifiers remain valid.

OpenAI-compatible and DeepSeek endpoints are shared by their provider workflows. The companion receives purpose-specific `PROMPTMEET_ANSWER_*`, `PROMPTMEET_QUESTION_*`, `PROMPTMEET_SUMMARY_*`, `PROMPTMEET_SCREENSHOT_*`, and `PROMPTMEET_TRANSLATION_*` environment values plus the two provider Base URLs. These values never include credentials. A workflow selected as text-only states the exact degradation: conversation can use transcript and prior analysis text without raw pixels, while screenshot analysis records `unsupported` and retains the image without inventing a visual conclusion.

API keys are added, updated, checked for presence, and removed through macOS Keychain service `com.promptmeet.desktop`. The settings UI uses Keychain metadata to display only configured or not configured. It reads a stored key only for an explicit validation request or companion launch and never renders the value.

The OpenAI-compatible boundary accepts HTTPS endpoints and plain HTTP only for exact loopback hosts `localhost`, `127.0.0.1`, and `::1`. DeepSeek endpoints require HTTPS. Both remove trailing slashes and derive exactly `<base>/chat/completions`. Connection validation posts a minimal request with the selected workflow model to that exact endpoint. Validation and runtime configuration errors identify workflow, provider, and model after removing the credential. Routing never falls back to another provider or endpoint. The local companion reads the selected key from Keychain only when constructing its child-process environment. Raw keys are excluded from ordinary app state, serialized meeting data, backend events, descriptions, feedback, and logs.

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
./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
codesign -d --entitlements :- dist/PromptMeet.app
```

For deterministic UI inspection without capture permissions or model credentials, launch a workspace projection:

```bash
cd desktop-macos
PROMPTMEET_UI_PREVIEW=workspace swift run PromptMeet
```

The release package check in `scripts/check-macos-package-inputs.sh` fails early when the desktop requirements, Info.plist, or third-party notices are absent.

### Native walkthrough evidence and limits

The capture-controls build was packaged and ad-hoc signed from the isolated worktree, then launched by its full bundle path in the real macOS session at 1100 by 750 points. The final workspace visibly separated `选择窗口` and `截图`, showed `我 · 正在准备` and `会议 · 采集中`, rendered the live system transcript as `会议`, and moved `猜你想问` into loading immediately after that transcript. The companion reported `is_recording=true` while microphone authorization was pending. The resulting version 2 record contained a `system` transcript at meeting offset 72,405 ms and a durable suggestions event with generation ID and context revision 1. The record was stopped and completed without retaining any test asset in the repository.

Computer Use could initiate the real microphone authorization request and ScreenCaptureKit window picker, but macOS omitted both protected overlays from the accessibility tree and captured pixels. Keyboard and coordinate attempts could not resolve the microphone dialog, so actual microphone authorization, picker choice, repeated real screenshots, and UI-driven pause/resume were not claimed. The workspace did expose `正在选择窗口` while the protected picker was active. Focused Swift tests cover every permission result, independent-source continuation, prebound first chunk, repeated screenshot reuse, pause/resume rollback, rapid toggles, and stop while paused. Backend tests cover truthful invalid transition responses, lifecycle persistence, paused chunk rejection, source attribution, and generation supersession.

The packaged app was exercised with a lane-local home directory and fake OpenAI-compatible provider through the real 1100 by 720 workspace. The walkthrough verified meeting creation before capture, transcript event display, screenshot thumbnail and text-only capability warning, live streaming answer, durable stop, app relaunch, history selection, chronological replay, and a durable historical follow-up. Provider settings were inspected in the real native window and showed masked Keychain state plus truthful model capabilities.

The OpenAI-compatible settings build was inspected in the signed native settings window with a placeholder-only loopback provider. The UI displayed readable Base URL and model fields after a field-editor contrast regression was found and fixed. Validation reached exactly `/v1/chat/completions` with the configured model, surfaced the provider JSON message with the placeholder credential redacted, rejected non-loopback HTTP before networking, normalized the saved trailing slash, and showed only masked Keychain state. A saved local URL and model were observed after one real app relaunch before the walkthrough deliberately restored the official defaults and deleted the placeholder. Fresh-instance UserDefaults and Keychain-spy regressions cover persistence deterministically. A later unique-bundle isolation rerun could not be visually observed because Computer Use failed to start ScreenCaptureKit with error `-3811`; the temporary process, defaults domain, placeholder credential, and fake server were removed.

Computer Use captures the macOS display through ScreenCaptureKit. While that observer was active, the machine provided no usable system-audio or microphone source to PromptMeet and hid the protected content-sharing selection overlay from automation. The meeting was therefore retained as incomplete first, the failed-state retry UI was checked, and the rest of the walkthrough injected fake transcript and PNG bytes through the same native backend endpoints used by the app. Automated Swift tests cover audio-source fallback and picker activation, while the API E2E covers screenshot persistence and analysis. No real user screenshot, recording, model credential, or Keychain value was retained.

PromptMeet currently uses an intentional fixed dark visual system in `VisualTokens.swift`; it does not expose a light appearance. The 1100-wide workspace and the fixed 650-wide settings window were visually checked. The workspace declares a 980 by 640 native minimum, but the automation driver could not drag the protected split view to that exact size, so minimum-size behavior remains covered by the native window constraints and layout tests rather than a second captured walkthrough.
