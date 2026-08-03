import Foundation

@testable import PromptMeet

@MainActor
final class NativeAudioCaptureSpy: NativeAudioCaptureCoordinating {
    var startedSessionID: String?
    var includedLocalMicrophone: Bool?
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
        request: NativeAudioCaptureRequest,
        onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void,
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onTranscriptionError: @escaping @Sendable (String) -> Void
    ) async throws {
        if let startError { throw startError }
        startedSessionID = request.sessionID
        includedLocalMicrophone = request.includeLocalMicrophone
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
final class ScreenshotCaptureControllerSpy: ScreenshotCaptureControlling {
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

    func cancelSelection() {}

    func openScreenRecordingSettings() {}
}

@MainActor
final class BlockingScreenshotCaptureControllerSpy: ScreenshotCaptureControlling {
    private(set) var targetState: ScreenshotTargetState = .none
    private(set) var cancelSelectionCount = 0
    private(set) var isSelecting = false
    private var selectionCount = 0
    private var continuation: CheckedContinuation<ScreenshotTargetState, Error>?

    func selectTarget() async throws -> ScreenshotTargetState {
        selectionCount += 1
        if selectionCount > 1 {
            targetState = .selected(label: "第二次选择")
            return targetState
        }
        isSelecting = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func captureSelected(sessionID: String) async throws {}

    func cancelSelection() {
        cancelSelectionCount += 1
        finishSelectionAsCancelled()
    }

    func finishSelectionAsCancelled() {
        guard let continuation else { return }
        self.continuation = nil
        isSelecting = false
        continuation.resume(throwing: ScreenshotPickerError.cancelled)
    }

    func openScreenRecordingSettings() {}
}

@MainActor
final class CompanionLauncherSpy: CompanionLaunching {
    var ensureCount = 0
    var reloadCount = 0
    var ensureDelay: Duration?
    private let error: (any Error)?
    private let onReload: (() -> Void)?

    init(error: (any Error)? = nil, onReload: (() -> Void)? = nil) {
        self.error = error
        self.onReload = onReload
    }

    func ensureRunning() async throws {
        ensureCount += 1
        if let ensureDelay { try await Task.sleep(for: ensureDelay) }
        if let error { throw error }
    }

    func stopOwnedProcess() {}

    func reloadConfiguration() async throws {
        reloadCount += 1
        onReload?()
        if let error { throw error }
    }
}

final class BackendClientSpy: BackendClientProtocol, @unchecked Sendable {
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

    struct RehydrateRequest: Equatable {
        let sessionID: String
        let isPaused: Bool
    }

    struct CreatedSessionRequest: Equatable {
        let sessionID: String
        let startedAt: Date
    }

    var summaryRequests: [SummaryGenerationRequest] = []
    var summaryResponse = SummaryGenerationResponse(
        success: true,
        status: .generated,
        message: "已生成"
    )

    var performedActions: [String] = []
    var healthCheckCount = 0
    var fetchHistoryCount = 0
    var connectCount = 0
    var connectedSessionID: String?
    var prompts: [Prompt] = []
    var submittedTranscripts: [LocalTranscript] = []
    var transcriptSubmissionError: (any Error)?
    var disconnectCount = 0
    var history: [StoredMeeting] = []
    var performDelay: Duration?
    var questionDelay: Duration?
    var questionRequests: [QuestionRequest] = []
    var questionCompletionCount = 0
    var questionCancellationCount = 0
    var createSessionCount = 0
    var createdSessionRequests: [CreatedSessionRequest] = []
    var rehydrateDelay: Duration?
    var rehydrateRequests: [RehydrateRequest] = []
    var rehydrateCancellationCount = 0
    var historicalQuestions: [HistoricalQuestion] = []
    private var eventHandler: (@Sendable (BackendEvent) -> Void)?

    func healthCheck() async throws {
        await MainActor.run { healthCheckCount += 1 }
    }

    func createSession(sessionID: String, startedAt: Date) async throws -> String {
        await MainActor.run {
            createSessionCount += 1
            createdSessionRequests.append(
                CreatedSessionRequest(sessionID: sessionID, startedAt: startedAt)
            )
        }
        return sessionID
    }

    func rehydrateSession(sessionID: String, isPaused: Bool) async throws {
        await MainActor.run {
            rehydrateRequests.append(
                RehydrateRequest(sessionID: sessionID, isPaused: isPaused)
            )
        }
        do {
            if let rehydrateDelay = await MainActor.run(body: { self.rehydrateDelay }) {
                try await Task.sleep(for: rehydrateDelay)
            }
        } catch is CancellationError {
            await MainActor.run { rehydrateCancellationCount += 1 }
            throw CancellationError()
        }
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
        do {
            if let questionDelay = await MainActor.run(body: { self.questionDelay }) {
                try await Task.sleep(for: questionDelay)
            }
            await MainActor.run { questionCompletionCount += 1 }
        } catch is CancellationError {
            await MainActor.run { questionCancellationCount += 1 }
            throw CancellationError()
        }
    }

    func generateSummary(
        sessionID: String,
        request: SummaryGenerationRequest
    ) async throws -> SummaryGenerationResponse {
        await MainActor.run {
            summaryRequests.append(request)
            performedActions.append("generate-summary")
        }
        return await MainActor.run { summaryResponse }
    }

    func connect(sessionID: String, onEvent: @escaping @Sendable (BackendEvent) -> Void) throws {
        connectedSessionID = sessionID
        connectCount += 1
        eventHandler = onEvent
    }

    func sendPrompt(_ prompt: String, requestID: UUID) async throws {
        await MainActor.run { prompts.append(Prompt(id: requestID, prompt: prompt)) }
    }

    func submitTranscript(_ transcript: LocalTranscript, sessionID: String) async throws {
        await MainActor.run { submittedTranscripts.append(transcript) }
        if let error = transcriptSubmissionError {
            throw error
        }
    }

    func fetchMeetingHistory() async throws -> [StoredMeeting] {
        await MainActor.run {
            fetchHistoryCount += 1
            return history
        }
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
        connectedSessionID = nil
        eventHandler = nil
    }

    func emit(_ event: BackendEvent) {
        eventHandler?(event)
    }
}
