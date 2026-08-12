import Foundation
import ImageIO
@preconcurrency import Vision

protocol ScreenshotOCRRecognizing: Sendable {
    func recognize(_ pngData: Data) async throws -> String?
}

struct LocalScreenshotOCR: ScreenshotOCRRecognizing, Sendable {
    func recognize(_ pngData: Data) async throws -> String? {
        try await Task.detached(priority: .utility) {
            try Self.recognizeSynchronously(pngData)
        }.value
    }

    private static func recognizeSynchronously(_ pngData: Data) throws -> String? {
        guard
            let source = CGImageSourceCreateWithData(pngData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let verticalDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if verticalDistance > 0.02 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let lines = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
