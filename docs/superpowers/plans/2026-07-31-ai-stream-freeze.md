# AI Stream Freeze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound AI stream completion work so a long Markdown answer reaches completed state without freezing PromptMeet and the app remains responsive to interaction and an immediate follow-up question.

**Architecture:** Treat the provider terminal marker as terminal in the Python companion. Before WebSocket events reach `MeetingStore`, coalesce small answer deltas into bounded batches and let a full final answer supersede any unsent partial text. In the native reader, stop running CoreText over the full answer after the reader is guaranteed to use its maximum size.

**Tech Stack:** Python 3.12, FastAPI companion services, Swift 6, URLSession WebSocket, SwiftUI, AppKit, XCTest, pytest.

## Global Constraints

- Work only in `/Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet` on `fm/promptmeet-local-ux-overhaul`.
- Do not push, create a PR, or invoke no-mistakes.
- Keep provider credentials out of serialized state, logs, tests, and documentation.
- Use strict red-green TDD for every production behavior change.
- The captain checkout `/Users/zilong/coding/PromptMeet` must remain clean at `f8cf5c2d0a9d67932a1415c02e988a6e0bf7f486`.
- Acceptance requires completed UI state, bounded CPU and memory, working window interaction, and a responsive immediate follow-up after a deterministic long stream.

## Reproduction evidence

- Exact setup: signed `dist/PromptMeet.app`, the captain's live meeting, OpenAI-compatible answer workflow, and a 4,289-character Markdown answer.
- Trigger: submit the second long Markdown question while recording continues.
- Expected: streamed Markdown remains interactive, final event completes the turn, and a follow-up can be entered immediately.
- Observed: the companion persisted and broadcast the final answer, while PromptMeet stayed near 100 percent CPU with about 172 MB RSS and Computer Use timed out reading accessibility state.
- Earliest real divergence: Swift entered `MeetingStore.receiveAnswerEvent(_:)`, published reader state, then spent the sampled main thread in `AIReaderLayout.targetSize` and `NSString.boundingRect` beneath `AIReaderWindowController.resize(for:)`.
- Repeatability: one-character synthetic Markdown deltas with the current sizing call processed only 500 characters in 15 seconds before timeout. A one-shot 6,400-character sizing test completed in 0.088 seconds.
- Proven path: the earlier 3,132-character answer in the same meeting completed and was durably stored. A controlled provider stream ending at EOF returned immediately.
- Smallest counterfactual: provider `[DONE]` followed by keepalives timed out after emitting its chunk, while the same stream followed by EOF completed. One final native sizing call completed, while repeated prefix sizing did not.
- Masking condition: flat or one-shot answers hide the quadratic repeated sizing cost; provider EOF hides that `[DONE]` is currently ignored.
- Visible symptom: application-wide freeze, not only a stale spinner. The window cannot process accessibility reads or follow-up input.

---

### Task 1: Honor provider terminal markers

**Files:**
- Modify: `backend/services/desktop_agent_service.py:513-529`
- Test: `backend/tests/test_desktop_agent_service.py:300-325`

**Interfaces:**
- Consumes: OpenAI-compatible SSE lines from `response.aiter_lines()`.
- Produces: `_stream_agent_turn(...) -> dict[str, object]` that stops reading after `data: [DONE]` and retains all content received before it.

- [ ] **Step 1: Write the failing terminal-marker regression**

Add a fake response whose generator raises if iteration advances beyond `[DONE]`, then call `_stream_agent_turn` and assert the returned content and emitted deltas contain only `bounded chunk`.

```python
class DoneThenUnexpectedReadResponse(FakeAgentStreamResponse):
    async def aiter_lines(self):
        yield 'data: {"choices":[{"delta":{"content":"bounded chunk"}}]}'
        yield "data: [DONE]"
        raise AssertionError("stream read beyond terminal marker")


def test_agent_stream_stops_at_done_without_waiting_for_transport_eof() -> None:
    emitted = []

    async def collect(message: dict) -> None:
        emitted.append(message)

    result = asyncio.run(
        DesktopAgentService._stream_agent_turn(
            DoneThenUnexpectedReadClient(),
            "http://127.0.0.1/v1/chat/completions",
            {},
            {},
            collect,
        )
    )

    assert result["content"] == "bounded chunk"
    assert emitted == [{"data": {"delta": "bounded chunk"}}]
```

- [ ] **Step 2: Run the focused pytest and verify RED**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_agent_service.py -k stops_at_done`

Expected: FAIL with `stream read beyond terminal marker`.

- [ ] **Step 3: Stop iteration at the terminal marker**

Replace the combined empty and `[DONE]` branch with explicit behavior:

```python
if not data:
    continue
if data == "[DONE]":
    break
```

- [ ] **Step 4: Run the focused pytest and verify GREEN**

Run: `cd backend && ../build/desktop-python/bin/python3 -m pytest -q tests/test_desktop_agent_service.py -k stops_at_done`

Expected: 1 passed.

### Task 2: Bound native stream delivery and reader sizing

**Files:**
- Create: `desktop-macos/Sources/PromptMeet/Domain/BackendEventBatcher.swift`
- Modify: `desktop-macos/Sources/PromptMeet/Services/BackendClient.swift:232-265`
- Modify: `desktop-macos/Sources/PromptMeet/Windows/AIReaderWindowController.swift:9-41`
- Create: `desktop-macos/Tests/PromptMeetTests/BackendEventBatcherTests.swift`
- Modify: `desktop-macos/Tests/PromptMeetTests/AIReaderLayoutTests.swift`

**Interfaces:**
- Consumes: decoded `BackendEvent.answerDelta`, `answerFinal`, `aiFailure`, and unrelated WebSocket events.
- Produces: `BackendEventBatcher.consume(_:) -> [BackendEvent]`, `finish() -> [BackendEvent]`, and `AIReaderLayout.shouldMeasureContent(_:) -> Bool`.

- [ ] **Step 1: Write failing batching and sizing tests**

Add tests that feed 4,289 one-character deltas, verify delivery in no more than 136 events including the final answer and immediate follow-up, verify the full final event supersedes an unsent partial, and verify content beyond 600 characters does not request CoreText measurement.

```swift
func testLongStreamHasBoundedReaderWorkAndImmediateFollowUp() {
    let firstID = UUID()
    let secondID = UUID()
    let answer = String(repeating: "证据", count: 2_144) + "结"
    var batcher = BackendEventBatcher(maximumBufferedCharacters: 32)
    var deliveryCount = 0
    for character in answer {
        deliveryCount += batcher.consume(
            .answerDelta(requestID: firstID, delta: String(character))
        ).count
    }
    deliveryCount += batcher.consume(
        .answerFinal(requestID: firstID, answer: answer)
    ).count
    _ = batcher.consume(.answerDelta(requestID: secondID, delta: "follow-up"))
    deliveryCount += batcher.consume(
        .answerFinal(requestID: secondID, answer: "follow-up complete")
    ).count

    XCTAssertEqual(answer.count, 4_289)
    XCTAssertLessThanOrEqual(deliveryCount, 136)
}

func testMaximumReaderContentSkipsFullDocumentMeasurement() {
    XCTAssertFalse(
        AIReaderLayout.shouldMeasureContent(String(repeating: "长回答", count: 201))
    )
}
```

- [ ] **Step 2: Run focused Swift tests and verify RED**

Run: `cd desktop-macos && swift test --filter 'BackendEventBatcherTests|AIReaderLayoutTests'`

Expected: compile failure because `BackendEventBatcher` and `shouldMeasureContent` do not exist.

- [ ] **Step 3: Implement the minimal batcher**

Create a value-type batcher with a default 32-character threshold. Buffer per request ID, emit an aggregated delta at the threshold, let `answerFinal` discard the same request's unsent partial because final content is authoritative, flush partial text before `aiFailure`, and flush all pending text before unrelated events or listener failure.

```swift
struct BackendEventBatcher {
    static let defaultMaximumBufferedCharacters = 32
    private let maximumBufferedCharacters: Int
    private var pending: [UUID?: String] = [:]
    private var order: [UUID?] = []

    mutating func consume(_ event: BackendEvent) -> [BackendEvent] {
        switch event {
        case .answerDelta(let requestID, let delta):
            return append(delta, requestID: requestID)
        case .answerFinal(let requestID, _):
            removePending(requestID)
            return [event]
        case .aiFailure(let requestID, _):
            return drain(requestID) + [event]
        default:
            return finish() + [event]
        }
    }
}
```

- [ ] **Step 4: Route decoded WebSocket events through the batcher**

Keep one batcher inside `BackendClient.listen`. Deliver every event returned by `consume`, call `finish` before emitting a listener failure, and preserve disconnect cancellation behavior.

- [ ] **Step 5: Short-circuit maximum reader sizing**

Add `maximumMeasuredCharacters = 600`, return `maximumSize` when `shouldMeasureContent` is false, and leave existing exact measurement for compact answers.

```swift
static let maximumMeasuredCharacters = 600

static func shouldMeasureContent(_ content: String) -> Bool {
    content.count <= maximumMeasuredCharacters
}

guard shouldMeasureContent(content) else { return maximumSize }
```

- [ ] **Step 6: Run focused Swift tests and verify GREEN**

Run: `cd desktop-macos && swift test --filter 'BackendEventBatcherTests|AIReaderLayoutTests'`

Expected: all selected tests pass and the long-answer structural bound is satisfied.

- [ ] **Step 7: Commit the fix and regression coverage**

```bash
git add backend/services/desktop_agent_service.py backend/tests/test_desktop_agent_service.py \
  desktop-macos/Sources/PromptMeet/Domain/BackendEventBatcher.swift \
  desktop-macos/Sources/PromptMeet/Services/BackendClient.swift \
  desktop-macos/Sources/PromptMeet/Windows/AIReaderWindowController.swift \
  desktop-macos/Tests/PromptMeetTests/BackendEventBatcherTests.swift \
  desktop-macos/Tests/PromptMeetTests/AIReaderLayoutTests.swift \
  docs/superpowers/plans/2026-07-31-ai-stream-freeze.md
git commit -m "fix: bound AI stream completion work"
```

### Task 3: Full validation and signed-app acceptance

**Files:**
- Modify if the invariant changes: `docs/macos-meeting-agent.md`
- Modify if the invariant changes: `AGENTS.md`

**Interfaces:**
- Consumes: committed source and tests from Tasks 1 and 2.
- Produces: signed `dist/PromptMeet.app`, fresh test evidence, captain-checkout proof, and the mandatory local-testing status line.

- [ ] **Step 1: Run focused counterfactuals**

Run the deterministic 4,289-character stream regression twice, then apply an immediate second request. Confirm both conversation turns are completed, the second answer is not delayed behind stale first-answer deltas, and the app-state reducer remains usable.

- [ ] **Step 2: Run complete backend validation**

```bash
cd backend
../build/desktop-python/bin/python3 -m pytest -q
/opt/anaconda3/bin/black --check --diff .
/opt/anaconda3/bin/flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics
```

Expected: all tests pass, Black reports no changes needed, and fatal-only flake8 is clean.

- [ ] **Step 3: Run complete native validation**

```bash
cd desktop-macos
swift test
swift build -c release
swiftlint lint --strict Sources Tests Package.swift
```

Expected: all Swift tests pass, release build exits 0, and strict SwiftLint reports no violations.

- [ ] **Step 4: Build and verify the signed package**

```bash
PROMPTMEET_SKIP_WHISPER_BUILD=1 ./scripts/build-macos-app.sh
codesign --verify --deep --strict dist/PromptMeet.app
codesign -d --entitlements :- dist/PromptMeet.app
```

Expected: package build exits 0, strict signature verification exits 0, microphone usage description remains present, and audio-input entitlement remains present.

- [ ] **Step 5: Exercise deterministic UI and the real signed app**

Use `PROMPTMEET_UI_PREVIEW=reader-long swift run PromptMeet` for layout review, then launch the exact signed app. Feed a deterministic long Markdown stream followed by its final event, inspect CPU and RSS, read accessibility state, focus the composer, submit an immediate follow-up, and verify the second completion. Reject the build if state clears but the app cannot process window interaction or the follow-up.

- [ ] **Step 6: Prove repository safety and remote absence**

Record `git status --short --branch` and `git rev-parse HEAD` in both the isolated worktree and the captain checkout. Confirm no upstream is configured for the feature branch and `gh-axi` shows no PR for it.

- [ ] **Step 7: Launch the final signed app and append the handoff**

Record the exact app path, PID, executable SHA-256, CPU, RSS, and responsive accessibility state. Append exactly:

```text
paused: local app ready for captain testing at /Users/zilong/.treehouse/PromptMeet-ab6001/1/PromptMeet/dist/PromptMeet.app; no branch pushed and no PR created
```

Stop without pushing, creating a PR, or invoking no-mistakes.
