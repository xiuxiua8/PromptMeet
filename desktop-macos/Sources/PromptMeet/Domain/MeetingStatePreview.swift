import Foundation

private let formulaAnswerPreview = """
## 能量公式

根据相对论，能量公式是 $E = mc^2$，其中 $c$ 是光速。

积分：$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$，极限：$\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1$。

求和公式：

$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$

分数相加：$\\frac{a}{b} + \\frac{c}{d} = \\frac{ad+bc}{bd}$，\
开方：$\\sqrt{x^2 + y^2}$，希腊字母 $\\alpha + \\beta = \\gamma$，无穷 $\\infty$。

**对比表**（粗体与斜体同时验证）：

| 指标 | 公式 | 结果 |
| :--- | ---: | :---: |
| 能量 | $E = mc^2$ | **成立** |
| 积分 | $\\int_0^1 x^2 dx$ | $\\frac{1}{3}$ |
| 求和 | $\\sum_{i=1}^{n} i$ | $\\frac{n(n+1)}{2}$ |
"""

extension MeetingState {
    static var previewLive: MeetingState {
        MeetingState(
            phase: .live,
            recordingActivity: .recording,
            audioCapture: AudioCaptureSnapshot(microphone: .active, system: .active),
            transcript: [
                TranscriptLine(
                    speaker: "林晨",
                    text: "我们先确认今天的讨论目标。",
                    source: .microphone,
                    translatedText: "First, let us confirm the goal of today's discussion."
                )
            ]
        )
    }

    static var previewAura: MeetingState {
        MeetingState(
            phase: .live,
            recordingActivity: .recording,
            audioCapture: AudioCaptureSnapshot(microphone: .active, system: .active),
            transcript: [
                TranscriptLine(
                    speaker: "林晨",
                    text: "我们先确定今天的发布目标，然后讨论上线节奏和风险。",
                    timestamp: Date().addingTimeInterval(-32),
                    source: .microphone
                ),
                TranscriptLine(
                    speaker: "周岚",
                    text: "设计部分保持克制，把最重要的信息留在第一眼能看到的位置。",
                    timestamp: Date().addingTimeInterval(-18),
                    source: .system
                ),
                TranscriptLine(
                    speaker: "林晨",
                    text: "接下来需要确认每个行动项的负责人、截止时间，以及发布前必须完成的风险检查。",
                    source: .microphone,
                    translatedText: "Next, confirm every action owner, deadline, and pre-release risk check."
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

    static var previewPaused: MeetingState {
        var state = previewAura
        state.recordingActivity = .paused
        state.audioCapture = AudioCaptureSnapshot(microphone: .paused, system: .paused)
        return state
    }

    static var previewQuickAsk: MeetingState {
        var state = previewAura
        state.isQuickAskPresented = true
        state.quickPromptDraft = "发布前还有哪些风险没有负责人？"
        return state
    }

    static var previewFormulaWorkspace: MeetingState {
        var state = previewWorkspace
        state.conversationTurns = [
            ConversationTurn(
                id: "preview-formula-answer",
                requestID: "preview-formula-answer",
                threadID: "main",
                meetingID: nil,
                question: "相对论中的能量公式是什么？",
                answer: formulaAnswerPreview,
                phase: .completed,
                errorMessage: nil,
                sources: [],
                degradedVision: false,
                askedAt: Date().addingTimeInterval(-12),
                answeredAt: Date()
            )
        ]
        state.aiReader = AIReaderState(
            title: "相对论中的能量公式是什么？",
            content: formulaAnswerPreview,
            isVisible: false,
            isStreaming: false
        )
        return state
    }

    static var previewFormulaWorkspaceStreaming: MeetingState {
        var state = previewWorkspace
        state.conversationTurns = [
            ConversationTurn(
                id: "preview-formula-streaming",
                requestID: "preview-formula-streaming",
                threadID: "main",
                meetingID: nil,
                question: "相对论中的能量公式是什么？",
                answer: "## 能量公式\n\n根据相对论，能量公式是 $E = mc^",
                phase: .streaming,
                errorMessage: nil,
                sources: [],
                degradedVision: false,
                askedAt: Date().addingTimeInterval(-12),
                answeredAt: nil
            )
        ]
        return state
    }

    static var previewFormulaReader: MeetingState {
        var state = previewFormulaWorkspace
        state.aiReader = AIReaderState(
            title: "相对论中的能量公式是什么？",
            content: formulaAnswerPreview,
            isVisible: true,
            isStreaming: false
        )
        return state
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
        state.timeline = previewWorkspaceTimeline
        let historyDate = Date().addingTimeInterval(-86_400)
        let historicalSummary = MeetingSummaryContent(
            summaryText: "团队完成 **Release** 演练，并确认 `rollback --dry-run` 可用。",
            tasks: [
                MeetingTask(
                    title: "归档回滚日志",
                    deadline: "周五 18:00",
                    details: "附上 **支付链路** 验证结果",
                    priority: "high",
                    assignee: "周岚",
                    status: "pending"
                ),
                MeetingTask(
                    title: "完成发布复核",
                    priority: "medium",
                    assignee: "林晨",
                    status: "completed"
                )
            ],
            keyPoints: ["核心链路稳定", "长行内容会自动换行"],
            decisions: ["周五分批上线", "异常时立即回滚"]
        )
        let historicalTimeline = [
            MeetingTimelineEvent(
                eventID: "preview-history-transcript-1",
                meetingID: "preview-release-history",
                sequence: 1,
                occurredAt: historyDate.addingTimeInterval(20),
                kind: .transcript,
                provenance: TimelineProvenance(
                    source: "preview",
                    provider: nil,
                    model: nil,
                    requestID: nil
                ),
                payload: .transcript(
                    TimelineTranscriptPayload(
                        segmentID: "22222222-2222-2222-2222-222222222222",
                        text: "Release rollback rehearsal completed",
                        speaker: "林晨",
                        source: "microphone",
                        translatedText: nil,
                        meetingTimeMilliseconds: 20_000
                    )
                )
            ),
            MeetingTimelineEvent(
                eventID: "preview-history-transcript-2",
                meetingID: "preview-release-history",
                sequence: 2,
                occurredAt: historyDate.addingTimeInterval(40),
                kind: .transcript,
                provenance: TimelineProvenance(
                    source: "preview",
                    provider: nil,
                    model: nil,
                    requestID: nil
                ),
                payload: .transcript(
                    TimelineTranscriptPayload(
                        segmentID: "33333333-3333-3333-3333-333333333333",
                        text: "支付链路回滚验证通过",
                        speaker: "周岚",
                        source: "microphone",
                        translatedText: nil,
                        meetingTimeMilliseconds: 40_000
                    )
                )
            ),
            MeetingTimelineEvent(
                eventID: "preview-history-question",
                meetingID: "preview-release-history",
                sequence: 3,
                occurredAt: historyDate.addingTimeInterval(60),
                kind: .userQuestion,
                provenance: TimelineProvenance(
                    source: "preview",
                    provider: nil,
                    model: nil,
                    requestID: "11111111-1111-1111-1111-111111111111"
                ),
                payload: .userQuestion(
                    TimelineQuestionPayload(
                        requestID: "11111111-1111-1111-1111-111111111111",
                        threadID: "main",
                        question: "历史发布结论是什么？"
                    )
                )
            ),
            MeetingTimelineEvent(
                eventID: "preview-history-answer",
                meetingID: "preview-release-history",
                sequence: 4,
                occurredAt: historyDate.addingTimeInterval(62),
                kind: .assistantAnswer,
                provenance: TimelineProvenance(
                    source: "preview",
                    provider: "openai",
                    model: "preview-model",
                    requestID: "11111111-1111-1111-1111-111111111111"
                ),
                payload: .assistantAnswer(
                    TimelineAnswerPayload(
                        requestID: "11111111-1111-1111-1111-111111111111",
                        threadID: "main",
                        answer: """
                            ## 历史发布结论

                            **核心链路验证通过**，周五分批上线。

                            > 异常时立即执行 `rollback --dry-run`。

                            参考 [发布清单](https://example.com/release-checklist)。
                            """,
                        sources: [],
                        degradedVision: false,
                        status: "completed",
                        errorMessage: nil
                    )
                )
            )
        ]
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
        state.meetingHistory = [
            StoredMeeting(
                id: "preview-release-history",
                schemaVersion: 2,
                title: "发布范围与回滚复盘",
                status: .completed,
                startTime: historyDate,
                endTime: historyDate.addingTimeInterval(3_600),
                timeline: historicalTimeline,
                transcript: [
                    TranscriptLine(
                        speaker: "林晨",
                        text: "Release rollback rehearsal completed",
                        timestamp: historyDate.addingTimeInterval(20)
                    ),
                    TranscriptLine(
                        speaker: "周岚",
                        text: "支付链路回滚验证通过",
                        timestamp: historyDate.addingTimeInterval(40)
                    )
                ],
                summary: historicalSummary
            ),
            StoredMeeting(
                id: "preview-kv-history",
                schemaVersion: 2,
                startTime: historyDate.addingTimeInterval(-86_400),
                endTime: historyDate.addingTimeInterval(-82_800),
                transcript: [
                    TranscriptLine(speaker: "陈曦", text: "KV Cache 压缩与延迟基准讨论")
                ],
                summary: MeetingSummaryContent(
                    summaryText: "确认 **KV Cache** 压缩测试范围。",
                    tasks: [],
                    keyPoints: ["覆盖 ASCII 搜索"],
                    decisions: ["先测长上下文"]
                )
            ),
            StoredMeeting(
                id: "preview-empty-history",
                schemaVersion: 2,
                startTime: historyDate.addingTimeInterval(-172_800),
                endTime: historyDate.addingTimeInterval(-172_200),
                transcript: [],
                summary: nil
            )
        ]
        return state
    }

}
