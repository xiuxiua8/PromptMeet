import Foundation

@MainActor
protocol NativeAudioCaptureCoordinating: AnyObject {
    func start(
        sessionID: String,
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onTranscriptionError: @escaping @Sendable (String) -> Void
    ) async throws
    func bindBackendSession(_ sessionID: String) async
    func stop() async
}

@MainActor
final class NativeAudioCaptureCoordinator: NativeAudioCaptureCoordinating {
    private let sources: [NativeAudioSourceCapture]
    private let uploader: NativeAudioUploading
    private let transcription: LocalTranscriptionServicing
    private var pump: NativeAudioPacketPump?
    private var activeSources: [NativeAudioSourceCapture] = []

    init(
        sources: [NativeAudioSourceCapture] = [SystemAudioCapture(), MicrophoneCapture()],
        uploader: NativeAudioUploading = NativeAudioUploader(),
        transcription: LocalTranscriptionServicing = LocalTranscriptionService()
    ) {
        self.sources = sources
        self.uploader = uploader
        self.transcription = transcription
    }

    func start(
        sessionID: String,
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onTranscriptionError: @escaping @Sendable (String) -> Void
    ) async throws {
        try await transcription.start(
            onPartialTranscript: onPartialTranscript,
            onTranscript: onTranscript,
            onError: onTranscriptionError
        )
        let packetPump = NativeAudioPacketPump(uploader: uploader)
        pump = packetPump
        activeSources = []
        var failures: [String] = []
        for source in sources {
            do {
                try await source.start { pcm in
                    Task {
                        try? await packetPump.consume(pcm)
                    }
                    Task {
                        await self.transcription.consume(pcm)
                    }
                }
                activeSources.append(source)
            } catch {
                await source.stop()
                let name = source.source == .system ? "系统音频" : "麦克风"
                let detail = "\(name)不可用，已尝试其他来源：\(error.localizedDescription)"
                failures.append(detail)
                onTranscriptionError(detail)
            }
        }
        guard !activeSources.isEmpty else {
            await transcription.stop()
            pump = nil
            throw CaptureError.noAvailableAudioSource(failures.joined(separator: "；"))
        }
    }

    func bindBackendSession(_ sessionID: String) async {
        await pump?.bind(sessionID: sessionID)
    }

    func stop() async {
        for source in activeSources {
            await source.stop()
        }
        activeSources = []
        await transcription.stop()
        pump = nil
    }
}

@MainActor
final class NoopNativeAudioCaptureCoordinator: NativeAudioCaptureCoordinating {
    func start(
        sessionID: String,
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onTranscriptionError: @escaping @Sendable (String) -> Void
    ) async throws {}
    func bindBackendSession(_ sessionID: String) async {}
    func stop() async {}
}
