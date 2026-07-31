import Foundation

enum BackendClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serviceRejected(Int)
    case serviceMessage(String)
    case missingSessionID
    case socketUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "后端地址无效"
        case .invalidResponse:
            "后端返回了无法识别的数据"
        case .serviceRejected(let status):
            "后端请求失败（\(status)）"
        case .serviceMessage(let message):
            message
        case .missingSessionID:
            "后端未返回会话 ID"
        case .socketUnavailable:
            "实时连接尚未建立"
        }
    }
}

enum SummaryGenerationTrigger: String, Codable, Equatable, Sendable {
    case manual
    case milestone
}

struct SummaryGenerationRequest: Codable, Equatable, Sendable {
    let trigger: SummaryGenerationTrigger
    let activeMinutes: Int?
    let clientInputRevision: Int

    enum CodingKeys: String, CodingKey {
        case trigger
        case activeMinutes = "active_minutes"
        case clientInputRevision = "client_input_revision"
    }
}

enum SummaryGenerationStatus: String, Codable, Equatable, Sendable {
    case generated
    case noAction = "no_action"
    case failed
}

struct SummaryGenerationResponse: Decodable, Equatable, Sendable {
    let success: Bool
    let status: SummaryGenerationStatus
    let message: String
}

protocol BackendClientProtocol: AnyObject, Sendable {
    func healthCheck() async throws
    func createSession() async throws -> String
    func perform(sessionID: String, action: String) async throws
    func generateQuestions(
        sessionID: String,
        generationID: UUID,
        contextRevision: Int
    ) async throws
    func generateSummary(
        sessionID: String,
        request: SummaryGenerationRequest
    ) async throws -> SummaryGenerationResponse
    func connect(sessionID: String, onEvent: @escaping @Sendable (BackendEvent) -> Void) throws
    func sendPrompt(_ prompt: String, requestID: UUID) async throws
    func submitTranscript(_ transcript: LocalTranscript, sessionID: String) async throws
    func fetchMeetingHistory() async throws -> [StoredMeeting]
    func fetchMeeting(id: String) async throws -> StoredMeeting
    func askMeeting(
        meetingID: String,
        question: String,
        requestID: UUID,
        threadID: String
    ) async throws -> HistoricalMeetingAnswer
    func disconnect()
}

private struct BackendActionResponse: Decodable {
    let success: Bool
    let message: String?
}

private struct BackendCreateSessionResponse: Decodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

final class BackendClient: BackendClientProtocol, @unchecked Sendable {
    private let environment: BackendEnvironment
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var listener: Task<Void, Never>?

    init(environment: BackendEnvironment = .local, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    func healthCheck() async throws {
        let (_, response) = try await session.data(for: environment.request(path: "/health"))
        try validate(response)
    }

    func createSession() async throws -> String {
        let (data, response) = try await session.data(
            for: environment.request(path: "/api/sessions", method: "POST")
        )
        try validate(response)
        guard let result = try? JSONDecoder().decode(BackendCreateSessionResponse.self, from: data) else {
            throw BackendClientError.missingSessionID
        }
        return result.sessionID
    }

    func perform(sessionID: String, action: String) async throws {
        let (data, response) = try await session.data(
            for: environment.sessionActionRequest(sessionID: sessionID, action: action)
        )
        try validate(response)
        if let result = try? JSONDecoder().decode(BackendActionResponse.self, from: data), !result.success {
            throw BackendClientError.serviceMessage(result.message ?? "操作未完成")
        }
    }

    func generateQuestions(
        sessionID: String,
        generationID: UUID,
        contextRevision: Int
    ) async throws {
        var request = environment.sessionActionRequest(
            sessionID: sessionID,
            action: "generate-questions"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "generation_id": generationID.uuidString,
                "context_revision": contextRevision
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)
        if let result = try? JSONDecoder().decode(BackendActionResponse.self, from: data), !result.success {
            throw BackendClientError.serviceMessage(result.message ?? "问题生成未完成")
        }
    }

    func generateSummary(
        sessionID: String,
        request summaryRequest: SummaryGenerationRequest
    ) async throws -> SummaryGenerationResponse {
        var request = environment.sessionActionRequest(
            sessionID: sessionID,
            action: "generate-summary"
        )
        request.httpBody = try JSONEncoder().encode(summaryRequest)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        let result = try JSONDecoder().decode(SummaryGenerationResponse.self, from: data)
        guard result.success else {
            throw BackendClientError.serviceMessage(result.message)
        }
        return result
    }

    func connect(
        sessionID: String,
        onEvent: @escaping @Sendable (BackendEvent) -> Void
    ) throws {
        disconnect()
        let task = session.webSocketTask(with: try environment.webSocketURL(sessionID: sessionID))
        socket = task
        task.resume()
        listener = Task { [weak self] in
            guard let self else { return }
            await self.listen(onEvent: onEvent)
        }
    }

    func sendPrompt(_ prompt: String, requestID: UUID) async throws {
        guard let socket else { throw BackendClientError.socketUnavailable }
        let payload: [String: Any] = [
            "type": "agent_message",
            "data": ["request_id": requestID.uuidString, "content": prompt]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackendClientError.invalidResponse
        }
        try await socket.send(.string(text))
    }

    func submitTranscript(_ transcript: LocalTranscript, sessionID: String) async throws {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": transcript.id.uuidString,
            "text": transcript.text,
            "speaker": transcript.speaker,
            "source": transcript.source.rawValue,
            "timestamp": formatter.string(from: transcript.timestamp),
            "meeting_time_ms": transcript.meetingTime?.millisecondsValue as Any
        ]
        if transcript.meetingTime == nil {
            payload.removeValue(forKey: "meeting_time_ms")
        }
        if let translationTarget = transcript.translationTarget {
            payload["translation_target"] = translationTarget
        }
        var request = environment.request(
            path: "/api/sessions/\(sessionID)/native-transcript",
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func fetchMeetingHistory() async throws -> [StoredMeeting] {
        let (data, response) = try await session.data(for: environment.request(path: "/api/meetings"))
        try validate(response)
        return try StoredMeeting.parseList(data)
    }

    func fetchMeeting(id: String) async throws -> StoredMeeting {
        let (data, response) = try await session.data(
            for: environment.request(path: "/api/meetings/\(id)")
        )
        try validate(response)
        let wrapped = Data("[".utf8) + data + Data("]".utf8)
        guard let meeting = try StoredMeeting.parseList(wrapped).first else {
            throw BackendClientError.invalidResponse
        }
        return meeting
    }

    func askMeeting(
        meetingID: String,
        question: String,
        requestID: UUID,
        threadID: String = "main"
    ) async throws -> HistoricalMeetingAnswer {
        var request = environment.request(
            path: "/api/meetings/\(meetingID)/questions",
            method: "POST"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "request_id": requestID.uuidString,
                "thread_id": threadID,
                "question": question
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(HistoricalMeetingAnswer.self, from: data)
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func listen(onEvent: @escaping @Sendable (BackendEvent) -> Void) async {
        guard let socket else { return }
        var batcher = BackendEventBatcher()
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    text = value
                @unknown default:
                    continue
                }
                for event in batcher.consume(try BackendEvent.decode(text)) {
                    onEvent(event)
                }
            } catch {
                if !Task.isCancelled {
                    for event in batcher.finish() {
                        onEvent(event)
                    }
                    onEvent(.failure(error.localizedDescription))
                }
                return
            }
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendClientError.serviceRejected(response.statusCode)
        }
    }
}
