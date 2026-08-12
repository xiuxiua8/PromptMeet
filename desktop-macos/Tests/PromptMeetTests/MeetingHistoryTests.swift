import XCTest

@testable import PromptMeet

final class MeetingHistoryTests: XCTestCase {
    func testStoredMeetingParserKeepsTranscriptAndStructuredSummary() throws {
        let data = Data(
            (#"[{"session_id":"session-1","title":"发布范围确认","start_time":"2026-07-25T10:00:00+08:00","#
                + #""transcript_segments":[{"id":"4E2CB506-925E-4A6E-BB68-E5006AB09BDF","#
                + #""speaker":"林晨","text":"确认范围","timestamp":"2026-07-25T10:01:00+08:00"}],"#
                + #""current_summary":{"summary_text":"范围已确认","tasks":[{"task":"准备发布"}],"#
                + #""key_points":["范围冻结"],"decisions":["周五上线"]}}]"#)
                .utf8
        )

        let meetings = try StoredMeeting.parseList(data)

        XCTAssertEqual(meetings.first?.id, "session-1")
        XCTAssertEqual(meetings.first?.title, "发布范围确认")
        XCTAssertEqual(meetings.first?.transcript.first?.text, "确认范围")
        XCTAssertEqual(meetings.first?.summary?.tasks.first?.title, "准备发布")
    }

    func testStoredMeetingKeepsTranscriptSourceAndMeetingTime() throws {
        let data = Data(
            (#"[{"schema_version":2,"meeting_id":"meeting-source","status":"completed","#
                + #""started_at":"2026-07-26T10:00:00Z","ended_at":"2026-07-26T10:05:00Z","events":[{"#
                + #""event_id":"event-1","meeting_id":"meeting-source","sequence":1,"#
                + #""occurred_at":"2026-07-26T10:00:01Z","kind":"transcript","#
                + #""provenance":{"source":"native_transcript"},"payload":{"type":"transcript","#
                + #""segment_id":"08f0900a-a756-48db-bf38-d3040ddcd986","text":"我会负责回滚","#
                + #""speaker":"我","source":"microphone","meeting_time_ms":1250,"#
                + #""translated_text":"I will handle rollback"}}]}]"#)
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertEqual(meeting.transcript.first?.source, .microphone)
        XCTAssertEqual(meeting.transcript.first?.meetingTime, .milliseconds(1_250))
        XCTAssertEqual(meeting.transcript.first?.translatedText, "I will handle rollback")
    }

    func testStoredMeetingRestoresLatestAcceptedSuggestions() throws {
        let data = Data(
            (#"[{"schema_version":2,"meeting_id":"meeting-suggestions","status":"completed","#
                + #""started_at":"2026-07-26T10:00:00Z","events":[{"event_id":"event-1","#
                + #""meeting_id":"meeting-suggestions","sequence":1,"occurred_at":"2026-07-26T10:00:01Z","#
                + #""kind":"suggestions","provenance":{"source":"suggestion_service"},"#
                + #""payload":{"type":"suggestions","generation_id":"22222222-2222-2222-2222-222222222222","#
                + #""context_revision":2,"questions":["谁负责上线？","何时冻结范围？"]}},{"#
                + #""event_id":"event-2","meeting_id":"meeting-suggestions","sequence":2,"#
                + #""occurred_at":"2026-07-26T10:00:02Z","kind":"suggestions","#
                + #""provenance":{"source":"suggestion_service"},"payload":{"type":"suggestions","#
                + #""generation_id":"33333333-3333-3333-3333-333333333333","context_revision":3,"#
                + #""questions":[]}}]}]"#)
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertEqual(meeting.suggestions, ["谁负责上线？", "何时冻结范围？"])
    }

    func testUntitledVersionTwoRecordKeepsStableDisplayFallbackWithoutChangingSchemaValue() throws {
        let data = Data(
            (#"[{"schema_version":2,"meeting_id":"meeting-untitled","status":"completed","#
                + #""started_at":"2026-07-30T10:00:00Z","events":[{"event_id":"event-1","#
                + #""meeting_id":"meeting-untitled","sequence":1,"occurred_at":"2026-07-30T10:00:01Z","#
                + #""kind":"transcript","provenance":{"source":"native_transcript"},"#
                + #""payload":{"type":"transcript","segment_id":"08f0900a-a756-48db-bf38-d3040ddcd986","#
                + #""text":"确认周五发布。后续内容不应进入标题","speaker":"林晨"}}]}]"#)
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertNil(meeting.title)
        XCTAssertEqual(meeting.schemaVersion, 2)
        XCTAssertEqual(meeting.displayTitle, "确认周五发布")
    }

    func testGenericStoredTitleUsesMeetingOwnedDisplayFallback() {
        let meeting = StoredMeeting(
            id: "meeting-generic",
            schemaVersion: 2,
            title: "新会议",
            startTime: Date(timeIntervalSince1970: 1_000),
            transcript: [
                TranscriptLine(speaker: "林晨", text: "新会议"),
                TranscriptLine(speaker: "林晨", text: "移动端登录恢复方案")
            ],
            summary: nil
        )

        XCTAssertEqual(meeting.title, "新会议")
        XCTAssertEqual(meeting.displayTitle, "移动端登录恢复方案")
    }

    func testEmptyHistoricalMeetingUsesTruthfulTimestampDisplayFallback() {
        let meeting = StoredMeeting(
            id: "meeting-empty",
            schemaVersion: 2,
            startTime: Date(timeIntervalSince1970: 1_000),
            transcript: [],
            summary: nil
        )

        XCTAssertTrue(meeting.displayTitle.hasSuffix("空会议"))
        XCTAssertNotEqual(meeting.displayTitle, "历史会议")
    }

    func testHistoricalReplayRetainsMarkdownAcrossAnswerSummaryDecisionAndTasks() throws {
        let data = Data(
            (#"[{"schema_version":2,"meeting_id":"meeting-markdown","title":"发布复盘","#
                + #""status":"completed","started_at":"2026-07-30T10:00:00Z","events":[{"#
                + #""event_id":"question","meeting_id":"meeting-markdown","sequence":1,"#
                + #""occurred_at":"2026-07-30T10:01:00Z","kind":"user_question","#
                + #""provenance":{"source":"desktop_agent"},"payload":{"type":"user_question","#
                + #""request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","#
                + #""question":"发布结论？"}},{"event_id":"answer","meeting_id":"meeting-markdown","#
                + #""sequence":2,"occurred_at":"2026-07-30T10:01:01Z","kind":"assistant_answer","#
                + #""provenance":{"source":"desktop_agent"},"payload":{"type":"assistant_answer","#
                + #""request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","#
                + ###""answer":"## 结论\n\n**周五上线**","sources":[],"degraded_vision":false,"###
                + #""status":"completed"}},{"event_id":"summary","meeting_id":"meeting-markdown","#
                + #""sequence":3,"occurred_at":"2026-07-30T10:02:00Z","kind":"summary","#
                + #""provenance":{"source":"summary_service"},"payload":{"type":"summary","#
                + #""summary_text":"发布窗口已 **确认**","key_points":["冻结 `API`"],"#
                + #""decisions":["周五上线"],"tasks":[{"task":"准备回滚","assignee":"周岚","#
                + #""deadline":"周四","priority":"high","status":"pending"}]}}]}]"#)
                .utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)
        let summary = try XCTUnwrap(meeting.summary)

        XCTAssertEqual(meeting.conversation.first?.answer, "## 结论\n\n**周五上线**")
        XCTAssertEqual(
            MarkdownDocument.parse(meeting.conversation[0].answer, mode: .completed).first?.kind,
            .heading(level: 2)
        )
        XCTAssertTrue(MeetingMarkdownFormatter.summary(summary).contains("冻结 `API`"))
        XCTAssertTrue(MeetingMarkdownFormatter.tasks(summary.tasks).contains("负责人：周岚"))
    }
}
