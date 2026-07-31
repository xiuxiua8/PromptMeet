import Foundation

extension MeetingState {
    mutating func reduce(_ action: MeetingAction) {
        switch action {
        case .prepareNewMeeting, .beginSession, .connectionReady, .failure:
            reduceLifecycle(action)
        case .transcriptPartial, .transcriptFinal, .transcriptTranslated:
            reduceTranscript(action)
        case .companionConnected, .companionDisconnected:
            reduceCompanion(action)
        case .userPromptSubmitted, .answerDelta, .answerFinal, .aiFailure:
            reduceConversation(action)
        case .quickPromptChanged, .quickAskPresented, .questionGenerated,
             .questionsGenerated, .suggestion:
            reduceSuggestions(action)
        case .summaryGenerated, .screenshotInsight, .meetingEvent:
            reduceEvidence(action)
        case .hideReader, .showReader:
            reduceReader(action)
        case .meetingHistoryLoaded, .meetingHistoryUpdated, .archivedMeetingSelected:
            reduceHistory(action)
        }
    }

    private mutating func reduceLifecycle(_ action: MeetingAction) {
        switch action {
        case .prepareNewMeeting:
            resetForNewMeeting()
        case .beginSession:
            phase = .connecting
            recordingActivity = .starting
        case .connectionReady:
            phase = .live
            recordingActivity = .recording
        case .failure(let message):
            phase = .failed(message)
            recordingActivity = .inactive
        default:
            break
        }
    }

    private mutating func resetForNewMeeting() {
        phase = .idle
        recordingActivity = .inactive
        screenshotOperation = .idle
        suggestionRefresh = SuggestionRefreshState()
        summaryAutomation = .idle
        audioCapture = AudioCaptureSnapshot()
        transcript = []
        activeTranscript = ""
        latestInsight = nil
        latestSummary = nil
        summary = nil
        screenshotInsights = []
        generatedQuestions = []
        aiReader = AIReaderState()
        aiRequest = AIRequestState()
        promptHistory = []
        quickPromptDraft = ""
        isQuickAskPresented = false
        selectedArchivedMeetingID = nil
        timeline = []
        conversationTurns = []
    }

    private mutating func reduceTranscript(_ action: MeetingAction) {
        switch action {
        case .transcriptPartial(let text):
            activeTranscript = text
        case .transcriptFinal(let line):
            if !transcript.contains(where: { $0.id == line.id }) {
                transcript.append(line)
            }
            activeTranscript = ""
        case .transcriptTranslated(let id, let text):
            guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
            transcript[index].translatedText = text
        default:
            break
        }
    }

    private mutating func reduceCompanion(_ action: MeetingAction) {
        switch action {
        case .companionConnected:
            isCompanionConnected = true
            if latestInsight?.contains("AI companion") == true
                || latestInsight?.contains("AI 服务连接") == true {
                latestInsight = nil
            }
        case .companionDisconnected(let message):
            isCompanionConnected = false
            latestInsight = message
        default:
            break
        }
    }

    private mutating func reduceConversation(_ action: MeetingAction) {
        switch action {
        case .userPromptSubmitted(let id, let prompt):
            submitPrompt(id: id, prompt: prompt)
        case .answerDelta(let requestID, let delta):
            appendAnswerDelta(requestID: requestID, delta: delta)
        case .answerFinal(let requestID, let answer):
            finishAnswer(requestID: requestID, answer: answer)
        case .aiFailure(let requestID, let message):
            failAnswer(requestID: requestID, message: message)
        default:
            break
        }
    }

    private mutating func submitPrompt(id: UUID, prompt: String) {
        let keepsReaderVisible = aiReader.isVisible
        promptHistory.append(prompt)
        aiRequest = AIRequestState(id: id, prompt: prompt, phase: .submitting)
        aiReader = AIReaderState(title: prompt, isVisible: keepsReaderVisible)
        guard !conversationTurns.contains(where: { $0.requestID == id.uuidString }) else { return }
        conversationTurns.append(
            ConversationTurn(
                id: id.uuidString,
                requestID: id.uuidString,
                threadID: "main",
                meetingID: selectedArchivedMeetingID,
                question: prompt,
                answer: "",
                phase: .submitting,
                errorMessage: nil,
                sources: [],
                degradedVision: false,
                askedAt: Date(),
                answeredAt: nil
            )
        )
    }

    private mutating func appendAnswerDelta(requestID: UUID?, delta: String) {
        guard let resolvedID = requestID ?? aiRequest.id,
              let index = conversationIndex(resolvedID) else { return }
        conversationTurns[index].answer += delta
        conversationTurns[index].phase = .streaming
        conversationTurns[index].errorMessage = nil
        guard aiRequest.id == resolvedID else { return }
        aiReader.content += delta
        aiReader.isVisible = true
        aiReader.isStreaming = true
        aiRequest.phase = .streaming
        aiRequest.errorMessage = nil
    }

    private mutating func finishAnswer(requestID: UUID?, answer: String) {
        guard let resolvedID = requestID ?? aiRequest.id,
              let index = conversationIndex(resolvedID) else { return }
        conversationTurns[index].answer = answer
        conversationTurns[index].phase = .completed
        conversationTurns[index].errorMessage = nil
        conversationTurns[index].answeredAt = Date()
        guard aiRequest.id == resolvedID else { return }
        aiReader.content = answer
        aiReader.isVisible = true
        aiReader.isStreaming = false
        aiRequest.phase = .completed
        aiRequest.errorMessage = nil
    }

    private mutating func failAnswer(requestID: UUID?, message: String) {
        guard let resolvedID = requestID ?? aiRequest.id,
              let index = conversationIndex(resolvedID) else { return }
        conversationTurns[index].phase = .failed
        conversationTurns[index].errorMessage = message
        guard aiRequest.id == resolvedID else { return }
        aiRequest.phase = .failed
        aiRequest.errorMessage = message
        aiReader.isStreaming = false
    }

    private mutating func reduceSuggestions(_ action: MeetingAction) {
        switch action {
        case .quickPromptChanged(let prompt):
            quickPromptDraft = prompt
        case .quickAskPresented(let isPresented):
            isQuickAskPresented = isPresented
        case .questionGenerated(let question):
            if !generatedQuestions.contains(question) { generatedQuestions.append(question) }
            latestInsight = question
        case .questionsGenerated(let questions):
            guard let refreshed = SuggestedQuestionSet.accepted(questions) else { return }
            generatedQuestions = refreshed
            latestInsight = refreshed.first
        case .suggestion(let insight):
            latestInsight = insight
        default:
            break
        }
    }

    private mutating func reduceEvidence(_ action: MeetingAction) {
        switch action {
        case .summaryGenerated(let summary):
            applySummary(summary)
        case .screenshotInsight(let insight):
            screenshotInsights.append(insight)
            latestInsight = insight
        case .meetingEvent(let event):
            ingestTimelineEvent(event)
        default:
            break
        }
    }

    private mutating func applySummary(_ summary: MeetingSummaryContent) {
        self.summary = summary
        latestSummary = summary.summaryText
        summaryAutomation = .completed(
            revision: summary.revision,
            activeMinute: summary.activeMinutes
        )
    }

    private mutating func reduceReader(_ action: MeetingAction) {
        switch action {
        case .hideReader:
            aiReader.isVisible = false
        case .showReader:
            if !aiReader.content.isEmpty { aiReader.isVisible = true }
        default:
            break
        }
    }

    private mutating func reduceHistory(_ action: MeetingAction) {
        switch action {
        case .meetingHistoryLoaded(let meetings):
            meetingHistory = meetings
            if latestInsight == Self.historyUnavailableInsight {
                latestInsight = nil
            }
            if let selectedArchivedMeetingID,
               !meetings.contains(where: { $0.id == selectedArchivedMeetingID }) {
                self.selectedArchivedMeetingID = nil
            }
        case .meetingHistoryUpdated(let meeting):
            updateMeetingHistory(with: meeting)
        case .archivedMeetingSelected(let id):
            selectedArchivedMeetingID = id
        default:
            break
        }
    }

    private mutating func updateMeetingHistory(with meeting: StoredMeeting) {
        if let index = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
            meetingHistory[index] = meeting
        } else {
            meetingHistory.append(meeting)
        }
        meetingHistory.sort { $0.startTime > $1.startTime }
    }

    private func conversationIndex(_ requestID: UUID) -> Int? {
        conversationTurns.firstIndex {
            $0.requestID.caseInsensitiveCompare(requestID.uuidString) == .orderedSame
        }
    }

    private mutating func ingestTimelineEvent(_ event: MeetingTimelineEvent) {
        guard !timeline.contains(where: { $0.id == event.id }) else { return }
        timeline.append(event)
        timeline.sort(by: timelineOrder)
        ingestTranscript(from: event)
        synchronizeConversation()
        applyTimelinePayload(event.payload)
    }

    private func timelineOrder(_ lhs: MeetingTimelineEvent, _ rhs: MeetingTimelineEvent) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.occurredAt < rhs.occurredAt
    }

    private mutating func ingestTranscript(from event: MeetingTimelineEvent) {
        guard let line = event.transcript,
              !transcript.contains(where: { $0.id == line.id }) else { return }
        transcript.append(line)
    }

    private mutating func synchronizeConversation() {
        for projected in MeetingTimelineProjection.conversation(timeline) {
            guard let index = conversationTurns.firstIndex(
                where: { $0.requestID == projected.requestID }
            ) else {
                conversationTurns.append(projected)
                continue
            }
            if projected.phase == .completed || projected.phase == .failed {
                conversationTurns[index] = projected
            }
        }
    }

    private mutating func applyTimelinePayload(_ payload: MeetingTimelinePayload) {
        switch payload {
        case .summary(let value):
            applySummary(summaryContent(from: value))
        case .screenshotAnalysis(let value):
            screenshotInsights.append(value.text)
            latestInsight = value.text
        case .suggestions(let value):
            applyTimelineSuggestions(value)
        default:
            break
        }
    }

    private mutating func applyTimelineSuggestions(_ value: TimelineSuggestionPayload) {
        guard let accepted = SuggestedQuestionSet.accepted(value.questions) else { return }
        generatedQuestions = accepted
        suggestionRefresh.phase = .ready
        suggestionRefresh.generationID = UUID(uuidString: value.generationID)
        suggestionRefresh.contextRevision = value.contextRevision
    }

    private func summaryContent(from value: TimelineSummaryPayload) -> MeetingSummaryContent {
        MeetingSummaryContent(
            summaryText: value.summaryText,
            tasks: value.tasks.compactMap(meetingTask),
            keyPoints: value.keyPoints,
            decisions: value.decisions,
            revision: value.revision ?? 1,
            sourceEventIDs: value.sourceEventIDs ?? [],
            sourceRevision: value.sourceRevision ?? 0,
            trigger: value.trigger,
            activeMinutes: value.activeMinutes
        )
    }

    private func meetingTask(from payload: [String: JSONValue]) -> MeetingTask? {
        guard let title = payload["task"]?.stringValue, !title.isEmpty else { return nil }
        return MeetingTask(
            title: title,
            deadline: payload["deadline"]?.stringValue,
            details: payload["describe"]?.stringValue ?? "",
            priority: payload["priority"]?.stringValue ?? "medium",
            assignee: payload["assignee"]?.stringValue,
            status: payload["status"]?.stringValue ?? "pending"
        )
    }
}
