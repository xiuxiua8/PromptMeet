import XCTest

@testable import PromptMeet

final class NativeAudioLifecycleTests: XCTestCase {
  @MainActor
  func testCoordinatorPausesTranscriptionBeforeWaitingForSlowUpload() async throws {
    let uploader = NonCooperativeNativeAudioUploader()
    let source = EmittingNativeAudioSourceCaptureSpy(source: .system)
    let transcription = LocalTranscriptionServiceSpy()
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [source],
      uploader: uploader,
      transcription: transcription
    )

    await coordinator.bindBackendSession("remote-session")
    try await coordinator.start(
      sessionID: "local-session",
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
    await uploader.waitUntilStarted()

    let pause = Task { @MainActor in await coordinator.pause() }
    try await Task.sleep(for: .milliseconds(30))
    let pauseCountBeforeUploadCompletes = await transcription.pauseCount
    await uploader.complete()
    await pause.value

    XCTAssertEqual(pauseCountBeforeUploadCompletes, 1)
  }

  @MainActor
  func testCoordinatorStopsTranscriptionBeforeWaitingForSlowUpload() async throws {
    let uploader = NonCooperativeNativeAudioUploader()
    let source = EmittingNativeAudioSourceCaptureSpy(source: .system)
    let transcription = LocalTranscriptionServiceSpy()
    let coordinator = NativeAudioCaptureCoordinator(
      sources: [source],
      uploader: uploader,
      transcription: transcription
    )

    await coordinator.bindBackendSession("remote-session")
    try await coordinator.start(
      sessionID: "local-session",
      onPartialTranscript: { _ in },
      onTranscript: { _ in },
      onTranscriptionError: { _ in }
    )
    await uploader.waitUntilStarted()

    let stop = Task { @MainActor in await coordinator.stop() }
    try await Task.sleep(for: .milliseconds(30))
    let stopCountBeforeUploadCompletes = await transcription.stopCount
    await uploader.complete()
    await stop.value

    XCTAssertEqual(stopCountBeforeUploadCompletes, 1)
  }
}
