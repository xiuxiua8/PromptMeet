import SwiftUI

struct SubtitleTickerView: View {
    let originalText: String
    let translatedText: String?
    var font: Font = .system(size: 12, weight: .medium, design: .rounded)
    var viewportHeight: CGFloat = 21

    @State private var contentWidth: CGFloat = 0
    @State private var cycleStartedAt = Date()

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let scrolls = SubtitleTickerMetrics.shouldScroll(
                contentWidth: contentWidth,
                viewportWidth: viewportWidth
            )

            Group {
                if scrolls {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        HStack(spacing: SubtitleTickerMetrics.loopGap) {
                            measuredCaptionRow
                            captionRow
                        }
                        .offset(
                            x: SubtitleTickerMetrics.offset(
                                elapsed: context.date.timeIntervalSince(cycleStartedAt),
                                contentWidth: contentWidth,
                                viewportWidth: viewportWidth
                            )
                        )
                    }
                } else {
                    measuredCaptionRow
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .mask { tickerMask(scrolls: scrolls) }
        }
        .frame(height: viewportHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCaption)
        .onPreferenceChange(SubtitleTickerContentWidthKey.self) { width in
            contentWidth = width
        }
        .onChange(of: captionIdentity, initial: true) { _, _ in
            contentWidth = 0
            cycleStartedAt = Date()
        }
    }

    private var measuredCaptionRow: some View {
        captionRow.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SubtitleTickerContentWidthKey.self,
                    value: proxy.size.width
                )
            }
        }
    }

    private var captionRow: some View {
        HStack(spacing: 9) {
            Text(originalText)
                .font(font)
                .foregroundStyle(VisualTokens.primaryText)

            if let translation = normalizedTranslation {
                Circle()
                    .fill(VisualTokens.sky.opacity(0.55))
                    .frame(width: 3, height: 3)

                Text(translation)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(VisualTokens.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func tickerMask(scrolls: Bool) -> some View {
        if scrolls {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Rectangle()
        }
    }

    private var normalizedTranslation: String? {
        guard let value = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private var captionIdentity: String {
        "\(originalText)\u{1F}\(normalizedTranslation ?? "")"
    }

    private var accessibilityCaption: String {
        guard let normalizedTranslation else { return originalText }
        return "原文：\(originalText)。译文：\(normalizedTranslation)"
    }
}

private struct SubtitleTickerContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
