# PromptMeet macOS Product Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a locally testable PromptMeet macOS app with reliable window selection, an input-left/output-right workspace, persistent suggestions, pause-aware summary milestones, optional microphone capture, and purpose-specific AI routing.

**Architecture:** Keep the version 2 meeting record as the durable source of truth. Add small typed domain services for Markdown blocks, automation milestones, capture preferences, and AI workflow configuration, then project durable events differently for input evidence and conversation output. Route each token-spending backend workflow through one validated provider configuration contract and store summary coverage metadata in append-only events.

**Tech Stack:** Swift 6, SwiftUI/AppKit, ScreenCaptureKit, AVAudioEngine, FastAPI, Pydantic 2, httpx, pytest, XCTest.

## Global Constraints

- Work only in the isolated task worktree and keep `/Users/zilong/coding/PromptMeet` read-only.
- API keys remain in Keychain or process environment and never enter serialized state, logs, responses, or ordinary UI values.
- Fixed dark appearance, loopback-only HTTP exceptions, atomic version 2 records, request-scoped Q&A, independent audio sources, and revisioned suggestions remain invariant.
- Add every behavior through a red-green-refactor test cycle.
- Do not push or create a PR before captain acceptance of the locally launched app.

---

### Task 1: Picker presentation and island hit geometry

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Capture/ScreenCapturePicker.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/IslandGeometry.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/IslandHostingView.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/ScreenCapturePickerTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/IslandGeometryTests.swift`

**Interfaces:**
- Produces: one presentation generation per picker attempt, deferred native presentation, idempotent callback completion, and one `interactiveRect` used by pointer tracking and hit testing.

- [ ] Write failing tests that cancellation restores idle state, repeated presentation reactivates the picker, duplicate presentation is rejected, stale generation callbacks are ignored, and large-host visible and interactive rectangles are identical.
- [ ] Run the focused XCTest filters and verify each new assertion fails for the missing generation and geometry contracts.
- [ ] Introduce a presentation-generation state machine and defer native `present()` until the initiating click completes.
- [ ] Use a single geometry function for tracking and `NSHostingView.hitTest`, keeping the physical-top anchor stable.
- [ ] Run focused picker and island tests, then the full Swift suite.

### Task 2: Input and output projection with Markdown

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Views/MarkdownDocument.swift`
- Create: `desktop-macos/Sources/PromptMeet/Views/MarkdownTextView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceProjection.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MarkdownDocumentTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift`

**Interfaces:**
- Produces: `MarkdownDocument.parse(_:mode:) -> [MarkdownBlock]` and an input-only `WorkspaceProjection.items`; consumes durable `ConversationTurn` values on the right.

- [ ] Write failing parser tests for headings, emphasis, lists, quotes, inline and fenced code, links, unfinished streaming fences, and long lines.
- [ ] Write failing projection tests proving questions, answers, and suggestions are excluded from the left while transcripts, screenshots, analyses, failures, summaries, and tasks stay chronological.
- [ ] Run focused tests and verify the raw-output behavior fails.
- [ ] Implement lenient block parsing with Foundation inline Markdown, safe HTTP(S) links, selectable text, code wrapping, and stable streaming treatment.
- [ ] Replace raw answer and generated-evidence text with the Markdown renderer; pin conversation scrolling and composer layout for compact and large windows.
- [ ] Run focused and full Swift tests and inspect workspace previews at compact and large sizes.

### Task 3: Atomic persistent suggestions

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/main_service.py`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`
- Test: `backend/tests/test_desktop_agent_service.py`
- Test: `backend/tests/test_meeting_lifecycle_e2e.py`

**Interfaces:**
- Produces: exactly-three successful suggestion batches; retains prior successful questions during loading, cancellation, failure, empty or malformed results; deduplicates context tokens.

- [ ] Write failing Swift tests for preservation through loading, empty, failure, cancellation, and atomic replacement by three newer questions.
- [ ] Write failing Python tests that only exactly-three normalized results are persisted and broadcast.
- [ ] Verify focused failures.
- [ ] Change context refresh to accept semantic tokens for transcript, screenshot analysis, summary/task, and answer updates; coalesce debounce without clearing display state.
- [ ] Make the backend prompt and result validator produce exactly three questions and skip persistence for unsuccessful batches.
- [ ] Move three understated suggestion buttons immediately above the composer, outside the conversation scroll view.
- [ ] Run focused and full Swift and Python suites.

### Task 4: Milestone summaries and auditable tasks

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Services/MeetingAutomationScheduler.swift`
- Create: `desktop-macos/Sources/PromptMeet/Services/MeetingPreferences.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingTimeline.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `backend/models/meeting_context.py`
- Modify: `backend/services/meeting_ingestion.py`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/main_service.py`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingAutomationSchedulerTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`
- Test: `backend/tests/test_meeting_lifecycle_e2e.py`
- Test: `backend/tests/test_meeting_repository.py`

**Interfaces:**
- Produces: `MeetingAutomationScheduler.advance(to:inputRevision:) -> MilestoneDecision`, `BackendClient.generateSummary`, and summary payload metadata `revision`, `source_event_ids`, `source_revision`, `trigger`, and `active_minutes`.

- [ ] Write failing scheduler tests for 5/10/every-5 defaults, 3-minute cadence, off, pause exclusion, no burst backfill, no double fire, and no call without new input.
- [ ] Write failing backend tests for cumulative source coverage, monotonically increasing revision, latest projection, historical audit, no-action, error, and retry.
- [ ] Verify focused failures.
- [ ] Implement the pure active-time scheduler and a cancellable one-second clock that only evaluates milestones.
- [ ] Replace the desktop legacy summary processor path with the unified structured AI request returning summary, tasks, key points, and decisions.
- [ ] Persist and decode coverage metadata, surface non-blocking loading/error/retry/no-action states, and retain all summary events on the input side.
- [ ] Add persisted Off/3/5/10 minute settings with 5 minutes as the default.
- [ ] Run focused and full Swift and Python suites.

### Task 5: Optional microphone capture

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingPreferences.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Capture/NativeAudioCaptureCoordinator.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/HoverMeetingCardView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/NativeAudioPipelineTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingCapturePreferences.includeMicrophone`; `NativeAudioCaptureCoordinating.start` consumes the effective source selection snapshot for the new meeting.

- [ ] Write failing tests that opt-out never starts the microphone source, never requests its permission, leaves it idle rather than failed, resumes only system audio, and does not relabel existing evidence.
- [ ] Verify focused failures.
- [ ] Persist the preference, snapshot it at meeting start, filter coordinator sources, and reset final capture state on stop.
- [ ] Show the effective next-meeting choice in Settings, idle island, and workspace start surface.
- [ ] Run focused and full Swift tests.

### Task 6: Unified per-workflow AI configuration

**Files:**
- Rewrite: `desktop-macos/Sources/PromptMeet/Services/AIProviderConfiguration.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/CompanionLauncher.swift`
- Modify: `backend/services/model_provider.py`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/services/meeting_ingestion.py`
- Test: `desktop-macos/Tests/PromptMeetTests/AIProviderConfigurationTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/CompanionRuntimeLocatorTests.swift`
- Test: `backend/tests/test_model_provider.py`
- Test: `backend/tests/test_desktop_agent_service.py`
- Test: `backend/tests/test_secret_hygiene.py`

**Interfaces:**
- Produces: `AIWorkflow` cases `conversation`, `suggestions`, `summaryTasks`, and `screenshotAnalysis`; provider endpoint preferences; per-workflow provider/model/capability selections; environment-only routing.

- [ ] Write failing migration tests from legacy provider/model keys to four workflow selections without secrets.
- [ ] Write failing validation tests for explicit DeepSeek and OpenAI-compatible endpoints, arbitrary non-empty model identifiers, exact chat paths, loopback HTTP, remote HTTPS, workflow-labeled results, and redaction.
- [ ] Write failing backend routing tests proving each workflow uses its selected provider, endpoint, model, and capability flag.
- [ ] Verify focused failures.
- [ ] Implement typed preferences and migration, preserving provider credentials in existing Keychain accounts.
- [ ] Build one Settings surface for both provider endpoints and four workflow rows, including explicit vision capability and truthful degradation copy.
- [ ] Export only credentials and typed non-secret configuration into the owned companion process environment.
- [ ] Wrap connection and runtime failures with provider, model, and workflow labels while redacting credentials.
- [ ] Run focused and full Swift and Python suites plus a bundle secret scan.

### Task 7: Visual quality, documentation, and local checkpoint

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `docs/macos-meeting-agent.md`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Produces: a signed packaged app and evidence that the captain checkout stayed unchanged.

- [ ] Fix stale screenshot and capture-end states and the settings picker contrast regression with focused tests where logic is extractable.
- [ ] Run deterministic workspace and reader previews, inspect compact and large windows, and repair clipping, overflow, scroll, focus, hit-target, spacing, empty-state, and contrast defects.
- [ ] Update durable schema, settings, routing, scheduling, and validation documentation without touching generated changelogs.
- [ ] Run Python formatting/lint, all 83+ backend tests, all 159+ Swift tests, release build, packaging, and strict signing verification.
- [ ] Build and launch the exact isolated `dist/PromptMeet.app`, record its PID and path, verify the captain checkout HEAD and porcelain match the baseline, and verify no remote branch or PR exists.
- [ ] Commit the cohesive implementation locally and append the required paused local-test handoff without invoking the no-mistakes pipeline.
