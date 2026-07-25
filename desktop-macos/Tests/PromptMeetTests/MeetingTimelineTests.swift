import Foundation
import XCTest
@testable import PromptMeet

final class MeetingTimelineTests: XCTestCase {
    func testVersionTwoRecordProjectsChronologicalMultimodalContent() throws {
        let data = Data(
            #"[{"schema_version":2,"meeting_id":"meeting-1","status":"completed","started_at":"2026-07-25T10:00:00Z","ended_at":"2026-07-25T11:00:00Z","events":[{"event_id":"event-1","meeting_id":"meeting-1","sequence":1,"occurred_at":"2026-07-25T10:01:00Z","kind":"transcript","provenance":{"source":"native_transcript"},"payload":{"type":"transcript","segment_id":"4E2CB506-925E-4A6E-BB68-E5006AB09BDF","text":"确认周五上线","speaker":"林晨","source":"microphone","translated_text":null}},{"event_id":"event-2","meeting_id":"meeting-1","sequence":2,"occurred_at":"2026-07-25T10:02:00Z","kind":"screenshot","provenance":{"source":"native_screenshot"},"payload":{"type":"screenshot","asset_id":"asset-1","relative_path":"assets/meeting-1/slide.png","mime_type":"image/png","sha256":"abc","width":1280,"height":720,"capture_status":"available"}},{"event_id":"event-3","meeting_id":"meeting-1","sequence":3,"occurred_at":"2026-07-25T10:03:00Z","kind":"screenshot_analysis","provenance":{"source":"multimodal_analysis","provider":"openai","model":"gpt-4o"},"payload":{"type":"screenshot_analysis","asset_id":"asset-1","status":"completed","text":"截图显示周岚负责回滚","vision_used":true}},{"event_id":"event-4","meeting_id":"meeting-1","sequence":4,"occurred_at":"2026-07-25T10:04:00Z","kind":"user_question","provenance":{"source":"user","request_id":"11111111-1111-1111-1111-111111111111"},"payload":{"type":"user_question","request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","question":"谁负责回滚？"}},{"event_id":"event-5","meeting_id":"meeting-1","sequence":5,"occurred_at":"2026-07-25T10:05:00Z","kind":"assistant_answer","provenance":{"source":"meeting_agent","provider":"openai","model":"gpt-4o","request_id":"11111111-1111-1111-1111-111111111111"},"payload":{"type":"assistant_answer","request_id":"11111111-1111-1111-1111-111111111111","thread_id":"main","answer":"周岚 [M3]","sources":[{"source_id":"M3","event_id":"event-3","label":"截图分析"}],"degraded_vision":false,"status":"completed","error_message":null}}]}]"#.utf8
        )

        let meeting = try XCTUnwrap(StoredMeeting.parseList(data).first)

        XCTAssertEqual(meeting.schemaVersion, 2)
        XCTAssertEqual(meeting.status, .completed)
        XCTAssertEqual(meeting.timeline.map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(meeting.transcript.first?.text, "确认周五上线")
        XCTAssertEqual(meeting.screenshots.first?.analysis?.text, "截图显示周岚负责回滚")
        XCTAssertEqual(meeting.conversation.first?.answer, "周岚 [M3]")
        XCTAssertEqual(meeting.conversation.first?.sources.first?.sourceID, "M3")
    }

    func testMissingScreenshotFileKeepsTimelineEvidenceAndMarksPreviewUnavailable() throws {
        let asset = ScreenshotAsset(
            id: "asset-missing",
            relativePath: "assets/meeting/missing.png",
            mimeType: "image/png",
            width: nil,
            height: nil,
            capturedAt: Date(),
            analysis: nil
        )

        XCTAssertNil(asset.availableFileURL(dataRoot: URL(fileURLWithPath: "/definitely-missing")))
        XCTAssertEqual(asset.id, "asset-missing")
    }
}
