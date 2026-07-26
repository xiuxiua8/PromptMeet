import XCTest
@testable import PromptMeet

final class BackendClientTests: XCTestCase {
    func testCreateSessionRequestPreservesExistingRoute() throws {
        let environment = BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!)

        let request = environment.request(path: "/api/sessions", method: "POST")

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/api/sessions")
        XCTAssertEqual(request.httpMethod, "POST")
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
            return (response, #"{"success":false,"message":"没有转录内容可分析"}"#.data(using: .utf8)!)
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
}

private final class BackendClientURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
