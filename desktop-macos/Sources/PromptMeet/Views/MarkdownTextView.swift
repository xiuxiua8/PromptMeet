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
            if isDisplayFormulaParagraph(block.text) {
                displayFormulaBlock(block.text)
            } else {
                inlineText(block.text)
                    .font(.system(size: baseFontSize, weight: .regular, design: .rounded))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        case .table(let columns):
            table(columns)
        }
    }

    private func table(_ columns: [MarkdownTableColumn]) -> some View {
        let rowCount = columns.first?.cells.count ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    tableCell(column.header, alignment: column.alignment, header: true)
                }
            }
            .background(VisualTokens.sky.opacity(0.10))
            Rectangle()
                .fill(VisualTokens.line)
                .frame(height: 0.5)
            ForEach(0..<rowCount, id: \.self) { row in
                if row > 0 {
                    Rectangle()
                        .fill(VisualTokens.line.opacity(0.6))
                        .frame(height: 0.5)
                }
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        tableCell(
                            column.cells.indices.contains(row) ? column.cells[row] : "",
                            alignment: column.alignment,
                            header: false
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(VisualTokens.line, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格，\(columns.count) 列，\(rowCount) 行")
    }

    private func tableCell(_ content: String, alignment: MarkdownTableAlignment, header: Bool) -> some View {
        inlineText(content)
            .font(.system(size: max(10, baseFontSize - 1), weight: header ? .semibold : .regular, design: .rounded))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: tableFrameAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(header ? VisualTokens.primaryText : VisualTokens.primaryText.opacity(0.88))
    }

    private func tableFrameAlignment(_ alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    /// True when the paragraph consists only of one or more display formulas.
    private func isDisplayFormulaParagraph(_ text: String) -> Bool {
        let pieces = MarkdownDocument.inlinePieces(text, mode: mode)
        guard !pieces.isEmpty else { return false }
        for piece in pieces {
            switch piece {
            case .text(let attributed):
                let content = String(attributed.characters)
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return false
                }
            case .math(_, let display):
                if !display { return false }
            }
        }
        return true
    }

    private func displayFormulaBlock(_ text: String) -> some View {
        VStack(alignment: .center, spacing: 10) {
            ForEach(displayFormulaContents(text), id: \.self) { content in
                formulaText(content, display: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func displayFormulaContents(_ text: String) -> [String] {
        MarkdownDocument.inlinePieces(text, mode: mode).compactMap { piece in
            if case .math(let content, let display) = piece, display { return content }
            return nil
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
        MarkdownDocument.inlinePieces(source, mode: mode).reduce(Text(verbatim: "")) { result, piece in
            switch piece {
            case .text(let attributed):
                return result + Text(attributed)
            case .math(let content, let display):
                return result + formulaText(content, display: display)
            }
        }
    }

    /// Renders a math span as an inline image, or a readable plain-text
    /// fallback when the formula is unsupported or malformed.
    private func formulaText(_ content: String, display: Bool) -> Text {
        if let formula = FormulaRenderer.image(
            for: content,
            display: display,
            baseFontSize: baseFontSize
        ) {
            let image = Text(Image(nsImage: formula.image))
                .baselineOffset(-formula.baselineShift)
            return image.accessibilityLabel("公式：\(content)")
        }
        return Text(verbatim: FormulaPlainText.plainText(content))
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
