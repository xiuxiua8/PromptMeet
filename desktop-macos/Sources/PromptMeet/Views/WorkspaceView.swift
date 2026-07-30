import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: MeetingStore
    let openSettings: () -> Void

    @State var selectedTab = WorkspaceTab.assistant
    @State var showsHistory = false
    @State var followsTranscript = true
    @State var showsNewMeetingConfirmation = false

    enum WorkspaceTab: String, CaseIterable {
        case assistant = "AI"
        case summary = "摘要"
        case tasks = "待办"
    }

    var isViewingHistory: Bool {
        store.state.selectedArchivedMeetingID != nil
    }

    var capturePresentation: CaptureStatusPresentation {
        CaptureStatusPresentation(snapshot: store.state.audioCapture)
    }

    var meetingControls: MeetingControlPresentation {
        MeetingControlPresentation(
            phase: store.state.phase,
            recordingActivity: store.state.recordingActivity
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            hairline

            HSplitView {
                if showsHistory {
                    historyColumn
                        .frame(minWidth: 190, idealWidth: 210, maxWidth: 230)
                }

                timelineColumn
                    .frame(minWidth: 470, idealWidth: 640, maxWidth: 880)

                intelligenceColumn
                    .frame(minWidth: 390, idealWidth: 620, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(workspaceBackground)
        .foregroundStyle(VisualTokens.primaryText)
        .task { await store.loadMeetingHistoryNow() }
        .confirmationDialog(
            "当前会议仍在进行",
            isPresented: $showsNewMeetingConfirmation,
            titleVisibility: .visible
        ) {
            Button("结束当前会议并开始新会议", role: .destructive) {
                store.replaceActiveMeeting()
            }
            Button("继续当前会议", role: .cancel) {}
        } message: {
            Text("当前会议会先安全结束并保存，然后创建完全隔离的新会议上下文。")
        }
    }
}

extension WorkspaceView {
    var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                toolbarButton(
                    showsHistory ? "隐藏会议历史" : "显示会议历史",
                    icon: "sidebar.left",
                    action: { withAnimation(.easeOut(duration: 0.18)) { showsHistory.toggle() } }
                )

                Circle()
                    .fill(workspaceStatusTint)
                    .frame(width: 6, height: 6)
                    .shadow(color: workspaceStatusTint.opacity(0.55), radius: 7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isViewingHistory ? "历史会议" : "当前会议")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(workspaceStatus)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(workspaceStatusTint)
                }

                Spacer(minLength: 18)

                toolbarButton(
                    "选择窗口",
                    icon: "rectangle.on.rectangle",
                    disabled: isViewingHistory || store.state.screenshotOperation == .selecting,
                    action: store.selectCaptureTarget
                )
                toolbarButton(
                    "截图",
                    icon: "viewfinder",
                    disabled: !store.hasMeetingContext
                        || isViewingHistory
                        || store.state.screenshotOperation == .selecting
                        || store.state.screenshotOperation == .capturing,
                    action: store.requestScreenshot
                )
                toolbarButton(
                    "生成摘要",
                    icon: "text.alignleft",
                    disabled: !store.hasMeetingContext || isViewingHistory,
                    action: store.requestSummary
                )

                if store.state.phase == .live {
                    toolbarButton(
                        meetingControls.pauseResumeTitle,
                        icon: meetingControls.pauseResumeIcon,
                        disabled: !meetingControls.canPauseResume,
                        action: store.togglePauseResume
                    )
                    toolbarButton("结束当前会议", icon: "stop.fill", action: store.endMeeting)
                }

                Button(action: beginNewMeeting) {
                    Label("开始新会议", systemImage: "plus.circle.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.86))
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(VisualTokens.live)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("创建新的隔离会议上下文")

                toolbarButton("设置", icon: "gearshape", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(height: 58)

            if showsCaptureStrip {
                captureStatusStrip
                    .frame(height: 34)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: showsCaptureStrip ? 92 : 62)
    }

    var showsCaptureStrip: Bool {
        !isViewingHistory || store.state.phase == .live
    }

    var captureStatusStrip: some View {
        HStack(spacing: 7) {
            if isViewingHistory {
                Text("当前会议后台采集")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)
            }
            captureSourceBadge(capturePresentation.microphone)
            captureSourceBadge(capturePresentation.system)

            if capturePresentation.showsMicrophoneSettingsAction {
                toolbarButton("打开麦克风隐私设置", icon: "gearshape", action: store.openMicrophoneSettings)
                    .accessibilityLabel("打开麦克风隐私设置")
            }
            if capturePresentation.showsMicrophoneRetryAction {
                toolbarButton("重试麦克风采集", icon: "arrow.clockwise", action: store.retryMicrophone)
                    .accessibilityLabel("重试麦克风采集")
            }

            Rectangle()
                .fill(VisualTokens.line)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)

            Label(screenshotTargetLabel, systemImage: screenshotTargetIcon)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(screenshotStatusTint)
                .lineLimit(1)

            if store.state.screenshotOperation == .selecting
                || store.state.screenshotOperation == .capturing
            {
                ProgressView()
                    .controlSize(.mini)
                    .tint(VisualTokens.sky)
            }

            Text(screenshotOperationLabel)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(screenshotStatusTint)
                .lineLimit(1)
                .help(screenshotOperationLabel)

            if screenshotNeedsSettings {
                Button("打开屏幕录制设置", action: store.openScreenRecordingSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.amber)
            }

            if screenshotNeedsAISettings {
                Button("打开 AI 截图设置", action: openSettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.amber)
            }

            Label(store.summaryAutomationDescription, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(summaryAutomationTint)
                .lineLimit(1)
                .help(store.summaryAutomationDescription)
            if case .failed = store.state.summaryAutomation {
                Button("重试", action: store.requestSummary)
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.amber)
            }

            Spacer(minLength: 0)
        }
    }

    func captureSourceBadge(_ source: CaptureStatusPresentation.Source) -> some View {
        Label(source.label, systemImage: source.icon)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(source.isActive ? VisualTokens.live : VisualTokens.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(VisualTokens.raised.opacity(0.72))
            .clipShape(Capsule())
            .accessibilityLabel(source.label)
    }

    func beginNewMeeting() {
        if store.state.phase == .live || store.state.phase == .connecting {
            showsNewMeetingConfirmation = true
        } else {
            store.startMeeting()
        }
    }

    func toolbarButton(
        _ title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualTokens.secondaryText)
                .frame(width: 30, height: 30)
                .background(VisualTokens.raised.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }

    var screenshotTargetLabel: String {
        switch store.state.screenshotTarget {
        case .none:
            "未选择截图窗口"
        case .selected(let label):
            "截图窗口：\(label)"
        case .invalid(let label, let reason):
            "截图窗口已失效：\(label)（\(reason)）"
        }
    }

    var screenshotTargetIcon: String {
        switch store.state.screenshotTarget {
        case .none: "rectangle.dashed"
        case .selected: "rectangle.on.rectangle"
        case .invalid: "exclamationmark.rectangle"
        }
    }

    var screenshotOperationLabel: String {
        switch store.state.screenshotOperation {
        case .idle: ""
        case .selecting: "正在选择窗口"
        case .capturing: "正在截图并上传"
        case .succeeded: "截图已保存，正在分析"
        case .analyzed(let status, let detail):
            status == "completed" ? "截图分析完成" : detail
        case .failed(let message): message
        }
    }

    var screenshotStatusTint: Color {
        switch store.state.screenshotOperation {
        case .succeeded: VisualTokens.sky
        case .analyzed(let status, _): status == "completed" ? VisualTokens.live : VisualTokens.amber
        case .failed: VisualTokens.amber
        case .selecting, .capturing: VisualTokens.sky
        case .idle: VisualTokens.secondaryText
        }
    }

    var screenshotNeedsSettings: Bool {
        guard case .failed(let message) = store.state.screenshotOperation else { return false }
        return message.contains("屏幕录制权限")
    }

    var screenshotNeedsAISettings: Bool {
        guard case .analyzed(let status, let detail) = store.state.screenshotOperation else {
            return false
        }
        return status == "unsupported" || detail.contains("截图分析工作流配置问题")
    }

    var summaryAutomationTint: Color {
        switch store.state.summaryAutomation {
        case .failed: VisualTokens.danger
        case .generating: VisualTokens.sky
        case .completed: VisualTokens.live
        case .noAction: VisualTokens.amber
        case .idle, .off, .waiting: VisualTokens.tertiaryText
        }
    }

}
