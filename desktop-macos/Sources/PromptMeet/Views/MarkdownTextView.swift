import SwiftUI

struct MarkdownTextView: View {
    let markdown: String
    var mode: MarkdownParseMode = .completed
    var baseFontSize: CGFloat = 12

    private var blocks: [MarkdownBlock] {
        MarkdownDocument.parse(markdown, mode: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            inlineText(block.text)
                .font(.system(size: headingSize(level), weight: .bold, design: .rounded))
                .padding(.top, level <= 2 ? 4 : 0)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            inlineText(block.text)
                .font(.system(size: baseFontSize, weight: .regular, design: .rounded))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList:
            list(block.lines, ordered: false)
        case .orderedList:
            list(block.lines, ordered: true)
        case .taskList(let completed):
            taskList(block.lines, completed: completed)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(VisualTokens.sky.opacity(0.72))
                    .frame(width: 3)
                inlineText(block.text)
                    .font(.system(size: baseFontSize, weight: .regular, design: .rounded))
                    .italic()
                    .foregroundStyle(VisualTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        case .code(let language):
            codeBlock(block, language: language)
        }
    }

    private func codeBlock(_ block: MarkdownBlock, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let language {
                Text(language.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(VisualTokens.sky)
            }
            Text(block.text)
                .font(.system(size: max(10, baseFontSize - 1), design: .monospaced))
                .foregroundStyle(VisualTokens.primaryText.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if mode == .streaming && !block.isComplete {
                Text("代码仍在生成")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualTokens.line, lineWidth: 0.5)
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(MarkdownDocument.inline(MarkdownDocument.stableInlineSource(source)))
    }

    private func list(_ lines: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.system(size: baseFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .frame(minWidth: ordered ? 20 : 9, alignment: .trailing)
                    inlineText(line)
                        .font(.system(size: baseFontSize, weight: .regular, design: .rounded))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func taskList(_ lines: [String], completed: [Bool]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let isCompleted = completed.indices.contains(index) && completed[index]
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                        .font(.system(size: baseFontSize, weight: .semibold))
                        .foregroundStyle(isCompleted ? VisualTokens.live : VisualTokens.sky)
                        .accessibilityHidden(true)
                    inlineText(line)
                        .font(.system(size: baseFontSize, weight: .regular, design: .rounded))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(isCompleted ? "已完成" : "未完成")，\(plainText(line))"
                )
            }
        }
    }

    private func plainText(_ source: String) -> String {
        String(MarkdownDocument.inline(source).characters)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: baseFontSize + 8
        case 2: baseFontSize + 6
        case 3: baseFontSize + 4
        default: baseFontSize + 2
        }
    }
}
