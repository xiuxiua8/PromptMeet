import Foundation

enum MeetingPhase: Equatable, Sendable {
    case idle
    case connecting
    case live
    case stopping
    case failed(String)
}

struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: String
    let text: String
    let timestamp: Date
    let source: NativeAudioSource?
    let meetingTime: Duration?
    var translatedText: String?

    init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        timestamp: Date = Date(),
        source: NativeAudioSource? = nil,
        meetingTime: Duration? = nil,
        translatedText: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.source = source
        self.meetingTime = meetingTime
        self.translatedText = translatedText
    }
}

struct AIReaderState: Equatable, Sendable {
    var title = "AI 回答"
    var content = ""
    var isVisible = false
    var isStreaming = false
}

enum AIRequestPhase: Equatable, Sendable {
    case idle
    case submitting
    case streaming
    case completed
    case failed
}

struct AIRequestState: Equatable, Sendable {
    var id: UUID?
    var prompt = ""
    var phase: AIRequestPhase = .idle
    var errorMessage: String?

    var isBusy: Bool {
        phase == .submitting || phase == .streaming
    }
}

struct MeetingTask: Identifiable, Equatable, Sendable {
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

struct MeetingSummaryContent: Equatable, Sendable {
    let summaryText: String
    let tasks: [MeetingTask]
    let keyPoints: [String]
    let decisions: [String]
    let revision: Int
    let sourceEventIDs: [String]
    let sourceRevision: Int
    let trigger: String?
    let activeMinutes: Int?

    init(
        summaryText: String,
        tasks: [MeetingTask],
        keyPoints: [String],
        decisions: [String],
        revision: Int = 1,
        sourceEventIDs: [String] = [],
        sourceRevision: Int = 0,
        trigger: String? = nil,
        activeMinutes: Int? = nil
    ) {
        self.summaryText = summaryText
        self.tasks = tasks
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.revision = revision
        self.sourceEventIDs = sourceEventIDs
        self.sourceRevision = sourceRevision
        self.trigger = trigger
        self.activeMinutes = activeMinutes
    }
}

enum SuggestedQuestionSet {
    static func accepted(_ questions: [String]) -> [String]? {
        let normalized = questions.reduce(into: [String]()) { result, question in
            let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        return (1...3).contains(normalized.count) ? normalized : nil
    }
}
