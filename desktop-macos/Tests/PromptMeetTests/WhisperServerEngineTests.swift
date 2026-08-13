import Foundation
import XCTest
@testable import PromptMeet

final class WhisperServerEngineTests: XCTestCase {
    func testServerArgumentsUsePerUtteranceAutoDetectionAndSuppressNonSpeech() {
        let arguments = WhisperServerEngine.launchArguments(
            modelPath: "/models/large.bin",
            port: 38_178
        )

        XCTAssertTrue(arguments.contains("-nc"))
        XCTAssertTrue(arguments.contains("-sns"))
        XCTAssertTrue(arguments.contains("auto"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-bs")! + 1], "5")
        XCTAssertTrue(arguments.contains("-sow"))
    }

    func testInferenceRequestContainsWaveLanguageAndVerboseJsonResponseFields() throws {
        let endpoint = URL(string: "http://127.0.0.1:38178/inference")!
        let request = WhisperServerRequest.makeInferenceRequest(
            endpoint: endpoint,
            waveData: Data([0, 1, 2]),
            language: "auto",
            boundary: "PromptMeetBoundary"
        )
        let body = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("PromptMeetBoundary") == true)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"segment.wav\""))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nauto"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nverbose_json"))
    }

    func testServerResponseReturnsTrimmedTranscriptAndRejectsFailure() throws {
        let json = #"{"text":"  本地结果 \n","detected_language":"chinese","language_probabilities":"# +
            #"{"zh":0.998,"en":0.002}}"#
        let transcription = try WhisperServerResponse.transcription(
            data: Data(json.utf8),
            statusCode: 200
        )

        XCTAssertEqual(transcription.text, "本地结果")
        XCTAssertEqual(transcription.detectedLanguage, "chinese")
        XCTAssertEqual(transcription.probabilities["zh"] ?? 0, 0.998, accuracy: 0.0001)
        XCTAssertEqual(transcription.probabilities["en"] ?? 0, 0.002, accuracy: 0.0001)

        XCTAssertThrowsError(
            try WhisperServerResponse.transcription(data: Data("failed".utf8), statusCode: 500)
        )
        XCTAssertThrowsError(
            try WhisperServerResponse.transcription(data: Data("not json".utf8), statusCode: 200)
        )
    }
}
