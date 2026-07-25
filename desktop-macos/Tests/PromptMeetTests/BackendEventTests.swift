import XCTest
@testable import PromptMeet

final class BackendEventTests: XCTestCase {
    func testTranscriptDecodesFromExistingWebSocketShape() throws {
        let event = try BackendEvent.decode(
            #"{"type":"audio_transcript","data":{"id":"line-1","speaker":"林晨","text":"确认范围","timestamp":"2026-07-24T09:30:00+08:00"}}"#
        )

        guard case let .transcript(line) = event else {
            return XCTFail("Expected transcript event")
        }
        XCTAssertEqual(line.speaker, "林晨")
        XCTAssertEqual(line.text, "确认范围")
    }

    func testStreamingAndFinalAnswersDecodeSeparately() throws {
        let requestID = UUID()
        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"answer","data":{"request_id":"\#(requestID.uuidString)","delta":"正在整理"}}"#),
            .answerDelta(requestID: requestID, delta: "正在整理")
        )
        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"answer","data":{"request_id":"\#(requestID.uuidString)","content":"整理完成"}}"#),
            .answerFinal(requestID: requestID, answer: "整理完成")
        )
    }

    func testAIErrorDecodesWithoutBecomingMeetingFailure() throws {
        let requestID = UUID()

        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"error","data":{"scope":"ai","request_id":"\#(requestID.uuidString)","message":"模型暂时不可用"}}"#),
            .aiFailure(requestID: requestID, message: "模型暂时不可用")
        )
    }

    func testQuestionBecomesLowNoiseInsight() throws {
        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"question","data":{"content":"预算上限是多少？"}}"#),
            .question("预算上限是多少？")
        )
    }

    func testQuestionBatchDecodesForLiveReplacement() throws {
        XCTAssertEqual(
            try BackendEvent.decode(
                #"{"type":"questions","data":{"questions":[{"question":"负责人是谁？"},{"question":"何时上线？"}]}}"#
            ),
            .questions(["负责人是谁？", "何时上线？"])
        )
    }

    func testStructuredSummaryKeepsTasksKeyPointsAndDecisions() throws {
        let event = try BackendEvent.decode(
            #"{"type":"summary_generated","data":{"summary_text":"已确认上线范围","tasks":[{"task":"准备发布","deadline":"明天","assignee":"林晨","priority":"high","status":"pending"}],"key_points":["范围冻结"],"decisions":["周五上线"]}}"#
        )

        guard case let .summary(summary) = event else {
            return XCTFail("Expected structured summary")
        }
        XCTAssertEqual(summary.summaryText, "已确认上线范围")
        XCTAssertEqual(summary.tasks.first?.title, "准备发布")
        XCTAssertEqual(summary.tasks.first?.assignee, "林晨")
        XCTAssertEqual(summary.keyPoints, ["范围冻结"])
        XCTAssertEqual(summary.decisions, ["周五上线"])
    }

    func testScreenshotAnalysisBecomesNonIntrusiveInsight() throws {
        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"image_ocr_result","data":{"content":"截图显示预算为 20 万元"}}"#),
            .screenshotInsight("截图显示预算为 20 万元")
        )
    }

    func testTranslationEventKeepsTranscriptIdentity() throws {
        let id = UUID()
        XCTAssertEqual(
            try BackendEvent.decode(
                #"{"type":"transcript_translation","data":{"id":"\#(id.uuidString)","translated_text":"大家好"}}"#
            ),
            .translation(id: id, text: "大家好")
        )
    }

    func testUnknownEventIsIgnoredForForwardCompatibility() throws {
        XCTAssertEqual(
            try BackendEvent.decode(#"{"type":"future_event","data":{}}"#),
            .ignored
        )
    }
}
