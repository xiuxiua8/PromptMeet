import Foundation

extension MeetingStore {
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
        screenshotController.cancelSelection()
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        automationClockTask?.cancel()
        automationClockTask = nil
        backend.disconnect()
        companion.stopOwnedProcess()
    }

    func shutdownNow() async {
        screenshotController.cancelSelection()
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
        automationClockTask?.cancel()
        automationClockTask = nil
        await capture.stop()
        backend.disconnect()
        companion.stopOwnedProcess()
    }
}
