import Combine
import Foundation
import XCTest

@testable import PromptMeet

@MainActor
final class MeetingStoreTests: XCTestCase {
    func testSharedDraftAndGeneratedQuestionsPublishImmediately() {
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        var snapshots: [MeetingState] = []
        let cancellable = store.$state
            .dropFirst()
            .sink { snapshots.append($0) }

        store.setQuickPromptDraft("谁负责上线？")
        store.receive(.question("截止日期是什么时候？"))

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].quickPromptDraft, "谁负责上线？")
        XCTAssertEqual(snapshots[1].generatedQuestions, ["截止日期是什么时候？"])
        withExtendedLifetime(cancellable) {}
    }

    func testStartMeetingCreatesSessionConnectsAndStartsRecording() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let companion = CompanionLauncherSpy()
        let store = MeetingStore(backend: backend, capture: capture, companion: companion)

        await store.startMeetingNow()

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertTrue(store.sessionID?.hasPrefix("local-") == true)
        XCTAssertEqual(backend.performedActions, ["start-native-recording"])
        XCTAssertEqual(backend.connectedSessionID, "session-1")
        XCTAssertEqual(capture.backendSessionID, "session-1")
        XCTAssertTrue(capture.startedSessionID?.hasPrefix("local-") == true)
        XCTAssertEqual(companion.ensureCount, 1)
    }

    func testCompanionCanBePrewarmedBeforeMeetingStarts() async {
        let companion = CompanionLauncherSpy()
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "retained-meeting",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: companion
        )

        await store.prepareCompanionNow()

        XCTAssertEqual(companion.ensureCount, 1)
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.meetingHistory.map(\.id), ["retained-meeting"])
    }

    func testAIConfigurationReloadRestartsOwnedCompanion() async {
        let companion = CompanionLauncherSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: companion
        )

        await store.reloadCompanionConfigurationNow()

        XCTAssertEqual(companion.reloadCount, 1)
        XCTAssertEqual(store.state.latestInsight, "AI 服务配置已更新")
    }

    func testBackendEventsDriveTranscriptAndReader() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.submitPromptNow("整理要点")
        let requestID = try XCTUnwrap(backend.prompts.first?.id)

        backend.emit(.transcript(TranscriptLine(speaker: "林晨", text: "确认范围")))
        backend.emit(.answerDelta(requestID: requestID, delta: "已整理"))

        await Task.yield()
        XCTAssertEqual(store.state.transcript.last?.text, "确认范围")
        XCTAssertTrue(store.state.aiReader.isVisible)
        XCTAssertEqual(backend.prompts.map(\.prompt), ["整理要点"])
    }

    func testLocalTranscriptAppearsImmediatelyAndIsSubmittedToBackend() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(id: UUID(), source: .microphone, text: "本地识别完成"))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.transcript.last?.text, "本地识别完成")
        XCTAssertEqual(store.state.transcript.last?.speaker, "我")
        XCTAssertEqual(backend.submittedTranscripts.map(\.text), ["本地识别完成"])
    }

    func testLocalPartialTranscriptStreamsIntoActiveCaption() async {
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emitPartial("这是正在连续识别的内容")
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.activeTranscript, "这是正在连续识别的内容")
        XCTAssertTrue(store.state.transcript.isEmpty)
    }

    func testCaptureSetupFailureRollsBackRecordingAndMarksDurableMeetingIncomplete() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy(startError: LocalTranscriptionError.modelNotInstalled)
        let store = MeetingStore(backend: backend, capture: capture, companion: CompanionLauncherSpy())

        await store.startMeetingNow()

        guard case .failed = store.state.phase else {
            return XCTFail("Expected failed meeting state")
        }
        XCTAssertEqual(
            backend.performedActions,
            ["start-native-recording", "stop-native-recording", "mark-incomplete"]
        )
        XCTAssertEqual(backend.createSessionCount, 1)
        XCTAssertEqual(backend.connectedSessionID, "session-1")
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(backend.disconnectCount, 0)
    }

    func testLocalTranscriptionStartsWhenCompanionIsUnavailable() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let companion = CompanionLauncherSpy(error: CompanionLauncherError.startupTimedOut)
        let store = MeetingStore(backend: backend, capture: capture, companion: companion)

        await store.startMeetingNow()
        capture.emit(LocalTranscript(source: .microphone, text: "离线字幕可用"))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertNotNil(capture.startedSessionID)
        XCTAssertNil(backend.connectedSessionID)
        XCTAssertTrue(backend.performedActions.isEmpty)
        XCTAssertEqual(store.state.transcript.last?.text, "离线字幕可用")
        XCTAssertTrue(backend.submittedTranscripts.isEmpty)
    }

    func testSourceStatusIsPublishedAndMicrophoneCanRecoverIndependently() async {
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emitStatus(AudioCaptureSnapshot(microphone: .denied, system: .active))
        await Task.yield()
        XCTAssertEqual(store.state.audioCapture.microphone, .denied)
        XCTAssertEqual(store.state.audioCapture.system, .active)

        await store.retryMicrophoneNow()
        XCTAssertEqual(capture.retriedSources, [.microphone])
    }

    func testEndingMeetingStoresSessionAndKeepsCompanionContextAvailable() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.endMeetingNow()
        await store.requestSummaryNow()
        await store.submitPromptNow("会后还可以提问吗？")

        XCTAssertEqual(
            backend.performedActions,
            ["start-native-recording", "stop-native-recording", "store-session", "generate-summary"]
        )
        XCTAssertEqual(backend.disconnectCount, 0)
        XCTAssertEqual(backend.prompts.map(\.prompt), ["会后还可以提问吗？"])
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertTrue(store.hasMeetingContext)
    }

    func testPauseResumeKeepsMeetingContextAndStopWhilePausedEndsNormally() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.pauseMeetingNow()
        XCTAssertEqual(store.state.phase, .live)
        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.pauseCount, 1)

        await store.resumeMeetingNow()
        XCTAssertEqual(store.state.recordingActivity, .recording)
        XCTAssertEqual(capture.resumeCount, 1)

        await store.pauseMeetingNow()
        await store.endMeetingNow()
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.recordingActivity, .inactive)
        XCTAssertEqual(
            backend.performedActions,
            [
                "start-native-recording",
                "pause-native-recording",
                "resume-native-recording",
                "pause-native-recording",
                "stop-native-recording",
                "store-session",
            ]
        )
    }

    func testResumeRollsBackendBackToPausedWhenLocalSourcesCannotRestart() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy(
            resumeError: CaptureError.systemAudioRuntimeFailure("restart failed")
        )
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.pauseMeetingNow()

        await store.resumeMeetingNow()

        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.resumeCount, 1)
        XCTAssertEqual(
            backend.performedActions,
            [
                "start-native-recording",
                "pause-native-recording",
                "resume-native-recording",
                "pause-native-recording",
            ]
        )
    }

    func testSaveMeetingStoresCurrentBackendSession() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.saveMeetingNow()

        XCTAssertEqual(backend.performedActions.last, "store-session")
        XCTAssertEqual(store.state.latestInsight, "会议已保存")
    }

    func testRequestQuestionsUsesCurrentBackendSession() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
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
            screenshotController: screenshot
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
            companion: CompanionLauncherSpy()
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

    func testEachFinalTranscriptAutomaticallyRefreshesSuggestedQuestions() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5)
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try? await Task.sleep(for: .milliseconds(40))
        capture.emit(LocalTranscript(source: .microphone, text: "第二条"))
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(
            backend.questionRequests.count,
            2
        )
    }

    func testSuggestedQuestionsRefreshAfterEveryNewTranscript() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5)
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try? await Task.sleep(for: .milliseconds(40))
        capture.emit(LocalTranscript(source: .microphone, text: "第二条"))
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(
            backend.questionRequests.count,
            2
        )
    }

    func testSuggestedQuestionRefreshCoalescesTranscriptsArrivingDuringGeneration() async {
        let backend = BackendClientSpy()
        backend.questionDelay = .milliseconds(40)
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5)
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(source: .microphone, text: "第一条"))
        try? await Task.sleep(for: .milliseconds(15))
        for text in ["第二条", "第三条", "第四条"] {
            capture.emit(LocalTranscript(source: .microphone, text: text))
        }
        for _ in 0..<50 {
            if backend.questionRequests.count == 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            backend.questionRequests.count,
            2
        )
    }

    func testOlderSuggestionGenerationCannotOverwriteNewerContext() async throws {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5)
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
                questions: ["新问题"]
            )
        )
        await Task.yield()
        XCTAssertEqual(store.state.generatedQuestions, ["新问题"])
    }

    func testScreenshotAndRelevantAnswerTriggerDebouncedSuggestionRefresh() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            suggestionDebounce: .milliseconds(5)
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

    func testQuickPromptUsesSharedDraftAndClosesShelfAfterSending() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        store.setQuickPromptDraft("  谁负责上线？  ")
        store.setQuickAskPresented(true)

        await store.submitQuickPromptNow()

        XCTAssertEqual(backend.prompts.map(\.prompt), ["谁负责上线？"])
        XCTAssertTrue(store.state.quickPromptDraft.isEmpty)
        XCTAssertFalse(store.state.isQuickAskPresented)
    }

    func testMeetingHistoryLoadsAndCanBeSelectedWithoutChangingLivePhase() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "历史", text: "旧会议内容")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )

        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        XCTAssertEqual(store.state.meetingHistory.map(\.id), ["archived-1"])
        XCTAssertEqual(store.state.displayedTranscript.first?.text, "旧会议内容")
        XCTAssertEqual(store.state.phase, .idle)
    }

    func testHistoricalQuestionUsesSelectedMeetingAndRefreshesDurableRecord() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "历史", text: "周岚负责回滚")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        await store.submitPromptNow("谁负责回滚？")

        XCTAssertEqual(backend.historicalQuestions.map(\.meetingID), ["archived-1"])
        XCTAssertEqual(
            store.state.conversationTurn(requestID: backend.historicalQuestions[0].requestID)?.answer, "历史回答")
    }

    func testViewingHistoryWhileLiveKeepsQuestionsScopedToArchivedMeeting() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "会议", text: "历史会议内容")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        await store.submitPromptNow("历史会议里谁负责？")

        XCTAssertEqual(backend.historicalQuestions.map(\.meetingID), ["archived-1"])
        XCTAssertTrue(backend.prompts.isEmpty)
        XCTAssertEqual(store.state.phase, .live)
    }

    func testStartingNewMeetingWhileLiveProtectsCurrentContext() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.startMeetingNow()

        XCTAssertEqual(backend.createSessionCount, 1)
        XCTAssertEqual(store.state.latestInsight, "当前会议仍在进行，请先结束后再开始新会议")
    }
}

@MainActor
private final class NativeAudioCaptureSpy: NativeAudioCaptureCoordinating {
    var startedSessionID: String?
    var stopCount = 0
    var backendSessionID: String?
    var pauseCount = 0
    var resumeCount = 0
    var retriedSources: [NativeAudioSource] = []
    private var statusHandler: (@Sendable (AudioCaptureSnapshot) -> Void)?
    private var transcriptHandler: (@Sendable (LocalTranscript) -> Void)?
    private var partialHandler: (@Sendable (String) -> Void)?
    private let startError: (any Error)?
    private let resumeError: (any Error)?

    init(startError: (any Error)? = nil, resumeError: (any Error)? = nil) {
        self.startError = startError
        self.resumeError = resumeError
    }

    func start(
        sessionID: String,
        onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void,
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onTranscriptionError: @escaping @Sendable (String) -> Void
    ) async throws {
        if let startError { throw startError }
        startedSessionID = sessionID
        partialHandler = onPartialTranscript
        transcriptHandler = onTranscript
        statusHandler = onStatus
        onStatus(AudioCaptureSnapshot(microphone: .active, system: .active))
    }

    func stop() async {
        stopCount += 1
    }

    func bindBackendSession(_ sessionID: String) async {
        backendSessionID = sessionID
    }

    func pause() async { pauseCount += 1 }
    func resume() async throws {
        resumeCount += 1
        if let resumeError { throw resumeError }
    }
    func retry(_ source: NativeAudioSource) async throws { retriedSources.append(source) }

    func emit(_ transcript: LocalTranscript) {
        transcriptHandler?(transcript)
    }

    func emitPartial(_ text: String) {
        partialHandler?(text)
    }

    func emitStatus(_ snapshot: AudioCaptureSnapshot) {
        statusHandler?(snapshot)
    }
}

@MainActor
private final class ScreenshotCaptureControllerSpy: ScreenshotCaptureControlling {
    private(set) var targetState: ScreenshotTargetState = .none
    private(set) var selectionCount = 0
    private(set) var captureCount = 0

    func selectTarget() async throws -> ScreenshotTargetState {
        selectionCount += 1
        targetState = .selected(label: "测试窗口")
        return targetState
    }

    func captureSelected(sessionID: String) async throws {
        captureCount += 1
        guard targetState != .none else { throw ScreenshotPickerError.noSelectedTarget }
    }

    func openScreenRecordingSettings() {}
}

@MainActor
private final class CompanionLauncherSpy: CompanionLaunching {
    var ensureCount = 0
    var reloadCount = 0
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func ensureRunning() async throws {
        ensureCount += 1
        if let error { throw error }
    }

    func stopOwnedProcess() {}

    func reloadConfiguration() async throws {
        reloadCount += 1
    }
}

private final class BackendClientSpy: BackendClientProtocol, @unchecked Sendable {
    struct Prompt: Equatable {
        let id: UUID
        let prompt: String
    }

    struct HistoricalQuestion: Equatable {
        let meetingID: String
        let requestID: UUID
        let question: String
    }

    struct QuestionRequest: Equatable {
        let sessionID: String
        let generationID: UUID
        let contextRevision: Int
    }

    var performedActions: [String] = []
    var connectedSessionID: String?
    var prompts: [Prompt] = []
    var submittedTranscripts: [LocalTranscript] = []
    var disconnectCount = 0
    var history: [StoredMeeting] = []
    var performDelay: Duration?
    var questionDelay: Duration?
    var questionRequests: [QuestionRequest] = []
    var createSessionCount = 0
    var historicalQuestions: [HistoricalQuestion] = []
    private var eventHandler: (@Sendable (BackendEvent) -> Void)?

    func healthCheck() async throws {}

    func createSession() async throws -> String {
        await MainActor.run { createSessionCount += 1 }
        return "session-1"
    }

    func perform(sessionID: String, action: String) async throws {
        if let performDelay = await MainActor.run(body: { self.performDelay }) {
            try await Task.sleep(for: performDelay)
        }
        await MainActor.run { performedActions.append(action) }
    }

    func generateQuestions(
        sessionID: String,
        generationID: UUID,
        contextRevision: Int
    ) async throws {
        await MainActor.run {
            questionRequests.append(
                QuestionRequest(
                    sessionID: sessionID,
                    generationID: generationID,
                    contextRevision: contextRevision
                )
            )
        }
        if let questionDelay = await MainActor.run(body: { self.questionDelay }) {
            try await Task.sleep(for: questionDelay)
        }
    }

    func connect(sessionID: String, onEvent: @escaping @Sendable (BackendEvent) -> Void) throws {
        connectedSessionID = sessionID
        eventHandler = onEvent
    }

    func sendPrompt(_ prompt: String, requestID: UUID) async throws {
        await MainActor.run { prompts.append(Prompt(id: requestID, prompt: prompt)) }
    }

    func submitTranscript(_ transcript: LocalTranscript, sessionID: String) async throws {
        await MainActor.run { submittedTranscripts.append(transcript) }
    }

    func fetchMeetingHistory() async throws -> [StoredMeeting] {
        await MainActor.run { history }
    }

    func fetchMeeting(id: String) async throws -> StoredMeeting {
        try await MainActor.run {
            guard let meeting = history.first(where: { $0.id == id }) else {
                throw BackendClientError.serviceMessage("会议不存在")
            }
            return meeting
        }
    }

    func askMeeting(
        meetingID: String,
        question: String,
        requestID: UUID,
        threadID: String
    ) async throws -> HistoricalMeetingAnswer {
        await MainActor.run {
            historicalQuestions.append(
                HistoricalQuestion(meetingID: meetingID, requestID: requestID, question: question)
            )
        }
        return HistoricalMeetingAnswer(
            requestID: requestID,
            answer: "历史回答",
            sources: [],
            degradedVision: false
        )
    }

    func disconnect() {
        disconnectCount += 1
    }

    func emit(_ event: BackendEvent) {
        eventHandler?(event)
    }
}
