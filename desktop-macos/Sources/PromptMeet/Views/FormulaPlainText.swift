import Foundation

/// Lenient one-pass converter that always produces readable plain text from
/// formula source. Used as the graceful fallback when strict parsing or
/// rendering fails: never crashes, never exposes `$`-style markers.
enum FormulaPlainText {
    static func plainText(_ source: String) -> String {
        var output = ""
        var index = source.startIndex

        while index < source.endIndex {
            let char = source[index]
            if char == "\\" {
                appendCommand(source: source, index: &index, output: &output)
                continue
            }
            if char == "^" {
                let (script, next) = consumeScript(source, after: index)
                output += superscriptText(script)
                index = next
                continue
            }
            if char == "_" {
                let (script, next) = consumeScript(source, after: index)
                output += script
                index = next
                continue
            }
            if char == "{" || char == "}" {
                index = source.index(after: index)
                continue
            }
            if char == "\n" || char == "\r" || char == "\t" || char == " " {
                output += " "
                index = source.index(after: index)
                continue
            }
            output.append(char)
            index = source.index(after: index)
        }
        return output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Handles a `\command` at `index`, converting known commands and
    /// emitting readable text for unknown ones. Never fails.
    private static func appendCommand(
        source: String,
        index: inout String.Index,
        output: inout String
    ) {
        let commandStart = source.index(after: index)
        var nameEnd = commandStart
        while nameEnd < source.endIndex, source[nameEnd].isLetter {
            nameEnd = source.index(after: nameEnd)
        }
        if commandStart < nameEnd {
            let name = String(source[commandStart..<nameEnd])
            if let converted = convert(command: name, source: source, index: &index) {
                output += converted
                return
            }
            output += String(source[commandStart..<nameEnd])
            index = nameEnd
            return
        }
        guard commandStart < source.endIndex else {
            index = source.index(after: index)
            return
        }
        let single = source[commandStart]
        switch single {
        case " ", ",", ";", ":", "!", "~":
            output += " "
        default:
            output += String(single)
        }
        index = source.index(after: commandStart)
    }
}
