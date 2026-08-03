import AppKit
import SwiftUI

extension WorkspaceView {
    var intelligenceColumn: some View {
        VStack(spacing: 0) {
            tabBar
                .frame(height: 50)
            hairline

            Group {
                switch selectedTab {
                case .assistant:
                    aiPanel
                case .summary:
                    if let summary = store.state.displayedSummary {
                        summaryPanel(summary)
                    } else {
                        emptyActionPanel(
                            icon: "text.alignleft",
                            text: "会议摘要会在生成后显示",
                            buttonTitle: "生成摘要",
                            action: store.requestSummary
                        )
                    }
                case .tasks:
                    tasksPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.08))
    }

    var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 8) {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(selectedTab == tab ? VisualTokens.primaryText : VisualTokens.secondaryText)
                        Capsule()
                            .fill(selectedTab == tab ? VisualTokens.sky : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    var aiPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !isViewingHistory,
                        let insight = store.state.latestInsight,
                        !insight.isEmpty {
                        aiSection(icon: "sparkles", title: "当前洞察") {
                            Text(insight)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if store.state.displayedConversation.isEmpty {
                        emptyState(
                            icon: isViewingHistory ? "bubble.left.and.bubble.right" : "sparkles",
                            text: isViewingHistory
                                ? "继续向这场历史会议提问，回答会追加到原会议"
                                : "提出一个问题，回答会携带可追溯的会议来源"
                        )
                        .frame(minHeight: 180)
                    } else {
                        ForEach(store.state.displayedConversation) { turn in
                            conversationCard(turn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollIndicators(.hidden)

            hairline

            if !isViewingHistory || !store.state.displayedGeneratedQuestions.isEmpty {
                suggestionsSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                hairline
            }

            QuickAskField(store: store, appearance: .aura)
                .padding(16)
        }
    }

    func conversationCard(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            conversationQuestion(turn.question)
            hairline
            conversationContent(turn)
        }
        .padding(14)
        .background(Color.white.opacity(0.032))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VisualTokens.line, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("问题与回答")
    }

    func conversationQuestion(_ question: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(VisualTokens.secondaryText)
            Text(question)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    func conversationContent(_ turn: ConversationTurn) -> some View {
        switch turn.phase {
        case .submitting:
            conversationProgress("正在组装相关会议上下文")
        case .streaming:
            VStack(alignment: .leading, spacing: 10) {
                answerText(turn.answer, mode: .streaming)
                conversationProgress("正在生成回答")
            }
        case .completed:
            completedConversation(turn)
        case .failed:
            failedConversation(turn)
        }
    }

    func completedConversation(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            answerText(turn.answer, mode: .completed)
            if turn.degradedVision {
                Label("当前模型没有看到截图像素，仅使用了文字分析", systemImage: "eye.slash")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.amber)
            }
            if !turn.sources.isEmpty {
                sourceChips(turn.sources)
            }
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.answer, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)
                .help("复制完整回答")
            }
        }
    }

    func failedConversation(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(turn.errorMessage ?? "回答失败", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.danger)
                .textSelection(.enabled)
            Button("重试") { store.retryPrompt(turn.question) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.sky)
        }
    }

    func answerText(_ answer: String, mode: MarkdownParseMode) -> some View {
        MarkdownTextView(
            markdown: answer.isEmpty ? "正在等待内容" : answer,
            mode: answer.isEmpty ? .streaming : mode,
            baseFontSize: 12
        )
        .foregroundStyle(VisualTokens.primaryText.opacity(answer.isEmpty ? 0.52 : 0.90))
    }

    func conversationProgress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(VisualTokens.sky)
            Text(text)
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(VisualTokens.secondaryText)
    }

    var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble")
                Text("猜你想问")
                Spacer()
                if !isViewingHistory {
                    Button(action: store.requestQuestions) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.hasMeetingContext || store.state.suggestionRefresh.phase == .loading)
                    .help("刷新问题")
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(VisualTokens.sky)
            .padding(.bottom, 8)

            if !visibleSuggestionQuestions.isEmpty {
                ForEach(visibleSuggestionQuestions, id: \.self) { question in
                    Button {
                        store.setQuickPromptDraft(question)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundStyle(VisualTokens.sky)
                            Text(question)
                                .foregroundStyle(VisualTokens.secondaryText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.vertical, 7)
                        .overlay(alignment: .top) {
                            Rectangle().fill(VisualTokens.line).frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if !isViewingHistory, store.state.suggestionRefresh.phase == .loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(VisualTokens.sky)
                    Text("正在根据最新会议内容更新")
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)
                .padding(.vertical, 9)
            } else if !isViewingHistory,
                case .failed(let message) = store.state.suggestionRefresh.phase {
                Button(action: store.requestQuestions) {
                    Label("更新失败，点此重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.amber)
                .help(message)
                .padding(.vertical, 9)
            } else if store.state.displayedGeneratedQuestions.isEmpty {
                Text(isViewingHistory ? "这次会议没有保存建议问题。" : "转写积累后会自动出现值得追问的问题。")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .padding(.vertical, 8)
            }
        }
    }

    var visibleSuggestionQuestions: [String] {
        Array(store.state.displayedGeneratedQuestions.prefix(3))
    }

    func aiSection<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(title == "AI" || title == "当前洞察" ? VisualTokens.sky : VisualTokens.secondaryText)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
