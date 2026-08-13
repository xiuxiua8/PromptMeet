import CoreGraphics
import Foundation
import XCTest
@testable import PromptMeet

final class SubtitleStreamFlowTests: XCTestCase {
    private func page(_ text: String, width: CGFloat = 200) -> SubtitleStreamPage {
        SubtitleStreamPage(id: UUID(), text: text, timestamp: Date(), width: width)
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

        // Tick until A has fully traversed (and popped), stopping before B.
        var steps = 0
        while flow.pages.count == 2, steps < 2_000 {
            flow.tick(deltaTime: 0.01)
            steps += 1
        }
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
        let speed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: flow.entryRatePtsPerSecond,
            pendingWidth: flow.pendingWidth
        )

        // Just before the pop, B's left edge sits at (travelA - cursor).
        flow.tick(deltaTime: Double(travelA / speed) - 0.001)
        let beforePop = flow.visiblePages(viewportWidth: 600).first(where: { $0.page.text == "B" })?.x
        XCTAssertNotNil(beforePop)

        // Just after the pop, B is the head at x = -cursor; the rendered
        // position is continuous (it only advanced by the tiny extra delta).
        flow.tick(deltaTime: 0.001)
        let afterPop = flow.visiblePages(viewportWidth: 600).first(where: { $0.page.text == "B" })?.x
        XCTAssertNotNil(afterPop)
        XCTAssertEqual(beforePop!, afterPop!, accuracy: 3)
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

    func testHeadPageIsAlwaysRenderedUntilItsWidthIsMeasured() {
        var flow = SubtitleStreamFlow()
        flow.append(page("first", width: 0))

        let visible = flow.visiblePages(viewportWidth: 300)

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].page.text, "first")
        XCTAssertEqual(visible[0].x, 0, accuracy: 0.001)
    }

    func testMergeCopiesLateTranslationOntoExistingPageWithoutResettingState() {
        var flow = SubtitleStreamFlow()
        let original = page("今天讨论了项目进度")
        flow.append(original)
        flow.tick(deltaTime: 2)

        let cursor = flow.cursor
        flow.merge(
            SubtitleStreamPage(
                id: original.id,
                text: original.text,
                translation: "Today we discussed progress",
                timestamp: original.timestamp
            )
        )

        XCTAssertEqual(flow.pages.count, 1)
        XCTAssertEqual(flow.pages[0].translation, "Today we discussed progress")
        XCTAssertEqual(flow.pages[0].width, original.width, accuracy: 0.001)
        XCTAssertEqual(flow.cursor, cursor, accuracy: 0.001)
    }

    func testMergeAppendsNewPages() {
        var flow = SubtitleStreamFlow()
        flow.merge(page("第一段", width: 120))
        flow.merge(page("第二段", width: 200))

        XCTAssertEqual(flow.pages.map(\.text), ["第一段", "第二段"])
    }

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
