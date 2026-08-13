import Foundation

/// The only languages the gated transcription pipeline emits: Simplified Chinese and English.
enum TranscriptLanguage: String, Sendable, Equatable {
    case chinese
    case english

    /// whisper.cpp language hint accepted by `-l` / the inference request.
    var whisperCode: String {
        switch self {
        case .chinese: "zh"
        case .english: "en"
        }
    }

    /// Full whisper language name used by the verbose_json `detected_language` field.
    static func fromWhisperFullName(_ name: String?) -> TranscriptLanguage? {
        switch name?.lowercased() {
        case "chinese": .chinese
        case "english": .english
        default: nil
        }
    }

    /// Short whisper language id used by `language_probabilities` keys.
    static func fromWhisperCode(_ code: String?) -> TranscriptLanguage? {
        switch code?.lowercased() {
        case "zh": .chinese
        case "en": .english
        default: nil
        }
    }
}

/// Third-language script categories the gate must never let through.
enum ThirdScript: Sendable, Equatable, Hashable {
    case japaneseKana
    case hangul
    case cyrillic
    case georgian
    case arabic
    case hebrew
    case greek
    case thai
    case devanagari
    case other

    var name: String {
        switch self {
        case .japaneseKana: "kana"
        case .hangul: "hangul"
        case .cyrillic: "cyrillic"
        case .georgian: "georgian"
        case .arabic: "arabic"
        case .hebrew: "hebrew"
        case .greek: "greek"
        case .thai: "thai"
        case .devanagari: "devanagari"
        case .other: "other"
        }
    }
}

/// Character-script profile of a transcript string.
struct TranscriptScriptProfile: Equatable, Sendable {
    var hanCharacters: Int = 0
    var latinCharacters: Int = 0
    var thirdScripts: Set<ThirdScript> = []

    var hasHan: Bool { hanCharacters > 0 }
    var hasLatin: Bool { latinCharacters > 0 }
    var hasThirdScript: Bool { !thirdScripts.isEmpty }
    /// Whether the text is Han content (optionally mixed with Latin) and no third script.
    var isChineseContent: Bool { hasHan && !hasThirdScript }

    // Exhaustive Unicode script classification is inherently case-heavy.
    // swiftlint:disable:next cyclomatic_complexity
    static func analyze(_ text: String) -> TranscriptScriptProfile {
        var profile = TranscriptScriptProfile()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF:
                profile.hanCharacters += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                profile.latinCharacters += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                profile.thirdScripts.insert(.japaneseKana)
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                profile.thirdScripts.insert(.hangul)
            case 0x0400...0x04FF:
                profile.thirdScripts.insert(.cyrillic)
            case 0x10A0...0x10FF:
                profile.thirdScripts.insert(.georgian)
            case 0x0600...0x06FF:
                profile.thirdScripts.insert(.arabic)
            case 0x0590...0x05FF:
                profile.thirdScripts.insert(.hebrew)
            case 0x0370...0x03FF:
                profile.thirdScripts.insert(.greek)
            case 0x0E00...0x0E7F:
                profile.thirdScripts.insert(.thai)
            case 0x0900...0x097F:
                profile.thirdScripts.insert(.devanagari)
            default:
                break
            }
        }
        return profile
    }
}
