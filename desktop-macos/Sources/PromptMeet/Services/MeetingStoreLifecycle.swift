import Foundation

extension MeetingStore {
    func startMeetingNow() async {
        guard state.phase != .live && state.phase != .connecting else {
            state.reduce(.suggestion("当前会议仍在进行，请先结束后再开始新会议"))
            return
        }
        resetMeetingStartState()
        state.reduce(.prepareNewMeeting)
        state.reduce(.beginSession)
        let localSessionID = "local-\(UUID().uuidString)"
        let remoteRecordingStarted = await connectMeetingCompanion()

        do {
            try await startCaptureSession(localSessionID: localSessionID)
            sessionID = localSessionID
            state.reduce(.connectionReady)
            startAutomationClock(at: now())
        } catch {
            await rollbackFailedCaptureStart(remoteRecordingStarted: remoteRecordingStarted)
            state.reduce(.failure(error.localizedDescription))
        }
    }

    private func resetMeetingStartState() {
        if backendSessionID != nil {
            backend.disconnect()
            backendSessionID = nil
        }
        suggestionRefreshTask?.cancel()
        suggestionRefreshTask = nil
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
            state.reduce(.companionConnected)
        } catch {
            backend.disconnect()
            backendSessionID = nil
            state.reduce(.companionDisconnected("本地转写可用 · AI 服务连接失败：\(error.localizedDescription)"))
        }

        guard let remoteSessionID = backendSessionID else { return false }
        do {
            try await backend.perform(sessionID: remoteSessionID, action: "start-native-recording")
            await capture.bindBackendSession(remoteSessionID)
            return true
        } catch {
            state.reduce(
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
                Task { @MainActor in self?.state.audioCapture = snapshot }
            },
            onPartialTranscript: { [weak self] text in
                Task { @MainActor in self?.state.reduce(.transcriptPartial(text)) }
            },
            onTranscript: { [weak self] transcript in
                Task { @MainActor in await self?.receiveLocalTranscript(transcript) }
            },
            onTranscriptionError: { [weak self] message in
                Task { @MainActor in self?.state.reduce(.suggestion(message)) }
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
            state.screenshotOperation = .idle
        }
        state.recordingActivity = .stopping
        automationScheduler?.stop(at: now())
        automationClockTask?.cancel()
        automationClockTask = nil
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
        state.audioCapture = AudioCaptureSnapshot()
        await loadMeetingHistoryNow()
    }

    func pauseMeetingNow() async {
        guard state.phase == .live, state.recordingActivity == .recording else { return }
        state.recordingActivity = .pausing
        await capture.pause()
        automationScheduler?.pause(at: now())
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
                try await backend.perform(sessionID: remoteSessionID, action: "resume-native-recording")
                backendResumed = true
            }
            try await capture.resume()
            state.recordingActivity = .recording
            automationScheduler?.resume(at: now())
        } catch {
            if backendResumed, let remoteSessionID {
                try? await backend.perform(sessionID: remoteSessionID, action: "pause-native-recording")
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
}
