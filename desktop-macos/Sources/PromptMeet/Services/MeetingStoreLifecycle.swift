import Foundation

extension MeetingStore {
    func startMeetingNow() async {
        guard state.phase != .live && state.phase != .connecting else {
            dispatch(.suggestion("当前会议仍在进行，请先结束后再开始新会议"))
            return
        }
        resetMeetingStartState()
        dispatch(.prepareNewMeeting)
        dispatch(.beginSession)
        let localSessionID = "local-\(UUID().uuidString)"
        let remoteRecordingStarted = await connectMeetingCompanion()

        do {
            try await startCaptureSession(localSessionID: localSessionID)
            sessionID = localSessionID
            dispatch(.connectionReady)
            startAutomationClock(at: now())
        } catch {
            await rollbackFailedCaptureStart(remoteRecordingStarted: remoteRecordingStarted)
            dispatch(.failure(error.localizedDescription))
        }
    }

    private func resetMeetingStartState() {
        if backendSessionID != nil {
            backend.disconnect()
            backendSessionID = nil
        }
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionGenerationTask?.cancel()
        suggestionGenerationTask = nil
        pendingSuggestionRevision = nil
        suggestionContextRevision = 0
        lastRequestedSuggestionRevision = -1
        activeSuggestionGenerationID = nil
        suggestionContextTokens = []
        meetingInputRevision = 0
        meetingInputTokens = []
        automationClockTask?.cancel()
        automationClockTask = nil
        automationScheduler = nil
    }

    private func connectMeetingCompanion() async -> Bool {
        do {
            try await companion.ensureRunning()
            try await backend.healthCheck()
            let remoteSessionID = try await backend.createSession()
            backendSessionID = remoteSessionID
            try connectBackendEvents(sessionID: remoteSessionID)
            dispatch(.companionConnected)
        } catch {
            backend.disconnect()
            backendSessionID = nil
            dispatch(.companionDisconnected("本地转写可用 · AI 服务连接失败：\(error.localizedDescription)"))
        }

        guard let remoteSessionID = backendSessionID else { return false }
        do {
            try await backend.perform(sessionID: remoteSessionID, action: "start-native-recording")
            await capture.bindBackendSession(remoteSessionID)
            return true
        } catch {
            dispatch(
                .companionDisconnected("本地转写可用 · 会议服务未开始记录：\(error.localizedDescription)")
            )
            try? await backend.perform(sessionID: remoteSessionID, action: "mark-incomplete")
            return false
        }
    }

    private func connectBackendEvents(sessionID remoteSessionID: String) throws {
        try backend.connect(sessionID: remoteSessionID) { [weak self] event in
            Task { @MainActor in
                guard self?.backendSessionID == remoteSessionID else { return }
                self?.receive(event)
            }
        }
    }

    private func startCaptureSession(localSessionID: String) async throws {
        try await capture.start(
            request: NativeAudioCaptureRequest(
                sessionID: localSessionID,
                includeLocalMicrophone: meetingPreferences.includeLocalMicrophone
            ),
            onStatus: { [weak self] snapshot in
                Task { @MainActor in self?.modify(\.audioCapture, to: snapshot) }
            },
            onPartialTranscript: { [weak self] text in
                Task { @MainActor in self?.dispatch(.transcriptPartial(text)) }
            },
            onTranscript: { [weak self] transcript in
                Task { @MainActor in await self?.receiveLocalTranscript(transcript) }
            },
            onTranscriptionError: { [weak self] message in
                Task { @MainActor in self?.dispatch(.suggestion(message)) }
            }
        )
    }

    private func rollbackFailedCaptureStart(remoteRecordingStarted: Bool) async {
        await capture.stop()
        sessionID = nil
        guard let backendSessionID else { return }
        if remoteRecordingStarted {
            try? await backend.perform(sessionID: backendSessionID, action: "stop-native-recording")
        }
        try? await backend.perform(sessionID: backendSessionID, action: "mark-incomplete")
    }

    func endMeetingNow() async {
        screenshotController.cancelSelection()
        if state.screenshotOperation == .selecting {
            modify(\.screenshotOperation, to: .idle)
        }
        modify(\.recordingActivity, to: .stopping)
        automationScheduler?.stop(at: now())
        automationClockTask?.cancel()
        automationClockTask = nil
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = nil
        suggestionGenerationTask?.cancel()
        suggestionGenerationTask = nil
        pendingSuggestionRevision = nil
        activeSuggestionGenerationID = nil
        await capture.stop()
        if let backendSessionID {
            try? await backend.perform(sessionID: backendSessionID, action: "stop-native-recording")
            do {
                try await backend.perform(sessionID: backendSessionID, action: "store-session")
                dispatch(.suggestion("会议已保存，可继续生成摘要或向 AI 提问"))
            } catch {
                dispatch(.suggestion("会议已结束，但保存失败：\(error.localizedDescription)"))
            }
        }
        sessionID = nil
        modify(\.phase, to: .idle)
        modify(\.recordingActivity, to: .inactive)
        modify(\.activeTranscript, to: "")
        modify(\.audioCapture, to: AudioCaptureSnapshot())
        await loadMeetingHistoryNow()
        await applyPendingCompanionConfigurationReloadNow()
    }

    func pauseMeetingNow() async {
        guard state.phase == .live, state.recordingActivity == .recording else { return }
        modify(\.recordingActivity, to: .pausing)
        await capture.pause()
        automationScheduler?.pause(at: now())
        if let backendSessionID {
            do {
                try await backend.perform(sessionID: backendSessionID, action: "pause-native-recording")
            } catch {
                dispatch(.suggestion("录音已在本机暂停，会议服务状态暂未同步"))
            }
        }
        modify(\.recordingActivity, to: .paused)
        modify(\.activeTranscript, to: "")
    }

    func resumeMeetingNow() async {
        guard state.phase == .live, state.recordingActivity == .paused else { return }
        modify(\.recordingActivity, to: .resuming)
        let remoteSessionID = backendSessionID
        var backendResumed = false
        do {
            if let remoteSessionID {
                try await backend.perform(sessionID: remoteSessionID, action: "resume-native-recording")
                backendResumed = true
            }
            try await capture.resume()
            modify(\.recordingActivity, to: .recording)
            automationScheduler?.resume(at: now())
        } catch {
            if backendResumed, let remoteSessionID {
                try? await backend.perform(sessionID: remoteSessionID, action: "pause-native-recording")
            }
            modify(\.recordingActivity, to: .paused)
            dispatch(.suggestion("继续录音失败：\(error.localizedDescription)"))
        }
    }

    func saveMeetingNow() async {
        guard let backendSessionID else {
            dispatch(.suggestion("当前没有可保存的会议"))
            return
        }
        do {
            try await backend.perform(sessionID: backendSessionID, action: "store-session")
            dispatch(.suggestion("会议已保存"))
            await loadMeetingHistoryNow()
        } catch {
            dispatch(.suggestion("保存失败：\(error.localizedDescription)"))
        }
    }
}
