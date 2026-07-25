# Modern Meeting Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the macOS meeting agent around a durable, meeting-scoped multimodal timeline that supports live and historical questions without cross-meeting leakage.

**Architecture:** The Python companion owns the versioned durable meeting record, event ingestion, context selection, prompt construction, and provider access. The Swift app owns capture and presentation, projects typed backend events into a timeline, and reconnects to retained meetings for historical questions. Assets use durable relative references under the local PromptMeet data directory, while API keys remain exclusively in macOS Keychain and process memory.

**Tech Stack:** Python 3.12, FastAPI, Pydantic 2, httpx, pytest, Swift 6, SwiftUI, AppKit, ScreenCaptureKit, XCTest, macOS Keychain.

## Global Constraints

- Never use an em dash in project text.
- Preserve every ported captain change and the untracked `build-app.sh` intent.
- Keep secrets in macOS Keychain only and never serialize or log raw keys.
- Use an explicit context token budget, stable chronology, relevance plus recency, and evidence source IDs.
- Retain and migrate legacy records without silently discarding malformed or incomplete data.
- Add production behavior only after the corresponding regression test has failed for the expected reason.
- Produce one clean implementation commit on `fm/promptmeet-modern-context` after complete verification.

---

### Task 1: Versioned meeting timeline and repository

**Files:**
- Create: `backend/models/meeting_context.py`
- Create: `backend/services/meeting_repository.py`
- Test: `backend/tests/test_meeting_repository.py`

**Interfaces:**
- Produces: `MeetingRecord`, `MeetingEvent`, typed event payload models, and `MeetingRepository`.
- `MeetingRepository.create(meeting_id, started_at) -> MeetingRecord`
- `MeetingRepository.append(meeting_id, event) -> MeetingRecord`
- `MeetingRepository.get(meeting_id) -> MeetingRecord | None`
- `MeetingRepository.list() -> list[MeetingRecord]`
- `MeetingRepository.finish(meeting_id, ended_at, status) -> MeetingRecord`

- [ ] **Step 1: Write migration, ordering, isolation, incomplete, and corrupt-record tests**

```python
def test_append_assigns_stable_sequence_and_never_crosses_meetings(tmp_path):
    repository = MeetingRepository(tmp_path)
    repository.create("a", START)
    repository.create("b", START)
    repository.append("a", MeetingEvent.transcript("one", START))
    assert [event.sequence for event in repository.get("a").events] == [1]
    assert repository.get("b").events == []

def test_legacy_desktop_sessions_are_migrated_without_removing_source(tmp_path):
    legacy = tmp_path / "desktop-sessions.json"
    legacy.write_text(json.dumps({"legacy": LEGACY_SESSION}), encoding="utf-8")
    records = MeetingRepository(tmp_path).list()
    assert records[0].schema_version == 2
    assert legacy.exists()
```

- [ ] **Step 2: Run `../build/desktop-python/bin/python3 -m pytest tests/test_meeting_repository.py -q` and verify the missing modules fail the tests**
- [ ] **Step 3: Implement Pydantic event payloads and atomic per-meeting JSON persistence**

```python
class MeetingEvent(BaseModel):
    event_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    meeting_id: str = ""
    sequence: int = 0
    occurred_at: datetime
    kind: EventKind
    provenance: EventProvenance
    payload: EventPayload

class MeetingRecord(BaseModel):
    schema_version: Literal[2] = 2
    meeting_id: str
    status: MeetingStatus = MeetingStatus.ACTIVE
    started_at: datetime
    ended_at: datetime | None = None
    events: list[MeetingEvent] = Field(default_factory=list)
```

- [ ] **Step 4: Run the focused repository tests and verify they pass**

### Task 2: Budgeted context assembly, prompts, and providers

**Files:**
- Create: `backend/services/context_builder.py`
- Create: `backend/services/prompt_builder.py`
- Create: `backend/services/model_provider.py`
- Modify: `backend/services/desktop_agent_service.py`
- Test: `backend/tests/test_context_builder.py`
- Test: `backend/tests/test_model_provider.py`
- Modify: `backend/tests/test_desktop_agent_service.py`

**Interfaces:**
- Consumes: `MeetingRecord` and current `question_event_id`.
- Produces: `ContextSelection(events, sources, estimated_tokens, omitted_count, derived_summary)`.
- `MeetingContextBuilder.select(record, question, budget) -> ContextSelection`
- `MeetingPromptBuilder.messages(selection, question, capabilities) -> list[ProviderMessage]`
- `ModelProvider.stream_answer(request, emit) -> ProviderResult`

- [ ] **Step 1: Write tests for relevance, recency, token ceilings, stable source ordering, old-evidence compression, vision degradation, and exact user questions**

```python
def test_selector_obeys_budget_and_keeps_relevant_visual_evidence():
    selection = MeetingContextBuilder(token_estimator=len).select(
        RECORD_WITH_OLD_TRANSCRIPT_AND_SCREENSHOT,
        "截图中的回滚负责人是谁？",
        ContextBudget(total_tokens=240, answer_reserve=80),
    )
    assert selection.estimated_tokens <= 160
    assert [source.source_id for source in selection.sources] == sorted(
        source.source_id for source in selection.sources
    )
    assert any(event.kind == EventKind.SCREENSHOT for event in selection.events)

def test_text_only_provider_discloses_that_image_pixels_were_not_seen():
    messages = MeetingPromptBuilder().messages(SELECTION_WITH_IMAGE, "风险？", TEXT_ONLY)
    assert "提供方不支持图像输入" in messages[1].content
    assert messages[-1].content == "风险？"
```

- [ ] **Step 2: Run focused tests and verify expected missing-interface failures**
- [ ] **Step 3: Implement pure selection and prompt builders with no global conversation state**
- [ ] **Step 4: Implement provider capability metadata, OpenAI image parts, DeepSeek text-only disclosure, and request-scoped streaming**
- [ ] **Step 5: Refactor `DesktopAgentService` to orchestrate repository, selector, prompt builder, and provider without concatenating an ever-growing prompt**
- [ ] **Step 6: Run context, provider, and desktop agent tests and verify they pass**

### Task 3: Durable ingestion, screenshot assets, and concurrent live or historical questions

**Files:**
- Create: `backend/services/meeting_ingestion.py`
- Modify: `backend/api/native_screenshot.py`
- Modify: `backend/main_service.py`
- Modify: `backend/services/desktop_storage.py`
- Modify: `backend/tests/test_native_screenshot_router.py`
- Modify: `backend/tests/test_desktop_ai_websocket.py`
- Create: `backend/tests/test_meeting_lifecycle_e2e.py`
- Modify: `backend/tests/test_secret_hygiene.py`

**Interfaces:**
- Consumes: session creation, transcript, screenshot upload, analysis, summary, question, and answer callbacks.
- Produces: durable event appends and websocket events named `meeting_event`.
- `POST /api/meetings/{meeting_id}/questions` accepts `request_id`, `thread_id`, and exact `question`.
- `GET /api/meetings` and `GET /api/meetings/{meeting_id}` return schema version 2 records.
- `/ws/{meeting_id}` accepts retained meetings even when no recording process is active.

- [ ] **Step 1: Write an API-level fake-provider test covering create, transcript, screenshot, ask, end, restart repository, reopen, and follow-up**

```python
def test_full_multimodal_meeting_survives_restart_and_accepts_follow_up(client_factory):
    first = client_factory()
    meeting_id = first.post("/api/sessions").json()["session_id"]
    first.post(f"/api/sessions/{meeting_id}/native-transcript", json=TRANSCRIPT)
    first.post(f"/api/sessions/{meeting_id}/native-screenshot", content=PNG, headers={"Content-Type": "image/png"})
    first.post(f"/api/sessions/{meeting_id}/stop-native-recording")
    second = client_factory(restart=True)
    response = second.post(
        f"/api/meetings/{meeting_id}/questions",
        json={"request_id": "r2", "thread_id": "main", "question": "谁负责回滚？"},
    )
    assert response.status_code == 200
    assert second.get(f"/api/meetings/{meeting_id}").json()["events"][-1]["kind"] == "assistant_answer"
```

- [ ] **Step 2: Run the lifecycle test and verify persistence and historical Q&A assertions fail**
- [ ] **Step 3: Wire repository creation and lifecycle events into session routes**
- [ ] **Step 4: Persist screenshot bytes under `assets/<meeting_id>/`, append preview metadata immediately, then append analysis or failure as a separate event**
- [ ] **Step 5: Schedule each question in its own task, snapshot its meeting-scoped context, correlate by request ID, and persist final answers plus source references**
- [ ] **Step 6: Keep `/db/sessions` as a legacy projection backed by the new repository**
- [ ] **Step 7: Run backend tests and verify no raw secret appears in responses, storage, captured logs, or websocket payloads**

### Task 4: Swift timeline domain, backend client, and meeting lifecycle

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Domain/MeetingTimeline.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/StoredMeeting.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/BackendEvent.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/BackendEventTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingTimelineEvent`, `ScreenshotAsset`, `ConversationTurn`, and `EvidenceSource` as `Codable`, `Identifiable`, and `Sendable` where appropriate.
- `BackendClient.fetchMeeting(id:)`, `fetchMeetingHistory()`, and `ask(meetingID:question:requestID:threadID:)`.
- `MeetingStore.startNewMeetingNow()` rejects replacement while live and resets all meeting-scoped state before creating another meeting.

- [ ] **Step 1: Write Swift tests for version 2 parsing, legacy parsing, missing assets, failed analyses, rapid answers, historical selection, historical ask, and active-meeting replacement protection**

```swift
func testConcurrentAnswersRemainBoundToTheirOwnTurns() {
    var state = MeetingState()
    let first = UUID()
    let second = UUID()
    state.reduce(.userPromptSubmitted(id: first, prompt: "风险？"))
    state.reduce(.userPromptSubmitted(id: second, prompt: "负责人？"))
    state.reduce(.answerDelta(requestID: first, delta: "范围"))
    state.reduce(.answerFinal(requestID: second, answer: "林晨"))
    XCTAssertEqual(state.turn(id: first)?.answer, "范围")
    XCTAssertEqual(state.turn(id: second)?.answer, "林晨")
}
```

- [ ] **Step 2: Run focused Swift tests and verify the absent timeline APIs fail compilation**
- [ ] **Step 3: Implement typed decoding and deterministic projections from timeline to transcript, screenshots, conversations, and summary**
- [ ] **Step 4: Change startup ordering to establish the durable backend meeting before capture, mark incomplete capture failures, and retain a safe offline transcript path**
- [ ] **Step 5: Connect selected historical meetings for Q&A and merge refreshed durable records without replacing active-meeting state**
- [ ] **Step 6: Run all Swift domain and store tests and verify they pass**

### Task 5: Conversation workspace, multimodal replay, and new meeting entry point

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/AIReaderView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/HoverMeetingCardView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/QuickAskField.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/VisualTokens.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/WorkspaceWindowController.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/WorkspaceProjectionTests.swift`

**Interfaces:**
- Consumes: the selected `MeetingState` timeline projection.
- Produces: history navigation, chronological screenshot cards, transcript cards, source chips, conversation turns, loading/error/retry states, copyable text, and `开始新会议`.

- [ ] **Step 1: Write projection tests for chronological mixed events, empty meetings, missing screenshot files, error retry metadata, and active-meeting confirmation state**
- [ ] **Step 2: Run focused tests and verify missing projection types fail**
- [ ] **Step 3: Implement a scrollable timeline and conversation column with selectable completed answers and stable streaming cards**
- [ ] **Step 4: Render screenshot thumbnails from durable local asset URLs, with explicit missing-file and failed-analysis cards**
- [ ] **Step 5: Add a prominent `开始新会议` toolbar action and a confirmation dialog only when a meeting is active**
- [ ] **Step 6: Add keyboard focus, submit, retry, copy, and source/context affordances with accessibility labels**
- [ ] **Step 7: Build and visually inspect 1100 by 720 and minimum 980 by 640 windows in light and dark appearances**

### Task 6: Provider settings and secret lifecycle

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Services/AIProviderConfiguration.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/KeychainStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/CompanionLauncher.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/PromptMeetSettingsView.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/AIProviderConfigurationTests.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/KeychainStoreTests.swift`

**Interfaces:**
- Produces: provider capability descriptors, allowed model lists, transient validation, add/update/remove operations, and masked configured status.
- `KeychainStoring` exposes read, write, and delete but no enumerable secret-bearing app state.
- `AIProviderValidator.validate(provider:key:model:)` returns only capability and success/error metadata.

- [ ] **Step 1: Write tests proving keys are trimmed, never written to defaults, removed on request, absent from descriptions, and paired only with supported models**
- [ ] **Step 2: Run focused tests and verify the new service types are missing**
- [ ] **Step 3: Implement provider descriptors with truthful text and vision capabilities**
- [ ] **Step 4: Implement masked configured states, update/remove controls, inline validation results, and capability explanations**
- [ ] **Step 5: Ensure companion environment construction reads secrets directly from Keychain into the child process environment and never publishes them**
- [ ] **Step 6: Run settings, keychain, and secret hygiene tests**

### Task 7: Packaging, documentation, and project memory

**Files:**
- Force-add: `backend/requirements-desktop.txt`
- Force-add: `desktop-macos/THIRD_PARTY_NOTICES.md`
- Modify: `README.md`
- Create: `docs/macos-meeting-agent.md`
- Create or modify: `AGENTS.md`

**Interfaces:**
- Produces: reproducible build, test, and E2E commands plus a concise architecture and migration reference.

- [ ] **Step 1: Add a packaging regression check that asserts every referenced bundle input exists**
- [ ] **Step 2: Verify `./build-app.sh` fails before restoring the ignored required files and succeeds after they are tracked**
- [ ] **Step 3: Document the version 2 schema, local asset layout, provider capabilities, fake-provider test command, and migration behavior**
- [ ] **Step 4: Run `/Users/zilong/coding/firstmate/bin/fm-ensure-agents-md.sh .` and record only durable commands and authoritative pointers**

### Task 8: Full verification and visual walkthrough

**Files:**
- Modify only files surfaced by verification before the final commit.

**Interfaces:**
- Consumes: complete implementation.
- Produces: fresh test, build, UI, source-integrity, and git evidence.

- [ ] **Step 1: Run `../build/desktop-python/bin/python3 -m pytest -q` from `backend`**
- [ ] **Step 2: Run `swift test` and `swift build -c release` from `desktop-macos`**
- [ ] **Step 3: Run `./build-app.sh` and `codesign --verify --deep --strict dist/PromptMeet.app`**
- [ ] **Step 4: Run the real app with local fake transcription and provider services, then complete start, transcript, screenshot, ask, end, relaunch, history, and follow-up**
- [ ] **Step 5: Inspect screenshots at realistic and minimum sizes in dark and light appearances, and repair every meaningful layout or accessibility defect found**
- [ ] **Step 6: Compare the captain checkout porcelain snapshot byte-for-byte with the original snapshot**
- [ ] **Step 7: Run `git diff --check`, inspect the entire scoped diff, and commit one clean implementation commit without co-author metadata**

## Self-Review

- Spec coverage: all five product outcome sections map to Tasks 1 through 8.
- Placeholder scan: no deferred implementation markers or unspecified error handling remain.
- Type consistency: the backend schema version 2 event types map directly to Swift timeline event types, and request IDs are the shared concurrency boundary.
- Execution choice: inline execution is required because the launch brief says to work independently and the active collaboration rules prohibit delegation.
