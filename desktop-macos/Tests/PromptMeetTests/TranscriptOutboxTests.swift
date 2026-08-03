import Foundation
import XCTest

@testable import PromptMeet

final class TranscriptOutboxTests: XCTestCase {
    func testOutboxPersistsStableIdentitySourceAndOrderAcrossReload() async throws {
        let fileURL = temporaryOutboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let first = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            source: .system,
            text: "系统音频",
            timestamp: Date(timeIntervalSince1970: 10),
            meetingTime: .seconds(2)
        )
        let second = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            source: .microphone,
            text: "麦克风音频",
            timestamp: Date(timeIntervalSince1970: 11),
            meetingTime: .seconds(3)
        )
        let writer = TranscriptOutboxStore(fileURL: fileURL)

        try await writer.enqueue(first, meetingID: "meeting-a")
        try await writer.enqueue(second, meetingID: "meeting-a")
        try await writer.enqueue(first, meetingID: "meeting-a")
        let restored = TranscriptOutboxStore(fileURL: fileURL)
        let pending = try await restored.pending(meetingID: "meeting-a")

        XCTAssertEqual(pending.map(\.id), [first.id, second.id])
        XCTAssertEqual(pending.map(\.source), [.system, .microphone])
        try await restored.acknowledge(first.id, meetingID: "meeting-a")
        let afterAcknowledgement = try await TranscriptOutboxStore(fileURL: fileURL)
            .pending(meetingID: "meeting-a")
        XCTAssertEqual(afterAcknowledgement.map(\.id), [second.id])
    }

    @MainActor
    func testReconnectReplaysFailedTranscriptsInOrderAndRemovesAfterAck() async throws {
        let fileURL = temporaryOutboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let outbox = TranscriptOutboxStore(fileURL: fileURL)
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: outbox
        )
        await store.startMeetingNow()
        let meetingID = try XCTUnwrap(store.sessionID)
        backend.transcriptSubmissionError = BackendClientError.socketUnavailable
        let system = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            source: .system,
            text: "断线系统音频",
            timestamp: Date(timeIntervalSince1970: 20)
        )
        let microphone = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            source: .microphone,
            text: "断线麦克风音频",
            timestamp: Date(timeIntervalSince1970: 21)
        )

        await store.receiveLocalTranscript(system)
        await store.receiveLocalTranscript(microphone)
        let failedPending = try await outbox.pending(meetingID: meetingID)
        XCTAssertEqual(failedPending.map(\.id), [system.id, microphone.id])
        backend.emit(.companionDisconnected("连接已关闭"))
        backend.transcriptSubmissionError = nil

        await store.reconnectCompanionNow()
        backend.emit(.connectionEstablished)
        await Task.yield()
        await store.synchronizeTranscriptOutboxNow(sessionID: meetingID)

        XCTAssertEqual(
            Array(backend.submittedTranscripts.suffix(2)).map(\.id),
            [system.id, microphone.id]
        )
        XCTAssertEqual(
            Array(backend.submittedTranscripts.suffix(2)).map(\.source),
            [.system, .microphone]
        )
        let replayedPending = try await outbox.pending(meetingID: meetingID)
        XCTAssertTrue(replayedPending.isEmpty)
    }

    @MainActor
    func testTranscriptQueuesUnderCanonicalMeetingIDWithoutBackendSession() async throws {
        let fileURL = temporaryOutboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let outbox = TranscriptOutboxStore(fileURL: fileURL)
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(error: BackendClientError.socketUnavailable),
            transcriptOutbox: outbox
        )

        await store.startMeetingNow()
        let meetingID = try XCTUnwrap(store.sessionID)
        XCTAssertNil(store.backendSessionID)
        let transcript = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            source: .system,
            text: "后端不可用时的证据",
            timestamp: Date(timeIntervalSince1970: 30)
        )
        await store.receiveLocalTranscript(transcript)

        let pending = try await outbox.pending(meetingID: meetingID)
        XCTAssertEqual(pending.map(\.id), [transcript.id])
    }

    @MainActor
    func testOfflineStopPersistsAndRestartFinalizesSameMeeting() async throws {
        let fileURL = temporaryOutboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let firstOutbox = TranscriptOutboxStore(fileURL: fileURL)
        let firstBackend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let firstStore = MeetingStore(
            backend: firstBackend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            transcriptOutbox: firstOutbox,
            now: { Date(timeIntervalSince1970: 40) }
        )
        await firstStore.startMeetingNow()
        let meetingID = try XCTUnwrap(firstStore.sessionID)
        firstBackend.transcriptSubmissionError = BackendClientError.socketUnavailable
        let transcript = LocalTranscript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            source: .microphone,
            text: "离线结束前的证据",
            timestamp: Date(timeIntervalSince1970: 41)
        )
        await firstStore.receiveLocalTranscript(transcript)
        firstBackend.emit(.companionDisconnected("连接已关闭"))
        await Task.yield()

        await firstStore.endMeetingNow()

        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(firstStore.state.phase, .idle)
        let pendingFinalizations = try await firstOutbox.pendingFinalizations()
        XCTAssertEqual(pendingFinalizations.map(\.meetingID), [meetingID])

        let restoredOutbox = TranscriptOutboxStore(fileURL: fileURL)
        let restoredBackend = BackendClientSpy()
        let restoredStore = MeetingStore(
            backend: restoredBackend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: restoredOutbox
        )

        await restoredStore.prepareCompanionNow()

        XCTAssertEqual(restoredBackend.createdSessionRequests.map(\.sessionID), [meetingID])
        XCTAssertEqual(restoredBackend.submittedTranscripts.map(\.id), [transcript.id])
        XCTAssertEqual(
            Array(restoredBackend.performedActions.suffix(2)),
            ["stop-native-recording", "store-session"]
        )
        let remainingFinalizations = try await restoredOutbox.pendingFinalizations()
        let remainingTranscripts = try await restoredOutbox.pending(meetingID: meetingID)
        XCTAssertTrue(remainingFinalizations.isEmpty)
        XCTAssertTrue(remainingTranscripts.isEmpty)
    }

    private func temporaryOutboxURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptMeetOutboxTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transcripts.json")
    }
}
