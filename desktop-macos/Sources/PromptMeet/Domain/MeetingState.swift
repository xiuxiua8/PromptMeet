import Foundation

struct IslandCaption: Equatable, Sendable {
    let original: String
    let translation: String?
}

enum MeetingAction: Equatable {
    case prepareNewMeeting
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
    case meetingEvent(MeetingTimelineEvent)
    case hideReader
    case showReader
    case meetingHistoryLoaded([StoredMeeting])
    case meetingHistoryUpdated(StoredMeeting)
    case archivedMeetingSelected(String?)
    case failure(String)
}

struct MeetingState: Equatable {
    static let historyUnavailableInsight = "历史会议暂时无法读取"

    var phase: MeetingPhase = .idle
    var recordingActivity: RecordingActivity = .inactive
    var screenshotTarget: ScreenshotTargetState = .none
    var screenshotOperation: ScreenshotOperationState = .idle
    var suggestionRefresh = SuggestionRefreshState()
    var summaryAutomation: SummaryAutomationState = .idle
    var audioCapture = AudioCaptureSnapshot()
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
    var timeline: [MeetingTimelineEvent] = []
    var conversationTurns: [ConversationTurn] = []
    var subtitleFlow = SubtitleStreamFlow()

    var islandCaption: IslandCaption {
        if !activeTranscript.isEmpty {
            return IslandCaption(original: activeTranscript, translation: nil)
        }
        guard let latest = transcript.last else {
            return IslandCaption(original: "", translation: nil)
        }
        return IslandCaption(
            original: latest.text,
            translation: latest.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var activeCaption: String {
        islandCaption.original
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

    var displayedTimeline: [MeetingTimelineEvent] {
        selectedArchivedMeeting?.timeline ?? timeline
    }

    var displayedScreenshots: [ScreenshotAsset] {
        selectedArchivedMeeting?.screenshots ?? MeetingTimelineProjection.screenshots(timeline)
    }

    var displayedGeneratedQuestions: [String] {
        selectedArchivedMeeting?.suggestions ?? generatedQuestions
    }

    var displayedConversation: [ConversationTurn] {
        guard let selectedArchivedMeeting else { return conversationTurns }
        var result = selectedArchivedMeeting.conversation
        for pending in conversationTurns where pending.meetingID == selectedArchivedMeeting.id {
            if !result.contains(where: { $0.requestID == pending.requestID }) {
                result.append(pending)
            }
        }
        return result.sorted { $0.askedAt < $1.askedAt }
    }

    func conversationTurn(requestID: UUID) -> ConversationTurn? {
        conversationTurns.first { $0.requestID.caseInsensitiveCompare(requestID.uuidString) == .orderedSame }
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
}
