import AppKit
import SwiftUI

struct AIReaderView: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            LinearGradient(
                colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 18)

            answerBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .foregroundStyle(VisualTokens.primaryText)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [VisualTokens.islandSoft, VisualTokens.island, VisualTokens.island],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            VisualTokens.live.opacity(0.42),
                            Color.white.opacity(0.08),
                            VisualTokens.sky.opacity(0.60),
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    lineWidth: 0.7
                )
        }
        .shadow(color: VisualTokens.sky.opacity(0.14), radius: 24, y: 10)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                    Text("AI")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.sky)

                Text(store.state.aiReader.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                Button(action: copyAnswer) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
                .disabled(store.state.aiReader.content.isEmpty)
                .help("复制回答")

                Button { store.hideReader() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
                .help("关闭")
            }
            .font(.system(size: 10, weight: .semibold))
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        if store.state.aiReader.content.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(VisualTokens.sky)
                Text(store.state.aiRequest.phase == .submitting ? "正在思考" : "回答会显示在这里")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            ScrollView {
                answerText
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.state.aiReader.isStreaming {
                HStack(spacing: 7) {
                    Circle()
                        .fill(VisualTokens.sky)
                        .frame(width: 5, height: 5)
                        .shadow(color: VisualTokens.sky.opacity(0.65), radius: 6)
                    Text("正在生成")
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.sky)
                .padding(.leading, 4)
            }

            QuickAskField(store: store, appearance: .aura)
        }
    }

    private var answerText: Text {
        if store.state.aiReader.isStreaming {
            return Text(store.state.aiReader.content)
        }
        if let attributed = try? AttributedString(
            markdown: store.state.aiReader.content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(store.state.aiReader.content)
    }

    private func copyAnswer() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.state.aiReader.content, forType: .string)
    }
}
