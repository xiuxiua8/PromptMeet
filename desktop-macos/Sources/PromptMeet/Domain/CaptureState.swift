import Foundation

enum AudioSourceState: Equatable, Sendable {
    case idle
    case starting
    case requestingPermission
    case active
    case paused
    case denied
    case restricted
    case unavailable(String)
    case failed(String)

    var isActive: Bool { self == .active }
}

struct AudioCaptureSnapshot: Equatable, Sendable {
    var microphone: AudioSourceState = .idle
    var system: AudioSourceState = .idle

    subscript(source: NativeAudioSource) -> AudioSourceState {
        get {
            switch source {
            case .microphone: microphone
            case .system, .mixed: system
            }
        }
        set {
            switch source {
            case .microphone: microphone = newValue
            case .system, .mixed: system = newValue
            }
        }
    }

    var hasActiveSource: Bool { microphone.isActive || system.isActive }
}

enum RecordingActivity: Equatable, Sendable {
    case inactive
    case starting
    case recording
    case pausing
    case paused
    case resuming
    case stopping
}

enum ScreenshotTargetState: Equatable, Sendable {
    case none
    case selected(label: String)
    case invalid(label: String, reason: String)

    var label: String? {
        switch self {
        case .none: nil
        case .selected(let label), .invalid(let label, _): label
        }
    }
}

enum ScreenshotOperationState: Equatable, Sendable {
    case idle
    case selecting
    case capturing
    case succeeded
    case analyzed(status: String, detail: String)
    case failed(String)
}

enum SuggestionRefreshPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

struct SuggestionRefreshState: Equatable, Sendable {
    var phase: SuggestionRefreshPhase = .idle
    var generationID: UUID?
    var contextRevision = 0
}

enum SummaryAutomationState: Equatable, Sendable {
    case idle
    case off
    case waiting(nextActiveMinute: Int)
    case generating(activeMinute: Int?)
    case completed(revision: Int, activeMinute: Int?)
    case noAction(activeMinute: Int, message: String)
    case failed(String)
}

extension Duration {
    var millisecondsValue: Int64 {
        let parts = components
        let seconds = parts.seconds.multipliedReportingOverflow(by: 1_000)
        if seconds.overflow { return parts.seconds >= 0 ? Int64.max : Int64.min }
        return seconds.partialValue + Int64(parts.attoseconds / 1_000_000_000_000_000)
    }
}
