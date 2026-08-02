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
            dispatch(.suggestion("AI companion 暂未连接：\(error.localizedDescription)"))
        }
    }

    func reloadCompanionConfiguration() {
        Task { await reloadCompanionConfigurationNow() }
    }

    func reloadCompanionConfigurationNow() async {
        guard !isMeetingActive else {
            pendingCompanionConfigurationReload = true
            dispatch(.suggestion("AI 服务配置已保存，将在会议结束后应用"))
            return
        }
        pendingCompanionConfigurationReload = true
        await applyPendingCompanionConfigurationReloadNow()
    }

    func applyPendingCompanionConfigurationReloadNow() async {
        guard pendingCompanionConfigurationReload, !isMeetingActive else { return }
        if await applyCompanionConfigurationReloadNow() {
            pendingCompanionConfigurationReload = false
        }
    }

    private func applyCompanionConfigurationReloadNow() async -> Bool {
        do {
            try await companion.reloadConfiguration()
            dispatch(.companionConnected)
            dispatch(.suggestion("AI 服务配置已更新"))
            return true
        } catch {
            dispatch(.suggestion(error.localizedDescription))
            return false
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
            dispatch(.suggestion("麦克风恢复失败：\(error.localizedDescription)"))
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
        dispatch(.quickPromptChanged(prompt))
    }

    func setQuickAskPresented(_ isPresented: Bool) {
        dispatch(.quickAskPresented(isPresented))
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
        dispatch(.quickPromptChanged(""))
        dispatch(.quickAskPresented(false))
        await submitPromptNow(prompt)
    }

    func loadMeetingHistory() {
        Task { await loadMeetingHistoryNow() }
    }

    func loadMeetingHistoryNow() async {
        guard uiPreviewMode == nil else { return }
        do {
            dispatch(.meetingHistoryLoaded(try await backend.fetchMeetingHistory()))
        } catch {
            dispatch(.suggestion(MeetingState.historyUnavailableInsight))
        }
    }

    func selectArchivedMeeting(_ id: String?) {
        dispatch(.archivedMeetingSelected(id))
    }

    func hideReader() {
        dispatch(.hideReader)
    }

    func showReader() {
        dispatch(.showReader)
    }

    func toggleReader() {
        if state.aiReader.isVisible { hideReader() } else { showReader() }
    }

    func shutdown() {
        screenshotController.cancelSelection()
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionGenerationTask?.cancel()
        suggestionGenerationTask = nil
        pendingSuggestionRevision = nil
        activeSuggestionGenerationID = nil
        pendingCompanionConfigurationReload = false
        automationClockTask?.cancel()
        automationClockTask = nil
        backend.disconnect()
        companion.stopOwnedProcess()
    }

    func shutdownNow() async {
        screenshotController.cancelSelection()
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionGenerationTask?.cancel()
        suggestionGenerationTask = nil
        pendingSuggestionRevision = nil
        activeSuggestionGenerationID = nil
        pendingCompanionConfigurationReload = false
        automationClockTask?.cancel()
        automationClockTask = nil
        await capture.stop()
        backend.disconnect()
        companion.stopOwnedProcess()
    }
}
