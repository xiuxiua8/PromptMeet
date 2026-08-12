import Foundation

/// Normalizes Chinese transcript text to Simplified Chinese (zh-CN).
///
/// The table (OpenCC Traditional->Simplified, Apache-2.0) is embedded via
/// `SimplifiedChineseMapping` and applied longest-match phrase first, then per
/// character. Text outside the Han ranges (English, punctuation) passes through
/// unchanged, so code-switched utterances survive normalization intact.
enum SimplifiedChineseNormalizer {
    private static let characters = SimplifiedChineseMapping.characters
    private static let phrases = SimplifiedChineseMapping.phrases

    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if let (target, consumed) = matchPhrase(at: index, in: characters) {
                result.append(contentsOf: target)
                index += consumed
                continue
            }
            let character = characters[index]
            // Single-scalar graphemes (Han, Latin, punctuation) map directly;
            // multi-scalar graphemes (combining marks, emoji) pass through.
            if character.unicodeScalars.count == 1 {
                let scalar = character.unicodeScalars.first!
                if scalar.value > 0xFF {
                    result.append(self.characters[character] ?? character)
                } else {
                    result.append(character)
                }
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    /// Longest-match phrase substitution starting at `index`.
    private static func matchPhrase(
        at index: Int,
        in characters: [Character]
    ) -> (target: String, consumed: Int)? {
        for phrase in phrases {
            let key = Array(phrase.source)
            guard key.count <= characters.count - index else { continue }
            var matches = true
            var offset = 0
            for keyCharacter in key {
                if keyCharacter != characters[index + offset] {
                    matches = false
                    break
                }
                offset += 1
            }
            if matches {
                return (phrase.target, offset)
            }
        }
        return nil
    }
}
