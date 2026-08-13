import Foundation

/// A single utterance transcription with its gated language.
struct WhisperLanguageTranscript: Equatable, Sendable {
    let text: String
    let language: TranscriptLanguage
}

/// Raw per-utterance engine output plus whisper's own detection signal.
struct RawWhisperTranscription: Equatable, Sendable {
    let text: String
    /// Full whisper language name (e.g. "chinese", "english"); nil when unknown
    /// (CLI engine) or absent from the response.
    let detectedLanguage: String?
    /// whisper language id -> probability, e.g. ["zh": 0.877].
    let probabilities: [String: Double]

    static func plain(_ text: String) -> RawWhisperTranscription {
        RawWhisperTranscription(text: text, detectedLanguage: nil, probabilities: [:])
    }
}

/// Per-utterance language gating so recognized text is always Simplified
/// Chinese or English (never a third language).
///
/// The gate trusts whisper's own per-utterance detection (the `detected_language`
/// field and `language_probabilities` from the verbose_json response) for retry
/// hints, and validates the OUTPUT script so a wrong detection can never surface
/// third-language or random text. Retrying uses the utterance's own signal first,
/// the majority of recently accepted utterances second, and the product default
/// (zh) last - never a single global flag.
enum WhisperLanguageGate {
    struct Input: Equatable, Sendable {
        var raw: RawWhisperTranscription
        /// Language of the majority of recently accepted finals; default .chinese.
        var majorityHint: TranscriptLanguage = .chinese
    }

    enum Decision: Equatable, Sendable {
        case accept(WhisperLanguageTranscript)
        /// Retry the same utterance with the given forced language hint.
        case retry(TranscriptLanguage)
        /// Give up on the utterance: its output could not be gated to zh/en.
        case drop(Reason)
    }

    enum Reason: Equatable, Sendable {
        case empty
        case thirdLanguageAfterRetry
        case unmatchedScriptAfterRetry
    }

    /// Minimum probability for a detection/probability signal to be trusted
    /// when choosing a retry hint.
    static let hintProbabilityThreshold: Double = 0.2
    /// Ratio the leading zh/en candidate must hold over the other before it wins.
    static let hintProbabilityMargin: Double = 2.0

    static func decide(_ input: Input) -> Decision {
        let raw = input.raw
        let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .drop(.empty) }

        let profile = TranscriptScriptProfile.analyze(text)
        let detected = TranscriptLanguage.fromWhisperFullName(raw.detectedLanguage)

        if profile.hasThirdScript {
            // Third-script output (kana, hangul, Georgian, ...) or Han contaminated
            // by a third script: never surface it - retry with the best hint.
            return .retry(hint(for: raw, majority: input.majorityHint))
        }

        if profile.hasHan, profile.hasLatin {
            // Code-switched utterance: the dominant script wins, and Han text is
            // normalized to Simplified Chinese while the English part is kept.
            let normalized = SimplifiedChineseNormalizer.normalize(text)
            let language: TranscriptLanguage =
                profile.hanCharacters >= profile.latinCharacters ? .chinese : .english
            return .accept(WhisperLanguageTranscript(text: normalized, language: language))
        }

        if profile.isChineseContent {
            let normalized = SimplifiedChineseNormalizer.normalize(text)
            return .accept(
                WhisperLanguageTranscript(text: normalized, language: .chinese)
            )
        }

        // Latin-only output. Accept as English unless whisper's own audio
        // detection says the utterance was Chinese (pinyin/transliteration
        // of Chinese speech): that is a retry with the zh hint.
        if profile.hasLatin {
            if detected == .chinese {
                return .retry(.chinese)
            }
            return .accept(WhisperLanguageTranscript(text: text, language: .english))
        }

        return .drop(.empty)
    }

    /// Choose the forced-language hint for a retry, using per-utterance signals
    /// before the rolling majority.
    static func hint(
        for raw: RawWhisperTranscription,
        majority: TranscriptLanguage
    ) -> TranscriptLanguage {
        if let detected = TranscriptLanguage.fromWhisperFullName(raw.detectedLanguage) {
            return detected
        }
        let chinese = TranscriptLanguage.fromWhisperCode(
            mostLikelyCode(in: raw.probabilities, among: [.chinese, .english])
        )
        if let chinese {
            return chinese
        }
        return majority
    }

    private static func mostLikelyCode(
        in probabilities: [String: Double],
        among candidates: [TranscriptLanguage]
    ) -> String? {
        var best: (code: String, probability: Double)?
        for candidate in candidates {
            let code = candidate.whisperCode
            let probability = probabilities[code] ?? 0
            guard probability >= hintProbabilityThreshold else { continue }
            if let current = best {
                if probability > current.probability {
                    best = (code, probability)
                }
            } else {
                best = (code, probability)
            }
        }
        guard let best else { return nil }
        for candidate in candidates {
            let code = candidate.whisperCode
            if code != best.code {
                let other = probabilities[code] ?? 0
                if best.probability < other * hintProbabilityMargin {
                    // Too close to decide from probabilities alone.
                    return nil
                }
            }
        }
        return best.code
    }
}
