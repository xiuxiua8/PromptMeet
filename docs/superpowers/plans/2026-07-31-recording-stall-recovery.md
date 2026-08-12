# Recording Stall Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the reproduced long-recording UI stall and the avoidable per-frame loopback persistence load while preserving low-latency local transcription, source attribution, pause behavior, and the signed local-app review gate.

**Architecture:** Keep raw capture frames flowing directly to the local speech gate and Whisper engine, but coalesce only the auxiliary loopback upload lane into one-second source-specific PCM batches. Bound projected transcript blocks by both segment count and text size so selectable SwiftUI text never grows without limit. Keep local Whisper as the default transcription backend because the reproduced stall is in projection and loopback persistence, not model inference.

**Tech Stack:** Swift 6, SwiftUI/AppKit, ScreenCaptureKit, async Swift actors and tasks, XCTest, FastAPI companion, whisper.cpp.

## Global Constraints

- Work only on `fm/promptmeet-local-ux-overhaul` in the isolated treehouse worktree.
- Keep `/Users/zilong/coding/PromptMeet` read-only and prove its clean `f8cf5c2` state again at handoff.
- Never expose, serialize, log, or commit API keys or captured private audio.
- Do not push, create a PR, invoke no-mistakes, or start PR preparation in this phase.
- Preserve real Markdown selection, transcript source attribution, independent audio-source lifecycle, and pause invalidation.
- Keep cloud transcription absent unless current API capability, a credential path, and reproduced evidence all justify transmitting meeting audio.

---

### Task 1: Preserve the packaged reproduction evidence

**Files:**
- Modify: `docs/testing/macos-overhaul-baseline-2026-07-29.md`

**Interfaces:**
- Consumes: packaged `dist/PromptMeet.app`, companion log, native audio ingress artifacts, and a live process stack sample.
- Produces: a durable defect record with setup, trigger, expected and observed behavior, repeatability, masking conditions, counterfactual, and root-cause evidence.

- [x] **Step 1: Reproduce the packaged system-audio path before edits**

Start a microphone-disabled meeting in the signed package, play continuous system speech, keep the workspace visible, then pause and attempt to resume after several minutes.

- [x] **Step 2: Measure the failing path and smallest counterfactual**

Record that 20 ms, 640-byte frames produce about 50 loopback requests and about 100 `.pcm` plus `.json` file writes per second. Record that pause immediately stops file growth and drops process CPU near idle.

- [x] **Step 3: Capture root-cause evidence**

Record the app at 100 percent CPU with a 1.8 GB physical footprint and an unresponsive workspace. Preserve the stack finding that `SwiftUI.SelectionOverlay` and `WorkspaceView.timelineScrollContent` consume the main thread while one selectable transcript block contains an unbounded adjacent run.

- [ ] **Step 4: Add the evidence to the baseline report**

Append a concise follow-up section. Do not add captured meeting content, private screenshots, raw PCM, or credentials.

### Task 2: Bound selectable transcript projection

**Files:**
- Modify: `desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceProjection.swift`

**Interfaces:**
- Consumes: ordered transcript events and legacy `TranscriptLine` records.
- Produces: `WorkspaceProjection.items` whose transcript blocks remain speaker/source coherent but never exceed `WorkspaceTranscriptBlock.maximumSegmentCount` or `maximumCharacterCount`.

- [ ] **Step 1: Replace the incorrect large-run expectation with a failing bounded-block regression**

Use 2,000 one-second adjacent segments and assert:

```swift
XCTAssertGreaterThan(projection.items.count, 1)
XCTAssertTrue(
    projection.items.compactMap(\.transcriptBlock).allSatisfy {
        $0.segments.count <= WorkspaceTranscriptBlock.maximumSegmentCount
    }
)
XCTAssertEqual(
    projection.items.compactMap(\.transcriptBlock).flatMap(\.segments).count,
    2_000
)
```

- [ ] **Step 2: Run the regression and verify RED**

Run: `cd desktop-macos && swift test --filter WorkspaceProjectionTests/testLargeAdjacentTranscriptRunUsesBoundedSelectableBlocks`

Expected: FAIL because the current projection produces one 2,000-segment block.

- [ ] **Step 3: Implement bounded grouping**

Add explicit limits and make both timeline and legacy accumulators check the prospective segment:

```swift
static let maximumSegmentCount = 6
static let maximumCharacterCount = 4_096

static func canGroup(
    segments: [WorkspaceTranscriptSegment],
    nextSegment: WorkspaceTranscriptSegment
) -> Bool {
    guard segments.count < maximumSegmentCount,
          let previous = segments.last else { return false }
    let characterCount = segments.reduce(0) { $0 + $1.text.count } + nextSegment.text.count
    return characterCount <= maximumCharacterCount
        && canGroup(previousTimestamp: previous.timestamp, nextTimestamp: nextSegment.timestamp)
}
```

- [ ] **Step 4: Run the projection suite and verify GREEN**

Run: `cd desktop-macos && swift test --filter WorkspaceProjectionTests`

Expected: all projection tests pass, chronological segment coverage remains exact, and normal two-segment grouping remains unchanged.

- [ ] **Step 5: Commit the projection fix**

```bash
git add desktop-macos/Sources/PromptMeet/Views/WorkspaceProjection.swift \
  desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift
git commit -m "fix(macOS): bound live transcript rendering"
```

### Task 3: Coalesce the loopback audio upload lane

**Files:**
- Modify: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTestDoubles.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeAudioPipeline.swift`

**Interfaces:**
- Consumes: source-tagged `CapturedPCM` frames in capture order.
- Produces: `NativeAudioUploadBatcher.append(_:) -> [CapturedPCM]`, one-second source-specific auxiliary upload chunks, and unchanged per-frame delivery to `LocalTranscriptionServicing.consume(_:)`.

- [ ] **Step 1: Write failing batching and dispatcher regressions**

Add tests proving that fifty 20 ms system frames form one 32,000-byte upload, that the first frame supplies batch timing, that sources and formats never mix, and that transcription still receives every raw frame before upload completion.

- [ ] **Step 2: Run the regressions and verify RED**

Run: `cd desktop-macos && swift test --filter NativeAudioPipelineTests`

Expected: compilation or assertion failure because `NativeAudioUploadBatcher` and batched dispatcher behavior do not exist.

- [ ] **Step 3: Implement the minimal source-specific batcher**

Use a value type owned under `NativeAudioFrameDispatcher.lock`:

```swift
struct NativeAudioUploadBatcher {
    static let defaultDuration: TimeInterval = 1
    private var pendingBySource: [NativeAudioSource: PendingBatch] = [:]

    mutating func append(_ pcm: CapturedPCM) -> [CapturedPCM] {
        // Flush a pending batch before a source format change.
        // Emit when bytes reach sampleRate * channels * 2 * duration.
        // Preserve the first frame's capturedAt and meetingTime.
    }

    mutating func reset() {
        pendingBySource.removeAll(keepingCapacity: true)
    }
}
```

Only create an upload task when the batcher emits a completed chunk. Keep the independent transcription lane unchanged and reset incomplete auxiliary batches on pause or stop so stale data cannot cross generations.

- [ ] **Step 4: Run the audio pipeline suite and verify GREEN**

Run: `cd desktop-macos && swift test --filter 'NativeAudioPipelineTests|NativeAudioCoordinatorTests|NativeAudioLifecycleTests|NativeAudioRecoveryTests'`

Expected: all selected tests pass, upload count is reduced by about 50 times for 20 ms system frames, and pause/resume ordering remains intact.

- [ ] **Step 5: Commit the batching fix**

```bash
git add desktop-macos/Sources/PromptMeet/Capture/NativeAudioPipeline.swift \
  desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift \
  desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTestDoubles.swift
git commit -m "perf(macOS): coalesce native audio persistence"
```

### Task 4: Record the current speech backend decision

**Files:**
- Modify: `docs/macos-meeting-agent.md`
- Modify: `AGENTS.md` only if a core invariant materially changes

**Interfaces:**
- Consumes: current OpenAI SDK types generated from its OpenAPI specification, PromptMeet Keychain wiring, and reproduced local runtime evidence.
- Produces: a concise backend decision that names supported current API families and explains why no cloud backend was added in this fix.

- [ ] **Step 1: Record the capability inventory**

Document the current OpenAI transcription model families visible in the generated official SDK, including `gpt-transcribe`, `gpt-live-transcribe`, `gpt-realtime-whisper`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-transcribe-diarize`, and `whisper-1`. Note that diarization and realtime sessions solve different product needs.

- [ ] **Step 2: Record credential and privacy constraints**

Document that an OpenAI Keychain account path exists and is present without reading its value, while DeepSeek remains a text provider in the current architecture. Any cloud backend would require an explicit opt-in, visible audio-transmission disclosure, endpoint validation, failure isolation, and tests proving keys never enter meeting state.

- [ ] **Step 3: Keep local Whisper as the implemented default**

State that no cloud backend is added because the captured stall occurs in SwiftUI projection and local loopback persistence, local Whisper continued producing transcripts, and cloud transmission would add privacy, network, and availability dependencies without fixing the proven root cause.

- [ ] **Step 4: Commit documentation with the completed defect report**

```bash
git add docs/testing/macos-overhaul-baseline-2026-07-29.md docs/macos-meeting-agent.md AGENTS.md
git commit -m "docs: record recording stall evidence"
```

### Task 5: Verify the signed package and restore the local review gate

**Files:**
- Verify only: all changed Swift and documentation files
- Build artifact: `dist/PromptMeet.app` remains untracked

**Interfaces:**
- Consumes: committed fixes and cached whisper runtime.
- Produces: complete test, lint, release, package, signature, performance, real-app, GitHub-safety, and captain-checkout evidence.

- [ ] **Step 1: Run complete automated validation**

Run the full backend suite, full Swift suite, Black check, fatal-only flake8, strict SwiftLint, and release build using the authoritative commands and existing project configuration.

- [ ] **Step 2: Build and verify the signed package**

Run:

```bash
PROMPTMEET_SKIP_WHISPER_BUILD=1 ./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
```

Verify the microphone usage description and audio-input entitlement without exposing credentials.

- [ ] **Step 3: Re-run the real long-recording journey**

Launch the exact package, start with microphone disabled, exercise speech, silence, pause, resume, and stop, and inspect the input timeline at compact and large sizes. Verify the workspace remains responsive and selectable, memory stays bounded, and the companion receives roughly one audio upload per source per second rather than about fifty.

- [ ] **Step 4: Verify safety state**

Confirm the task worktree is clean, the captain checkout is still clean at `f8cf5c2`, the local app PID is recorded, no remote branch exists, and no PR exists.

- [ ] **Step 5: Append the mandatory local handoff and stop**

Append:

```text
paused: local app ready for captain testing at /Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet/dist/PromptMeet.app; no branch pushed and no PR created
```

Do not invoke no-mistakes or continue into PR preparation.
