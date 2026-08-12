import Foundation

struct PCMTranscriptionSegment: Equatable, Sendable {
  let source: NativeAudioSource
  let sampleRate: Int
  let samples: [Int16]
  let capturedAt: Date
  let meetingTime: Duration

  init(
    source: NativeAudioSource,
    sampleRate: Int,
    samples: [Int16],
    capturedAt: Date = Date(),
    meetingTime: Duration = .zero
  ) {
    self.source = source
    self.sampleRate = sampleRate
    self.samples = samples
    self.capturedAt = capturedAt
    self.meetingTime = meetingTime
  }
}

struct PCMTranscriptionUpdate: Equatable, Sendable {
  let preview: PCMTranscriptionSegment?
  let finalized: [PCMTranscriptionSegment]
  let signalTransition: AudioSignalState?
}

struct PCMTranscriptionSegmenter {
  private let targetSampleRate = 16_000
  private let segmentSampleCount: Int
  private let previewIntervalSampleCount: Int
  private let minimumPreviewSampleCount: Int
  private var gatesBySource: [NativeAudioSource: SpeechActivityGate] = [:]
  private var samplesBySource: [NativeAudioSource: [Int16]] = [:]
  private var lastPreviewSampleCountBySource: [NativeAudioSource: Int] = [:]
  private var capturedAtBySource: [NativeAudioSource: Date] = [:]
  private var meetingTimeBySource: [NativeAudioSource: Duration] = [:]
  private var inputCapturedAtBySource: [NativeAudioSource: Date] = [:]
  private var inputMeetingTimeBySource: [NativeAudioSource: Duration] = [:]
  private var signalStateBySource: [NativeAudioSource: AudioSignalState] = [:]

  init(
    segmentDuration: TimeInterval = 3,
    minimumFlushDuration _: TimeInterval = 0.5,
    previewInterval: TimeInterval = 1.25,
    minimumPreviewDuration: TimeInterval = 1
  ) {
    segmentSampleCount = max(1, Int(segmentDuration * 16_000))
    previewIntervalSampleCount = max(1, Int(previewInterval * 16_000))
    minimumPreviewSampleCount = max(1, Int(minimumPreviewDuration * 16_000))
  }

  mutating func consume(_ pcm: CapturedPCM) -> [PCMTranscriptionSegment] {
    consumeStreaming(pcm).finalized
  }

  mutating func consumeStreaming(_ pcm: CapturedPCM) -> PCMTranscriptionUpdate {
    guard pcm.channels > 0, pcm.sampleRate > 0 else {
      return PCMTranscriptionUpdate(preview: nil, finalized: [], signalTransition: nil)
    }
    let decoded = Self.decodePCM16(pcm.payload, channels: pcm.channels)
    let normalized = Self.resample(decoded, from: pcm.sampleRate, to: targetSampleRate)
    guard !normalized.isEmpty else {
      return PCMTranscriptionUpdate(preview: nil, finalized: [], signalTransition: nil)
    }
    if inputCapturedAtBySource[pcm.source] == nil {
      inputCapturedAtBySource[pcm.source] = pcm.capturedAt
      inputMeetingTimeBySource[pcm.source] = pcm.meetingTime
    }
    var gate = gatesBySource[pcm.source] ?? SpeechActivityGate()
    let events = gate.consume(normalized)
    gatesBySource[pcm.source] = gate
    var update = apply(events, source: pcm.source)
    if update.signalTransition == nil,
      signalStateBySource[pcm.source] == nil,
      gate.diagnostics.analyzedFrames >= 20 {
      signalStateBySource[pcm.source] = .silenceFiltered
      update = PCMTranscriptionUpdate(
        preview: update.preview,
        finalized: update.finalized,
        signalTransition: .silenceFiltered
      )
    }
    return update
  }

  mutating func flush() -> [PCMTranscriptionSegment] {
    var output: [PCMTranscriptionSegment] = []
    for source in gatesBySource.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard var gate = gatesBySource[source] else { continue }
      let events = gate.finish()
      gatesBySource[source] = gate
      output.append(contentsOf: apply(events, source: source).finalized)
      output.append(contentsOf: finalizeRemainder(for: source))
    }
    clearStreamBuffers()
    return output
  }

  mutating func finishInactiveSource(_ source: NativeAudioSource) -> PCMTranscriptionUpdate {
    guard var gate = gatesBySource[source] else {
      return PCMTranscriptionUpdate(preview: nil, finalized: [], signalTransition: nil)
    }
    let events = gate.finishAfterInactivity()
    gatesBySource[source] = gate
    let update = apply(events, source: source)
    inputCapturedAtBySource[source] = nil
    inputMeetingTimeBySource[source] = nil
    return update
  }

  mutating func discardBufferedAudio() {
    for source in gatesBySource.keys {
      gatesBySource[source]?.discardBufferedAudio()
    }
    clearStreamBuffers()
  }

  func diagnostics(for source: NativeAudioSource) -> SpeechGateDiagnostics {
    gatesBySource[source]?.diagnostics ?? SpeechGateDiagnostics()
  }

  private mutating func apply(
    _ events: [SpeechGateEvent],
    source: NativeAudioSource
  ) -> PCMTranscriptionUpdate {
    var preview: PCMTranscriptionSegment?
    var finalized: [PCMTranscriptionSegment] = []
    var signalTransition: AudioSignalState?
    for event in events {
      switch event {
      case .speechStarted(let span):
        if signalStateBySource[source] != .speechDetected {
          signalStateBySource[source] = .speechDetected
          signalTransition = .speechDetected
        }
        append(span, source: source)
        finalized.append(contentsOf: drainFullSegments(for: source))
        preview = makePreviewIfNeeded(for: source) ?? preview
      case .speechContinued(let span):
        append(span, source: source)
        finalized.append(contentsOf: drainFullSegments(for: source))
        preview = makePreviewIfNeeded(for: source) ?? preview
      case .speechEnded:
        finalized.append(contentsOf: finalizeRemainder(for: source))
        preview = nil
        if signalStateBySource[source] != .silenceFiltered {
          signalStateBySource[source] = .silenceFiltered
          signalTransition = .silenceFiltered
        }
      }
    }
    return PCMTranscriptionUpdate(
      preview: preview,
      finalized: finalized,
      signalTransition: signalTransition
    )
  }

  private mutating func append(_ span: SpeechAudioSpan, source: NativeAudioSource) {
    guard !span.samples.isEmpty else { return }
    if samplesBySource[source, default: []].isEmpty {
      let interval = Double(span.startSampleIndex) / Double(targetSampleRate)
      capturedAtBySource[source] = (inputCapturedAtBySource[source] ?? Date())
        .addingTimeInterval(interval)
      inputMeetingTimeBySource[source].map {
        meetingTimeBySource[source] = $0 + .milliseconds(Int64(interval * 1_000))
      }
    }
    samplesBySource[source, default: []].append(contentsOf: span.samples)
  }

  private mutating func drainFullSegments(for source: NativeAudioSource)
    -> [PCMTranscriptionSegment] {
    var output: [PCMTranscriptionSegment] = []
    while let samples = samplesBySource[source], samples.count >= segmentSampleCount {
      output.append(segment(source: source, samples: Array(samples.prefix(segmentSampleCount))))
      samplesBySource[source] = Array(samples.dropFirst(segmentSampleCount))
      advanceTiming(for: source, sampleCount: segmentSampleCount)
      lastPreviewSampleCountBySource[source] = 0
    }
    return output
  }

  private mutating func finalizeRemainder(for source: NativeAudioSource)
    -> [PCMTranscriptionSegment] {
    guard let remainder = samplesBySource[source], !remainder.isEmpty else {
      clearOutputBuffer(for: source)
      return []
    }
    let output = segment(source: source, samples: remainder)
    clearOutputBuffer(for: source)
    return [output]
  }

  private mutating func makePreviewIfNeeded(for source: NativeAudioSource)
    -> PCMTranscriptionSegment? {
    guard let samples = samplesBySource[source], samples.count >= minimumPreviewSampleCount else {
      return nil
    }
    let previousCount = lastPreviewSampleCountBySource[source, default: 0]
    guard samples.count - previousCount >= previewIntervalSampleCount else {
      return nil
    }
    lastPreviewSampleCountBySource[source] = samples.count
    return segment(source: source, samples: samples)
  }

  private func segment(source: NativeAudioSource, samples: [Int16]) -> PCMTranscriptionSegment {
    PCMTranscriptionSegment(
      source: source,
      sampleRate: targetSampleRate,
      samples: samples,
      capturedAt: capturedAtBySource[source] ?? Date(),
      meetingTime: meetingTimeBySource[source] ?? .zero
    )
  }

  private mutating func advanceTiming(for source: NativeAudioSource, sampleCount: Int) {
    let interval = Double(sampleCount) / Double(targetSampleRate)
    if let capturedAt = capturedAtBySource[source] {
      capturedAtBySource[source] = capturedAt.addingTimeInterval(interval)
    }
    if let meetingTime = meetingTimeBySource[source] {
      meetingTimeBySource[source] = meetingTime + .milliseconds(Int64(interval * 1_000))
    }
  }

  private mutating func clearOutputBuffer(for source: NativeAudioSource) {
    samplesBySource[source] = []
    lastPreviewSampleCountBySource[source] = 0
    capturedAtBySource[source] = nil
    meetingTimeBySource[source] = nil
  }

  private mutating func clearStreamBuffers() {
    samplesBySource.removeAll(keepingCapacity: true)
    lastPreviewSampleCountBySource.removeAll(keepingCapacity: true)
    capturedAtBySource.removeAll(keepingCapacity: true)
    meetingTimeBySource.removeAll(keepingCapacity: true)
    inputCapturedAtBySource.removeAll(keepingCapacity: true)
    inputMeetingTimeBySource.removeAll(keepingCapacity: true)
    signalStateBySource.removeAll(keepingCapacity: true)
  }

  private static func decodePCM16(_ data: Data, channels: Int) -> [Int16] {
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return [] }
    let interleaved: [Int16] = data.withUnsafeBytes { bytes in
      Array(bytes.bindMemory(to: Int16.self).prefix(sampleCount))
    }
    guard channels > 1 else { return interleaved }
    return stride(from: 0, to: interleaved.count, by: channels).map { frameStart in
      let frame = interleaved[frameStart..<min(frameStart + channels, interleaved.count)]
      let total = frame.reduce(Int64(0)) { $0 + Int64($1) }
      return Int16(total / Int64(frame.count))
    }
  }

  private static func resample(_ samples: [Int16], from sourceRate: Int, to targetRate: Int)
    -> [Int16] {
    guard !samples.isEmpty, sourceRate != targetRate else { return samples }
    let outputCount = Int(
      (Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded())
    guard outputCount > 0 else { return [] }
    return (0..<outputCount).map { outputIndex in
      let sourcePosition = Double(outputIndex) * Double(sourceRate) / Double(targetRate)
      let lower = min(Int(sourcePosition), samples.count - 1)
      let upper = min(lower + 1, samples.count - 1)
      let fraction = sourcePosition - Double(lower)
      let value = Double(samples[lower]) * (1 - fraction) + Double(samples[upper]) * fraction
      return Int16(max(Double(Int16.min), min(Double(Int16.max), value.rounded())))
    }
  }
}
