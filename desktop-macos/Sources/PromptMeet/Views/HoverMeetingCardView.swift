import SwiftUI

struct MeetingControlPresentation: Equatable {
    let startTitle: String
    let startIcon: String
    let transcriptPlaceholder: String
    let canStart: Bool
    let canStop: Bool

    init(phase: MeetingPhase) {
        switch phase {
        case .idle:
            startTitle = "开始录音"
            startIcon = "mic.fill"
            transcriptPlaceholder = "开始录音后，转写会在这里连续流动。"
            canStart = true
            canStop = false
        case .connecting:
            startTitle = "正在连接"
            startIcon = "waveform"
            transcriptPlaceholder = "正在准备本地转写"
            canStart = false
            canStop = true
        case .live:
            startTitle = "录音中"
            startIcon = "waveform"
            transcriptPlaceholder = "正在等待第一段转写"
            canStart = false
            canStop = true
        case .stopping:
            startTitle = "正在结束"
            startIcon = "waveform"
            transcriptPlaceholder = "正在保存会议内容"
            canStart = false
            canStop = false
        case .failed:
            startTitle = "重试录音"
            startIcon = "arrow.clockwise"
            transcriptPlaceholder = "录音未开始，请检查权限或音频来源后重试。"
            canStart = true
            canStop = false
        }
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
        MeetingControlPresentation(phase: store.state.phase)
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

            controls
        }
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
                "结束",
                icon: "stop.fill",
                color: VisualTokens.danger,
                disabled: !controlPresentation.canStop,
                perform: store.endMeeting
            )
            iconControl(
                "截图",
                icon: "viewfinder",
                disabled: !store.hasMeetingContext,
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

            if store.state.generatedQuestions.isEmpty {
                Text(store.hasMeetingContext ? "转写积累后会自动出现值得追问的问题。" : "开始会议后生成值得追问的问题。")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.state.generatedQuestions.prefix(2), id: \.self) { question in
                    suggestionButton(question)
                }
            }

            Spacer(minLength: 8)

            QuickAskField(store: store, appearance: .aura)
        }
    }

    private func suggestionButton(_ question: String) -> some View {
        Button { store.useSuggestedQuestion(question) } label: {
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
           !insight.isEmpty {
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
