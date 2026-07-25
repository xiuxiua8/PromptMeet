import Foundation

enum WorkspaceTimelineItemKind: Equatable, Sendable {
    case lifecycle
    case transcript
    case screenshot
    case screenshotAnalysis
    case question
    case answer
    case summary
}

struct WorkspaceTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int
    let kind: WorkspaceTimelineItemKind
    let title: String
    let body: String
    let timestamp: Date
    let screenshot: ScreenshotAsset?
    let sources: [EvidenceSource]
    let isFailure: Bool
}

struct WorkspaceProjection: Equatable, Sendable {
    let items: [WorkspaceTimelineItem]
    let conversation: [ConversationTurn]

    var isEmpty: Bool { items.isEmpty && conversation.isEmpty }

    init(meeting: StoredMeeting?) {
        self.init(
            events: meeting?.timeline ?? [],
            conversation: meeting?.conversation ?? []
        )
    }

    init(events: [MeetingTimelineEvent], conversation: [ConversationTurn]) {
        let screenshots = Dictionary(
            uniqueKeysWithValues: MeetingTimelineProjection.screenshots(events).map { ($0.id, $0) }
        )
        items = events.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.occurredAt < $1.occurredAt
        }.map { event in
            switch event.payload {
            case let .lifecycle(value):
                return Self.item(
                    event,
                    .lifecycle,
                    "会议状态",
                    value.detail ?? value.status.rawValue
                )
            case let .transcript(value):
                return Self.item(event, .transcript, value.speaker, value.text)
            case let .screenshot(value):
                return Self.item(
                    event,
                    .screenshot,
                    "会议截图",
                    "已保留原始截图，可用于后续提问",
                    screenshot: screenshots[value.assetID]
                )
            case let .screenshotAnalysis(value):
                return Self.item(
                    event,
                    .screenshotAnalysis,
                    value.status == "completed" ? "截图分析" : "截图分析状态",
                    value.text,
                    isFailure: value.status == "failed"
                )
            case let .userQuestion(value):
                return Self.item(event, .question, "你问", value.question)
            case let .assistantAnswer(value):
                return Self.item(
                    event,
                    .answer,
                    "AI 回答",
                    value.status == "failed" ? (value.errorMessage ?? "回答失败") : value.answer,
                    sources: value.sources,
                    isFailure: value.status == "failed"
                )
            case let .summary(value):
                return Self.item(event, .summary, "会议摘要", value.summaryText)
            }
        }
        self.conversation = conversation
    }

    static func retryableTurns(_ turns: [ConversationTurn]) -> Set<String> {
        Set(turns.filter { $0.phase == .failed }.map(\.requestID))
    }

    private static func item(
        _ event: MeetingTimelineEvent,
        _ kind: WorkspaceTimelineItemKind,
        _ title: String,
        _ body: String,
        screenshot: ScreenshotAsset? = nil,
        sources: [EvidenceSource] = [],
        isFailure: Bool = false
    ) -> WorkspaceTimelineItem {
        WorkspaceTimelineItem(
            id: event.id,
            sequence: event.sequence,
            kind: kind,
            title: title,
            body: body,
            timestamp: event.occurredAt,
            screenshot: screenshot,
            sources: sources,
            isFailure: isFailure
        )
    }
}
