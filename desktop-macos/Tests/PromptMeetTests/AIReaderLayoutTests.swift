import XCTest
@testable import PromptMeet

final class AIReaderLayoutTests: XCTestCase {
    @MainActor
    func testReaderWindowCanBecomeKeyForFollowUpInput() {
        let controller = AIReaderWindowController(store: MeetingStore())

        XCTAssertTrue(controller.window?.canBecomeKey == true)
    }

    func testShortAnswerUsesCompactReaderSize() {
        XCTAssertEqual(
            AIReaderLayout.targetSize(content: "简短回答", isStreaming: false),
            CGSize(width: 380, height: 240)
        )
    }

    func testLongAnswerIsCappedAtReaderMaximum() {
        let size = AIReaderLayout.targetSize(
            content: String(repeating: "很长的回答内容。", count: 800),
            isStreaming: true
        )

        XCTAssertEqual(size.width, 460)
        XCTAssertEqual(size.height, 620)
    }

    func testMaximumReaderContentSkipsFullDocumentMeasurement() {
        XCTAssertFalse(
            AIReaderLayout.shouldMeasureContent(String(repeating: "长回答", count: 201))
        )
    }

    func testExplicitParagraphsGrowReaderMoreThanFlatTextWithSimilarLength() {
        let flat = AIReaderLayout.targetSize(
            content: String(repeating: "内容", count: 40),
            isStreaming: false
        )
        let paragraphs = AIReaderLayout.targetSize(
            content: Array(repeating: "内容内容内容内容", count: 10).joined(separator: "\n"),
            isStreaming: false
        )

        XCTAssertGreaterThan(paragraphs.height, flat.height)
    }

    func testReaderResizeKeepsTopRightAnchorWhenThereIsRoom() {
        let frame = AIReaderLayout.resizedFrame(
            currentFrame: CGRect(x: 400, y: 400, width: 380, height: 240),
            targetSize: CGSize(width: 460, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        )

        XCTAssertEqual(frame.maxX, 780)
        XCTAssertEqual(frame.maxY, 640)
        XCTAssertEqual(frame.size, CGSize(width: 460, height: 500))
    }
}
