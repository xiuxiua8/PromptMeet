import CoreGraphics
import Foundation
import XCTest
@testable import PromptMeet

final class SubtitleStreamFlowTests: XCTestCase {
    private func page(_ text: String, width: CGFloat = 200) -> SubtitleStreamPage {
        SubtitleStreamPage(
            id: UUID(),
            text: text,
            translation: nil,
            timestamp: Date(),
            width: width
        )
    }

    // MARK: - Appending never replaces existing content

    func testAppendAccumulatesInsteadOfReplacing() {
        var flow = SubtitleStreamFlow()
        flow.append(page("第一段转写"))
        flow.append(page("第二段转写"))
        flow.append(page("第三段转写"))

        XCTAssertEqual(flow.pages.map(\.text), ["第一段转写", "第二段转写", "第三段转写"])
        XCTAssertEqual(flow.pendingCharacterCount, 15)
    }

    func testAppendDuringFlowDoesNotResetCursor() {
        var flow = SubtitleStreamFlow()
        flow.append(page("First line", width: 300))
        flow.tick(deltaTime: 2)
        let cursorBefore = flow.cursor
        XCTAssertGreaterThan(cursorBefore, 0)

        flow.append(page("Second line", width: 250))
        XCTAssertEqual(flow.cursor, cursorBefore, accuracy: 0.001)
        XCTAssertEqual(flow.pages.count, 2)
    }

    func testAppendDoesNotOverwritePageBeingRead() {
        var flow = SubtitleStreamFlow()
        flow.append(page("正在阅读的句子", width: 320))
        flow.tick(deltaTime: 1)

        flow.append(page("突发的新句子", width: 240))

        // The first page is still buffered and flows; the new page waits behind it.
        XCTAssertEqual(flow.pages.count, 2)
        XCTAssertEqual(flow.pages[0].text, "正在阅读的句子")
        XCTAssertEqual(flow.pages[1].text, "突发的新句子")
    }

    // MARK: - Traversal and drain

    func testPagesPopAfterFullTraverseAndGap() {
        var flow = SubtitleStreamFlow()
        flow.append(page("A", width: 100))
        flow.append(page("B", width: 100))
        let travelA = 100 + SubtitleFlowMetrics.traverseGap
        let speed = SubtitleFlowMetrics.speed(pendingCharacters: 2)

        // Tick just far enough to traverse page A and its gap, not page B.
        flow.tick(deltaTime: Double(travelA / speed) + 0.001)
        XCTAssertEqual(flow.pages.count, 1)
        XCTAssertEqual(flow.pages[0].text, "B")

        let remaining = flow.cursor
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThan(remaining, travelA)
    }

    func testQuietStreamStopsWhenDrainedAndFreshAppendStartsFresh() {
        var flow = SubtitleStreamFlow()
        flow.append(page("Lone caption", width: 200))

        flow.tick(deltaTime: 60)

        XCTAssertTrue(flow.isEmpty)
        XCTAssertEqual(flow.cursor, 0)

        flow.append(page("Next caption", width: 220))
        XCTAssertEqual(flow.pages.map(\.text), ["Next caption"])
        XCTAssertEqual(flow.cursor, 0)
    }

    func testRenderedPositionNeverJumpsWhenPagePops() {
        var flow = SubtitleStreamFlow()
        flow.append(page("A", width: 120))
        flow.append(page("B", width: 120))
        let travelA = 120 + SubtitleFlowMetrics.traverseGap
        let speed = SubtitleFlowMetrics.speed(pendingCharacters: 2)

        // Just before the pop, B's left edge sits at (travelA - cursor).
        flow.tick(deltaTime: Double(travelA / speed) - 0.001)
        let beforePop = flow.visiblePages(viewportWidth: 600).first(where: { $0.page.text == "B" })?.x
        XCTAssertNotNil(beforePop)

        // Just after the pop, B is the head at x = -cursor (same position).
        flow.tick(deltaTime: 0.01)
        let afterPop = flow.visiblePages(viewportWidth: 600).first(where: { $0.page.text == "B" })?.x
        XCTAssertNotNil(afterPop)
        XCTAssertEqual(beforePop!, afterPop!, accuracy: 0.5)
    }

    // MARK: - Adaptive speed

    func testSpeedRisesWithPendingVolumeAndIsClamped() {
        XCTAssertEqual(SubtitleFlowMetrics.speed(pendingCharacters: 0), 26, accuracy: 0.001)
        XCTAssertEqual(SubtitleFlowMetrics.speed(pendingCharacters: 1), 26.25, accuracy: 0.001)
        XCTAssertGreaterThan(
            SubtitleFlowMetrics.speed(pendingCharacters: 200),
            SubtitleFlowMetrics.speed(pendingCharacters: 0)
        )
        XCTAssertEqual(
            SubtitleFlowMetrics.speed(pendingCharacters: 10_000),
            SubtitleFlowMetrics.maximumSpeed,
            accuracy: 0.001
        )
    }

    func testSpeedIsMonotonicInPendingVolume() {
        var previous: CGFloat = -1
        for count in stride(from: 0, through: 500, by: 25) {
            let speed = SubtitleFlowMetrics.speed(pendingCharacters: count)
            XCTAssertGreaterThanOrEqual(speed, previous)
            previous = speed
        }
    }

    func testBurstAdvancesFasterThanQuietStream() {
        var quiet = SubtitleStreamFlow()
        quiet.append(page("Q1", width: 300))

        var burst = SubtitleStreamFlow()
        for index in 0..<8 {
            burst.append(page("burst line number \(index)", width: 260))
        }

        quiet.tick(deltaTime: 1)
        burst.tick(deltaTime: 1)

        XCTAssertGreaterThan(burst.cursor, quiet.cursor)
    }

    func testSpeedDecaysAsBacklogDrains() {
        var flow = SubtitleStreamFlow()
        for index in 0..<6 {
            flow.append(page("line \(index)", width: 250))
        }
        flow.tick(deltaTime: 0.1)
        let fastCursor = flow.cursor
        // Drain everything.
        flow.tick(deltaTime: 120)
        XCTAssertTrue(flow.isEmpty)

        flow.append(page("fresh", width: 250))
        flow.tick(deltaTime: 0.1)
        XCTAssertLessThan(flow.cursor, fastCursor)
    }

    // MARK: - Bounds

    func testBufferIsBoundedByPageAndCharacterCaps() {
        var flow = SubtitleStreamFlow(maximumPages: 3, maximumCharacters: 1_000)
        for index in 0..<10 {
            flow.append(page("line \(index)", width: 100))
        }

        XCTAssertEqual(flow.pages.count, 3)
        XCTAssertEqual(flow.pages.map(\.text), ["line 7", "line 8", "line 9"])
    }

    func testCharacterCapTrimsOldestPages() {
        var flow = SubtitleStreamFlow(maximumPages: 100, maximumCharacters: 12)
        flow.append(page("abcdefghij", width: 100))
        flow.append(page("klmno", width: 100))

        // 15 characters > 12: the oldest page is trimmed, keeping the newest.
        XCTAssertEqual(flow.pages.map(\.text), ["klmno"])
    }

    func testEmptyAndBlankPagesAreIgnored() {
        var flow = SubtitleStreamFlow()
        flow.append(page("", width: 0))
        flow.append(page("   ", width: 0))

        XCTAssertTrue(flow.isEmpty)
    }

    func testUnmeasuredPageIsNeverPoppedPrematurely() {
        var flow = SubtitleStreamFlow()
        flow.append(page("not yet measured", width: 0))

        flow.tick(deltaTime: 10)

        XCTAssertEqual(flow.pages.count, 1)
        XCTAssertEqual(flow.pages[0].text, "not yet measured")
    }

    func testCapTrimKeepsCursorConsistentWithNewHead() {
        var flow = SubtitleStreamFlow(maximumPages: 2, maximumCharacters: 10_000)
        flow.append(page("A", width: 100))
        flow.append(page("B", width: 100))
        flow.append(page("C", width: 100))
        flow.append(page("D", width: 100))

        XCTAssertEqual(flow.pages.map(\.text), ["C", "D"])
        XCTAssertEqual(flow.cursor, 0, accuracy: 0.001)
    }

    // MARK: - Visibility window

    func testVisiblePagesCoverTheViewportWindow() {
        var flow = SubtitleStreamFlow()
        flow.append(page("first", width: 200))
        flow.append(page("second", width: 200))
        flow.append(page("third", width: 200))

        // Cursor at 0: the first page occupies x=0..200; the viewport 300 wide
        // also shows the beginning of the second page.
        let visible = flow.visiblePages(viewportWidth: 300)
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].page.text, "first")
        XCTAssertEqual(visible[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(visible[1].page.text, "second")
    }

    func testLiveTailPositionFollowsBufferedContent() {
        var flow = SubtitleStreamFlow()
        XCTAssertEqual(flow.liveTailPosition, 0, accuracy: 0.001)

        flow.append(page("first", width: 200))
        flow.tick(deltaTime: 0)
        let position = flow.liveTailPosition
        XCTAssertEqual(position, 200, accuracy: 0.001)

        flow.tick(deltaTime: 2)
        XCTAssertEqual(flow.liveTailPosition, position - flow.cursor, accuracy: 0.001)
    }

    func testResetClearsStream() {
        var flow = SubtitleStreamFlow()
        flow.append(page("A", width: 100))
        flow.tick(deltaTime: 1)

        flow.reset()

        XCTAssertTrue(flow.isEmpty)
        XCTAssertEqual(flow.cursor, 0)
    }
}
