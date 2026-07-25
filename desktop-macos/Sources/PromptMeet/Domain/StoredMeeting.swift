import Foundation

struct StoredMeeting: Identifiable, Equatable, Sendable {
    let id: String
    let schemaVersion: Int
    let title: String?
    let status: StoredMeetingStatus
    let startTime: Date
    let endTime: Date?
    let timeline: [MeetingTimelineEvent]
    let transcript: [TranscriptLine]
    let summary: MeetingSummaryContent?

    var screenshots: [ScreenshotAsset] {
        MeetingTimelineProjection.screenshots(timeline)
    }

    var conversation: [ConversationTurn] {
        MeetingTimelineProjection.conversation(timeline)
    }

    init(
        id: String,
        schemaVersion: Int = 1,
        title: String? = nil,
        status: StoredMeetingStatus = .completed,
        startTime: Date,
        endTime: Date? = nil,
        timeline: [MeetingTimelineEvent] = [],
        transcript: [TranscriptLine],
        summary: MeetingSummaryContent?
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.status = status
        self.startTime = startTime
        self.endTime = endTime
        self.timeline = timeline
        self.transcript = transcript
        self.summary = summary
    }

    static func parseList(_ data: Data) throws -> [StoredMeeting] {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendClientError.invalidResponse
        }
        if objects.contains(where: { ($0["schema_version"] as? Int) == 2 }) {
            let records = try JSONDecoder.meetingTimeline.decode([VersionTwoRecord].self, from: data)
            return records.map(StoredMeeting.init).sorted { $0.startTime > $1.startTime }
        }
        return objects.compactMap(parseLegacy).sorted { $0.startTime > $1.startTime }
    }

    private init(_ record: VersionTwoRecord) {
        let sortedTimeline = record.events.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.occurredAt < $1.occurredAt
        }
        id = record.meetingID
        schemaVersion = record.schemaVersion
        title = record.title
        status = record.status
        startTime = record.startedAt
        endTime = record.endedAt
        timeline = sortedTimeline
        transcript = sortedTimeline.compactMap(\.transcript)
        summary = sortedTimeline.reversed().compactMap { event -> MeetingSummaryContent? in
            guard case let .summary(value) = event.payload else { return nil }
            return MeetingSummaryContent(
                summaryText: value.summaryText,
                tasks: value.tasks.compactMap(Self.task),
                keyPoints: value.keyPoints,
                decisions: value.decisions
            )
        }.first
    }

    private static func task(_ payload: [String: JSONValue]) -> MeetingTask? {
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

    private static func parseLegacy(_ object: [String: Any]) -> StoredMeeting? {
        guard let id = object["session_id"] as? String else { return nil }
        let startTime = parseDate(object["start_time"] as? String)
        let transcript = (object["transcript_segments"] as? [[String: Any]] ?? []).compactMap {
            segment -> TranscriptLine? in
            guard let text = segment["text"] as? String else { return nil }
            let identifier = (segment["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return TranscriptLine(
                id: identifier,
                speaker: segment["speaker"] as? String ?? "发言人",
                text: text,
                timestamp: parseDate(segment["timestamp"] as? String),
                translatedText: segment["translated_text"] as? String
            )
        }
        let summary = (object["current_summary"] as? [String: Any]).flatMap(parseLegacySummary)
        return StoredMeeting(
            id: id,
            schemaVersion: object["schema_version"] as? Int ?? 1,
            status: StoredMeetingStatus(rawValue: object["status"] as? String ?? "completed") ?? .completed,
            startTime: startTime,
            endTime: (object["end_time"] as? String).map(parseDate),
            transcript: transcript,
            summary: summary
        )
    }

    private static func parseLegacySummary(_ payload: [String: Any]) -> MeetingSummaryContent? {
        guard let summaryText = payload["summary_text"] as? String else { return nil }
        let tasks = (payload["tasks"] as? [[String: Any]] ?? []).compactMap { task -> MeetingTask? in
            guard let title = task["task"] as? String, !title.isEmpty else { return nil }
            return MeetingTask(
                title: title,
                deadline: task["deadline"] as? String,
                details: task["describe"] as? String ?? "",
                priority: task["priority"] as? String ?? "medium",
                assignee: task["assignee"] as? String,
                status: task["status"] as? String ?? "pending"
            )
        }
        return MeetingSummaryContent(
            summaryText: summaryText,
            tasks: tasks,
            keyPoints: payload["key_points"] as? [String] ?? [],
            decisions: payload["decisions"] as? [String] ?? []
        )
    }

    private static func parseDate(_ value: String?) -> Date {
        guard let value else { return Date.distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value) ?? Date.distantPast
    }
}

private struct VersionTwoRecord: Decodable {
    let schemaVersion: Int
    let meetingID: String
    let title: String?
    let status: StoredMeetingStatus
    let startedAt: Date
    let endedAt: Date?
    let events: [MeetingTimelineEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case title, status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case events
    }
}
