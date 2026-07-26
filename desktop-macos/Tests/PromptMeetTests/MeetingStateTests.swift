import XCTest
@testable import PromptMeet

final class MeetingStateTests: XCTestCase {
    func testAuraPreviewIncludesInsightAndTwoSuggestedQuestions() {
        let state = MeetingState.previewAura

        XCTAssertNotNil(state.latestInsight)
        XCTAssertEqual(state.generatedQuestions.count, 2)
        XCTAssertEqual(state.transcript.count, 3)
    }

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

    func testFollowUpKeepsVisibleReaderOpenWhileSubmitting() {
        var state = MeetingState.previewReader

        state.reduce(.userPromptSubmitted(id: UUID(), prompt: "继续解释风险"))

        XCTAssertTrue(state.aiReader.isVisible)
        XCTAssertEqual(state.aiReader.title, "继续解释风险")
        XCTAssertTrue(state.aiReader.content.isEmpty)
        XCTAssertEqual(state.aiRequest.phase, .submitting)
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

    func testConcurrentAnswersRemainBoundToTheirOwnConversationTurns() {
        var state = MeetingState()
        let first = UUID()
        let second = UUID()
        state.reduce(.userPromptSubmitted(id: first, prompt: "风险？"))
        state.reduce(.userPromptSubmitted(id: second, prompt: "负责人？"))

        state.reduce(.answerDelta(requestID: first, delta: "范围"))
        state.reduce(.answerFinal(requestID: second, answer: "林晨"))
        state.reduce(.answerFinal(requestID: first, answer: "范围漂移"))

        XCTAssertEqual(state.conversationTurn(requestID: first)?.answer, "范围漂移")
        XCTAssertEqual(state.conversationTurn(requestID: second)?.answer, "林晨")
        XCTAssertEqual(state.conversationTurn(requestID: first)?.phase, .completed)
        XCTAssertEqual(state.conversationTurn(requestID: second)?.phase, .completed)
    }

    func testDurableAnswerEventRemainsVisibleInActiveMeetingConversation() {
        var state = MeetingState(phase: .live)
        let requestID = UUID()
        let askedAt = Date()
        state.reduce(.userPromptSubmitted(id: requestID, prompt: "谁负责发布？"))
        state.reduce(
            .meetingEvent(
                MeetingTimelineEvent(
                    eventID: "question-event",
                    meetingID: "active-meeting",
                    sequence: 1,
                    occurredAt: askedAt,
                    kind: .userQuestion,
                    provenance: TimelineProvenance(
                        source: "user",
                        provider: nil,
                        model: nil,
                        requestID: requestID.uuidString
                    ),
                    payload: .userQuestion(
                        TimelineQuestionPayload(
                            requestID: requestID.uuidString,
                            threadID: "main",
                            question: "谁负责发布？"
                        )
                    )
                )
            )
        )
        state.reduce(
            .meetingEvent(
                MeetingTimelineEvent(
                    eventID: "answer-event",
                    meetingID: "active-meeting",
                    sequence: 2,
                    occurredAt: askedAt.addingTimeInterval(1),
                    kind: .assistantAnswer,
                    provenance: TimelineProvenance(
                        source: "meeting_agent",
                        provider: "fake",
                        model: "fake-chat",
                        requestID: requestID.uuidString
                    ),
                    payload: .assistantAnswer(
                        TimelineAnswerPayload(
                            requestID: requestID.uuidString,
                            threadID: "main",
                            answer: "林晨负责发布。",
                            sources: [],
                            degradedVision: false,
                            status: "completed",
                            errorMessage: nil
                        )
                    )
                )
            )
        )

        XCTAssertEqual(state.displayedConversation.count, 1)
        XCTAssertEqual(state.displayedConversation.first?.meetingID, "active-meeting")
        XCTAssertEqual(state.displayedConversation.first?.answer, "林晨负责发布。")
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

    func testFailedCaptureOffersRetryInsteadOfClaimingRecordingIsActive() {
        let presentation = MeetingControlPresentation(
            phase: .failed("没有可用的音频来源")
        )

        XCTAssertEqual(presentation.startTitle, "重试录音")
        XCTAssertEqual(presentation.transcriptPlaceholder, "录音未开始，请检查权限或音频来源后重试。")
        XCTAssertTrue(presentation.canStart)
        XCTAssertFalse(presentation.canStop)
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

    func testEmptyQuestionBatchClearsStaleSuggestions() {
        var state = MeetingState.previewLive
        state.reduce(.questionsGenerated(["已经过时的问题"]))

        state.reduce(.questionsGenerated([]))

        XCTAssertTrue(state.generatedQuestions.isEmpty)
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
