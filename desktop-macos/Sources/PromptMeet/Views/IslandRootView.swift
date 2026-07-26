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
                IslandShape()
                    .fill(
                        LinearGradient(
                            colors: [VisualTokens.islandSoft, VisualTokens.island, VisualTokens.island],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .clipShape(IslandShape())
            .overlay {
                IslandShape()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                auraLeadingColor,
                                Color.white.opacity(isExpanded ? 0.10 : 0.035),
                                auraTrailingColor
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: isExpanded ? 0.7 : 0.5
                    )
                    .mask(Rectangle().padding(.top, 1))
            }
            .shadow(color: auraLeadingColor.opacity(auraOpacity), radius: isExpanded ? 24 : 18, y: 10)
            .shadow(color: auraTrailingColor.opacity(auraOpacity), radius: isExpanded ? 28 : 20, y: 12)
            .contentShape(IslandShape())
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.presentation)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactIsland: some View {
        switch store.state.phase {
        case .idle:
            notchFlanks {
                statusOrb(color: VisualTokens.tertiaryText)
            } trailing: {
                quickAskButton
            }
        case .connecting, .stopping:
            notchFlanks {
                ProgressView()
                    .controlSize(.mini)
                    .tint(VisualTokens.amber)
            } trailing: {
                quickAskButton
            }
        case let .failed(message):
            notchFlanks {
                statusOrb(color: VisualTokens.danger)
                    .help(message)
            } trailing: {
                quickAskButton
            }
        case .live:
            VStack(spacing: 0) {
                notchFlanks {
                    waveform
                } trailing: {
                    if store.state.aiReader.isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(VisualTokens.sky)
                    }
                    quickAskButton
                }
                .frame(height: store.topChromeHeight)

                LinearGradient(
                    colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 22)

                RollingCaptionView(
                    text: store.state.activeCaption.isEmpty ? "正在等待第一段转写" : store.state.activeCaption,
                    viewportHeight: 39,
                    topPadding: 4
                )
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func notchFlanks<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                leading()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: store.topChromeWidth)

            HStack(spacing: 6) {
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16 + IslandShape.topCurl)
    }

    private func statusOrb(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color.opacity(0.45), radius: 6)
    }

    private var quickAskButton: some View {
        Button(action: store.toggleQuickAsk) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualTokens.sky)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("问 AI")
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach([5, 11, 7, 13, 6], id: \.self) { height in
                Capsule()
                    .fill(VisualTokens.live)
                    .frame(width: 1.5, height: CGFloat(height))
            }
        }
        .frame(width: 20)
        .shadow(color: VisualTokens.live.opacity(0.36), radius: 7)
    }

    private var auraOpacity: Double {
        switch store.state.phase {
        case .live:
            0.34
        case .connecting, .stopping:
            0.18
        case .failed:
            0.20
        case .idle:
            store.isHovered || store.state.isQuickAskPresented ? 0.18 : 0
        }
    }

    private var auraLeadingColor: Color {
        switch store.state.phase {
        case .live:
            VisualTokens.live
        case .failed:
            VisualTokens.danger
        case .connecting, .stopping:
            VisualTokens.amber
        case .idle:
            VisualTokens.sky
        }
    }

    private var auraTrailingColor: Color {
        store.isHovered || store.state.aiReader.isStreaming || store.state.isQuickAskPresented
            ? VisualTokens.sky
            : auraLeadingColor
    }
}
