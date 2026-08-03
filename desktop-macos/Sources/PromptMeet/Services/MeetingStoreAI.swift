import Foundation

extension MeetingStore {
    func requestQuestionsNow() async {
        guard let backendSessionID else {
            dispatch(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        suggestionContextRevision = max(
            suggestionContextRevision + 1,
            lastRequestedSuggestionRevision + 1
        )
        pendingSuggestionRevision = suggestionContextRevision
        modify(\.suggestionRefresh.phase, to: .loading)
        modify(\.suggestionRefresh.contextRevision, to: suggestionContextRevision)
        dispatch(.suggestion("正在生成值得追问的问题"))
        guard suggestionGenerationTask == nil else { return }
        let task = startPendingSuggestionGeneration(
            sessionID: backendSessionID,
            announce: true
        )
        await task?.value
    }

    func requestSummaryNow() async {
        guard let backendSessionID else {
            dispatch(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        modify(\.summaryAutomation, to: .generating(activeMinute: nil))
        do {
            let response = try await backend.generateSummary(
                sessionID: backendSessionID,
                request: SummaryGenerationRequest(
                    trigger: .manual,
                    activeMinutes: nil,
                    clientInputRevision: meetingInputRevision
                )
            )
            applySummaryResponse(response, activeMinute: nil)
        } catch {
            modify(\.summaryAutomation, to: .failed(error.localizedDescription))
            dispatch(.suggestion(error.localizedDescription))
        }
    }

    func submitPromptNow(_ prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let archivedMeetingID = state.selectedArchivedMeetingID
        guard backendSessionID != nil || archivedMeetingID != nil else {
            dispatch(.suggestion("AI companion 暂未连接"))
            return
        }
        let requestID = UUID()
        dispatch(.userPromptSubmitted(id: requestID, prompt: trimmed))
        if let archivedMeetingID {
            await submitHistoricalPrompt(
                trimmed,
                meetingID: archivedMeetingID,
                requestID: requestID
            )
            return
        }
        do {
            try await backend.sendPrompt(trimmed, requestID: requestID)
        } catch {
            dispatch(.aiFailure(requestID: requestID, message: error.localizedDescription))
        }
    }

    private func submitHistoricalPrompt(
        _ prompt: String,
        meetingID: String,
        requestID: UUID
    ) async {
        do {
            let answer = try await backend.askMeeting(
                meetingID: meetingID,
                question: prompt,
                requestID: requestID,
                threadID: "main"
            )
            dispatch(.answerFinal(requestID: requestID, answer: answer.answer))
            dispatch(.meetingHistoryUpdated(try await backend.fetchMeeting(id: meetingID)))
        } catch {
            dispatch(.aiFailure(requestID: requestID, message: error.localizedDescription))
        }
    }

    func receive(_ event: BackendEvent) {
        switch event {
        case .connectionEstablished:
            dispatch(.companionConnected)
            if let backendSessionID {
                Task { @MainActor [weak self] in
                    await self?.synchronizeTranscriptOutboxNow(
                        sessionID: backendSessionID
                    )
                }
            }
        case .ignored:
            break
        case .meetingEvent, .transcript, .translation:
            receiveEvidenceEvent(event)
        case .answerDelta, .answerFinal, .aiFailure:
            receiveAnswerEvent(event)
        case .question, .questions, .suggestion:
            receiveSuggestionEvent(event)
        case .summary, .screenshotInsight, .companionDisconnected, .failure:
            receiveInsightEvent(event)
        }
    }

    private func receiveEvidenceEvent(_ event: BackendEvent) {
        switch event {
        case .meetingEvent(let timelineEvent):
            receiveTimelineEvent(timelineEvent)
        case .transcript(let line):
            dispatch(.transcriptFinal(line))
            registerMeetingInput(token: "transcript:\(line.id.uuidString.lowercased())")
        case .translation(let id, let text):
            dispatch(.transcriptTranslated(id: id, text: text))
        default:
            break
        }
    }

    private func receiveTimelineEvent(_ event: MeetingTimelineEvent) {
        if case .suggestions(let value) = event.payload {
            guard suggestionResponseIsCurrent(
                generationID: UUID(uuidString: value.generationID),
                contextRevision: value.contextRevision
            ) else { return }
        }
        dispatch(.meetingEvent(event))
        registerTimelineInput(event.payload)
        refreshSuggestions(after: event)
    }

    private func registerTimelineInput(_ payload: MeetingTimelinePayload) {
        switch payload {
        case .transcript(let value):
            registerMeetingInput(token: "transcript:\(value.segmentID.lowercased())")
        case .screenshot(let value):
            registerMeetingInput(token: "screenshot:\(value.assetID)")
        case .screenshotAnalysis(let value):
            registerMeetingInput(token: "screenshot-analysis:\(value.assetID):\(value.status)")
        default:
            break
        }
    }

    private func refreshSuggestions(after event: MeetingTimelineEvent) {
        switch event.payload {
        case .screenshotAnalysis(let value):
            modify(\.screenshotOperation, to: .analyzed(status: value.status, detail: value.text))
            scheduleSuggestionRefresh(
                contextToken: "screenshot:\(value.assetID):\(value.status):\(value.text)"
            )
        case .assistantAnswer(let value):
            scheduleSuggestionRefresh(contextToken: "answer:\(value.requestID.lowercased())")
        case .summary:
            scheduleSuggestionRefresh(contextToken: "summary:\(event.eventID)")
        default:
            break
        }
    }

    private func receiveAnswerEvent(_ event: BackendEvent) {
        switch event {
        case .answerDelta(let requestID, let delta):
            dispatch(.answerDelta(requestID: requestID, delta: delta))
        case .answerFinal(let requestID, let answer):
            dispatch(.answerFinal(requestID: requestID, answer: answer))
            scheduleSuggestionRefresh(
                contextToken: requestID.map { "answer:\($0.uuidString.lowercased())" }
                    ?? "answer:\(answer)"
            )
        case .aiFailure(let requestID, let message):
            dispatch(.aiFailure(requestID: requestID, message: message))
        default:
            break
        }
    }

    private func receiveSuggestionEvent(_ event: BackendEvent) {
        switch event {
        case .question(let question):
            dispatch(.questionGenerated(question))
        case .questions(let generationID, let contextRevision, let questions):
            guard suggestionResponseIsCurrent(
                generationID: generationID,
                contextRevision: contextRevision
            ) else { return }
            dispatch(.questionsGenerated(questions))
            modify(\.suggestionRefresh.phase, to: .ready)
        case .suggestion(let insight):
            dispatch(.suggestion(insight))
        default:
            break
        }
    }

    private func suggestionResponseIsCurrent(
        generationID: UUID?,
        contextRevision: Int?
    ) -> Bool {
        if let generationID, generationID != activeSuggestionGenerationID { return false }
        if let contextRevision, contextRevision != lastRequestedSuggestionRevision { return false }
        return true
    }

    private func receiveInsightEvent(_ event: BackendEvent) {
        switch event {
        case .summary(let summary):
            dispatch(.summaryGenerated(summary))
            scheduleSuggestionRefresh(contextToken: "summary:\(summary.summaryText)")
        case .screenshotInsight(let insight):
            dispatch(.screenshotInsight(insight))
            scheduleSuggestionRefresh(contextToken: "screenshot-insight:\(insight)")
        case .companionDisconnected(let message):
            transcriptSyncTask?.cancel()
            transcriptSyncTask = nil
            transcriptSyncGeneration = nil
            dispatch(
                .companionDisconnected(
                    "本地录音继续，AI 服务连接已中断：\(message)。请重新连接 AI 服务"
                )
            )
        case .failure(let message):
            dispatch(.failure(message))
        default:
            break
        }
    }

    func receiveLocalTranscript(_ transcript: LocalTranscript) async {
        dispatch(
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
        registerMeetingInput(token: "transcript:\(transcript.id.uuidString.lowercased())")
        guard let backendSessionID else { return }
        do {
            try await transcriptOutbox.enqueue(
                transcript,
                meetingID: backendSessionID
            )
        } catch {
            dispatch(.suggestion("本机转写同步队列保存失败：\(error.localizedDescription)"))
            return
        }
        if state.isCompanionConnected {
            await synchronizeTranscriptOutboxNow(sessionID: backendSessionID)
        }
    }

    func synchronizeTranscriptOutboxNow(sessionID: String) async {
        guard backendSessionID == sessionID, state.isCompanionConnected else { return }
        if let task = transcriptSyncTask {
            _ = await task.value
            return
        }
        let generation = UUID()
        transcriptSyncGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.drainTranscriptOutbox(sessionID: sessionID)
        }
        transcriptSyncTask = task
        let succeeded = await task.value
        guard transcriptSyncGeneration == generation else { return }
        transcriptSyncTask = nil
        transcriptSyncGeneration = nil
        guard succeeded,
              backendSessionID == sessionID,
              state.isCompanionConnected,
              let pending = try? await transcriptOutbox.pending(meetingID: sessionID),
              !pending.isEmpty else { return }
        await synchronizeTranscriptOutboxNow(sessionID: sessionID)
    }

    private func drainTranscriptOutbox(sessionID: String) async -> Bool {
        while !Task.isCancelled,
              backendSessionID == sessionID,
              state.isCompanionConnected {
            let pending: [LocalTranscript]
            do {
                pending = try await transcriptOutbox.pending(meetingID: sessionID)
            } catch {
                dispatch(.suggestion("本机转写同步队列读取失败：\(error.localizedDescription)"))
                return false
            }
            guard let transcript = pending.first else { return true }
            do {
                try await backend.submitTranscript(transcript, sessionID: sessionID)
                try await transcriptOutbox.acknowledge(
                    transcript.id,
                    meetingID: sessionID
                )
                scheduleSuggestionRefresh(
                    contextToken: "transcript:\(transcript.id.uuidString)"
                )
            } catch is CancellationError {
                return false
            } catch {
                dispatch(.suggestion("转写已保留在本机，暂未同步到会议服务"))
                return false
            }
        }
        return false
    }

    func scheduleSuggestionRefresh(contextToken: String) {
        guard let backendSessionID else { return }
        guard suggestionContextTokens.insert(contextToken).inserted else { return }
        suggestionContextRevision += 1
        let revision = suggestionContextRevision
        modify(\.suggestionRefresh.phase, to: .loading)
        modify(\.suggestionRefresh.contextRevision, to: revision)
        pendingSuggestionRevision = revision
        guard suggestionGenerationTask == nil else { return }
        scheduleSuggestionDebounce(sessionID: backendSessionID)
    }

    private func scheduleSuggestionDebounce(sessionID: String) {
        suggestionDebounceTask?.cancel()
        suggestionDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.suggestionDebounce ?? .milliseconds(350))
            } catch {
                return
            }
            guard let self, self.backendSessionID == sessionID else { return }
            self.suggestionDebounceTask = nil
            self.startPendingSuggestionGeneration(sessionID: sessionID, announce: false)
        }
    }

    @discardableResult
    private func startPendingSuggestionGeneration(
        sessionID: String,
        announce: Bool
    ) -> Task<Void, Never>? {
        guard suggestionGenerationTask == nil,
              let revision = pendingSuggestionRevision,
              revision > lastRequestedSuggestionRevision else { return nil }
        pendingSuggestionRevision = nil
        lastRequestedSuggestionRevision = revision
        let generationID = UUID()
        activeSuggestionGenerationID = generationID
        modify(\.suggestionRefresh, to: SuggestionRefreshState(
            phase: .loading,
            generationID: generationID,
            contextRevision: revision
        ))
        if announce {
            dispatch(.suggestion("正在生成值得追问的问题"))
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSuggestionGeneration(
                sessionID: sessionID,
                revision: revision,
                generationID: generationID,
                announce: announce
            )
        }
        suggestionGenerationTask = task
        return task
    }

    private func performSuggestionGeneration(
        sessionID: String,
        revision: Int,
        generationID: UUID,
        announce: Bool
    ) async {
        do {
            try await backend.generateQuestions(
                sessionID: sessionID,
                generationID: generationID,
                contextRevision: revision
            )
        } catch is CancellationError {
        } catch {
            if activeSuggestionGenerationID == generationID,
               lastRequestedSuggestionRevision == revision,
               pendingSuggestionRevision == nil {
                modify(\.suggestionRefresh.phase, to: .failed(error.localizedDescription))
                if announce {
                    dispatch(.suggestion(error.localizedDescription))
                }
            }
        }
        finishSuggestionGeneration(
            sessionID: sessionID,
            generationID: generationID
        )
    }

    private func finishSuggestionGeneration(
        sessionID: String,
        generationID: UUID
    ) {
        guard activeSuggestionGenerationID == generationID else { return }
        suggestionGenerationTask = nil
        guard backendSessionID == sessionID,
              let pendingSuggestionRevision,
              pendingSuggestionRevision > lastRequestedSuggestionRevision else { return }
        scheduleSuggestionDebounce(sessionID: sessionID)
    }
}
