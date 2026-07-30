# Native Audio Denoising and Speech Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve native microphone capture with safe macOS voice processing and prevent non-speech PCM from reaching local Whisper while preserving quiet and brief speech.

**Architecture:** Keep microphone-only denoising at the AVAudioEngine source boundary. Add a pure Swift, per-source streaming speech gate between PCM normalization and segmentation, with adaptive noise-floor tracking, speech-shape evidence, hysteresis, minimum duration, pre-roll, hangover, timing anchors, and aggregate counters. Make transcription lifecycle generation-scoped so pause and stop intentionally discard stale work, then surface only transition-level source activity in the existing capture badges.

**Tech Stack:** Swift 6, AVFoundation Voice Processing, Foundation, XCTest, SwiftPM, packaged whisper.cpp, FastAPI pytest validation.

## Global Constraints

- Process microphone audio only where microphone semantics apply; never relabel or stop system audio.
- Never log samples or transcript content from diagnostics.
- Keep timing monotonic per source across chunk boundaries and reset buffered speech intentionally at pause and stop.
- Do not add tuning controls, third-party VAD dependencies, model files, recordings, generated bundles, or secrets.
- Do not modify screenshots, history titles, Markdown output, timeline layout, or island geometry.

---

### Task 1: Deterministic PCM regressions

**Files:**
- Create: `desktop-macos/Tests/PromptMeetTests/PCMTestFixtures.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/PCMTranscriptionSegmenterTests.swift`

**Interfaces:**
- Produces: `PCMTestFixtures.silence`, `dcOffset`, `whiteNoise`, `quietSpeech`, `speechBurst`, and `overlappingSpeech` as deterministic `[Int16]` samples at 16 kHz.
- Consumes: `PCMTranscriptionSegmenter.consumeStreaming`, `flush`, `discardBufferedAudio`, and `diagnostics`.

- [ ] **Step 1: Write fixture-backed failing tests**

```swift
func testDigitalSilenceDCOffsetAndSteadyWhiteNoiseNeverFinalize() {
    for samples in [PCMTestFixtures.silence(), PCMTestFixtures.dcOffset(), PCMTestFixtures.whiteNoise()] {
        var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
        XCTAssertTrue(segmenter.consume(.packet(samples)).isEmpty)
        XCTAssertTrue(segmenter.flush().isEmpty)
    }
}

func testQuietSpeechAfterSilenceKeepsPreRollAndFinalizesAfterHangover() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 8)
    let update = segmenter.consumeStreaming(.packet(PCMTestFixtures.silenceThenQuietSpeech()))
    XCTAssertEqual(update.activityTransition, .speechDetected(.microphone))
    XCTAssertFalse(segmenter.flush().isEmpty)
}
```

- [ ] **Step 2: Run tests and confirm the existing RMS gate fails for DC, white noise, and quiet speech**

Run: `cd desktop-macos && swift test --filter PCMTranscriptionSegmenterTests`

Expected: failures show non-speech segments are emitted and quiet speech is not reliably retained.

- [ ] **Step 3: Keep tests red until the gate implementation in Task 2**

### Task 2: Per-source adaptive speech gate

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Transcription/SpeechActivityGate.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Transcription/PCMTranscriptionSegmenter.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/PCMTranscriptionSegmenterTests.swift`

**Interfaces:**
- Produces: `SpeechActivityGate.consume(_:) -> SpeechGateUpdate`, `reset(discard:)`, `SpeechGateDiagnostics`, and `AudioSignalState` transitions.
- Consumes: mono 16 kHz `Int16` frames from the segmenter.

- [ ] **Step 1: Implement the minimum gate required by the failing tests**

```swift
struct SpeechGateConfiguration: Sendable {
    let frameDuration: TimeInterval
    let preRollDuration: TimeInterval
    let minimumSpeechDuration: TimeInterval
    let hangoverDuration: TimeInterval
    let openSNRDecibels: Double
    let closeSNRDecibels: Double
}

struct SpeechGateDiagnostics: Equatable, Sendable {
    var analyzedFrames = 0
    var acceptedSpeechFrames = 0
    var droppedSilenceFrames = 0
    var droppedNoiseFrames = 0
    var utterances = 0
}
```

Use 20 ms DC-removed frames, adaptive noise-floor EWMA, separate open and close margins, normalized pitch autocorrelation plus zero-crossing evidence to distinguish speech from steady white noise, 100 ms minimum speech, 200 ms pre-roll, and 300 ms hangover. Keep one gate and timeline anchor per `NativeAudioSource`.

- [ ] **Step 2: Verify quiet speech, brief bursts, chunk-boundary onsets, pre-roll, hangover, mixed sources, monotonic timing, and diagnostic counters**

Run: `cd desktop-macos && swift test --filter PCMTranscriptionSegmenterTests`

Expected: all segmenter tests pass with noise dropped and speech preserved.

### Task 3: Cancel stale Whisper work at lifecycle boundaries

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Transcription/LocalTranscriptionService.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/LocalTranscriptionServiceTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift`

**Interfaces:**
- Produces: injectable `LocalTranscriptionEngineFactory`, generation-tagged jobs, transition callback `onSignalState`, and stop semantics that cancel queued work before shutting down the engine.
- Consumes: finalized speech-only segments from Task 2.

- [ ] **Step 1: Write failing service tests with a controllable fake engine**

```swift
func testNoiseNeverReachesEngineOrPublishesTranscript() async throws
func testPauseDiscardsBufferedAndQueuedPreviewWithoutReplay() async throws
func testStopCancelsQueuedJobsAndIgnoresLateEngineResult() async throws
func testSpeechFromSurvivingSourceContinuesWhenPeerFails() async throws
```

- [ ] **Step 2: Implement generation-scoped queue draining**

Each start creates a generation token. Pause resets gate buffers and removes previews. Stop invalidates the generation, discards buffered input and pending jobs, clears callbacks before awaiting engine shutdown, and ignores any late result whose generation no longer matches. A normal speech gate close, not meeting stop, finalizes short utterances.

- [ ] **Step 3: Verify no hallucinated transcript, duplicate, replay, or phantom final callback**

Run: `cd desktop-macos && swift test --filter LocalTranscriptionServiceTests && swift test --filter NativeAudioRecoveryTests`

Expected: all lifecycle tests pass and stop completes without publishing late text.

### Task 4: Safe microphone-only Voice Processing

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Capture/MicrophoneCapture.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/MicrophoneVoiceProcessingTests.swift`

**Interfaces:**
- Produces: `MicrophoneVoiceProcessing.enableIfSupported(_:) -> Bool` with a protocol-backed test seam.
- Consumes: only the microphone `AVAudioInputNode`; system capture remains unchanged.

- [ ] **Step 1: Write failing fallback and idempotence tests**

```swift
func testVoiceProcessingIsRequestedBeforeTapInstallation()
func testUnsupportedVoiceProcessingFallsBackWithoutFailingMicrophoneCapture()
func testSystemAudioCaptureHasNoVoiceProcessingDependency()
```

- [ ] **Step 2: Enable AVAudioEngine Voice Processing before reading the microphone format**

Call `setVoiceProcessingEnabled(true)` on the microphone input node. Treat an unsupported or failed enable as a safe unprocessed fallback. Re-evaluate the format after the call, retain the existing permission and configuration-change recovery, and never touch `SystemAudioCapture`.

- [ ] **Step 3: Verify capture and packaging compatibility**

Run: `cd desktop-macos && swift test --filter MicrophoneVoiceProcessingTests && swift build -c release`

Expected: tests and release compilation pass without new entitlements or libraries.

### Task 5: Restrained source activity UI and compatibility coverage

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Domain/CaptureState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeAudioCaptureCoordinator.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/MeetingCapturePresentations.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/AudioPackagingCompatibilityTests.swift`

**Interfaces:**
- Produces: per-source `AudioSignalState.idle`, `speechDetected`, and `silenceFiltered` inside `AudioCaptureSnapshot`.
- Consumes: transition-only callbacks from Task 3.

- [ ] **Step 1: Write failing presentation and source-independence tests**

```swift
func testActiveSourceShowsSpeechDetectedOnlyOnGateTransition()
func testFilteredSourceShowsSilenceNotSentToTranscription()
func testMicrophoneSignalChangeDoesNotRelabelSystemSource()
func testBundleRetainsMicrophoneUsageDescriptionAndAudioInputEntitlement()
```

- [ ] **Step 2: Wire transition-only source state into existing badges**

Use `检测到语音` while the gate is open and `静音，未送入转写` after filtered silence. Reset to idle at pause, stop, failure, and new meeting. Do not add controls or per-frame UI updates.

- [ ] **Step 3: Run native focused and full validation**

Run: `cd desktop-macos && swift test`

Expected: the full Swift suite passes.

### Task 6: Release, companion, and real-audio verification

**Files:**
- Modify: `docs/audio-preprocessing-validation.md`
- Modify: `AGENTS.md` only if the audio gate becomes a durable project invariant

**Interfaces:**
- Consumes: all implementation outputs.
- Produces: fresh validation evidence and one clean local contributor commit.

- [ ] **Step 1: Run companion tests using the validated external interpreter without writing outside this worktree**

Run: `cd backend && PYTHONPATH="$PWD" /Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet/build/desktop-python/bin/python3 -m pytest -q`

- [ ] **Step 2: Run strict scoped checks, release build, package, and signing verification**

Run: `cd desktop-macos && swift test && swift build -c release`

Run: `./scripts/check-macos-package-inputs.sh`

Run: `PROMPTMEET_SKIP_WHISPER_BUILD=1 PROMPTMEET_SKIP_PYTHON_BUILD=1 ./scripts/build-macos-app.sh`

Run: `codesign --verify --deep --strict dist/PromptMeet.app`

- [ ] **Step 3: Repeat the signed-app walkthrough**

Verify silence, room noise, white noise, speech after silence, quiet speech, overlapping sources, pause/resume, stop, and a source failure. Confirm no noise transcript or downstream revision, preserved speech, prompt stop, monotonic timing, and restrained state labels.

- [ ] **Step 4: Ensure project memory and repository hygiene**

Run: `/Users/zilong/coding/firstmate/bin/fm-ensure-agents-md.sh .`

Run: `git status --short && git diff --check && git diff --stat 19bb25d`

- [ ] **Step 5: Commit only source, tests, and documentation**

```bash
git add AGENTS.md docs/audio-preprocessing-validation.md docs/superpowers/plans/2026-07-30-native-audio-denoise-vad.md desktop-macos/Sources desktop-macos/Tests
git commit -m "feat(macOS): add speech-aware audio preprocessing"
```
