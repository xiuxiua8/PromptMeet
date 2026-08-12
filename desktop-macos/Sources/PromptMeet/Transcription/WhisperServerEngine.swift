import Foundation

enum WhisperServerRequest {
    static func makeInferenceRequest(
        endpoint: URL,
        waveData: Data,
        language: String,
        boundary: String = "PromptMeet-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.appendMultipartField(name: "language", value: language, boundary: boundary)
        body.appendMultipartField(name: "response_format", value: "verbose_json", boundary: boundary)
        body.appendMultipartFile(
            name: "file",
            filename: "segment.wav",
            contentType: "audio/wav",
            data: waveData,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }
}

enum WhisperServerResponse {
    static func transcription(data: Data, statusCode: Int) throws -> RawWhisperTranscription {
        guard (200..<300).contains(statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw LocalTranscriptionError.processFailed(message)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String
        else {
            let message = String(data: data, encoding: .utf8) ?? "invalid verbose_json"
            throw LocalTranscriptionError.processFailed(message)
        }
        let detectedLanguage = object["detected_language"] as? String
        var probabilities: [String: Double] = [:]
        if let rawProbabilities = object["language_probabilities"] as? [String: Any] {
            for (key, value) in rawProbabilities {
                if let number = value as? NSNumber {
                    probabilities[key] = number.doubleValue
                }
            }
        }
        return RawWhisperTranscription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: detectedLanguage,
            probabilities: probabilities
        )
    }
}

actor WhisperServerEngine: LocalTranscriptionEngine {
    private let executableURL: URL
    private let modelURL: URL
    private let port: Int
    private let session: URLSession
    private var process: Process?

    init(
        executableURL: URL,
        modelURL: URL,
        port: Int = Int.random(in: 28_000...48_000),
        session: URLSession? = nil
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.port = port
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 240
            self.session = URLSession(configuration: configuration)
        }
    }

    nonisolated static func launchArguments(
        modelPath: String,
        port: Int
    ) -> [String] {
        [
            "-m", modelPath,
            "-l", "auto",
            "-nt",
            "-nc",
            "-sns",
            "-bs", "5",
            "-sow",
            "-nth", "0.65",
            "--host", "127.0.0.1",
            "--port", String(port)
        ]
    }

    func prepare() async throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LocalTranscriptionError.runtimeNotInstalled
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw LocalTranscriptionError.modelNotInstalled
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.launchArguments(
            modelPath: modelURL.path,
            port: port
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        for _ in 0..<300 {
            if !process.isRunning {
                self.process = nil
                throw LocalTranscriptionError.serverStartFailed
            }
            if await isHealthy() {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        process.terminate()
        self.process = nil
        throw LocalTranscriptionError.serverStartFailed
    }

    func transcribe(
        _ segment: PCMTranscriptionSegment,
        language: String
    ) async throws -> RawWhisperTranscription {
        guard process?.isRunning == true else {
            throw LocalTranscriptionError.serverStartFailed
        }
        let request = WhisperServerRequest.makeInferenceRequest(
            endpoint: baseURL.appendingPathComponent("inference"),
            waveData: PCM16WaveWriter.data(samples: segment.samples, sampleRate: segment.sampleRate),
            language: language
        )
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        return try WhisperServerResponse.transcription(data: data, statusCode: response.statusCode)
    }

    func shutdown() async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard
            let (data, response) = try? await session.data(for: request),
            let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return false
        }
        return object["status"] == "ok"
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
