import Foundation

enum MeetingPhase: Equatable {
    case idle
    case connecting
    case live
    case stopping
    case failed(String)
}

struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    let speaker: String
    let text: String
    let timestamp: Date
    var translatedText: String?

    init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        timestamp: Date = Date(),
        translatedText: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.translatedText = translatedText
    }
}

struct AIReaderState: Equatable {
    var title = "AI 回答"
    var content = ""
    var isVisible = false
    var isStreaming = false
}

enum AIRequestPhase: Equatable {
    case idle
    case submitting
    case streaming
    case completed
    case failed
}

struct AIRequestState: Equatable {
    var id: UUID?
    var prompt = ""
    var phase: AIRequestPhase = .idle
    var errorMessage: String?

    var isBusy: Bool {
        phase == .submitting || phase == .streaming
    }
}

struct MeetingTask: Identifiable, Equatable {
    let id: UUID
    let title: String
    let deadline: String?
    let details: String
    let priority: String
    let assignee: String?
    let status: String

    init(
        id: UUID = UUID(),
        title: String,
        deadline: String? = nil,
        details: String = "",
        priority: String = "medium",
        assignee: String? = nil,
        status: String = "pending"
    ) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.details = details
        self.priority = priority
        self.assignee = assignee
        self.status = status
    }
}

struct MeetingSummaryContent: Equatable {
    let summaryText: String
    let tasks: [MeetingTask]
    let keyPoints: [String]
    let decisions: [String]
}

enum MeetingAction: Equatable {
    case beginSession
    case connectionReady
    case transcriptPartial(String)
    case transcriptFinal(TranscriptLine)
    case transcriptTranslated(id: UUID, text: String)
    case companionConnected
    case companionDisconnected(String)
    case userPromptSubmitted(id: UUID, prompt: String)
    case answerDelta(requestID: UUID?, delta: String)
    case answerFinal(requestID: UUID?, answer: String)
    case aiFailure(requestID: UUID?, message: String)
    case quickPromptChanged(String)
    case quickAskPresented(Bool)
    case questionGenerated(String)
    case questionsGenerated([String])
    case suggestion(String)
    case summaryGenerated(MeetingSummaryContent)
    case screenshotInsight(String)
    case hideReader
    case showReader
    case meetingHistoryLoaded([StoredMeeting])
    case archivedMeetingSelected(String?)
    case failure(String)
}

struct MeetingState: Equatable {
    var phase: MeetingPhase = .idle
    var transcript: [TranscriptLine] = []
    var activeTranscript = ""
    var latestInsight: String?
    var latestSummary: String?
    var summary: MeetingSummaryContent?
    var screenshotInsights: [String] = []
    var generatedQuestions: [String] = []
    var isCompanionConnected = false
    var aiReader = AIReaderState()
    var aiRequest = AIRequestState()
    var promptHistory: [String] = []
    var quickPromptDraft = ""
    var isQuickAskPresented = false
    var meetingHistory: [StoredMeeting] = []
    var selectedArchivedMeetingID: String?

    var activeCaption: String {
        activeTranscript.isEmpty ? (transcript.last?.text ?? "") : activeTranscript
    }

    var selectedArchivedMeeting: StoredMeeting? {
        meetingHistory.first { $0.id == selectedArchivedMeetingID }
    }

    var displayedTranscript: [TranscriptLine] {
        selectedArchivedMeeting?.transcript ?? transcript
    }

    var displayedSummary: MeetingSummaryContent? {
        selectedArchivedMeeting?.summary ?? summary
    }

    func islandPresentation(isHovered: Bool) -> IslandPresentation {
        if isQuickAskPresented || isHovered {
            switch phase {
            case .idle, .failed:
                return .hoverIdle
            case .connecting, .live, .stopping:
                return .hoverLive
            }
        }

        if aiReader.isStreaming {
            return .answering
        }

        switch phase {
        case .idle, .failed:
            return .idle
        case .connecting, .stopping:
            return .connecting
        case .live:
            return .live
        }
    }

    mutating func reduce(_ action: MeetingAction) {
        switch action {
        case .beginSession:
            phase = .connecting
        case .connectionReady:
            phase = .live
        case let .transcriptPartial(text):
            activeTranscript = text
        case let .transcriptFinal(line):
            if !transcript.contains(where: { $0.id == line.id }) {
                transcript.append(line)
            }
            activeTranscript = ""
        case let .transcriptTranslated(id, text):
            guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
            transcript[index].translatedText = text
        case .companionConnected:
            isCompanionConnected = true
            if latestInsight?.contains("AI companion") == true || latestInsight?.contains("AI 服务连接") == true {
                latestInsight = nil
            }
        case let .companionDisconnected(message):
            isCompanionConnected = false
            latestInsight = message
        case let .userPromptSubmitted(id, prompt):
            promptHistory.append(prompt)
            aiRequest = AIRequestState(id: id, prompt: prompt, phase: .submitting)
            aiReader = AIReaderState(title: prompt)
        case let .answerDelta(requestID, delta):
            guard acceptsAIEvent(requestID) else { return }
            aiReader.content += delta
            aiReader.isVisible = true
            aiReader.isStreaming = true
            aiRequest.phase = .streaming
            aiRequest.errorMessage = nil
        case let .answerFinal(requestID, answer):
            guard acceptsAIEvent(requestID) else { return }
            aiReader.content = answer
            aiReader.isVisible = true
            aiReader.isStreaming = false
            aiRequest.phase = .completed
            aiRequest.errorMessage = nil
        case let .aiFailure(requestID, message):
            guard acceptsAIEvent(requestID) else { return }
            aiRequest.phase = .failed
            aiRequest.errorMessage = message
            aiReader.isStreaming = false
        case let .quickPromptChanged(prompt):
            quickPromptDraft = prompt
        case let .quickAskPresented(isPresented):
            isQuickAskPresented = isPresented
        case let .questionGenerated(question):
            if !generatedQuestions.contains(question) {
                generatedQuestions.append(question)
            }
            latestInsight = question
        case let .questionsGenerated(questions):
            let refreshed = questions.reduce(into: [String]()) { result, question in
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !result.contains(trimmed) {
                    result.append(trimmed)
                }
            }
            guard !refreshed.isEmpty else { return }
            generatedQuestions = refreshed
            latestInsight = refreshed.first
        case let .suggestion(insight):
            latestInsight = insight
        case let .summaryGenerated(summary):
            self.summary = summary
            latestSummary = summary.summaryText
        case let .screenshotInsight(insight):
            screenshotInsights.append(insight)
            latestInsight = insight
        case .hideReader:
            aiReader.isVisible = false
        case .showReader:
            if !aiReader.content.isEmpty {
                aiReader.isVisible = true
            }
        case let .meetingHistoryLoaded(meetings):
            meetingHistory = meetings
            if let selectedArchivedMeetingID,
               !meetings.contains(where: { $0.id == selectedArchivedMeetingID }) {
                self.selectedArchivedMeetingID = nil
            }
        case let .archivedMeetingSelected(id):
            selectedArchivedMeetingID = id
        case let .failure(message):
            phase = .failed(message)
        }
    }

    private func acceptsAIEvent(_ requestID: UUID?) -> Bool {
        guard aiRequest.id != nil else { return false }
        return requestID == nil || requestID == aiRequest.id
    }
}

extension MeetingState {
    static var previewLive: MeetingState {
        MeetingState(
            phase: .live,
            transcript: [
                TranscriptLine(speaker: "林晨", text: "我们先确认今天的讨论目标。")
            ]
        )
    }

    static var previewReader: MeetingState {
        var state = previewLive
        state.aiReader = AIReaderState(
            title: "总结",
            content: "已完成的回答",
            isVisible: true,
            isStreaming: false
        )
        return state
    }
}
