import Foundation

struct SpeechGateConfiguration: Equatable, Sendable {
  let sampleRate: Int
  let frameDuration: TimeInterval
  let preRollDuration: TimeInterval
  let minimumSpeechDuration: TimeInterval
  let hangoverDuration: TimeInterval
  let openSNRDecibels: Double
  let closeSNRDecibels: Double
  let minimumLevelDecibels: Double

  static let `default` = SpeechGateConfiguration(
    sampleRate: 16_000,
    frameDuration: 0.025,
    preRollDuration: 0.2,
    minimumSpeechDuration: 0.1,
    hangoverDuration: 0.3,
    openSNRDecibels: 6,
    closeSNRDecibels: 3,
    minimumLevelDecibels: -64
  )
}

struct SpeechGateDiagnostics: Equatable, Sendable {
  var analyzedFrames = 0
  var acceptedSpeechFrames = 0
  var droppedSilenceFrames = 0
  var droppedNoiseFrames = 0
  var utterances = 0
}

struct SpeechAudioSpan: Equatable, Sendable {
  let samples: [Int16]
  let startSampleIndex: Int64
}

enum SpeechGateEvent: Equatable, Sendable {
  case speechStarted(SpeechAudioSpan)
  case speechContinued(SpeechAudioSpan)
  case speechEnded
}

struct SpeechActivityGate: Sendable {
  private struct Frame: Sendable {
    let samples: [Int16]
    let startSampleIndex: Int64
  }

  private struct Features: Sendable {
    let levelDecibels: Double
    let zeroCrossingRate: Double
    let periodicity: Double
    let differenceRatio: Double
  }

  private let configuration: SpeechGateConfiguration
  private let frameSampleCount: Int
  private let preRollFrameCount: Int
  private let minimumSpeechFrameCount: Int
  private let hangoverFrameCount: Int
  private var inputBuffer: [Int16] = []
  private var nextFrameSampleIndex: Int64 = 0
  private var preRollFrames: [Frame] = []
  private var pendingFrames: [Frame] = []
  private var pendingSpeechFrames = 0
  private var pendingGapFrames = 0
  private var isOpen = false
  private var remainingHangoverFrames = 0
  private var noiseFloorDecibels: Double?
  private var previousLevelDecibels: Double?
  private(set) var diagnostics = SpeechGateDiagnostics()

  init(configuration: SpeechGateConfiguration = .default) {
    self.configuration = configuration
    frameSampleCount = max(
      1,
      Int(
        (Double(configuration.sampleRate) * configuration.frameDuration).rounded()
      ))
    preRollFrameCount = max(
      0,
      Int(
        (configuration.preRollDuration / configuration.frameDuration).rounded()
      ))
    minimumSpeechFrameCount = max(
      1,
      Int(
        (configuration.minimumSpeechDuration / configuration.frameDuration).rounded(.up)
      ))
    hangoverFrameCount = max(
      1,
      Int(
        (configuration.hangoverDuration / configuration.frameDuration).rounded(.up)
      ))
  }

  mutating func consume(_ samples: [Int16]) -> [SpeechGateEvent] {
    guard !samples.isEmpty else { return [] }
    inputBuffer.append(contentsOf: samples)
    var events: [SpeechGateEvent] = []
    while inputBuffer.count >= frameSampleCount {
      let frameSamples = Array(inputBuffer.prefix(frameSampleCount))
      inputBuffer.removeFirst(frameSampleCount)
      let correctedSamples = Self.removingDCOffset(from: frameSamples)
      events.append(
        contentsOf: processFrame(
          samples: correctedSamples,
          analysisSamples: correctedSamples
        ))
      nextFrameSampleIndex += Int64(frameSampleCount)
    }
    return events
  }

  mutating func finish() -> [SpeechGateEvent] {
    var events: [SpeechGateEvent] = []
    if !inputBuffer.isEmpty {
      let correctedSamples = Self.removingDCOffset(from: inputBuffer)
      let padded =
        correctedSamples
        + [Int16](repeating: 0, count: frameSampleCount - correctedSamples.count)
      events.append(
        contentsOf: processFrame(samples: correctedSamples, analysisSamples: padded)
      )
      nextFrameSampleIndex += Int64(correctedSamples.count)
      inputBuffer = []
    }
    if isOpen {
      events.append(.speechEnded)
    } else {
      dropPendingFrames()
    }
    resetStreamState(keepingDiagnostics: true)
    return events
  }

  mutating func finishAfterInactivity() -> [SpeechGateEvent] {
    let confirmedSilence = [Int16](
      repeating: 0,
      count: frameSampleCount * (hangoverFrameCount + 1)
    )
    return consume(confirmedSilence) + finish()
  }

  mutating func discardBufferedAudio() {
    resetStreamState(keepingDiagnostics: true)
  }
}

private extension SpeechActivityGate {
  mutating func processFrame(
    samples: [Int16],
    analysisSamples: [Int16]
  ) -> [SpeechGateEvent] {
    let frame = Frame(samples: samples, startSampleIndex: nextFrameSampleIndex)
    let features = Self.features(for: analysisSamples)
    diagnostics.analyzedFrames += 1
    let levelChange =
      previousLevelDecibels.map {
        abs(features.levelDecibels - $0)
      } ?? 0
    previousLevelDecibels = features.levelDecibels

    if isOpen {
      return processOpenFrame(frame, features: features, levelChange: levelChange)
    }
    return processClosedFrame(frame, features: features, levelChange: levelChange)
  }

  private mutating func processOpenFrame(
    _ frame: Frame,
    features: Features,
    levelChange: Double
  ) -> [SpeechGateEvent] {
    let remainsSpeech = isSpeechCandidate(
      features,
      levelChange: levelChange,
      snrMargin: configuration.closeSNRDecibels
    )
    diagnostics.acceptedSpeechFrames += 1
    var events: [SpeechGateEvent] = [
      .speechContinued(
        SpeechAudioSpan(samples: frame.samples, startSampleIndex: frame.startSampleIndex)
      )
    ]
    if remainsSpeech {
      remainingHangoverFrames = hangoverFrameCount
    } else {
      remainingHangoverFrames -= 1
      if remainingHangoverFrames <= 0 {
        isOpen = false
        events.append(.speechEnded)
      }
    }
    return events
  }

  private mutating func processClosedFrame(
    _ frame: Frame,
    features: Features,
    levelChange: Double
  ) -> [SpeechGateEvent] {
    let isCandidate = isSpeechCandidate(
      features,
      levelChange: levelChange,
      snrMargin: configuration.openSNRDecibels
    )
    if isCandidate {
      pendingFrames.append(frame)
      pendingSpeechFrames += 1
      pendingGapFrames = 0
    } else if !pendingFrames.isEmpty, pendingGapFrames < 1 {
      pendingFrames.append(frame)
      pendingGapFrames += 1
    } else {
      dropPendingFrames()
      appendToPreRoll(frame)
      recordDroppedFrame(features)
      adaptNoiseFloor(toward: features.levelDecibels)
    }

    guard pendingSpeechFrames >= minimumSpeechFrameCount else { return [] }
    let retainedFrames = preRollFrames + pendingFrames
    let span = Self.span(from: retainedFrames)
    diagnostics.acceptedSpeechFrames += retainedFrames.count
    diagnostics.utterances += 1
    preRollFrames = []
    pendingFrames = []
    pendingSpeechFrames = 0
    pendingGapFrames = 0
    isOpen = true
    remainingHangoverFrames = hangoverFrameCount
    return [.speechStarted(span)]
  }

  private func isSpeechCandidate(
    _ features: Features,
    levelChange: Double,
    snrMargin: Double
  ) -> Bool {
    let noiseFloor = noiseFloorDecibels ?? -72
    guard
      features.levelDecibels >= configuration.minimumLevelDecibels,
      features.levelDecibels - noiseFloor >= snrMargin
    else {
      return false
    }
    let voiced =
      features.periodicity >= 0.24
      && features.differenceRatio < 0.9
      && features.zeroCrossingRate < 0.42
    let changingSpeechLikeSignal =
      features.periodicity >= 0.10
      && features.differenceRatio < 1.15
      && features.zeroCrossingRate < 0.34
      && levelChange >= 2.5
    return voiced || changingSpeechLikeSignal
  }

  mutating func adaptNoiseFloor(toward levelDecibels: Double) {
    let bounded = min(-20, max(-90, levelDecibels))
    guard let current = noiseFloorDecibels else {
      noiseFloorDecibels = bounded
      return
    }
    let rate = bounded < current ? 0.22 : 0.035
    noiseFloorDecibels = current + (bounded - current) * rate
  }

  private mutating func recordDroppedFrame(_ features: Features) {
    if features.levelDecibels < configuration.minimumLevelDecibels {
      diagnostics.droppedSilenceFrames += 1
    } else {
      diagnostics.droppedNoiseFrames += 1
    }
  }

  mutating func dropPendingFrames() {
    guard !pendingFrames.isEmpty else { return }
    diagnostics.droppedNoiseFrames += pendingFrames.count
    for frame in pendingFrames {
      appendToPreRoll(frame)
    }
    pendingFrames = []
    pendingSpeechFrames = 0
    pendingGapFrames = 0
  }

  private mutating func appendToPreRoll(_ frame: Frame) {
    guard preRollFrameCount > 0 else { return }
    preRollFrames.append(frame)
    if preRollFrames.count > preRollFrameCount {
      preRollFrames.removeFirst(preRollFrames.count - preRollFrameCount)
    }
  }

  mutating func resetStreamState(keepingDiagnostics: Bool) {
    inputBuffer = []
    nextFrameSampleIndex = 0
    preRollFrames = []
    pendingFrames = []
    pendingSpeechFrames = 0
    pendingGapFrames = 0
    isOpen = false
    remainingHangoverFrames = 0
    noiseFloorDecibels = nil
    previousLevelDecibels = nil
    if !keepingDiagnostics {
      diagnostics = SpeechGateDiagnostics()
    }
  }

  private static func span(from frames: [Frame]) -> SpeechAudioSpan {
    SpeechAudioSpan(
      samples: frames.flatMap(\.samples),
      startSampleIndex: frames.first?.startSampleIndex ?? 0
    )
  }

  private static func removingDCOffset(from samples: [Int16]) -> [Int16] {
    guard !samples.isEmpty else { return [] }
    let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    return samples.map {
      Int16(clamping: Int((Double($0) - mean).rounded()))
    }
  }

  private static func features(for samples: [Int16]) -> Features {
    guard !samples.isEmpty else {
      return Features(
        levelDecibels: -120,
        zeroCrossingRate: 0,
        periodicity: 0,
        differenceRatio: 0
      )
    }
    let centered = samples.map(Double.init)
    let energy = centered.reduce(0.0) { $0 + $1 * $1 }
    let rms = sqrt(energy / Double(centered.count))
    let levelDecibels = Self.levelDecibels(for: rms)
    let variation = Self.variationFeatures(centered: centered, rms: rms)
    let periodicity = Self.periodicity(centered: centered, energy: energy)
    return Features(
      levelDecibels: levelDecibels,
      zeroCrossingRate: variation.zeroCrossingRate,
      periodicity: periodicity,
      differenceRatio: variation.differenceRatio
    )
  }

  static func levelDecibels(for rms: Double) -> Double {
    rms > 0 ? 20 * log10(rms / Double(Int16.max)) : -120
  }

  static func variationFeatures(centered: [Double], rms: Double)
    -> (zeroCrossingRate: Double, differenceRatio: Double) {
    var zeroCrossings = 0
    var differenceEnergy = 0.0
    if centered.count > 1 {
      for index in 1..<centered.count {
        if (centered[index - 1] < 0) != (centered[index] < 0) {
          zeroCrossings += 1
        }
        let difference = centered[index] - centered[index - 1]
        differenceEnergy += difference * difference
      }
    }
    let zeroCrossingRate = Double(zeroCrossings) / Double(max(1, centered.count - 1))
    let differenceRMS = sqrt(differenceEnergy / Double(max(1, centered.count - 1)))
    let differenceRatio = rms > 0 ? differenceRMS / rms : 0
    return (zeroCrossingRate, differenceRatio)
  }

  static func periodicity(centered: [Double], energy: Double) -> Double {
    var periodicity = 0.0
    if energy > 0 {
      let maximumLag = min(200, centered.count - 2)
      if maximumLag >= 32 {
        for lag in 32...maximumLag {
          var correlation = 0.0
          var leftEnergy = 0.0
          var rightEnergy = 0.0
          for index in lag..<centered.count {
            let left = centered[index]
            let right = centered[index - lag]
            correlation += left * right
            leftEnergy += left * left
            rightEnergy += right * right
          }
          let denominator = sqrt(leftEnergy * rightEnergy)
          if denominator > 0 {
            periodicity = max(periodicity, correlation / denominator)
          }
        }
      }
    }
    return periodicity
  }
}
