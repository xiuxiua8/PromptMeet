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
    private let screenshotController: ScreenshotCaptureControlling
    private let suggestionDebounce: Duration
    private var suggestionRefreshTask: Task<Void, Never>?
    private var suggestionContextRevision = 0
    private var lastRequestedSuggestionRevision = -1
    private var activeSuggestionGenerationID: UUID?

    init(
        backend: BackendClientProtocol = BackendClient(),
        capture: NativeAudioCaptureCoordinating = NativeAudioCaptureCoordinator(),
        companion: CompanionLaunching = CompanionLauncher(),
        screenshotController: ScreenshotCaptureControlling = ScreenCaptureController(),
        suggestionDebounce: Duration = .milliseconds(350)
    ) {
        self.backend = backend
        self.capture = capture
        self.companion = companion
        self.screenshotController = screenshotController
        self.suggestionDebounce = suggestionDebounce
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

    func pauseMeeting() {
        Task { await pauseMeetingNow() }
    }

    func resumeMeeting() {
        Task { await resumeMeetingNow() }
    }

    func togglePauseResume() {
        if state.recordingActivity == .paused {
            resumeMeeting()
        } else {
            pauseMeeting()
        }
    }

    func retryMicrophone() {
        Task { await retryMicrophoneNow() }
    }

    func retryMicrophoneNow() async {
        do {
            try await capture.retry(.microphone)
        } catch {
            state.reduce(.suggestion("麦克风恢复失败：\(error.localizedDescription)"))
        }
    }

    func openMicrophoneSettings() {
        SystemMicrophonePermission().openSystemSettings()
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

    func selectCaptureTarget() {
        Task { await selectCaptureTargetNow() }
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
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        suggestionContextRevision = 0
        lastRequestedSuggestionRevision = -1
        activeSuggestionGenerationID = nil
        state.reduce(.prepareNewMeeting)
        state.reduce(.beginSession)
        let localSessionID = "local-\(UUID().uuidString)"
        var remoteRecordingStarted = false
        do {
            try await companion.ensureRunning()
            try await backend.healthCheck()
            let remoteSessionID = try await backend.createSession()
            backendSessionID = remoteSessionID
            try backend.connect(sessionID: remoteSessionID) { [weak self] event in
                Task { @MainActor in
                    guard self?.backendSessionID == remoteSessionID else { return }
                    self?.receive(event)
                }
            }
            state.reduce(.companionConnected)
        } catch {
            backend.disconnect()
            backendSessionID = nil
            state.reduce(.companionDisconnected("本地转写可用 · AI 服务连接失败：\(error.localizedDescription)"))
        }

        if let remoteSessionID = backendSessionID {
            do {
                try await backend.perform(
                    sessionID: remoteSessionID,
                    action: "start-native-recording"
                )
                remoteRecordingStarted = true
                await capture.bindBackendSession(remoteSessionID)
            } catch {
                state.reduce(
                    .companionDisconnected(
                        "本地转写可用 · 会议服务未开始记录：\(error.localizedDescription)"
                    )
                )
                try? await backend.perform(sessionID: remoteSessionID, action: "mark-incomplete")
            }
        }

        do {
            try await capture.start(
                sessionID: localSessionID,
                onStatus: { [weak self] snapshot in
                    Task { @MainActor in self?.state.audioCapture = snapshot }
                },
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
                if remoteRecordingStarted {
                    try? await backend.perform(
                        sessionID: backendSessionID,
                        action: "stop-native-recording"
                    )
                }
                try? await backend.perform(sessionID: backendSessionID, action: "mark-incomplete")
            }
            state.reduce(.failure(error.localizedDescription))
            return
        }
    }

    func endMeetingNow() async {
        state.recordingActivity = .stopping
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        await capture.stop()
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
        state.recordingActivity = .inactive
        state.activeTranscript = ""
        await loadMeetingHistoryNow()
    }

    func pauseMeetingNow() async {
        guard state.phase == .live, state.recordingActivity == .recording else { return }
        state.recordingActivity = .pausing
        await capture.pause()
        if let backendSessionID {
            do {
                try await backend.perform(sessionID: backendSessionID, action: "pause-native-recording")
            } catch {
                state.reduce(.suggestion("录音已在本机暂停，会议服务状态暂未同步"))
            }
        }
        state.recordingActivity = .paused
        state.activeTranscript = ""
    }

    func resumeMeetingNow() async {
        guard state.phase == .live, state.recordingActivity == .paused else { return }
        state.recordingActivity = .resuming
        let remoteSessionID = backendSessionID
        var backendResumed = false
        do {
            if let remoteSessionID {
                try await backend.perform(
                    sessionID: remoteSessionID,
                    action: "resume-native-recording"
                )
                backendResumed = true
            }
            try await capture.resume()
            state.recordingActivity = .recording
        } catch {
            if backendResumed, let remoteSessionID {
                try? await backend.perform(
                    sessionID: remoteSessionID,
                    action: "pause-native-recording"
                )
            }
            state.recordingActivity = .paused
            state.reduce(.suggestion("继续录音失败：\(error.localizedDescription)"))
        }
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
        suggestionContextRevision = max(
            suggestionContextRevision + 1,
            lastRequestedSuggestionRevision + 1
        )
        await refreshSuggestedQuestionsNow(
            sessionID: backendSessionID,
            revision: suggestionContextRevision,
            announce: true
        )
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
        state.screenshotOperation = .capturing
        do {
            try await screenshotController.captureSelected(sessionID: backendSessionID)
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .succeeded
            state.reduce(.suggestion("截图已保存，正在分析"))
        } catch ScreenshotPickerError.noSelectedTarget {
            state.screenshotOperation = .failed("请先选择窗口")
            state.reduce(.suggestion("请先选择窗口"))
        } catch {
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .failed(error.localizedDescription)
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func selectCaptureTargetNow() async {
        state.screenshotOperation = .selecting
        do {
            state.screenshotTarget = try await screenshotController.selectTarget()
            state.screenshotOperation = .idle
            state.reduce(.suggestion("已选择截图窗口"))
        } catch ScreenshotPickerError.cancelled {
            state.screenshotOperation = .idle
            state.reduce(.suggestion("窗口选择已取消"))
        } catch {
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .failed(error.localizedDescription)
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func openScreenRecordingSettings() {
        screenshotController.openScreenRecordingSettings()
    }

    func submitPromptNow(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let archivedMeetingID = state.selectedArchivedMeetingID
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
        case .meetingEvent(let event):
            if case .suggestions(let value) = event.payload {
                guard UUID(uuidString: value.generationID) == activeSuggestionGenerationID,
                    value.contextRevision == suggestionContextRevision
                else { return }
            }
            state.reduce(.meetingEvent(event))
            if case .screenshotAnalysis = event.payload {
                scheduleSuggestionRefresh()
            } else if case .assistantAnswer = event.payload {
                scheduleSuggestionRefresh()
            }
        case .transcript(let line):
            state.reduce(.transcriptFinal(line))
        case .translation(let id, let text):
            state.reduce(.transcriptTranslated(id: id, text: text))
        case .answerDelta(let requestID, let delta):
            state.reduce(.answerDelta(requestID: requestID, delta: delta))
        case .answerFinal(let requestID, let answer):
            state.reduce(.answerFinal(requestID: requestID, answer: answer))
            scheduleSuggestionRefresh()
        case .aiFailure(let requestID, let message):
            state.reduce(.aiFailure(requestID: requestID, message: message))
        case .question(let question):
            state.reduce(.questionGenerated(question))
        case .questions(let generationID, let contextRevision, let questions):
            if let generationID,
                generationID != activeSuggestionGenerationID {
                return
            }
            if let contextRevision,
                contextRevision != suggestionContextRevision {
                return
            }
            state.reduce(.questionsGenerated(questions))
            state.suggestionRefresh.phase = .ready
        case .suggestion(let insight):
            state.reduce(.suggestion(insight))
        case .summary(let summary):
            state.reduce(.summaryGenerated(summary))
        case .screenshotInsight(let insight):
            state.reduce(.screenshotInsight(insight))
            scheduleSuggestionRefresh()
        case .failure(let message):
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
                    timestamp: transcript.timestamp,
                    source: transcript.source,
                    meetingTime: transcript.meetingTime
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
        scheduleSuggestionRefresh()
    }

    private func scheduleSuggestionRefresh() {
        guard let backendSessionID else { return }
        suggestionContextRevision += 1
        let revision = suggestionContextRevision
        state.suggestionRefresh.phase = .loading
        state.suggestionRefresh.contextRevision = revision
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.suggestionDebounce ?? .milliseconds(350))
            } catch {
                return
            }
            guard let self,
                self.backendSessionID == backendSessionID,
                self.suggestionContextRevision == revision
            else { return }
            await self.refreshSuggestedQuestionsNow(
                sessionID: backendSessionID,
                revision: revision,
                announce: false
            )
        }
    }

    private func refreshSuggestedQuestionsNow(
        sessionID: String,
        revision: Int,
        announce: Bool
    ) async {
        guard revision > lastRequestedSuggestionRevision else { return }
        lastRequestedSuggestionRevision = revision
        let generationID = UUID()
        activeSuggestionGenerationID = generationID
        state.suggestionRefresh = SuggestionRefreshState(
            phase: .loading,
            generationID: generationID,
            contextRevision: revision
        )
        if announce {
            state.reduce(.suggestion("正在生成值得追问的问题"))
        }
        do {
            try await backend.generateQuestions(
                sessionID: sessionID,
                generationID: generationID,
                contextRevision: revision
            )
        } catch is CancellationError {
            return
        } catch {
            guard activeSuggestionGenerationID == generationID,
                suggestionContextRevision == revision
            else { return }
            state.suggestionRefresh.phase = .failed(error.localizedDescription)
            if announce {
                state.reduce(.suggestion(error.localizedDescription))
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
        if state.aiReader.isVisible { hideReader() } else { showReader() }
    }

    func shutdown() {
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        backend.disconnect()
        companion.stopOwnedProcess()
    }

    func shutdownNow() async {
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        await capture.stop()
        backend.disconnect()
        companion.stopOwnedProcess()
    }
}
