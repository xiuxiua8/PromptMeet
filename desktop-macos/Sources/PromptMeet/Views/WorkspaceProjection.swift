import Foundation

enum WorkspaceTimelineItemKind: Equatable, Sendable {
    case lifecycle
    case transcript
    case screenshot
    case screenshotAnalysis
    case summary
}

struct WorkspaceTranscriptSegment: Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int
    let text: String
    let translatedText: String?
    let timestamp: Date
}

struct WorkspaceTranscriptBlock: Identifiable, Equatable, Sendable {
    static let groupingWindow: TimeInterval = 45
    static let maximumSegmentCount = 6
    static let maximumCharacterCount = 4_096

    let speaker: String
    let source: String?
    let segments: [WorkspaceTranscriptSegment]

    var id: String {
        segments.first?.id ?? "empty:\(speaker):\(source ?? "unknown")"
    }

    var displaySpeaker: String {
        let trimmedSpeaker = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSpeaker.isEmpty { return trimmedSpeaker }
        switch source {
        case NativeAudioSource.microphone.rawValue: return "我"
        case NativeAudioSource.system.rawValue: return "会议"
        default: return "未知发言人"
        }
    }

    var text: String {
        segments.map(\.text).joined(separator: " ")
    }

    var translatedText: String? {
        let translations = segments.compactMap(\.translatedText)
        return translations.isEmpty ? nil : translations.joined(separator: " ")
    }

    func canAppend(
        speaker: String,
        source: String?,
        segment: WorkspaceTranscriptSegment
    ) -> Bool {
        guard self.speaker == speaker,
              self.source == source else { return false }
        return Self.canGroup(segments: segments, nextSegment: segment)
    }

    static func canGroup(previousTimestamp: Date, nextTimestamp: Date) -> Bool {
        let interval = nextTimestamp.timeIntervalSince(previousTimestamp)
        return interval >= 0 && interval <= groupingWindow
    }

    static func canGroup(
        segments: [WorkspaceTranscriptSegment],
        nextSegment: WorkspaceTranscriptSegment
    ) -> Bool {
        guard segments.count < maximumSegmentCount,
              let previousTimestamp = segments.last?.timestamp else { return false }
        let existingCharacters = segments.reduce(0) { $0 + $1.text.count }
        let separatorCharacters = segments.isEmpty ? 0 : 1
        guard existingCharacters + separatorCharacters + nextSegment.text.count
            <= maximumCharacterCount else { return false }
        return canGroup(
            previousTimestamp: previousTimestamp,
            nextTimestamp: nextSegment.timestamp
        )
    }
}

private struct TranscriptBlockAccumulator {
    let speaker: String
    let source: String?
    var segments: [WorkspaceTranscriptSegment]

    func canAppend(
        speaker: String,
        source: String?,
        segment: WorkspaceTranscriptSegment
    ) -> Bool {
        guard self.speaker == speaker,
              self.source == source else { return false }
        return WorkspaceTranscriptBlock.canGroup(segments: segments, nextSegment: segment)
    }

    mutating func append(_ segment: WorkspaceTranscriptSegment) {
        segments.append(segment)
    }

    var block: WorkspaceTranscriptBlock {
        WorkspaceTranscriptBlock(speaker: speaker, source: source, segments: segments)
    }
}

private struct TimelineTranscriptAccumulator {
    let firstEvent: MeetingTimelineEvent
    var transcript: TranscriptBlockAccumulator
}

struct WorkspaceTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let sequence: Int
    let endSequence: Int
    let kind: WorkspaceTimelineItemKind
    let title: String
    let body: String
    let timestamp: Date
    let screenshot: ScreenshotAsset?
    let sources: [EvidenceSource]
    let isFailure: Bool
    let transcriptBlock: WorkspaceTranscriptBlock?
}

struct WorkspaceProjection: Equatable, Sendable {
    let items: [WorkspaceTimelineItem]
    let conversation: [ConversationTurn]

    var isEmpty: Bool { items.isEmpty && conversation.isEmpty }

    func visibleInputCount(fallbackTranscriptLines: [TranscriptLine]) -> Int {
        items.isEmpty ? Self.transcriptBlocks(fallbackTranscriptLines).count : items.count
    }

    init(meeting: StoredMeeting?) {
        self.init(
            events: meeting?.timeline ?? [],
            conversation: meeting?.conversation ?? [],
            transcriptLines: meeting?.transcript ?? []
        )
    }

    init(
        events: [MeetingTimelineEvent],
        conversation: [ConversationTurn],
        transcriptLines: [TranscriptLine] = []
    ) {
        let screenshots = Dictionary(
            uniqueKeysWithValues: MeetingTimelineProjection.screenshots(events).map { ($0.id, $0) }
        )
        let translations = Self.translationOverrides(transcriptLines)
        let sortedEvents = events.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.occurredAt < $1.occurredAt
        }
        items = Self.projectItems(
            sortedEvents,
            screenshots: screenshots,
            translationOverrides: translations
        )
        self.conversation = conversation
    }

    static func retryableTurns(_ turns: [ConversationTurn]) -> Set<String> {
        Set(turns.filter { $0.phase == .failed }.map(\.requestID))
    }

    static func transcriptBlocks(_ lines: [TranscriptLine]) -> [WorkspaceTranscriptBlock] {
        var blocks: [WorkspaceTranscriptBlock] = []
        var openBlock: TranscriptBlockAccumulator?
        for (index, line) in lines.enumerated() {
            let segment = WorkspaceTranscriptSegment(
                id: line.id.uuidString,
                sequence: index,
                text: line.text,
                translatedText: line.translatedText,
                timestamp: line.timestamp
            )
            let source = line.source?.rawValue
            if openBlock?.canAppend(
                   speaker: line.speaker,
                   source: source,
                   segment: segment
               ) == true {
                openBlock?.append(segment)
            } else {
                flushLegacyBlock(&openBlock, into: &blocks)
                openBlock = TranscriptBlockAccumulator(
                    speaker: line.speaker,
                    source: source,
                    segments: [segment]
                )
            }
        }
        flushLegacyBlock(&openBlock, into: &blocks)
        return blocks
    }

    private static func projectItems(
        _ events: [MeetingTimelineEvent],
        screenshots: [String: ScreenshotAsset],
        translationOverrides: [String: String]
    ) -> [WorkspaceTimelineItem] {
        var items: [WorkspaceTimelineItem] = []
        var openTranscript: TimelineTranscriptAccumulator?
        for event in events {
            if case .transcript(let payload) = event.payload {
                appendTranscript(
                    event,
                    payload: payload,
                    translationOverrides: translationOverrides,
                    openTranscript: &openTranscript,
                    items: &items
                )
            } else {
                flushTimelineBlock(&openTranscript, into: &items)
                if let item = nonTranscriptItem(event, screenshots: screenshots) {
                    items.append(item)
                }
            }
        }
        flushTimelineBlock(&openTranscript, into: &items)
        return items
    }

    private static func appendTranscript(
        _ event: MeetingTimelineEvent,
        payload: TimelineTranscriptPayload,
        translationOverrides: [String: String],
        openTranscript: inout TimelineTranscriptAccumulator?,
        items: inout [WorkspaceTimelineItem]
    ) {
        let segment = WorkspaceTranscriptSegment(
            id: payload.segmentID,
            sequence: event.sequence,
            text: payload.text,
            translatedText: translationOverrides[payload.segmentID.lowercased()] ?? payload.translatedText,
            timestamp: event.occurredAt
        )
        if openTranscript?.transcript.canAppend(
            speaker: payload.speaker,
            source: payload.source,
            segment: segment
        ) == true {
            openTranscript?.transcript.append(segment)
        } else {
            flushTimelineBlock(&openTranscript, into: &items)
            openTranscript = TimelineTranscriptAccumulator(
                firstEvent: event,
                transcript: TranscriptBlockAccumulator(
                    speaker: payload.speaker,
                    source: payload.source,
                    segments: [segment]
                )
            )
        }
    }

    private static func flushTimelineBlock(
        _ openTranscript: inout TimelineTranscriptAccumulator?,
        into items: inout [WorkspaceTimelineItem]
    ) {
        guard let accumulator = openTranscript else { return }
        items.append(transcriptItem(accumulator))
        openTranscript = nil
    }

    private static func flushLegacyBlock(
        _ openBlock: inout TranscriptBlockAccumulator?,
        into blocks: inout [WorkspaceTranscriptBlock]
    ) {
        guard let accumulator = openBlock else { return }
        blocks.append(accumulator.block)
        openBlock = nil
    }

    private static func translationOverrides(_ lines: [TranscriptLine]) -> [String: String] {
        var translations: [String: String] = [:]
        for line in lines {
            guard let translation = line.translatedText else { continue }
            translations[line.id.uuidString.lowercased()] = translation
        }
        return translations
    }

    private static func nonTranscriptItem(
        _ event: MeetingTimelineEvent,
        screenshots: [String: ScreenshotAsset]
    ) -> WorkspaceTimelineItem? {
        switch event.payload {
        case .lifecycle(let value):
            return item(event, .lifecycle, "会议状态", value.detail ?? value.status.rawValue)
        case .screenshot(let value):
            return item(
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
            return item(
                event,
                .screenshotAnalysis,
                title,
                value.text,
                isFailure: value.status == "failed"
            )
        case .summary(let value):
            return item(event, .summary, "会议摘要", value.summaryText)
        case .userQuestion, .assistantAnswer, .suggestions, .transcript:
            return nil
        }
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
            endSequence: event.sequence,
            kind: kind,
            title: title,
            body: body,
            timestamp: event.occurredAt,
            screenshot: screenshot,
            sources: sources,
            isFailure: isFailure,
            transcriptBlock: nil
        )
    }

    private static func transcriptItem(
        _ accumulator: TimelineTranscriptAccumulator
    ) -> WorkspaceTimelineItem {
        let block = accumulator.transcript.block
        let event = accumulator.firstEvent
        return WorkspaceTimelineItem(
            id: event.id,
            sequence: event.sequence,
            endSequence: block.segments.last?.sequence ?? event.sequence,
            kind: .transcript,
            title: block.speaker,
            body: block.text,
            timestamp: event.occurredAt,
            screenshot: nil,
            sources: [],
            isFailure: false,
            transcriptBlock: block
        )
    }

}
