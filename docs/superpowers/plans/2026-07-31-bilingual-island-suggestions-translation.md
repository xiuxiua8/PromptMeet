# Compact Bilingual Island, Timely Suggestions, and Durable Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a compact bilingual recording island with a horizontal adaptive subtitle ticker, prevent transcript churn from repeatedly cancelling useful suggested-question generations, and make successful translations survive meeting history reload.

**Architecture:** Model the island caption and ticker motion as deterministic domain values, then render a single-line SwiftUI marquee only when measured content overflows. Split suggestion debounce work from in-flight generation work so one request can finish while newer revisions coalesce into one follow-up. Enrich the existing version 2 transcript event atomically by `segment_id` before broadcasting the live translation side channel, preserving event identity and avoiding duplicate evidence.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Python 3.12, FastAPI, Pydantic v2, pytest, atomic JSON meeting records, macOS codesign.

## Global Constraints

- Work only in `/Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet` on `fm/promptmeet-local-ux-overhaul` and preserve all current commits.
- Keep `/Users/zilong/coding/PromptMeet` read-only and prove its HEAD and porcelain status remain unchanged.
- Use test-driven development with observed red and green runs for every behavior change.
- Do not push, create a PR, invoke no-mistakes, or mutate credentials and private meeting evidence.
- Preserve stable island control anchors and complete 32 point hit regions at realistic host sizes.
- Keep exactly three last-good suggestions visible until a newer successful set replaces them.
- Keep the original transcript immutable when translation fails; successful translation enriches the matching event without adding a second transcript event.

## Reproduction record

- **Compact island:** Expected a restrained single-line recording surface that uses horizontal motion only when needed and shows original plus translated text. Observed the signed app rendering a 520 by 62 point island with controls on one row and a vertical `ScrollView` on a second row; the latest long English line was clipped at the right edge. Repeats whenever the workspace is closed during an active meeting with a long transcript. Trigger is a final or partial transcript longer than the viewport. Opening the workspace masks the island symptom. Visible symptom is one original-language line with no translation and no horizontal continuation.
- **Suggested questions:** Expected the first useful set to complete despite later transcript arrivals, followed by at most one refresh for the newest revision. Observed accepted sets 12.509, 15.967, and 17.239 seconds after the most recent preceding transcript context in meeting `c10d4fcf-0b73-4267-81fc-120a14c60aea`. Repeats during continuous speech. A quiet gap masks it by allowing one request to finish. Source tracing shows `scheduleSuggestionRefresh` cancels the task that is already awaiting the HTTP generation request, so each new transcript restarts useful model work.
- **Historical translation:** Expected successful live translation to appear in the island and remain after reopening the meeting. Observed 17 transcript events and zero durable `translated_text` values while translation was enabled; historical selection displays only original text. Repeats for every translated segment on the current path. Provider failure can mask the persistence defect because no successful translation exists to save. Source tracing shows the original event is written first and `translate_native_transcript` later broadcasts only `transcript_translation`, never updating the record.
- **Proven paths and disconfirming evidence:** Live translation side-channel reduction already attaches text to the matching in-memory `TranscriptLine`, version 2 decoding already accepts `translated_text`, and legacy migration already preserves it. Existing suggestion generation identity checks prevent a response from an actually replaced generation from winning. Therefore the missing behaviors are bounded to caption projection, in-flight scheduling, and durable enrichment rather than provider routing or schema migration.

---

### Task 1: Deterministic bilingual caption and horizontal ticker

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Views/SubtitleTickerMetrics.swift`
- Create: `desktop-macos/Sources/PromptMeet/Views/SubtitleTickerView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Domain/MeetingStatePreview.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/RollingCaptionView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/IslandRootView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/IslandGeometry.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/IslandGeometryTests.swift`

**Interfaces:**
- Consumes: `TranscriptLine.text`, `TranscriptLine.translatedText`, `MeetingState.activeTranscript`, and the stable island control rail.
- Produces: `IslandCaption(original:translation:)`, `SubtitleTickerMetrics.offset(elapsed:contentWidth:viewportWidth:)`, and a compact single-line `SubtitleTickerView(originalText:translatedText:)`.

- [ ] **Step 1: Write failing bilingual projection and ticker tests**

```swift
func testIslandCaptionKeepsOriginalAndLatestTranslationTogether() {
    var state = MeetingState()
    let id = UUID()
    state.reduce(.transcriptFinal(TranscriptLine(id: id, speaker: "会议", text: "Hello team")))
    state.reduce(.transcriptTranslated(id: id, text: "大家好"))
    XCTAssertEqual(state.islandCaption, IslandCaption(original: "Hello team", translation: "大家好"))
}

func testTickerStaysLeadingWhenContentFitsAndLoopsWithinOneTravelDistance() {
    XCTAssertEqual(SubtitleTickerMetrics.offset(elapsed: 20, contentWidth: 180, viewportWidth: 220), 0)
    let offset = SubtitleTickerMetrics.offset(elapsed: 5, contentWidth: 420, viewportWidth: 220)
    XCTAssertLessThanOrEqual(offset, 0)
    XCTAssertGreaterThan(offset, -(420 + SubtitleTickerMetrics.loopGap))
}
```

- [ ] **Step 2: Run the focused Swift tests and verify red**

Run: `cd desktop-macos && swift test --filter 'MeetingStateTests|IslandGeometryTests'`

Expected: FAIL because `islandCaption` and `SubtitleTickerMetrics` do not exist and the current live size is 520 by 62.

- [ ] **Step 3: Implement deterministic projection, compact geometry, and adaptive marquee**

```swift
struct IslandCaption: Equatable {
    let original: String
    let translation: String?
}

enum SubtitleTickerMetrics {
    static let pointsPerSecond: CGFloat = 30
    static let leadingPause: TimeInterval = 1
    static let loopGap: CGFloat = 42

    static func offset(elapsed: TimeInterval, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard contentWidth > viewportWidth else { return 0 }
        let travel = contentWidth + loopGap
        let moving = max(0, elapsed - leadingPause)
        return -CGFloat(moving * pointsPerSecond).truncatingRemainder(dividingBy: travel)
    }
}
```

Render original and translation as separately styled text in one measured row, duplicate the row only while it overflows, mask the viewport edges, reset the cycle when caption identity changes, disable hit testing, and expose one combined accessibility label. Set the compact rail to 460 points and live height to 54 points while retaining the 32 point hit areas and fixed anchors.

- [ ] **Step 4: Run focused Swift tests and verify green**

Run: `cd desktop-macos && swift test --filter 'MeetingStateTests|IslandGeometryTests'`

Expected: PASS with bilingual projection, bounded ticker motion, compact geometry, and stable control anchors.

- [ ] **Step 5: Commit the island task**

```bash
git add desktop-macos/Sources/PromptMeet/Domain/MeetingState.swift \
  desktop-macos/Sources/PromptMeet/Domain/MeetingStatePreview.swift \
  desktop-macos/Sources/PromptMeet/Views/IslandRootView.swift \
  desktop-macos/Sources/PromptMeet/Views/RollingCaptionView.swift \
  desktop-macos/Sources/PromptMeet/Views/SubtitleTickerMetrics.swift \
  desktop-macos/Sources/PromptMeet/Windows/IslandGeometry.swift \
  desktop-macos/Tests/PromptMeetTests/MeetingStateTests.swift \
  desktop-macos/Tests/PromptMeetTests/IslandGeometryTests.swift
git commit -m "feat(macos): add compact bilingual subtitle ticker"
```

### Task 2: Coalesce suggested-question revisions without cancelling useful work

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStoreAI.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStoreLifecycle.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/MeetingStoreCommands.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingStoreTestDoubles.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingStoreSuggestionTests.swift`

**Interfaces:**
- Consumes: meeting-scoped context tokens, monotonically increasing context revisions, backend generation identity, and persisted suggestion events.
- Produces: separate `suggestionDebounceTask` and `suggestionGenerationTask` lifecycles plus one `pendingSuggestionRevision` that always represents the newest coalesced context.

- [ ] **Step 1: Write failing controlled scheduling tests**

```swift
func testTranscriptChurnDoesNotCancelUsefulInFlightSuggestionGeneration() async throws {
    let backend = BackendClientSpy()
    backend.questionDelay = .milliseconds(40)
    // Start revision 1, then emit revisions 2 through 4 while it is running.
    // Assert request revisions are [1, 4], completed count is 2, and cancellation count is 0.
}

func testInFlightSuggestionSetIsAcceptedBeforeCoalescedFollowUpStarts() async throws {
    // Emit a valid response for revision 1 after revision 2 is pending but before revision 2 starts.
    // Assert the first exactly-three set becomes visible, then a later revision can replace it.
}
```

Extend `BackendClientSpy.generateQuestions` to count successful completions and caught `CancellationError` values without hiding the error.

- [ ] **Step 2: Run focused scheduling tests and verify red**

Run: `cd desktop-macos && swift test --filter MeetingStoreTests`

Expected: FAIL because the active generation is cancelled by each new context and an otherwise-current response is rejected solely because a newer revision is pending.

- [ ] **Step 3: Implement one-in-flight plus newest-pending scheduling**

```swift
var suggestionDebounceTask: Task<Void, Never>?
var suggestionGenerationTask: Task<Void, Never>?
var pendingSuggestionRevision: Int?
```

On meaningful context, update `pendingSuggestionRevision`; if generation is active, leave it running. Otherwise debounce and launch the newest pending revision. When that request returns, clear only the matching generation task and schedule at most one follow-up for the newest pending revision. Accept a suggestion event when its generation ID matches the active generation and its revision matches the last requested revision; do not reject it merely because later context is waiting. Cancel both task types only at real meeting lifecycle boundaries.

- [ ] **Step 4: Run focused scheduling tests and verify green**

Run: `cd desktop-macos && swift test --filter MeetingStoreTests`

Expected: PASS with request revisions `[1, 4]`, zero churn cancellations, first useful response accepted, and stale replaced generation responses still rejected.

- [ ] **Step 5: Commit the scheduling task**

```bash
git add desktop-macos/Sources/PromptMeet/Services/MeetingStore.swift \
  desktop-macos/Sources/PromptMeet/Services/MeetingStoreAI.swift \
  desktop-macos/Sources/PromptMeet/Services/MeetingStoreLifecycle.swift \
  desktop-macos/Sources/PromptMeet/Services/MeetingStoreCommands.swift \
  desktop-macos/Tests/PromptMeetTests/MeetingStoreTestDoubles.swift \
  desktop-macos/Tests/PromptMeetTests/MeetingStoreSuggestionTests.swift
git commit -m "fix(macos): coalesce suggestion refreshes in flight"
```

### Task 3: Persist successful translations by enriching existing evidence

**Files:**
- Modify: `backend/services/meeting_repository.py`
- Modify: `backend/services/meeting_ingestion.py`
- Modify: `backend/main_service.py`
- Modify: `backend/tests/test_meeting_repository.py`
- Modify: `backend/tests/test_meeting_lifecycle_e2e.py`
- Modify: `desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift`

**Interfaces:**
- Consumes: meeting ID, transcript `segment_id`, translated text, and the existing atomic sibling-file writer.
- Produces: `MeetingRepository.enrich_transcript_translation(meeting_id, segment_id, translated_text) -> MeetingEvent` and `MeetingIngestionService.translate_transcript(...) -> MeetingEvent`.

- [ ] **Step 1: Write failing repository, live-path, and reload tests**

```python
def test_translation_enriches_existing_event_without_appending_duplicate(tmp_path):
    repository = MeetingRepository(tmp_path)
    repository.create("meeting-a", START)
    original = repository.append("meeting-a", transcript_event("Hello")).events[-1]
    enriched = repository.enrich_transcript_translation("meeting-a", "segment-Hello", "你好")
    restored = MeetingRepository(tmp_path).get("meeting-a")
    assert len(restored.events) == 1
    assert enriched.event_id == original.event_id
    assert enriched.sequence == original.sequence
    assert enriched.payload.text == "Hello"
    assert enriched.payload.translated_text == "你好"
```

Add an async controlled `translate_native_transcript` test that asserts the record is already enriched when the live translation payload is broadcast, and a Swift version 2 parser test that asserts historical `translated_text` restores into `TranscriptLine.translatedText`.

- [ ] **Step 2: Run focused Python and Swift tests and verify red**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_meeting_repository.py tests/test_meeting_lifecycle_e2e.py`

Run: `cd desktop-macos && swift test --filter MeetingHistoryTests`

Expected: Python FAIL because no enrichment API exists. Swift parser test should pass only after its fixture carries a non-null translation, proving the already-supported reload path.

- [ ] **Step 3: Implement atomic event enrichment before broadcast**

```python
def enrich_transcript_translation(self, meeting_id: str, segment_id: str, translated_text: str) -> MeetingEvent:
    with self._lock:
        record = self.get(meeting_id)
        # Find the one transcript payload with the matching segment ID.
        # Replace only its payload with model_copy(update={"translated_text": translated_text}).
        # Preserve event_id, sequence, occurred_at, provenance, original text, source, and timing.
        # Write the updated record atomically and return the enriched event.
```

Call the ingestion method after the provider succeeds and before `websocket_manager.broadcast_to_session`. If the transcript no longer exists, keep the original evidence and log the bounded failure without appending a duplicate. A provider failure remains non-destructive.

- [ ] **Step 4: Run focused Python and Swift tests and verify green**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_meeting_repository.py tests/test_meeting_lifecycle_e2e.py`

Run: `cd desktop-macos && swift test --filter MeetingHistoryTests`

Expected: PASS with one enriched event, stable identity and sequence, persistence before live broadcast, and durable Swift history decoding.

- [ ] **Step 5: Commit the persistence task**

```bash
git add backend/services/meeting_repository.py backend/services/meeting_ingestion.py \
  backend/main_service.py backend/tests/test_meeting_repository.py \
  backend/tests/test_meeting_lifecycle_e2e.py \
  desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift
git commit -m "fix: persist translated transcript evidence"
```

### Task 4: Documentation, full validation, and local signed-app checkpoint

**Files:**
- Modify: `docs/macos-meeting-agent.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: all completed tasks and project validation commands.
- Produces: durable invariants for translation enrichment and one-in-flight suggestion scheduling, a signed app bundle, and the local-only captain handoff.

- [ ] **Step 1: Update concise durable invariants**

Document that successful live translation atomically enriches the original transcript event before broadcast and that suggestion refresh permits one request in flight while coalescing newer revisions into one follow-up. Keep the architecture owner pointers in `AGENTS.md` concise.

- [ ] **Step 2: Run all automated tests and formatting or lint checks**

Run:

```bash
cd desktop-macos && swift test
cd backend && ../build/desktop-python/bin/python3 -m pytest -q
swiftlint lint --strict desktop-macos/Sources desktop-macos/Tests
cd backend && ../build/desktop-python/bin/python3 -m black --check .
```

Expected: all Swift and Python tests pass, strict SwiftLint reports no violations, and Black reports no changes needed.

- [ ] **Step 3: Build release, package, and verify signing**

Run:

```bash
cd desktop-macos && swift build -c release
PROMPTMEET_SKIP_WHISPER_BUILD=1 ./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
codesign -d --entitlements :- dist/PromptMeet.app
plutil -p dist/PromptMeet.app/Contents/Info.plist
```

Expected: release and package commands exit 0, strict signing verifies, microphone usage text exists, and the audio-input entitlement remains present.

- [ ] **Step 4: Perform deterministic preview and real packaged walkthroughs**

Launch preview modes for live bilingual overflow, paused, quick ask, compact workspace, and large workspace. Verify the compact island remains attached to the screen top, controls retain their anchors and hit areas, short text does not move, long original plus translation moves horizontally without vertical clipping, and hover expansion remains stable. In the signed app, verify live and historical translation, one prompt suggestion set appearing while speech continues, pause and resume, workspace and island transitions, and app responsiveness.

- [ ] **Step 5: Commit final documentation and any verification-only preview fixtures**

```bash
git add docs/macos-meeting-agent.md AGENTS.md desktop-macos/Sources/PromptMeet/Domain/MeetingStatePreview.swift
git commit -m "docs: record translation and suggestion invariants"
```

- [ ] **Step 6: Verify branch, captain checkout, remote state, and launch exact signed app**

Run read-only branch and checkout checks, use `gh-axi` to prove no PR exists, and prove no remote `fm/promptmeet-local-ux-overhaul` branch exists. Stop only PromptMeet test or preview processes launched from this worktree, then launch `/Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet/dist/PromptMeet.app` normally and record its PID.

- [ ] **Step 7: Append the mandatory paused handoff and stop**

```bash
echo "paused: local app ready for captain testing at /Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet/dist/PromptMeet.app; no branch pushed and no PR created" >> /Users/zilong/coding/firstmate/state/promptmeet-local-ux-overhaul.status
```

Expected: branch and signed app remain available locally; no push, PR, merge, or no-mistakes run occurs.
