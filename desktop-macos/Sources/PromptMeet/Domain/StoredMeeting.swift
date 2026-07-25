import Foundation

struct StoredMeeting: Identifiable, Equatable {
    let id: String
    let startTime: Date
    let transcript: [TranscriptLine]
    let summary: MeetingSummaryContent?

    static func parseList(_ data: Data) throws -> [StoredMeeting] {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BackendClientError.invalidResponse
        }
        return objects.compactMap(parse)
            .sorted { $0.startTime > $1.startTime }
    }

    private static func parse(_ object: [String: Any]) -> StoredMeeting? {
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
                timestamp: parseDate(segment["timestamp"] as? String)
            )
        }
        let summary = (object["current_summary"] as? [String: Any]).flatMap(parseSummary)
        return StoredMeeting(id: id, startTime: startTime, transcript: transcript, summary: summary)
    }

    private static func parseSummary(_ payload: [String: Any]) -> MeetingSummaryContent? {
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
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) ?? Date.distantPast
    }
}
