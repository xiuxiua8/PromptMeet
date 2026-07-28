import AVFoundation
import AppKit
import CoreGraphics
import Foundation

enum CapturePermissionSettingsURL {
    static let microphone = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!
    static let screenRecording = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
}

enum MicrophoneAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable

    var canOpenSystemSettings: Bool {
        self == .denied || self == .restricted
    }
}

protocol MicrophonePermissionProviding: Sendable {
    var authorizationState: MicrophoneAuthorizationState { get }
    func requestAuthorization() async -> MicrophoneAuthorizationState
    func openSystemSettings()
}

struct SystemMicrophonePermission: MicrophonePermissionProviding {
    var authorizationState: MicrophoneAuthorizationState {
        guard AVCaptureDevice.default(for: .audio) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return MicrophoneAuthorizationState.notDetermined
        case .authorized: return MicrophoneAuthorizationState.authorized
        case .denied: return MicrophoneAuthorizationState.denied
        case .restricted: return MicrophoneAuthorizationState.restricted
        @unknown default: return MicrophoneAuthorizationState.restricted
        }
    }

    func requestAuthorization() async -> MicrophoneAuthorizationState {
        guard authorizationState == .notDetermined else { return authorizationState }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : authorizationState
    }

    func openSystemSettings() {
        Task { @MainActor in
            NSWorkspace.shared.open(CapturePermissionSettingsURL.microphone)
        }
    }
}

struct MicrophonePermissionResolver: Sendable {
    let permission: any MicrophonePermissionProviding

    func resolveForUserStart() async -> MicrophoneAuthorizationState {
        let current = permission.authorizationState
        guard current == .notDetermined else { return current }
        return await permission.requestAuthorization()
    }
}

protocol ScreenRecordingPermissionProviding: Sendable {
    var hasAccess: Bool { get }
    func requestAccess() -> Bool
    func openSystemSettings()
}

struct SystemScreenRecordingPermission: ScreenRecordingPermissionProviding {
    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    func requestAccess() -> Bool {
        hasAccess || CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        Task { @MainActor in
            NSWorkspace.shared.open(CapturePermissionSettingsURL.screenRecording)
        }
    }
}

struct ScreenRecordingPermissionResolver: Sendable {
    let permission: any ScreenRecordingPermissionProviding

    var hasAccess: Bool { permission.hasAccess }

    func resolveForUserAction() async -> Bool {
        permission.hasAccess || permission.requestAccess()
    }
}
