import XCTest

@testable import PromptMeet

final class MeetingHistorySearchTests: XCTestCase {
    func testTitleMatchRanksAheadOfBodyMatchWhileKeepingBoth() {
        let bodyMatch = meeting(
            id: "body-match",
            title: "架构讨论",
            transcript: ["The RELEASE checklist is ready"]
        )
        let titleMatch = meeting(
            id: "title-match",
            title: "Release Planning",
            transcript: ["unrelated body"]
        )

        let results = MeetingHistorySearch.results(
            in: [bodyMatch, titleMatch],
            query: "release"
        )

        XCTAssertEqual(results.map(\.id), ["title-match", "body-match"])
    }

    func testChineseSearchMatchesTranscriptSummaryDecisionAndTaskText() {
        let transcript = meeting(id: "transcript", transcript: ["移动端登录失败"])
        let summary = meeting(id: "summary", summaryText: "海外账单调整")
        let decision = meeting(id: "decision", decisions: ["周五冻结范围"])
        let task = meeting(
            id: "task",
            tasks: [
                MeetingTask(
                    title: "准备回滚演练",
                    deadline: "周四",
                    details: "覆盖支付链路",
                    priority: "high",
                    assignee: "周岚",
                    status: "pending"
                )
            ]
        )
        let meetings = [transcript, summary, decision, task]

        XCTAssertEqual(
            MeetingHistorySearch.results(in: meetings, query: "登录").map(\.id),
            ["transcript"]
        )
        XCTAssertEqual(
            MeetingHistorySearch.results(in: meetings, query: "账单").map(\.id),
            ["summary"]
        )
        XCTAssertEqual(
            MeetingHistorySearch.results(in: meetings, query: "冻结").map(\.id),
            ["decision"]
        )
        XCTAssertEqual(
            MeetingHistorySearch.results(in: meetings, query: "周岚 支付").map(\.id),
            ["task"]
        )
    }

    func testAsciiSearchIsCaseInsensitiveAndSupportsMultipleTerms() {
        let matching = meeting(
            id: "matching",
            title: "KV Cache Review",
            transcript: ["Latency benchmark"]
        )
        let other = meeting(id: "other", title: "Planning")

        XCTAssertEqual(
            MeetingHistorySearch.results(
                in: [matching, other],
                query: "kv BENCHMARK"
            ).map(\.id),
            ["matching"]
        )
    }

    func testDuplicateTitlesRemainIndependentAndKeepHistoryOrder() {
        let first = meeting(id: "first", title: "发布复盘")
        let second = meeting(id: "second", title: "发布复盘")

        let results = MeetingHistorySearch.results(
            in: [first, second],
            query: "发布"
        )

        XCTAssertEqual(results.map(\.id), ["first", "second"])
    }

    func testEmptyQueryPreservesHistoryOrderAndNoMatchIsEmpty() {
        let meetings = [
            meeting(id: "newest", title: "第一场"),
            meeting(id: "older", title: "第二场")
        ]

        XCTAssertEqual(
            MeetingHistorySearch.results(in: meetings, query: "   ").map(\.id),
            ["newest", "older"]
        )
        XCTAssertTrue(
            MeetingHistorySearch.results(in: meetings, query: "不存在").isEmpty
        )
    }

    func testWorkspacePreviewProvidesSearchableSyntheticHistory() {
        let history = MeetingState.previewWorkspace.meetingHistory

        XCTAssertGreaterThanOrEqual(history.count, 3)
        XCTAssertEqual(
            MeetingHistorySearch.results(in: history, query: "rollback").map(\.id),
            ["preview-release-history"]
        )
        XCTAssertTrue(history.contains { !$0.conversation.isEmpty })
        XCTAssertTrue(history.contains { $0.summary?.tasks.isEmpty == false })
        let releaseHistory = history.first { $0.id == "preview-release-history" }
        XCTAssertFalse(WorkspaceProjection(meeting: releaseHistory).items.isEmpty)
    }
}

private func meeting(
    id: String,
    title: String? = nil,
    transcript: [String] = [],
    summaryText: String = "",
    decisions: [String] = [],
    tasks: [MeetingTask] = []
) -> StoredMeeting {
    let summary = summaryText.isEmpty && decisions.isEmpty && tasks.isEmpty
        ? nil
        : MeetingSummaryContent(
            summaryText: summaryText,
            tasks: tasks,
            keyPoints: [],
            decisions: decisions
        )
    return StoredMeeting(
        id: id,
        schemaVersion: 2,
        title: title,
        startTime: Date(timeIntervalSince1970: 1_000),
        transcript: transcript.map { TranscriptLine(speaker: "发言人", text: $0) },
        summary: summary
    )
}
