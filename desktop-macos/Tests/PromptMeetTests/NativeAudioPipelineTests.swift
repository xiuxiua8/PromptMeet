import Foundation
import XCTest

@testable import PromptMeet

final class NativeAudioPipelineTests: XCTestCase {
  func testAudioPumpWaitsForRemoteSessionBeforeUploading() async throws {
    let uploader = RecordingNativeAudioUploader()
    let pump = NativeAudioPacketPump(uploader: uploader)
    let pcm = CapturedPCM(
      source: .microphone,
      sampleRate: 16_000,
      channels: 1,
      payload: Data([0, 1])
    )

    try await pump.consume(pcm)
    let beforeBinding = await uploader.sessionIDs
    XCTAssertEqual(beforeBinding, [])

    await pump.bind(sessionID: "remote-session")
    try await pump.consume(pcm)
    let afterBinding = await uploader.sessionIDs
    XCTAssertEqual(afterBinding, ["remote-session"])
  }

  @MainActor
  func testCoordinatorPrebindsRemoteSessionBeforeFirstSourceChunk() async throws {
    let uploader = RecordingNativeAudioUploader()
    let source = EmittingNativeAudioSourceCaptureSpy(source: .system)
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [source],
      uploader: uploader,
      transcription: LocalTranscriptionServiceSpy()
    )

    await coordinator.bindBackendSession("remote-session")
    try await coordinator.start(
      request: NativeAudioCaptureRequest(
        sessionID: "local-session",
        includeLocalMicrophone: true
      ),
      onStatus: { _ in },
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
    for _ in 0..<20 {
      if !(await uploader.sessionIDs).isEmpty { break }
      await Task.yield()
    }

    let uploadedSessionIDs = await uploader.sessionIDs
    XCTAssertEqual(uploadedSessionIDs, ["remote-session"])
    await coordinator.stop()
  }

  func testAudioPumpSerializesUploadsEvenWhenFirstRequestIsSlow() async throws {
    let uploader = DelayedNativeAudioUploader()
    let pump = NativeAudioPacketPump(uploader: uploader, sessionID: "remote-session")
    let pcm = CapturedPCM(
      source: .microphone,
      sampleRate: 16_000,
      channels: 1,
      payload: Data([0, 1])
    )

    let first = Task { try await pump.consume(pcm) }
    try await Task.sleep(for: .milliseconds(10))
    let second = Task { try await pump.consume(pcm) }
    try await first.value
    try await second.value

    let completedSequences = await uploader.completedSequences
    XCTAssertEqual(completedSequences, [0, 1])
  }

  func testAudioPumpBoundsOpenUploadWithExplicitDeadline() async {
    let pump = NativeAudioPacketPump(
      uploader: CancellableSlowNativeAudioUploader(),
      sessionID: "remote-session",
      uploadTimeout: .milliseconds(10)
    )
    let pcm = CapturedPCM(
      source: .system,
      sampleRate: 16_000,
      channels: 1,
      payload: Data(repeating: 0, count: 32_000)
    )

    do {
      try await pump.consume(pcm)
      XCTFail("Expected upload timeout")
    } catch {
      XCTAssertEqual(error as? NativeAudioUploadError, .timedOut)
    }
  }

  func testFrameDispatcherCoalescesPendingUploadPerSourceWhileTranscriptionContinues() async throws {
    let uploader = CoalescingNativeAudioUploader()
    let transcription = OrderedLocalTranscriptionServiceSpy()
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: NativeAudioPacketPump(
        uploader: uploader,
        sessionID: "remote-session"
      ),
      transcription: transcription
    )

    dispatcher.enqueue(
      CapturedPCM(
        source: .system,
        sampleRate: 16_000,
        channels: 1,
        meetingTime: .milliseconds(100),
        payload: Data(repeating: 0, count: 32_000)
      )
    )
    for _ in 0..<100 {
      if await uploader.packets.count == 1 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    for meetingTime in [200, 300] {
      dispatcher.enqueue(
        CapturedPCM(
          source: .system,
          sampleRate: 16_000,
          channels: 1,
          meetingTime: .milliseconds(meetingTime),
          payload: Data(repeating: 0, count: 32_000)
        )
      )
    }

    await dispatcher.drain()

    let uploadedPackets = await uploader.packets
    let uploadedTimes = uploadedPackets.map(\.meetingTime)
    let transcribedTimes = await transcription.meetingTimes
    XCTAssertEqual(uploadedTimes, [.milliseconds(100), .milliseconds(300)])
    XCTAssertEqual(
      transcribedTimes,
      [.milliseconds(100), .milliseconds(200), .milliseconds(300)]
    )
  }

  func testFrameDispatcherPreservesTranscriptionOrderAcrossSlowUpload() async throws {
    let uploader = DelayedNativeAudioUploader()
    let packetPump = NativeAudioPacketPump(uploader: uploader, sessionID: "remote-session")
    let transcription = OrderedLocalTranscriptionServiceSpy()
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: packetPump,
      transcription: transcription
    )

    dispatcher.enqueue(
      CapturedPCM(
        source: .system,
        sampleRate: 16_000,
        channels: 1,
        meetingTime: .milliseconds(100),
        payload: Data([0, 1])
      )
    )
    dispatcher.enqueue(
      CapturedPCM(
        source: .microphone,
        sampleRate: 16_000,
        channels: 1,
        meetingTime: .milliseconds(200),
        payload: Data([2, 3])
      )
    )
    try await Task.sleep(for: .milliseconds(20))
    let earlyMeetingTimes = await transcription.meetingTimes
    await dispatcher.drain()

    let meetingTimes = await transcription.meetingTimes
    XCTAssertEqual(earlyMeetingTimes, [.milliseconds(100), .milliseconds(200)])
    XCTAssertEqual(meetingTimes, [.milliseconds(100), .milliseconds(200)])
  }

  func testFrameDispatcherDropsQueuedFrameWhenSuspendedBeforeTranscription() async throws {
    let uploader = DelayedNativeAudioUploader()
    let packetPump = NativeAudioPacketPump(uploader: uploader, sessionID: "remote-session")
    let transcription = OrderedLocalTranscriptionServiceSpy()
    let dispatcher = NativeAudioFrameDispatcher(
      packetPump: packetPump,
      transcription: transcription
    )

    dispatcher.enqueue(
      CapturedPCM(
        source: .system,
        sampleRate: 16_000,
        channels: 1,
        meetingTime: .milliseconds(100),
        payload: Data([0, 1])
      )
    )
    try await Task.sleep(for: .milliseconds(10))
    await dispatcher.suspend()
    await transcription.pause()
    await dispatcher.resume()
    dispatcher.enqueue(
      CapturedPCM(
        source: .system,
        sampleRate: 16_000,
        channels: 1,
        meetingTime: .milliseconds(200),
        payload: Data([2, 3])
      )
    )
    await dispatcher.drain()

    let meetingTimes = await transcription.meetingTimes
    XCTAssertEqual(meetingTimes, [.milliseconds(200)])
  }

  func testSharedSequencerKeepsSystemAndMicrophoneChunksMonotonic() {
    var sequencer = NativeAudioSequencer()

    let system = sequencer.packet(
      source: .system,
      sampleRate: 16_000,
      channels: 1,
      payload: Data([1])
    )
    let microphone = sequencer.packet(
      source: .microphone,
      sampleRate: 16_000,
      channels: 1,
      payload: Data([2])
    )

    XCTAssertEqual(system.sequence, 0)
    XCTAssertEqual(microphone.sequence, 1)
  }

  func testUploadRequestMatchesNativeAudioEndpointContract() {
    let packet = NativeAudioPacket(
      sequence: 4,
      source: .mixed,
      sampleRate: 16_000,
      channels: 1,
      capturedAt: Date(timeIntervalSince1970: 100),
      meetingTime: .milliseconds(1_250),
      payload: Data([0, 1])
    )

    let request = NativeAudioUploader.makeRequest(
      packet: packet,
      sessionID: "session-1",
      environment: BackendEnvironment(baseURL: URL(string: "http://127.0.0.1:8000")!)
    )

    XCTAssertEqual(request.url?.path, "/api/sessions/session-1/native-audio")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-PromptMeet-Sequence"), "4")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-PromptMeet-Source"), "mixed")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-PromptMeet-Meeting-Time-Ms"), "1250")
    XCTAssertEqual(request.timeoutInterval, NativeAudioUploader.requestTimeout)
    XCTAssertEqual(request.httpBody, Data([0, 1]))
  }

  func testMeetingClockKeepsMonotonicTimeAcrossPauseInterval() {
    let clock = NativeAudioMeetingClock(originNanoseconds: 1_000_000_000)

    XCTAssertEqual(clock.offset(atNanoseconds: 1_250_000_000), .milliseconds(250))
    XCTAssertEqual(clock.offset(atNanoseconds: 4_000_000_000), .seconds(3))
    XCTAssertEqual(clock.offset(atNanoseconds: 900_000_000), .zero)
  }

}

final class NativeAudioCoordinatorTests: XCTestCase {
  @MainActor
  func testCoordinatorContinuesWithMicrophoneWhenSystemAudioFails() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system, error: CaptureError.noDisplay)
    let microphone = NativeAudioSourceCaptureSpy(source: .microphone)
    let transcription = LocalTranscriptionServiceSpy()
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: transcription
    )
    let warnings = WarningRecorder()

    try await coordinator.start(
      sessionID: "local-1",
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { warnings.append($0) }
    )

    XCTAssertEqual(system.startCount, 1)
    XCTAssertEqual(microphone.startCount, 1)
    XCTAssertEqual(microphone.stopCount, 0)
    XCTAssertEqual(warnings.count, 1)
    await coordinator.stop()
  }

  @MainActor
  func testCoordinatorDoesNotStartOrReportMicrophoneWhenPreferenceIsDisabled() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let microphone = NativeAudioSourceCaptureSpy(
      source: .microphone,
      error: CaptureError.microphoneDenied
    )
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: LocalTranscriptionServiceSpy()
    )
    let snapshots = CaptureSnapshotRecorder()
    let warnings = WarningRecorder()

    try await coordinator.start(
      request: NativeAudioCaptureRequest(
        sessionID: "local-1",
        includeLocalMicrophone: false
      ),
      onStatus: { snapshots.append($0) },
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { warnings.append($0) }
    )

    XCTAssertEqual(system.startCount, 1)
    XCTAssertEqual(microphone.startCount, 0)
    XCTAssertEqual(microphone.stopCount, 0)
    XCTAssertEqual(snapshots.last?.microphone, .idle)
    XCTAssertEqual(warnings.count, 0)
    await coordinator.stop()
  }

  @MainActor
  func testCoordinatorPublishesSignalTransitionsWithoutRelabelingPeerSource() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let microphone = NativeAudioSourceCaptureSpy(source: .microphone)
    let transcription = LocalTranscriptionServiceSpy()
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: transcription
    )
    let snapshots = CaptureSnapshotRecorder()

    try await coordinator.start(
      request: NativeAudioCaptureRequest(
        sessionID: "local-1",
        includeLocalMicrophone: true
      ),
      onStatus: { snapshots.append($0) },
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
    await transcription.emitSignal(.microphone, .speechDetected)
    await transcription.emitSignal(.system, .silenceFiltered)

    XCTAssertEqual(snapshots.last?.microphoneSignal, .speechDetected)
    XCTAssertEqual(snapshots.last?.systemSignal, .silenceFiltered)
    XCTAssertEqual(snapshots.last?.microphone, .active)
    XCTAssertEqual(snapshots.last?.system, .active)
    await coordinator.stop()
  }

  @MainActor
  func testCoordinatorFailsOnlyWhenEveryAudioSourceFails() async {
    let system = NativeAudioSourceCaptureSpy(source: .system, error: CaptureError.noDisplay)
    let microphone = NativeAudioSourceCaptureSpy(
      source: .microphone, error: CaptureError.microphoneDenied)
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: LocalTranscriptionServiceSpy()
    )

    do {
      try await coordinator.start(
        sessionID: "local-1",
        onPartialTranscript: { _ in },
        onTranscript: { _ in },
        onTranscriptionError: { _ in }
      )
      XCTFail("Expected all audio sources to fail")
    } catch {
      XCTAssertEqual(system.stopCount, 1)
      XCTAssertEqual(microphone.stopCount, 1)
    }
  }

  @MainActor
  func testPauseStopsOnlyActiveSourceAndResumeRestartsItOnce() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let microphone = NativeAudioSourceCaptureSpy(
      source: .microphone,
      error: CaptureError.microphoneDenied
    )
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: LocalTranscriptionServiceSpy()
    )
    let snapshots = CaptureSnapshotRecorder()

    try await coordinator.start(
      request: NativeAudioCaptureRequest(
        sessionID: "local-1",
        includeLocalMicrophone: true
      ),
      onStatus: { snapshots.append($0) },
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
    await coordinator.pause()
    try await coordinator.resume()

    XCTAssertEqual(system.startCount, 2)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertEqual(microphone.startCount, 1)
    XCTAssertEqual(microphone.stopCount, 1)
    XCTAssertEqual(snapshots.last?.system, .active)
    XCTAssertEqual(snapshots.last?.microphone, .denied)
  }
}
