import Foundation

struct BackendEnvironment: Equatable {
    var baseURL: URL

    /// Loopback companion backend. `PROMPTMEET_BACKEND_URL` overrides the
    /// endpoint so packaged instances can run against an isolated companion
    /// instead of one another's.
    static var local: BackendEnvironment {
        BackendEnvironment(
            baseURL: URL(
                string: ProcessInfo.processInfo.environment["PROMPTMEET_BACKEND_URL"]
                    ?? "http://127.0.0.1:8000"
            )!
        )
    }

    func request(path: String, method: String = "GET") -> URLRequest {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func sessionActionRequest(sessionID: String, action: String) -> URLRequest {
        request(path: "/api/sessions/\(sessionID)/\(action)", method: "POST")
    }

    func webSocketURL(sessionID: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BackendClientError.invalidURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/\(sessionID)"
        guard let url = components.url else {
            throw BackendClientError.invalidURL
        }
        return url
    }
}
