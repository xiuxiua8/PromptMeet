import SwiftUI

extension WorkspaceView {
    func legacyTranscriptStream(_ blocks: [WorkspaceTranscriptBlock]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                transcriptBlockRow(block, timestamp: block.segments.first?.timestamp ?? Date())
            }
        }
    }

    func transcriptBlockRow(
        _ block: WorkspaceTranscriptBlock,
        timestamp: Date
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timestamp, style: .time)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.tertiaryText)
                .frame(width: 46, alignment: .leading)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(transcriptTint(source: block.source))
                .frame(width: 3)
                .padding(.vertical, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(transcriptSpeakerLabel(block))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(transcriptTint(source: block.source))
                    Text(transcriptSourceLabel(block.source))
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.tertiaryText)
                    if block.segments.count > 1 {
                        Text("\(block.segments.count) 段")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(VisualTokens.tertiaryText)
                    }
                }

                Text(block.text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(VisualTokens.primaryText.opacity(0.90))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let translation = block.translatedText {
                    Text(translation)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VisualTokens.sky.opacity(0.90))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "\(transcriptSpeakerLabel(block))，\(transcriptSourceLabel(block.source))，\(block.text)"
            )
        }
        .padding(.vertical, 10)
    }

    var activeTranscriptStreamRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("现在")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.live)
                .frame(width: 46, alignment: .leading)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(VisualTokens.live)
                .frame(width: 3)
                .shadow(color: VisualTokens.live.opacity(0.45), radius: 5)
                .padding(.vertical, 3)

            Text(store.state.activeTranscript)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VisualTokens.primaryText.opacity(0.78))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在转写，\(store.state.activeTranscript)")
    }

    func transcriptSpeakerLabel(_ block: WorkspaceTranscriptBlock) -> String {
        block.displaySpeaker
    }

    func transcriptSourceLabel(_ source: String?) -> String {
        switch source {
        case NativeAudioSource.microphone.rawValue: "本机麦克风"
        case NativeAudioSource.system.rawValue: "系统音频"
        case NativeAudioSource.mixed.rawValue: "混合音频"
        default: "来源未标记"
        }
    }

    func transcriptTint(source: String?) -> Color {
        source == NativeAudioSource.microphone.rawValue ? VisualTokens.sky : VisualTokens.live
    }
}
