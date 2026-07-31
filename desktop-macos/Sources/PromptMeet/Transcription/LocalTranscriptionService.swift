import Foundation
import os

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
    onSignalState: @escaping @Sendable (NativeAudioSource, AudioSignalState) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws
  func consume(_ pcm: CapturedPCM) async
  func pause() async
  func stop() async
}

actor LocalTranscriptionService: LocalTranscriptionServicing {
  nonisolated static let defaultSegmentDuration: TimeInterval = 8
  private nonisolated static let systemAudioInactivityDuration = Duration.milliseconds(600)
  private static let logger = Logger(
    subsystem: "com.promptmeet.desktop",
    category: "speech-gate"
  )

  private enum JobKind: Sendable {
    case preview
    case final
  }

  private struct TranscriptionJob: Sendable {
    let kind: JobKind
    let segment: PCMTranscriptionSegment
    let generation: UInt64
  }

  private let engineFactory: any LocalTranscriptionEngineBuilding
  private let preferences: WhisperPreferences
  private let segmentDuration: TimeInterval
  private var segmenter: PCMTranscriptionSegmenter
  private var engine: (any LocalTranscriptionEngine)?
  private var onPartialTranscript: (@Sendable (String) -> Void)?
  private var onTranscript: (@Sendable (LocalTranscript) -> Void)?
  private var onSignalState: (@Sendable (NativeAudioSource, AudioSignalState) -> Void)?
  private var onError: (@Sendable (String) -> Void)?
  private var pendingJobs: [TranscriptionJob] = []
  private var processingTask: Task<Void, Never>?
  private var inactivityTasks: [NativeAudioSource: Task<Void, Never>] = [:]
  private var activeGeneration: UInt64 = 0

  init(
    repository: WhisperModelRepository = WhisperModelRepository(),
    preferences: WhisperPreferences = WhisperPreferences(),
    segmentDuration: TimeInterval = LocalTranscriptionService.defaultSegmentDuration
  ) {
    engineFactory = WhisperServerEngineBuilder(
      repository: repository,
      preferences: preferences
    )
    self.preferences = preferences
    self.segmentDuration = segmentDuration
    segmenter = PCMTranscriptionSegmenter(segmentDuration: segmentDuration)
  }

  init(
    engineFactory: any LocalTranscriptionEngineBuilding,
    preferences: WhisperPreferences = WhisperPreferences(),
    segmentDuration: TimeInterval = LocalTranscriptionService.defaultSegmentDuration
  ) {
    self.engineFactory = engineFactory
    self.preferences = preferences
    self.segmentDuration = segmentDuration
    segmenter = PCMTranscriptionSegmenter(segmentDuration: segmentDuration)
  }

  func start(
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onSignalState: @escaping @Sendable (NativeAudioSource, AudioSignalState) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    let newEngine = try engineFactory.makeEngine()
    try await newEngine.prepare()
    invalidateCurrentWork()
    engine = newEngine
    self.onPartialTranscript = onPartialTranscript
    self.onTranscript = onTranscript
    self.onSignalState = onSignalState
    self.onError = onError
    segmenter = PCMTranscriptionSegmenter(segmentDuration: segmentDuration)
  }

  func consume(_ pcm: CapturedPCM) async {
    let update = segmenter.consumeStreaming(pcm)
    if let signalTransition = update.signalTransition {
      onSignalState?(pcm.source, signalTransition)
    }
    if let preview = update.preview {
      enqueuePreview(preview)
    }
    enqueueFinals(update.finalized)
    scheduleInactivityClose(for: pcm.source)
  }

  func stop() async {
    logDiagnostics(boundary: "stop")
    segmenter.discardBufferedAudio()
    invalidateCurrentWork()
    let engineToStop = engine
    engine = nil
    onPartialTranscript = nil
    onTranscript = nil
    onSignalState = nil
    onError = nil
    await engineToStop?.shutdown()
  }

  func pause() async {
    logDiagnostics(boundary: "pause")
    segmenter.discardBufferedAudio()
    invalidateCurrentWork()
    onPartialTranscript?("")
  }

  private func enqueuePreview(_ segment: PCMTranscriptionSegment) {
    pendingJobs.removeAll {
      if case .preview = $0.kind {
        return $0.segment.source == segment.source
      }
      return false
    }
    pendingJobs.append(
      TranscriptionJob(
        kind: .preview,
        segment: segment,
        generation: activeGeneration
      )
    )
    beginProcessingIfNeeded()
  }

  private func scheduleInactivityClose(for source: NativeAudioSource) {
    guard source == .system else { return }
    inactivityTasks[source]?.cancel()
    let generation = activeGeneration
    inactivityTasks[source] = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.systemAudioInactivityDuration)
      } catch {
        return
      }
      await self?.finishInactiveSource(source, generation: generation)
    }
  }

  private func finishInactiveSource(_ source: NativeAudioSource, generation: UInt64) {
    guard generation == activeGeneration else { return }
    inactivityTasks[source] = nil
    let update = segmenter.finishInactiveSource(source)
    if let signalTransition = update.signalTransition {
      onSignalState?(source, signalTransition)
    }
    enqueueFinals(update.finalized)
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
    pendingJobs.append(
      contentsOf: segments.map {
        TranscriptionJob(
          kind: .final,
          segment: $0,
          generation: activeGeneration
        )
      })
    beginProcessingIfNeeded()
  }

  private func beginProcessingIfNeeded() {
    guard processingTask == nil, !pendingJobs.isEmpty else { return }
    let generation = activeGeneration
    processingTask = Task { [weak self] in
      await self?.drainQueue(generation: generation)
    }
  }

  private func drainQueue(generation: UInt64) async {
    while !Task.isCancelled,
      generation == activeGeneration,
      !pendingJobs.isEmpty {
      let job = pendingJobs.removeFirst()
      guard job.generation == generation, let engine else { continue }
      do {
        let text = try await engine.transcribe(job.segment)
        guard
          !Task.isCancelled,
          generation == activeGeneration,
          job.generation == activeGeneration
        else {
          return
        }
        publish(text, for: job)
      } catch is CancellationError {
        return
      } catch {
        guard generation == activeGeneration else { return }
        onError?(error.localizedDescription)
      }
    }
    guard generation == activeGeneration else { return }
    processingTask = nil
    beginProcessingIfNeeded()
  }

  private func publish(_ text: String, for job: TranscriptionJob) {
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
  }

  private func invalidateCurrentWork() {
    activeGeneration &+= 1
    pendingJobs = []
    for task in inactivityTasks.values {
      task.cancel()
    }
    inactivityTasks = [:]
    processingTask?.cancel()
    processingTask = nil
  }

  private func logDiagnostics(boundary: String) {
    for source in [NativeAudioSource.microphone, .system] {
      let counters = segmenter.diagnostics(for: source)
      guard counters.analyzedFrames > 0 else { continue }
      let sourceName = source.rawValue
      let analyzed = counters.analyzedFrames
      let accepted = counters.acceptedSpeechFrames
      let droppedSilence = counters.droppedSilenceFrames
      let droppedNoise = counters.droppedNoiseFrames
      let utterances = counters.utterances
      let diagnosticSummary =
        "boundary=\(boundary) source=\(sourceName) analyzed=\(analyzed) accepted=\(accepted) "
        + "dropped_silence=\(droppedSilence) dropped_noise=\(droppedNoise) utterances=\(utterances)"
      Self.logger.info("\(diagnosticSummary, privacy: .public)")
    }
  }

  private static func containsContent(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }
}

actor NoopLocalTranscriptionService: LocalTranscriptionServicing {
  func start(
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onSignalState: @escaping @Sendable (NativeAudioSource, AudioSignalState) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {}
  func consume(_ pcm: CapturedPCM) async {}
  func pause() async {}
  func stop() async {}
}
