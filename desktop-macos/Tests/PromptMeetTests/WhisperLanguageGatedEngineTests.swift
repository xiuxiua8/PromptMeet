import Foundation
import XCTest
@testable import PromptMeet

final class WhisperLanguageGatedEngineTests: XCTestCase {
    private func segment() -> PCMTranscriptionSegment {
        PCMTranscriptionSegment(source: .microphone, sampleRate: 16_000, samples: [1, 2, 3])
    }

    // MARK: - Auto preference

    func testCleanChinesePassesThroughInOneCall() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "今天下午的会议主要讨论了项目进度。",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.998]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(
            underlying: scripted,
            preference: .auto
        )

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        XCTAssertEqual(transcript.text, "今天下午的会议主要讨论了项目进度。")
        let calls = await scripted.calls
        XCTAssertEqual(calls.map(\.language), ["auto"])
    }

    func testTraditionalChineseOutputIsNormalized() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "今天下午的會議主要討論了項目進度。",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.9]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.text, "今天下午的会议主要讨论了项目进度。")
    }

    func testThirdLanguageOutputRetriesWithHintAndAcceptsCleanSecondPass() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "ლლლლლლლ",
                    detectedLanguage: "english",
                    probabilities: ["en": 0.546]
                )),
                ("en", RawWhisperTranscription(
                    text: "The meeting covered the project timeline.",
                    detectedLanguage: "english",
                    probabilities: ["en": 0.9]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .english)
        XCTAssertEqual(transcript.text, "The meeting covered the project timeline.")
        let calls = await scripted.calls
        XCTAssertEqual(calls.map(\.language), ["auto", "en"])
    }

    func testThirdLanguageOutputDropsWhenRetryStillUnacceptable() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "ლლლლლ",
                    detectedLanguage: "english",
                    probabilities: ["en": 0.4]
                )),
                ("en", RawWhisperTranscription(
                    text: "ㅎㅎㅎㅎ",
                    detectedLanguage: "korean",
                    probabilities: ["ko": 0.9]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        XCTAssertEqual(result, .dropped(.unmatchedScriptAfterRetry))
    }

    func testEmptyOutputDropsWithoutRetry() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription.plain(""))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        XCTAssertEqual(result, .dropped(.empty))
        let calls = await scripted.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testLatinOnlyWithChineseDetectionRetriesZh() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "jin tian xia wu de hui yi",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.85]
                )),
                ("zh", RawWhisperTranscription(
                    text: "今天下午的会议",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.99]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.text, "今天下午的会议")
        let calls = await scripted.calls
        XCTAssertEqual(calls.map(\.language), ["auto", "zh"])
    }

    func testEnglishInterjectionDetectedAsChineseIsAcceptedAsChineseContent() async throws {
        // The audio detector can be confidently wrong (English "OK" -> zh);
        // the output is clean Han so the gate cannot distinguish it and the
        // utterance is kept as zh content rather than dropped.
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("auto", RawWhisperTranscription(
                    text: "好的",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.877, "en": 0.093]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .auto)

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        XCTAssertEqual(transcript.text, "好的")
    }

    // MARK: - Explicit preferences

    func testForcedZhPreferenceUsesZhForPrimaryPass() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("zh", RawWhisperTranscription(
                    text: "这个季度我们完成了主要功能，接下来我们讨论一下时间安排,OK",
                    detectedLanguage: "chinese",
                    probabilities: ["zh": 0.9]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(underlying: scripted, preference: .gated(.chinese))

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        let calls = await scripted.calls
        XCTAssertEqual(calls.map(\.language), ["zh"])
    }

    func testExplicitThirdLanguagePreferencePassesThroughUngated() async throws {
        let scripted = ScriptedTranscriptionEngine(
            responses: [
                ("ja", RawWhisperTranscription(
                    text: "今日の会議では、プロジェクトの進捗状況について話し合いました。",
                    detectedLanguage: "japanese",
                    probabilities: ["ja": 0.99]
                ))
            ]
        )
        let engine = WhisperLanguageGatedEngine(
            underlying: scripted,
            preference: .explicit("ja")
        )

        let result = try await engine.gated(segment(), majorityHint: .chinese)

        guard case .accepted(let transcript) = result else {
            return XCTFail("expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.text, "今日の会議では、プロジェクトの進捗状況について話し合いました。")
        let calls = await scripted.calls
        XCTAssertEqual(calls.map(\.language), ["ja"])
    }
}

/// Records every (language) request and returns scripted raw transcriptions.
private actor ScriptedTranscriptionEngine: LocalTranscriptionEngine {
    struct Call: Equatable {
        let language: String
    }

    private let responses: [String: RawWhisperTranscription]
    private(set) var calls: [Call] = []

    init(responses: [(String, RawWhisperTranscription)]) {
        self.responses = Dictionary(responses, uniquingKeysWith: { $1 })
    }

    func transcribe(
        _ segment: PCMTranscriptionSegment,
        language: String
    ) async throws -> RawWhisperTranscription {
        calls.append(Call(language: language))
        guard let response = responses[language] else {
            throw LocalTranscriptionError.processFailed("unexpected language \(language)")
        }
        return response
    }
}
