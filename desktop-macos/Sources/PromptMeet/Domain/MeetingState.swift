import Foundation

enum MeetingPhase: Equatable, Sendable {
    case idle
    case connecting
    case live
    case stopping
    case failed(String)
}

struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: String
    let text: String
    let timestamp: Date
    var translatedText: String?

    init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        timestamp: Date = Date(),
        translatedText: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.translatedText = translatedText
    }
}

struct AIReaderState: Equatable, Sendable {
    var title = "AI 回答"
    var content = ""
    var isVisible = false
    var isStreaming = false
}

enum AIRequestPhase: Equatable, Sendable {
    case idle
    case submitting
    case streaming
    case completed
    case failed
}

struct AIRequestState: Equatable, Sendable {
    var id: UUID?
    var prompt = ""
    var phase: AIRequestPhase = .idle
    var errorMessage: String?

    var isBusy: Bool {
        phase == .submitting || phase == .streaming
    }
}

struct MeetingTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let deadline: String?
    let details: String
    let priority: String
    let assignee: String?
    let status: String

    init(
        id: UUID = UUID(),
        title: String,
        deadline: String? = nil,
        details: String = "",
        priority: String = "medium",
        assignee: String? = nil,
        status: String = "pending"
    ) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.details = details
        self.priority = priority
        self.assignee = assignee
        self.status = status
    }
}

struct MeetingSummaryContent: Equatable, Sendable {
    let summaryText: String
    let tasks: [MeetingTask]
    let keyPoints: [String]
    let decisions: [String]
}

enum MeetingAction: Equatable {
    case prepareNewMeeting
    case beginSession
    case connectionReady
    case transcriptPartial(String)
    case transcriptFinal(TranscriptLine)
    case transcriptTranslated(id: UUID, text: String)
    case companionConnected
    case companionDisconnected(String)
    case userPromptSubmitted(id: UUID, prompt: String)
    case answerDelta(requestID: UUID?, delta: String)
    case answerFinal(requestID: UUID?, answer: String)
    case aiFailure(requestID: UUID?, message: String)
    case quickPromptChanged(String)
    case quickAskPresented(Bool)
    case questionGenerated(String)
    case questionsGenerated([String])
    case suggestion(String)
    case summaryGenerated(MeetingSummaryContent)
    case screenshotInsight(String)
    case meetingEvent(MeetingTimelineEvent)
    case hideReader
    case showReader
    case meetingHistoryLoaded([StoredMeeting])
    case meetingHistoryUpdated(StoredMeeting)
    case archivedMeetingSelected(String?)
    case failure(String)
}

struct MeetingState: Equatable {
    var phase: MeetingPhase = .idle
    var transcript: [TranscriptLine] = []
    var activeTranscript = ""
    var latestInsight: String?
    var latestSummary: String?
    var summary: MeetingSummaryContent?
    var screenshotInsights: [String] = []
    var generatedQuestions: [String] = []
    var isCompanionConnected = false
    var aiReader = AIReaderState()
    var aiRequest = AIRequestState()
    var promptHistory: [String] = []
    var quickPromptDraft = ""
    var isQuickAskPresented = false
    var meetingHistory: [StoredMeeting] = []
    var selectedArchivedMeetingID: String?
    var timeline: [MeetingTimelineEvent] = []
    var conversationTurns: [ConversationTurn] = []

    var activeCaption: String {
        activeTranscript.isEmpty ? (transcript.last?.text ?? "") : activeTranscript
    }

    var selectedArchivedMeeting: StoredMeeting? {
        meetingHistory.first { $0.id == selectedArchivedMeetingID }
    }

    var displayedTranscript: [TranscriptLine] {
        selectedArchivedMeeting?.transcript ?? transcript
    }

    var displayedSummary: MeetingSummaryContent? {
        selectedArchivedMeeting?.summary ?? summary
    }

    var displayedTimeline: [MeetingTimelineEvent] {
        selectedArchivedMeeting?.timeline ?? timeline
    }

    var displayedScreenshots: [ScreenshotAsset] {
        selectedArchivedMeeting?.screenshots ?? MeetingTimelineProjection.screenshots(timeline)
    }

    var displayedConversation: [ConversationTurn] {
        guard let selectedArchivedMeeting else { return conversationTurns }
        var result = selectedArchivedMeeting.conversation
        for pending in conversationTurns where pending.meetingID == selectedArchivedMeeting.id {
            if !result.contains(where: { $0.requestID == pending.requestID }) {
                result.append(pending)
            }
        }
        return result.sorted { $0.askedAt < $1.askedAt }
    }

    func conversationTurn(requestID: UUID) -> ConversationTurn? {
        conversationTurns.first { $0.requestID.caseInsensitiveCompare(requestID.uuidString) == .orderedSame }
    }

    func islandPresentation(isHovered: Bool) -> IslandPresentation {
        if isQuickAskPresented || isHovered {
            switch phase {
            case .idle, .failed:
                return .hoverIdle
            case .connecting, .live, .stopping:
                return .hoverLive
            }
        }

        if aiReader.isStreaming {
            return .answering
        }

        switch phase {
        case .idle, .failed:
            return .idle
        case .connecting, .stopping:
            return .connecting
        case .live:
            return .live
        }
    }

    mutating func reduce(_ action: MeetingAction) {
        switch action {
        case .prepareNewMeeting:
            phase = .idle
            transcript = []
            activeTranscript = ""
            latestInsight = nil
            latestSummary = nil
            summary = nil
            screenshotInsights = []
            generatedQuestions = []
            aiReader = AIReaderState()
            aiRequest = AIRequestState()
            promptHistory = []
            quickPromptDraft = ""
            isQuickAskPresented = false
            selectedArchivedMeetingID = nil
            timeline = []
            conversationTurns = []
        case .beginSession:
            phase = .connecting
        case .connectionReady:
            phase = .live
        case let .transcriptPartial(text):
            activeTranscript = text
        case let .transcriptFinal(line):
            if !transcript.contains(where: { $0.id == line.id }) {
                transcript.append(line)
            }
            activeTranscript = ""
        case let .transcriptTranslated(id, text):
            guard let index = transcript.firstIndex(where: { $0.id == id }) else { return }
            transcript[index].translatedText = text
        case .companionConnected:
            isCompanionConnected = true
            if latestInsight?.contains("AI companion") == true || latestInsight?.contains("AI 服务连接") == true {
                latestInsight = nil
            }
        case let .companionDisconnected(message):
            isCompanionConnected = false
            latestInsight = message
        case let .userPromptSubmitted(id, prompt):
            let keepsReaderVisible = aiReader.isVisible
            promptHistory.append(prompt)
            aiRequest = AIRequestState(id: id, prompt: prompt, phase: .submitting)
            aiReader = AIReaderState(title: prompt, isVisible: keepsReaderVisible)
            if !conversationTurns.contains(where: { $0.requestID == id.uuidString }) {
                conversationTurns.append(
                    ConversationTurn(
                        id: id.uuidString,
                        requestID: id.uuidString,
                        threadID: "main",
                        meetingID: selectedArchivedMeetingID,
                        question: prompt,
                        answer: "",
                        phase: .submitting,
                        errorMessage: nil,
                        sources: [],
                        degradedVision: false,
                        askedAt: Date(),
                        answeredAt: nil
                    )
                )
            }
        case let .answerDelta(requestID, delta):
            guard let resolvedID = requestID ?? aiRequest.id,
                  let index = conversationIndex(resolvedID)
            else { return }
            conversationTurns[index].answer += delta
            conversationTurns[index].phase = .streaming
            conversationTurns[index].errorMessage = nil
            if aiRequest.id == resolvedID {
                aiReader.content += delta
                aiReader.isVisible = true
                aiReader.isStreaming = true
                aiRequest.phase = .streaming
                aiRequest.errorMessage = nil
            }
        case let .answerFinal(requestID, answer):
            guard let resolvedID = requestID ?? aiRequest.id,
                  let index = conversationIndex(resolvedID)
            else { return }
            conversationTurns[index].answer = answer
            conversationTurns[index].phase = .completed
            conversationTurns[index].errorMessage = nil
            conversationTurns[index].answeredAt = Date()
            if aiRequest.id == resolvedID {
                aiReader.content = answer
                aiReader.isVisible = true
                aiReader.isStreaming = false
                aiRequest.phase = .completed
                aiRequest.errorMessage = nil
            }
        case let .aiFailure(requestID, message):
            guard let resolvedID = requestID ?? aiRequest.id,
                  let index = conversationIndex(resolvedID)
            else { return }
            conversationTurns[index].phase = .failed
            conversationTurns[index].errorMessage = message
            if aiRequest.id == resolvedID {
                aiRequest.phase = .failed
                aiRequest.errorMessage = message
                aiReader.isStreaming = false
            }
        case let .quickPromptChanged(prompt):
            quickPromptDraft = prompt
        case let .quickAskPresented(isPresented):
            isQuickAskPresented = isPresented
        case let .questionGenerated(question):
            if !generatedQuestions.contains(question) {
                generatedQuestions.append(question)
            }
            latestInsight = question
        case let .questionsGenerated(questions):
            let refreshed = questions.reduce(into: [String]()) { result, question in
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !result.contains(trimmed) {
                    result.append(trimmed)
                }
            }
            generatedQuestions = refreshed
            if let first = refreshed.first {
                latestInsight = first
            }
        case let .suggestion(insight):
            latestInsight = insight
        case let .summaryGenerated(summary):
            self.summary = summary
            latestSummary = summary.summaryText
        case let .screenshotInsight(insight):
            screenshotInsights.append(insight)
            latestInsight = insight
        case let .meetingEvent(event):
            ingestTimelineEvent(event)
        case .hideReader:
            aiReader.isVisible = false
        case .showReader:
            if !aiReader.content.isEmpty {
                aiReader.isVisible = true
            }
        case let .meetingHistoryLoaded(meetings):
            meetingHistory = meetings
            if let selectedArchivedMeetingID,
               !meetings.contains(where: { $0.id == selectedArchivedMeetingID }) {
                self.selectedArchivedMeetingID = nil
            }
        case let .meetingHistoryUpdated(meeting):
            if let index = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
                meetingHistory[index] = meeting
            } else {
                meetingHistory.append(meeting)
            }
            meetingHistory.sort { $0.startTime > $1.startTime }
        case let .archivedMeetingSelected(id):
            selectedArchivedMeetingID = id
        case let .failure(message):
            phase = .failed(message)
        }
    }

    private func conversationIndex(_ requestID: UUID) -> Int? {
        conversationTurns.firstIndex {
            $0.requestID.caseInsensitiveCompare(requestID.uuidString) == .orderedSame
        }
    }

    private mutating func ingestTimelineEvent(_ event: MeetingTimelineEvent) {
        guard !timeline.contains(where: { $0.id == event.id }) else { return }
        timeline.append(event)
        timeline.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.occurredAt < $1.occurredAt
        }
        if let line = event.transcript,
           !transcript.contains(where: { $0.id == line.id }) {
            transcript.append(line)
        }
        for projected in MeetingTimelineProjection.conversation(timeline) {
            if let index = conversationTurns.firstIndex(where: { $0.requestID == projected.requestID }) {
                if projected.phase == .completed || projected.phase == .failed {
                    conversationTurns[index] = projected
                }
            } else {
                conversationTurns.append(projected)
            }
        }
        switch event.payload {
        case let .summary(value):
            let content = MeetingSummaryContent(
                summaryText: value.summaryText,
                tasks: value.tasks.compactMap { payload in
                    guard let title = payload["task"]?.stringValue, !title.isEmpty else { return nil }
                    return MeetingTask(
                        title: title,
                        deadline: payload["deadline"]?.stringValue,
                        details: payload["describe"]?.stringValue ?? "",
                        priority: payload["priority"]?.stringValue ?? "medium",
                        assignee: payload["assignee"]?.stringValue,
                        status: payload["status"]?.stringValue ?? "pending"
                    )
                },
                keyPoints: value.keyPoints,
                decisions: value.decisions
            )
            summary = content
            latestSummary = content.summaryText
        case let .screenshotAnalysis(value):
            screenshotInsights.append(value.text)
            latestInsight = value.text
        default:
            break
        }
    }
}

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
                "帮我整理明确的行动项"
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
        return state
    }
}
