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
        XCTAssertEqual(request.httpBody, Data([0, 1]))
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
}

private final class NativeAudioSourceCaptureSpy: NativeAudioSourceCapture, @unchecked Sendable {
    let source: NativeAudioSource
    let error: (any Error)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(source: NativeAudioSource, error: (any Error)? = nil) {
        self.source = source
        self.error = error
    }

    func start(handler: @escaping @Sendable (CapturedPCM) -> Void) async throws {
        startCount += 1
        if let error { throw error }
    }

    func stop() async {
        stopCount += 1
    }
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
    func start(
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onTranscript: @escaping @Sendable (LocalTranscript) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {}

    func consume(_ pcm: CapturedPCM) async {}
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
