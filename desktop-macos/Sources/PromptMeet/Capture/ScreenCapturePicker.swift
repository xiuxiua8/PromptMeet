import AppKit
@preconcurrency import ScreenCaptureKit

@MainActor
protocol ScreenshotCaptureControlling: AnyObject {
    var targetState: ScreenshotTargetState { get }
    func selectTarget() async throws -> ScreenshotTargetState
    func captureSelected(sessionID: String) async throws
    func openScreenRecordingSettings()
}

@MainActor
protocol ScreenshotTargetPicking: AnyObject {
    func pickTarget() async throws -> ScreenshotTargetHandle
}

@MainActor
protocol ScreenshotTargetCapturing: AnyObject {
    func capture(_ target: ScreenshotTargetHandle) async throws -> Data
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

struct ScreenshotTargetHandle: @unchecked Sendable {
    let id: UUID
    let label: String
    fileprivate let filter: SCContentFilter?

    init(id: UUID = UUID(), label: String, filter: SCContentFilter? = nil) {
        self.id = id
        self.label = label
        self.filter = filter
    }
}

enum ScreenshotPickerError: LocalizedError, Equatable {
    case requiresMacOS14
    case cancelled
    case encodingFailed
    case noSelectedTarget
    case selectionInProgress
    case screenRecordingDenied
    case selectedTargetUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .requiresMacOS14: "系统内容选择器需要 macOS 14 或更高版本"
        case .cancelled: "已取消窗口选择"
        case .encodingFailed: "截图编码失败"
        case .noSelectedTarget: "请先选择窗口"
        case .selectionInProgress: "窗口选择器已打开"
        case .screenRecordingDenied: "需要屏幕录制权限才能选择和截取窗口"
        case .selectedTargetUnavailable(let label): "已选择的窗口不可用：\(label)"
        }
    }
}

@MainActor
final class ScreenCaptureController: ScreenshotCaptureControlling {
    private let targetPicker: any ScreenshotTargetPicking
    private let targetCapturer: any ScreenshotTargetCapturing
    private let uploader: any NativeScreenshotUploading
    private let permission: any ScreenRecordingPermissionProviding
    private var selectedTarget: ScreenshotTargetHandle?
    private(set) var targetState: ScreenshotTargetState = .none

    init(
        targetPicker: any ScreenshotTargetPicking = SystemContentSharingTargetPicker(),
        targetCapturer: any ScreenshotTargetCapturing = SystemScreenshotTargetCapturer(),
        uploader: any NativeScreenshotUploading = NativeScreenshotUploader(),
        permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission()
    ) {
        self.targetPicker = targetPicker
        self.targetCapturer = targetCapturer
        self.uploader = uploader
        self.permission = permission
    }

    func selectTarget() async throws -> ScreenshotTargetState {
        let target = try await targetPicker.pickTarget()
        selectedTarget = target
        targetState = .selected(label: target.label)
        return targetState
    }

    func captureSelected(sessionID: String) async throws {
        guard let selectedTarget else { throw ScreenshotPickerError.noSelectedTarget }
        do {
            let data = try await targetCapturer.capture(selectedTarget)
            try await uploader.upload(data, sessionID: sessionID)
            targetState = .selected(label: selectedTarget.label)
        } catch let error as ScreenshotPickerError {
            if case .selectedTargetUnavailable = error {
                targetState = .invalid(
                    label: selectedTarget.label,
                    reason: error.localizedDescription
                )
            }
            throw error
        } catch {
            let unavailable = ScreenshotPickerError.selectedTargetUnavailable(
                selectedTarget.label
            )
            targetState = .invalid(
                label: selectedTarget.label,
                reason: error.localizedDescription
            )
            throw unavailable
        }
    }

    func openScreenRecordingSettings() {
        permission.openSystemSettings()
    }
}

@MainActor
final class SystemContentSharingTargetPicker: NSObject, ScreenshotTargetPicking {
    private let contentPicker: any ContentSharingPickerPresenting
    private let permission: any ScreenRecordingPermissionProviding
    private var continuation: CheckedContinuation<ScreenshotTargetHandle, Error>?

    init(
        contentPicker: any ContentSharingPickerPresenting = SCContentSharingPicker.shared,
        permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission()
    ) {
        self.contentPicker = contentPicker
        self.permission = permission
    }

    func pickTarget() async throws -> ScreenshotTargetHandle {
        guard #available(macOS 14.0, *) else { throw ScreenshotPickerError.requiresMacOS14 }
        guard continuation == nil else { throw ScreenshotPickerError.selectionInProgress }
        guard
            await ScreenRecordingPermissionResolver(
                permission: permission
            ).resolveForUserAction()
        else {
            throw ScreenshotPickerError.screenRecordingDenied
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            beginPickerPresentation()
        }
    }

    func beginPickerPresentation() {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        contentPicker.configuration = configuration
        contentPicker.add(self)
        contentPicker.isActive = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        contentPicker.present()
    }

    private func finish() {
        contentPicker.remove(self)
        contentPicker.isActive = false
    }

    private static func label(for filter: SCContentFilter) -> String {
        if #available(macOS 15.2, *), let window = filter.includedWindows.first {
            let application = window.owningApplication?.applicationName
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [application, title].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
        }
        switch filter.style {
        case .window: return "已选择窗口"
        case .display: return "已选择屏幕"
        case .application: return "已选择应用"
        default: return "已选择采集目标"
        }
    }
}

@available(macOS 14.0, *)
extension SystemContentSharingTargetPicker: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            finish()
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
            let target = ScreenshotTargetHandle(label: Self.label(for: filter), filter: filter)
            finish()
            continuation?.resume(returning: target)
            continuation = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            finish()
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

@MainActor
final class SystemScreenshotTargetCapturer: ScreenshotTargetCapturing {
    private let permission: any ScreenRecordingPermissionProviding

    init(permission: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermission()) {
        self.permission = permission
    }

    func capture(_ target: ScreenshotTargetHandle) async throws -> Data {
        guard permission.hasAccess else { throw ScreenshotPickerError.screenRecordingDenied }
        guard let filter = target.filter else {
            throw ScreenshotPickerError.selectedTargetUnavailable(target.label)
        }
        let configuration = SCStreamConfiguration()
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let rawWidth = max(1, filter.contentRect.width * scale)
        let rawHeight = max(1, filter.contentRect.height * scale)
        let downscale = min(1, min(1_920 / rawWidth, 1_080 / rawHeight))
        configuration.width = Int(rawWidth * downscale)
        configuration.height = Int(rawHeight * downscale)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw ScreenshotPickerError.encodingFailed
            }
            return data
        } catch let error as ScreenshotPickerError {
            throw error
        } catch {
            throw ScreenshotPickerError.selectedTargetUnavailable(target.label)
        }
    }
}
