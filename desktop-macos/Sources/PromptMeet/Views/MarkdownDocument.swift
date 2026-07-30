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
              !startsBlock(lines[index]) {
            paragraph.append(lines[index])
            index += 1
        }
        return MarkdownBlock(kind: .paragraph, lines: paragraph)
    }

    static func inline(_ markdown: String) -> AttributedString {
        var attributed = (
            try? AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        ) ?? AttributedString(markdown)
        for run in attributed.runs.reversed() {
            guard let link = run.link else { continue }
            let scheme = link.scheme?.lowercased()
            if scheme != "https" && scheme != "http" {
                attributed[run.range].link = nil
            }
        }
        return attributed
    }

    static func stableInlineSource(_ source: String) -> String {
        MarkdownInlineStabilizer.stableSource(source)
    }

    private static func startsBlock(_ line: String) -> Bool {
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

private enum MarkdownInlineStabilizer {
    static func stableSource(_ source: String) -> String {
        let codeDelimiters = unescapedRanges(of: "`", in: source)
        var stable = ""
        var segmentStart = source.startIndex
        for (index, delimiter) in codeDelimiters.enumerated() {
            let segment = String(source[segmentStart..<delimiter.lowerBound])
            stable.append(index.isMultiple(of: 2) ? stableEmphasisSource(segment) : segment)
            let isUnmatchedLast = !codeDelimiters.count.isMultiple(of: 2)
                && index == codeDelimiters.count - 1
            if !isUnmatchedLast { stable.append("`") }
            segmentStart = delimiter.upperBound
        }
        let trailing = String(source[segmentStart..<source.endIndex])
        stable.append(
            codeDelimiters.count.isMultiple(of: 2)
                ? stableEmphasisSource(trailing)
                : trailing
        )
        return stable
    }

    private static func stableEmphasisSource(_ source: String) -> String {
        var stable = source
        for marker in ["**", "__", "*", "_"] {
            let ranges = unescapedRanges(of: marker, in: stable)
            guard !ranges.count.isMultiple(of: 2),
                  let last = ranges.last,
                  isLikelyUnpairedDelimiter(marker, range: last, in: stable)
            else { continue }
            stable.removeSubrange(last)
        }
        return stable
    }

    private static func unescapedRanges(
        of marker: String,
        in source: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = source.startIndex
        while start < source.endIndex,
              let range = source.range(of: marker, range: start..<source.endIndex) {
            var slashCount = 0
            var cursor = range.lowerBound
            while cursor > source.startIndex {
                let previous = source.index(before: cursor)
                guard source[previous] == "\\" else { break }
                slashCount += 1
                cursor = previous
            }
            if slashCount.isMultiple(of: 2) { ranges.append(range) }
            start = range.upperBound
        }
        return ranges
    }

    private static func isLikelyUnpairedDelimiter(
        _ marker: String,
        range: Range<String.Index>,
        in source: String
    ) -> Bool {
        guard range.upperBound < source.endIndex else { return true }
        let next = source[range.upperBound]
        guard !next.isWhitespace else { return false }
        guard marker.contains("_") else {
            if range.lowerBound > source.startIndex {
                let previous = source[source.index(before: range.lowerBound)]
                if previous.isNumber && next.isNumber { return false }
            }
            return true
        }
        guard range.lowerBound > source.startIndex else { return true }
        let previous = source[source.index(before: range.lowerBound)]
        return !previous.isLetter && !previous.isNumber
    }
}
