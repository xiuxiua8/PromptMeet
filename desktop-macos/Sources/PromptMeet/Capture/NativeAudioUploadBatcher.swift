import Foundation

struct NativeAudioUploadBatcher {
  static let defaultDuration: TimeInterval = 1

  private struct PendingBatch {
    let source: NativeAudioSource
    let sampleRate: Int
    let channels: Int
    let capturedAt: Date
    let meetingTime: Duration
    var payload: Data

    var pcm: CapturedPCM {
      CapturedPCM(
        source: source,
        sampleRate: sampleRate,
        channels: channels,
        capturedAt: capturedAt,
        meetingTime: meetingTime,
        payload: payload
      )
    }

    func matches(_ pcm: CapturedPCM) -> Bool {
      sampleRate == pcm.sampleRate && channels == pcm.channels
    }
  }

  private let duration: TimeInterval
  private var pendingBySource: [NativeAudioSource: PendingBatch] = [:]

  init(duration: TimeInterval = defaultDuration) {
    self.duration = max(0.02, duration)
  }

  mutating func append(_ pcm: CapturedPCM) -> [CapturedPCM] {
    guard !pcm.payload.isEmpty, pcm.sampleRate > 0, pcm.channels > 0 else { return [] }
    var emitted: [CapturedPCM] = []
    var pending = pendingBySource.removeValue(forKey: pcm.source)
    if let existing = pending, !existing.matches(pcm) {
      emitted.append(existing.pcm)
      pending = nil
    }
    if pending == nil {
      pending = PendingBatch(
        source: pcm.source,
        sampleRate: pcm.sampleRate,
        channels: pcm.channels,
        capturedAt: pcm.capturedAt,
        meetingTime: pcm.meetingTime,
        payload: Data()
      )
    }
    pending?.payload.append(pcm.payload)
    guard let pending else { return emitted }
    if pending.payload.count >= targetPayloadByteCount(for: pcm) {
      emitted.append(pending.pcm)
    } else {
      pendingBySource[pcm.source] = pending
    }
    return emitted
  }

  mutating func reset() {
    pendingBySource.removeAll(keepingCapacity: true)
  }

  private func targetPayloadByteCount(for pcm: CapturedPCM) -> Int {
    let bytesPerSecond = Double(pcm.sampleRate * pcm.channels * MemoryLayout<Int16>.size)
    return max(1, Int((bytesPerSecond * duration).rounded(.up)))
  }
}

final class NativeAudioFrameDispatcher: @unchecked Sendable {
  private let packetPump: NativeAudioPacketPump
  private let transcription: LocalTranscriptionServicing
  private let lock = NSLock()
  private var uploadBatcher = NativeAudioUploadBatcher()
  private var generation: UInt64 = 0
  private var isSuspended = false
  private var pendingUploadBySource: [NativeAudioSource: (CapturedPCM, UInt64)] = [:]
  private var uploadWorkerTask: Task<Void, Never>?
  private var pendingTranscriptionTask: Task<Void, Never>?

  init(
    packetPump: NativeAudioPacketPump,
    transcription: LocalTranscriptionServicing
  ) {
    self.packetPump = packetPump
    self.transcription = transcription
  }

  func enqueue(_ pcm: CapturedPCM) {
    lock.withLock {
      guard !isSuspended else { return }
      let expectedGeneration = generation
      for batch in uploadBatcher.append(pcm) {
        pendingUploadBySource[batch.source] = (batch, expectedGeneration)
        if uploadWorkerTask == nil {
          uploadWorkerTask = Task { [weak self] in
            await self?.runUploadWorker()
          }
        }
      }
      let transcriptionPredecessor = pendingTranscriptionTask
      pendingTranscriptionTask = Task { [weak self] in
        _ = await transcriptionPredecessor?.result
        guard let self, isCurrent(expectedGeneration) else { return }
        await transcription.consume(pcm)
      }
    }
  }

  func beginSuspension() {
    let pending = lock.withLock {
      isSuspended = true
      generation &+= 1
      uploadBatcher.reset()
      pendingUploadBySource.removeAll(keepingCapacity: true)
      let pending = (uploadWorkerTask, pendingTranscriptionTask)
      uploadWorkerTask = nil
      pendingTranscriptionTask = nil
      return pending
    }
    pending.0?.cancel()
    pending.1?.cancel()
  }

  func finishSuspension() async {
    await packetPump.suspend()
  }

  func suspend() async {
    beginSuspension()
    await finishSuspension()
  }

  func resume() async {
    await packetPump.resume()
    lock.withLock { isSuspended = false }
  }

  func drain() async {
    while let uploadWorker = lock.withLock({ uploadWorkerTask }) {
      _ = await uploadWorker.result
    }
    let transcriptionTask = lock.withLock { pendingTranscriptionTask }
    _ = await transcriptionTask?.result
  }

  private func runUploadWorker() async {
    while !Task.isCancelled, let pending = nextPendingUpload() {
      guard isCurrent(pending.1) else { continue }
      try? await packetPump.consume(pending.0)
    }
  }

  private func nextPendingUpload() -> (CapturedPCM, UInt64)? {
    lock.withLock {
      guard !isSuspended,
            let source = pendingUploadBySource.min(by: {
              $0.value.0.capturedAt < $1.value.0.capturedAt
            })?.key else {
        uploadWorkerTask = nil
        return nil
      }
      return pendingUploadBySource.removeValue(forKey: source)
    }
  }

  private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
    lock.withLock {
      !isSuspended && generation == expectedGeneration
    }
  }
}
