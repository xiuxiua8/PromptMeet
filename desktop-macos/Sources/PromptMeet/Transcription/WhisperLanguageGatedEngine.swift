import Foundation

/// Result of a gated transcription attempt.
enum GatedTranscription: Equatable, Sendable {
    case accepted(WhisperLanguageTranscript)
    case dropped(WhisperLanguageGate.Reason)
}

/// User-facing language preference for local transcription.
///
/// Only the gated flow ("auto", "zh", "en") enforces the zh/en output contract.
/// Explicit third-language selections (e.g. ja/ko in settings) are honored as
/// the user's deliberate choice and pass through ungated.
enum WhisperLanguagePreference: Sendable, Equatable {
    case auto
    case gated(TranscriptLanguage)
    case explicit(String)

    init(rawValue: String) {
        switch rawValue {
        case "auto": self = .auto
        case "zh": self = .gated(.chinese)
        case "en": self = .gated(.english)
        default: self = .explicit(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .auto: "auto"
        case .gated(let language): language.whisperCode
        case .explicit(let value): value
        }
    }
}

/// Wraps any `LocalTranscriptionEngine` with per-utterance language gating:
/// primary pass, script validation, one retry with a per-utterance hint, and a
/// final drop instead of ever surfacing third-language or random output.
struct WhisperLanguageGatedEngine: Sendable {
    private let underlying: any LocalTranscriptionEngine
    private let preference: WhisperLanguagePreference

    init(
        underlying: any LocalTranscriptionEngine,
        preference: WhisperLanguagePreference
    ) {
        self.underlying = underlying
        self.preference = preference
    }

    func prepare() async throws {
        try await underlying.prepare()
    }

    func shutdown() async {
        await underlying.shutdown()
    }

    /// Per-utterance gated transcription. `majorityHint` is the rolling language
    /// of recently accepted finals, provided by the caller per utterance.
    func gated(
        _ segment: PCMTranscriptionSegment,
        majorityHint: TranscriptLanguage
    ) async throws -> GatedTranscription {
        switch preference {
        case .explicit:
            // User deliberately chose a third language: pass through ungated
            // (no normalization - T2S must never rewrite non-Chinese text).
            let raw = try await underlying.transcribe(
                segment,
                language: preference.rawValue
            )
            return .accepted(
                WhisperLanguageTranscript(
                    text: raw.text,
                    language: .english
                )
            )
        case .auto, .gated:
            let first = try await underlying.transcribe(
                segment,
                language: primaryLanguage
            )
            let decision = WhisperLanguageGate.decide(
                WhisperLanguageGate.Input(
                    raw: first,
                    majorityHint: majorityHint
                )
            )
            switch decision {
            case .accept(let transcript):
                return .accepted(transcript)
            case .retry(let hint):
                let second = try await underlying.transcribe(
                    segment,
                    language: hint.whisperCode
                )
                let retryDecision = WhisperLanguageGate.decide(
                    WhisperLanguageGate.Input(
                        raw: second,
                        majorityHint: majorityHint
                    )
                )
                switch retryDecision {
                case .accept(let transcript):
                    return .accepted(transcript)
                case .retry:
                    // The retried pass still cannot be gated to zh/en.
                    return .dropped(.unmatchedScriptAfterRetry)
                case .drop(let reason):
                    return .dropped(reason)
                }
            case .drop(let reason):
                return .dropped(reason)
            }
        }
    }

    /// The primary pass language: "auto" detects per utterance; an explicit
    /// zh/en preference forces that language for the first pass.
    private var primaryLanguage: String {
        switch preference {
        case .auto: "auto"
        case .gated(let language): language.whisperCode
        case .explicit(let value): value
        }
    }
}
