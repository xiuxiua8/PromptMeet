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

struct HoverMeetingCardView: View {
    @ObservedObject var store: MeetingStore
    let openWorkspace: () -> Void

    private var transcriptFlow: String {
        TranscriptFlowFormatter.text(
            lines: store.state.transcript,
            activeText: store.state.activeTranscript
        )
    }

    private var controlPresentation: MeetingControlPresentation {
        MeetingControlPresentation(
            phase: store.state.phase,
            recordingActivity: store.state.recordingActivity
        )
    }

    private var capturePresentation: CaptureStatusPresentation {
        CaptureStatusPresentation(snapshot: store.state.audioCapture)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: max(44, store.topChromeHeight + 10))

            HStack(spacing: 0) {
                transcriptPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 24)

                Rectangle()
                    .fill(VisualTokens.line)
                    .frame(width: 1)
                    .padding(.vertical, 4)

                pulsePane
                    .frame(width: 286)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .foregroundStyle(VisualTokens.primaryText)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.55), radius: 7)
                if let timestamp = store.state.transcript.last?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: max(190, store.topChromeWidth))

            Button(action: openWorkspace) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开工作台")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 22)
    }

    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if transcriptFlow.isEmpty {
                Text(controlPresentation.transcriptPlaceholder)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                RollingCaptionView(
                    text: transcriptFlow,
                    font: .system(size: 13, weight: .regular, design: .rounded),
                    viewportHeight: 164,
                    topPadding: 0
                )
                .lineSpacing(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            captureStatusRow
            controls
        }
    }

    private var captureStatusRow: some View {
        HStack(spacing: 6) {
            sourceBadge(capturePresentation.microphone)
            sourceBadge(capturePresentation.system)

            if capturePresentation.showsMicrophoneSettingsAction {
                Button(action: store.openMicrophoneSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("打开麦克风隐私设置")
                .accessibilityLabel("打开麦克风隐私设置")
            }
            if capturePresentation.showsMicrophoneRetryAction {
                Button(action: store.retryMicrophone) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("重试麦克风")
                .accessibilityLabel("重试麦克风采集")
            }
            Spacer(minLength: 0)
            Text(screenshotTargetLabel)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.tertiaryText)
                .lineLimit(1)
        }
        .foregroundStyle(VisualTokens.secondaryText)
    }

    private func sourceBadge(_ source: CaptureStatusPresentation.Source) -> some View {
        Label(source.label, systemImage: source.icon)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(source.isActive ? VisualTokens.live : VisualTokens.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(VisualTokens.raised.opacity(0.72))
            .clipShape(Capsule())
            .accessibilityLabel(source.label)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: store.startMeeting) {
                Label(
                    controlPresentation.startTitle,
                    systemImage: controlPresentation.startIcon
                )
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.live)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!controlPresentation.canStart)

            iconControl(
                controlPresentation.pauseResumeTitle,
                icon: controlPresentation.pauseResumeIcon,
                color: VisualTokens.amber,
                disabled: !controlPresentation.canPauseResume,
                perform: store.togglePauseResume
            )
            iconControl(
                "结束",
                icon: "stop.fill",
                color: VisualTokens.danger,
                disabled: !controlPresentation.canStop,
                perform: store.endMeeting
            )
            iconControl(
                "选择窗口",
                icon: "rectangle.on.rectangle",
                disabled: store.state.screenshotOperation == .selecting,
                perform: store.selectCaptureTarget
            )
            iconControl(
                "截图",
                icon: "viewfinder",
                disabled: !store.hasMeetingContext
                    || store.state.screenshotOperation == .selecting
                    || store.state.screenshotOperation == .capturing,
                perform: store.requestScreenshot
            )
            iconControl(
                "摘要",
                icon: "text.alignleft",
                disabled: !store.hasMeetingContext,
                perform: store.requestSummary
            )
        }
        .frame(height: 34)
    }

    private var screenshotTargetLabel: String {
        switch store.state.screenshotTarget {
        case .none: "未选择窗口"
        case .selected(let label): label
        case .invalid(let label, _): "\(label) · 已失效"
        }
    }

    private var pulsePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("AI")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer()
                if store.hasMeetingContext {
                    Button(action: store.requestQuestions) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(VisualTokens.tertiaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("刷新问题")
                }
            }
            .foregroundStyle(VisualTokens.sky)
            .padding(.bottom, 10)

            Text(insightText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineSpacing(3)
                .foregroundStyle(VisualTokens.primaryText.opacity(0.90))
                .lineLimit(3)
                .padding(.bottom, 10)

            if store.state.suggestionRefresh.phase == .loading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini).tint(VisualTokens.sky)
                    Text("正在更新问题")
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)
                .padding(.vertical, 8)
            } else if case .failed(let message) = store.state.suggestionRefresh.phase {
                Button(action: store.requestQuestions) {
                    Label("更新失败，点此重试", systemImage: "arrow.clockwise")
                        .help(message)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.amber)
                .padding(.vertical, 8)
            } else if store.state.displayedGeneratedQuestions.isEmpty {
                Text(store.hasMeetingContext ? "转写积累后会自动出现值得追问的问题。" : "开始会议后生成值得追问的问题。")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.state.displayedGeneratedQuestions.prefix(2), id: \.self) { question in
                    suggestionButton(question)
                }
            }

            Spacer(minLength: 8)

            QuickAskField(store: store, appearance: .aura)
        }
    }

    private func suggestionButton(_ question: String) -> some View {
        Button {
            store.useSuggestedQuestion(question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VisualTokens.sky)
                Text(question)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(VisualTokens.line)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func iconControl(
        _ title: String,
        icon: String,
        color: Color = VisualTokens.secondaryText,
        disabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }

    private var insightText: String {
        if let insight = store.state.latestInsight?.trimmingCharacters(in: .whitespacesAndNewlines),
            !insight.isEmpty
        {
            return insight
        }
        return store.hasMeetingContext
            ? "我会持续提炼会议中的关键变化。"
            : "开始会议后，我会在这里保持一条最重要的提示。"
    }

    private var statusColor: Color {
        switch store.state.phase {
        case .live: VisualTokens.live
        case .failed: VisualTokens.danger
        case .connecting, .stopping: VisualTokens.amber
        case .idle: VisualTokens.tertiaryText
        }
    }
}
