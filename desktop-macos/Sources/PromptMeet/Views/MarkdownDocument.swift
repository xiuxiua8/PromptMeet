import Foundation

enum MarkdownParseMode: Equatable, Sendable {
    case streaming
    case completed
}

enum MarkdownBlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case unorderedList
    case orderedList
    case taskList(completed: [Bool])
    case quote
    case code(language: String?)
    case table(columns: [MarkdownTableColumn])
}

struct MarkdownBlock: Equatable, Sendable {
    let kind: MarkdownBlockKind
    let text: String
    let lines: [String]
    let isComplete: Bool

    init(
        kind: MarkdownBlockKind,
        lines: [String],
        isComplete: Bool = true
    ) {
        self.kind = kind
        self.lines = lines
        text = lines.joined(separator: "\n")
        self.isComplete = isComplete
    }
}

/// Block-level markdown parser used by the native renderer. Inline content
/// (emphasis, links, math segments) is delegated to `MarkdownInline`.
enum MarkdownDocument {
    static func parse(_ markdown: String, mode: MarkdownParseMode) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            blocks.append(consumeBlock(lines, index: &index))
        }

        return blocks
    }

    static func inline(_ markdown: String) -> AttributedString {
        MarkdownInline.inline(markdown)
    }

    static func stableInlineSource(_ source: String) -> String {
        MarkdownInline.stableInlineSource(source)
    }

    /// Splits an inline flow into text and math segments. See `MarkdownInline`.
    static func inlineSegments(_ source: String, mode: MarkdownParseMode) -> [MarkdownInlineSegment] {
        MarkdownInline.inlineSegments(source, mode: mode)
    }

    /// Rendering pieces for one inline flow. See `MarkdownInline`.
    static func inlinePieces(_ source: String, mode: MarkdownParseMode) -> [MarkdownInlinePiece] {
        MarkdownInline.inlinePieces(source, mode: mode)
    }

    private static func consumeBlock(_ lines: [String], index: inout Int) -> MarkdownBlock {
        let line = lines[index]
        if isFence(line) { return consumeCode(lines, index: &index) }
        if let value = heading(line) {
            index += 1
            return MarkdownBlock(kind: .heading(level: value.level), lines: [value.text])
        }
        if let item = taskItem(line) {
            return consumeTaskList(lines, index: &index, first: item)
        }
        if let item = unorderedItem(line) {
            return consumeList(lines, index: &index, first: item, ordered: false)
        }
        if let item = orderedItem(line) {
            return consumeList(lines, index: &index, first: item, ordered: true)
        }
        if let quote = quoteLine(line) {
            return consumeQuote(lines, index: &index, first: quote)
        }
        if MarkdownTableParser.isTableStart(lines, at: index) {
            return MarkdownTableParser.consumeTable(lines, index: &index)
        }
        return consumeParagraph(lines, index: &index)
    }

    private static func consumeCode(_ lines: [String], index: inout Int) -> MarkdownBlock {
        let language = fenceLanguage(lines[index])
        index += 1
        var codeLines: [String] = []
        var completed = false
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                completed = true
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        return MarkdownBlock(
            kind: .code(language: language),
            lines: codeLines,
            isComplete: completed
        )
    }

    private static func consumeList(
        _ lines: [String],
        index: inout Int,
        first: String,
        ordered: Bool
    ) -> MarkdownBlock {
        var items = [first]
        index += 1
        while index < lines.count {
            let next = ordered ? orderedItem(lines[index]) : unorderedItem(lines[index])
            guard let next else { break }
            items.append(next)
            index += 1
        }
        return MarkdownBlock(kind: ordered ? .orderedList : .unorderedList, lines: items)
    }

    private static func consumeTaskList(
        _ lines: [String],
        index: inout Int,
        first: (completed: Bool, text: String)
    ) -> MarkdownBlock {
        var items = [first.text]
        var completed = [first.completed]
        index += 1
        while index < lines.count, let next = taskItem(lines[index]) {
            items.append(next.text)
            completed.append(next.completed)
            index += 1
        }
        return MarkdownBlock(kind: .taskList(completed: completed), lines: items)
    }

    private static func consumeQuote(
        _ lines: [String],
        index: inout Int,
        first: String
    ) -> MarkdownBlock {
        var quotes = [first]
        index += 1
        while index < lines.count, let next = quoteLine(lines[index]) {
            quotes.append(next)
            index += 1
        }
        return MarkdownBlock(kind: .quote, lines: quotes)
    }

    private static func consumeParagraph(
        _ lines: [String],
        index: inout Int
    ) -> MarkdownBlock {
        var paragraph = [lines[index]]
        index += 1
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
              !startsBlock(lines[index]),
              !MarkdownTableParser.isTableStart(lines, at: index) {
            paragraph.append(lines[index])
            index += 1
        }
        return MarkdownBlock(kind: .paragraph, lines: paragraph)
    }

    static func startsBlock(_ line: String) -> Bool {
        isFence(line)
            || heading(line) != nil
            || taskItem(line) != nil
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || quoteLine(line) != nil
    }

    private static func fenceLanguage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return language.isEmpty ? nil : language
    }

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count),
              trimmed.dropFirst(hashes.count).first == " "
        else { return nil }
        return (
            hashes.count,
            String(trimmed.dropFirst(hashes.count + 1)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func unorderedItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private static func taskItem(_ line: String) -> (completed: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let item: String
        if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
            item = String(trimmed.dropFirst(marker.count))
        } else {
            return nil
        }
        for marker in ["[x] ", "[X] "] where item.hasPrefix(marker) {
            return (true, String(item.dropFirst(marker.count)))
        }
        guard item.hasPrefix("[ ] ") else { return nil }
        return (false, String(item.dropFirst(4)))
    }

    private static func orderedItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex else { return nil }
        let number = trimmed[..<dot]
        guard number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dot)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return String(trimmed[trimmed.index(after: afterDot)...])
    }

    private static func quoteLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}
