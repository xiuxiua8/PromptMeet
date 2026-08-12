import Foundation

/// Command conversion and token helpers for the lenient plain-text fallback.
extension FormulaPlainText {
    static func convert(
        command name: String,
        source: String,
        index: inout String.Index
    ) -> String? {
        let commandStart = source.index(after: index)
        var nameEnd = commandStart
        while nameEnd < source.endIndex, source[nameEnd].isLetter {
            nameEnd = source.index(after: nameEnd)
        }
        index = nameEnd

        if let converted = convertSymbol(command: name, source: source, index: &index) {
            return converted
        }
        switch name {
        case "frac":
            return convertFraction(source: source, index: &index)
        case "sqrt":
            return convertRadical(source: source, index: &index)
        case "text", "mathrm", "mathbf", "mathit", "operatorname", "mathbb":
            return convertTextCommand(source: source, index: &index)
        case "left", "right":
            return convertDelimiter(source: source, index: &index)
        case "quad", "qquad", "enspace", "thinspace", "medspace", "thickspace",
            "negthinspace":
            return " "
        default:
            return nil
        }
    }

    /// Symbol-table commands: operators with limits, glyphs, accents.
    static func convertSymbol(
        command name: String,
        source: String,
        index: inout String.Index
    ) -> String? {
        if let glyph = FormulaSymbols.largeOperatorGlyph(forCommand: name) {
            return largeOperatorText(glyph: glyph, source: source, index: &index)
        }
        if let operatorName = FormulaSymbols.operatorName(forCommand: name) {
            return largeOperatorText(glyph: operatorName, source: source, index: &index)
        }
        if let glyph = FormulaSymbols.glyph(forCommand: name) {
            return glyph
        }
        if let mark = FormulaSymbols.accentMark(forCommand: name) {
            if let (arg, next) = consumeGroupOrAtom(source, from: index) {
                index = next
                return plainText(arg) + mark
            }
            return mark
        }
        return nil
    }

    static func convertFraction(
        source: String,
        index: inout String.Index
    ) -> String {
        guard let (numerator, afterNumerator) = consumeGroupOrAtom(source, from: index) else {
            return "frac"
        }
        guard let (denominator, afterDenominator) = consumeGroupOrAtom(source, from: afterNumerator) else {
            index = afterNumerator
            return plainText(numerator) + "/"
        }
        index = afterDenominator
        return plainText(numerator) + "/" + plainText(denominator)
    }

    static func convertRadical(
        source: String,
        index: inout String.Index
    ) -> String {
        if let (degree, afterDegree) = consumeSquareBracket(source, from: index) {
            if let (base, afterBase) = consumeGroupOrAtom(source, from: afterDegree) {
                index = afterBase
                return "√" + plainText(base) + " (degree " + plainText(degree) + ")"
            }
        }
        if let (base, next) = consumeGroupOrAtom(source, from: index) {
            index = next
            return "√" + plainText(base)
        }
        return "√"
    }

    static func convertTextCommand(
        source: String,
        index: inout String.Index
    ) -> String {
        guard index < source.endIndex, source[index] == "{" else { return "text" }
        let raw = consumeBracedRaw(source, from: index)
        index = raw.next
        return raw.content
    }

    static func convertDelimiter(
        source: String,
        index: inout String.Index
    ) -> String {
        if let (delimiter, next) = consumeDelimiter(source, from: index) {
            index = next
            return delimiter
        }
        return ""
    }

    /// Operator glyph or name with optional lower/upper limits attached.
    static func largeOperatorText(
        glyph: String,
        source: String,
        index: inout String.Index
    ) -> String {
        var lower: String?
        var upper: String?
        var cursor = index
        while cursor < source.endIndex, source[cursor] == "^" || source[cursor] == "_" {
            let marker = source[cursor]
            let (script, next) = consumeScript(source, after: cursor)
            if marker == "^" { upper = script } else { lower = script }
            cursor = next
        }
        index = cursor
        switch (lower, upper) {
        case let (lower?, upper?): return glyph + "(" + lower + ".." + upper + ")"
        case let (lower?, nil): return glyph + "(" + lower + ")"
        case let (nil, upper?): return glyph + "(" + upper + ")"
        default: return glyph
        }
    }

    /// `{...}` group or a single atom, returning consumed content and next index.
    static func consumeGroupOrAtom(
        _ source: String,
        from index: String.Index
    ) -> (content: String, next: String.Index)? {
        guard index < source.endIndex else { return nil }
        if source[index] == "{" {
            let (raw, next) = consumeBracedRaw(source, from: index)
            return (raw, next)
        }
        if source[index] == "}" { return nil }
        if source[index] == "\\" {
            var nameEnd = source.index(after: index)
            while nameEnd < source.endIndex, source[nameEnd].isLetter {
                nameEnd = source.index(after: nameEnd)
            }
            let content = String(source[index..<nameEnd])
            return (content, nameEnd)
        }
        return (String(source[index]), source.index(after: index))
    }

    static func consumeSquareBracket(
        _ source: String,
        from index: String.Index
    ) -> (content: String, next: String.Index)? {
        guard index < source.endIndex, source[index] == "[" else { return nil }
        var cursor = source.index(after: index)
        var content = ""
        while cursor < source.endIndex, source[cursor] != "]" {
            content.append(source[cursor])
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex else { return nil }
        return (content, source.index(after: cursor))
    }

    static func consumeBracedRaw(
        _ source: String,
        from index: String.Index
    ) -> (content: String, next: String.Index) {
        guard index < source.endIndex, source[index] == "{" else {
            return ("", index)
        }
        var cursor = source.index(after: index)
        var depth = 1
        var content = ""
        while cursor < source.endIndex {
            if source[cursor] == "{" {
                depth += 1
                content.append("{")
            } else if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    return (content, source.index(after: cursor))
                }
                content.append("}")
            } else {
                content.append(source[cursor])
            }
            cursor = source.index(after: cursor)
        }
        return (content, cursor)
    }

    static func consumeScript(
        _ source: String,
        after index: String.Index
    ) -> (content: String, next: String.Index) {
        guard index < source.endIndex, source[index] == "^" || source[index] == "_" else {
            return ("", index)
        }
        let cursor = source.index(after: index)
        if cursor < source.endIndex, source[cursor] == "{" {
            let (raw, next) = consumeBracedRaw(source, from: cursor)
            return (raw, next)
        }
        guard cursor < source.endIndex else { return ("", cursor) }
        let single = String(source[cursor])
        return (single, source.index(after: cursor))
    }

    private static let plainNamedDelimiters: [String: String] = [
        "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "lvert": "|", "rvert": "|",
        "Vert": "‖", "lVert": "‖", "rVert": "‖"
    ]

    private static let plainSymbolDelimiters: [Character: String] = [
        "{": "{", "}": "}", "|": "‖", ".": ""
    ]

    static func consumeDelimiter(
        _ source: String,
        from index: String.Index
    ) -> (delimiter: String, next: String.Index)? {
        guard index < source.endIndex else { return nil }
        if source[index] != "\\" {
            return (String(source[index]), source.index(after: index))
        }
        let cursor = source.index(after: index)
        guard cursor < source.endIndex else { return nil }
        if source[cursor].isLetter {
            var nameEnd = cursor
            while nameEnd < source.endIndex, source[nameEnd].isLetter {
                nameEnd = source.index(after: nameEnd)
            }
            let name = String(source[cursor..<nameEnd])
            return (plainNamedDelimiters[name] ?? "", nameEnd)
        }
        let char = source[cursor]
        return (plainSymbolDelimiters[char] ?? String(char), source.index(after: cursor))
    }

    static func superscriptText(_ content: String) -> String {
        let mapping: [Character: Character] = [
            "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
            "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
            "8": "\u{2078}", "9": "\u{2079}", "-": "\u{207B}", "+": "\u{207A}",
            "(": "\u{207D}", ")": "\u{207E}", "=": "\u{207C}", "n": "\u{207F}"
        ]
        var result = ""
        for char in content {
            if let superscript = mapping[char] {
                result.append(superscript)
            } else {
                result.append(char)
            }
        }
        return result
    }
}
