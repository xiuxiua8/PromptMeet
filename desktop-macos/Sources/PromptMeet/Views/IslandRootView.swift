import SwiftUI

struct IslandRootView: View {
    @ObservedObject var store: MeetingStore
    let openWorkspace: () -> Void

    var body: some View {
        let isExpanded = store.isHovered || store.state.isQuickAskPresented
        let size = IslandGeometry.size(
            for: store.presentation,
            topChromeWidth: store.topChromeWidth,
            topChromeHeight: store.topChromeHeight
        )

        VStack(spacing: 0) {
            Group {
                if isExpanded {
                    HoverMeetingCardView(store: store, openWorkspace: openWorkspace)
                } else {
                    compactIsland
                }
            }
            .frame(width: size.width, height: size.height)
            .background {
                IslandShape().fill(VisualTokens.island)
            }
            .clipShape(IslandShape())
            .overlay {
                IslandShape()
                    .stroke(
                        VisualTokens.cobalt.opacity(
                            isExpanded ? 0.38 : 0.06
                        ),
                        lineWidth: 1
                    )
            }
            .contentShape(IslandShape())
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: store.presentation)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactIsland: some View {
        switch store.state.phase {
        case .idle:
            HStack(spacing: 8) {
                Circle().fill(Color.white.opacity(0.24)).frame(width: 5, height: 5)
                Text("PromptMeet")
                    .font(.system(size: 12, weight: .semibold))
                Text("待机")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(VisualTokens.secondaryText)
                Spacer(minLength: 4)
                quickAskButton
            }
            .padding(.horizontal, 14)
        case .connecting, .stopping:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(VisualTokens.live)
                Text(store.state.phase == .connecting ? "正在连接音频与转写" : "正在结束会议")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                quickAskButton
            }
            .padding(.horizontal, 14)
        case let .failed(message):
            HStack(spacing: 8) {
                Circle().fill(VisualTokens.danger).frame(width: 6, height: 6)
                Text(message).lineLimit(1)
                Spacer(minLength: 4)
                quickAskButton
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 14)
        case .live:
            HStack(spacing: 10) {
                waveform
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.state.transcript.last?.speaker ?? "实时转写")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(VisualTokens.live)
                    RollingCaptionView(
                        text: store.state.activeCaption.isEmpty ? "会议进行中" : store.state.activeCaption
                    )
                    .offset(y: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 4)
                if store.state.aiReader.isStreaming {
                    HStack(spacing: 4) {
                        Circle().fill(VisualTokens.sky).frame(width: 5, height: 5)
                        Text("AI")
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualTokens.sky)
                }
                quickAskButton
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(VisualTokens.live)
            }
            .padding(.horizontal, 14)
        }
    }

    private var quickAskButton: some View {
        Button(action: store.toggleQuickAsk) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualTokens.sky)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("问 AI")
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([7, 13, 9, 17, 11], id: \.self) { height in
                Capsule()
                    .fill(VisualTokens.live)
                    .frame(width: 2, height: CGFloat(height))
            }
        }
        .frame(width: 20)
    }
}
