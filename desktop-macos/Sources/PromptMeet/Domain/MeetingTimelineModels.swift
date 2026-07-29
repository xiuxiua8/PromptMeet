import Foundation

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
