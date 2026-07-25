import XCTest
@testable import PromptMeet

final class MeetingStateTests: XCTestCase {
    func testSuccessfulCompanionConnectionClearsStaleFailureMessage() {
        var state = MeetingState()
        state.reduce(.companionDisconnected("本地转写可用 · AI companion 暂未连接"))

        state.reduce(.companionConnected)

        XCTAssertTrue(state.isCompanionConnected)
        XCTAssertNil(state.latestInsight)
    }

    func testSummaryDoesNotOpenOrReplaceAIReader() {
        var state = MeetingState.previewLive
        let summary = MeetingSummaryContent(
            summaryText: "完整会议摘要",
            tasks: [MeetingTask(title: "准备发布", deadline: "明天")],
            keyPoints: ["范围冻结"],
            decisions: ["周五上线"]
        )

        state.reduce(.summaryGenerated(summary))

        XCTAssertEqual(state.latestSummary, "完整会议摘要")
        XCTAssertEqual(state.summary?.tasks.first?.title, "准备发布")
        XCTAssertEqual(state.summary?.keyPoints, ["范围冻结"])
        XCTAssertFalse(state.aiReader.isVisible)
        XCTAssertTrue(state.aiReader.content.isEmpty)
    }

    func testTranslationIsAttachedWithoutReplacingOriginalTranscript() {
        var state = MeetingState()
        let id = UUID()
        state.reduce(.transcriptFinal(TranscriptLine(id: id, speaker: "会议", text: "Hello team")))

        state.reduce(.transcriptTranslated(id: id, text: "大家好"))

        XCTAssertEqual(state.transcript.first?.text, "Hello team")
        XCTAssertEqual(state.transcript.first?.translatedText, "大家好")
    }

    func testPartialTranscriptReplacesOnlyTheActiveLine() {
        var state = MeetingState.previewLive

        state.reduce(.transcriptPartial("评分标准"))
        state.reduce(.transcriptPartial("评分标准需要确认"))

        XCTAssertEqual(state.activeTranscript, "评分标准需要确认")
        XCTAssertEqual(state.transcript.count, 1)
    }

    func testReaderAppearsOnlyAfterRequestedAnswerStarts() {
        var state = MeetingState.previewLive
        let requestID = UUID()

        state.reduce(.suggestion("预算上限待确认"))
        XCTAssertFalse(state.aiReader.isVisible)

        state.reduce(.userPromptSubmitted(id: requestID, prompt: "整理要点"))
        XCTAssertFalse(state.aiReader.isVisible)
        XCTAssertEqual(state.aiRequest.phase, .submitting)

        state.reduce(.answerDelta(requestID: requestID, delta: "已整理"))
        XCTAssertTrue(state.aiReader.isVisible)
        XCTAssertEqual(state.aiReader.content, "已整理")
        XCTAssertEqual(state.aiRequest.phase, .streaming)
    }

    func testAutomaticInsightNeverReplacesReaderContent() {
        var state = MeetingState.previewReader

        state.reduce(.suggestion("预算上限待确认"))

        XCTAssertEqual(state.aiReader.content, "已完成的回答")
        XCTAssertEqual(state.latestInsight, "预算上限待确认")
    }

    func testFinalAnswerKeepsReaderVisible() {
        var state = MeetingState.previewLive
        let requestID = UUID()
        state.reduce(.userPromptSubmitted(id: requestID, prompt: "总结"))
        state.reduce(.answerDelta(requestID: requestID, delta: "内容"))

        state.reduce(.answerFinal(requestID: requestID, answer: "内容完成"))

        XCTAssertTrue(state.aiReader.isVisible)
        XCTAssertEqual(state.aiReader.content, "内容完成")
        XCTAssertFalse(state.aiReader.isStreaming)
        XCTAssertEqual(state.aiRequest.phase, .completed)
    }

    func testMismatchedAnswerIsIgnored() {
        var state = MeetingState.previewLive
        let activeID = UUID()
        state.reduce(.userPromptSubmitted(id: activeID, prompt: "总结"))

        state.reduce(.answerDelta(requestID: UUID(), delta: "错误会话"))

        XCTAssertFalse(state.aiReader.isVisible)
        XCTAssertTrue(state.aiReader.content.isEmpty)
        XCTAssertEqual(state.aiRequest.phase, .submitting)
    }

    func testAIErrorStaysInlineAndDoesNotFailMeeting() {
        var state = MeetingState.previewLive
        let requestID = UUID()
        state.reduce(.userPromptSubmitted(id: requestID, prompt: "总结"))

        state.reduce(.aiFailure(requestID: requestID, message: "模型暂时不可用"))

        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.aiRequest.phase, .failed)
        XCTAssertEqual(state.aiRequest.errorMessage, "模型暂时不可用")
        XCTAssertFalse(state.aiReader.isVisible)
    }

    func testSubmittedPromptsRemainVisibleInWorkbenchHistory() {
        var state = MeetingState.previewLive

        state.reduce(.userPromptSubmitted(id: UUID(), prompt: "第一问"))
        state.reduce(.userPromptSubmitted(id: UUID(), prompt: "第二问"))

        XCTAssertEqual(state.promptHistory, ["第一问", "第二问"])
    }

    func testTranscriptEchoWithSameIDIsDeduplicated() {
        var state = MeetingState()
        let line = TranscriptLine(id: UUID(), speaker: "我", text: "只出现一次")

        state.reduce(.transcriptFinal(line))
        state.reduce(.transcriptFinal(line))

        XCTAssertEqual(state.transcript.count, 1)
    }

    func testGeneratedQuestionsAreDeduplicatedAndRemainVisible() {
        var state = MeetingState.previewLive

        state.reduce(.questionGenerated("预算上限是多少？"))
        state.reduce(.questionGenerated("预算上限是多少？"))
        state.reduce(.questionGenerated("谁负责下一步？"))

        XCTAssertEqual(state.generatedQuestions, ["预算上限是多少？", "谁负责下一步？"])
        XCTAssertEqual(state.latestInsight, "谁负责下一步？")
    }

    func testNewQuestionBatchReplacesStaleSuggestions() {
        var state = MeetingState.previewLive
        state.reduce(.questionsGenerated(["旧问题一", "旧问题二"]))

        state.reduce(.questionsGenerated(["新问题一", "新问题二", "新问题三"]))

        XCTAssertEqual(state.generatedQuestions, ["新问题一", "新问题二", "新问题三"])
        XCTAssertEqual(state.latestInsight, "新问题一")
    }

    func testQuickAskPresentationAndDraftAreSharedState() {
        var state = MeetingState.previewLive

        state.reduce(.quickPromptChanged("预算上限是多少？"))
        state.reduce(.quickAskPresented(true))

        XCTAssertEqual(state.quickPromptDraft, "预算上限是多少？")
        XCTAssertTrue(state.isQuickAskPresented)
        XCTAssertEqual(state.islandPresentation(isHovered: false), .hoverLive)
        XCTAssertEqual(state.islandPresentation(isHovered: true), .hoverLive)
    }
}
