import XCTest
@testable import PromptMeet

final class AIReaderLayoutTests: XCTestCase {
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
}
