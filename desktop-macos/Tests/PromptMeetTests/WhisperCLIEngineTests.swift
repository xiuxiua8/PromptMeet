import Foundation
import XCTest
@testable import PromptMeet

final class WhisperCLIEngineTests: XCTestCase {
    func testEnginePassesSelectedModelAndLanguageAndNormalizesOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("whisper-cli")
        let model = root.appendingPathComponent("ggml-small.bin")
        try Data().write(to: executable)
        try Data().write(to: model)
        let runner = WhisperProcessRunnerSpy(output: "  你好，世界。  \n")
        let engine = WhisperCLIEngine(
            executableURL: executable,
            modelURL: model,
            language: "zh",
            temporaryDirectory: root,
            runner: runner
        )

        let text = try await engine.transcribe(
            PCMTranscriptionSegment(source: .microphone, sampleRate: 16_000, samples: [1, 2, 3])
        )

        XCTAssertEqual(text, "你好，世界。")
        let invocation = await runner.invocation
        XCTAssertEqual(invocation?.executable, executable)
        XCTAssertTrue(invocation?.arguments.contains(model.path) == true)
        XCTAssertTrue(invocation?.arguments.contains("zh") == true)
    }
}

private actor WhisperProcessRunnerSpy: WhisperProcessRunning {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var invocation: Invocation?
    private let output: String

    init(output: String) {
        self.output = output
    }

    func run(executable: URL, arguments: [String]) async throws -> String {
        invocation = Invocation(executable: executable, arguments: arguments)
        return output
    }
}
