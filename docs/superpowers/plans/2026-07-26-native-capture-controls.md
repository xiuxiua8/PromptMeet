# Native Capture Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver permission-aware, independently attributed microphone and system-audio capture, fresh meeting-scoped suggestions, persistent window selection with one-click screenshots, and safe pause/resume controls in the native macOS app.

**Architecture:** Keep the meeting session distinct from recording activity. A native capture coordinator owns per-source state and a monotonic meeting clock, while microphone and system audio start, fail, pause, recover, and resume independently. Source-tagged audio and transcript metadata remain explicit through Swift, HTTP, Python models, durable timeline events, history projection, context rendering, and UI. Screenshot selection becomes a retained capture target, suggestion generation carries a meeting-scoped generation token and revision, and stale backend work is cancelled or discarded.

**Tech Stack:** Swift 6, SwiftUI, AppKit, AVFoundation, ScreenCaptureKit, CoreGraphics, FastAPI, Pydantic, pytest, XCTest.

## Global Constraints

- Start from merged commit `be3d435a434c2bf18ec1eef2bd38971f86c5257e` in the isolated worktree only.
- Never serialize, log, or transmit provider secrets or Keychain values.
- Do not mix microphone and system audio before source-aware transcription and attribution.
- Preserve version 2 atomic sibling-file writes and keep malformed records as `recovery_required`.
- DeepSeek remains text-only and visual degradation must remain truthful.
- The macOS UI remains fixed dark appearance with Chinese copy and accessible control labels.
- Write and observe every regression test failing before implementation.
- Never commit app bundles, permission databases, real meeting media, `.env`, or Keychain material.

## Reproduction Record

Exact setup: macOS arm64, packaged `dist/PromptMeet.app` built from `be3d435` with cached Python and a freshly compiled pinned whisper.cpp runtime, ad-hoc hardened-runtime signing, the real companion process, a 1100 by 750 point workspace, and the machine's existing protected-resource state. The baseline was 110 Swift tests and 60 Python tests with no failures.

| Path | Expected | Observed | Repeatability | Trigger, mask, symptom |
| --- | --- | --- | --- | --- |
| Start meeting | Permission state is requested or explained; each source reports truthfully | `麦克风不可用，已尝试其他来源：麦克风权限未授权` while the meeting still looks live | First attempt on the isolated packaged build | Trigger: start capture. Mask: system audio succeeds. Symptom: generic insight with no per-source state or recovery action. |
| Package authorization | Hardened app carries audio-input entitlement and usage metadata | Usage strings exist, but `codesign -d --entitlements :-` reports no app entitlements | Every package build | Trigger: `build-macos-app.sh`. Mask: Info.plist looks correct. Symptom: hardened binary lacks the signing capability input. |
| Screenshot | `选择窗口` changes the retained target; `截图` immediately captures it | The only screenshot button sets `请选择要分析的窗口或屏幕` and awaits the system picker | Every click | Trigger: screenshot button. Mask: button copy says screenshot. Symptom: selection and capture are one continuation. |
| Pause | Meeting remains live while both available inputs suspend and resume | Only stop exists in island and workspace | Always | Trigger: inspect active controls. Mask: transcript auto-follow has a separate pause icon. Symptom: no recording pause action. |
| Attribution | `我` and `会议` survive live UI, durable history, and agent context | Backend version 2 event retains `source=system`, but `TranscriptSegment` and Swift `TranscriptLine` drop source; timestamps are completion time | Every event through those projections | Trigger: transcript projection. Mask: speaker text often still looks plausible. Symptom: semantic source and capture-relative time disappear. |
| Suggestions | Debounced event-driven refresh after transcript, screenshot, and answer; stale work cannot overwrite | Refresh is immediate per final transcript only; a boolean blocks overlap; websocket results have no generation token | Every code path | Trigger: new context while generation runs. Mask: loop eventually issues another call for transcripts only. Symptom: old results can arrive without a freshness check and visual/answer context does not trigger. |

The smallest disconfirming evidence was the proven system-audio path: the same failed microphone start produced source-tagged `*-system.pcm` assets, HTTP 200 ingestion, and a persisted transcript with `speaker=会议` and `source=system`. This rules out a whole-meeting startup failure. The narrow failure is microphone authorization and source-state reporting, while fallback masks it.

## File Structure

- Create `desktop-macos/Resources/PromptMeet.entitlements`: hardened-runtime audio-input capability.
- Create `desktop-macos/Sources/PromptMeet/Domain/CaptureState.swift`: permission, per-source, recording, screenshot-selection, screenshot-operation, and suggestion-refresh value types.
- Create `desktop-macos/Sources/PromptMeet/Capture/CapturePermissions.swift`: injectable microphone and screen-recording permission providers plus System Settings routing.
- Modify `desktop-macos/Sources/PromptMeet/Capture/MicrophoneCapture.swift`: explicit authorization transition and runtime-failure handling.
- Modify `desktop-macos/Sources/PromptMeet/Capture/SystemAudioCapture.swift`: explicit Screen Recording permission and stream-failure reporting.
- Modify `desktop-macos/Sources/PromptMeet/Capture/NativeAudioPipeline.swift`: capture timestamps, meeting-relative offsets, source tags, and pause-safe pump behavior.
- Modify `desktop-macos/Sources/PromptMeet/Capture/NativeAudioCaptureCoordinator.swift`: independent source lifecycle, pause/resume, recovery, and source status publishing.
- Modify `desktop-macos/Sources/PromptMeet/Transcription/PCMTranscriptionSegmenter.swift` and `LocalTranscriptionService.swift`: source-aware capture timing and pause boundary reset.
- Replace the responsibilities in `desktop-macos/Sources/PromptMeet/Capture/ScreenCapturePicker.swift`: target selection only, retained target validation, and separate capture.
- Modify `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`: meeting-scoped recording state, screenshot actions, debounced suggestion revision, and stale-event guards.
- Modify `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift` and `Domain/BackendEvent.swift`: timing fields and typed suggestion generations.
- Modify `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`, `MeetingTimeline.swift`, and `StoredMeeting.swift`: source attribution, suggestion persistence, historical projection, and operation states.
- Modify `desktop-macos/Sources/PromptMeet/Views/HoverMeetingCardView.swift`, `IslandRootView.swift`, and `WorkspaceView.swift`: per-source badges, recovery links, selection state, capture feedback, and pause/resume controls.
- Modify `backend/models/native_bridge.py`, `models/data_models.py`, and `models/meeting_context.py`: timing, source, paused session, and suggestion event types.
- Modify `backend/api/native_audio.py`, `native_recording.py`, and `native_transcript.py`: pause/resume routes and explicit timing transport.
- Modify `backend/main_service.py`, `services/meeting_ingestion.py`, `services/context_builder.py`, and `services/desktop_agent_service.py`: pause events, source-aware context, cancellable suggestion generations, and screenshot/answer context.
- Modify `scripts/build-macos-app.sh`, `scripts/check-macos-package-inputs.sh`, and packaging tests: entitlements are mandatory and applied.
- Update `docs/macos-meeting-agent.md` and `AGENTS.md`: document the new top-level domain/service boundaries and core invariants.

### Task 1: Permission and Packaging Contract

**Files:**
- Create: `desktop-macos/Resources/PromptMeet.entitlements`
- Create: `desktop-macos/Sources/PromptMeet/Capture/CapturePermissions.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/MicrophoneCapture.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/SystemAudioCapture.swift`
- Modify: `scripts/build-macos-app.sh`
- Modify: `scripts/check-macos-package-inputs.sh`
- Test: `desktop-macos/Tests/PromptMeetTests/CapturePermissionTests.swift`
- Test: `backend/tests/test_macos_packaging_inputs.py`

**Interfaces:**
- Produces: `MicrophoneAuthorizationState`, `MicrophonePermissionProviding`, `ScreenRecordingPermissionProviding`, and precise `CaptureError` cases.
- Consumes: `AVCaptureDevice.authorizationStatus(for:)`, `requestAccess(for:)`, `CGPreflightScreenCaptureAccess()`, and `CGRequestScreenCaptureAccess()` only at explicit user actions.

- [x] **Step 1: Write failing permission transition and package-input tests**

```swift
func testNotDeterminedRequestsOnceThenStartsOnlyWhenAuthorized() async throws {
    let permission = MicrophonePermissionSpy(status: .notDetermined, requestResult: .authorized)
    let decision = await MicrophonePermissionResolver(permission: permission).resolveForUserStart()
    XCTAssertEqual(decision, .authorized)
    XCTAssertEqual(permission.requestCount, 1)
}

func testDeniedDoesNotRequestAgainAndOffersSettingsRecovery() async {
    let permission = MicrophonePermissionSpy(status: .denied)
    let decision = await MicrophonePermissionResolver(permission: permission).resolveForUserStart()
    XCTAssertEqual(decision, .denied)
    XCTAssertEqual(permission.requestCount, 0)
    XCTAssertTrue(decision.canOpenSystemSettings)
}
```

```python
def test_package_requires_audio_input_entitlement() -> None:
    entitlement = ROOT / "desktop-macos/Resources/PromptMeet.entitlements"
    assert plistlib.loads(entitlement.read_bytes())["com.apple.security.device.audio-input"] is True
    assert "--entitlements" in (ROOT / "scripts/build-macos-app.sh").read_text()
```

- [x] **Step 2: Run tests and verify the intended failures**

Run: `cd desktop-macos && swift test --filter CapturePermissionTests`

Expected: FAIL because permission resolver types do not exist.

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_macos_packaging_inputs.py`

Expected: FAIL because the entitlement file and signing argument do not exist.

- [x] **Step 3: Implement permission resolution and signing inputs**

```swift
enum MicrophoneAuthorizationState: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted, unavailable
}

struct MicrophonePermissionResolver {
    let permission: any MicrophonePermissionProviding
    func resolveForUserStart() async -> MicrophoneAuthorizationState {
        let state = permission.authorizationState
        return state == .notDetermined ? await permission.requestAuthorization() : state
    }
}
```

Use `CaptureError.microphoneDenied`, `.microphoneRestricted`, `.microphoneUnavailable`, `.microphoneRuntimeFailure(String)`, `.screenRecordingDenied`, and `.systemAudioRuntimeFailure(String)` without collapsing them into one fallback string. Sign the app with `codesign --entitlements "$MACOS_ROOT/Resources/PromptMeet.entitlements"`.

- [x] **Step 4: Run focused tests and inspect signed entitlements**

Run: `cd desktop-macos && swift test --filter CapturePermissionTests`

Expected: PASS.

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_macos_packaging_inputs.py`

Expected: PASS.

Run after packaging: `codesign -d --entitlements :- dist/PromptMeet.app`

Expected: `com.apple.security.device.audio-input = true`.

### Task 2: Independent Source Lifecycle, Timing, and Pause Boundaries

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Domain/CaptureState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeAudioPipeline.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeAudioCaptureCoordinator.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Transcription/PCMTranscriptionSegmenter.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Transcription/LocalTranscriptionService.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/PCMTranscriptionSegmenterTests.swift`

**Interfaces:**
- Produces: `AudioSourceState`, `AudioCaptureSnapshot`, `RecordingActivity`, `pause()`, `resume()`, and `retry(source:)` on `NativeAudioCaptureCoordinating`.
- Produces: `CapturedPCM.capturedAt`, `CapturedPCM.meetingTime`, `NativeAudioPacket.meetingTime`, and `LocalTranscript.meetingTime`.

- [x] **Step 1: Write failing independent lifecycle and rapid-toggle tests**

```swift
func testPauseStopsOnlyActiveSourcesAndResumeRestartsThemOnce() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let microphone = NativeAudioSourceCaptureSpy(source: .microphone, error: CaptureError.microphoneDenied)
    let coordinator = NativeAudioCaptureCoordinator(sources: [system, microphone], uploader: UploadSpy(), transcription: TranscriptionSpy())
    try await coordinator.start(sessionID: "local", onStatus: { _ in }, onPartialTranscript: { _ in }, onTranscript: { _ in }, onTranscriptionError: { _ in })
    await coordinator.pause()
    try await coordinator.resume()
    XCTAssertEqual(system.startCount, 2)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertEqual(microphone.startCount, 1)
}
```

```swift
func testMeetingTimeContinuesAcrossPauseAndNeverMovesBackward() {
    var clock = NativeAudioMeetingClock(now: { 1_000 })
    clock.start()
    XCTAssertEqual(clock.offset(at: 1_250), .milliseconds(250))
    XCTAssertEqual(clock.offset(at: 4_000), .seconds(3))
}
```

- [x] **Step 2: Run focused Swift tests and verify failures**

Run: `cd desktop-macos && swift test --filter NativeAudioPipelineTests && swift test --filter PCMTranscriptionSegmenterTests`

Expected: FAIL because pause/resume, source snapshots, and meeting timing do not exist.

- [x] **Step 3: Implement source state and pause-safe capture**

```swift
enum AudioSourceState: Equatable, Sendable {
    case idle, requestingPermission, active, paused
    case denied, restricted, unavailable(String), failed(String)
}

struct AudioCaptureSnapshot: Equatable, Sendable {
    var microphone: AudioSourceState = .idle
    var system: AudioSourceState = .idle
}
```

Stop active source objects during pause, retain the meeting clock and packet sequence, clear unfinalized transcription preview buffers at the pause boundary, and restart each previously active source at most once. A denied source remains denied until explicit retry. Runtime failures update only that source and do not terminate the other source or the meeting.

- [x] **Step 4: Run focused Swift tests**

Run: `cd desktop-macos && swift test --filter NativeAudioPipelineTests && swift test --filter PCMTranscriptionSegmenterTests`

Expected: PASS with no duplicate callbacks or replayed buffered segment.

### Task 3: Source and Timing Preservation Through Python and History

**Files:**
- Modify: `backend/models/native_bridge.py`
- Modify: `backend/models/data_models.py`
- Modify: `backend/models/meeting_context.py`
- Modify: `backend/api/native_audio.py`
- Modify: `backend/api/native_transcript.py`
- Modify: `backend/services/meeting_ingestion.py`
- Modify: `backend/services/context_builder.py`
- Modify: `backend/main_service.py`
- Modify: `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/BackendEvent.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingTimeline.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/StoredMeeting.swift`
- Test: `backend/tests/test_native_audio_router.py`
- Test: `backend/tests/test_native_transcript_router.py`
- Test: `backend/tests/test_meeting_lifecycle_e2e.py`
- Test: `backend/tests/test_context_builder.py`
- Test: `desktop-macos/Tests/PromptMeetTests/BackendEventTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift`

**Interfaces:**
- Produces: optional `meeting_time_ms` on audio and transcript models for backward compatibility.
- Produces: explicit `source` on `TranscriptSegment`, `TranscriptLine`, and context labels.

- [x] **Step 1: Write failing end-to-end attribution tests**

```python
def test_microphone_and_system_transcripts_keep_source_speaker_and_monotonic_time(client):
    events = submit_two_sources(client, microphone_ms=1200, system_ms=1250)
    assert [(e["payload"]["source"], e["payload"]["speaker"]) for e in events] == [
        ("microphone", "我"), ("system", "会议")
    ]
    assert [e["payload"]["meeting_time_ms"] for e in events] == [1200, 1250]
```

```swift
func testHistoricalTranscriptKeepsSemanticSourceAndMeetingTime() throws {
    let meeting = try StoredMeeting.parseList(sourceTaggedRecord).first
    XCTAssertEqual(meeting?.transcript.map(\.source), [.microphone, .system])
    XCTAssertEqual(meeting?.transcript.map(\.meetingTime), [.milliseconds(1200), .milliseconds(1250)])
}
```

- [x] **Step 2: Run Python and Swift tests and verify failures**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_native_audio_router.py tests/test_native_transcript_router.py tests/test_meeting_lifecycle_e2e.py tests/test_context_builder.py`

Expected: FAIL because timing and legacy projection source fields are absent.

Run: `cd desktop-macos && swift test --filter 'BackendEventTests|MeetingHistoryTests'`

Expected: FAIL because `TranscriptLine` lacks semantic source and meeting time.

- [x] **Step 3: Implement explicit source and timing transport**

```python
class TranscriptSegment(BaseModel):
    source: Literal["system", "microphone", "mixed"] | None = None
    meeting_time_ms: int | None = Field(default=None, ge=0)
```

Render transcript context as `我（麦克风）` or `会议（系统音频）`, preserve optional fields for legacy records, and order equal-sequence projections deterministically by meeting time, capture timestamp, then ID.

- [x] **Step 4: Run focused end-to-end tests**

Run the commands from Step 2.

Expected: PASS with source identity present in live websocket, durable JSON, history, and context.

### Task 4: Backend and Store Pause/Resume State Machine

**Files:**
- Modify: `backend/api/native_recording.py`
- Modify: `backend/models/data_models.py`
- Modify: `backend/main_service.py`
- Modify: `backend/services/meeting_ingestion.py`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Test: `backend/tests/test_native_recording_router.py`
- Test: `backend/tests/test_meeting_lifecycle_e2e.py`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`

**Interfaces:**
- Produces: `/pause-native-recording` and `/resume-native-recording`.
- Produces: `MeetingStore.pauseMeetingNow()` and `resumeMeetingNow()` while `MeetingPhase.live` remains unchanged.

- [x] **Step 1: Write failing transition tests**

```swift
func testPauseResumeKeepsMeetingContextAndStopWhilePausedEndsNormally() async {
    await store.startMeetingNow()
    await store.pauseMeetingNow()
    XCTAssertEqual(store.state.phase, .live)
    XCTAssertEqual(store.state.recordingActivity, .paused)
    await store.resumeMeetingNow()
    XCTAssertEqual(store.state.recordingActivity, .recording)
    await store.pauseMeetingNow()
    await store.endMeetingNow()
    XCTAssertEqual(store.state.phase, .idle)
}
```

```python
def test_pause_resume_routes_append_lifecycle_without_completing_meeting(client):
    assert client.post(f"/api/sessions/{meeting}/pause-native-recording").status_code == 200
    assert client.post(f"/api/sessions/{meeting}/resume-native-recording").status_code == 200
    assert latest_record(meeting).status == MeetingStatus.ACTIVE
```

- [x] **Step 2: Run focused tests and verify failures**

Run: `cd desktop-macos && swift test --filter 'MeetingStoreTests|MeetingStateTests'`

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_native_recording_router.py tests/test_meeting_lifecycle_e2e.py`

Expected: FAIL because pause/resume states and routes do not exist.

- [x] **Step 3: Implement serialized meeting recording transitions**

```swift
enum RecordingActivity: Equatable, Sendable {
    case inactive, starting, recording, pausing, paused, resuming, stopping
}
```

Guard rapid toggles through transitional states, stop while paused without resuming, retain screenshot and Q&A availability while paused, and reset to inactive after app relaunch. Backend lifecycle events explicitly record pause and resume without closing the version 2 record.

- [x] **Step 4: Run focused transition tests**

Run the commands from Step 2.

Expected: PASS.

### Task 5: Separate Window Selection and Screenshot Capture

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Capture/ScreenCapturePicker.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeScreenshotUploader.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/ScreenCapturePickerTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`
- Test: `backend/tests/test_desktop_screenshot_processing.py`

**Interfaces:**
- Produces: `selectTarget() async throws -> ScreenshotTargetState` and `captureSelected(sessionID:) async throws`.
- Produces: `MeetingStore.selectCaptureTargetNow()` and `requestScreenshotNow()` as separate actions.

- [x] **Step 1: Write failing separation and repeat-capture tests**

```swift
func testSelectingTargetPresentsPickerWithoutCapturing() async throws {
    try await controller.selectTarget()
    XCTAssertEqual(picker.presentCount, 1)
    XCTAssertEqual(capturer.captureCount, 0)
}

func testRepeatedScreenshotsReuseSelectionWithoutPickerChurn() async throws {
    try await controller.selectTarget()
    try await controller.captureSelected(sessionID: "meeting")
    try await controller.captureSelected(sessionID: "meeting")
    XCTAssertEqual(picker.presentCount, 1)
    XCTAssertEqual(capturer.captureCount, 2)
}
```

- [x] **Step 2: Run focused tests and verify failures**

Run: `cd desktop-macos && swift test --filter 'ScreenCapturePickerTests|MeetingStoreTests'`

Expected: FAIL because selection always captures and uploads.

- [x] **Step 3: Retain a validated filter and separate operations**

```swift
enum ScreenshotTargetState: Equatable, Sendable {
    case none
    case selected(label: String)
    case invalid(label: String, reason: String)
}

enum ScreenshotOperationState: Equatable, Sendable {
    case idle, selecting, capturing, succeeded, failed(String)
}
```

The selection observer stores the filter and resumes selection without calling `SCScreenshotManager`. Capture uses the stored filter immediately. Capture failure retains an invalid target label and exposes reselection. With no target, return `请先选择窗口`; Screen Recording denial offers System Settings.

- [x] **Step 4: Run screenshot tests**

Run: `cd desktop-macos && swift test --filter 'ScreenCapturePickerTests|MeetingStoreTests'`

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_screenshot_processing.py`

Expected: PASS.

### Task 6: Fresh, Meeting-Scoped Suggested Questions

**Files:**
- Modify: `backend/models/meeting_context.py`
- Modify: `backend/services/meeting_ingestion.py`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/main_service.py`
- Modify: `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/BackendEvent.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingTimeline.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/StoredMeeting.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Test: `backend/tests/test_desktop_question_route.py`
- Test: `backend/tests/test_meeting_repository.py`
- Test: `desktop-macos/Tests/PromptMeetTests/BackendEventTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift`

**Interfaces:**
- Produces: `generateQuestions(sessionID:generationID:contextRevision:)`.
- Produces: websocket `questions` data containing `generation_id`, `context_revision`, and `questions`.
- Produces: durable `suggestions` timeline payload for history restoration.

- [x] **Step 1: Write failing stale-response and event-trigger tests**

```swift
func testOlderQuestionGenerationCannotOverwriteNewerSuggestions() async {
    store.receive(.questions(generationID: old, contextRevision: 1, questions: ["旧问题"]))
    store.receive(.questions(generationID: current, contextRevision: 2, questions: ["新问题"]))
    XCTAssertEqual(store.state.generatedQuestions, ["新问题"])
}

func testScreenshotAndAnswerScheduleDebouncedSuggestionRefresh() async {
    store.receive(.screenshotInsight("预算是二十万"))
    store.receive(.answerFinal(requestID: request, answer: "负责人是周岚"))
    await clock.advance(by: .milliseconds(350))
    XCTAssertEqual(backend.questionRequests.count, 1)
}
```

```python
def test_superseded_generation_never_broadcasts(monkeypatch):
    first, second = start_overlapping_generations()
    assert first.json()["superseded"] is True
    assert broadcasts == [{"generation_id": second_id, "context_revision": 2}]
```

- [x] **Step 2: Run focused tests and verify failures**

Run: `cd desktop-macos && swift test --filter 'BackendEventTests|MeetingStoreTests|MeetingHistoryTests'`

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_question_route.py tests/test_meeting_repository.py`

Expected: FAIL because generations, debounce, cancellation, and persistence do not exist.

- [x] **Step 3: Implement freshness tokens and event-driven debounce**

```swift
struct SuggestionRefreshState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, loading, ready, failed(String) }
    var phase: Phase = .idle
    var generationID: UUID?
    var contextRevision = 0
}
```

Increment the revision for meaningful transcript, screenshot-analysis, and final-answer context. Cancel the local debounce task, skip unchanged fingerprints, and apply results only when meeting ID, generation ID, and revision match. Backend cancels the prior model task per session, checks the token again before broadcast, and persists only accepted suggestions. Historical meetings project their latest accepted suggestion event.

- [x] **Step 4: Run suggestion freshness tests**

Run the commands from Step 2.

Expected: PASS with one debounced call and no stale overwrite.

### Task 7: Accessible Capture Controls and State Clarity

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/HoverMeetingCardView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/IslandRootView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceProjection.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/IslandGeometryTests.swift`

**Interfaces:**
- Consumes: `AudioCaptureSnapshot`, `RecordingActivity`, `ScreenshotTargetState`, `ScreenshotOperationState`, and `SuggestionRefreshState`.
- Produces: visible and accessible Chinese controls in compact hover and workspace surfaces.

- [x] **Step 1: Write failing presentation tests**

```swift
func testDeniedMicrophoneAndActiveSystemAudioHaveTruthfulLabels() {
    let presentation = CaptureStatusPresentation(snapshot: .init(microphone: .denied, system: .active))
    XCTAssertEqual(presentation.microphone.label, "我 · 需要麦克风权限")
    XCTAssertEqual(presentation.system.label, "会议 · 采集中")
    XCTAssertTrue(presentation.showsMicrophoneSettingsAction)
}

func testPausedMeetingPresentsResumeSeparateFromStop() {
    let controls = MeetingControlPresentation(phase: .live, recordingActivity: .paused)
    XCTAssertEqual(controls.pauseResumeTitle, "继续录音")
    XCTAssertTrue(controls.canStop)
}
```

- [x] **Step 2: Run focused UI model tests and verify failures**

Run: `cd desktop-macos && swift test --filter 'MeetingStateTests|WorkspaceProjectionTests|IslandGeometryTests'`

Expected: FAIL because the presentation has no source, pause, selection, or operation models.

- [x] **Step 3: Implement compact status surfaces**

```swift
Label("我 · 需要麦克风权限", systemImage: "mic.slash")
    .accessibilityLabel("当前发言人，我，麦克风权限未授权")

Button(action: store.togglePauseResume) {
    Label(isPaused ? "继续录音" : "暂停录音", systemImage: isPaused ? "play.fill" : "pause.fill")
}
```

Show `选择窗口` and `截图` as distinct accessible actions, selected or invalid target text, capture progress and retry, suggestion loading/error/retry, and source badges. Keep pause/resume separate from the red stop action in both hover and workspace controls. Use `我` for microphone transcript rows and `会议` for system rows.

- [x] **Step 4: Run UI model and geometry tests**

Run the command from Step 2.

Expected: PASS with no geometry regression.

### Task 8: Documentation, Full Validation, and Real-App Verification

**Files:**
- Modify: `docs/macos-meeting-agent.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Documents: capture source contract, permission recovery, pause intervals, screenshot target lifecycle, suggestion freshness, and validation commands.

- [x] **Step 1: Update authoritative documentation**

Document that microphone and system audio are distinct source-tagged streams, `MeetingPhase.live` can coexist with paused `RecordingActivity`, screenshots capture the retained target without reopening selection, and suggestions are generation-tokened timeline state.

- [x] **Step 2: Run format and complete automated verification**

Run: `swift-format lint --recursive desktop-macos/Sources desktop-macos/Tests` if `swift-format` is available.

Run: `cd desktop-macos && swift test && swift build -c release`.

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q`.

Run: `./scripts/check-macos-package-inputs.sh`.

Expected: all commands exit 0 with no failures.

- [x] **Step 3: Build, sign, and inspect the app**

Run: `PROMPTMEET_SKIP_WHISPER_BUILD=1 PROMPTMEET_SKIP_PYTHON_BUILD=1 ./scripts/build-macos-app.sh`.

Run: `codesign --verify --deep --strict dist/PromptMeet.app`.

Run: `codesign -d --entitlements :- dist/PromptMeet.app`.

Expected: release app builds and verifies, and audio-input entitlement is present.

- [x] **Step 4: Exercise the real UI at realistic sizes**

Launch the packaged app, open the workspace, start a meeting, inspect the real permission result without treating simulated status as proof, verify independent source badges, play safe synthetic meeting speech into system audio, select a non-sensitive test window, capture it twice without picker churn, observe analysis and suggestion refresh, pause, verify source ingestion stops while screenshot and Q&A remain intentional, resume, and stop while paused once. Inspect 980 by 640 minimum and approximately 1100 by 750 normal sizes for clipping, alignment, Chinese copy, visible focus and accessibility labels.

- [x] **Step 5: Verify worktree hygiene and commit**

Run: `git status --short` and `git diff --check`.

Confirm no `.app`, media, screenshot, `.env`, TCC database, logs, or Keychain content is tracked. Commit only implementation, tests, and documentation using a concise commit message without an agent co-author.

## Self-Review

- Spec coverage: permission states and recovery are Tasks 1, 2, and 7; distinct source identity is Tasks 2 and 3; suggestion freshness is Task 6; picker separation is Task 5; pause/resume is Tasks 2, 4, and 7; packaging, UI, and real-app verification are Task 8.
- Placeholder scan: no deferred implementation placeholders remain.
- Type consistency: `AudioCaptureSnapshot`, `RecordingActivity`, `ScreenshotTargetState`, `ScreenshotOperationState`, `SuggestionRefreshState`, `generationID`, `contextRevision`, `source`, and `meetingTime` use the same names across producers and consumers.
