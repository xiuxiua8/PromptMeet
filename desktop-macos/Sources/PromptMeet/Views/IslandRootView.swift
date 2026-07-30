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
            ZStack(alignment: .top) {
                if isExpanded {
                    HoverMeetingCardView(store: store)
                } else {
                    compactContent
                }

                permanentControlRail
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
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: store.presentation)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var effectiveTopChromeHeight: CGFloat {
        max(IslandGeometry.controlHitSize, store.topChromeHeight)
    }

    @ViewBuilder
    private var compactContent: some View {
        if store.state.phase == .live {
            VStack(spacing: 0) {
                Color.clear.frame(height: effectiveTopChromeHeight)

                LinearGradient(
                    colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 22)

                RollingCaptionView(
                    text: compactCaption,
                    font: .system(size: 12, weight: .medium),
                    viewportHeight: 24,
                    topPadding: 4
                )
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var permanentControlRail: some View {
        HStack(spacing: IslandGeometry.controlSpacing) {
            workspaceButton

            Spacer(minLength: 0)

            pauseResumeSlot
                .frame(
                    width: IslandGeometry.controlHitSize,
                    height: IslandGeometry.controlHitSize
                )

            quickAskButton
        }
        .padding(.horizontal, IslandGeometry.controlInset)
        .frame(
            width: IslandGeometry.controlRailWidth,
            height: effectiveTopChromeHeight
        )
    }

    private var workspaceButton: some View {
        let presentation = IslandControlPresentation.workspace
        return Button(action: openWorkspace) {
            workspaceStatusSymbol
                .frame(
                    width: IslandGeometry.controlHitSize,
                    height: IslandGeometry.controlHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)
        .keyboardShortcut(
            KeyEquivalent(presentation.shortcut.key),
            modifiers: presentation.shortcut.modifiers
        )
    }

    @ViewBuilder
    private var workspaceStatusSymbol: some View {
        switch store.state.phase {
        case .idle:
            statusOrb(color: VisualTokens.tertiaryText)
        case .connecting, .stopping:
            ProgressView()
                .controlSize(.mini)
                .tint(VisualTokens.amber)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(VisualTokens.danger)
        case .live:
            if store.state.recordingActivity == .paused {
                statusOrb(color: VisualTokens.amber)
            } else {
                waveform
            }
        }
    }

    @ViewBuilder
    private var pauseResumeSlot: some View {
        switch store.state.recordingActivity {
        case .pausing, .resuming:
            ProgressView()
                .controlSize(.mini)
                .tint(VisualTokens.amber)
                .accessibilityLabel("正在切换录音状态")
        case .recording, .paused:
            let control = IslandControlPresentation.pauseResume(
                recordingActivity: store.state.recordingActivity
            )
            let isPaused = store.state.recordingActivity == .paused
            Button(action: store.togglePauseResume) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isPaused ? VisualTokens.live : VisualTokens.amber)
                    .frame(
                        width: IslandGeometry.controlHitSize,
                        height: IslandGeometry.controlHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(control.help)
            .accessibilityLabel(control.accessibilityLabel)
            .keyboardShortcut(
                KeyEquivalent(control.shortcut.key),
                modifiers: control.shortcut.modifiers
            )
        default:
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private var quickAskButton: some View {
        let presentation = IslandControlPresentation.quickAsk
        return Button(action: store.toggleQuickAsk) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualTokens.sky)
                .frame(
                    width: IslandGeometry.controlHitSize,
                    height: IslandGeometry.controlHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)
        .keyboardShortcut(
            KeyEquivalent(presentation.shortcut.key),
            modifiers: presentation.shortcut.modifiers
        )
    }

    private func statusOrb(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.45), radius: 6)
    }

    private var compactCaption: String {
        if store.state.recordingActivity == .paused {
            return "录音已暂停，会议内容和问答仍保留"
        }
        return store.state.activeCaption.isEmpty ? "正在等待第一段转写" : store.state.activeCaption
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
            store.state.recordingActivity == .paused ? VisualTokens.amber : VisualTokens.live
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
