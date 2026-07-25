import Foundation

enum StoredMeetingStatus: String, Codable, Equatable, Sendable {
    case active
    case completed
    case incomplete
    case recoveryRequired = "recovery_required"
}

enum MeetingTimelineKind: String, Codable, Equatable, Sendable {
    case lifecycle
    case transcript
    case screenshot
    case screenshotAnalysis = "screenshot_analysis"
    case userQuestion = "user_question"
    case assistantAnswer = "assistant_answer"
    case summary
}

struct TimelineProvenance: Codable, Equatable, Sendable {
    let source: String
    let provider: String?
    let model: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case source, provider, model
        case requestID = "request_id"
    }
}

struct EvidenceSource: Codable, Equatable, Identifiable, Sendable {
    let sourceID: String
    let eventID: String
    let label: String

    var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case eventID = "event_id"
        case label
    }
}

struct TimelineLifecyclePayload: Codable, Equatable, Sendable {
    let status: StoredMeetingStatus
    let detail: String?
}

struct TimelineTranscriptPayload: Codable, Equatable, Sendable {
    let segmentID: String
    let text: String
    let speaker: String
    let source: String?
    let translatedText: String?

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case text, speaker, source
        case translatedText = "translated_text"
    }
}

struct TimelineScreenshotPayload: Codable, Equatable, Sendable {
    let assetID: String
    let relativePath: String
    let mimeType: String
    let sha256: String
    let width: Int?
    let height: Int?
    let captureStatus: String

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case relativePath = "relative_path"
        case mimeType = "mime_type"
        case sha256, width, height
        case captureStatus = "capture_status"
    }
}

struct TimelineScreenshotAnalysisPayload: Codable, Equatable, Sendable {
    let assetID: String
    let status: String
    let text: String
    let visionUsed: Bool

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case status, text
        case visionUsed = "vision_used"
    }
}

struct TimelineQuestionPayload: Codable, Equatable, Sendable {
    let requestID: String
    let threadID: String
    let question: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case threadID = "thread_id"
        case question
    }
}

struct TimelineAnswerPayload: Codable, Equatable, Sendable {
    let requestID: String
    let threadID: String
    let answer: String
    let sources: [EvidenceSource]
    let degradedVision: Bool
    let status: String
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case threadID = "thread_id"
        case answer, sources, status
        case degradedVision = "degraded_vision"
        case errorMessage = "error_message"
    }
}

struct TimelineSummaryPayload: Codable, Equatable, Sendable {
    let summaryText: String
    let tasks: [[String: JSONValue]]
    let keyPoints: [String]
    let decisions: [String]

    enum CodingKeys: String, CodingKey {
        case summaryText = "summary_text"
        case tasks
        case keyPoints = "key_points"
        case decisions
    }
}

indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null
        } else if let value = try? container.decode(String.self) { self = .string(value)
        } else if let value = try? container.decode(Bool.self) { self = .bool(value)
        } else if let value = try? container.decode(Double.self) { self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) { self = .object(value)
        } else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

enum MeetingTimelinePayload: Equatable, Decodable, Sendable {
    case lifecycle(TimelineLifecyclePayload)
    case transcript(TimelineTranscriptPayload)
    case screenshot(TimelineScreenshotPayload)
    case screenshotAnalysis(TimelineScreenshotAnalysisPayload)
    case userQuestion(TimelineQuestionPayload)
    case assistantAnswer(TimelineAnswerPayload)
    case summary(TimelineSummaryPayload)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "lifecycle": self = .lifecycle(try TimelineLifecyclePayload(from: decoder))
        case "transcript": self = .transcript(try TimelineTranscriptPayload(from: decoder))
        case "screenshot": self = .screenshot(try TimelineScreenshotPayload(from: decoder))
        case "screenshot_analysis":
            self = .screenshotAnalysis(try TimelineScreenshotAnalysisPayload(from: decoder))
        case "user_question": self = .userQuestion(try TimelineQuestionPayload(from: decoder))
        case "assistant_answer":
            self = .assistantAnswer(try TimelineAnswerPayload(from: decoder))
        case "summary": self = .summary(try TimelineSummaryPayload(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown meeting timeline payload"
            )
        }
    }
}

struct MeetingTimelineEvent: Identifiable, Equatable, Decodable, Sendable {
    let eventID: String
    let meetingID: String
    let sequence: Int
    let occurredAt: Date
    let kind: MeetingTimelineKind
    let provenance: TimelineProvenance
    let payload: MeetingTimelinePayload

    var id: String { eventID }

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case meetingID = "meeting_id"
        case sequence
        case occurredAt = "occurred_at"
        case kind, provenance, payload
    }

    var transcript: TranscriptLine? {
        guard case let .transcript(value) = payload else { return nil }
        return TranscriptLine(
            id: UUID(uuidString: value.segmentID) ?? UUID(),
            speaker: value.speaker,
            text: value.text,
            timestamp: occurredAt,
            translatedText: value.translatedText
        )
    }

    var screenshot: ScreenshotAsset? {
        guard case let .screenshot(value) = payload else { return nil }
        return ScreenshotAsset(
            id: value.assetID,
            relativePath: value.relativePath,
            mimeType: value.mimeType,
            width: value.width,
            height: value.height,
            capturedAt: occurredAt,
            analysis: nil
        )
    }
}

struct ScreenshotAnalysis: Equatable, Sendable {
    let status: String
    let text: String
    let visionUsed: Bool
    let provider: String?
    let model: String?
}

struct ScreenshotAsset: Identifiable, Equatable, Sendable {
    let id: String
    let relativePath: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let capturedAt: Date
    var analysis: ScreenshotAnalysis?

    func availableFileURL(dataRoot: URL = Self.defaultDataRoot) -> URL? {
        let url = dataRoot.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var defaultDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
    }
}

enum ConversationTurnPhase: Equatable, Sendable {
    case submitting
    case streaming
    case completed
    case failed
}

struct ConversationTurn: Identifiable, Equatable, Sendable {
    let id: String
    let requestID: String
    let threadID: String
    var meetingID: String?
    var question: String
    var answer: String
    var phase: ConversationTurnPhase
    var errorMessage: String?
    var sources: [EvidenceSource]
    var degradedVision: Bool
    let askedAt: Date
    var answeredAt: Date?
}

struct HistoricalMeetingAnswer: Equatable, Decodable, Sendable {
    let requestID: UUID
    let answer: String
    let sources: [EvidenceSource]
    let degradedVision: Bool

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case answer, sources
        case degradedVision = "degraded_vision"
    }
}

enum MeetingTimelineProjection {
    static func screenshots(_ events: [MeetingTimelineEvent]) -> [ScreenshotAsset] {
        var assets: [ScreenshotAsset] = []
        for event in events.sorted(by: eventOrder) {
            if let screenshot = event.screenshot {
                assets.append(screenshot)
                continue
            }
            guard case let .screenshotAnalysis(value) = event.payload,
                  let index = assets.firstIndex(where: { $0.id == value.assetID })
            else { continue }
            assets[index].analysis = ScreenshotAnalysis(
                status: value.status,
                text: value.text,
                visionUsed: value.visionUsed,
                provider: event.provenance.provider,
                model: event.provenance.model
            )
        }
        return assets
    }

    static func conversation(_ events: [MeetingTimelineEvent]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for event in events.sorted(by: eventOrder) {
            switch event.payload {
            case let .userQuestion(value):
                if !turns.contains(where: { $0.requestID == value.requestID }) {
                    turns.append(
                        ConversationTurn(
                            id: value.requestID,
                            requestID: value.requestID,
                            threadID: value.threadID,
                            meetingID: event.meetingID,
                            question: value.question,
                            answer: "",
                            phase: .submitting,
                            errorMessage: nil,
                            sources: [],
                            degradedVision: false,
                            askedAt: event.occurredAt,
                            answeredAt: nil
                        )
                    )
                }
            case let .assistantAnswer(value):
                let index: Int
                if let existing = turns.firstIndex(where: { $0.requestID == value.requestID }) {
                    index = existing
                } else {
                    turns.append(
                        ConversationTurn(
                            id: value.requestID,
                            requestID: value.requestID,
                            threadID: value.threadID,
                            meetingID: event.meetingID,
                            question: "历史问题",
                            answer: "",
                            phase: .submitting,
                            errorMessage: nil,
                            sources: [],
                            degradedVision: false,
                            askedAt: event.occurredAt,
                            answeredAt: nil
                        )
                    )
                    index = turns.count - 1
                }
                turns[index].answer = value.answer
                turns[index].phase = value.status == "failed" ? .failed : .completed
                turns[index].errorMessage = value.errorMessage
                turns[index].sources = value.sources
                turns[index].degradedVision = value.degradedVision
                turns[index].answeredAt = event.occurredAt
            default:
                break
            }
        }
        return turns
    }

    private static func eventOrder(_ lhs: MeetingTimelineEvent, _ rhs: MeetingTimelineEvent) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.occurredAt < rhs.occurredAt
    }
}

extension JSONDecoder {
    static var meetingTimeline: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date")
            )
        }
        return decoder
    }
}
