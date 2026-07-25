import SwiftUI

struct HoverMeetingCardView: View {
    @ObservedObject var store: MeetingStore
    let openWorkspace: () -> Void

    private var transcriptFlow: String {
        TranscriptFlowFormatter.text(
            lines: store.state.transcript,
            activeText: store.state.activeTranscript
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 30)
            hairline
            HStack(spacing: 0) {
                leftColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(VisualTokens.line)
                    .frame(width: 1)
                    .padding(.vertical, 10)

                questionPanel
                    .frame(width: 286)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 160)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .foregroundStyle(VisualTokens.primaryText)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 6, height: 6)
            Text("PromptMeet")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(statusLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
            Spacer()
            Text(sessionLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(VisualTokens.secondaryText)
            Button(action: openWorkspace) {
                Label("工作台", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VisualTokens.sky)
            .padding(.leading, 10)
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            transcriptPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hairline
            controls
                .frame(height: 38)
        }
        .padding(.trailing, 16)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRANSCRIPT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(VisualTokens.secondaryText)
                Spacer()
                if let timestamp = store.state.transcript.last?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
            }

            if transcriptFlow.isEmpty {
                Text(store.state.phase == .idle ? "开始会议后，转写会在这里连续流动。" : "正在等待第一段转写…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Text(transcriptFlow)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .lineSpacing(4)
                    .foregroundStyle(VisualTokens.primaryText.opacity(0.86))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, 10)
    }

    private var controls: some View {
        HStack(spacing: 7) {
            compactControl(
                store.state.phase == .idle ? "录音" : "录音中",
                icon: store.state.phase == .idle ? "mic.fill" : "waveform",
                color: VisualTokens.live,
                disabled: store.state.phase != .idle,
                perform: store.startMeeting
            )
            compactControl(
                "结束",
                icon: "stop.fill",
                color: VisualTokens.danger,
                disabled: store.state.phase == .idle,
                perform: store.endMeeting
            )
            compactControl(
                "截图",
                icon: "viewfinder",
                color: VisualTokens.primaryText,
                disabled: !store.hasMeetingContext,
                perform: store.requestScreenshot
            )
            compactControl(
                "摘要",
                icon: "text.alignleft",
                color: VisualTokens.sky,
                disabled: !store.hasMeetingContext,
                perform: store.requestSummary
            )
        }
        .padding(.vertical, 5)
    }

    private var questionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 9, weight: .semibold))
                Text("猜你想问")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Spacer()
                if store.hasMeetingContext {
                    Button(action: store.requestQuestions) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VisualTokens.secondaryText)
                    .help("刷新问题")
                }
            }
            .foregroundStyle(VisualTokens.sky)

            if store.state.generatedQuestions.isEmpty {
                Text(store.hasMeetingContext ? "转写积累后会自动刷新问题。" : "开始会议后生成值得追问的问题。")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.state.generatedQuestions.prefix(2), id: \.self) { question in
                        Button { store.useSuggestedQuestion(question) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                Text(question)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(VisualTokens.primaryText.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            QuickAskField(store: store)
        }
        .padding(.leading, 16)
        .padding(.vertical, 10)
    }

    private func compactControl(
        _ title: String,
        icon: String,
        color: Color,
        disabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 27)
                .background(VisualTokens.raised.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var hairline: some View {
        LinearGradient(
            colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    private var statusColor: Color {
        switch store.state.phase {
        case .live: VisualTokens.live
        case .failed: VisualTokens.danger
        case .connecting, .stopping: VisualTokens.amber
        case .idle: Color.white.opacity(0.28)
        }
    }

    private var statusLabel: String {
        switch store.state.phase {
        case .live: "LIVE"
        case .failed: "ERROR"
        case .connecting: "CONNECTING"
        case .stopping: "STOPPING"
        case .idle: "READY"
        }
    }

    private var sessionLabel: String {
        store.state.phase == .live ? "LIVE SESSION" : (store.hasMeetingContext ? "MEETING READY" : "READY")
    }
}
