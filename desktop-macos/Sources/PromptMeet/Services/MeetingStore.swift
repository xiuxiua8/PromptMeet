import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var state = MeetingState()
    @Published private(set) var isHovered = false
    @Published private(set) var sessionID: String?
    @Published private(set) var topChromeWidth: CGFloat = 200
    @Published private(set) var topChromeHeight: CGFloat = 34
    private var backendSessionID: String?
    private var uiPreviewMode: String?

    private let backend: BackendClientProtocol
    private let capture: NativeAudioCaptureCoordinating
    private let companion: CompanionLaunching
    private let screenshotPicker: ScreenshotSelecting
    private let questionRefreshStride = 1
    private var lastQuestionGenerationTranscriptCount = 0
    private var isQuestionGenerationInFlight = false

    init(
        backend: BackendClientProtocol = BackendClient(),
        capture: NativeAudioCaptureCoordinating = NativeAudioCaptureCoordinator(),
        companion: CompanionLaunching = CompanionLauncher(),
        screenshotPicker: ScreenshotSelecting = ScreenCapturePicker()
    ) {
        self.backend = backend
        self.capture = capture
        self.companion = companion
        self.screenshotPicker = screenshotPicker
    }

    var presentation: IslandPresentation {
        state.islandPresentation(isHovered: isHovered)
    }

    var hasMeetingContext: Bool {
        backendSessionID != nil || uiPreviewMode != nil
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    func updateNotchInfo(_ notch: NotchInfo) {
        topChromeWidth = max(100, notch.width)
        topChromeHeight = max(24, notch.height)
    }

    func configureUIPreview(_ mode: String) {
        uiPreviewMode = mode
        switch mode {
        case "live":
            state = .previewAura
            isHovered = false
        case "hover":
            state = .previewAura
            isHovered = true
        case "workspace":
            state = .previewWorkspace
            isHovered = false
        case "reader-short":
            state = .previewReader
            isHovered = false
        case "reader-long":
            state = .previewLongReader
            isHovered = false
        default:
            state = MeetingState()
            isHovered = false
        }
    }

    func startMeeting() {
        Task { await startMeetingNow() }
    }

    func prepareCompanion() {
        Task { await prepareCompanionNow() }
    }

    func prepareCompanionNow() async {
        do {
            try await companion.ensureRunning()
            await loadMeetingHistoryNow()
        } catch {
            state.reduce(.suggestion("AI companion 暂未连接：\(error.localizedDescription)"))
        }
    }

    func reloadCompanionConfiguration() {
        Task { await reloadCompanionConfigurationNow() }
    }

    func reloadCompanionConfigurationNow() async {
        do {
            try await companion.reloadConfiguration()
            state.reduce(.companionConnected)
            state.reduce(.suggestion("AI 服务配置已更新"))
        } catch {
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func endMeeting() {
        Task { await endMeetingNow() }
    }

    func replaceActiveMeeting() {
        Task {
            if state.phase == .live || state.phase == .connecting {
                await endMeetingNow()
            }
            await startMeetingNow()
        }
    }

    func requestSummary() {
        Task { await requestSummaryNow() }
    }

    func requestQuestions() {
        Task { await requestQuestionsNow() }
    }

    func saveMeeting() {
        Task { await saveMeetingNow() }
    }

    func requestScreenshot() {
        Task { await requestScreenshotNow() }
    }

    func submitPrompt(_ prompt: String) {
        Task { await submitPromptNow(prompt) }
    }

    func retryPrompt(_ prompt: String) {
        Task { await submitPromptNow(prompt) }
    }

    func setQuickPromptDraft(_ prompt: String) {
        state.reduce(.quickPromptChanged(prompt))
    }

    func setQuickAskPresented(_ isPresented: Bool) {
        state.reduce(.quickAskPresented(isPresented))
    }

    func toggleQuickAsk() {
        setQuickAskPresented(!state.isQuickAskPresented)
    }

    func useSuggestedQuestion(_ question: String) {
        setQuickPromptDraft(question)
        setQuickAskPresented(true)
    }

    func submitQuickPrompt() {
        Task { await submitQuickPromptNow() }
    }

    func submitQuickPromptNow() async {
        let prompt = state.quickPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.aiRequest.isBusy else { return }
        state.reduce(.quickPromptChanged(""))
        state.reduce(.quickAskPresented(false))
        await submitPromptNow(prompt)
    }

    func loadMeetingHistory() {
        Task { await loadMeetingHistoryNow() }
    }

    func loadMeetingHistoryNow() async {
        guard uiPreviewMode == nil else { return }
        do {
            state.reduce(.meetingHistoryLoaded(try await backend.fetchMeetingHistory()))
        } catch {
            state.reduce(.suggestion("历史会议暂时无法读取"))
        }
    }

    func selectArchivedMeeting(_ id: String?) {
        state.reduce(.archivedMeetingSelected(id))
    }

    func startMeetingNow() async {
        guard state.phase != .live && state.phase != .connecting else {
            state.reduce(.suggestion("当前会议仍在进行，请先结束后再开始新会议"))
            return
        }
        if backendSessionID != nil {
            backend.disconnect()
            backendSessionID = nil
        }
        state.reduce(.prepareNewMeeting)
        state.reduce(.beginSession)
        let localSessionID = "local-\(UUID().uuidString)"
        do {
            try await companion.ensureRunning()
            try await backend.healthCheck()
            let remoteSessionID = try await backend.createSession()
            try backend.connect(sessionID: remoteSessionID) { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
            backendSessionID = remoteSessionID
            state.reduce(.companionConnected)
        } catch {
            backend.disconnect()
            backendSessionID = nil
            state.reduce(.companionDisconnected("本地转写可用 · AI 服务连接失败：\(error.localizedDescription)"))
        }

        do {
            try await capture.start(
                sessionID: localSessionID,
                onPartialTranscript: { [weak self] text in
                    Task { @MainActor in
                        self?.state.reduce(.transcriptPartial(text))
                    }
                },
                onTranscript: { [weak self] transcript in
                    Task { @MainActor in
                        await self?.receiveLocalTranscript(transcript)
                    }
                },
                onTranscriptionError: { [weak self] message in
                    Task { @MainActor in
                        self?.state.reduce(.suggestion(message))
                    }
                }
            )
            sessionID = localSessionID
            state.reduce(.connectionReady)
        } catch {
            await capture.stop()
            sessionID = nil
            if let backendSessionID {
                try? await backend.perform(sessionID: backendSessionID, action: "mark-incomplete")
            }
            state.reduce(.failure(error.localizedDescription))
            return
        }

        if let remoteSessionID = backendSessionID {
            await capture.bindBackendSession(remoteSessionID)
            do {
                try await backend.perform(sessionID: remoteSessionID, action: "start-native-recording")
            } catch {
                state.reduce(.companionDisconnected("本地转写可用 · 会议服务未开始记录：\(error.localizedDescription)"))
                try? await backend.perform(sessionID: remoteSessionID, action: "mark-incomplete")
            }
        }
    }

    func endMeetingNow() async {
        await capture.stop()
        await maybeGenerateQuestions(forceRefresh: true)
        if let backendSessionID {
            try? await backend.perform(sessionID: backendSessionID, action: "stop-native-recording")
            do {
                try await backend.perform(sessionID: backendSessionID, action: "store-session")
                state.reduce(.suggestion("会议已保存，可继续生成摘要或向 AI 提问"))
            } catch {
                state.reduce(.suggestion("会议已结束，但保存失败：\(error.localizedDescription)"))
            }
        }
        sessionID = nil
        state.phase = .idle
        state.activeTranscript = ""
        await loadMeetingHistoryNow()
    }

    func saveMeetingNow() async {
        guard let backendSessionID else {
            state.reduce(.suggestion("当前没有可保存的会议"))
            return
        }
        do {
            try await backend.perform(sessionID: backendSessionID, action: "store-session")
            state.reduce(.suggestion("会议已保存"))
            await loadMeetingHistoryNow()
        } catch {
            state.reduce(.suggestion("保存失败：\(error.localizedDescription)"))
        }
    }

    func requestQuestionsNow() async {
        guard let backendSessionID else {
            state.reduce(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        await generateQuestions(sessionID: backendSessionID, announce: true)
    }

    func requestSummaryNow() async {
        guard let backendSessionID else {
            state.reduce(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        do {
            try await backend.perform(sessionID: backendSessionID, action: "generate-summary")
            state.reduce(.suggestion("正在生成会议摘要"))
        } catch {
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func requestScreenshotNow() async {
        guard let backendSessionID else {
            state.reduce(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        state.reduce(.suggestion("请选择要分析的窗口或屏幕"))
        do {
            try await screenshotPicker.present(sessionID: backendSessionID)
            state.reduce(.suggestion("正在分析截图"))
        } catch ScreenshotPickerError.cancelled {
            state.reduce(.suggestion("截图已取消"))
        } catch {
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func submitPromptNow(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let archivedMeetingID = state.phase == .live ? nil : state.selectedArchivedMeetingID
        guard backendSessionID != nil || archivedMeetingID != nil else {
            state.reduce(.suggestion("AI companion 暂未连接"))
            return
        }
        let requestID = UUID()
        state.reduce(.userPromptSubmitted(id: requestID, prompt: trimmed))
        if let archivedMeetingID {
            do {
                let answer = try await backend.askMeeting(
                    meetingID: archivedMeetingID,
                    question: trimmed,
                    requestID: requestID,
                    threadID: "main"
                )
                state.reduce(.answerFinal(requestID: requestID, answer: answer.answer))
                state.reduce(.meetingHistoryUpdated(try await backend.fetchMeeting(id: archivedMeetingID)))
            } catch {
                state.reduce(.aiFailure(requestID: requestID, message: error.localizedDescription))
            }
            return
        }
        do {
            try await backend.sendPrompt(trimmed, requestID: requestID)
        } catch {
            state.reduce(.aiFailure(requestID: requestID, message: error.localizedDescription))
        }
    }

    func receive(_ event: BackendEvent) {
        switch event {
        case .connectionEstablished, .ignored:
            break
        case let .meetingEvent(event):
            state.reduce(.meetingEvent(event))
        case let .transcript(line):
            state.reduce(.transcriptFinal(line))
        case let .translation(id, text):
            state.reduce(.transcriptTranslated(id: id, text: text))
        case let .answerDelta(requestID, delta):
            state.reduce(.answerDelta(requestID: requestID, delta: delta))
        case let .answerFinal(requestID, answer):
            state.reduce(.answerFinal(requestID: requestID, answer: answer))
        case let .aiFailure(requestID, message):
            state.reduce(.aiFailure(requestID: requestID, message: message))
        case let .question(question):
            state.reduce(.questionGenerated(question))
        case let .questions(questions):
            state.reduce(.questionsGenerated(questions))
        case let .suggestion(insight):
            state.reduce(.suggestion(insight))
        case let .summary(summary):
            state.reduce(.summaryGenerated(summary))
        case let .screenshotInsight(insight):
            state.reduce(.screenshotInsight(insight))
        case let .failure(message):
            state.reduce(.failure(message))
        }
    }

    private func receiveLocalTranscript(_ transcript: LocalTranscript) async {
        state.reduce(
            .transcriptFinal(
                TranscriptLine(
                    id: transcript.id,
                    speaker: transcript.speaker,
                    text: transcript.text,
                    timestamp: transcript.timestamp
                )
            )
        )
        if let backendSessionID {
            do {
                try await backend.submitTranscript(transcript, sessionID: backendSessionID)
            } catch {
                state.reduce(.suggestion("转写已保留在本机，暂未同步到会议服务"))
            }
        }
        await maybeGenerateQuestions(forceRefresh: false)
    }

    private func maybeGenerateQuestions(forceRefresh: Bool) async {
        guard let backendSessionID else { return }
        let transcriptCount = state.transcript.count
        guard transcriptCount >= questionRefreshStride else { return }
        guard forceRefresh
                ? transcriptCount > lastQuestionGenerationTranscriptCount
                : transcriptCount - lastQuestionGenerationTranscriptCount >= questionRefreshStride
        else { return }
        await generateQuestions(sessionID: backendSessionID, announce: false)
    }

    private func generateQuestions(sessionID: String, announce: Bool) async {
        guard !isQuestionGenerationInFlight else { return }
        isQuestionGenerationInFlight = true
        if announce {
            state.reduce(.suggestion("正在生成值得追问的问题"))
        }
        defer { isQuestionGenerationInFlight = false }
        while true {
            let requestedTranscriptCount = state.transcript.count
            do {
                try await backend.perform(sessionID: sessionID, action: "generate-questions")
                lastQuestionGenerationTranscriptCount = max(
                    lastQuestionGenerationTranscriptCount,
                    requestedTranscriptCount
                )
            } catch {
                if announce {
                    state.reduce(.suggestion(error.localizedDescription))
                }
                return
            }
            guard state.transcript.count - lastQuestionGenerationTranscriptCount >= questionRefreshStride else {
                return
            }
        }
    }

    func hideReader() {
        state.reduce(.hideReader)
    }

    func showReader() {
        state.reduce(.showReader)
    }

    func toggleReader() {
        state.aiReader.isVisible ? hideReader() : showReader()
    }

    func shutdown() {
        backend.disconnect()
        companion.stopOwnedProcess()
    }

    func shutdownNow() async {
        await capture.stop()
        backend.disconnect()
        companion.stopOwnedProcess()
    }
}
