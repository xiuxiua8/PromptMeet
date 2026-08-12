import Foundation

extension MeetingState {
    static var previewWorkspaceTimeline: [MeetingTimelineEvent] {
        let base = Date(timeIntervalSince1970: 1_785_360_000)
        return [
            previewEvent(
                sequence: 1,
                date: base,
                kind: .lifecycle,
                payload: .lifecycle(TimelineLifecyclePayload(status: .active, detail: "会议开始"))
            ),
            previewTranscript(
                sequence: 2,
                date: base.addingTimeInterval(12),
                speaker: "林晨",
                source: "microphone",
                text: "我们先锁定本次发布范围，核心流程必须保持稳定。"
            ),
            previewTranscript(
                sequence: 3,
                date: base.addingTimeInterval(31),
                speaker: "林晨",
                source: "microphone",
                text: "临时需求统一进入下一个版本，不在今天继续扩展。"
            ),
            previewTranscript(
                sequence: 4,
                date: base.addingTimeInterval(39),
                speaker: "周岚",
                source: "system",
                text: "设计验收今天完成，我会同时核对小屏窗口和长文本换行。"
            ),
            previewEvent(
                sequence: 5,
                date: base.addingTimeInterval(52),
                kind: .screenshot,
                payload: .screenshot(
                    TimelineScreenshotPayload(
                        assetID: "preview-screenshot",
                        relativePath: "preview/synthetic-workspace.png",
                        mimeType: "image/png",
                        sha256: "synthetic-preview-only",
                        width: 1_200,
                        height: 720,
                        captureStatus: "completed",
                        localOCRText: "发布检查清单：回滚路径与负责人待确认",
                        ocrEngine: "apple_vision"
                    )
                )
            ),
            previewEvent(
                sequence: 6,
                date: base.addingTimeInterval(58),
                kind: .screenshotAnalysis,
                payload: .screenshotAnalysis(
                    TimelineScreenshotAnalysisPayload(
                        assetID: "preview-screenshot",
                        status: "completed",
                        text: "界面展示发布检查清单，回滚路径与负责人仍需最终确认。",
                        visionUsed: true,
                        evidenceKind: "vision",
                        imageRejection: nil
                    )
                )
            ),
            previewEvent(
                sequence: 7,
                date: base.addingTimeInterval(70),
                kind: .screenshotAnalysis,
                payload: .screenshotAnalysis(
                    TimelineScreenshotAnalysisPayload(
                        assetID: "preview-failed-screenshot",
                        status: "failed",
                        text: "另一张截图分析失败，可在配置恢复后重试。",
                        visionUsed: false,
                        evidenceKind: nil,
                        imageRejection: nil
                    )
                )
            ),
            previewEvent(
                sequence: 8,
                date: base.addingTimeInterval(84),
                kind: .summary,
                payload: .summary(
                    TimelineSummaryPayload(
                        summaryText: "发布范围已经冻结，接下来集中完成视觉验收、回滚验证和负责人确认。",
                        tasks: [],
                        keyPoints: ["范围冻结", "验证回滚"],
                        decisions: ["临时需求进入下个版本"],
                        revision: 1,
                        sourceEventIDs: ["preview-event-2", "preview-event-4"],
                        sourceRevision: 4,
                        trigger: "manual",
                        activeMinutes: 1
                    )
                )
            )
        ]
    }

    private static func previewTranscript(
        sequence: Int,
        date: Date,
        speaker: String,
        source: String,
        text: String
    ) -> MeetingTimelineEvent {
        previewEvent(
            sequence: sequence,
            date: date,
            kind: .transcript,
            payload: .transcript(
                TimelineTranscriptPayload(
                    segmentID: "preview-segment-\(sequence)",
                    text: text,
                    speaker: speaker,
                    source: source,
                    translatedText: nil,
                    meetingTimeMilliseconds: Int64(sequence * 10_000)
                )
            )
        )
    }

    private static func previewEvent(
        sequence: Int,
        date: Date,
        kind: MeetingTimelineKind,
        payload: MeetingTimelinePayload
    ) -> MeetingTimelineEvent {
        MeetingTimelineEvent(
            eventID: "preview-event-\(sequence)",
            meetingID: "preview-meeting",
            sequence: sequence,
            occurredAt: date,
            kind: kind,
            provenance: TimelineProvenance(
                source: "synthetic_preview",
                provider: nil,
                model: nil,
                requestID: nil
            ),
            payload: payload
        )
    }
}
