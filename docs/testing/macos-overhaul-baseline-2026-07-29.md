# macOS overhaul baseline reproduction

Date: 2026-07-29

Build under test: packaged `dist/PromptMeet.app` built from `f8cf5c2` in the isolated task worktree.

Environment: macOS with previously granted Screen Recording access, an installed local Whisper model, a configured OpenAI-compatible loopback endpoint, one large PromptMeet workspace window, and the native ScreenCaptureKit content picker. The protected picker surface is intentionally absent from screenshots and its controls are not exposed through the PromptMeet accessibility tree. Selection and cancellation were exercised with real pointer input, but the protected picker itself could not be visually inspected or addressed by accessibility element.

## Journey completed

The packaged app was launched, the workspace opened, the native picker opened and cancelled repeatedly, a meeting started, real system-audio transcript segments arrived, the microphone failed independently without stopping system audio, a window was selected, a screenshot was captured, multimodal analysis completed, suggestion generations were observed, a Markdown-rich question was asked and answered, recording paused and resumed, and the meeting ended.

## Reproduced defects

### Expanded island hit target differs from visible control

- Expected: the visible workspace button responds through its accessibility hit target at compact and expanded island sizes.
- Observed: the accessibility click was rejected as offscreen or had no effect while a coordinate click on the visible workspace button succeeded.
- Repeatability: 2 of 2 attempts on the expanded 760 by 300 island; the idle path succeeded once before expansion.
- Exact setup: packaged app, 1184-point display capture, live meeting, expanded island.
- Initiating trigger: select the accessibility workspace button after expanding the island.
- Masking condition: a direct coordinate click at the visibly rendered button bypasses the mismatch.
- Visible symptom: the control appears reachable but does not respond to its semantic click target.
- Proven path: the same closure opens the workspace when invoked by a coordinate click.
- History comparison: `9ab3a79` introduced the stable oversized island host and presentation geometry used at `f8cf5c2`.
- Smallest counterfactual: align the host's visible and interactive rectangles and settle the initiating click before presenting the system picker.
- Disconfirming evidence sought: other workspace controls responded normally through accessibility once the standard workspace window was key.

### Picker presentation can consume the initiating pointer sequence

- Expected: opening the picker waits until the initiating button click is complete, then allows an intentional selection.
- Observed: the first presentation immediately selected PromptMeet itself before a separate target click. Later presentations that were allowed to settle remained active until a deliberate outside click cancelled them.
- Repeatability: immediate selection on the first attempt; settled presentation remained active on two later attempts.
- Exact setup: workspace window visible, no previous target, native single-window picker.
- Initiating trigger: click `选择窗口`.
- Masking condition: waiting for the protected picker to settle before the next pointer action.
- Visible symptom: the selected label becomes `PromptMeet · PromptMeet` without a deliberate target choice.
- Proven path: later presentations stayed in selecting state and cancelled cleanly after a separate pointer action.
- History comparison: `ScreenCapturePicker.swift` presents synchronously inside the checked-continuation setup.
- Smallest counterfactual: defer `present()` to the next main-actor turn and scope callbacks to one presentation generation.
- Disconfirming evidence sought: repeated cancellation itself did restore the button, so the reusable-idle path is present when the callback arrives normally.

### Input timeline contains output-only events

- Expected: the left stream contains collected and derived meeting evidence only; user questions and AI answers remain in the right conversation.
- Observed: the left timeline rendered `你问`, `AI 回答`, and empty `猜你想问` cards alongside transcripts and screenshots.
- Repeatability: every question, answer, and suggestion generation appeared on the left.
- Exact setup: live meeting with transcript, one AI question, and repeated suggestion refreshes.
- Initiating trigger: completion of suggestion and conversation events.
- Masking condition: switching attention to the right AI panel hides neither the duplicated left events nor their scroll cost.
- Visible symptom: discussion output competes with chronological input and empty suggestion cards create large blank gaps.
- Proven path: durable conversation turns were already available and readable in the right panel.
- History comparison: `WorkspaceProjection` maps every timeline payload, including questions, answers, and suggestions, into left-side items.
- Smallest counterfactual: project output events only into conversation state while retaining them in the durable record.
- Disconfirming evidence sought: summary and screenshot-analysis events are generated evidence and belong on the left.

### Markdown syntax is rendered as plain text

- Expected: headings, emphasis, lists, quotes, inline and fenced code, and links receive Markdown styling in streaming and completed answers.
- Observed: literal `##`, `**`, `*`, `>`, backticks, and Markdown link syntax remained visible in the right conversation and left duplicated answer.
- Repeatability: 1 of 1 deliberately Markdown-rich answer, visible in both projections.
- Exact setup: question explicitly requested all supported Markdown constructs.
- Initiating trigger: final answer event.
- Masking condition: the separate AI reader uses Foundation Markdown for limited inline presentation, but the workspace uses plain `Text(answer)`.
- Visible symptom: raw syntax, weak hierarchy, dense spacing, and a fenced code block rendered as ordinary prose.
- Proven path: answer content remained selectable and copyable.
- History comparison: `WorkspaceView.answerText` passes the raw string directly to `Text`.
- Smallest counterfactual: parse stable Markdown blocks and render safe inline Markdown with a lenient streaming mode.
- Disconfirming evidence sought: accessibility preserved the full source text, so the defect is presentation rather than data loss.

### Failed or empty suggestions erase the useful surface and pollute the record

- Expected: exactly three last-known-good suggestions remain above the composer until three newer successful suggestions atomically replace them.
- Observed: each refresh persisted an empty suggestions event, produced a blank left timeline card, and left the right surface with only an empty-state sentence.
- Repeatability: every transcript-triggered generation during the meeting returned and stored an empty set.
- Exact setup: six system-audio transcript segments and one completed answer.
- Initiating trigger: debounced generation after each context update.
- Masking condition: a manually successful generation would temporarily show buttons, but loading and empty results can replace the state.
- Visible symptom: no usable suggested questions and repeated blank timeline cards.
- Proven path: historical meeting projection can restore a previously accepted non-empty suggestion set.
- History comparison: `MeetingState.questionsGenerated` and timeline ingestion assign the refreshed array even when it is empty; the backend persists all returned arrays.
- Smallest counterfactual: accept and persist only a deduplicated set of exactly three questions.
- Disconfirming evidence sought: generation IDs and context revisions correctly rejected stale generations.

### Screenshot status and capability disclosure are inconsistent

- Expected: screenshot capture transitions from capture to analysis and then to a completed, unsupported, or failed state naming provider, model, and degradation.
- Observed: a screenshot-analysis event completed with a response that explicitly said no pixels were available, while the toolbar continued to say `截图已保存，正在分析` after analysis and after meeting end.
- Repeatability: 1 of 1 screenshot.
- Exact setup: OpenAI-compatible loopback endpoint with custom model identifier and a real PNG captured from the selected PromptMeet window.
- Initiating trigger: screenshot upload and analysis completion.
- Masking condition: opening the timeline reveals the analysis payload, but the persistent toolbar status remains stale.
- Visible symptom: indefinite loading copy and no clear model-capability explanation at the action point.
- Proven path: the original PNG and analysis event were durably stored.
- History comparison: `MeetingStore.requestScreenshotNow` sets a success state and loading insight, but receipt of `screenshot_analysis` does not finish the operation; backend treats every OpenAI-compatible model as vision-capable.
- Smallest counterfactual: finish the local operation from the matching analysis event and make vision capability explicit per workflow.
- Disconfirming evidence sought: the backend already reports explicit degradation when an endpoint rejects images with a recognized error, but silent text-only compatibility is not detected.

### Meeting end leaves stale capture badges

- Expected: ending the meeting sets microphone and system-audio presentation to inactive without changing prior transcript attribution.
- Observed: the workspace became idle while source badges still displayed microphone failure and system audio as actively collecting.
- Repeatability: 1 of 1 meeting end.
- Exact setup: independent microphone runtime failure and active system audio before stop.
- Initiating trigger: `结束当前会议`.
- Masking condition: closing the workspace hides the stale badges.
- Visible symptom: contradictory `可继续整理` and `会议 · 采集中` status.
- Proven path: pause and resume states updated correctly before stop.
- History comparison: the coordinator resets its internal snapshot on stop but no final idle snapshot is published to `MeetingState`.
- Smallest counterfactual: explicitly reset the state snapshot after capture stop.
- Disconfirming evidence sought: recording activity itself correctly became inactive.

### Settings controls lose contrast in the fixed dark appearance

- Expected: labels and values remain readable in every settings pane.
- Observed: general-pane native picker values rendered near-black on the dark background.
- Repeatability: 1 of 1 general-pane inspection.
- Exact setup: fixed dark visual system, packaged app.
- Initiating trigger: open Settings.
- Masking condition: accessibility text exposes the values even when visual contrast is poor.
- Visible symptom: target display and interface language values are difficult to read.
- Proven path: text fields explicitly force a light field appearance and readable dark text.
- History comparison: general `Picker` controls do not receive the explicit appearance used by text fields.
- Smallest counterfactual: apply a consistent dark-compatible picker style or contained light field appearance.
- Disconfirming evidence sought: sidebar labels and ordinary text had acceptable contrast.

## Protected UI limitation

ScreenCaptureKit's system picker surface was excluded from screenshots and not exposed in the PromptMeet accessibility tree. The real presentation lifecycle, disabled/enabled app controls, pointer selection, and pointer cancellation were verified. Thumbnail geometry inside the protected picker could not be inspected pixel-for-pixel, and this report does not present preview-mode geometry as equivalent evidence.

## Final signed-build follow-up

Date: 2026-07-31

Build under test: signed packaged app from `c8f13c4` plus the final uncommitted integration fixes in the isolated task worktree.

### Idle workspace hides the effective microphone choice

- Expected: before capture begins, the workspace visibly states whether the next meeting will include the local microphone.
- Observed: the persisted opt-out was enforced at runtime, but the idle capture strip showed only `我 · 未启动` and `会议 · 未启动`.
- Repeatability: 2 of 2 idle workspace launches, including a real meeting where system audio continued and the microphone stayed unstarted without a permission prompt.
- Exact setup: signed packaged app, persisted local-microphone opt-out, companion healthy, no active meeting.
- Initiating trigger: open the workspace before starting a meeting.
- Masking condition: after capture starts, live source badges reveal which sources actually started.
- Visible symptom: the user cannot confirm the saved choice at the decision point before spending audio and AI resources.
- Proven path: `MeetingStore.nextMeetingCaptureDescription` already returned the exact truthful policy and the capture request received `includeLocalMicrophone = false`.
- History comparison: the typed preference and start-path routing were implemented, but the description was not consumed by any view.
- Smallest counterfactual: replace the two generic idle source badges with the existing next-meeting capture description.
- Disconfirming evidence sought: Settings already displayed the preference truthfully, confirming the problem was workspace projection rather than persistence.
- Regression proof: `WorkspaceLayoutTests.testIdleWorkspaceShowsTheEffectiveNextMeetingMicrophoneChoice` failed before the view change and passes after it.

### Ending a meeting leaves an active picker stuck

- Expected: ending or quitting while window selection is active dismisses the picker, returns the operation to idle, and permits a later selection.
- Observed: the meeting stored successfully, but `正在选择窗口` remained visible and both `选择窗口` and `截图` stayed disabled.
- Repeatability: 1 of 1 real signed-app meeting end while the protected picker was active, plus a deterministic store-level reproduction.
- Exact setup: live system-audio meeting, microphone opted out, no selected screenshot target, native single-window picker active.
- Initiating trigger: choose `选择窗口`, then end the meeting while the protected picker still owns the selection lifecycle.
- Masking condition: quitting and relaunching the process clears the in-memory selection state.
- Visible symptom: the completed meeting is reusable for Q&A, but window selection remains indefinitely unavailable.
- Proven path: ordinary system cancellation already returns `screenshotOperation` to idle when its callback arrives.
- History comparison: `endMeetingNow` stopped audio and persisted the session but did not cancel the independent screenshot continuation.
- Smallest counterfactual: give the screenshot controller an explicit cancellation path, finish the active picker generation, and reset `.selecting` during meeting end and shutdown.
- Disconfirming evidence sought: pause, resume, audio stop, storage, suggestions, and transcript durability all completed normally, isolating the defect to picker lifecycle ownership.
- Regression proof: `MeetingStoreCaptureLifecycleTests.testEndingMeetingCancelsActiveWindowSelectionAndReturnsToReusableIdle` failed with cancel count `0` and operation `selecting`, then passed with a successful second selection.

### Successful history retry leaves a stale failure insight

- Expected: once meeting history loads, any earlier transient history-unavailable message disappears without clearing unrelated meeting insight.
- Observed: the history rail contained real meetings while the AI panel still stated `历史会议暂时无法读取`.
- Repeatability: 2 of 2 cold signed-app launches where the workspace opened while the companion was still warming.
- Exact setup: signed packaged app, cold companion process, durable local meeting records, idle workspace.
- Initiating trigger: the initial history request fails transiently, then a later workspace-triggered request succeeds.
- Masking condition: opening the history rail proves the records are present, but does not remove the contradictory insight.
- Visible symptom: the interface simultaneously reports successful history content and a history-read failure.
- Proven path: `/api/meetings` returned the durable records and the native history list rendered them.
- History comparison: `meetingHistoryLoaded` replaced the record array but did not reconcile the exact error insight written by the prior request.
- Smallest counterfactual: successful history loading clears only the canonical history-unavailable insight.
- Disconfirming evidence sought: a non-history insight must survive the same history refresh.
- Regression proof: `MeetingStateTests.testSuccessfulHistoryReloadClearsOnlyItsStaleFailureMessage` failed before the reducer change and passes while preserving an unrelated insight.

The system picker remained absent from captured pixels and from the accessibility tree during this follow-up. Computer Use could verify app-side state and real pointer selection, but could not faithfully drive the protected Cancel control; automated Escape directed at PromptMeet is not treated as equivalent manual cancellation proof.

## Intermittent recording stall follow-up

Date: 2026-07-31

Build under test: the signed packaged app from `34998dd` in the isolated task worktree, before the performance changes.

### Long system-audio recording makes the workspace unresponsive

- Expected: a long system-audio-only meeting remains responsive while transcripts accumulate; pause, resume, text selection, and timeline scrolling complete without unbounded memory or CPU growth.
- Observed: after roughly seven minutes, a pause and resume attempt left the process alive but the workspace stopped answering accessibility queries. PromptMeet was pinned at 100 percent CPU, resident memory had grown from roughly 140 MB to 677 MB, and the live stack sample reported a 1.8 GB physical footprint.
- Repeatability: the high-frequency ingestion load was measured in two active-recording windows and stopped immediately on pause; the full UI stall occurred in the single sustained packaged reproduction.
- Exact setup: signed `dist/PromptMeet.app`, local microphone disabled, Screen Recording already authorized, `ggml-large-v3-turbo-q5_0.bin`, real ScreenCaptureKit system audio, a visible workspace, and sustained system speech output.
- Initiating trigger: allow consecutive system-audio transcript segments to accumulate in one live meeting, then pause and attempt to resume while the workspace is showing the input timeline.
- Masking condition: a short meeting or a collapsed workspace does not build a large selectable transcript block. Pausing early also stops the independent audio ingress load before it compounds the render cost.
- Visible symptom: controls stop responding, the accessibility driver times out, and the workspace no longer opens even though the app process remains alive.
- Proven path: the same package remained responsive with a short transcript. During the stalled run, the local Whisper process had continued publishing transcript events and became idle after pause, so model inference was not holding the main thread.
- History comparison: `cbe5891` introduced dense transcript grouping and an explicit regression expectation that 2,000 adjacent segments materialize as one block. The grouping window was measured only between consecutive segments, so continuous speech could extend a selectable SwiftUI `Text` indefinitely.
- Smallest counterfactual: keep speaker/source grouping but cap each projected selectable block at six segments and 4,096 characters. Preserve all segments in chronological order across the resulting lazy rows.
- Disconfirming evidence sought: a five-second process sample placed essentially all main-thread time in SwiftUI `SelectionOverlay`, `AttributeGraph`, and `WorkspaceView.timelineScrollContent` at `WorkspaceTimelineView.swift:289`, not in `WhisperServerEngine` or audio capture.
- Regression proof: `WorkspaceProjectionTests.testLargeAdjacentTranscriptRunUsesBoundedSelectableBlocks` and `testLongTranscriptTextStartsANewSelectableBlockBeforeCharacterCap` fail on the unbounded projection and pass with exact 2,000-segment coverage after the cap.

### Auxiliary loopback persistence writes every 20 ms frame separately

- Expected: low-latency local transcription may consume capture frames directly, while auxiliary loopback persistence uses bounded, efficient chunks and does not create unbounded request-task pressure.
- Observed: each 640-byte, 20 ms system frame became one HTTP request, one `.pcm` file, and one JSON sidecar. A three-second active sample added 323 files, about 108 file creations per second, while the app and companion each consumed sustained CPU even during non-speech intervals.
- Repeatability: file growth tracked active recording in both measured windows. The count remained exactly unchanged across a three-second pause while app CPU fell near 0.6 percent and companion CPU near 0.2 percent.
- Exact setup: the same system-audio-only packaged meeting, companion work directory under `~/Library/Application Support/PromptMeet/temp_sessions/native_audio`, and no repository copy of the generated PCM.
- Initiating trigger: ScreenCaptureKit emits normal 20 ms audio buffers after native capture starts.
- Masking condition: without inspecting the local work directory, the request and file amplification is hidden behind successful 200 responses. Fast storage can keep up temporarily.
- Visible symptom: elevated background CPU and filesystem churn increase the probability and severity of long-recording stalls, although the stack sample identifies transcript rendering as the immediate main-thread failure.
- Proven path: transcription already has an independent dispatcher lane, so upload delay does not need to gate the speech segmenter or Whisper.
- History comparison: `NativeAudioFrameDispatcher` previously created one chained upload task per raw frame, and `NativeAudioIngress` persisted every received packet as two sibling files.
- Smallest counterfactual: coalesce only the auxiliary upload lane into source-specific one-second PCM batches while delivering every raw frame to local transcription. Flush a pending batch before a source format change and discard incomplete auxiliary batches when a pause or stop invalidates the generation.
- Disconfirming evidence sought: pause stopped file growth but not the already rendered transcript cost, proving upload amplification and the UI stall are distinct boundaries that both need bounded behavior.
- Regression proof: `NativeAudioUploadBatcherTests` covers one-second coalescing and format isolation; `NativeAudioFrameDispatcherTests` proves all 50 raw frames still reach transcription while one upload is emitted and incomplete batches cannot cross a suspension.

The system speech stimulus overlapped unrelated system playback during this run, so the walkthrough proves capture, load, and responsiveness behavior but does not claim a controlled word-error-rate comparison.
