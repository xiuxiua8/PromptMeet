import Foundation

protocol WhisperProcessRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> String
}

struct FoundationWhisperProcessRunner: WhisperProcessRunning {
    func run(executable: URL, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: error, encoding: .utf8) ?? "退出码 \(process.terminationStatus)"
                throw LocalTranscriptionError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(data: output, encoding: .utf8) ?? ""
        }.value
    }
}

struct WhisperCLIEngine<Runner: WhisperProcessRunning>: LocalTranscriptionEngine {
    let executableURL: URL
    let modelURL: URL
    let language: String
    let temporaryDirectory: URL
    let runner: Runner

    init(
        executableURL: URL,
        modelURL: URL,
        language: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: Runner
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.language = language
        self.temporaryDirectory = temporaryDirectory
        self.runner = runner
    }

    func transcribe(
        _ segment: PCMTranscriptionSegment,
        language requestLanguage: String
    ) async throws -> RawWhisperTranscription {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LocalTranscriptionError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalTranscriptionError.modelNotInstalled
        }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let audioURL = temporaryDirectory.appendingPathComponent("promptmeet-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try PCM16WaveWriter.write(segment, to: audioURL)

        let output = try await runner.run(
            executable: executableURL,
            arguments: [
                "-m", modelURL.path,
                "-f", audioURL.path,
                "-l", requestLanguage,
                "-nt",
                "-np"
            ]
        )
        let text = Self.normalized(output)
        return RawWhisperTranscription(
            text: text,
            detectedLanguage: nil,
            probabilities: [:]
        )
    }

    private static func normalized(_ output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("whisper_") && !$0.hasPrefix("ggml_") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension WhisperCLIEngine where Runner == FoundationWhisperProcessRunner {
    init(executableURL: URL, modelURL: URL, language: String) {
        self.init(
            executableURL: executableURL,
            modelURL: modelURL,
            language: language,
            temporaryDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PromptMeet/transcription", isDirectory: true),
            runner: FoundationWhisperProcessRunner()
        )
    }
}

enum WhisperRuntimeLocator {
    static func executableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["PROMPTMEET_WHISPER_CLI"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("whisper/bin/whisper-cli")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/whisper/bin/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
    }

    static func serverExecutableURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = environment["PROMPTMEET_WHISPER_SERVER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("whisper/bin/whisper-server")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/whisper/bin/whisper-server")
        return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
    }
}
