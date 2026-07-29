import Foundation
import XCTest
@testable import PromptMeet

final class WorkspaceProjectionTests: XCTestCase {
    func testMixedTimelineProjectsInputLeftAndConversationRight() throws {
        let meeting = projectionMeeting(
            timeline: [transcriptEvent(), questionEvent(sequence: 2), answerEvent(sequence: 3)]
        )

        let projection = WorkspaceProjection(meeting: meeting)

        XCTAssertEqual(projection.items.map(\.sequence), [1])
        XCTAssertEqual(projection.items.map(\.kind), [.transcript])
        XCTAssertEqual(projection.conversation.first?.sources.first?.sourceID, "M1")
        XCTAssertFalse(projection.isEmpty)
    }

    func testSuggestionsAndDiscussionNeverBecomeInputItems() throws {
        let suggestions = timelineEvent(
            sequence: 1,
            kind: .suggestions,
            payload: .suggestions(
                TimelineSuggestionPayload(
                    generationID: "gen-1",
                    contextRevision: 1,
                    questions: ["问题一", "问题二", "问题三"]
                )
            )
        )
        let meeting = projectionMeeting(
            timeline: [suggestions, questionEvent(sequence: 2), answerEvent(sequence: 3)]
        )

        let projection = WorkspaceProjection(meeting: meeting)

        XCTAssertTrue(projection.items.isEmpty)
        XCTAssertEqual(projection.conversation.map(\.question), ["风险？"])
        XCTAssertEqual(projection.conversation.map(\.answer), ["范围漂移"])
    }

    func testEmptyAndFailedConversationStatesAreExplicit() {
        let empty = WorkspaceProjection(meeting: nil)
        let failed = ConversationTurn(
            id: "request-1",
            requestID: "request-1",
            threadID: "main",
            question: "重试？",
            answer: "",
            phase: .failed,
            errorMessage: "模型离线",
            sources: [],
            degradedVision: false,
            askedAt: Date(),
            answeredAt: Date()
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(WorkspaceProjection.retryableTurns([failed]).contains("request-1"))
    }
}

private let projectionRequestID = "11111111-1111-1111-1111-111111111111"

private func projectionMeeting(timeline: [MeetingTimelineEvent]) -> StoredMeeting {
    StoredMeeting(
        id: "meeting-1",
        schemaVersion: 2,
        startTime: Date(timeIntervalSince1970: 1_000),
        timeline: timeline,
        transcript: [],
        summary: nil
    )
}

private func timelineEvent(
    sequence: Int,
    kind: MeetingTimelineKind,
    payload: MeetingTimelinePayload
) -> MeetingTimelineEvent {
    MeetingTimelineEvent(
        eventID: "event-\(sequence)",
        meetingID: "meeting-1",
        sequence: sequence,
        occurredAt: Date(timeIntervalSince1970: TimeInterval(1_000 + sequence)),
        kind: kind,
        provenance: TimelineProvenance(
            source: "test",
            provider: nil,
            model: nil,
            requestID: projectionRequestID
        ),
        payload: payload
    )
}

private func transcriptEvent() -> MeetingTimelineEvent {
    timelineEvent(
        sequence: 1,
        kind: .transcript,
        payload: .transcript(
            TimelineTranscriptPayload(
                segmentID: "4E2CB506-925E-4A6E-BB68-E5006AB09BDF",
                text: "范围冻结",
                speaker: "林晨",
                source: "microphone",
                translatedText: nil,
                meetingTimeMilliseconds: nil
            )
        )
    )
}

private func questionEvent(sequence: Int) -> MeetingTimelineEvent {
    timelineEvent(
        sequence: sequence,
        kind: .userQuestion,
        payload: .userQuestion(
            TimelineQuestionPayload(
                requestID: projectionRequestID,
                threadID: "main",
                question: "风险？"
            )
        )
    )
}

private func answerEvent(sequence: Int) -> MeetingTimelineEvent {
    timelineEvent(
        sequence: sequence,
        kind: .assistantAnswer,
        payload: .assistantAnswer(
            TimelineAnswerPayload(
                requestID: projectionRequestID,
                threadID: "main",
                answer: "范围漂移",
                sources: [EvidenceSource(sourceID: "M1", eventID: "event-1", label: "会议转写")],
                degradedVision: false,
                status: "completed",
                errorMessage: nil
            )
        )
    )
}
