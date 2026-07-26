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
            sessionID: "local-session",
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
        XCTAssertEqual(request.httpBody, Data([0, 1]))
    }

    func testMeetingClockKeepsMonotonicTimeAcrossPauseInterval() {
        let clock = NativeAudioMeetingClock(originNanoseconds: 1_000_000_000)

        XCTAssertEqual(clock.offset(atNanoseconds: 1_250_000_000), .milliseconds(250))
        XCTAssertEqual(clock.offset(atNanoseconds: 4_000_000_000), .seconds(3))
        XCTAssertEqual(clock.offset(atNanoseconds: 900_000_000), .zero)
    }

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
    func testCoordinatorFailsOnlyWhenEveryAudioSourceFails() async {
        let system = NativeAudioSourceCaptureSpy(source: .system, error: CaptureError.noDisplay)
        let microphone = NativeAudioSourceCaptureSpy(source: .microphone, error: CaptureError.microphoneDenied)
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
            sessionID: "local-1",
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

    @MainActor
    func testRapidPauseAndResumeAreIdempotent() async throws {
        let system = NativeAudioSourceCaptureSpy(source: .system)
        let coordinator = NativeAudioCaptureCoordinator(
            sources: [system],
            uploader: NativeAudioUploaderSpy(),
            transcription: LocalTranscriptionServiceSpy()
        )
        try await coordinator.start(
            sessionID: "local-1",
            onStatus: { _ in },
            onPartialTranscript: { _ in },
            onTranscript: { _ in },
            onTranscriptionError: { _ in }
        )

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
        let coordinator = NativeAudioCaptureCoordinator(
            sources: [system],
            uploader: NativeAudioUploaderSpy(),
            transcription: LocalTranscriptionServiceSpy()
        )
        try await coordinator.start(
            sessionID: "local-1",
            onStatus: { _ in },
            onPartialTranscript: { _ in },
            onTranscript: { _ in },
            onTranscriptionError: { _ in }
        )
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
        let coordinator = NativeAudioCaptureCoordinator(
            sources: [system, microphone],
            uploader: NativeAudioUploaderSpy(),
            transcription: LocalTranscriptionServiceSpy()
        )
        let snapshots = CaptureSnapshotRecorder()
        try await coordinator.start(
            sessionID: "local-1",
            onStatus: { snapshots.append($0) },
            onPartialTranscript: { _ in },
            onTranscript: { _ in },
            onTranscriptionError: { _ in }
        )

        system.fail(CaptureError.systemAudioRuntimeFailure("stream stopped"))
        for _ in 0..<20 where snapshots.last?.system == .active {
            await Task.yield()
        }

        XCTAssertEqual(snapshots.last?.system, .failed("系统音频采集失败：stream stopped"))
        XCTAssertEqual(snapshots.last?.microphone, .active)
        XCTAssertEqual(microphone.stopCount, 0)
    }
}

private final class NativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
    let source: NativeAudioSource
    let error: (any Error)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var failureHandler: (@Sendable (any Error) -> Void)?

    init(source: NativeAudioSource, error: (any Error)? = nil) {
        self.source = source
        self.error = error
    }

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        startCount += 1
        if let error { throw error }
    }

    func start(
        handler: @escaping @Sendable (CapturedPCM) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) async throws {
        failureHandler = onFailure
        try await start(handler: handler)
    }

    func stop() async {
        stopCount += 1
    }

    func fail(_ error: any Error) {
        failureHandler?(error)
    }
}

private final class EmittingNativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
    let source: NativeAudioSource

    init(source: NativeAudioSource) {
        self.source = source
    }

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        handler(
            CapturedPCM(
                source: source,
                sampleRate: 16_000,
                channels: 1,
                payload: Data([0, 1])
            )
        )
    }

    func stop() async {}
}

private final class FailOnRestartCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
    let source: NativeAudioSource
    private(set) var startCount = 0

    init(source: NativeAudioSource) {
        self.source = source
    }

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        startCount += 1
        if startCount > 1 {
            throw CaptureError.systemAudioRuntimeFailure("restart failed")
        }
    }

    func stop() async {}
}

private struct NativeAudioUploaderSpy: NativeAudioUploading {
    func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {}
}

private actor RecordingNativeAudioUploader: NativeAudioUploading {
    private(set) var sessionIDs: [String] = []

    func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
        sessionIDs.append(sessionID)
    }
}

private actor DelayedNativeAudioUploader: NativeAudioUploading {
    private(set) var completedSequences: [Int] = []

    func upload(_ packet: NativeAudioPacket, sessionID: String) async throws {
        if packet.sequence == 0 {
            try await Task.sleep(for: .milliseconds(80))
        }
        completedSequences.append(packet.sequence)
    }
}

private actor LocalTranscriptionServiceSpy: LocalTranscriptionServicing {
    private(set) var pauseCount = 0
    func start(
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {}

    func consume(_ pcm: CapturedPCM) async {}
    func pause() async { pauseCount += 1 }
    func stop() async {}
}

private final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var count: Int { lock.withLock { values.count } }

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }
}

private final class CaptureSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AudioCaptureSnapshot] = []

    var last: AudioCaptureSnapshot? { lock.withLock { values.last } }

    func append(_ value: AudioCaptureSnapshot) {
        lock.withLock { values.append(value) }
    }
}
