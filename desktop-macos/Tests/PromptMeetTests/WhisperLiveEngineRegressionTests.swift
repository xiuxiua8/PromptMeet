import Foundation
import XCTest
@testable import PromptMeet

/// Live regression for the ASR language contract, reproducing the exact
/// end-user failure modes on the real packaged whisper engine:
/// - Chinese audio must produce Simplified Chinese (zh), never Traditional-only.
/// - English audio must produce English (en).
/// - Mixed speech keeps both languages; no third-language output may surface.
///
/// Requires:
///   PROMPTMEET_LIVE_WHISPER_TESTS=1
///   PROMPTMEET_WHISPER_MODEL=/path/to/ggml-*.bin
///   PROMPTMEET_WHISPER_FIXTURES=/dir/with/16k-mono-wav-fixtures
/// Fixtures are generated deterministically and must never be committed.
final class WhisperLiveEngineRegressionTests: XCTestCase {
    private static let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipUnless(
            Self.environment["PROMPTMEET_LIVE_WHISPER_TESTS"] == "1",
            "live engine regression requires PROMPTMEET_LIVE_WHISPER_TESTS=1"
        )
        try XCTSkipUnless(
            Self.environment["PROMPTMEET_WHISPER_MODEL"] != nil,
            "live engine regression requires PROMPTMEET_WHISPER_MODEL"
        )
        try XCTSkipUnless(
            Self.environment["PROMPTMEET_WHISPER_FIXTURES"] != nil,
            "live engine regression requires PROMPTMEET_WHISPER_FIXTURES"
        )
    }

    private var executableURL: URL {
        WhisperRuntimeLocator.serverExecutableURL()!
    }

    private var modelURL: URL {
        URL(fileURLWithPath: Self.environment["PROMPTMEET_WHISPER_MODEL"]!)
    }

    private func gatedEngine() -> WhisperLanguageGatedEngine {
        WhisperLanguageGatedEngine(
            underlying: WhisperServerEngine(
                executableURL: executableURL,
                modelURL: modelURL
            ),
            preference: .auto
        )
    }

    private func segment(from wavURL: URL) throws -> PCMTranscriptionSegment {
        let data = try Data(contentsOf: wavURL)
        let header = WAVHeaderParser.parse(data)
        XCTAssertEqual(header.sampleRate, 16_000)
        XCTAssertEqual(header.channelCount, 1)
        return PCMTranscriptionSegment(
            source: .system,
            sampleRate: header.sampleRate,
            samples: Array(header.samples)
        )
    }

    private func fixture(_ name: String) -> URL? {
        let root = URL(
            fileURLWithPath: Self.environment["PROMPTMEET_WHISPER_FIXTURES"]!
        )
        return root.appendingPathComponent(name)
    }

    // MARK: - Contract: every utterance is gated to zh or en (or dropped)

    func testNoFixtureEverProducesThirdLanguageText() async throws {
        let engine = gatedEngine()
        try await engine.prepare()
        defer { Task { await engine.shutdown() } }

        let fixtures = [
            "zh-only.wav",
            "en-only.wav",
            "mixed-zh-en.wav",
            "mixed-en-zh.wav",
            "zh-short-noisy8s.wav",
            "en-ok-noisy8s.wav",
            "noise-only8s.wav",
            "ja-only.wav"
        ]
        for name in fixtures {
            guard let url = fixture(name) else { continue }
            let result = try await engine.gated(
                try segment(from: url),
                majorityHint: .chinese
            )
            switch result {
            case .accepted(let transcript):
                let profile = TranscriptScriptProfile.analyze(transcript.text)
                XCTAssertFalse(
                    profile.hasThirdScript,
                    "\(name) surfaced third-language text: \(transcript.text)"
                )
                XCTAssertTrue(
                    transcript.language == .chinese || transcript.language == .english,
                    "\(name) produced unexpected language \(transcript.language)"
                )
            case .dropped:
                break
            }
        }
    }

    func testChineseSpeechProducesSimplifiedChinese() async throws {
        try XCTSkipUnless(fixture("zh-only.wav") != nil, "missing zh-only.wav")
        let engine = gatedEngine()
        try await engine.prepare()
        defer { Task { await engine.shutdown() } }

        let result = try await engine.gated(
            try segment(from: fixture("zh-only.wav")!),
            majorityHint: .chinese
        )

        guard case .accepted(let transcript) = result else {
            return XCTFail("zh-only expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .chinese)
        // The exact simplified string depends on the model, but the output must
        // not contain Traditional-only characters (會議/討論/項目/進度/計劃).
        let simplified = SimplifiedChineseNormalizer.normalize(transcript.text)
        XCTAssertEqual(transcript.text, simplified, "zh output must already be Simplified Chinese")
        XCTAssertTrue(transcript.text.contains("会议"), "expected meeting vocabulary, got \(transcript.text)")
    }

    func testEnglishSpeechProducesEnglish() async throws {
        try XCTSkipUnless(fixture("en-only.wav") != nil, "missing en-only.wav")
        let engine = gatedEngine()
        try await engine.prepare()
        defer { Task { await engine.shutdown() } }

        let result = try await engine.gated(
            try segment(from: fixture("en-only.wav")!),
            majorityHint: .chinese
        )

        guard case .accepted(let transcript) = result else {
            return XCTFail("en-only expected accepted, got \(result)")
        }
        XCTAssertEqual(transcript.language, .english)
        XCTAssertTrue(
            transcript.text.lowercased().contains("meeting"),
            "expected English transcript, got \(transcript.text)"
        )
    }

    func testJapaneseAudioNeverSurfacesAsJapaneseText() async throws {
        try XCTSkipUnless(fixture("ja-only.wav") != nil, "missing ja-only.wav")
        let engine = gatedEngine()
        try await engine.prepare()
        defer { Task { await engine.shutdown() } }

        let result = try await engine.gated(
            try segment(from: fixture("ja-only.wav")!),
            majorityHint: .chinese
        )

        switch result {
        case .accepted(let transcript):
            let profile = TranscriptScriptProfile.analyze(transcript.text)
            XCTAssertFalse(
                profile.thirdScripts.contains(.japaneseKana),
                "Japanese kana must never surface: \(transcript.text)"
            )
        case .dropped:
            break
        }
    }
}

private struct WAVHeaderParser {
    struct ParsedWAV {
        let sampleRate: Int
        let channelCount: Int
        let samples: [Int16]
    }

    static func parse(_ data: Data) -> ParsedWAV {
        precondition(data.count >= 44)
        let byteArray = [UInt8](data)
        let littleEndian = { (offset: Int, count: Int) -> Int in
            var value = 0
            for index in 0..<count {
                value |= Int(byteArray[offset + index]) << (8 * index)
            }
            return value
        }
        let channels = littleEndian(22, 2)
        let rate = littleEndian(24, 4)
        let bitsPerSample = littleEndian(34, 2)
        var samples: [Int16] = []
        if bitsPerSample == 16 {
            var offset = 44
            while offset + 2 <= data.count {
                let sample = Int16(
                    bitPattern: UInt16(byteArray[offset]) | UInt16(byteArray[offset + 1]) << 8
                )
                samples.append(sample)
                offset += 2
            }
        }
        return ParsedWAV(sampleRate: rate, channelCount: channels, samples: samples)
    }
}
