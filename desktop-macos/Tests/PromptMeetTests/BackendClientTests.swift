import XCTest

@testable import PromptMeet

final class BackendClientTests: XCTestCase {
    func testWebSocketDecodeAndTransportFailuresBecomeCompanionDisconnects() {
        let decodeError = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "invalid envelope")
        )
        let transportError = URLError(.networkConnectionLost)

        for error in [decodeError, transportError] as [any Error] {
            guard case .companionDisconnected(let message) =
                BackendClient.connectionFailureEvent(error) else {
                return XCTFail("Expected a companion disconnect event")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testCreateSessionRequestPreservesExistingRoute() throws {
        let environment = BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!)

        let request = environment.request(path: "/api/sessions", method: "POST")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/api/sessions")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRehydrateSessionUsesSameIDAndPausedState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendClientURLProtocol.self]
        BackendClientURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/rehydrate")
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["is_paused"] as? Bool, true)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"success":true,"session_id":"session-1"}"#.utf8)
            )
        }
        let client = BackendClient(
            environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!),
            session: URLSession(configuration: configuration)
        )

        try await client.rehydrateSession(sessionID: "session-1", isPaused: true)
    }

    func testWebSocketURLUsesExistingSessionRoute() throws {
        let environment = BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!)

        let url = try environment.webSocketURL(sessionID: "session-1")

        XCTAssertEqual(url.absoluteString, "ws://127.0.0.1:8000/ws/session-1")
    }

    func testRecordingAndSummaryActionsRemainHTTPPosts() {
        let environment = BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!)

        XCTAssertEqual(
            environment.sessionActionRequest(sessionID: "session-1", action: "start-recording").url?.path,
            "/api/sessions/session-1/start-recording"
        )
        XCTAssertEqual(
            environment.sessionActionRequest(sessionID: "session-1", action: "generate-summary").httpMethod,
            "POST"
        )
    }

    func testActionReportsBusinessFailureReturnedWithHTTP200() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendClientURLProtocol.self]
        BackendClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"success":false,"message":"没有转录内容可分析"}"#.utf8))
        }
        let client = BackendClient(
            environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!),
            session: URLSession(configuration: configuration)
        )

        do {
            try await client.perform(sessionID: "session-1", action: "generate-summary")
            XCTFail("Expected business failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "没有转录内容可分析")
        }
    }

    func testSummaryGenerationSendsMilestoneMetadataAndDecodesNoAction() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendClientURLProtocol.self]
        BackendClientURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1/generate-summary")
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["trigger"] as? String, "milestone")
            XCTAssertEqual(json["active_minutes"] as? Int, 5)
            XCTAssertEqual(json["client_input_revision"] as? Int, 3)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"success":true,"status":"no_action","message":"没有新的会议输入"}"#.utf8)
            )
        }
        let client = BackendClient(
            environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!),
            session: URLSession(configuration: configuration)
        )

        let response = try await client.generateSummary(
            sessionID: "session-1",
            request: SummaryGenerationRequest(
                trigger: .milestone,
                activeMinutes: 5,
                clientInputRevision: 3
            )
        )

        XCTAssertEqual(response.status, .noAction)
        XCTAssertEqual(response.message, "没有新的会议输入")
    }

    func testSummaryGenerationSurfacesTypedWorkflowFailureMessage() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendClientURLProtocol.self]
        BackendClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(
                    #"{"success":false,"status":"failed","message":"摘要与待办 · OpenAI 兼容 · summary-model 连接失败"}"#.utf8
                )
            )
        }
        let client = BackendClient(
            environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!),
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.generateSummary(
                sessionID: "session-1",
                request: SummaryGenerationRequest(
                    trigger: .manual,
                    activeMinutes: nil,
                    clientInputRevision: 1
                )
            )
            XCTFail("Expected typed service failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "摘要与待办 · OpenAI 兼容 · summary-model 连接失败"
            )
        }
    }

    func testNativeScreenshotUploaderSendsPixelsAndOCRAsJSON() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendClientURLProtocol.self]
        BackendClientURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/meeting-ocr/native-screenshot")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["mime_type"] as? String, "image/png")
            XCTAssertEqual(json["ocr_engine"] as? String, "apple_vision")
            XCTAssertEqual(
                json["local_ocr_text"] as? String,
                "截图证据：青岚计划在 14:30 部署，负责人周岚。"
            )
            let encoded = try XCTUnwrap(json["image_base64"] as? String)
            XCTAssertEqual(Data(base64Encoded: encoded), Data([0, 1, 2, 3]))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"success":true,"status":"analyzing"}"#.utf8))
        }
        let uploader = NativeScreenshotUploader(
            environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!),
            session: URLSession(configuration: configuration)
        )

        try await uploader.upload(
            Data([0, 1, 2, 3]),
            sessionID: "meeting-ocr",
            localOCRText: "截图证据：青岚计划在 14:30 部署，负责人周岚。"
        )
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? BackendClientError.invalidResponse
        }
        if count == 0 {
            break
        }
        body.append(buffer, count: count)
    }
    return body
}

private final class BackendClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
