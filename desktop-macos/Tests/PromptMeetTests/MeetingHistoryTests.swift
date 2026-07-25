import XCTest
@testable import PromptMeet

final class MeetingHistoryTests: XCTestCase {
    func testStoredMeetingParserKeepsTranscriptAndStructuredSummary() throws {
        let data = Data(
            #"[{"session_id":"session-1","start_time":"2026-07-25T10:00:00+08:00","transcript_segments":[{"id":"4E2CB506-925E-4A6E-BB68-E5006AB09BDF","speaker":"林晨","text":"确认范围","timestamp":"2026-07-25T10:01:00+08:00"}],"current_summary":{"summary_text":"范围已确认","tasks":[{"task":"准备发布"}],"key_points":["范围冻结"],"decisions":["周五上线"]}}]"#.utf8
        )

        let meetings = try StoredMeeting.parseList(data)

        XCTAssertEqual(meetings.first?.id, "session-1")
        XCTAssertEqual(meetings.first?.transcript.first?.text, "确认范围")
        XCTAssertEqual(meetings.first?.summary?.tasks.first?.title, "准备发布")
    }
}
