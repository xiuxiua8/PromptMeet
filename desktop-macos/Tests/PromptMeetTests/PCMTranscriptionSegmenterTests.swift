import Foundation
import XCTest

@testable import PromptMeet

final class PCMTranscriptionSegmenterTests: XCTestCase {
  func testLocalTranscriptionKeepsOriginalEightSecondChunksByDefault() {
    XCTAssertEqual(LocalTranscriptionService.defaultSegmentDuration, 8)
  }

  func testDefaultStreamingPreviewKeepsOriginalOnePointTwoFiveSecondCadence() {
    var segmenter = PCMTranscriptionSegmenter()
    let speech = PCMTestFixtures.voicedSpeech(duration: 1.25)
    let earlySamples = Array(speech.prefix(12_000)).pcmData
    let remainingSamples = Array(speech.dropFirst(12_000)).pcmData

    let early = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: earlySamples)
    )
    let originalCadence = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: remainingSamples)
    )

    XCTAssertNil(early.preview)
    XCTAssertEqual(originalCadence.preview?.samples.count, 20_000)
    XCTAssertTrue(originalCadence.finalized.isEmpty)
  }

  func testStreamingPreviewRefreshesBeforeLongSegmentIsFinalized() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 4,
      previewInterval: 1,
      minimumPreviewDuration: 1
    )
    let oneSecond = PCMTestFixtures.voicedSpeech().pcmData

    let first = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
    )
    let second = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
    )
    _ = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
    )
    let finalized = segmenter.consumeStreaming(
      CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
    )

    XCTAssertEqual(first.preview?.samples.count, 16_000)
    XCTAssertEqual(second.preview?.samples.count, 32_000)
    XCTAssertTrue(first.finalized.isEmpty)
    XCTAssertEqual(finalized.finalized.first?.samples.count, 64_000)
    XCTAssertNil(finalized.preview)
  }

  func testSegmenterEmitsThreeSecondMonoSegmentAt16kHz() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3)
    let samples = PCMTestFixtures.voicedSpeech(duration: 3)
    let packet = CapturedPCM(
      source: .system, sampleRate: 16_000, channels: 1, payload: samples.pcmData)

    let output = segmenter.consume(packet)

    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0].source, .system)
    XCTAssertEqual(output[0].samples.count, 48_000)
    XCTAssertEqual(output[0].sampleRate, 16_000)
  }

  func testSegmentKeepsFirstCaptureTimeAndMeetingOffset() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
    let capturedAt = Date(timeIntervalSince1970: 100)
    let samples = PCMTestFixtures.voicedSpeech()

    let output = segmenter.consume(
      CapturedPCM(
        source: .microphone,
        sampleRate: 16_000,
        channels: 1,
        capturedAt: capturedAt,
        meetingTime: .milliseconds(1_250),
        payload: samples.pcmData
      )
    )

    XCTAssertEqual(output.first?.capturedAt, capturedAt)
    XCTAssertEqual(output.first?.meetingTime, .milliseconds(1_250))
  }

  func testSegmenterKeepsSourcesSeparateAndFlushesRemainder() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3, minimumFlushDuration: 0.5)
    let oneSecond = PCMTestFixtures.voicedSpeech().pcmData

    XCTAssertTrue(
      segmenter.consume(
        CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: oneSecond)
      ).isEmpty
    )
    XCTAssertTrue(
      segmenter.consume(
        CapturedPCM(source: .microphone, sampleRate: 16_000, channels: 1, payload: oneSecond)
      )
      .isEmpty)

    let flushed = segmenter.flush()
    XCTAssertEqual(Set(flushed.map(\.source)), Set([.system, .microphone]))
    XCTAssertEqual(flushed.map(\.samples.count).sorted(), [16_000, 16_000])
  }

  func testPauseBoundaryDiscardsBufferedAudioInsteadOfReplayingIt() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 3, minimumFlushDuration: 0.5)
    let oneSecond = PCMTestFixtures.voicedSpeech().pcmData
    _ = segmenter.consume(
      CapturedPCM(source: .system, sampleRate: 16_000, channels: 1, payload: oneSecond)
    )

    segmenter.discardBufferedAudio()

    XCTAssertTrue(segmenter.flush().isEmpty)
  }

  func testSegmenterResamples48kHzInput() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
    let samples = PCMTestFixtures.voicedSpeech().flatMap { [$0, $0, $0] }

    let output = segmenter.consume(
      CapturedPCM(source: .microphone, sampleRate: 48_000, channels: 1, payload: samples.pcmData)
    )

    XCTAssertEqual(output.first?.samples.count, 16_000)
  }

  func testWaveWriterCreatesPCM16Header() throws {
    let data = PCM16WaveWriter.data(samples: [0, 1, -1], sampleRate: 16_000)

    XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
    XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
    XCTAssertEqual(data.count, 50)
  }

  func testFloatSamplesAreClampedAndEncodedAsPCM16() {
    let data = PCM16SampleEncoder.data(floatSamples: [-2, -1, 0, 1, 2])
    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

    XCTAssertEqual(samples, [Int16.min + 1, Int16.min + 1, 0, Int16.max, Int16.max])
  }

  func testNearSilentSegmentIsNotSentToWhisper() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)
    let roomNoise = [Int16](repeating: 20, count: 16_000)

    XCTAssertTrue(
      segmenter.consume(
        CapturedPCM(
          source: .microphone,
          sampleRate: 16_000,
          channels: 1,
          payload: roomNoise.pcmData
        )
      ).isEmpty
    )
  }

  func testEmptyBufferDigitalSilenceAndDCOffsetAreNeverSentToWhisper() {
    for samples in [
      [Int16](),
      PCMTestFixtures.silence(),
      PCMTestFixtures.dcOffset()
    ] {
      var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)

      XCTAssertTrue(segmenter.consume(PCMTestFixtures.packet(samples)).isEmpty)
      XCTAssertTrue(segmenter.flush().isEmpty)
    }
  }
}

final class SpeechActivityGateTests: XCTestCase {
  func testSteadyWhiteNoiseFromEitherSourceIsNeverSentToWhisper() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 1)

    let microphone = segmenter.consume(
      PCMTestFixtures.packet(PCMTestFixtures.whiteNoise(), source: .microphone)
    )
    let system = segmenter.consume(
      PCMTestFixtures.packet(PCMTestFixtures.whiteNoise(seed: 0xBEEF), source: .system)
    )

    XCTAssertTrue(microphone.isEmpty)
    XCTAssertTrue(system.isEmpty)
    XCTAssertTrue(segmenter.flush().isEmpty)
    XCTAssertEqual(segmenter.diagnostics(for: .microphone).acceptedSpeechFrames, 0)
    XCTAssertGreaterThan(segmenter.diagnostics(for: .microphone).droppedNoiseFrames, 0)
    XCTAssertEqual(segmenter.diagnostics(for: .system).utterances, 0)
  }

  func testQuietSpeechAfterSilenceSurvivesPreRollAndHangover() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 8,
      minimumFlushDuration: 0.1
    )

    let consumed = segmenter.consume(
      PCMTestFixtures.packet(PCMTestFixtures.silenceThenQuietSpeech())
    )
    let finalized = consumed + segmenter.flush()

    XCTAssertEqual(
      finalized.count,
      1,
      "diagnostics: \(segmenter.diagnostics(for: .microphone))"
    )
    XCTAssertEqual(finalized.first?.source, .microphone)
    XCTAssertGreaterThanOrEqual(finalized.first?.samples.count ?? 0, 8_000)
    XCTAssertLessThan(finalized.first?.samples.count ?? .max, 20_000)
    XCTAssertEqual(segmenter.diagnostics(for: .microphone).utterances, 1)
    XCTAssertGreaterThan(segmenter.diagnostics(for: .microphone).acceptedSpeechFrames, 0)
    XCTAssertGreaterThan(segmenter.diagnostics(for: .microphone).droppedSilenceFrames, 0)
  }

  func testBriefSpeechAcrossChunkBoundaryIsNotClipped() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 8,
      minimumFlushDuration: 0.1
    )
    let input =
      PCMTestFixtures.silence(duration: 0.25)
      + PCMTestFixtures.speechBurst()
      + PCMTestFixtures.silence(duration: 0.4)
    let boundary = 5_100

    let first = segmenter.consume(
      PCMTestFixtures.packet(Array(input.prefix(boundary)))
    )
    let second = segmenter.consume(
      PCMTestFixtures.packet(Array(input.dropFirst(boundary)))
    )
    let finalized = first + second + segmenter.flush()

    XCTAssertEqual(
      finalized.count,
      1,
      "diagnostics: \(segmenter.diagnostics(for: .microphone))"
    )
    guard let segment = finalized.first else { return }
    XCTAssertTrue(segment.samples.contains { abs(Int($0)) > 500 })
    XCTAssertGreaterThan(segment.samples.count, PCMTestFixtures.speechBurst().count)
    XCTAssertLessThan(segment.samples.count, input.count)
    XCTAssertLessThan(
      segment.samples.firstIndex(where: { abs(Int($0)) > 500 }) ?? .max,
      4_000
    )
  }

  func testBriefSpeechAtStreamStartIsFinalizedAfterHangover() {
    var segmenter = PCMTranscriptionSegmenter(segmentDuration: 8)
    let input =
      PCMTestFixtures.speechBurst(duration: 0.16)
      + PCMTestFixtures.silence(duration: 0.4)

    let finalized = segmenter.consume(PCMTestFixtures.packet(input)) + segmenter.flush()

    XCTAssertEqual(
      finalized.count,
      1,
      "diagnostics: \(segmenter.diagnostics(for: .microphone))"
    )
    guard let segment = finalized.first else { return }
    XCTAssertTrue(segment.samples.contains { abs(Int($0)) > 500 })
  }

  func testSpeechSubmittedToWhisperHasDCOffsetRemoved() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 8,
      minimumFlushDuration: 0.1
    )
    let offsetSpeech = PCMTestFixtures.voicedSpeech(duration: 0.5).map {
      Int16(clamping: Int($0) + 1_200)
    }
    let input = offsetSpeech + PCMTestFixtures.silence(duration: 0.4)

    let finalized = segmenter.consume(PCMTestFixtures.packet(input)) + segmenter.flush()

    XCTAssertEqual(finalized.count, 1)
    let mean =
      finalized[0].samples.reduce(0.0) { $0 + Double($1) }
      / Double(finalized[0].samples.count)
    XCTAssertEqual(mean, 0, accuracy: 20)
  }

  func testSpeechTimingStartsAtBoundedPreRollAndRemainsMonotonic() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 0.4,
      minimumFlushDuration: 0.1
    )
    let capturedAt = Date(timeIntervalSince1970: 500)
    let input =
      PCMTestFixtures.silence(duration: 0.4)
      + PCMTestFixtures.voicedSpeech(duration: 1)
      + PCMTestFixtures.silence(duration: 0.4)

    let finalized =
      segmenter.consume(
        PCMTestFixtures.packet(
          input,
          capturedAt: capturedAt,
          meetingTime: .seconds(10)
        )
      ) + segmenter.flush()

    XCTAssertGreaterThanOrEqual(finalized.count, 2)
    XCTAssertEqual(
      finalized.first?.capturedAt.timeIntervalSince(capturedAt) ?? -1,
      0.2,
      accuracy: 0.026
    )
    XCTAssertEqual(finalized.first?.meetingTime, .milliseconds(10_200))
    XCTAssertTrue(
      zip(finalized, finalized.dropFirst()).allSatisfy { left, right in
        left.capturedAt < right.capturedAt && left.meetingTime < right.meetingTime
      })
  }

  func testMixedSourcesKeepIndependentNoiseFloorsAndSpeechBuffers() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 2,
      minimumFlushDuration: 0.1
    )
    let systemNoise = PCMTestFixtures.whiteNoise(duration: 1.2)
    let microphoneSpeech =
      PCMTestFixtures.silence(duration: 0.2)
      + PCMTestFixtures.overlappingSpeech(duration: 0.7)
      + PCMTestFixtures.silence(duration: 0.4)

    let system = segmenter.consume(
      PCMTestFixtures.packet(systemNoise, source: .system)
    )
    let microphone = segmenter.consume(
      PCMTestFixtures.packet(microphoneSpeech, source: .microphone)
    )
    let finalized = system + microphone + segmenter.flush()

    XCTAssertEqual(finalized.map(\.source), [.microphone])
    XCTAssertEqual(segmenter.diagnostics(for: .system).acceptedSpeechFrames, 0)
    XCTAssertEqual(segmenter.diagnostics(for: .microphone).utterances, 1)
  }

  func testSignalStateTransitionsOnlyWhenSpeechOpensOrCloses() {
    var segmenter = PCMTranscriptionSegmenter(
      segmentDuration: 8,
      minimumFlushDuration: 0.1
    )

    let initialSilence = segmenter.consumeStreaming(
      PCMTestFixtures.packet(PCMTestFixtures.silence(duration: 0.5))
    )
    let speechOpens = segmenter.consumeStreaming(
      PCMTestFixtures.packet(PCMTestFixtures.voicedSpeech(duration: 0.35))
    )
    let continuingSpeech = segmenter.consumeStreaming(
      PCMTestFixtures.packet(PCMTestFixtures.voicedSpeech(duration: 0.2))
    )
    let speechCloses = segmenter.consumeStreaming(
      PCMTestFixtures.packet(PCMTestFixtures.silence(duration: 0.4))
    )

    XCTAssertEqual(initialSilence.signalTransition, .silenceFiltered)
    XCTAssertEqual(speechOpens.signalTransition, .speechDetected)
    XCTAssertNil(continuingSpeech.signalTransition)
    XCTAssertEqual(speechCloses.signalTransition, .silenceFiltered)
  }
}
