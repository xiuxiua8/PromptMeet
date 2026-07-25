import XCTest
@testable import PromptMeet

final class TranscriptFlowFormatterTests: XCTestCase {
    func testAdjacentTranscriptLinesReadAsOneContinuousFlow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let lines = [
            TranscriptLine(speaker: "我", text: "先确认目标。", timestamp: start),
            TranscriptLine(speaker: "会议", text: "然后讨论上线时间。", timestamp: start.addingTimeInterval(8)),
        ]

        XCTAssertEqual(
            TranscriptFlowFormatter.text(lines: lines, activeText: "最后确认负责人"),
            "先确认目标。 然后讨论上线时间。 最后确认负责人"
        )
    }

    func testLargeTimeGapCreatesOneRestrainedTimestampMarker() {
        let start = Date(timeIntervalSince1970: 1_000)
        let lines = [
            TranscriptLine(speaker: "我", text: "第一部分。", timestamp: start),
            TranscriptLine(speaker: "会议", text: "第二部分。", timestamp: start.addingTimeInterval(90)),
        ]

        let result = TranscriptFlowFormatter.text(lines: lines, activeText: "")

        XCTAssertTrue(result.hasPrefix("第一部分。  · "))
        XCTAssertTrue(result.hasSuffix("  第二部分。"))
    }
}
