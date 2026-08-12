# PromptMeet Workspace and Island Density Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the low-density meeting input timeline with a compact chronological stream and make the recording island hug its content while keeping its primary controls stationary.

**Architecture:** Add a deterministic projection that groups only adjacent compatible transcript events, plus pure layout and scroll-follow models that can be verified without UI timing. Render the workspace and island from those models, using one permanent island control rail over both compact and expanded content so hover changes content bounds without changing button anchors.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, SwiftLint, Swift Package Manager.

## Global Constraints

- Stay in the isolated worktree and branch created from `19bb25d04898bce4461bdf9979df9b245139d96b`.
- Keep the fixed dark palette and existing mint, sky, amber, cobalt, and danger tokens.
- Do not change screenshot model routing, history title generation, Markdown parsing or rendering semantics, or audio denoising and VAD.
- Preserve version 2 event chronology, screenshot assets, source attribution, historical replay, text selection, and the window-picker interactive rectangle contract.
- Keep the provided visual reference read-only and never stage it.
- Add each behavior through a red-green-refactor cycle and make one clean contributor commit after fresh full verification.

---

### Task 1: Dense chronological projection

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceProjection.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift`

**Interfaces:**
- Produces: `WorkspaceTranscriptBlock`, `WorkspaceTranscriptSegment`, and grouped `WorkspaceProjection.items`.
- Contract: transcripts group only when adjacent in sorted event order, speaker and source match, and the next event occurs within 45 seconds. Any screenshot, analysis, summary, lifecycle event, source change, speaker change, or larger time gap closes the block.

- [ ] Add failing tests that assert same-speaker and same-source events within 45 seconds form one selectable text block with both segment IDs.
- [ ] Add failing tests that assert speaker changes, source changes, time gaps, and screenshots between segments produce separate chronologically ordered items.
- [ ] Run `cd desktop-macos && swift test --filter WorkspaceProjectionTests` and confirm failures are caused by the missing grouped transcript API.
- [ ] Implement transcript block accumulation while walking the existing sequence and timestamp sort once, retaining the first event ID and sequence plus the final event sequence for stable identity and follow tokens.
- [ ] Re-run `cd desktop-macos && swift test --filter WorkspaceProjectionTests` and confirm all projection tests pass.

### Task 2: Deterministic scroll-follow and workspace sizing

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Views/WorkspaceLayout.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/WorkspaceLayoutTests.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceTimelineView.swift`

**Interfaces:**
- Produces: `TimelineFollowState.contentDidChange() -> Bool`, `TimelineFollowState.update(bottomDistance:)`, `WorkspaceLayout.columnWidths(totalWidth:showsHistory:)`, and a stable timeline tail token.
- Contract: content changes scroll only in follow or programmatic-settle mode. Geometry more than 48 points from the bottom enters manual mode. An explicit resume returns to follow mode. Both columns remain above their minimum width at 980 and 1,440 point workspace sizes.

- [ ] Add failing pure tests for initial auto-follow, repeated rapid updates, manual scroll preservation, explicit resume, near-bottom re-entry, and compact and large column bounds with history hidden and shown.
- [ ] Run `cd desktop-macos && swift test --filter WorkspaceLayoutTests` and confirm the new test target fails because the models do not exist.
- [ ] Implement the pure models and replace count-only animated scrolling with a tail-token scroll that has no relayout animation and ignores updates in manual mode.
- [ ] Measure the bottom anchor in a named scroll coordinate space, update follow state from its distance to the viewport, and expose a labeled `自动跟随` or `回到最新` control.
- [ ] Re-run `cd desktop-macos && swift test --filter WorkspaceLayoutTests` and the projection tests.

### Task 3: Workspace hierarchy and dense timeline rendering

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceTimelineView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceAIView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceSummaryView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/VisualTokens.swift`

**Interfaces:**
- Consumes: grouped projection and adaptive workspace metrics from Tasks 1 and 2.
- Produces: labeled toolbar actions, flowing transcript rows, compact lifecycle rows, and restrained evidence surfaces for screenshots, analyses, failures, and summaries.

- [ ] Add layout assertions to `WorkspaceLayoutTests` for a 34 point minimum action height, non-negative remaining widths, and no clipping at 980 by 640 and 1,440 by 900.
- [ ] Run the focused tests and confirm the new hit-target and size assertions fail against the old metrics.
- [ ] Replace icon-only primary actions with compact labeled controls for window selection, screenshot, pause or resume, stop, new meeting, and settings while retaining labels for the AI, summary, and tasks tabs.
- [ ] Render transcript blocks as document-like rows with subtle time, speaker, and localized source labels, selectable wrapped text, translated text treatment, and no enclosing card.
- [ ] Render lifecycle events as thin inline status rows and retain modest bordered surfaces only for screenshot media, analyses, summaries, and failures. Keep screenshot thumbnails, unavailable states, source chips, and existing Markdown views intact.
- [ ] Reduce sidebar and column minimums according to `WorkspaceLayout` so history replay remains usable at the minimum workspace size.
- [ ] Re-run focused layout and projection tests, then `cd desktop-macos && swift test`.

### Task 4: Stable island geometry and control semantics

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Windows/IslandGeometry.swift`
- Create: `desktop-macos/Sources/PromptMeet/Views/IslandControlPresentation.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/IslandGeometryTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/IslandWindowControllerTests.swift`

**Interfaces:**
- Produces: a constant 520 point control rail, compact live height of 62 points, fixed control anchors and 32 point hit rectangles, and shortcut metadata for workspace, pause or resume, and quick ask.
- Contract: the workspace anchor, pause anchor, and quick-ask anchor are identical in host coordinates for idle, live, paused-equivalent, answering, hover, and quick-ask presentations. Expanded content surrounds that rail without moving it.

- [ ] Replace old geometry expectations with failing compact-height, fixed-anchor, hit-region, multiple-display, repeated-hover, and host-bound tests.
- [ ] Add failing tests for labels and keyboard shortcuts: workspace uses Command-Shift-M, pause or resume uses Command-Shift-Space, and quick ask uses Command-Shift-P.
- [ ] Run `cd desktop-macos && swift test --filter IslandGeometryTests` and `swift test --filter IslandWindowControllerTests`; confirm failures reflect the old 82 point height and presentation-relative controls.
- [ ] Implement anchor and hit-rectangle calculations centered on the permanent control rail, keeping `interactiveRect` exactly equal to `visibleRect` for the prior picker hit-geometry guarantee.
- [ ] Implement typed control labels and shortcuts and re-run the focused tests.

### Task 5: One permanent island control rail

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/IslandRootView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/HoverMeetingCardView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/RollingCaptionView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/IslandHostingView.swift`

**Interfaces:**
- Consumes: stable anchors and control metadata from Task 4.
- Produces: one persistent top control rail shared by compact and expanded content.

- [ ] Add pointer assertions that each geometry hit rectangle lies inside the hosting view interactive rectangle for compact, expanded, small-display, and large-target-window cases.
- [ ] Run the focused island tests and confirm the assertions fail until the permanent rail geometry is used.
- [ ] Move workspace or capture-status, pause or resume, and quick-ask buttons into one overlay that is never conditionally replaced. Give each a 32 by 32 point content shape, accessibility label, help text, and declared keyboard shortcut.
- [ ] Make the left waveform or status indicator a button that opens the workspace. Keep empty pause space reserved when pause is unavailable so the quick-ask anchor does not shift.
- [ ] Place the compact caption in a 27 point content band below the top rail and remove expanding spacers so one wrapped rolling line fits within the 62 point live island.
- [ ] Remove the expanded card header that previously replaced the compact controls and lay transcript, capture status, labeled meeting actions, AI insight, suggestions, and composer below and around the permanent rail.
- [ ] Re-run focused geometry, window, meeting-state, and transcript formatter tests.

### Task 6: Synthetic previews and complete verification

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingStatePreview.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/AppDelegate.swift`
- Modify: `AGENTS.md` only if the validation or preview commands materially change.

**Interfaces:**
- Produces: deterministic mixed-event workspace, live, paused, hover, and quick-ask preview modes with no capture permissions or private meeting data.

- [ ] Add failing state tests proving preview modes select live, paused, hover, and quick-ask states without modifying capture or persistence behavior.
- [ ] Populate the workspace preview with synthetic same-speaker groups, a source change, lifecycle event, screenshot state, analysis, failure, and summary so every timeline treatment can be inspected.
- [ ] Run `cd desktop-macos && swift test` and confirm zero failures.
- [ ] Run strict scoped lint with `swiftlint lint --strict` over every changed Swift source and test file and repair every reported issue.
- [ ] Run `cd desktop-macos && swift build -c release` and confirm exit 0.
- [ ] Run `PROMPTMEET_SKIP_WHISPER_BUILD=1 ./scripts/build-macos-app.sh` and `codesign --verify --deep --strict dist/PromptMeet.app` and confirm both exit 0.
- [ ] Launch only this worktree's synthetic preview modes, capture untracked workspace and island images, inspect compact and large workspace sizes plus multiple display bounds, and stop only the preview process started for each inspection.
- [ ] Verify `git status --short`, `git diff --check`, the reference screenshot exclusion, no generated bundle or preview assets staged, and no changes in forbidden domains.
- [ ] Commit all source, test, and plan changes once with a contributor-focused message and report the full SHA.
