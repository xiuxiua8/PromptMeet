import SwiftUI

struct HoverMeetingCardView: View {
    @ObservedObject var store: MeetingStore

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
        HStack(spacing: 0) {
            transcriptPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, 22)

            Rectangle()
                .fill(VisualTokens.line)
                .frame(width: 1)
                .padding(.vertical, 2)

            pulsePane
                .frame(width: 286)
                .frame(maxHeight: .infinity)
                .padding(.leading, 22)
        }
        .padding(.horizontal, 20)
        .padding(.top, max(IslandGeometry.controlHitSize, store.topChromeHeight) + 8)
        .padding(.bottom, 14)
        .foregroundStyle(VisualTokens.primaryText)
    }
}

extension HoverMeetingCardView {
    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("实时转写")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(VisualTokens.live)
                if let timestamp = store.state.transcript.last?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.tertiaryText)
                }
                Spacer()
                Text(screenshotTargetLabel)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)
                    .lineLimit(1)
            }

            if transcriptFlow.isEmpty {
                Text(controlPresentation.transcriptPlaceholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                RollingCaptionView(
                    text: transcriptFlow,
                    font: .system(size: 12, weight: .regular),
                    viewportHeight: 92,
                    topPadding: 0
                )
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
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
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开麦克风隐私设置")
                .accessibilityLabel("打开麦克风隐私设置")
            }
            if capturePresentation.showsMicrophoneRetryAction {
                Button(action: store.retryMicrophone) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("重试麦克风")
                .accessibilityLabel("重试麦克风采集")
            }
            Spacer(minLength: 0)
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
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
            spacing: 6
        ) {
            actionControl(
                controlPresentation.startTitle,
                icon: controlPresentation.startIcon,
                color: VisualTokens.live,
                disabled: !controlPresentation.canStart,
                perform: store.startMeeting
            )
            actionControl(
                controlPresentation.pauseResumeTitle,
                icon: controlPresentation.pauseResumeIcon,
                color: VisualTokens.amber,
                disabled: !controlPresentation.canPauseResume,
                perform: store.togglePauseResume
            )
            actionControl(
                "结束",
                icon: "stop.fill",
                color: VisualTokens.danger,
                disabled: !controlPresentation.canStop,
                perform: store.endMeeting
            )
            actionControl(
                "选择窗口",
                icon: "rectangle.on.rectangle",
                disabled: store.state.screenshotOperation == .selecting,
                perform: store.selectCaptureTarget
            )
            actionControl(
                "截图",
                icon: "viewfinder",
                disabled: !store.hasMeetingContext
                    || store.state.screenshotOperation == .selecting
                    || store.state.screenshotOperation == .capturing,
                perform: store.requestScreenshot
            )
            actionControl(
                "生成摘要",
                icon: "text.alignleft",
                disabled: !store.hasMeetingContext,
                perform: store.requestSummary
            )
        }
    }

    private func actionControl(
        _ title: String,
        icon: String,
        color: Color = VisualTokens.secondaryText,
        disabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .help(title)
        .accessibilityLabel(title)
    }

    private var screenshotTargetLabel: String {
        switch store.state.screenshotTarget {
        case .none: "未选择窗口"
        case .selected(let label): label
        case .invalid(let label, let reason): "\(label) · 已失效（\(reason)）"
        }
    }
}

extension HoverMeetingCardView {
    private var pulsePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text("AI 快速提问")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                if store.hasMeetingContext {
                    Button(action: store.requestQuestions) {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(VisualTokens.tertiaryText)
                            .frame(height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("刷新建议问题")
                    .accessibilityLabel("刷新建议问题")
                }
            }
            .foregroundStyle(VisualTokens.sky)
            .padding(.bottom, 9)

            Text(insightText)
                .font(.system(size: 11, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(VisualTokens.primaryText.opacity(0.88))
                .lineLimit(3)
                .padding(.bottom, 8)

            suggestions

            Spacer(minLength: 6)

            QuickAskField(store: store, appearance: .aura)
                .accessibilityLabel("AI 提问输入框")
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if store.state.suggestionRefresh.phase == .loading {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(VisualTokens.sky)
                Text("正在更新问题")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(VisualTokens.secondaryText)
            .padding(.vertical, 7)
        } else if case .failed(let message) = store.state.suggestionRefresh.phase {
            Button(action: store.requestQuestions) {
                Label("更新失败，点此重试", systemImage: "arrow.clockwise")
                    .help(message)
            }
            .buttonStyle(.plain)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(VisualTokens.amber)
            .padding(.vertical, 7)
        } else if store.state.displayedGeneratedQuestions.isEmpty {
            Text(store.hasMeetingContext ? "转写积累后会出现建议问题。" : "开始会议后生成建议问题。")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)
                .padding(.vertical, 7)
        } else {
            ForEach(store.state.displayedGeneratedQuestions.prefix(2), id: \.self) { question in
                suggestionButton(question)
            }
        }
    }

    private func suggestionButton(_ question: String) -> some View {
        Button {
            store.useSuggestedQuestion(question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(VisualTokens.sky)
                Text(question)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(VisualTokens.line)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("建议问题，\(question)")
    }

    private var insightText: String {
        if let insight = store.state.latestInsight?.trimmingCharacters(in: .whitespacesAndNewlines),
           !insight.isEmpty {
            return insight
        }
        return store.hasMeetingContext
            ? "我会持续提炼会议中的关键变化。"
            : "开始会议后，我会在这里保持一条最重要的提示。"
    }
}
