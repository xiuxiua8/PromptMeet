import Foundation

/// A source-level segment of an inline markdown flow. Math spans are split
/// out so the renderer can draw them as formulas instead of literal text.
enum MarkdownInlineSegment: Equatable, Sendable {
    case text(String)
    case math(content: String, display: Bool)
}

/// Rendering pieces for one inline flow: attributed text runs interleaved
/// with math spans that the view turns into images.
enum MarkdownInlinePiece: Equatable, Sendable {
    case text(AttributedString)
    case math(content: String, display: Bool)
}

/// Inline markdown parsing: the shared Foundation-based renderer plus math
/// segmentation. Math delimiters are `$...$` and `\(...\)` (inline) plus
/// `$$...$$` and `\[...\]` (display). Code spans keep their literal content;
/// unclosed or malformed delimiters stay as literal text so streaming never
/// breaks.
enum MarkdownInline {
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

    static func inlineSegments(_ source: String, mode: MarkdownParseMode) -> [MarkdownInlineSegment] {
        var scanner = MarkdownInlineScanner(source: source)
        return scanner.scan()
    }

    /// Renders one inline flow with math spans replaced by placeholder
    /// characters before the shared markdown parse, so emphasis and links
    /// keep working across formulas. The attributed result is then split at
    /// the placeholders and math pieces are returned for image rendering.
    static func inlinePieces(_ source: String, mode: MarkdownParseMode) -> [MarkdownInlinePiece] {
        let segments = inlineSegments(source, mode: mode)
        let mathCount = segments.reduce(into: 0) { count, segment in
            if case .math = segment { count += 1 }
        }
        guard mathCount > 0 else {
            return [.text(inline(stableInlineSource(source)))]
        }

        let placeholder = "\u{FFFF}"
        var marked = ""
        var mathSegments: [MarkdownInlineSegment] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                marked += text
            case .math:
                marked += placeholder
                mathSegments.append(segment)
            }
        }
        let stable = stableInlineSource(marked)
        let attributed = inline(stable)

        var pieces: [MarkdownInlinePiece] = []
        var pieceStart = attributed.startIndex
        var cursor = attributed.startIndex
        var mathCursor = 0
        while cursor < attributed.endIndex {
            if attributed.characters[cursor] == Character(placeholder) {
                if pieceStart < cursor {
                    pieces.append(.text(AttributedString(attributed[pieceStart..<cursor])))
                }
                if mathCursor < mathSegments.count,
                    case .math(let content, let display) = mathSegments[mathCursor] {
                    pieces.append(.math(content: content, display: display))
                }
                mathCursor += 1
                cursor = attributed.index(afterCharacter: cursor)
                pieceStart = cursor
            } else {
                cursor = attributed.index(afterCharacter: cursor)
            }
        }
        if pieceStart < attributed.endIndex {
            pieces.append(.text(AttributedString(attributed[pieceStart..<attributed.endIndex])))
        }
        return pieces
    }
}

/// One-pass math scanner: walks the source, emitting text and math segments.
private struct MarkdownInlineScanner {
    let source: String
    var segments: [MarkdownInlineSegment] = []
    var textBuffer = ""
    var index: String.Index

    init(source: String) {
        self.source = source
        index = source.startIndex
    }

    mutating func scan() -> [MarkdownInlineSegment] {
        while index < source.endIndex {
            if consumeCodeSpan() { continue }
            if consumeDisplayDollar() { continue }
            if consumeInlineDollar() { continue }
            if consumeParenthesisMath() { continue }
            if consumeBracketMath() { continue }
            textBuffer.append(source[index])
            index = source.index(after: index)
        }
        flushText()
        return segments
    }

    private mutating func flushText() {
        if !textBuffer.isEmpty {
            segments.append(.text(textBuffer))
            textBuffer = ""
        }
    }

    private func isEscaped(_ position: String.Index) -> Bool {
        var slashCount = 0
        var cursor = position
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return !slashCount.isMultiple(of: 2)
    }

    /// Code spans are never math: copy through the paired backtick.
    private mutating func consumeCodeSpan() -> Bool {
        guard source[index] == "`", !isEscaped(index) else { return false }
        let after = source.index(after: index)
        if let close = source.range(of: "`", range: after..<source.endIndex)?.lowerBound {
            textBuffer.append(String(source[index...close]))
            index = source.index(after: close)
            return true
        }
        textBuffer.append(String(source[index..<source.endIndex]))
        index = source.endIndex
        return true
    }

    /// `$$...$$` display math.
    private mutating func consumeDisplayDollar() -> Bool {
        let second = source.index(after: index)
        guard second < source.endIndex,
            source[index] == "$",
            source[second] == "$",
            !isEscaped(index) else { return false }
        let contentStart = source.index(index, offsetBy: 2)
        guard let close = source.range(of: "$$", range: contentStart..<source.endIndex)?.lowerBound,
            !isEscaped(close) else { return false }
        let content = String(source[contentStart..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        flushText()
        segments.append(.math(content: content, display: true))
        index = source.index(close, offsetBy: 2)
        return true
    }

    /// `$...$` inline math (KaTeX-style open/close rules).
    private mutating func consumeInlineDollar() -> Bool {
        guard source[index] == "$", !isEscaped(index) else { return false }
        let after = source.index(after: index)
        guard after < source.endIndex, !source[after].isWhitespace else { return false }
        guard let close = findClosingInlineDollar(from: after) else { return false }
        let content = String(source[after..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.contains("`") else { return false }
        flushText()
        segments.append(.math(content: content, display: false))
        index = source.index(after: close)
        return true
    }

    /// `\(...\)` inline math.
    private mutating func consumeParenthesisMath() -> Bool {
        let second = source.index(after: index)
        guard second < source.endIndex,
            source[index] == "\\",
            source[second] == "(",
            !isEscaped(index) else { return false }
        let contentStart = source.index(index, offsetBy: 2)
        guard let close = source.range(of: "\\)", range: contentStart..<source.endIndex)?.lowerBound else {
            return false
        }
        let content = String(source[contentStart..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.contains("`") else { return false }
        flushText()
        segments.append(.math(content: content, display: false))
        index = source.index(close, offsetBy: 2)
        return true
    }

    /// `\[...\]` display math.
    private mutating func consumeBracketMath() -> Bool {
        let second = source.index(after: index)
        guard second < source.endIndex,
            source[index] == "\\",
            source[second] == "[",
            !isEscaped(index) else { return false }
        let contentStart = source.index(index, offsetBy: 2)
        guard let close = source.range(of: "\\]", range: contentStart..<source.endIndex)?.lowerBound else {
            return false
        }
        let content = String(source[contentStart..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.contains("`") else { return false }
        flushText()
        segments.append(.math(content: content, display: true))
        index = source.index(close, offsetBy: 2)
        return true
    }

    private func findClosingInlineDollar(from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            guard source[cursor] == "$" else {
                cursor = source.index(after: cursor)
                continue
            }
            guard !isEscaped(cursor) else {
                cursor = source.index(after: cursor)
                continue
            }
            guard cursor > start else {
                cursor = source.index(after: cursor)
                continue
            }
            let previous = source.index(before: cursor)
            guard !source[previous].isWhitespace else {
                cursor = source.index(after: cursor)
                continue
            }
            let content = String(source[start..<cursor])
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor = source.index(after: cursor)
                continue
            }
            return cursor
        }
        return nil
    }
}

/// Streaming stabilizer: hides unpaired emphasis markers and protects code
/// spans so partial inline markdown never exposes dangling `*`/`_` text.
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
