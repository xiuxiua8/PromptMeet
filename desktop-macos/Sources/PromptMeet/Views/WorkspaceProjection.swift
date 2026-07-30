import Foundation

enum WorkspaceTimelineItemKind: Equatable, Sendable {
    case lifecycle
    case transcript
    case screenshot
    case screenshotAnalysis
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
        }.compactMap { event in
            switch event.payload {
            case .lifecycle(let value):
                return Self.item(
                    event,
                    .lifecycle,
                    "会议状态",
                    value.detail ?? value.status.rawValue
                )
            case .transcript(let value):
                return Self.item(event, .transcript, value.speaker, value.text)
            case .screenshot(let value):
                return Self.item(
                    event,
                    .screenshot,
                    "会议截图",
                    "已保留原始截图，可用于后续提问",
                    screenshot: screenshots[value.assetID]
                )
            case .screenshotAnalysis(let value):
                let title =
                    switch (value.status, value.evidenceKind) {
                    case ("completed", "ocr"): "截图 OCR 证据"
                    case ("completed", _): "截图视觉分析"
                    case ("unsupported", _): "截图分析配置"
                    default: "截图分析状态"
                    }
                return Self.item(
                    event,
                    .screenshotAnalysis,
                    title,
                    value.text,
                    isFailure: value.status == "failed"
                )
            case .userQuestion, .assistantAnswer, .suggestions:
                return nil
            case .summary(let value):
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
