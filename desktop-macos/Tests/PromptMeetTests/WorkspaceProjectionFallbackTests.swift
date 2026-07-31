import XCTest

@testable import PromptMeet

final class WorkspaceProjectionFallbackTests: XCTestCase {
    func testVisibleInputCountIncludesLegacyTranscriptFallbackBlocks() {
        let lines = [
            TranscriptLine(speaker: "林晨", text: "确认发布范围", source: .microphone),
            TranscriptLine(speaker: "林晨", text: "确认回滚路径", source: .microphone),
            TranscriptLine(speaker: "周岚", text: "完成上线检查", source: .system)
        ]
        let projection = WorkspaceProjection(
            events: [],
            conversation: [],
            transcriptLines: lines
        )

        XCTAssertEqual(projection.visibleInputCount(fallbackTranscriptLines: lines), 2)
    }
}
