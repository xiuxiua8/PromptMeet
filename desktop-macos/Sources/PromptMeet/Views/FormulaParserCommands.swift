import Foundation

/// Command handling for the strict formula parser: named commands like
/// `\frac`, `\sqrt`, `\left`, symbol and operator commands, spacing, and
/// single-character escape sequences.
extension FormulaParser {
    private static let symbolicSpaces: [Character: CGFloat] = [
        " ": 0.18, ",": 0.17, ";": 0.28, ":": 0.22, "!": -0.17
    ]

    private static let literalSymbols: [Character: String] = [
        "{": "{", "}": "}", "%": "%", "&": "&", "#": "#",
        "$": "$", "_": "_", "^": "^", "\\": "\\",
        "(": "(", ")": ")", "[": "[", "]": "]", "|": "|"
    ]

    private static let spacingWidths: [String: CGFloat] = [
        "quad": 1.0, "qquad": 2.0, "enspace": 0.5,
        "thinspace": 0.17, "medspace": 0.22,
        "thickspace": 0.28, "negthinspace": -0.17
    ]

    mutating func parseCommand() -> FormulaNode? {
        position += 1
        guard !isAtEnd else { return nil }
        let char = characters[position]
        if char.isLetter {
            let name = consumeConsecutive(\.isLetter)
            return tryCommand(named: name)
        }
        position += 1
        if let width = Self.symbolicSpaces[char] {
            return .space(width: width)
        }
        if let text = Self.literalSymbols[char] {
            return .text(text)
        }
        return nil
    }

    mutating func tryCommand(named name: String) -> FormulaNode? {
        switch name {
        case "frac":
            return parseFracCommand()
        case "sqrt":
            return parseSqrtCommand()
        case "text", "mathrm", "mathbf", "mathit", "operatorname", "mathbb":
            return parseTextCommand()
        case "left":
            return parseLeftCommand()
        case "right":
            return nil
        default:
            break
        }
        if let command = trySymbolCommand(named: name) {
            return command
        }
        if let width = Self.spacingWidths[name] {
            return .space(width: width)
        }
        return nil
    }

    mutating func parseFracCommand() -> FormulaNode? {
        guard let numerator = parseGroupOrAtom() else { return nil }
        guard let denominator = parseGroupOrAtom() else { return nil }
        return .fraction(numerator: numerator, denominator: denominator)
    }

    mutating func parseSqrtCommand() -> FormulaNode? {
        var degree: FormulaNode?
        if !isAtEnd, characters[position] == "[" {
            position += 1
            guard let value = parseSequence(stopAtRightDelimiter: false),
                !isAtEnd, characters[position] == "]" else { return nil }
            degree = value
            position += 1
        }
        guard let base = parseGroupOrAtom() else { return nil }
        return .radical(base: base, degree: degree)
    }

    mutating func parseTextCommand() -> FormulaNode? {
        guard let raw = consumeBracedRaw() else { return nil }
        return .text(raw)
    }

    mutating func parseLeftCommand() -> FormulaNode? {
        guard let open = parseDelimiter() else { return nil }
        guard let content = parseSequence(stopAtRightDelimiter: true) else { return nil }
        guard !isAtEnd, isRightDelimiter(at: position) else { return nil }
        position += 6
        guard let close = parseDelimiter() else { return nil }
        return .delimiter(open: open, content: content, close: close)
    }

    /// Symbol tables: large operators, operator names, glyphs, accents.
    mutating func trySymbolCommand(named name: String) -> FormulaNode? {
        if let glyph = FormulaSymbols.largeOperatorGlyph(forCommand: name) {
            return .mathOperator(name: glyph, lower: nil, upper: nil)
        }
        if let operatorName = FormulaSymbols.operatorName(forCommand: name) {
            return .mathOperator(name: operatorName, lower: nil, upper: nil)
        }
        if let glyph = FormulaSymbols.glyph(forCommand: name) {
            return .symbol(glyph)
        }
        if let mark = FormulaSymbols.accentMark(forCommand: name) {
            guard let base = parseGroupOrAtom() else { return nil }
            return .accent(base: base, mark: mark)
        }
        return nil
    }

    private static let namedDelimiters: [String: String] = [
        "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "Vert": "‖",
        "lvert": "|", "rvert": "|",
        "lVert": "‖", "rVert": "‖"
    ]

    private static let symbolDelimiters: [Character: String] = [
        "{": "{", "}": "}", "|": "‖", ".": ""
    ]

    /// `\left` / `\right` delimiter: a character or a short command.
    mutating func parseDelimiter() -> String? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        if characters[position] != "\\" {
            let char = characters[position]
            position += 1
            return String(char)
        }
        position += 1
        guard !isAtEnd else { return nil }
        if characters[position].isLetter {
            let name = consumeConsecutive(\.isLetter)
            return Self.namedDelimiters[name]
        }
        let char = characters[position]
        position += 1
        return Self.symbolDelimiters[char]
    }

    /// Raw `{...}` content for \text-like commands, brace-depth aware.
    mutating func consumeBracedRaw() -> String? {
        skipWhitespace()
        guard !isAtEnd, characters[position] == "{" else { return nil }
        position += 1
        var depth = 1
        var result = ""
        while !isAtEnd {
            let char = characters[position]
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    position += 1
                    return result
                }
            }
            result.append(char)
            position += 1
        }
        return nil
    }
}
