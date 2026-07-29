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

    @MainActor
    func testRuntimeFailureMarksOnlyFailedSourceAndKeepsOtherSourceActive() async throws {
        let system = NativeAudioSourceCaptureSpy(source: .system)
        let microphone = NativeAudioSourceCaptureSpy(source: .microphone)
        let coordinator = recoveryCoordinator(sources: [system, microphone])
        let snapshots = CaptureSnapshotRecorder()
        try await start(coordinator, onStatus: { snapshots.append($0) })

        system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
        for _ in 0..<20 where snapshots.last?.system == .active {
            await Task.yield()
        }

        XCTAssertEqual(snapshots.last?.system, .failed("系统音频采集失败：stream stopped"))
        XCTAssertEqual(snapshots.last?.microphone, .active)
        XCTAssertEqual(microphone.stopCount, 0)
    }

    @MainActor
    private func recoveryCoordinator(
        sources: [NativeAudioSourceCapture]
    ) -> NativeAudioCaptureCoordinator {
        NativeAudioCaptureCoordinator(
            sources: sources,
            uploader: NativeAudioUploaderSpy(),
            transcription: LocalTranscriptionServiceSpy()
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
}
