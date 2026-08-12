import XCTest

@testable import PromptMeet

extension MeetingStoreTests {
    func testRequestQuestionsUsesCurrentBackendSession() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        await store.requestQuestionsNow()

        XCTAssertEqual(backend.questionRequests.count, 1)
        XCTAssertEqual(store.state.latestInsight, "正在生成值得追问的问题")
    }

    func testScreenshotRequiresSelectionAndSelectionIsSeparateFromCapture() async {
        let screenshot = ScreenshotCaptureControllerSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            screenshotController: screenshot,
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        await store.requestScreenshotNow()
        XCTAssertEqual(store.state.latestInsight, "请先选择窗口")
        XCTAssertEqual(screenshot.captureCount, 1)
        XCTAssertEqual(screenshot.selectionCount, 0)

        await store.selectCaptureTargetNow()
        XCTAssertEqual(screenshot.selectionCount, 1)
        XCTAssertEqual(screenshot.captureCount, 1)
        XCTAssertEqual(store.state.screenshotTarget, .selected(label: "测试窗口"))
    }

    func testGeneratedQuestionsAreCollectedWithoutReplacingAIAnswer() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        await store.submitPromptNow("总结风险")
        let requestID = try XCTUnwrap(backend.prompts.first?.id)
        backend.emit(.answerFinal(requestID: requestID, answer: "当前风险有两项"))

        backend.emit(.question("负责人和截止日期分别是什么？"))
        await Task.yield()

        XCTAssertEqual(store.state.generatedQuestions, ["负责人和截止日期分别是什么？"])
        XCTAssertEqual(store.state.aiReader.content, "当前风险有两项")
    }

    func testPartialGroundedQuestionsReplaceAtomicallyAndEmptyResultPreservesThem() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        await store.requestQuestionsNow()
        let partialRequest = try XCTUnwrap(backend.questionRequests.last)
        backend.emit(
            .questions(
                generationID: partialRequest.generationID,
                contextRevision: partialRequest.contextRevision,
                questions: ["谁负责上线？", "何时冻结范围？"]
            )
        )
        await Task.yield()

        XCTAssertEqual(store.state.generatedQuestions, ["谁负责上线？", "何时冻结范围？"])
        XCTAssertEqual(store.state.suggestionRefresh.phase, .ready)

        await store.requestQuestionsNow()
        let emptyRequest = try XCTUnwrap(backend.questionRequests.last)
        backend.emit(
            .questions(
                generationID: emptyRequest.generationID,
                contextRevision: emptyRequest.contextRevision,
                questions: []
            )
        )
        await Task.yield()

        XCTAssertEqual(store.state.generatedQuestions, ["谁负责上线？", "何时冻结范围？"])
        XCTAssertEqual(store.state.suggestionRefresh.phase, .ready)
    }

    func testEachFinalTranscriptAutomaticallyRefreshesSuggestedQuestions() async throws {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try await waitUntil { backend.questionRequests.count == 1 }
        capture.emit(LocalTranscript(source: .microphone, text: "第二条"))
        try await waitUntil { backend.questionRequests.count == 2 }
    }

    func testSuggestedQuestionsRefreshAfterEveryNewTranscript() async throws {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try await waitUntil { backend.questionRequests.count == 1 }
        capture.emit(LocalTranscript(source: .microphone, text: "第二条"))
        try await waitUntil { backend.questionRequests.count == 2 }
    }

    func testSuggestedQuestionRefreshCoalescesTranscriptsArrivingDuringGeneration() async {
        let backend = BackendClientSpy()
        backend.questionDelay = .milliseconds(40)
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try? await Task.sleep(for: .milliseconds(15))
        for text in ["第二条", "第三条", "第四条"] {
            capture.emit(LocalTranscript(source: .microphone, text: text))
        }
        for _ in 0..<100 {
            if backend.questionCompletionCount == 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(backend.questionRequests.map(\.contextRevision), [1, 4])
        XCTAssertEqual(backend.questionCompletionCount, 2)
        XCTAssertEqual(backend.questionCancellationCount, 0)
    }

    func testInFlightSuggestionSetIsAcceptedWhileNewerContextWaits() async throws {
        let backend = BackendClientSpy()
        backend.questionDelay = .milliseconds(40)
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(10),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try await waitUntil { backend.questionRequests.count == 1 }
        let first = try XCTUnwrap(backend.questionRequests.first)
        capture.emit(LocalTranscript(source: .microphone, text: "第二条"))
        try await waitUntil { store.state.suggestionRefresh.contextRevision == 2 }
        backend.emit(
            .questions(
                generationID: first.generationID,
                contextRevision: first.contextRevision,
                questions: ["首轮问题一", "首轮问题二", "首轮问题三"]
            )
        )
        await Task.yield()

        XCTAssertEqual(
            store.state.generatedQuestions,
            ["首轮问题一", "首轮问题二", "首轮问题三"]
        )
        XCTAssertEqual(backend.questionRequests.count, 1)
    }

    func testOlderSuggestionGenerationCannotOverwriteNewerContext() async throws {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try await waitUntil { backend.questionRequests.count == 1 }
        let first = try XCTUnwrap(backend.questionRequests.first)
        backend.emit(.screenshotInsight("截图显示新的预算"))
        try await waitUntil { backend.questionRequests.count == 2 }
        let second = try XCTUnwrap(backend.questionRequests.last)

        backend.emit(
            .questions(
                generationID: first.generationID,
                contextRevision: first.contextRevision,
                questions: ["旧问题"]
            )
        )
        await Task.yield()
        XCTAssertFalse(store.state.generatedQuestions.contains("旧问题"))

        backend.emit(
            .questions(
                generationID: second.generationID,
                contextRevision: second.contextRevision,
                questions: ["新问题一", "新问题二", "新问题三"]
            )
        )
        await Task.yield()
        XCTAssertEqual(store.state.generatedQuestions, ["新问题一", "新问题二", "新问题三"])
    }

    func testDuplicateMeaningfulContextDoesNotScheduleAnotherSuggestionGeneration() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        let event = MeetingTimelineEvent(
            eventID: "analysis-1",
            meetingID: "session-1",
            sequence: 4,
            occurredAt: Date(),
            kind: .screenshotAnalysis,
            provenance: TimelineProvenance(
                source: "multimodal_analysis",
                provider: "openai",
                model: "vision-model",
                requestID: nil
            ),
            payload: .screenshotAnalysis(
                TimelineScreenshotAnalysisPayload(
                    assetID: "asset-1",
                    status: "completed",
                    text: "截图显示发布风险",
                    visionUsed: true,
                    evidenceKind: "vision",
                    imageRejection: nil
                )
            )
        )

        store.receive(.meetingEvent(event))
        try await waitUntil { backend.questionRequests.count == 1 }
        store.receive(.meetingEvent(event))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(backend.questionRequests.count, 1)
    }

    func testScreenshotAnalysisEventCompletesVisibleCaptureOperation() async {
        let screenshot = ScreenshotCaptureControllerSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            screenshotController: screenshot,
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        await store.selectCaptureTargetNow()
        await store.requestScreenshotNow()
        XCTAssertEqual(store.state.screenshotOperation, .succeeded)
        let event = MeetingTimelineEvent(
            eventID: "analysis-completed",
            meetingID: "session-1",
            sequence: 4,
            occurredAt: Date(),
            kind: .screenshotAnalysis,
            provenance: TimelineProvenance(
                source: "multimodal_analysis",
                provider: "openai",
                model: "vision-model",
                requestID: nil
            ),
            payload: .screenshotAnalysis(
                TimelineScreenshotAnalysisPayload(
                    assetID: "asset-1",
                    status: "completed",
                    text: "截图显示发布风险",
                    visionUsed: true,
                    evidenceKind: "vision",
                    imageRejection: nil
                )
            )
        )

        store.receive(.meetingEvent(event))

        XCTAssertEqual(
            store.state.screenshotOperation,
            .analyzed(status: "completed", detail: "截图显示发布风险")
        )
    }

    func testSummaryContextTriggersSuggestionRefresh() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        backend.emit(
            .summary(
                MeetingSummaryContent(
                    summaryText: "决定周五发布",
                    tasks: [MeetingTask(title: "完成回滚演练")],
                    keyPoints: ["冻结范围"],
                    decisions: ["周五发布"]
                )
            )
        )
        try await waitUntil { backend.questionRequests.count == 1 }

        XCTAssertEqual(backend.questionRequests.map(\.contextRevision), [1])
    }

    func testScreenshotAndRelevantAnswerTriggerDebouncedSuggestionRefresh() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        backend.emit(.screenshotInsight("截图显示风险列表"))
        try await waitUntil { backend.questionRequests.count == 1 }
        await store.submitPromptNow("谁负责？")
        let requestID = try XCTUnwrap(backend.prompts.last?.id)
        backend.emit(.answerFinal(requestID: requestID, answer: "周岚负责"))
        try await waitUntil { backend.questionRequests.count == 2 }

        XCTAssertEqual(backend.questionRequests.map(\.contextRevision), [1, 2])
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not become true")
    }

}
