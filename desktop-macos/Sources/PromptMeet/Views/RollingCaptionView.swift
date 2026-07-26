import SwiftUI

struct RollingCaptionView: View {
    let text: String
    var font: Font = .system(size: 12, weight: .medium, design: .rounded)
    var viewportHeight: CGFloat = 34
    var topPadding: CGFloat = 3

    private let bottomAnchor = "rolling-caption-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(VisualTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.top, topPadding)
            }
            .scrollIndicators(.hidden)
            .allowsHitTesting(false)
            .onChange(of: text, initial: true) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: viewportHeight)
    }
}
