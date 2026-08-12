import Foundation

enum NativeAudioSource: String, Codable, Sendable {
  case system
  case microphone
  case mixed
}

struct NativeAudioPacket: Equatable, Sendable {
  let sequence: Int
  let source: NativeAudioSource
  let sampleRate: Int
  let channels: Int
  let capturedAt: Date
  let meetingTime: Duration
  let payload: Data

  init(
    sequence: Int,
    source: NativeAudioSource,
    sampleRate: Int,
    channels: Int,
    capturedAt: Date = Date(),
    meetingTime: Duration = .zero,
    payload: Data
  ) {
    self.sequence = sequence
    self.source = source
    self.sampleRate = sampleRate
    self.channels = channels
    self.capturedAt = capturedAt
    self.meetingTime = meetingTime
    self.payload = payload
  }
}

struct NativeAudioSequencer {
  private var nextSequence = 0

  mutating func packet(
    source: NativeAudioSource,
    sampleRate: Int,
    channels: Int,
    capturedAt: Date = Date(),
    meetingTime: Duration = .zero,
    payload: Data
  ) -> NativeAudioPacket {
    defer { nextSequence += 1 }
    return NativeAudioPacket(
      sequence: nextSequence,
      source: source,
      sampleRate: sampleRate,
      channels: channels,
      capturedAt: capturedAt,
      meetingTime: meetingTime,
      payload: payload
    )
  }

  mutating func reset() {
    nextSequence = 0
  }
}

struct NativeAudioUploader: Sendable {
  static let requestTimeout: TimeInterval = 10

  private let environment: BackendEnvironment
  private let session: URLSession

  init(environment: BackendEnvironment = .local, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
  }

  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
    let request = Self.makeRequest(
      packet: packet,
      sessionID: sessionID,
      environment: environment
    )
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw BackendClientError.invalidResponse
    }
    guard (200..<300).contains(response.statusCode) else {
      throw BackendClientError.serviceRejected(response.statusCode)
    }
  }

  static func makeRequest(
    packet: NativeAudioPacket,
    sessionID: String,
    environment: BackendEnvironment
  ) -> URLRequest {
    var request = environment.request(
      path: "/api/sessions/\(sessionID)/native-audio",
      method: "POST"
    )
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(packet.sequence), forHTTPHeaderField: "X-PromptMeet-Sequence")
    request.setValue(String(packet.sampleRate), forHTTPHeaderField: "X-PromptMeet-Sample-Rate")
    request.setValue(String(packet.channels), forHTTPHeaderField: "X-PromptMeet-Channels")
    request.setValue(packet.source.rawValue, forHTTPHeaderField: "X-PromptMeet-Source")
    request.setValue(
      ISO8601DateFormatter().string(from: packet.capturedAt),
      forHTTPHeaderField: "X-PromptMeet-Captured-At"
    )
    request.setValue(
      String(packet.meetingTime.millisecondsValue),
      forHTTPHeaderField: "X-PromptMeet-Meeting-Time-Ms"
    )
    request.timeoutInterval = requestTimeout
    request.httpBody = packet.payload
    return request
  }
}

protocol NativeAudioUploading: Sendable {
  func upload(_ packet: NativeAudioPacket, sessionID: String) async throws
}

extension NativeAudioUploader: NativeAudioUploading {}

enum NativeAudioUploadError: Error, Equatable {
  case timedOut
}

struct CapturedPCM: Sendable {
  let source: NativeAudioSource
  let sampleRate: Int
  let channels: Int
  let capturedAt: Date
  let meetingTime: Duration
  let payload: Data

  init(
    source: NativeAudioSource,
    sampleRate: Int,
    channels: Int,
    capturedAt: Date = Date(),
    meetingTime: Duration = .zero,
    payload: Data
  ) {
    self.source = source
    self.sampleRate = sampleRate
    self.channels = channels
    self.capturedAt = capturedAt
    self.meetingTime = meetingTime
    self.payload = payload
  }

  func timed(capturedAt: Date, meetingTime: Duration) -> CapturedPCM {
    CapturedPCM(
      source: source,
      sampleRate: sampleRate,
      channels: channels,
      capturedAt: capturedAt,
      meetingTime: meetingTime,
      payload: payload
    )
  }
}

struct NativeAudioMeetingClock: Sendable {
  let originNanoseconds: UInt64

  init(originNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
    self.originNanoseconds = originNanoseconds
  }

  func offset(atNanoseconds value: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Duration {
    guard value >= originNanoseconds else { return .zero }
    let delta = min(value - originNanoseconds, UInt64(Int64.max))
    return .nanoseconds(Int64(delta))
  }
}

protocol NativeAudioSourceCapture: AnyObject, Sendable {
  var source: NativeAudioSource { get }
  func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws
  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws
  func stop() async
}

extension NativeAudioSourceCapture {
  func start(
    handler: @escaping @Sendable (CapturedPCM) -> Void,
    onFailure: @escaping @Sendable (any Error) -> Void
  ) async throws {
    try await start(handler: handler)
  }
}

actor NativeAudioPacketPump {
  private var sequencer = NativeAudioSequencer()
  private let uploader: NativeAudioUploading
  private let uploadTimeout: Duration
  private var sessionID: String?
  private var uploadInProgress = false
  private var uploadWaiters: [CheckedContinuation<Void, Never>] = []
  private var isSuspended = false

  init(
    uploader: NativeAudioUploading,
    sessionID: String? = nil,
    uploadTimeout: Duration = .seconds(10)
  ) {
    self.uploader = uploader
    self.sessionID = sessionID
    self.uploadTimeout = uploadTimeout
  }

  func bind(sessionID: String) {
    self.sessionID = sessionID
  }

  func suspend() {
    isSuspended = true
  }

  func resume() {
    isSuspended = false
  }

  func consume(_ pcm: CapturedPCM) async throws {
    guard !isSuspended, let sessionID else { return }
    await acquireUploadSlot()
    defer { releaseUploadSlot() }
    try Task.checkCancellation()
    guard !isSuspended else { return }
    let packet = sequencer.packet(
      source: pcm.source,
      sampleRate: pcm.sampleRate,
      channels: pcm.channels,
      capturedAt: pcm.capturedAt,
      meetingTime: pcm.meetingTime,
      payload: pcm.payload
    )
    let uploader = self.uploader
    let uploadTimeout = self.uploadTimeout
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await uploader.upload(packet, sessionID: sessionID)
      }
      group.addTask {
        try await Task.sleep(for: uploadTimeout)
        throw NativeAudioUploadError.timedOut
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private func acquireUploadSlot() async {
    if !uploadInProgress {
      uploadInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      uploadWaiters.append(continuation)
    }
  }

  private func releaseUploadSlot() {
    guard !uploadWaiters.isEmpty else {
      uploadInProgress = false
      return
    }
    uploadWaiters.removeFirst().resume()
  }
}
