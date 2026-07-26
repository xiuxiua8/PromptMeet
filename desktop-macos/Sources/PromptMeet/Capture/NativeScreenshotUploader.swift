import Foundation

protocol NativeScreenshotUploading: Sendable {
    func upload(_ pngData: Data, sessionID: String) async throws
}

struct NativeScreenshotUploader: NativeScreenshotUploading, Sendable {
    private let environment: BackendEnvironment
    private let session: URLSession

    init(environment: BackendEnvironment = .local, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    func upload(_ pngData: Data, sessionID: String) async throws {
        var request = environment.request(
            path: "/api/sessions/\(sessionID)/native-screenshot",
            method: "POST"
        )
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.httpBody = pngData
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendClientError.serviceRejected(response.statusCode)
        }
    }
}
