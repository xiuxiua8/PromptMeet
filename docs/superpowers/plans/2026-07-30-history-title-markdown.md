# Meeting Titles, History Search, and Markdown Outputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate safe meeting-scoped titles, make meeting history searchable, and render AI, summary, and task content consistently through the native Markdown presentation layer.

**Architecture:** The Python companion owns title persistence and uses an immediate deterministic fallback before an optional asynchronous AI refinement. Swift owns stable display fallbacks and pure ranked search over decoded meeting content. All three output tabs share `MarkdownTextView`, with formatters converting structured summaries and tasks into Markdown and the parser presenting checklists without exposing raw markers.

**Tech Stack:** Python 3, FastAPI, Pydantic v2, pytest, Swift 6, SwiftUI, XCTest.

## Global Constraints

- Start from `19bb25d04898bce4461bdf9979df9b245139d96b` on `fm/promptmeet-history-title-markdown`.
- Never leak content across meetings during title generation.
- Meeting completion must persist before title AI runs and must survive any title generation failure.
- Historical version 2 records without a title must remain readable without rewriting source data.
- Do not modify screenshot pixel routing, audio denoising/VAD, dense timeline redesign, or island geometry.
- Do not push or create a pull request.
- Leave one clean contributor commit with verification evidence.

---

### Task 1: Meeting-scoped title finalization

**Files:**
- Create: `backend/services/meeting_title_service.py`
- Modify: `backend/services/meeting_repository.py`
- Modify: `backend/services/desktop_agent_service.py`
- Modify: `backend/main_service.py`
- Test: `backend/tests/test_meeting_title_service.py`
- Test: `backend/tests/test_meeting_lifecycle_e2e.py`

**Interfaces:**
- Consumes: one immutable `MeetingRecord` selected by meeting ID.
- Produces: `MeetingTitleService.fallback_title(record)`, `MeetingTitleService.finalize(meeting_id)`, `MeetingRepository.set_title(meeting_id, title)`, and `DesktopAgentService.generate_meeting_title(record)`.

- [ ] **Step 1: Write failing title service tests**

```python
async def test_ai_title_replaces_persisted_fallback():
    title = await service.finalize("meeting-a")
    assert title == "周五发布回滚准备"
    assert repository.get("meeting-a").title == title

def test_fallback_uses_only_target_meeting():
    assert service.fallback_title(repository.get("meeting-a")) != service.fallback_title(repository.get("meeting-b"))

def test_empty_meeting_uses_truthful_timestamp():
    assert "2026" in service.fallback_title(repository.get("empty"))
```

- [ ] **Step 2: Run title tests and confirm missing-service failures**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_meeting_title_service.py`

Expected: collection or import failure because `MeetingTitleService` does not exist.

- [ ] **Step 3: Implement fallback, persistence, and AI refinement**

```python
class MeetingTitleService:
    def persist_fallback(self, meeting_id: str) -> str:
        record = self.repository.get(meeting_id)
        title = self.fallback_title(record)
        self.repository.set_title(meeting_id, title)
        return title

    async def finalize(self, meeting_id: str) -> str:
        record = self.repository.get(meeting_id)
        fallback = self.persist_fallback(meeting_id)
        try:
            generated = await self.generator(record)
        except Exception:
            return fallback
        title = self.normalize_generated_title(generated) or fallback
        self.repository.set_title(meeting_id, title)
        return title
```

The stop route first marks the record completed, persists the fallback synchronously, and schedules `finalize` in a tracked background task. The optional AI prompt contains only transcript, latest summary, decisions, and tasks from the same `MeetingRecord`.

- [ ] **Step 4: Run title unit and lifecycle E2E tests**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_meeting_title_service.py tests/test_meeting_lifecycle_e2e.py`

Expected: all selected tests pass.

### Task 2: Stable titles and ranked history search

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Domain/StoredMeeting.swift`
- Create: `desktop-macos/Sources/PromptMeet/Domain/MeetingHistorySearch.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceView.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceTimelineView.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MeetingHistoryTests.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/MeetingHistorySearchTests.swift`

**Interfaces:**
- Consumes: decoded optional `StoredMeeting.title` and meeting-owned searchable text.
- Produces: `StoredMeeting.displayTitle`, `StoredMeeting.searchableText`, and `MeetingHistorySearch.results(in:query:)`.

- [ ] **Step 1: Write failing schema, fallback, duplicate, Chinese, and ASCII search tests**

```swift
func testUntitledVersionTwoRecordKeepsStableDisplayFallback() throws {
    let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)
    XCTAssertEqual(meeting.title, nil)
    XCTAssertEqual(meeting.displayTitle, "确认周五发布")
}

func testTitleMatchesRankAheadOfTranscriptMatches() {
    let results = MeetingHistorySearch.results(in: meetings, query: "release")
    XCTAssertEqual(results.map(\.id), ["title-match", "body-match"])
}
```

- [ ] **Step 2: Run the focused Swift tests and confirm missing-API failures**

Run: `cd desktop-macos && swift test --filter 'MeetingHistory(Search)?Tests'`

Expected: compile failure because the search and display APIs do not exist.

- [ ] **Step 3: Implement pure display fallback and ranked search**

```swift
var displayTitle: String {
    if let normalizedTitle { return normalizedTitle }
    return MeetingTitleFallback.title(transcript: transcript, summary: summary, startedAt: startTime)
}

enum MeetingHistorySearch {
    static func results(in meetings: [StoredMeeting], query: String) -> [StoredMeeting] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return meetings }
        var ranked: [RankedMeeting] = []
        for (index, meeting) in meetings.enumerated() {
            guard let rank = rank(meeting, terms: terms) else { continue }
            ranked.append(RankedMeeting(rank: rank, index: index, meeting: meeting))
        }
        return ranked.sorted { lhs, rhs in
            (lhs.rank, lhs.index) < (rhs.rank, rhs.index)
        }.map(\.meeting)
    }
}
```

The sidebar gets a native search field with clear action, result count, title-first ordering, and unchanged meeting-ID selection so duplicate titles remain independent. The reopened toolbar uses `displayTitle` prominently.

- [ ] **Step 4: Run focused history tests**

Run: `cd desktop-macos && swift test --filter 'MeetingHistory(Search)?Tests'`

Expected: all selected tests pass.

### Task 3: Shared Markdown presentation for summary and tasks

**Files:**
- Modify: `desktop-macos/Sources/PromptMeet/Views/MarkdownDocument.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/MarkdownTextView.swift`
- Create: `desktop-macos/Sources/PromptMeet/Views/MeetingMarkdownFormatter.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Views/WorkspaceSummaryView.swift`
- Test: `desktop-macos/Tests/PromptMeetTests/MarkdownDocumentTests.swift`
- Create: `desktop-macos/Tests/PromptMeetTests/MeetingMarkdownFormatterTests.swift`

**Interfaces:**
- Consumes: `MeetingSummaryContent` and `[MeetingTask]`.
- Produces: `MeetingMarkdownFormatter.summary(_:)`, `MeetingMarkdownFormatter.tasks(_:)`, and parsed task-list blocks with raw `[ ]` or `[x]` markers removed.

- [ ] **Step 1: Write failing checklist, summary, streaming, replay, long-line, and source-guard tests**

```swift
func testTaskFormatterIncludesAllStructuredMetadata() {
    let markdown = MeetingMarkdownFormatter.tasks([task])
    XCTAssertTrue(markdown.contains("- [ ] **准备发布**"))
    XCTAssertTrue(markdown.contains("负责人：周岚"))
    XCTAssertTrue(markdown.contains("截止：周五"))
    XCTAssertTrue(markdown.contains("状态：待处理"))
    XCTAssertTrue(markdown.contains("优先级：高"))
}

func testChecklistMarkersBecomeSemanticTaskList() {
    let block = MarkdownDocument.parse("- [x] 已完成", mode: .completed).first
    XCTAssertEqual(block?.kind, .taskList(completed: [true]))
    XCTAssertEqual(block?.lines, ["已完成"])
}
```

- [ ] **Step 2: Run focused Markdown tests and confirm missing-API failures**

Run: `cd desktop-macos && swift test --filter 'Markdown(Document|Formatter)Tests'`

Expected: compile failure because formatter and task-list support do not exist.

- [ ] **Step 3: Implement formatter, task-list rendering, and wrapping/accessibility safeguards**

```swift
enum MeetingMarkdownFormatter {
    static func summary(_ summary: MeetingSummaryContent) -> String { /* joined Markdown sections */ }
    static func tasks(_ tasks: [MeetingTask]) -> String { /* concise checklist lines with metadata */ }
}
```

`WorkspaceSummaryView` renders both output tabs with `MarkdownTextView`. Checklist blocks render a semantic checked or unchecked icon and stripped inline content. Text remains selectable, uses fixed vertical sizing, wraps long unbroken lines, and allows only `http` and `https` links.

- [ ] **Step 4: Run focused Markdown and state replay tests**

Run: `cd desktop-macos && swift test --filter 'Markdown|MeetingState|MeetingHistory'`

Expected: all selected tests pass.

### Task 4: Validation, UI walkthrough, memory, and clean commit

**Files:**
- Modify when warranted: `AGENTS.md`
- Verify all task files and tests.

**Interfaces:**
- Consumes: completed implementation.
- Produces: a clean branch commit and firstmate completion status.

- [ ] **Step 1: Run full Python and Swift tests**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q`

Run: `cd desktop-macos && swift test`

Expected: zero failures.

- [ ] **Step 2: Run strict scoped formatting and lint checks**

Run Black in check mode over changed Python files and SwiftLint strict over changed Swift files using the repository or installed tool configuration.

Expected: zero violations and no modified generated files.

- [ ] **Step 3: Run release build**

Run: `cd desktop-macos && swift build -c release`

Expected: exit status 0.

- [ ] **Step 4: Walk through compact and large native previews**

Run permission-free workspace previews, open history, search Chinese and ASCII terms, reopen a historical record, inspect AI/summary/tasks, resize the workspace through compact and large supported sizes, verify keyboard focus, selection, contrast, wrapping, and scrolling, then stop only the preview process started for the walkthrough.

- [ ] **Step 5: Ensure project memory and commit once**

Run: `/Users/zilong/coding/firstmate/bin/fm-ensure-agents-md.sh .`

Review `git diff --check`, `git status`, and the staged diff, then commit with a contributor-authored message and no co-author line.

Expected: clean worktree and one full commit SHA ready for integration.
