import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
protocol ScreenshotSelecting: AnyObject {
    func present(sessionID: String) async throws
}

@MainActor
protocol ContentSharingPickerPresenting: AnyObject {
    var configuration: SCContentSharingPickerConfiguration? { get set }
    var isActive: Bool { get set }
    func add(_ observer: any SCContentSharingPickerObserver)
    func remove(_ observer: any SCContentSharingPickerObserver)
    func present()
}

@available(macOS 14.0, *)
extension SCContentSharingPicker: ContentSharingPickerPresenting {}

enum ScreenshotPickerError: LocalizedError {
    case requiresMacOS14
    case cancelled
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .requiresMacOS14: "系统内容选择器需要 macOS 14 或更高版本"
        case .cancelled: "已取消截图"
        case .encodingFailed: "截图编码失败"
        }
    }
}

@MainActor
final class ScreenCapturePicker: NSObject, ScreenshotSelecting {
    private let uploader: NativeScreenshotUploader
    private let contentPicker: any ContentSharingPickerPresenting
    private var sessionID: String?
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        uploader: NativeScreenshotUploader = NativeScreenshotUploader(),
        contentPicker: any ContentSharingPickerPresenting = SCContentSharingPicker.shared
    ) {
        self.uploader = uploader
        self.contentPicker = contentPicker
    }

    func present(sessionID: String) async throws {
        guard #available(macOS 14.0, *) else {
            throw ScreenshotPickerError.requiresMacOS14
        }
        self.sessionID = sessionID
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            beginPickerPresentation()
        }
    }

    func beginPickerPresentation() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        contentPicker.configuration = configuration
        contentPicker.add(self)
        contentPicker.isActive = true
        contentPicker.present()
    }

    private func finishPickerPresentation() {
        contentPicker.remove(self)
        contentPicker.isActive = false
    }
}

@available(macOS 14.0, *)
extension ScreenCapturePicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            finishPickerPresentation()
            continuation?.resume(throwing: ScreenshotPickerError.cancelled)
            continuation = nil
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            do {
                let configuration = SCStreamConfiguration()
                configuration.width = 1_920
                configuration.height = 1_080
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                let representation = NSBitmapImageRep(cgImage: image)
                guard let pngData = representation.representation(using: .png, properties: [:]),
                      let sessionID
                else {
                    throw ScreenshotPickerError.encodingFailed
                }
                try await uploader.upload(pngData, sessionID: sessionID)
                finishPickerPresentation()
                continuation?.resume()
                continuation = nil
            } catch {
                finishPickerPresentation()
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            finishPickerPresentation()
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
