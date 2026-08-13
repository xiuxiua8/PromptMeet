import Foundation

@testable import PromptMeet

final class NativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
  let source: NativeAudioSource
  let error: (any Error)?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var failureHandler: (@Sendable (any Error) -> Void)?

  init(source: NativeAudioSource, error: (any Error)? = nil) {
    self.source = source
    self.error = error
  }

  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
    startCount += 1
    if let error { throw error }
  }

  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws {
    failureHandler = onFailure
    try await start(handler: handler)
  }

  func stop() async {
    stopCount += 1
  }

  func fail(_ error: any Error) {
    failureHandler?(error)
  }
}

final class EmittingNativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
  let source: NativeAudioSource

  init(source: NativeAudioSource) {
    self.source = source
  }

  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
    handler(
      CapturedPCM(
        source: source,
        sampleRate: 16_000,
        channels: 1,
        payload: Data(repeating: 0, count: 32_000)
      )
    )
  }

  func stop() async {}
}

final class GatedNativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
  let source: NativeAudioSource
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var failureHandler: (@Sendable (any Error) -> Void)?
  private var startGate: CheckedContinuation<Void, Never>?
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
  private var isBlocked = false
  private let lock = NSLock()

  init(source: NativeAudioSource) {
    self.source = source
  }

  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
    lock.withLock {
      isBlocked = true
      for waiter in blockedWaiters {
        waiter.resume()
      }
      blockedWaiters = []
    }
    await withCheckedContinuation { continuation in
      lock.withLock { startGate = continuation }
    }
    lock.withLock {
      isBlocked = false
      startCount += 1
    }
  }

  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws {
    failureHandler = onFailure
    try await start(handler: handler)
  }

  func stop() async {
    lock.withLock { stopCount += 1 }
  }

  func fail(_ error: any Error) {
    failureHandler?(error)
  }

  func waitUntilBlocked() async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if isBlocked {
          continuation.resume()
          return
        }
        blockedWaiters.append(continuation)
      }
    }
  }

  func releaseStart() {
    lock.withLock {
      startGate?.resume()
      startGate = nil
    }
  }
}

final class FailOnRestartCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
  let source: NativeAudioSource
  let restartError: any Error
  let failingStarts: Int
  private(set) var startCount = 0
  private var failureHandler: (@Sendable (any Error) -> Void)?

  init(
    source: NativeAudioSource,
    restartError: any Error = CaptureError.systemAudioRuntimeFailure("restart failed"),
    failingStarts: Int = .max
  ) {
    self.source = source
    self.restartError = restartError
    self.failingStarts = failingStarts
  }

  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
    startCount += 1
    if startCount > 1, startCount - 1 <= failingStarts {
      throw restartError
    }
  }

  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws {
    failureHandler = onFailure
    try await start(handler: handler)
  }

  func stop() async {}

  func fail(_ error: any Error) {
    failureHandler?(error)
  }
}

struct NativeAudioUploaderSpy: NativeAudioUploading {
  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {}
}

actor RecordingNativeAudioUploader: NativeAudioUploading {
  private(set) var sessionIDs: [String] = []
  private(set) var packets: [NativeAudioPacket] = []

  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    sessionIDs.append(sessionID)
    packets.append(packet)
  }
}

actor DelayedNativeAudioUploader: NativeAudioUploading {
  private(set) var completedSequences: [Int] = []

  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    if packet.sequence == 0 {
      try await Task.sleep(for: .milliseconds(80))
    }
    completedSequences.append(packet.sequence)
  }
}

actor CoalescingNativeAudioUploader: NativeAudioUploading {
  private(set) var packets: [NativeAudioPacket] = []

  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    packets.append(packet)
    if packets.count == 1 {
      try await Task.sleep(for: .milliseconds(80))
    }
  }
}

struct CancellableSlowNativeAudioUploader: NativeAudioUploading {
  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    try await Task.sleep(for: .seconds(10))
  }
}

actor NonCooperativeNativeAudioUploader: NativeAudioUploading {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var completion: CheckedContinuation<Void, Never>?

  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    started = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters = []
    await withCheckedContinuation { continuation in
      completion = continuation
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func complete() {
    completion?.resume()
    completion = nil
  }
}

actor LocalTranscriptionServiceSpy: LocalTranscriptionServicing {
  private(set) var pauseCount = 0
  private(set) var stopCount = 0
  private var signalHandler: (@Sendable (NativeAudioSource, AudioSignalState) -> Void)?

  func start(
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onSignalState: @escaping @Sendable (NativeAudioSource, AudioSignalState) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    signalHandler = onSignalState
  }

  func consume(_ pcm: CapturedPCM) async {}
  func pause() async { pauseCount += 1 }
  func stop() async { stopCount += 1 }

  func emitSignal(_ source: NativeAudioSource, _ state: AudioSignalState) {
    signalHandler?(source, state)
  }
}

actor OrderedLocalTranscriptionServiceSpy: LocalTranscriptionServicing {
  private(set) var meetingTimes: [Duration] = []

  func start(
    onPartialTranscript: @escaping @Sendable (String) -> Void,
    onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
    onSignalState: @escaping @Sendable (NativeAudioSource, AudioSignalState) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {}

  func consume(_ pcm: CapturedPCM) async {
    meetingTimes.append(pcm.meetingTime)
  }

  func pause() async { meetingTimes = [] }
  func stop() async {}
}

final class WarningRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  var count: Int { lock.withLock { values.count } }

  func append(_ value: String) {
    lock.withLock { values.append(value) }
  }
}

final class CaptureSnapshotRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AudioCaptureSnapshot] = []

  var last: AudioCaptureSnapshot? { lock.withLock { values.last } }

  var all: [AudioCaptureSnapshot] { lock.withLock { values } }

  func append(_ value: AudioCaptureSnapshot) {
    lock.withLock { values.append(value) }
  }
}
