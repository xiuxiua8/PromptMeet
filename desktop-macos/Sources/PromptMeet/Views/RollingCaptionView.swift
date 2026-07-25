import SwiftUI

struct RollingCaptionView: View {
    let text: String

    private let bottomAnchor = "rolling-caption-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(VisualTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .padding(.top, 3)
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
        .frame(height: 34)
    }
}
