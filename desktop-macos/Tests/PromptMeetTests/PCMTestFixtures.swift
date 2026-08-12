import Foundation

@testable import PromptMeet

enum PCMTestFixtures {
  static let sampleRate = 16_000

  static func silence(duration: TimeInterval = 1) -> [Int16] {
    [Int16](repeating: 0, count: sampleCount(duration))
  }

  static func dcOffset(duration: TimeInterval = 1, level: Int16 = 180) -> [Int16] {
    [Int16](repeating: level, count: sampleCount(duration))
  }

  static func roomNoise(duration: TimeInterval = 1) -> [Int16] {
    whiteNoise(duration: duration, amplitude: 36, seed: 0xC0FFEE)
  }

  static func whiteNoise(
    duration: TimeInterval = 1,
    amplitude: Int16 = 2_000,
    seed: UInt64 = 0x5EED
  ) -> [Int16] {
    var state = seed
    let scale = Int(amplitude)
    return (0..<sampleCount(duration)).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let unit = Int((state >> 33) & 0x7FFF)
      return Int16((unit * scale * 2 / 0x7FFF) - scale)
    }
  }

  static func voicedSpeech(
    duration: TimeInterval = 1,
    amplitude: Double = 1_400,
    frequency: Double = 185
  ) -> [Int16] {
    (0..<sampleCount(duration)).map { index in
      let time = Double(index) / Double(sampleRate)
      let syllablePhase = time.truncatingRemainder(dividingBy: 0.24) / 0.24
      let envelope = 0.18 + 0.82 * pow(sin(.pi * syllablePhase), 2)
      let fundamental = sin(2 * .pi * frequency * time)
      let secondHarmonic = sin(2 * .pi * frequency * 2 * time + 0.3)
      let value = amplitude * envelope * (0.78 * fundamental + 0.22 * secondHarmonic)
      return Int16(value.rounded())
    }
  }

  static func quietSpeech(duration: TimeInterval = 0.45) -> [Int16] {
    voicedSpeech(duration: duration, amplitude: 155, frequency: 205)
  }

  static func speechBurst(duration: TimeInterval = 0.16) -> [Int16] {
    voicedSpeech(duration: duration, amplitude: 1_600, frequency: 170)
  }

  static func silenceThenQuietSpeech() -> [Int16] {
    silence(duration: 0.4)
      + quietSpeech(duration: 0.45)
      + silence(duration: 0.5)
  }

  static func overlappingSpeech(duration: TimeInterval = 1) -> [Int16] {
    zip(
      voicedSpeech(duration: duration, amplitude: 1_200, frequency: 170),
      voicedSpeech(duration: duration, amplitude: 900, frequency: 245)
    ).map { left, right in
      Int16(clamping: Int(left) + Int(right))
    }
  }

  static func packet(
    _ samples: [Int16],
    source: NativeAudioSource = .microphone,
    sampleRate: Int = sampleRate,
    capturedAt: Date = Date(timeIntervalSince1970: 100),
    meetingTime: Duration = .seconds(1)
  ) -> CapturedPCM {
    CapturedPCM(
      source: source,
      sampleRate: sampleRate,
      channels: 1,
      capturedAt: capturedAt,
      meetingTime: meetingTime,
      payload: samples.pcmData
    )
  }

  private static func sampleCount(_ duration: TimeInterval) -> Int {
    max(0, Int((duration * Double(sampleRate)).rounded()))
  }
}

extension Array where Element == Int16 {
  var pcmData: Data { withUnsafeBytes { Data($0) } }
}
