import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: MeetingStore
    let openSettings: () -> Void
    @State private var prompt = ""
    @State private var selectedTab = WorkspaceTab.ai
    @State private var showsHistory = false
    @State private var followsTranscript = true

    private enum WorkspaceTab: String, CaseIterable {
        case ai = "AI"
        case summary = "摘要"
        case tasks = "待办"
        case questions = "追问"
    }

    private var isViewingHistory: Bool {
        store.state.selectedArchivedMeetingID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            Divider().overlay(VisualTokens.line)
            HSplitView {
                if showsHistory {
                    historyColumn.frame(minWidth: 188, idealWidth: 200, maxWidth: 220)
                }
                transcriptColumn.frame(minWidth: 420, idealWidth: 500)
                intelligenceColumn.frame(minWidth: 380, idealWidth: 460, maxWidth: 520)
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .background(Color(red: 0.035, green: 0.038, blue: 0.045))
        .foregroundStyle(VisualTokens.primaryText)
        .task { await store.loadMeetingHistoryNow() }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsHistory.toggle() }
            } label: {
                Image(systemName: showsHistory ? "sidebar.left" : "sidebar.left")
            }
            .help(showsHistory ? "隐藏会议历史" : "显示会议历史")
            VStack(alignment: .leading, spacing: 2) {
                Text("当前会议").font(.system(size: 13, weight: .semibold))
                Text(workspaceStatus)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(store.state.phase == .live ? VisualTokens.live : VisualTokens.secondaryText)
            }
            Spacer()
            Button { store.requestScreenshot() } label: { Label("截图", systemImage: "viewfinder") }
                .disabled(!store.hasMeetingContext || isViewingHistory)
            Button { store.saveMeeting() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .disabled(!store.hasMeetingContext || isViewingHistory)
            Button { store.requestQuestions() } label: { Label("追问", systemImage: "questionmark.bubble") }
                .disabled(!store.hasMeetingContext || isViewingHistory)
            Button { store.requestSummary() } label: { Label("摘要", systemImage: "text.alignleft") }
                .disabled(!store.hasMeetingContext || isViewingHistory)
            Button(store.state.phase == .live ? "结束" : "开始") {
                store.state.phase == .live ? store.endMeeting() : store.startMeeting()
            }
            .buttonStyle(.borderedProminent)
            .tint(store.state.phase == .live ? VisualTokens.danger : VisualTokens.cobalt)
            Divider()
                .overlay(VisualTokens.line)
                .frame(height: 18)
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .foregroundStyle(VisualTokens.secondaryText)
            .keyboardShortcut(",", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("会议").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(VisualTokens.secondaryText)
            historyItem("当前会议", detail: "现在", active: store.state.selectedArchivedMeetingID == nil) {
                store.selectArchivedMeeting(nil)
            }
            ForEach(store.state.meetingHistory) { meeting in
                historyItem(
                    meeting.summary?.summaryText.split(separator: "\n").first.map(String.init) ?? "历史会议",
                    detail: meeting.startTime.formatted(date: .abbreviated, time: .shortened),
                    active: store.state.selectedArchivedMeetingID == meeting.id
                ) {
                    store.selectArchivedMeeting(meeting.id)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Color.black.opacity(0.16))
    }

    private func historyItem(
        _ title: String,
        detail: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(2)
                Text(detail).font(.system(size: 9, design: .rounded)).foregroundStyle(VisualTokens.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(active ? VisualTokens.cobalt.opacity(0.24) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("实时记录")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
                Button {
                    followsTranscript.toggle()
                } label: {
                    Label(followsTranscript ? "跟随中" : "已暂停", systemImage: followsTranscript ? "arrow.down.to.line" : "pause")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(followsTranscript ? VisualTokens.live : VisualTokens.secondaryText)
            }
            .padding(18)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(store.state.displayedTranscript) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(line.speaker).foregroundStyle(VisualTokens.live)
                                    Text(line.timestamp, style: .time).foregroundStyle(VisualTokens.secondaryText)
                                }
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                Text(line.text)
                                    .font(.system(size: 13, design: .rounded))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let translation = line.translatedText {
                                    Text(translation)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(VisualTokens.sky)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .id(line.id)
                        }
                        if !isViewingHistory && !store.state.activeTranscript.isEmpty {
                            Text(store.state.activeTranscript)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(VisualTokens.primaryText.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                                .id("active-transcript")
                        }
                        Color.clear.frame(height: 28).id("transcript-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 28)
                }
                .onChange(of: store.state.displayedTranscript.count) { _, _ in
                    guard followsTranscript else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: store.state.activeTranscript) { _, _ in
                    guard followsTranscript else { return }
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var intelligenceColumn: some View {
        VStack(spacing: 14) {
            Picker("", selection: $selectedTab) {
                ForEach(WorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .ai:
                    if isViewingHistory {
                        emptyPanel("历史会议为只读；可继续查看摘要与待办")
                    } else {
                        aiPanel
                    }
                case .summary:
                    if let summary = store.state.displayedSummary {
                        summaryPanel(summary)
                    } else {
                        emptyActionPanel(
                            "会议摘要将在生成后显示",
                            buttonTitle: "生成摘要",
                            systemImage: "text.alignleft",
                            action: store.requestSummary
                        )
                    }
                case .tasks:
                    tasksPanel
                case .questions:
                    questionsPanel
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .background(Color.black.opacity(0.12))
    }

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.state.generatedQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("猜你想问")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                    ForEach(store.state.generatedQuestions.prefix(3), id: \.self) { question in
                        Button {
                            prompt = question
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "sparkle")
                                Text(question).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(VisualTokens.sky)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let insight = store.state.latestInsight {
                Text(insight)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VisualTokens.sky)
                    .padding(10)
                    .background(VisualTokens.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(store.state.promptHistory.enumerated()), id: \.offset) { _, prompt in
                        Text(prompt)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(VisualTokens.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    if !store.state.aiReader.content.isEmpty {
                        HStack(spacing: 9) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                Text(store.state.aiReader.title)
                            }
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(VisualTokens.sky)
                            Spacer()
                            Button("在阅读器中打开") { store.showReader() }
                                .buttonStyle(.plain)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(VisualTokens.sky)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(VisualTokens.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            Spacer()
            TextField("向 AI 提问…", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(10)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(submitPrompt)
                .disabled(store.state.aiRequest.isBusy)
            Button("发送") { submitPrompt() }
                .buttonStyle(.borderedProminent)
                .tint(VisualTokens.cobalt)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.state.aiRequest.isBusy)
        }
    }

    private func emptyPanel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(VisualTokens.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryPanel(_ summary: MeetingSummaryContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(summary.summaryText)
                    .font(.system(size: 12, design: .rounded))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                if !summary.keyPoints.isEmpty {
                    summaryList("关键点", values: summary.keyPoints, tint: VisualTokens.live)
                }
                if !summary.decisions.isEmpty {
                    summaryList("已确认", values: summary.decisions, tint: VisualTokens.sky)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var tasksPanel: some View {
        Group {
            if let tasks = store.state.displayedSummary?.tasks, !tasks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                HStack(spacing: 9) {
                                    if let assignee = task.assignee, !assignee.isEmpty {
                                        Label(assignee, systemImage: "person")
                                    }
                                    if let deadline = task.deadline, !deadline.isEmpty {
                                        Label(deadline, systemImage: "calendar")
                                    }
                                }
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(VisualTokens.secondaryText)
                                if !task.details.isEmpty {
                                    Text(task.details)
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(VisualTokens.secondaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(VisualTokens.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            } else {
                emptyPanel("摘要生成后，识别出的待办会在这里出现")
            }
        }
    }

    private func summaryList(_ title: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
            ForEach(values, id: \.self) { value in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(tint).frame(width: 4, height: 4).padding(.top, 6)
                    Text(value)
                        .font(.system(size: 11, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var questionsPanel: some View {
        Group {
            if store.state.generatedQuestions.isEmpty {
                emptyActionPanel(
                    "从会议里找出尚未解决的问题",
                    buttonTitle: "生成追问",
                    systemImage: "questionmark.bubble",
                    action: store.requestQuestions
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(store.state.generatedQuestions.enumerated()), id: \.offset) { index, question in
                            HStack(alignment: .top, spacing: 9) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(VisualTokens.sky)
                                Text(question)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineSpacing(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(VisualTokens.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func emptyActionPanel(
        _ text: String,
        buttonTitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(VisualTokens.secondaryText)
            Button(action: action) {
                Label(buttonTitle, systemImage: systemImage)
            }
            .buttonStyle(.bordered)
            .disabled(!store.hasMeetingContext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceStatus: String {
        if isViewingHistory {
            return "历史会议 · 只读"
        }
        if store.state.phase == .live {
            return "实时转写中"
        }
        return store.hasMeetingContext ? "已结束 · 可继续整理" : "尚未开始"
    }

    private func submitPrompt() {
        store.submitPrompt(prompt)
        prompt = ""
    }
}
