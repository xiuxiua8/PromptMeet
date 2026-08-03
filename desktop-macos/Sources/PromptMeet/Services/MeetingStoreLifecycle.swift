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
        let meetingID = UUID().uuidString
        let startedAt = now()
        sessionID = meetingID
        meetingStartedAt = startedAt
        let remoteRecordingStarted = await connectMeetingCompanion(
            meetingID: meetingID,
            startedAt: startedAt
        )

        do {
            try await startCaptureSession(localSessionID: meetingID)
            dispatch(.connectionReady)
            startAutomationClock(at: now())
        } catch {
            await rollbackFailedCaptureStart(remoteRecordingStarted: remoteRecordingStarted)
            dispatch(.failure(error.localizedDescription))
        }
    }

    private func resetMeetingStartState() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectInProgress = false
        meetingGeneration = UUID()
        transcriptSyncTask?.cancel()
        transcriptSyncTask = nil
        transcriptSyncGeneration = nil
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
        meetingStartedAt = nil
    }

    private func connectMeetingCompanion(
        meetingID: String,
        startedAt: Date
    ) async -> Bool {
        do {
            try await companion.ensureRunning()
            try await backend.healthCheck()
            let remoteSessionID = try await backend.createSession(
                sessionID: meetingID,
                startedAt: startedAt
            )
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

    func reconnectCompanionNow() async {
        await reconnectCompanionNow(
            expectedGeneration: meetingGeneration,
            expectedLocalSessionID: sessionID
        )
    }

    func reconnectCompanionNow(
        expectedGeneration: UUID,
        expectedLocalSessionID: String?
    ) async {
        guard isMeetingActive else {
            await prepareCompanionNow()
            return
        }
        guard !reconnectInProgress else { return }
        guard reconnectMatches(
            generation: expectedGeneration,
            localSessionID: expectedLocalSessionID
        ) else { return }
        reconnectInProgress = true
        defer { reconnectInProgress = false }
        let isPaused = state.recordingActivity == .paused
        dispatch(.companionDisconnected("本地录音继续，正在重新连接 AI 服务"))
        do {
            try await companion.ensureRunning()
            guard reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) else { return }
            try await backend.healthCheck()
            guard reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) else { return }
            let remoteSessionID: String
            if let existingSessionID = backendSessionID {
                try await backend.rehydrateSession(
                    sessionID: existingSessionID,
                    isPaused: isPaused
                )
                remoteSessionID = existingSessionID
            } else {
                guard let localSessionID = expectedLocalSessionID,
                      let meetingStartedAt else { return }
                remoteSessionID = try await backend.createSession(
                    sessionID: localSessionID,
                    startedAt: meetingStartedAt
                )
                guard reconnectMatches(
                    generation: expectedGeneration,
                    localSessionID: expectedLocalSessionID
                ) else { return }
                backendSessionID = remoteSessionID
                try await backend.perform(
                    sessionID: remoteSessionID,
                    action: "start-native-recording"
                )
                if isPaused {
                    try await backend.perform(
                        sessionID: remoteSessionID,
                        action: "pause-native-recording"
                    )
                }
            }
            guard reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) else { return }
            try connectBackendEvents(sessionID: remoteSessionID)
            guard reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) else {
                backend.disconnect()
                return
            }
            await capture.bindBackendSession(remoteSessionID)
            guard reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) else {
                backend.disconnect()
                return
            }
        } catch is CancellationError {
            return
        } catch {
            backend.disconnect()
            if reconnectMatches(
                generation: expectedGeneration,
                localSessionID: expectedLocalSessionID
            ) {
                dispatch(
                    .companionDisconnected(
                        "本地录音继续，AI 服务重连失败：\(error.localizedDescription)"
                    )
                )
            }
        }
    }

    private func reconnectMatches(
        generation: UUID,
        localSessionID: String?
    ) -> Bool {
        !Task.isCancelled
            && meetingGeneration == generation
            && sessionID == localSessionID
            && isMeetingActive
    }

    func cancelCompanionReconnectNow() async {
        meetingGeneration = UUID()
        let task = reconnectTask
        reconnectTask = nil
        task?.cancel()
        await task?.value
        reconnectInProgress = false
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
        meetingStartedAt = nil
        guard let backendSessionID else { return }
        if remoteRecordingStarted {
            try? await backend.perform(sessionID: backendSessionID, action: "stop-native-recording")
        }
        try? await backend.perform(sessionID: backendSessionID, action: "mark-incomplete")
    }

    func endMeetingNow() async {
        let endingMeetingID = sessionID
        let endingStartedAt = meetingStartedAt
        let stopTask = Task { @MainActor [capture] in await capture.stop() }
        if let endingMeetingID, let endingStartedAt {
            do {
                try await transcriptOutbox.markPendingFinalization(
                    PendingMeetingFinalization(
                        meetingID: endingMeetingID,
                        startedAt: endingStartedAt
                    )
                )
            } catch {
                dispatch(.suggestion("会议结束状态保存失败：\(error.localizedDescription)"))
            }
        }
        await stopTask.value
        await cancelCompanionReconnectNow()
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
        var finalized = false
        if let endingMeetingID, let endingStartedAt, state.isCompanionConnected {
            finalized = await finalizePendingMeetingNow(
                PendingMeetingFinalization(
                    meetingID: endingMeetingID,
                    startedAt: endingStartedAt
                )
            )
        }
        sessionID = nil
        meetingStartedAt = nil
        modify(\.phase, to: .idle)
        modify(\.recordingActivity, to: .inactive)
        modify(\.activeTranscript, to: "")
        modify(\.audioCapture, to: AudioCaptureSnapshot())
        if !finalized, endingMeetingID != nil {
            dispatch(.suggestion("会议已在本机结束，等待 AI 服务恢复后同步保存"))
        }
        if pendingCompanionConfigurationReload {
            await applyPendingCompanionConfigurationReloadNow()
        } else {
            await loadMeetingHistoryNow()
        }
    }

    func finalizePendingMeetingsNow() async {
        let pending: [PendingMeetingFinalization]
        do {
            pending = try await transcriptOutbox.pendingFinalizations()
        } catch {
            dispatch(.suggestion("待保存会议无法读取：\(error.localizedDescription)"))
            return
        }
        for finalization in pending {
            guard await finalizePendingMeetingNow(finalization) else { return }
        }
    }

    private func finalizePendingMeetingNow(
        _ finalization: PendingMeetingFinalization
    ) async -> Bool {
        do {
            let remoteSessionID: String
            if backendSessionID == finalization.meetingID,
               sessionID == finalization.meetingID,
               state.isCompanionConnected {
                remoteSessionID = finalization.meetingID
            } else {
                try await backend.healthCheck()
                remoteSessionID = try await backend.createSession(
                    sessionID: finalization.meetingID,
                    startedAt: finalization.startedAt
                )
                guard remoteSessionID == finalization.meetingID else {
                    throw BackendClientError.invalidResponse
                }
                try await backend.perform(
                    sessionID: remoteSessionID,
                    action: "start-native-recording"
                )
            }
            guard await replayTranscriptOutboxForFinalizationNow(
                sessionID: remoteSessionID
            ) else { return false }
            try await backend.perform(
                sessionID: remoteSessionID,
                action: "stop-native-recording"
            )
            try await backend.perform(
                sessionID: remoteSessionID,
                action: "store-session"
            )
            try await transcriptOutbox.completeFinalization(
                meetingID: finalization.meetingID
            )
            dispatch(.suggestion("会议已保存，可继续生成摘要或向 AI 提问"))
            return true
        } catch is CancellationError {
            return false
        } catch {
            dispatch(.suggestion("会议仍等待同步保存：\(error.localizedDescription)"))
            return false
        }
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
