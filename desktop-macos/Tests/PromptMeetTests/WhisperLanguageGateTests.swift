import Foundation
import XCTest
@testable import PromptMeet

final class WhisperLanguageGateTests: XCTestCase {
    private func input(
        text: String,
        detected: String? = nil,
        probabilities: [String: Double] = [:],
        majority: TranscriptLanguage = .chinese
    ) -> WhisperLanguageGate.Input {
        WhisperLanguageGate.Input(
            raw: RawWhisperTranscription(
                text: text,
                detectedLanguage: detected,
                probabilities: probabilities
            ),
            majorityHint: majority
        )
    }

    // MARK: - Accept: zh-only, en-only, mixed

    func testSimplifiedChineseAcceptsZhAndStaysSimplified() {
        let decision = WhisperLanguageGate.decide(input(text: "今天下午的会议主要讨论了项目进度。"))

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        XCTAssertEqual(transcript.text, "今天下午的会议主要讨论了项目进度。")
    }

    func testTraditionalChineseAcceptsZhAndNormalizesToSimplified() {
        let decision = WhisperLanguageGate.decide(input(text: "今天下午的會議主要討論了項目進度和下一步計劃。"))

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        XCTAssertEqual(transcript.text, "今天下午的会议主要讨论了项目进度和下一步计划。")
    }

    func testEnglishAcceptsEn() {
        let decision = WhisperLanguageGate.decide(
            input(text: "The meeting covered the project timeline.", detected: "english")
        )

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .english)
        XCTAssertEqual(transcript.text, "The meeting covered the project timeline.")
    }

    func testEnglishAcceptsEnWithoutDetectionSignal() {
        let decision = WhisperLanguageGate.decide(input(text: "OK, let's move on."))

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .english)
    }

    func testCodeSwitchedUtteranceAcceptsZhAndPreservesEnglish() {
        let decision = WhisperLanguageGate.decide(
            input(text: "這個季度我們完成了主要功能，接下來我們討論一下時間安排,OK")
        )

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        XCTAssertEqual(transcript.text, "这个季度我们完成了主要功能，接下来我们讨论一下时间安排,OK")
    }

    func testEnglishDominantCodeSwitchAcceptsEn() {
        let decision = WhisperLanguageGate.decide(
            input(text: "We shipped the dashboard last week,上周我们发布了新的仪表盘。")
        )

        guard case .accept(let transcript) = decision else {
            return XCTFail("expected accept, got \(decision)")
        }
        XCTAssertEqual(transcript.language, .english)
    }

    // MARK: - Third-language rejection and retry

    func testGeorgianNoiseOutputRetriesWithDetectedEnglishHint() {
        // noise-only segment: whisper detected english with low confidence and
        // the small model hallucinated Georgian script
        let decision = WhisperLanguageGate.decide(
            input(
                text: "ლლლლლლლ",
                detected: "english",
                probabilities: ["en": 0.546, "ru": 0.113, "ja": 0.05]
            )
        )

        XCTAssertEqual(decision, .retry(.english))
    }

    func testJapaneseOutputRetriesWithChineseHintWhenDetected() {
        // short Chinese speech misdetected as Japanese
        let decision = WhisperLanguageGate.decide(
            input(
                text: "今日の会議は終了しました。",
                detected: "japanese",
                probabilities: ["ja": 0.88, "zh": 0.07, "en": 0.02]
            )
        )

        // no zh/en detection; probabilities for zh/en too low -> majority (zh)
        XCTAssertEqual(decision, .retry(.chinese))
    }

    func testJapaneseOutputRetriesWithEnglishHintWhenProbabilitiesDecide() {
        let decision = WhisperLanguageGate.decide(
            input(
                text: "すみません、ちょっと待ってください。",
                detected: "japanese",
                probabilities: ["ja": 0.6, "en": 0.35, "zh": 0.03]
            )
        )

        XCTAssertEqual(decision, .retry(.english))
    }

    func testHanContaminatedWithKanaRetriesWithDetectedChinese() {
        let decision = WhisperLanguageGate.decide(
            input(
                text: "会议を開きます",
                detected: "chinese",
                probabilities: ["zh": 0.9]
            )
        )

        XCTAssertEqual(decision, .retry(.chinese))
    }

    func testLatinOnlyOutputWithChineseDetectionRetriesZh() {
        // Chinese audio that whisper emitted as Latin (pinyin/transliteration)
        let decision = WhisperLanguageGate.decide(
            input(text: "jin tian xia wu de hui yi", detected: "chinese")
        )

        XCTAssertEqual(decision, .retry(.chinese))
    }

    func testEmptyOutputDrops() {
        XCTAssertEqual(
            WhisperLanguageGate.decide(input(text: "   \n")),
            .drop(.empty)
        )
    }

    // MARK: - Retry outcome on second pass

    func testRetrySecondPassAccept() {
        let first = WhisperLanguageGate.decide(
            input(text: "ლლლლლ", detected: "english")
        )
        guard case .retry(let hint) = first else {
            return XCTFail("expected retry, got \(first)")
        }

        let second = WhisperLanguageGate.decide(
            input(
                text: "今天下午的会议主要讨论了项目进度。",
                detected: "chinese",
                majority: hint
            )
        )
        guard case .accept(let transcript) = second else {
            return XCTFail("expected accept, got \(second)")
        }
        XCTAssertEqual(transcript.language, .chinese)
    }

    func testRetrySecondPassStillThirdLanguageDrops() {
        let first = WhisperLanguageGate.decide(
            input(text: "ლლლლლ", detected: "english")
        )
        guard case .retry(let hint) = first else {
            return XCTFail("expected retry, got \(first)")
        }

        let second = WhisperLanguageGate.decide(
            input(text: "ㅎㅎㅎㅎ", detected: "korean", majority: hint)
        )
        // The gate still cannot gate the retried output; the engine wrapper is
        // what converts this into a final drop.
        XCTAssertEqual(second, .retry(.english))
    }

    // MARK: - Hint selection

    func testHintPrefersDetectedZhEn() {
        XCTAssertEqual(
            WhisperLanguageGate.hint(
                for: RawWhisperTranscription(
                    text: "",
                    detectedLanguage: "english",
                    probabilities: [:]
                ),
                majority: .chinese
            ),
            .english
        )
        XCTAssertEqual(
            WhisperLanguageGate.hint(
                for: RawWhisperTranscription(
                    text: "",
                    detectedLanguage: "chinese",
                    probabilities: [:]
                ),
                majority: .english
            ),
            .chinese
        )
    }

    func testHintFallsBackToMajorityWhenDetectionIsThirdLanguageAndProbabilitiesFlat() {
        XCTAssertEqual(
            WhisperLanguageGate.hint(
                for: RawWhisperTranscription(
                    text: "",
                    detectedLanguage: "japanese",
                    probabilities: ["ja": 0.9, "en": 0.02, "zh": 0.01]
                ),
                majority: .chinese
            ),
            .chinese
        )
    }

    func testHintUsesProbabilityLeaderWhenNoZhEnDetection() {
        XCTAssertEqual(
            WhisperLanguageGate.hint(
                for: RawWhisperTranscription(
                    text: "",
                    detectedLanguage: "japanese",
                    probabilities: ["ja": 0.6, "en": 0.35, "zh": 0.03]
                ),
                majority: .chinese
            ),
            .english
        )
    }

    func testHintDefaultsToZhForFirstUtterance() {
        XCTAssertEqual(
            WhisperLanguageGate.hint(
                for: RawWhisperTranscription.plain(""),
                majority: .chinese
            ),
            .chinese
        )
    }
}
