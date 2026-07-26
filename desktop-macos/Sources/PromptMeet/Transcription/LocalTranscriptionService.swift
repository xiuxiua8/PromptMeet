import Foundation

struct LocalTranscript: Equatable, Sendable {
    let id: UUID
    let source: NativeAudioSource
    let text: String
    let timestamp: Date
    let meetingTime: Duration?
    let translationTarget: String?

    init(
        id: UUID = UUID(),
        source: NativeAudioSource,
        text: String,
        timestamp: Date = Date(),
        meetingTime: Duration? = nil,
        translationTarget: String? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.timestamp = timestamp
        self.meetingTime = meetingTime
        self.translationTarget = translationTarget
    }

    var speaker: String {
        switch source {
        case .microphone: "我"
        case .system, .mixed: "会议"
        }
    }
}

protocol LocalTranscriptionServicing: Sendable {
    func start(
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws
    func consume(_ pcm: CapturedPCM) async
    func pause() async
    func stop() async
}

actor LocalTranscriptionService: LocalTranscriptionServicing {
    nonisolated static let defaultSegmentDuration: TimeInterval = 8
    private enum JobKind: Sendable {
        case preview
        case final
    }

    private struct TranscriptionJob: Sendable {
        let kind: JobKind
        let segment: PCMTranscriptionSegment
    }

    private let repository: WhisperModelRepository
    private let preferences: WhisperPreferences
    private let segmentDuration: TimeInterval
    private var segmenter: PCMTranscriptionSegmenter
    private var engine: (any LocalTranscriptionEngine)?
    private var onPartialTranscript: (@Sendable (String) -> Void)?
    private var onTranscript: (@Sendable (LocalTranscript) -> Void)?
    private var onError: (@Sendable (String) -> Void)?
    private var pendingJobs: [TranscriptionJob] = []
    private var isProcessing = false

    init(
        repository: WhisperModelRepository = WhisperModelRepository(),
        preferences: WhisperPreferences = WhisperPreferences(),
        segmentDuration: TimeInterval = LocalTranscriptionService.defaultSegmentDuration
    ) {
        self.repository = repository
        self.preferences = preferences
        self.segmentDuration = segmentDuration
        segmenter = PCMTranscriptionSegmenter(segmentDuration: segmentDuration)
    }

    func start(
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        try repository.prepareDirectory()
        guard
            let descriptor = WhisperModelCatalog.descriptor(id: preferences.selectedModelID),
            repository.isInstalled(descriptor)
        else {
            throw LocalTranscriptionError.modelNotInstalled
        }
        guard let executableURL = WhisperRuntimeLocator.serverExecutableURL() else {
            throw LocalTranscriptionError.runtimeNotInstalled
        }
        let serverEngine = WhisperServerEngine(
            executableURL: executableURL,
            modelURL: repository.modelURL(for: descriptor),
            language: preferences.language
        )
        try await serverEngine.prepare()
        engine = serverEngine
        self.onPartialTranscript = onPartialTranscript
        self.onTranscript = onTranscript
        self.onError = onError
        segmenter = PCMTranscriptionSegmenter(segmentDuration: segmentDuration)
        pendingJobs = []
    }

    func consume(_ pcm: CapturedPCM) async {
        let update = segmenter.consumeStreaming(pcm)
        if let preview = update.preview {
            enqueuePreview(preview)
        }
        enqueueFinals(update.finalized)
    }

    func stop() async {
        enqueueFinals(segmenter.flush())
        while isProcessing || !pendingJobs.isEmpty {
            try? await Task.sleep(for: .milliseconds(30))
        }
        await engine?.shutdown()
        engine = nil
        onPartialTranscript = nil
        onTranscript = nil
        onError = nil
    }

    func pause() async {
        segmenter.discardBufferedAudio()
        pendingJobs.removeAll {
            if case .preview = $0.kind { return true }
            return false
        }
        onPartialTranscript?("")
    }

    private func enqueuePreview(_ segment: PCMTranscriptionSegment) {
        pendingJobs.removeAll {
            if case .preview = $0.kind {
                return $0.segment.source == segment.source
            }
            return false
        }
        pendingJobs.append(TranscriptionJob(kind: .preview, segment: segment))
        beginProcessingIfNeeded()
    }

    private func enqueueFinals(_ segments: [PCMTranscriptionSegment]) {
        guard !segments.isEmpty else { return }
        let sources = Set(segments.map(\.source))
        pendingJobs.removeAll {
            if case .preview = $0.kind {
                return sources.contains($0.segment.source)
            }
            return false
        }
        pendingJobs.append(contentsOf: segments.map { TranscriptionJob(kind: .final, segment: $0) })
        beginProcessingIfNeeded()
    }

    private func beginProcessingIfNeeded() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { await drainQueue() }
    }

    private func drainQueue() async {
        while !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            guard let engine else { continue }
            do {
                let text = try await engine.transcribe(job.segment)
                switch job.kind {
                case .preview:
                    if Self.containsContent(text) {
                        onPartialTranscript?(text)
                    }
                case .final:
                    if Self.containsContent(text) {
                        onTranscript?(
                            LocalTranscript(
                                source: job.segment.source,
                                text: text,
                                timestamp: job.segment.capturedAt,
                                meetingTime: job.segment.meetingTime,
                                translationTarget: preferences.translationEnabled
                                    ? preferences.translationTargetLanguage
                                    : nil
                            )
                        )
                    }
                    onPartialTranscript?("")
                }
            } catch {
                onError?(error.localizedDescription)
            }
        }
        isProcessing = false
    }

    private static func containsContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

actor NoopLocalTranscriptionService: LocalTranscriptionServicing {
    func start(
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {}
    func consume(_ pcm: CapturedPCM) async {}
    func pause() async {}
    func stop() async {}
}
