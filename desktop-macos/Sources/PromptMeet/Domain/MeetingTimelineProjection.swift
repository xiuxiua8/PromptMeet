import Foundation

enum MeetingTimelineProjection {
    static func screenshots(_ events: [MeetingTimelineEvent]) -> [ScreenshotAsset] {
        var assets: [ScreenshotAsset] = []
        for event in events.sorted(by: eventOrder) {
            if let screenshot = event.screenshot {
                assets.append(screenshot)
                continue
            }
            guard case .screenshotAnalysis(let value) = event.payload,
                  let index = assets.firstIndex(where: { $0.id == value.assetID }) else {
                continue
            }
            assets[index].analysis = ScreenshotAnalysis(
                status: value.status,
                text: value.text,
                visionUsed: value.visionUsed,
                provider: event.provenance.provider,
                model: event.provenance.model
            )
        }
        return assets
    }

    static func conversation(_ events: [MeetingTimelineEvent]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for event in events.sorted(by: eventOrder) {
            applyConversationEvent(event, to: &turns)
        }
        return turns
    }

    private static func applyConversationEvent(
        _ event: MeetingTimelineEvent,
        to turns: inout [ConversationTurn]
    ) {
        switch event.payload {
        case .userQuestion(let value):
            guard !turns.contains(where: { $0.requestID == value.requestID }) else { return }
            turns.append(turn(from: value, event: event))
        case .assistantAnswer(let value):
            applyAnswer(value, event: event, to: &turns)
        default:
            break
        }
    }

    private static func turn(
        from question: TimelineQuestionPayload,
        event: MeetingTimelineEvent
    ) -> ConversationTurn {
        ConversationTurn(
            id: question.requestID,
            requestID: question.requestID,
            threadID: question.threadID,
            meetingID: event.meetingID,
            question: question.question,
            answer: "",
            phase: .submitting,
            errorMessage: nil,
            sources: [],
            degradedVision: false,
            askedAt: event.occurredAt,
            answeredAt: nil
        )
    }

    private static func applyAnswer(
        _ answer: TimelineAnswerPayload,
        event: MeetingTimelineEvent,
        to turns: inout [ConversationTurn]
    ) {
        let index = turns.firstIndex(where: { $0.requestID == answer.requestID })
            ?? appendPlaceholder(for: answer, event: event, to: &turns)
        turns[index].answer = answer.answer
        turns[index].phase = answer.status == "failed" ? .failed : .completed
        turns[index].errorMessage = answer.errorMessage
        turns[index].sources = answer.sources
        turns[index].degradedVision = answer.degradedVision
        turns[index].answeredAt = event.occurredAt
    }

    private static func appendPlaceholder(
        for answer: TimelineAnswerPayload,
        event: MeetingTimelineEvent,
        to turns: inout [ConversationTurn]
    ) -> Int {
        turns.append(
            turn(
                from: TimelineQuestionPayload(
                    requestID: answer.requestID,
                    threadID: answer.threadID,
                    question: "历史问题"
                ),
                event: event
            )
        )
        return turns.count - 1
    }

    private static func eventOrder(_ lhs: MeetingTimelineEvent, _ rhs: MeetingTimelineEvent) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.occurredAt < rhs.occurredAt
    }
}
