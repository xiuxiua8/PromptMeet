import AppKit
import SwiftUI

extension WorkspaceView {
    var workspaceStatus: String {
        if isViewingHistory {
            return "可回顾并继续提问"
        }
        switch store.state.phase {
        case .live:
            switch store.state.recordingActivity {
            case .paused: return "录音已暂停，会议上下文仍保留"
            case .pausing: return "正在暂停录音"
            case .resuming: return "正在继续录音"
            default: return "实时转写中"
            }
        case .connecting:
            return "正在准备音频来源"
        case .stopping:
            return "正在保存会议"
        case .failed:
            return "录音未启动，请检查音频来源"
        case .idle:
            return store.hasMeetingContext ? "可继续整理" : "尚未开始"
        }
    }

    var workspaceStatusTint: Color {
        if isViewingHistory { return VisualTokens.secondaryText }
        switch store.state.phase {
        case .live:
            return store.state.recordingActivity == .paused ? VisualTokens.amber : VisualTokens.live
        case .connecting, .stopping:
            return VisualTokens.amber
        case .failed:
            return VisualTokens.danger
        case .idle:
            return VisualTokens.tertiaryText
        }
    }

    func meetingStatus(_ status: StoredMeetingStatus) -> String {
        switch status {
        case .active: "进行中"
        case .completed: "已完成"
        case .incomplete: "未完整结束"
        case .recoveryRequired: "需要恢复"
        }
    }

    var hairline: some View {
        LinearGradient(
            colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    var workspaceBackground: some View {
        ZStack {
            VisualTokens.island
            RadialGradient(
                colors: [VisualTokens.sky.opacity(0.055), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [VisualTokens.live.opacity(0.035), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 460
            )
        }
    }}
