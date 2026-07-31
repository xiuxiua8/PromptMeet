import Foundation
import XCTest
@testable import PromptMeet

final class WorkspaceProjectionTests: XCTestCase {
    func testLiveTranslationSideChannelEnrichesMatchingTimelineSegment() {
        let segmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111119")!
        let event = transcriptEvent(
            sequence: 1,
            offset: 0,
            text: "范围已经冻结",
            segmentID: segmentID.uuidString
        )
        let translatedLine = TranscriptLine(
            id: segmentID,
            speaker: "林晨",
            text: "范围已经冻结",
            timestamp: event.occurredAt,
            source: .microphone,
            translatedText: "The scope is frozen."
        )

        let projection = WorkspaceProjection(
            events: [event],
            conversation: [],
            transcriptLines: [translatedLine]
        )

        XCTAssertEqual(
            projection.items.first?.transcriptBlock?.segments.first?.translatedText,
            "The scope is frozen."
        )
    }

    func testNamedSpeakerRemainsVisibleBesideLocalizedSourceLabel() {
        let projection = WorkspaceProjection(
            events: [
                transcriptEvent(
                    sequence: 1,
                    offset: 0,
                    text: "设计验收完成",
                    speaker: "周岚",
                    source: "system"
                )
            ],
            conversation: []
        )

        XCTAssertEqual(projection.items.first?.transcriptBlock?.displaySpeaker, "周岚")
        XCTAssertEqual(projection.items.first?.transcriptBlock?.source, "system")
    }

    func testOCRScreenshotAnalysisKeepsGroundingSpecificLabel() {
        let event = timelineEvent(
            sequence: 1,
            kind: .screenshotAnalysis,
            payload: .screenshotAnalysis(
                TimelineScreenshotAnalysisPayload(
                    assetID: "asset-1",
                    status: "completed",
                    text: "截图中的本地 OCR 证据",
                    visionUsed: false,
                    evidenceKind: "ocr",
                    imageRejection: "HTTP 400: image input rejected"
                )
            )
        )

        let projection = WorkspaceProjection(events: [event], conversation: [])

        XCTAssertEqual(projection.items.first?.title, "截图 OCR 证据")
    }

    func testBackwardTimestampDoesNotJoinOtherwiseCompatibleTranscriptBlock() {
        let projection = WorkspaceProjection(
            events: [
                transcriptEvent(sequence: 1, offset: 20, text: "第一段"),
                transcriptEvent(sequence: 2, offset: 10, text: "时间异常的第二段")
            ],
            conversation: []
        )

        XCTAssertEqual(projection.items.count, 2)
    }

    func testLargeAdjacentTranscriptRunUsesBoundedSelectableBlocks() {
        let events = (1...2_000).map { sequence in
            transcriptEvent(
                sequence: sequence,
                offset: TimeInterval(sequence),
                text: "第 \(sequence) 段"
            )
        }

        let projection = WorkspaceProjection(events: events, conversation: [])
        let blocks = projection.items.compactMap(\.transcriptBlock)

        XCTAssertGreaterThan(blocks.count, 1)
        XCTAssertTrue(
            blocks.allSatisfy {
                $0.segments.count <= WorkspaceTranscriptBlock.maximumSegmentCount
            }
        )
        XCTAssertEqual(blocks.flatMap(\.segments).count, 2_000)
        XCTAssertEqual(projection.items.last?.endSequence, 2_000)
    }

    func testLongTranscriptTextStartsANewSelectableBlockBeforeCharacterCap() {
        let projection = WorkspaceProjection(
            events: [
                transcriptEvent(
                    sequence: 1,
                    offset: 0,
                    text: String(repeating: "长", count: 4_090)
                ),
                transcriptEvent(
                    sequence: 2,
                    offset: 1,
                    text: String(repeating: "文", count: 20)
                )
            ],
            conversation: []
        )

        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(projection.items.map(\.endSequence), [1, 2])
    }

    func testLegacyTranscriptFallbackUsesTheSameDenseGroupingRules() {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111112")!
        let secondID = UUID(uuidString: "11111111-1111-1111-1111-111111111113")!
        let lines = [
            TranscriptLine(
                id: firstID,
                speaker: "林晨",
                text: "先确认范围",
                timestamp: Date(timeIntervalSince1970: 1_000),
                source: .microphone
            ),
            TranscriptLine(
                id: secondID,
                speaker: "林晨",
                text: "再确认负责人",
                timestamp: Date(timeIntervalSince1970: 1_020),
                source: .microphone
            )
        ]

        let blocks = WorkspaceProjection.transcriptBlocks(lines)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.segments.map(\.id), [firstID.uuidString, secondID.uuidString])
        XCTAssertEqual(blocks.first?.text, "先确认范围 再确认负责人")
    }

    func testAdjacentTranscriptSegmentsGroupBySpeakerAndSourceWithinTimeWindow() {
        let projection = WorkspaceProjection(
            events: [
                transcriptEvent(sequence: 1, offset: 0, text: "先确认发布范围"),
                transcriptEvent(sequence: 2, offset: 24, text: "再逐项确认负责人")
            ],
            conversation: []
        )

        XCTAssertEqual(projection.items.count, 1)
        XCTAssertEqual(projection.items.first?.kind, .transcript)
        XCTAssertEqual(projection.items.first?.transcriptBlock?.speaker, "林晨")
        XCTAssertEqual(projection.items.first?.transcriptBlock?.source, "microphone")
        XCTAssertEqual(
            projection.items.first?.transcriptBlock?.segments.map(\.id),
            ["segment-1", "segment-2"]
        )
        XCTAssertEqual(
            projection.items.first?.transcriptBlock?.text,
            "先确认发布范围 再逐项确认负责人"
        )
        XCTAssertEqual(projection.items.first?.endSequence, 2)
    }

    func testSpeakerSourceTimeGapAndScreenshotEachCloseTranscriptBlock() {
        let projection = WorkspaceProjection(
            events: [
                transcriptEvent(sequence: 1, offset: 0, text: "麦克风一"),
                transcriptEvent(sequence: 2, offset: 8, text: "系统一", source: "system"),
                transcriptEvent(
                    sequence: 3,
                    offset: 14,
                    text: "另一位发言",
                    speaker: "周岚",
                    source: "system"
                ),
                transcriptEvent(
                    sequence: 4,
                    offset: 70,
                    text: "时间间隔后的发言",
                    speaker: "周岚",
                    source: "system"
                ),
                screenshotEvent(sequence: 5, offset: 72),
                transcriptEvent(
                    sequence: 6,
                    offset: 73,
                    text: "截图后的发言",
                    speaker: "周岚",
                    source: "system"
                )
            ],
            conversation: []
        )

        XCTAssertEqual(
            projection.items.map(\.kind),
            [.transcript, .transcript, .transcript, .transcript, .screenshot, .transcript]
        )
        XCTAssertEqual(projection.items.map(\.sequence), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(
            projection.items.compactMap(\.transcriptBlock?.text),
            ["麦克风一", "系统一", "另一位发言", "时间间隔后的发言", "截图后的发言"]
        )
    }

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
    offset: TimeInterval? = nil,
    kind: MeetingTimelineKind,
    payload: MeetingTimelinePayload
) -> MeetingTimelineEvent {
    MeetingTimelineEvent(
        eventID: "event-\(sequence)",
        meetingID: "meeting-1",
        sequence: sequence,
        occurredAt: Date(timeIntervalSince1970: 1_000 + (offset ?? TimeInterval(sequence))),
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
    transcriptEvent(sequence: 1, offset: 1, text: "范围冻结")
}

private func transcriptEvent(
    sequence: Int,
    offset: TimeInterval,
    text: String,
    speaker: String = "林晨",
    source: String = "microphone",
    segmentID: String? = nil
) -> MeetingTimelineEvent {
    timelineEvent(
        sequence: sequence,
        offset: offset,
        kind: .transcript,
        payload: .transcript(
            TimelineTranscriptPayload(
                segmentID: segmentID ?? "segment-\(sequence)",
                text: text,
                speaker: speaker,
                source: source,
                translatedText: nil,
                meetingTimeMilliseconds: Int64(offset * 1_000)
            )
        )
    )
}

private func screenshotEvent(sequence: Int, offset: TimeInterval) -> MeetingTimelineEvent {
    timelineEvent(
        sequence: sequence,
        offset: offset,
        kind: .screenshot,
        payload: .screenshot(
            TimelineScreenshotPayload(
                assetID: "asset-\(sequence)",
                relativePath: "assets/meeting-1/screenshot-\(sequence).png",
                mimeType: "image/png",
                sha256: "synthetic",
                width: 1_200,
                height: 800,
                captureStatus: "completed",
                localOCRText: nil,
                ocrEngine: nil
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
