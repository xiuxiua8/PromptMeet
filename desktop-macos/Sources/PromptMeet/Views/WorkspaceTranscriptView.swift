import AppKit
import SwiftUI

extension WorkspaceView {
    var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("会议记录")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("\(store.state.displayedTranscript.count)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)

                Spacer()

                Button {
                    followsTranscript.toggle()
                } label: {
                    Image(systemName: followsTranscript ? "arrow.down.to.line" : "pause")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(followsTranscript ? VisualTokens.live : VisualTokens.secondaryText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(followsTranscript ? "自动跟随转写" : "恢复自动跟随")
            }
            .padding(.horizontal, 20)
            .frame(height: 50)

            hairline

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.state.displayedTranscript.isEmpty {
                            emptyState(
                                icon: "waveform",
                                text: isViewingHistory ? "这次会议没有保存转写" : "开始录音后，转写会在这里连续出现"
                            )
                            .frame(minHeight: 360)
                        } else {
                            let enumerated = Array(store.state.displayedTranscript.enumerated())
                            ForEach(enumerated, id: \.element.id) { index, line in
                                transcriptRow(
                                    line,
                                    isLast: index == store.state.displayedTranscript.count - 1
                                        && store.state.activeTranscript.isEmpty
                                )
                                .id(line.id)
                            }
                        }

                        if !isViewingHistory && !store.state.activeTranscript.isEmpty {
                            activeTranscriptRow
                                .id("active-transcript")
                        }

                        Color.clear
                            .frame(height: 32)
                            .id("transcript-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.state.displayedTranscript.count) { _, _ in
                    guard followsTranscript else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: store.state.activeTranscript) { _, _ in
                    guard followsTranscript else { return }
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    func transcriptRow(_ line: TranscriptLine, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                Text(line.timestamp, style: .time)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)

                Circle()
                    .fill(VisualTokens.live.opacity(0.72))
                    .frame(width: 5, height: 5)

                if !isLast {
                    Rectangle()
                        .fill(VisualTokens.line)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 46)

            VStack(alignment: .leading, spacing: 7) {
                Text(transcriptSpeakerLabel(line))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(transcriptTint(line))

                Text(line.text)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let translation = line.translatedText {
                    Text(translation)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
        }
    }

    func transcriptSpeakerLabel(_ line: TranscriptLine) -> String {
        switch line.source {
        case .microphone: "我"
        case .system: "会议"
        case .mixed, .none: line.speaker
        }
    }

    func transcriptTint(_ line: TranscriptLine) -> Color {
        line.source == .microphone ? VisualTokens.sky : VisualTokens.live
    }

    var activeTranscriptRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                Text("现在")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.live)
                Circle()
                    .fill(VisualTokens.live)
                    .frame(width: 6, height: 6)
                    .shadow(color: VisualTokens.live.opacity(0.55), radius: 6)
            }
            .frame(width: 46)

            Text(store.state.activeTranscript)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.primaryText.opacity(0.80))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 22)
        }
    }

}
