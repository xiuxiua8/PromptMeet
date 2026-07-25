import AppKit
import SwiftUI

struct AIReaderView: View {
    @ObservedObject var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("PROMPTMEET · AI")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VisualTokens.sky)
                    Text(store.state.aiReader.title)
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                Button(action: copyAnswer) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
                .help("复制回答")
                Button { store.hideReader() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
            }

            Divider().overlay(VisualTokens.line)

            ScrollView {
                answerText
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            if store.state.aiReader.isStreaming {
                HStack(spacing: 6) {
                    Circle().fill(VisualTokens.sky).frame(width: 5, height: 5)
                    Text("正在生成")
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualTokens.sky)
            }
        }
        .padding(22)
        .foregroundStyle(VisualTokens.primaryText)
        .background(Color(red: 14 / 255, green: 15 / 255, blue: 19 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
