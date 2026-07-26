import Foundation
import XCTest
@testable import PromptMeet

final class WhisperServerEngineTests: XCTestCase {
    func testServerArgumentsDisableCrossSegmentContextAndSuppressNonSpeech() {
        let arguments = WhisperServerEngine.launchArguments(
            modelPath: "/models/large.bin",
            language: "zh",
            port: 38_178
        )

        XCTAssertTrue(arguments.contains("-nc"))
        XCTAssertTrue(arguments.contains("-sns"))
        XCTAssertTrue(arguments.contains("zh"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-bs")! + 1], "5")
        XCTAssertTrue(arguments.contains("-sow"))
    }

    func testInferenceRequestContainsWaveLanguageAndTextResponseFields() throws {
        let endpoint = URL(string: "http://127.0.0.1:38178/inference")!
        let request = WhisperServerRequest.makeInferenceRequest(
            endpoint: endpoint,
            waveData: Data([0, 1, 2]),
            language: "zh",
            boundary: "PromptMeetBoundary"
        )
        let body = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.contains("PromptMeetBoundary") == true)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"segment.wav\""))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\ntext"))
    }

    func testServerResponseReturnsTrimmedTranscriptAndRejectsFailure() throws {
        XCTAssertEqual(
            try WhisperServerResponse.transcript(data: Data("  本地结果 \n".utf8), statusCode: 200),
            "本地结果"
        )
        XCTAssertThrowsError(
            try WhisperServerResponse.transcript(data: Data("failed".utf8), statusCode: 500)
        )
    }
}
