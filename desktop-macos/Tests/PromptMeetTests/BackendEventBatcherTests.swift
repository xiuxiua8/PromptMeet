import XCTest

@testable import PromptMeet

final class BackendEventBatcherTests: XCTestCase {
    func testLongStreamHasBoundedReaderWorkAndImmediateFollowUp() {
        let firstID = UUID()
        let secondID = UUID()
        let answer = String(repeating: "证据", count: 2_144) + "结"
        var batcher = BackendEventBatcher(maximumBufferedCharacters: 32)
        var state = MeetingState()
        var deliveryCount = 0
        var measuredPrefixCount = 0

        state.reduce(.userPromptSubmitted(id: firstID, prompt: "first"))
        for character in answer {
            for event in batcher.consume(
                .answerDelta(requestID: firstID, delta: String(character))
            ) {
                deliveryCount += 1
                apply(event, to: &state)
                if AIReaderLayout.shouldMeasureContent(state.aiReader.content) {
                    measuredPrefixCount += 1
                }
            }
        }
        for event in batcher.consume(.answerFinal(requestID: firstID, answer: answer)) {
            deliveryCount += 1
            apply(event, to: &state)
        }

        state.reduce(.userPromptSubmitted(id: secondID, prompt: "follow-up"))
        for event in batcher.consume(
            .answerDelta(requestID: secondID, delta: "follow-up partial")
        ) {
            deliveryCount += 1
            apply(event, to: &state)
        }
        for event in batcher.consume(
            .answerFinal(requestID: secondID, answer: "follow-up complete")
        ) {
            deliveryCount += 1
            apply(event, to: &state)
        }

        XCTAssertEqual(answer.count, 4_289)
        XCTAssertLessThanOrEqual(deliveryCount, 136)
        XCTAssertLessThanOrEqual(measuredPrefixCount, 19)
        XCTAssertEqual(state.aiRequest.id, secondID)
        XCTAssertEqual(state.aiRequest.phase, .completed)
        XCTAssertEqual(state.aiReader.content, "follow-up complete")
        XCTAssertFalse(state.aiReader.isStreaming)
    }

    func testFinalAnswerSupersedesUnsentPartialForTheSameRequest() {
        let requestID = UUID()
        var batcher = BackendEventBatcher(maximumBufferedCharacters: 32)

        XCTAssertTrue(
            batcher.consume(.answerDelta(requestID: requestID, delta: "short partial")).isEmpty
        )
        XCTAssertEqual(
            batcher.consume(.answerFinal(requestID: requestID, answer: "authoritative final")),
            [.answerFinal(requestID: requestID, answer: "authoritative final")]
        )
        XCTAssertTrue(batcher.finish().isEmpty)
    }

    func testFailureFlushesReadablePartialBeforeFailureState() {
        let requestID = UUID()
        var batcher = BackendEventBatcher(maximumBufferedCharacters: 32)

        _ = batcher.consume(.answerDelta(requestID: requestID, delta: "readable partial"))

        XCTAssertEqual(
            batcher.consume(.aiFailure(requestID: requestID, message: "provider stopped")),
            [
                .answerDelta(requestID: requestID, delta: "readable partial"),
                .aiFailure(requestID: requestID, message: "provider stopped")
            ]
        )
    }

    func testUnrelatedEventFlushesPendingAnswerInArrivalOrder() {
        let requestID = UUID()
        var batcher = BackendEventBatcher(maximumBufferedCharacters: 32)

        _ = batcher.consume(.answerDelta(requestID: requestID, delta: "partial"))

        XCTAssertEqual(
            batcher.consume(.suggestion("new evidence")),
            [
                .answerDelta(requestID: requestID, delta: "partial"),
                .suggestion("new evidence")
            ]
        )
    }

    private func apply(_ event: BackendEvent, to state: inout MeetingState) {
        switch event {
        case .answerDelta(let requestID, let delta):
            state.reduce(.answerDelta(requestID: requestID, delta: delta))
        case .answerFinal(let requestID, let answer):
            state.reduce(.answerFinal(requestID: requestID, answer: answer))
        case .aiFailure(let requestID, let message):
            state.reduce(.aiFailure(requestID: requestID, message: message))
        default:
            break
        }
    }
}
