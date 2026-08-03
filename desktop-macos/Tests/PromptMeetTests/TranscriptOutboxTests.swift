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
        let failedPending = try await outbox.pending(meetingID: "session-1")
        XCTAssertEqual(failedPending.map(\.id), [system.id, microphone.id])
        backend.emit(.companionDisconnected("连接已关闭"))
        backend.transcriptSubmissionError = nil

        await store.reconnectCompanionNow()
        backend.emit(.connectionEstablished)
        await Task.yield()
        await store.synchronizeTranscriptOutboxNow(sessionID: "session-1")

        XCTAssertEqual(
            Array(backend.submittedTranscripts.suffix(2)).map(\.id),
            [system.id, microphone.id]
        )
        XCTAssertEqual(
            Array(backend.submittedTranscripts.suffix(2)).map(\.source),
            [.system, .microphone]
        )
        let replayedPending = try await outbox.pending(meetingID: "session-1")
        XCTAssertTrue(replayedPending.isEmpty)
    }

    private func temporaryOutboxURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptMeetOutboxTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transcripts.json")
    }
}
