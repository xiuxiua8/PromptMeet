import Foundation

/// Parsed LaTeX-subset formula tree used by the native formula renderer.
/// Pure value types: parsing never touches AppKit and is fully unit-testable.
indirect enum FormulaNode: Equatable, Sendable {
    case text(String)
    case letter(String)
    case symbol(String)
    case mathOperator(name: String, lower: FormulaNode?, upper: FormulaNode?)
    case script(base: FormulaNode, lower: FormulaNode?, upper: FormulaNode?)
    case fraction(numerator: FormulaNode, denominator: FormulaNode)
    case radical(base: FormulaNode, degree: FormulaNode?)
    case accent(base: FormulaNode, mark: String)
    case delimiter(open: String, content: FormulaNode, close: String)
    case space(width: CGFloat)
    case sequence([FormulaNode])
}

/// Strict recursive-descent parser over a LaTeX subset. Returns nil for
/// anything unsupported or malformed so callers can fall back to readable
/// plain text instead of crashing or leaking raw markers.
struct FormulaParser {
    let characters: [Character]
    var position = 0

    init(source: String) {
        characters = Array(source)
    }

    static func parse(_ source: String) -> FormulaNode? {
        var parser = FormulaParser(source: source)
        guard let node = parser.parseSequence(stopAtRightDelimiter: false), parser.isAtEnd else {
            return nil
        }
        return node
    }

    var isAtEnd: Bool { position >= characters.count }

    /// Sequence of atoms until the end or a closing group/`\right` boundary.
    mutating func parseSequence(stopAtRightDelimiter: Bool) -> FormulaNode? {
        var nodes: [FormulaNode] = []
        while true {
            skipWhitespace()
            if isAtEnd { break }
            if characters[position] == "}" { break }
            if stopAtRightDelimiter, isRightDelimiter(at: position) { break }
            guard let atom = parseScriptedAtom() else { return nil }
            nodes.append(atom)
        }
        if nodes.isEmpty { return nil }
        return nodes.count == 1 ? nodes[0] : .sequence(nodes)
    }

    mutating func parseScriptedAtom() -> FormulaNode? {
        guard let base = parseBaseAtom() else { return nil }

        var lower: FormulaNode?
        var upper: FormulaNode?
        var seen = Set<Character>()
        while !isAtEnd, characters[position] == "^" || characters[position] == "_" {
            let marker = characters[position]
            guard seen.insert(marker).inserted else { return nil }
            position += 1
            guard let script = parseScript() else { return nil }
            if marker == "^" { upper = script } else { lower = script }
        }
        if lower == nil, upper == nil { return base }
        if case .mathOperator(let name, _, _) = base {
            return .mathOperator(name: name, lower: lower, upper: upper)
        }
        return .script(base: base, lower: lower, upper: upper)
    }

    mutating func parseScript() -> FormulaNode? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        if characters[position] == "{" {
            position += 1
            guard let group = parseSequence(stopAtRightDelimiter: false) else { return nil }
            guard !isAtEnd, characters[position] == "}" else { return nil }
            position += 1
            return group
        }
        guard characters[position] != "^",
            characters[position] != "_",
            characters[position] != "}" else { return nil }
        return parseScriptedAtom()
    }

    mutating func parseBaseAtom() -> FormulaNode? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        let char = characters[position]
        if char == "^" || char == "_" { return nil }
        if char == "{" {
            return parseGroup()
        }
        if char == "\\" { return parseCommand() }
        if char.isLetter { return .letter(consumeConsecutive(\.isLetter)) }
        if char.isNumber { return .text(consumeConsecutive(\.isNumber)) }
        position += 1
        return parseSpaceOrSymbol(char)
    }

    mutating func parseGroup() -> FormulaNode? {
        position += 1
        guard let group = parseSequence(stopAtRightDelimiter: false) else { return nil }
        guard !isAtEnd, characters[position] == "}" else { return nil }
        position += 1
        return group
    }

    /// Whitespace and punctuation that are not structural in a formula.
    mutating func parseSpaceOrSymbol(_ char: Character) -> FormulaNode? {
        switch char {
        case " ", "~": return .space(width: 0.18)
        default: return .text(String(char))
        }
    }

    /// `{...}` group or a single atom, used by \frac, \sqrt, accents.
    mutating func parseGroupOrAtom() -> FormulaNode? {
        skipWhitespace()
        guard !isAtEnd else { return nil }
        if characters[position] == "{" {
            return parseGroup()
        }
        if characters[position] == "^" || characters[position] == "_" || characters[position] == "}" {
            return nil
        }
        return parseScriptedAtom()
    }

    mutating func skipWhitespace() {
        while !isAtEnd {
            let char = characters[position]
            guard char == " " || char == "\t" || char == "\n" || char == "\r" else { break }
            position += 1
        }
    }

    mutating func consumeConsecutive(_ predicate: (Character) -> Bool) -> String {
        var result = ""
        while !isAtEnd, predicate(characters[position]) {
            result.append(characters[position])
            position += 1
        }
        return result
    }

    func isRightDelimiter(at index: Int) -> Bool {
        guard characters[index] == "\\" else { return false }
        let remaining = characters[(index + 1)...]
        let command = String(remaining.prefix(5))
        return command == "right"
    }
}
