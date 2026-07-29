import Foundation

extension MeetingState {
    static var previewLive: MeetingState {
        MeetingState(
            phase: .live,
            transcript: [
                TranscriptLine(speaker: "林晨", text: "我们先确认今天的讨论目标。")
            ]
        )
    }

    static var previewAura: MeetingState {
        MeetingState(
            phase: .live,
            transcript: [
                TranscriptLine(
                    speaker: "林晨",
                    text: "我们先确定今天的发布目标，然后讨论上线节奏和风险。",
                    timestamp: Date().addingTimeInterval(-32)
                ),
                TranscriptLine(
                    speaker: "周岚",
                    text: "设计部分保持克制，把最重要的信息留在第一眼能看到的位置。",
                    timestamp: Date().addingTimeInterval(-18)
                ),
                TranscriptLine(
                    speaker: "林晨",
                    text: "接下来需要确认每个行动项的负责人、截止时间，以及发布前必须完成的风险检查。"
                )
            ],
            latestInsight: "团队正在收敛发布范围，当前关键是确定负责人和截止时间。",
            generatedQuestions: [
                "这次发布最大的风险是什么？",
                "帮我整理明确的行动项",
                "发布前还缺少哪些确认？"
            ]
        )
    }

    static var previewReader: MeetingState {
        var state = previewLive
        state.aiReader = AIReaderState(
            title: "总结",
            content: "已完成的回答",
            isVisible: true,
            isStreaming: false
        )
        return state
    }

    static var previewLongReader: MeetingState {
        var state = previewAura
        state.promptHistory = ["这次发布最需要关注什么？"]
        state.aiReader = AIReaderState(
            title: "这次发布最需要关注什么？",
            content: """
                当前最需要关注三件事：

                1. 明确发布范围，避免在最后阶段继续加入未经验证的功能。
                2. 为每个行动项指定负责人和截止时间，并在发布前完成一次风险复核。
                3. 保留回滚路径，确认监控、告警和用户反馈入口都能够正常工作。

                如果时间有限，优先保证核心流程稳定，再安排后续体验优化。
                """,
            isVisible: true,
            isStreaming: false
        )
        return state
    }

    static var previewWorkspace: MeetingState {
        var state = previewAura
        state.promptHistory = ["这次发布最需要关注什么？"]
        state.aiReader = AIReaderState(
            title: "这次发布最需要关注什么？",
            content: "当前最重要的是锁定发布范围、明确负责人，并提前验证回滚路径。",
            isVisible: false,
            isStreaming: false
        )
        state.summary = MeetingSummaryContent(
            summaryText: "团队确认本次发布以核心流程稳定为优先，视觉体验保持克制，并在上线前完成风险复核。",
            tasks: [
                MeetingTask(title: "确认最终发布范围", deadline: "今天 18:00", assignee: "林晨"),
                MeetingTask(title: "完成回滚路径验证", deadline: "明天 12:00", assignee: "周岚")
            ],
            keyPoints: ["核心流程优先", "避免临时增加范围", "上线前完成风险复核"],
            decisions: ["采用 Aura 视觉方向", "保留独立 AI 阅读器"]
        )
        state.conversationTurns = [
            ConversationTurn(
                id: "preview-answer",
                requestID: "preview-answer",
                threadID: "main",
                meetingID: nil,
                question: "这次发布最需要关注什么？",
                answer: """
                    ## 发布重点

                    优先保证 **核心流程稳定**，并在上线前完成以下检查：

                    1. 锁定发布范围，避免临时新增功能。
                    2. 明确负责人和截止时间。
                    3. 验证 `rollback --dry-run` 回滚路径。

                    > 如果时间有限，先保障可恢复性，再安排体验优化。

                    参考 [发布检查清单](https://example.com/release-checklist)。
                    """,
                phase: .completed,
                errorMessage: nil,
                sources: [],
                degradedVision: false,
                askedAt: Date().addingTimeInterval(-12),
                answeredAt: Date()
            )
        ]
        return state
    }
}
