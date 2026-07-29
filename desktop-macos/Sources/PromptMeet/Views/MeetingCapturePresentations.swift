import SwiftUI

struct MeetingControlPresentation: Equatable {
    let startTitle: String
    let startIcon: String
    let transcriptPlaceholder: String
    let canStart: Bool
    let canStop: Bool
    let pauseResumeTitle: String
    let pauseResumeIcon: String
    let canPauseResume: Bool

    init(phase: MeetingPhase, recordingActivity: RecordingActivity = .inactive) {
        pauseResumeTitle = recordingActivity == .paused ? "继续录音" : "暂停录音"
        pauseResumeIcon = recordingActivity == .paused ? "play.fill" : "pause.fill"
        switch phase {
        case .idle:
            startTitle = "开始录音"
            startIcon = "mic.fill"
            transcriptPlaceholder = "开始录音后，转写会在这里连续流动。"
            canStart = true
            canStop = false
            canPauseResume = false
        case .connecting:
            startTitle = "正在连接"
            startIcon = "waveform"
            transcriptPlaceholder = "正在准备本地转写"
            canStart = false
            canStop = true
            canPauseResume = false
        case .live:
            startTitle = "录音中"
            startIcon = "waveform"
            transcriptPlaceholder = "正在等待第一段转写"
            canStart = false
            canStop = true
            canPauseResume = recordingActivity == .recording || recordingActivity == .paused
        case .stopping:
            startTitle = "正在结束"
            startIcon = "waveform"
            transcriptPlaceholder = "正在保存会议内容"
            canStart = false
            canStop = false
            canPauseResume = false
        case .failed:
            startTitle = "重试录音"
            startIcon = "arrow.clockwise"
            transcriptPlaceholder = "录音未开始，请检查权限或音频来源后重试。"
            canStart = true
            canStop = false
            canPauseResume = false
        }
    }
}

struct CaptureStatusPresentation: Equatable {
    struct Source: Equatable {
        let label: String
        let icon: String
        let isActive: Bool
    }

    let microphone: Source
    let system: Source
    let showsMicrophoneSettingsAction: Bool
    let showsMicrophoneRetryAction: Bool

    init(snapshot: AudioCaptureSnapshot) {
        microphone = Self.sourcePresentation(
            prefix: "我",
            icon: "mic",
            state: snapshot.microphone
        )
        system = Self.sourcePresentation(
            prefix: "会议",
            icon: "waveform",
            state: snapshot.system
        )
        showsMicrophoneSettingsAction =
            snapshot.microphone == .denied
            || snapshot.microphone == .restricted
        switch snapshot.microphone {
        case .denied, .restricted, .unavailable, .failed:
            showsMicrophoneRetryAction = true
        default:
            showsMicrophoneRetryAction = false
        }
    }

    private static func sourcePresentation(
        prefix: String,
        icon: String,
        state: AudioSourceState
    ) -> Source {
        let status: String
        switch state {
        case .idle: status = "未启动"
        case .starting, .requestingPermission: status = "正在准备"
        case .active: status = "采集中"
        case .paused: status = "已暂停"
        case .denied: status = prefix == "我" ? "需要麦克风权限" : "需要屏幕录制权限"
        case .restricted: status = "受系统限制"
        case .unavailable: status = "不可用"
        case .failed: status = "采集失败"
        }
        return Source(label: "\(prefix) · \(status)", icon: icon, isActive: state == .active)
    }
}
