import Foundation

enum BackendEvent: Equatable, Sendable {
    case connectionEstablished
    case meetingEvent(MeetingTimelineEvent)
    case transcript(TranscriptLine)
    case translation(id: UUID, text: String)
    case answerDelta(requestID: UUID?, delta: String)
    case answerFinal(requestID: UUID?, answer: String)
    case aiFailure(requestID: UUID?, message: String)
    case question(String)
    case questions(generationID: UUID?, contextRevision: Int?, questions: [String])
    case suggestion(String)
    case summary(MeetingSummaryContent)
    case screenshotInsight(String)
    case failure(String)
    case ignored

    static func decode(_ text: String) throws -> BackendEvent {
        let (type, payload) = try envelope(from: text)
        switch type {
        case "connection_established", "meeting_event", "audio_transcript", "transcript":
            return try decodeCaptureEvent(type: type, payload: payload)
        case "answer", "transcript_translation", "question", "questions":
            return decodeConversationEvent(type: type, payload: payload)
        case "summary_generated", "summary", "image_ocr_result", "error":
            return decodeInsightEvent(type: type, payload: payload)
        default:
            return .ignored
        }
    }

    private static func envelope(from text: String) throws -> (String, [String: Any]) {
        guard let data = text.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "WebSocket 消息不是 UTF-8")
            )
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard
            let envelope = object as? [String: Any],
            let type = envelope["type"] as? String
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "WebSocket 消息缺少 type")
            )
        }
        return (type, envelope["data"] as? [String: Any] ?? [:])
    }

    private static func decodeCaptureEvent(
        type: String,
        payload: [String: Any]
    ) throws -> BackendEvent {
        switch type {
        case "connection_established":
            return .connectionEstablished
        case "meeting_event":
            let eventData = try JSONSerialization.data(withJSONObject: payload)
            return .meetingEvent(
                try JSONDecoder.meetingTimeline.decode(MeetingTimelineEvent.self, from: eventData)
            )
        case "audio_transcript", "transcript":
            return decodeTranscript(payload)
        default:
            return .ignored
        }
    }

    private static func decodeTranscript(_ payload: [String: Any]) -> BackendEvent {
        guard let text = payload["text"] as? String else { return .ignored }
        let identifier = (payload["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let source = (payload["source"] as? String).flatMap(NativeAudioSource.init(rawValue:))
        let meetingTime = (payload["meeting_time_ms"] as? NSNumber).map {
            Duration.milliseconds($0.int64Value)
        }
        return .transcript(
            TranscriptLine(
                id: identifier,
                speaker: payload["speaker"] as? String ?? "发言人",
                text: text,
                timestamp: parseDate(payload["timestamp"] as? String),
                source: source,
                meetingTime: meetingTime
            )
        )
    }

    private static func decodeConversationEvent(
        type: String,
        payload: [String: Any]
    ) -> BackendEvent {
        switch type {
        case "answer":
            return decodeAnswer(payload)
        case "transcript_translation":
            return decodeTranslation(payload)
        case "question":
            guard let content = payload["content"] as? String else { return .ignored }
            return .question(content)
        case "questions":
            return decodeQuestions(payload)
        default:
            return .ignored
        }
    }

    private static func decodeAnswer(_ payload: [String: Any]) -> BackendEvent {
        let requestID = (payload["request_id"] as? String).flatMap(UUID.init(uuidString:))
        if let delta = (payload["delta"] ?? payload["chunk"]) as? String {
            return .answerDelta(requestID: requestID, delta: delta)
        }
        if let content = payload["content"] as? String {
            return .answerFinal(requestID: requestID, answer: content)
        }
        return .ignored
    }

    private static func decodeTranslation(_ payload: [String: Any]) -> BackendEvent {
        guard let rawID = payload["id"] as? String,
              let identifier = UUID(uuidString: rawID),
              let translatedText = payload["translated_text"] as? String else {
            return .ignored
        }
        return .translation(id: identifier, text: translatedText)
    }

    private static func decodeQuestions(_ payload: [String: Any]) -> BackendEvent {
        let questions = (payload["questions"] as? [[String: Any]] ?? []).compactMap {
            ($0["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return .questions(
            generationID: (payload["generation_id"] as? String).flatMap(UUID.init(uuidString:)),
            contextRevision: (payload["context_revision"] as? NSNumber)?.intValue,
            questions: questions
        )
    }

    private static func decodeInsightEvent(
        type: String,
        payload: [String: Any]
    ) -> BackendEvent {
        switch type {
        case "summary_generated", "summary":
            return decodeSummary(payload)
        case "image_ocr_result":
            guard let content = payload["content"] as? String, !content.isEmpty else {
                return .ignored
            }
            return .screenshotInsight(content)
        case "error":
            if payload["scope"] as? String == "ai" {
                let requestID = (payload["request_id"] as? String).flatMap(UUID.init(uuidString:))
                return .aiFailure(
                    requestID: requestID,
                    message: payload["message"] as? String ?? "AI 服务发生错误"
                )
            }
            return .failure(payload["message"] as? String ?? "后端服务发生错误")
        default:
            return .ignored
        }
    }

    private static func decodeSummary(_ payload: [String: Any]) -> BackendEvent {
        guard let summary = (payload["summary_text"] ?? payload["content"]) as? String else {
            return .ignored
        }
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
        return .summary(
            MeetingSummaryContent(
                summaryText: summary,
                tasks: tasks,
                keyPoints: payload["key_points"] as? [String] ?? [],
                decisions: payload["decisions"] as? [String] ?? []
            )
        )
    }

    private static func parseDate(_ value: String?) -> Date {
        guard let value else { return Date() }
        return ISO8601DateFormatter().date(from: value) ?? Date()
    }
}
