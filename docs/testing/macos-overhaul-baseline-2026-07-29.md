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
