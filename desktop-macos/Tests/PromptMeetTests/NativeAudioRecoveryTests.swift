import XCTest

@testable import PromptMeet

final class NativeAudioRecoveryTests: XCTestCase {
  @MainActor
  func testRapidPauseAndResumeAreIdempotent() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(sources: [system])
    try await start(coordinator)

    await coordinator.pause()
    await coordinator.pause()
    try await coordinator.resume()
    try await coordinator.resume()

    XCTAssertEqual(system.stopCount, 1)
    XCTAssertEqual(system.startCount, 2)
  }

  @MainActor
  func testFailedResumeRemainsPausedAndCanRetryAllPreviousSources() async throws {
    let system = FailOnRestartCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(sources: [system])
    try await start(coordinator)
    await coordinator.pause()

    do {
      try await coordinator.resume()
      XCTFail("Expected first resume to fail")
    } catch {}
    do {
      try await coordinator.resume()
      XCTFail("Expected second resume to retry and fail")
    } catch {}

    XCTAssertEqual(system.startCount, 3)
  }

  // MARK: - Automatic runtime recovery

  @MainActor
  func testRuntimeFailureAutoRecoversSystemSourceAndKeepsMicrophoneActive() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let microphone = NativeAudioSourceCaptureSpy(source: .microphone)
    let transcription = LocalTranscriptionServiceSpy()
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [system, microphone],
      uploader: NativeAudioUploaderSpy(),
      transcription: transcription,
      recoveryDelay: { _ in .milliseconds(200) }
    )
    let snapshots = CaptureSnapshotRecorder()
    try await start(coordinator, onStatus: { snapshots.append($0) })
    await transcription.emitSignal(.microphone, .speechDetected)

    system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
    await waitUntil { snapshots.last?.system == .failed("系统音频采集失败：stream stopped") }

    XCTAssertEqual(snapshots.last?.microphone, .active)
    XCTAssertEqual(microphone.stopCount, 0)
    XCTAssertEqual(microphone.startCount, 1)

    await waitUntil { snapshots.last?.system == .active }

    XCTAssertEqual(system.startCount, 2)
    XCTAssertEqual(system.stopCount, 1)
    XCTAssertEqual(snapshots.last?.microphone, .active)
    XCTAssertEqual(snapshots.last?.microphoneSignal, .speechDetected)
    XCTAssertEqual(microphone.stopCount, 0)
  }

  @MainActor
  func testFailedRuntimeRestartKeepsRetryingUntilStopped() async throws {
    let system = FailOnRestartCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(
      sources: [system],
      recoveryDelay: { _ in .milliseconds(10) }
    )
    let snapshots = CaptureSnapshotRecorder()
    try await start(coordinator, onStatus: { snapshots.append($0) })

    system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
    await waitUntil { system.startCount >= 3 }

    // Failed attempts surface as failed state between retries and the loop
    // keeps going instead of leaving the transcript silent forever.
    XCTAssertTrue(
      snapshots.all.contains { $0.system == .starting },
      "expected at least one starting transition during recovery"
    )
    await waitUntil { system.startCount >= 4 }
    XCTAssertEqual(snapshots.last?.system, .failed("系统音频采集失败：restart failed"))

    await coordinator.stop()
  }

  @MainActor
  func testUnavailableRuntimeFailureDoesNotAutoRetry() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(
      sources: [system],
      recoveryDelay: { _ in .milliseconds(10) }
    )
    try await start(coordinator)

    system.fail(CaptureError.noDisplay)
    await waitUntil { system.startCount >= 1 }
    try await Task.sleep(for: .milliseconds(150))

    XCTAssertEqual(system.startCount, 1, "unavailable sources must not auto-retry")
  }

  @MainActor
  func testPauseCancelsPendingRecoveryAndResumeRestoresTheSource() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(
      sources: [system],
      recoveryDelay: { _ in .milliseconds(200) }
    )
    try await start(coordinator)

    system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
    await waitUntil { system.startCount >= 1 }
    try await Task.sleep(for: .milliseconds(30))
    await coordinator.pause()

    // The pending automatic restart must not fire while paused.
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(system.startCount, 1)

    try await coordinator.resume()
    await waitUntil { system.startCount == 2 }
  }

  @MainActor
  func testStopCancelsPendingRecovery() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(
      sources: [system],
      recoveryDelay: { _ in .milliseconds(50) }
    )
    try await start(coordinator)

    system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
    await waitUntil { system.startCount >= 1 }
    try await Task.sleep(for: .milliseconds(10))
    await coordinator.stop()

    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(system.startCount, 1, "stop must cancel the pending restart")
  }

  @MainActor
  func testManualRetryCancelsPendingRecoveryWithoutDoubleStart() async throws {
    let system = NativeAudioSourceCaptureSpy(source: .system)
    let coordinator = recoveryCoordinator(
      sources: [system],
      recoveryDelay: { _ in .milliseconds(200) }
    )
    try await start(coordinator)

    system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
    await waitUntil { system.startCount >= 1 }
    try await Task.sleep(for: .milliseconds(10))
    try await coordinator.retry(.system)

    await waitUntil { system.startCount == 2 }
    // The superseded recovery task must not start the source a third time.
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(system.startCount, 2)
  }

  // MARK: - Helpers

  @MainActor
  private func recoveryCoordinator(
    sources: [NativeAudioSourceCapture],
    recoveryDelay: @escaping (Int) -> Duration = NativeAudioCaptureCoordinator
      .defaultRecoveryDelay
  ) -> NativeAudioCaptureCoordinator {
    NativeAudioCaptureCoordinator(
      sources: sources,
      uploader: NativeAudioUploaderSpy(),
      transcription: LocalTranscriptionServiceSpy(),
      recoveryDelay: recoveryDelay
    )
  }

  @MainActor
  private func start(
    _ coordinator: NativeAudioCaptureCoordinator,
    onStatus: @escaping @Sendable (AudioCaptureSnapshot) -> Void = { _ in }
  ) async throws {
    try await coordinator.start(
      request: NativeAudioCaptureRequest(
        sessionID: "local-1",
        includeLocalMicrophone: true
      ),
      onStatus: onStatus,
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
  }

  @MainActor
  private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
  ) async {
    for _ in 0..<200 {
      if await predicate() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}
