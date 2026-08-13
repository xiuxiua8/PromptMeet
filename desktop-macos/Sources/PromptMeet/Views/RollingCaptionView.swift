import SwiftUI

/// Vertical rolling caption for the expanded meeting card.
///
/// Renders the buffered subtitle pages (stable identities, appended - never
/// replaced wholesale) with the current partial as a live tail, auto-following
/// to the newest content. Manual scrolling away from the bottom suspends the
/// auto-follow until the user returns to the bottom.
struct RollingCaptionView: View {
    let pages: [SubtitleStreamPage]
    let liveText: String
    var font: Font = .system(size: 12, weight: .regular)
    var viewportHeight: CGFloat = 34
    var topPadding: CGFloat = 3

    private let bottomAnchor = "rolling-caption-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRows) { row in
                        captionRow(row)
                    }

                    if let live = normalizedLiveText, !live.isEmpty {
                        Text(live)
                            .font(font)
                            .foregroundStyle(VisualTokens.live.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.top, topPadding)
            }
            .scrollIndicators(.hidden)
            .allowsHitTesting(false)
            .onChange(of: visibleRowIdentities) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: viewportHeight)
    }

    private var visibleRows: [SubtitleStreamPage] {
        Array(pages.suffix(8))
    }

    private var visibleRowIdentities: [UUID] {
        visibleRows.map(\.id)
    }

    private var normalizedLiveText: String? {
        let value = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func captionRow(_ page: SubtitleStreamPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.timestamp != nil, !page.text.isEmpty {
                Color.clear.frame(height: 6)
            }
            Text(page.text)
                .font(font)
                .foregroundStyle(VisualTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let translation = page.translation?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VisualTokens.sky.opacity(0.90))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id(page.id)
    }
}
