import Foundation

protocol NativeScreenshotUploading: Sendable {
    func upload(_ pngData: Data, sessionID: String, localOCRText: String?) async throws
}

private struct NativeScreenshotUploadEnvelope: Encodable {
    let mimeType = "image/png"
    let imageBase64: String
    let localOCRText: String?
    let ocrEngine: String?

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case imageBase64 = "image_base64"
        case localOCRText = "local_ocr_text"
        case ocrEngine = "ocr_engine"
    }
}

struct NativeScreenshotUploader: NativeScreenshotUploading, Sendable {
    private let environment: BackendEnvironment
    private let session: URLSession

    init(environment: BackendEnvironment = .local, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    func upload(_ pngData: Data, sessionID: String, localOCRText: String?) async throws {
        var request = environment.request(
            path: "/api/sessions/\(sessionID)/native-screenshot",
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let normalizedOCR = localOCRText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        request.httpBody = try JSONEncoder().encode(
            NativeScreenshotUploadEnvelope(
                imageBase64: pngData.base64EncodedString(),
                localOCRText: normalizedOCR?.isEmpty == false ? normalizedOCR : nil,
                ocrEngine: normalizedOCR?.isEmpty == false ? "apple_vision" : nil
            )
        )
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BackendClientError.serviceRejected(response.statusCode)
        }
    }
}
