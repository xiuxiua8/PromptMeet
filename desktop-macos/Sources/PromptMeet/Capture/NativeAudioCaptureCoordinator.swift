import Foundation

struct NativeAudioCaptureRequest: Equatable, Sendable {
  let sessionID: String
  let includeLocalMicrophone: Bool
}

@MainActor
protocol NativeAudioCaptureCoordinating: AnyObject {
  func start(
    request: NativeAudioCaptureRequest,
    onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void,
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onTranscriptionError: @escaping @Sendable (String) -> Void
  ) async throws
  func bindBackendSession(_ sessionID: String) async
  func pause() async
  func resume() async throws
  func retry(_ source: NativeAudioSource) async throws
  func stop() async
}

@MainActor
final class NativeAudioCaptureCoordinator: NativeAudioCaptureCoordinating {
  private let sources: [NativeAudioSourceCapture]
  private let uploader: NativeAudioUploading
  private let transcription: LocalTranscriptionServicing
  private var pump: NativeAudioPacketPump?
  private var frameDispatcher: NativeAudioFrameDispatcher?
  private var backendSessionID: String?
  private var activeSources: [NativeAudioSource: NativeAudioSourceCapture] = [:]
  private var resumableSources: Set<NativeAudioSource> = []
  private var snapshot = AudioCaptureSnapshot()
  private var statusHandler: (@Sendable (AudioCaptureSnapshot) -> Void)?
  private var sourceHandler: (@Sendable (CapturedPCM) -> Void)?
  private var transcriptionErrorHandler: (@Sendable (String) -> Void)?
  private var isPaused = false

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
    includeLocalMicrophone: Bool = true,
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onTranscriptionError: @escaping @Sendable (String) -> Void
  ) async throws {
    try await start(
      request: NativeAudioCaptureRequest(
        sessionID: sessionID,
        includeLocalMicrophone: includeLocalMicrophone
      ),
      onStatus: { _ in },
      onPartialTranscript: onPartialTranscript,
      onTranscript: onTranscript,
      onTranscriptionError: onTranscriptionError
    )
  }

  func start(
    request: NativeAudioCaptureRequest,
    onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void,
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onTranscriptionError: @escaping @Sendable (String) -> Void
  ) async throws {
    try await transcription.start(
      onPartialTranscript: onPartialTranscript,
      onTranscript: onTranscript,
      onSignalState: { [weak self] source, state in
        Task { @MainActor [weak self] in
          self?.updateSignal(source, state: state)
        }
      },
      onError: onTranscriptionError
    )
    let packetPump = NativeAudioPacketPump(uploader: uploader)
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: packetPump,
      transcription: transcription
    )
    pump = packetPump
    frameDispatcher = dispatcher
    if let backendSessionID {
      await packetPump.bind(sessionID: backendSessionID)
    }
    activeSources = [:]
    resumableSources = []
    snapshot = AudioCaptureSnapshot()
    statusHandler = onStatus
    transcriptionErrorHandler = onTranscriptionError
    isPaused = false
    let clock = NativeAudioMeetingClock()
    let transcription = self.transcription
    let capturedHandler: @Sendable (CapturedPCM) -> Void = { pcm in
      let timed = pcm.timed(capturedAt: Date(), meetingTime: clock.offset())
      dispatcher.enqueue(timed)
    }
    sourceHandler = capturedHandler
    let failures = await startEnabledSources(
      request: request,
      handler: capturedHandler,
      onTranscriptionError: onTranscriptionError
    )
    guard !activeSources.isEmpty else {
      await transcription.stop()
      pump = nil
      frameDispatcher = nil
      throw CaptureError.noAvailableAudioSource(failures.joined(separator: "；"))
    }
  }

  private func startEnabledSources(
    request: NativeAudioCaptureRequest,
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onTranscriptionError: @escaping @Sendable (String) -> Void
  ) async -> [String] {
    var failures: [String] = []
    let enabledSources = sources.filter {
      request.includeLocalMicrophone || $0.source != .microphone
    }
    for source in enabledSources {
      do {
        let startingState: AudioSourceState =
          source.source == .microphone ? .requestingPermission : .starting
        update(source.source, state: startingState)
        try await startSource(source, handler: handler)
        activeSources[source.source] = source
        update(source.source, state: .active)
      } catch {
        await source.stop()
        let name = source.source == .system ? "系统音频" : "麦克风"
        let detail = "\(name)不可用：\(error.localizedDescription)"
        failures.append(detail)
        update(source.source, state: Self.state(for: error))
        onTranscriptionError(detail)
      }
    }
    return failures
  }

  func bindBackendSession(_ sessionID: String) async {
    backendSessionID = sessionID
    await pump?.bind(sessionID: sessionID)
  }

  func pause() async {
    guard !isPaused else { return }
    isPaused = true
    resumableSources = Set(activeSources.keys)
    frameDispatcher?.beginSuspension()
    await transcription.pause()
    for (source, capture) in activeSources {
      await capture.stop()
      update(source, state: .paused)
    }
    activeSources = [:]
    await frameDispatcher?.finishSuspension()
  }

  func resume() async throws {
    guard isPaused else { return }
    guard let sourceHandler else { return }
    let sourcesToResume = resumableSources
    isPaused = false
    await frameDispatcher?.resume()
    var failures: [String] = []
    for source in sources where sourcesToResume.contains(source.source) {
      do {
        update(source.source, state: .starting)
        try await startSource(source, handler: sourceHandler)
        activeSources[source.source] = source
        update(source.source, state: .active)
      } catch {
        await source.stop()
        failures.append(error.localizedDescription)
        update(source.source, state: Self.state(for: error))
        transcriptionErrorHandler?(error.localizedDescription)
      }
    }
    guard !activeSources.isEmpty else {
      isPaused = true
      resumableSources = sourcesToResume
      await frameDispatcher?.suspend()
      throw CaptureError.noAvailableAudioSource(failures.joined(separator: "；"))
    }
    resumableSources = []
  }

  func retry(_ requestedSource: NativeAudioSource) async throws {
    guard !isPaused, activeSources[requestedSource] == nil, let sourceHandler else { return }
    guard let source = sources.first(where: { $0.source == requestedSource }) else { return }
    do {
      update(
        requestedSource, state: requestedSource == .microphone ? .requestingPermission : .starting)
      try await startSource(source, handler: sourceHandler)
      activeSources[requestedSource] = source
      update(requestedSource, state: .active)
    } catch {
      await source.stop()
      update(requestedSource, state: Self.state(for: error))
      throw error
    }
  }

  func stop() async {
    frameDispatcher?.beginSuspension()
    await transcription.stop()
    for (_, source) in activeSources {
      await source.stop()
    }
    await frameDispatcher?.finishSuspension()
    activeSources = [:]
    resumableSources = []
    pump = nil
    frameDispatcher = nil
    backendSessionID = nil
    sourceHandler = nil
    statusHandler = nil
    transcriptionErrorHandler = nil
    isPaused = false
    snapshot = AudioCaptureSnapshot()
  }

  private func update(_ source: NativeAudioSource, state: AudioSourceState) {
    snapshot[source] = state
    if state != .active {
      snapshot.setSignal(.idle, for: source)
    }
    statusHandler?(snapshot)
  }

  private func updateSignal(_ source: NativeAudioSource, state: AudioSignalState) {
    guard snapshot[source] == .active else { return }
    snapshot.setSignal(state, for: source)
    statusHandler?(snapshot)
  }

  private func startSource(
    _ source: NativeAudioSourceCapture,
    handler: @escaping @Sendable (CapturedPCM) -> Void
  ) async throws {
    let semanticSource = source.source
    try await source.start(
      handler: handler,
      onFailure: { [weak self] error in
        Task { @MainActor [weak self] in
          await self?.handleRuntimeFailure(semanticSource, error: error)
        }
      }
    )
  }

  private func handleRuntimeFailure(
    _ source: NativeAudioSource,
    error: any Error
  ) async {
    guard let capture = activeSources.removeValue(forKey: source) else { return }
    await capture.stop()
    let state = Self.state(for: error)
    update(source, state: state)
    transcriptionErrorHandler?(error.localizedDescription)
  }

  private static func state(for error: any Error) -> AudioSourceState {
    guard let captureError = error as? CaptureError else {
      return .failed(error.localizedDescription)
    }
    switch captureError {
    case .microphoneDenied, .screenRecordingDenied: return .denied
    case .microphoneRestricted: return .restricted
    case .microphoneUnavailable, .noDisplay: return .unavailable(captureError.localizedDescription)
    case .microphoneRuntimeFailure, .systemAudioRuntimeFailure,
      .unsupportedAudioFormat, .noAvailableAudioSource:
      return .failed(captureError.localizedDescription)
    }
  }
}

@MainActor
final class NoopNativeAudioCaptureCoordinator: NativeAudioCaptureCoordinating {
  func start(
    request: NativeAudioCaptureRequest,
    onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void,
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onTranscriptionError: @escaping @Sendable (String) -> Void
  ) async throws {}
  func bindBackendSession(_ sessionID: String) async {}
  func pause() async {}
  func resume() async throws {}
  func retry(_ source: NativeAudioSource) async throws {}
  func stop() async {}
}
