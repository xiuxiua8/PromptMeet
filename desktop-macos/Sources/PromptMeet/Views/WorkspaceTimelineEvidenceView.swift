import AppKit
import SwiftUI

extension WorkspaceView {
    @ViewBuilder
    func timelineItemBody(_ item: WorkspaceTimelineItem) -> some View {
        if item.kind == .screenshot {
            Text(item.body)
                .font(.system(size: 11))
                .foregroundStyle(VisualTokens.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownTextView(markdown: item.body, baseFontSize: 11)
                .foregroundStyle(VisualTokens.primaryText.opacity(item.isFailure ? 0.66 : 0.88))
        }
    }

    @ViewBuilder
    func screenshotPreview(_ screenshot: ScreenshotAsset) -> some View {
        if let url = screenshot.availableFileURL(), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 220)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("会议截图")
        } else {
            HStack(spacing: 9) {
                Image(systemName: "photo.badge.exclamationmark")
                Text("截图文件不可用，时间线和分析记录仍已保留")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(VisualTokens.amber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VisualTokens.amber.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    func sourceChips(_ sources: [EvidenceSource]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Text("[\(source.sourceID)] \(source.label)")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(VisualTokens.sky.opacity(0.09))
                        .clipShape(Capsule())
                        .help(source.label)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("回答来源")
    }

    func timelineIcon(_ kind: WorkspaceTimelineItemKind) -> String {
        switch kind {
        case .lifecycle: "circle.dotted"
        case .transcript: "waveform"
        case .screenshot: "photo"
        case .screenshotAnalysis: "viewfinder.circle"
        case .summary: "text.alignleft"
        }
    }

    func timelineTint(_ kind: WorkspaceTimelineItemKind) -> Color {
        switch kind {
        case .lifecycle: VisualTokens.secondaryText
        case .transcript: VisualTokens.live
        case .screenshot: VisualTokens.amber
        case .screenshotAnalysis: VisualTokens.sky
        case .summary: VisualTokens.cobalt
        }
    }
}
