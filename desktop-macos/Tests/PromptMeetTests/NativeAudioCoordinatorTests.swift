import Foundation
import XCTest

@testable import PromptMeet

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
