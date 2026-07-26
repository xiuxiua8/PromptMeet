import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: MeetingStore
    let openSettings: () -> Void

    @State private var selectedTab = WorkspaceTab.ai
    @State private var showsHistory = false
    @State private var followsTranscript = true
    @State private var showsNewMeetingConfirmation = false

    private enum WorkspaceTab: String, CaseIterable {
        case ai = "AI"
        case summary = "摘要"
        case tasks = "待办"
    }

    private var isViewingHistory: Bool {
        store.state.selectedArchivedMeetingID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            hairline

            HSplitView {
                if showsHistory {
                    historyColumn
                        .frame(minWidth: 190, idealWidth: 210, maxWidth: 230)
                }

                timelineColumn
                    .frame(minWidth: 470, idealWidth: 570)

                intelligenceColumn
                    .frame(minWidth: 390, idealWidth: 450, maxWidth: 520)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(workspaceBackground)
        .foregroundStyle(VisualTokens.primaryText)
        .task { await store.loadMeetingHistoryNow() }
        .confirmationDialog(
            "当前会议仍在进行",
            isPresented: $showsNewMeetingConfirmation,
            titleVisibility: .visible
        ) {
            Button("结束当前会议并开始新会议", role: .destructive) {
                store.replaceActiveMeeting()
            }
            Button("继续当前会议", role: .cancel) {}
        } message: {
            Text("当前会议会先安全结束并保存，然后创建完全隔离的新会议上下文。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            toolbarButton(
                showsHistory ? "隐藏会议历史" : "显示会议历史",
                icon: "sidebar.left",
                action: { withAnimation(.easeOut(duration: 0.18)) { showsHistory.toggle() } }
            )

            Circle()
                .fill(store.state.phase == .live ? VisualTokens.live : VisualTokens.tertiaryText)
                .frame(width: 6, height: 6)
                .shadow(
                    color: store.state.phase == .live ? VisualTokens.live.opacity(0.55) : .clear,
                    radius: 7
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(isViewingHistory ? "历史会议" : "当前会议")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(workspaceStatus)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(store.state.phase == .live ? VisualTokens.live : VisualTokens.secondaryText)
            }

            Spacer(minLength: 18)

            toolbarButton(
                "截图",
                icon: "viewfinder",
                disabled: !store.hasMeetingContext || isViewingHistory,
                action: store.requestScreenshot
            )
            toolbarButton(
                "生成摘要",
                icon: "text.alignleft",
                disabled: !store.hasMeetingContext || isViewingHistory,
                action: store.requestSummary
            )

            if store.state.phase == .live {
                toolbarButton("结束当前会议", icon: "stop.fill", action: store.endMeeting)
            }

            Button(action: beginNewMeeting) {
                Label("开始新会议", systemImage: "plus.circle.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background(VisualTokens.live)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("创建新的隔离会议上下文")

            toolbarButton("设置", icon: "gearshape", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private func beginNewMeeting() {
        if store.state.phase == .live || store.state.phase == .connecting {
            showsNewMeetingConfirmation = true
        } else {
            store.startMeeting()
        }
    }

    private func toolbarButton(
        _ title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VisualTokens.secondaryText)
                .frame(width: 30, height: 30)
                .background(VisualTokens.raised.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("会议历史")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)

            historyItem(
                "当前会议",
                detail: workspaceStatus,
                active: store.state.selectedArchivedMeetingID == nil
            ) {
                store.selectArchivedMeeting(nil)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.state.meetingHistory) { meeting in
                        historyItem(
                            meeting.title
                                ?? meeting.summary?.summaryText.split(separator: "\n").first.map(String.init)
                                ?? "历史会议",
                            detail: "\(meeting.startTime.formatted(date: .abbreviated, time: .shortened))"
                                + " · \(meetingStatus(meeting.status))",
                            active: store.state.selectedArchivedMeetingID == meeting.id
                        ) {
                            store.selectArchivedMeeting(meeting.id)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(Color.black.opacity(0.10))
        .overlay(alignment: .trailing) {
            Rectangle().fill(VisualTokens.line).frame(width: 1)
        }
    }

    private func historyItem(
        _ title: String,
        detail: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(active ? VisualTokens.sky : Color.clear)
                    .frame(width: 2, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(active ? Color.white.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var workspaceProjection: WorkspaceProjection {
        WorkspaceProjection(
            events: store.state.displayedTimeline,
            conversation: store.state.displayedConversation
        )
    }

    @ViewBuilder
    private var timelineColumn: some View {
        if store.state.displayedTimeline.isEmpty {
            transcriptColumn
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("会议时间线")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("\(workspaceProjection.items.count)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.tertiaryText)
                    Spacer()
                    Label("按会议时间排序", systemImage: "clock")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
                .padding(.horizontal, 20)
                .frame(height: 50)

                hairline

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(workspaceProjection.items) { item in
                                timelineItem(item)
                                    .id(item.id)
                            }
                            if !isViewingHistory && !store.state.activeTranscript.isEmpty {
                                activeTranscriptRow
                            }
                            Color.clear.frame(height: 20).id("timeline-bottom")
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: workspaceProjection.items.count) { _, _ in
                        guard followsTranscript else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func timelineItem(_ item: WorkspaceTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 7) {
                Text(item.timestamp, style: .time)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)
                Image(systemName: timelineIcon(item.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(timelineTint(item.kind))
                    .frame(width: 22, height: 22)
                    .background(timelineTint(item.kind).opacity(0.12))
                    .clipShape(Circle())
            }
            .frame(width: 48)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.isFailure ? VisualTokens.danger : timelineTint(item.kind))
                    Spacer()
                    if !item.sources.isEmpty {
                        Text("\(item.sources.count) 个来源")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(VisualTokens.secondaryText)
                    }
                }

                if let screenshot = item.screenshot {
                    screenshotPreview(screenshot)
                }

                Text(item.body)
                    .font(.system(size: item.kind == .transcript ? 13 : 12, design: .rounded))
                    .foregroundStyle(VisualTokens.primaryText.opacity(item.isFailure ? 0.66 : 0.90))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.sources.isEmpty {
                    sourceChips(item.sources)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(timelineTint(item.kind).opacity(item.kind == .answer ? 0.09 : 0.045))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(timelineTint(item.kind).opacity(0.12), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    private func screenshotPreview(_ screenshot: ScreenshotAsset) -> some View {
        if let url = screenshot.availableFileURL(), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 240)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("会议截图")
        } else {
            HStack(spacing: 10) {
                Image(systemName: "photo.badge.exclamationmark")
                Text("截图文件不可用，时间线和分析记录仍已保留")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(VisualTokens.amber)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VisualTokens.amber.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func sourceChips(_ sources: [EvidenceSource]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Text("[\(source.sourceID)] \(source.label)")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(VisualTokens.sky.opacity(0.10))
                        .clipShape(Capsule())
                        .help(source.label)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func timelineIcon(_ kind: WorkspaceTimelineItemKind) -> String {
        switch kind {
        case .lifecycle: "circle.dotted"
        case .transcript: "waveform"
        case .screenshot: "photo"
        case .screenshotAnalysis: "viewfinder.circle"
        case .question: "person.crop.circle"
        case .answer: "sparkles"
        case .summary: "text.alignleft"
        }
    }

    private func timelineTint(_ kind: WorkspaceTimelineItemKind) -> Color {
        switch kind {
        case .lifecycle: VisualTokens.secondaryText
        case .transcript: VisualTokens.live
        case .screenshot: VisualTokens.amber
        case .screenshotAnalysis, .answer: VisualTokens.sky
        case .question: VisualTokens.primaryText
        case .summary: VisualTokens.cobalt
        }
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("会议记录")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("\(store.state.displayedTranscript.count)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)

                Spacer()

                Button {
                    followsTranscript.toggle()
                } label: {
                    Image(systemName: followsTranscript ? "arrow.down.to.line" : "pause")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(followsTranscript ? VisualTokens.live : VisualTokens.secondaryText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(followsTranscript ? "自动跟随转写" : "恢复自动跟随")
            }
            .padding(.horizontal, 20)
            .frame(height: 50)

            hairline

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.state.displayedTranscript.isEmpty {
                            emptyState(
                                icon: "waveform",
                                text: isViewingHistory ? "这次会议没有保存转写" : "开始录音后，转写会在这里连续出现"
                            )
                            .frame(minHeight: 360)
                        } else {
                            let enumerated = Array(store.state.displayedTranscript.enumerated())
                            ForEach(enumerated, id: \.element.id) { index, line in
                                transcriptRow(
                                    line,
                                    isLast: index == store.state.displayedTranscript.count - 1
                                        && store.state.activeTranscript.isEmpty
                                )
                                .id(line.id)
                            }
                        }

                        if !isViewingHistory && !store.state.activeTranscript.isEmpty {
                            activeTranscriptRow
                                .id("active-transcript")
                        }

                        Color.clear
                            .frame(height: 32)
                            .id("transcript-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                }
                .scrollIndicators(.hidden)
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

    private func transcriptRow(_ line: TranscriptLine, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                Text(line.timestamp, style: .time)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)

                Circle()
                    .fill(VisualTokens.live.opacity(0.72))
                    .frame(width: 5, height: 5)

                if !isLast {
                    Rectangle()
                        .fill(VisualTokens.line)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 46)

            VStack(alignment: .leading, spacing: 7) {
                Text(line.speaker)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(VisualTokens.live)

                Text(line.text)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let translation = line.translatedText {
                    Text(translation)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
        }
    }

    private var activeTranscriptRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                Text("现在")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.live)
                Circle()
                    .fill(VisualTokens.live)
                    .frame(width: 6, height: 6)
                    .shadow(color: VisualTokens.live.opacity(0.55), radius: 6)
            }
            .frame(width: 46)

            Text(store.state.activeTranscript)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.primaryText.opacity(0.80))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 22)
        }
    }

    private var intelligenceColumn: some View {
        VStack(spacing: 0) {
            tabBar
                .frame(height: 50)
            hairline

            Group {
                switch selectedTab {
                case .ai:
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

    private var tabBar: some View {
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

    private var aiPanel: some View {
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

                    if !isViewingHistory {
                        suggestionsSection
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

            QuickAskField(store: store, appearance: .aura)
                .padding(16)
        }
    }

    private func conversationCard(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(VisualTokens.secondaryText)
                Text(turn.question)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            hairline

            switch turn.phase {
            case .submitting:
                conversationProgress("正在组装相关会议上下文")
            case .streaming:
                VStack(alignment: .leading, spacing: 10) {
                    answerText(turn.answer)
                    conversationProgress("正在生成回答")
                }
            case .completed:
                VStack(alignment: .leading, spacing: 10) {
                    answerText(turn.answer)
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
            case .failed:
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

    private func answerText(_ answer: String) -> some View {
        Text(answer.isEmpty ? "正在等待内容" : answer)
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(VisualTokens.primaryText.opacity(answer.isEmpty ? 0.52 : 0.90))
            .lineSpacing(5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func conversationProgress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(VisualTokens.sky)
            Text(text)
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(VisualTokens.secondaryText)
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble")
                Text("猜你想问")
                Spacer()
                Button(action: store.requestQuestions) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!store.hasMeetingContext)
                .help("刷新问题")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(VisualTokens.sky)
            .padding(.bottom, 8)

            if store.state.generatedQuestions.isEmpty {
                Text("转写积累后会自动出现值得追问的问题。")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.state.generatedQuestions.prefix(3), id: \.self) { question in
                    Button { store.setQuickPromptDraft(question) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundStyle(VisualTokens.sky)
                            Text(question)
                                .foregroundStyle(VisualTokens.secondaryText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.vertical, 9)
                        .overlay(alignment: .top) {
                            Rectangle().fill(VisualTokens.line).frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func aiSection<Content: View>(
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

    private func summaryPanel(_ summary: MeetingSummaryContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(summary.summaryText)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !summary.keyPoints.isEmpty {
                    summaryList("关键点", values: summary.keyPoints, tint: VisualTokens.live)
                }
                if !summary.decisions.isEmpty {
                    summaryList("已确认", values: summary.decisions, tint: VisualTokens.sky)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private var tasksPanel: some View {
        Group {
            if let tasks = store.state.displayedSummary?.tasks, !tasks.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .stroke(VisualTokens.live.opacity(0.70), lineWidth: 1)
                                    .frame(width: 12, height: 12)
                                    .padding(.top, 3)

                                VStack(alignment: .leading, spacing: 7) {
                                    Text(task.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))

                                    HStack(spacing: 10) {
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
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundStyle(VisualTokens.secondaryText)
                                            .lineSpacing(3)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 14)
                            .overlay(alignment: .top) {
                                Rectangle().fill(VisualTokens.line).frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState(icon: "checklist", text: "摘要生成后，识别出的待办会显示在这里")
            }
        }
    }

    private func summaryList(_ title: String, values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)

            ForEach(values, id: \.self) { value in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(value)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func emptyActionPanel(
        icon: String,
        text: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            emptyState(icon: icon, text: text)
            Button(buttonTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualTokens.sky)
                .disabled(!store.hasMeetingContext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(VisualTokens.tertiaryText)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var workspaceStatus: String {
        if isViewingHistory {
            return "可回顾并继续提问"
        }
        if store.state.phase == .live {
            return "实时转写中"
        }
        return store.hasMeetingContext ? "可继续整理" : "尚未开始"
    }

    private func meetingStatus(_ status: StoredMeetingStatus) -> String {
        switch status {
        case .active: "进行中"
        case .completed: "已完成"
        case .incomplete: "未完整结束"
        case .recoveryRequired: "需要恢复"
        }
    }

    private var hairline: some View {
        LinearGradient(
            colors: [.clear, VisualTokens.line, VisualTokens.line, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
    }

    private var workspaceBackground: some View {
        ZStack {
            VisualTokens.island
            RadialGradient(
                colors: [VisualTokens.sky.opacity(0.055), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [VisualTokens.live.opacity(0.035), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 460
            )
        }
    }
}
