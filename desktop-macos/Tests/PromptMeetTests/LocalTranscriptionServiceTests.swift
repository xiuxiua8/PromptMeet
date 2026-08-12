import Foundation
import XCTest

@testable import PromptMeet

final class LocalTranscriptionServiceTests: XCTestCase {
  func testSilenceDCAndWhiteNoiseNeverReachWhisperOrPublishTranscript() async throws {
    let engine = RecordingTranscriptionEngine(response: "hallucinated text")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 1
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(PCMTestFixtures.packet(PCMTestFixtures.silence()))
    await service.consume(PCMTestFixtures.packet(PCMTestFixtures.dcOffset()))
    await service.consume(PCMTestFixtures.packet(PCMTestFixtures.whiteNoise()))
    await service.stop()

    let submissionCount = await engine.submissionCount
    XCTAssertEqual(submissionCount, 0)
    XCTAssertEqual(transcripts.values, [])
  }

  func testQuietSpeechAfterSilenceReachesWhisperAndPublishesOnce() async throws {
    let engine = RecordingTranscriptionEngine(response: "quiet speech")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.silenceThenQuietSpeech())
    )
    await waitUntil { transcripts.values.count == 1 }
    await service.stop()

    let submissionCount = await engine.submissionCount
    XCTAssertEqual(submissionCount, 1)
    XCTAssertEqual(transcripts.values.map(\.text), ["quiet speech"])
    XCTAssertEqual(transcripts.values.map(\.source), [.microphone])
  }

  func testSystemSpeechFinalizesWhenScreenCaptureStopsDeliveringBuffers() async throws {
    let engine = RecordingTranscriptionEngine(response: "system speech")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(
      PCMTestFixtures.packet(
        PCMTestFixtures.voicedSpeech(duration: 1.3),
        source: .system
      )
    )
    await waitUntil { transcripts.values.count == 1 }
    await service.stop()

    XCTAssertEqual(transcripts.values.map(\.text), ["system speech"])
    XCTAssertEqual(transcripts.values.map(\.source), [.system])
  }

  func testNewSystemPacketSupersedesEarlierInactivityClose() async throws {
    let engine = RecordingTranscriptionEngine(response: "continuous system speech")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(
      PCMTestFixtures.packet(
        PCMTestFixtures.voicedSpeech(duration: 0.35),
        source: .system
      )
    )
    try await Task.sleep(for: .milliseconds(500))
    await service.consume(
      PCMTestFixtures.packet(
        PCMTestFixtures.voicedSpeech(duration: 0.35),
        source: .system,
        capturedAt: Date(timeIntervalSince1970: 100.5),
        meetingTime: .milliseconds(1_500)
      )
    )
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertTrue(transcripts.values.isEmpty)
    await waitUntil { transcripts.values.count == 1 }
    await service.stop()
    XCTAssertEqual(transcripts.values.map(\.text), ["continuous system speech"])
  }

  func testPauseInvalidatesInFlightResultAndDoesNotReplayBufferedAudio() async throws {
    let engine = RecordingTranscriptionEngine(
      response: "late text",
      delay: .milliseconds(120)
    )
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(PCMTestFixtures.packet(speechUtterance()))
    await waitUntil { await engine.submissionCount == 1 }
    await service.pause()
    try await Task.sleep(for: .milliseconds(160))

    XCTAssertTrue(transcripts.values.isEmpty)

    await service.consume(PCMTestFixtures.packet(speechUtterance()))
    await waitUntil { transcripts.values.count == 1 }
    await service.stop()

    let submissionCount = await engine.submissionCount
    XCTAssertEqual(submissionCount, 2)
    XCTAssertEqual(transcripts.values.count, 1)
  }

  func testStopCancelsQueueAndIgnoresLateEngineResult() async throws {
    let engine = RecordingTranscriptionEngine(
      response: "phantom final",
      delay: .milliseconds(300)
    )
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(
      PCMTestFixtures.packet(speechUtterance() + speechUtterance())
    )
    await waitUntil { await engine.submissionCount == 1 }
    let clock = ContinuousClock()
    let started = clock.now
    await service.stop()
    let stopDuration = started.duration(to: clock.now)
    try await Task.sleep(for: .milliseconds(340))

    XCTAssertLessThan(stopDuration, .milliseconds(150))
    let submissionCount = await engine.submissionCount
    XCTAssertEqual(submissionCount, 1)
    XCTAssertTrue(transcripts.values.isEmpty)
  }

  func testStopDiscardsOpenSpeechInsteadOfCreatingPhantomFinalSubmission() async throws {
    let engine = RecordingTranscriptionEngine(response: "phantom final")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    try await start(service, transcripts: transcripts)

    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.voicedSpeech(duration: 0.35))
    )
    await service.stop()

    let submissionCount = await engine.submissionCount
    XCTAssertEqual(submissionCount, 0)
    XCTAssertTrue(transcripts.values.isEmpty)
  }

  func testSignalStateCallbackPublishesOnlySourceTransitions() async throws {
    let engine = RecordingTranscriptionEngine(response: "speech")
    let service = LocalTranscriptionService(
      engineFactory: FixedTranscriptionEngineFactory(engine: engine),
      segmentDuration: 8
    )
    let transcripts = LocalTranscriptRecorder()
    let signals = SignalStateRecorder()
    try await start(service, transcripts: transcripts, signals: signals)

    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.silence(duration: 0.5))
    )
    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.voicedSpeech(duration: 0.35))
    )
    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.voicedSpeech(duration: 0.2))
    )
    await service.consume(
      PCMTestFixtures.packet(PCMTestFixtures.silence(duration: 0.4))
    )
    await service.stop()

    XCTAssertEqual(
      signals.values,
      [
        SignalStateRecorder.Value(source: .microphone, state: .silenceFiltered),
        SignalStateRecorder.Value(source: .microphone, state: .speechDetected),
        SignalStateRecorder.Value(source: .microphone, state: .silenceFiltered)
      ]
    )
  }

  private func start(
    _ service: LocalTranscriptionService,
    transcripts: LocalTranscriptRecorder,
    signals: SignalStateRecorder? = nil
  ) async throws {
    try await service.start(
      onPartialTranscript: { _ in },
      onTranscript: { transcripts.append($0) },
      onSignalState: { source, state in signals?.append(source, state) },
      onError: { _ in }
    )
  }

  private func speechUtterance() -> [Int16] {
    PCMTestFixtures.voicedSpeech(duration: 0.35)
      + PCMTestFixtures.silence(duration: 0.4)
  }

  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async {
    for _ in 0..<200 {
      if await predicate() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

private struct FixedTranscriptionEngineFactory: LocalTranscriptionEngineBuilding {
  let engine: RecordingTranscriptionEngine

  func makeEngine() throws -> any LocalTranscriptionEngine {
    engine
  }
}

private actor RecordingTranscriptionEngine: LocalTranscriptionEngine {
  private(set) var segments: [PCMTranscriptionSegment] = []
  private(set) var requestedLanguages: [String] = []
  private let response: String
  private let delay: Duration?

  init(response: String, delay: Duration? = nil) {
    self.response = response
    self.delay = delay
  }

  var submissionCount: Int { segments.count }

  func transcribe(
    _ segment: PCMTranscriptionSegment,
    language: String
  ) async throws -> RawWhisperTranscription {
    segments.append(segment)
    requestedLanguages.append(language)
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return RawWhisperTranscription.plain(response)
  }
}

private final class LocalTranscriptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [LocalTranscript] = []

  var values: [LocalTranscript] { lock.withLock { storage } }

  func append(_ transcript: LocalTranscript) {
    lock.withLock { storage.append(transcript) }
  }
}

private final class SignalStateRecorder: @unchecked Sendable {
  struct Value: Equatable {
    let source: NativeAudioSource
    let state: AudioSignalState
  }

  private let lock = NSLock()
  private var storage: [Value] = []

  var values: [Value] { lock.withLock { storage } }

  func append(_ source: NativeAudioSource, _ state: AudioSignalState) {
    lock.withLock { storage.append(Value(source: source, state: state)) }
  }
}
