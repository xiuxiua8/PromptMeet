import XCTest

@testable import PromptMeet

final class MeetingHistoryTests: XCTestCase {
    func testStoredMeetingParserKeepsTranscriptAndStructuredSummary() throws {
        let data = Data(
            #"[{"session_id":"session-1","start_time":"2026-07-25T10:00:00+08:00","transcript_segments":[{"id":"4E2CB506-925E-4A6E-BB68-E5006AB09BDF","speaker":"林晨","text":"确认范围","timestamp":"2026-07-25T10:01:00+08:00"}],"current_summary":{"summary_text":"范围已确认","tasks":[{"task":"准备发布"}],"key_points":["范围冻结"],"decisions":["周五上线"]}}]"#
                .utf8
        )

        let meetings = try StoredMeeting.parseList(data)

        XCTAssertEqual(meetings.first?.id, "session-1")
        XCTAssertEqual(meetings.first?.transcript.first?.text, "确认范围")
        XCTAssertEqual(meetings.first?.summary?.tasks.first?.title, "准备发布")
    }

    func testStoredMeetingKeepsTranscriptSourceAndMeetingTime() throws {
        let data = Data(
            #"[{"schema_version":2,"meeting_id":"meeting-source","status":"completed","started_at":"2026-07-26T10:00:00Z","ended_at":"2026-07-26T10:05:00Z","events":[{"event_id":"event-1","meeting_id":"meeting-source","sequence":1,"occurred_at":"2026-07-26T10:00:01Z","kind":"transcript","provenance":{"source":"native_transcript"},"payload":{"type":"transcript","segment_id":"08f0900a-a756-48db-bf38-d3040ddcd986","text":"我会负责回滚","speaker":"我","source":"microphone","meeting_time_ms":1250,"translated_text":null}}]}]"#
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertEqual(meeting.transcript.first?.source, .microphone)
        XCTAssertEqual(meeting.transcript.first?.meetingTime, .milliseconds(1_250))
    }

    func testStoredMeetingRestoresLatestAcceptedSuggestions() throws {
        let data = Data(
            #"[{"schema_version":2,"meeting_id":"meeting-suggestions","status":"completed","started_at":"2026-07-26T10:00:00Z","events":[{"event_id":"event-1","meeting_id":"meeting-suggestions","sequence":1,"occurred_at":"2026-07-26T10:00:01Z","kind":"suggestions","provenance":{"source":"suggestion_service"},"payload":{"type":"suggestions","generation_id":"22222222-2222-2222-2222-222222222222","context_revision":2,"questions":["谁负责上线？"]}}]}]"#
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertEqual(meeting.suggestions, ["谁负责上线？"])
    }
}
