import Foundation
import XCTest
@testable import PromptMeet

final class WorkspaceProjectionTests: XCTestCase {
    func testMixedTimelineKeepsBackendSequenceAndConversationSources() throws {
        let data = Data(
            #"[{"schema_version":2,"meeting_id":"meeting-1","status":"completed","started_at":"2026-07-25T10:00:00Z","ended_at":null,"events":[{"event_id":"event-1","meeting_id":"meeting-1","sequence":1,"occurred_at":"2026-07-25T10:01:00Z","kind":"transcript","provenance":{"source":"native_transcript"},"payload":{"type":"transcript","segment_id":"4E2CB506-925E-4A6E-BB68-E5006AB09BDF","text":"范围冻结","speaker":"林晨","source":"microphone","translated_text":null}},{"event_id":"event-2","meeting_id":"meeting-1","sequence":2,"occurred_at":"2026-07-25T10:02:00Z","kind":"user_question","provenance":{"source":"user","request_id":"11111111-1111-1111-1111-111111111111"},"payload":{"type":"user_question","request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","question":"风险？"}},{"event_id":"event-3","meeting_id":"meeting-1","sequence":3,"occurred_at":"2026-07-25T10:03:00Z","kind":"assistant_answer","provenance":{"source":"meeting_agent","provider":"openai","model":"gpt-4o","request_id":"11111111-1111-1111-1111-111111111111"},"payload":{"type":"assistant_answer","request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","answer":"范围漂移 [M1]","sources":[{"source_id":"M1","event_id":"event-1","label":"会议转写"}],"degraded_vision":false,"status":"completed","error_message":null}}]}]"#.utf8
        )
        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        let projection = WorkspaceProjection(meeting: meeting)

        XCTAssertEqual(projection.items.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(projection.items.map(\.kind), [.transcript, .question, .answer])
        XCTAssertEqual(projection.conversation.first?.sources.first?.sourceID, "M1")
        XCTAssertFalse(projection.isEmpty)
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
