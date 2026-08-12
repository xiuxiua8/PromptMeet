import Foundation

@testable import PromptMeet

/// In-memory outbox used by `MeetingStore` tests so runs stay isolated from
/// the real on-disk outbox and from other test runs' leftover meetings.
actor TranscriptOutboxSpy: TranscriptOutboxStoring {
    private var entries: [LocalTranscript] = []
    private var activeMeetings: [ActiveMeetingEnvelope] = []
    private var finalizations: [PendingMeetingFinalization] = []

    func enqueue(_ transcript: LocalTranscript, meetingID: String) async throws {
        entries.append(transcript)
    }

    func pending(meetingID: String) async throws -> [LocalTranscript] {
        entries
    }

    func acknowledge(_ transcriptID: UUID, meetingID: String) async throws {
        entries.removeAll { $0.id == transcriptID }
    }

    func markActiveMeeting(_ meeting: ActiveMeetingEnvelope) async throws {
        guard !activeMeetings.contains(where: { $0.meetingID == meeting.meetingID }),
              !finalizations.contains(where: { $0.meetingID == meeting.meetingID }) else {
            return
        }
        activeMeetings.append(meeting)
    }

    func markPendingFinalization(
        _ finalization: PendingMeetingFinalization
    ) async throws {
        activeMeetings.removeAll { $0.meetingID == finalization.meetingID }
        if !finalizations.contains(where: { $0.meetingID == finalization.meetingID }) {
            finalizations.append(finalization)
        }
    }

    func pendingFinalizations() async throws -> [PendingMeetingFinalization] {
        for meeting in activeMeetings where !finalizations.contains(
            where: { $0.meetingID == meeting.meetingID }
        ) {
            finalizations.append(
                PendingMeetingFinalization(
                    meetingID: meeting.meetingID,
                    startedAt: meeting.startedAt
                )
            )
        }
        activeMeetings.removeAll()
        return finalizations.sorted { $0.startedAt < $1.startedAt }
    }

    func completeFinalization(meetingID: String) async throws {
        activeMeetings.removeAll { $0.meetingID == meetingID }
        finalizations.removeAll { $0.meetingID == meetingID }
    }
}
