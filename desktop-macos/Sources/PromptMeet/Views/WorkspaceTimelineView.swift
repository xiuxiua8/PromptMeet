import AppKit
import SwiftUI

private struct TimelineBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension WorkspaceView {
    var filteredMeetingHistory: [StoredMeeting] {
        MeetingHistorySearch.results(
            in: store.state.meetingHistory,
            query: historySearchText
        )
    }

    var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("会议历史")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                if !historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("\(filteredMeetingHistory.count)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.tertiaryText)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 46)

            historySearchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            historyItem(
                "当前会议",
                detail: workspaceStatus,
                active: store.state.selectedArchivedMeetingID == nil
            ) {
                store.selectArchivedMeeting(nil)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if filteredMeetingHistory.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .medium))
                            Text("没有匹配的会议")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(VisualTokens.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(filteredMeetingHistory) { meeting in
                        historyItem(
                            meeting.displayTitle,
                            detail: "\(meeting.startTime.formatted(date: .abbreviated, time: .shortened))"
                                + " · \(meetingStatus(meeting.status))",
                            active: store.state.selectedArchivedMeetingID == meeting.id
                        ) {
                            store.selectArchivedMeeting(meeting.id)
                        }
                    }
                }
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
        }
        .background(VisualTokens.sidebar)
    }

    var historySearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(VisualTokens.tertiaryText)

            TextField("搜索标题或内容", text: $historySearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .focused($isHistorySearchFocused)
                .accessibilityLabel("搜索会议历史")
                .onExitCommand {
                    if historySearchText.isEmpty {
                        isHistorySearchFocused = false
                    } else {
                        historySearchText = ""
                    }
                }

            if !historySearchText.isEmpty {
                Button {
                    historySearchText = ""
                    isHistorySearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VisualTokens.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除历史搜索")
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    isHistorySearchFocused ? VisualTokens.sky.opacity(0.55) : VisualTokens.line,
                    lineWidth: isHistorySearchFocused ? 1 : 0.5
                )
        }
    }

    func historyItem(
        _ title: String,
        detail: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(active ? VisualTokens.sky : Color.clear)
                    .frame(width: 2, height: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(active ? VisualTokens.selected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(detail)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    var timelineColumn: some View {
        let projection = WorkspaceProjection(
            events: store.state.displayedTimeline,
            conversation: store.state.displayedConversation,
            transcriptLines: store.state.displayedTranscript
        )
        let legacyBlocks = projection.items.isEmpty
            ? WorkspaceProjection.transcriptBlocks(store.state.displayedTranscript)
            : []
        return VStack(alignment: .leading, spacing: 0) {
            timelineHeader(projection)
            hairline
            timelineScrollView(projection, legacyBlocks: legacyBlocks)
        }
        .background(VisualTokens.workspaceSurface)
    }

    func timelineFollowToken(_ projection: WorkspaceProjection) -> String {
        let translationHash = projection.items.last?.transcriptBlock?.translatedText?.hashValue ?? 0
        let tail = projection.items.last.map {
            "\($0.id):\($0.endSequence):\(translationHash)"
        } ?? "legacy:\(store.state.displayedTranscript.count)"
        return "\(tail):\(store.state.activeTranscript)"
    }

    func timelineHeader(_ projection: WorkspaceProjection) -> some View {
        HStack(spacing: 9) {
            Text("会议记录")
                .font(.system(size: 12, weight: .semibold))
            Text("\(projection.items.count) 条输入")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.tertiaryText)
            Spacer()
            Button(action: toggleTimelineFollow) {
                Label(
                    timelineFollowState.isFollowing ? "自动跟随" : "回到最新",
                    systemImage: timelineFollowState.isFollowing ? "arrow.down.to.line" : "arrow.down"
                )
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    timelineFollowState.isFollowing ? VisualTokens.live : VisualTokens.secondaryText
                )
                .padding(.horizontal, 9)
                .frame(height: WorkspaceLayout.actionHeight)
                .background(VisualTokens.raised.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                timelineFollowState.isFollowing ? "暂停自动跟随" : "回到最新转写并恢复自动跟随"
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    func timelineScrollView(
        _ projection: WorkspaceProjection,
        legacyBlocks: [WorkspaceTranscriptBlock]
    ) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    timelineScrollContent(projection, legacyBlocks: legacyBlocks)
                }
                .coordinateSpace(name: "meeting-timeline")
                .scrollIndicators(.hidden)
                .onAppear {
                    timelineFollowState.resume()
                    DispatchQueue.main.async {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: timelineFollowToken(projection)) { _, _ in
                    var followState = timelineFollowState
                    guard followState.contentDidChange() else { return }
                    timelineFollowState = followState
                    DispatchQueue.main.async {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: timelineScrollRequest) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("timeline-bottom", anchor: .bottom)
                    }
                }
                .onPreferenceChange(TimelineBottomPreferenceKey.self) { bottomY in
                    var followState = timelineFollowState
                    followState.update(bottomDistance: max(0, bottomY - viewport.size.height))
                    timelineFollowState = followState
                }
            }
        }
    }

    func timelineScrollContent(
        _ projection: WorkspaceProjection,
        legacyBlocks: [WorkspaceTranscriptBlock]
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if projection.items.isEmpty && legacyBlocks.isEmpty {
                emptyState(
                    icon: "waveform",
                    text: isViewingHistory
                        ? "这次会议没有保存输入记录"
                        : "开始录音后，转写和会议输入会按时间连续出现"
                )
                .frame(minHeight: 360)
            } else if projection.items.isEmpty {
                legacyTranscriptStream(legacyBlocks)
            } else {
                ForEach(projection.items) { item in
                    timelineItem(item)
                        .id(item.id)
                }
            }

            if !isViewingHistory && !store.state.activeTranscript.isEmpty {
                activeTranscriptStreamRow
                    .id("active-transcript")
            }

            Color.clear
                .frame(height: 20)
                .id("timeline-bottom")
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TimelineBottomPreferenceKey.self,
                            value: geometry.frame(in: .named("meeting-timeline")).maxY
                        )
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    func toggleTimelineFollow() {
        if timelineFollowState.toggleFollow() {
            timelineScrollRequest += 1
        }
    }

    @ViewBuilder
    func timelineItem(_ item: WorkspaceTimelineItem) -> some View {
        if let transcriptBlock = item.transcriptBlock {
            transcriptBlockRow(transcriptBlock, timestamp: item.timestamp)
        } else if item.kind == .lifecycle {
            lifecycleTimelineRow(item)
        } else {
            evidenceTimelineRow(item)
        }
    }

    func lifecycleTimelineRow(_ item: WorkspaceTimelineItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.timestamp, style: .time)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.tertiaryText)
                .frame(width: 46, alignment: .leading)
            Image(systemName: timelineIcon(item.kind))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(timelineTint(item.kind))
                .frame(width: 14)
            Text(item.body)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(VisualTokens.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("会议状态，\(item.body)")
    }

    func evidenceTimelineRow(_ item: WorkspaceTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.timestamp, style: .time)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.tertiaryText)
                Image(systemName: timelineIcon(item.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.isFailure ? VisualTokens.danger : timelineTint(item.kind))
            }
            .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(item.isFailure ? VisualTokens.danger : timelineTint(item.kind))
                    if !item.sources.isEmpty {
                        Text("\(item.sources.count) 个来源")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(VisualTokens.tertiaryText)
                    }
                    Spacer()
                }

                if let screenshot = item.screenshot {
                    screenshotPreview(screenshot)
                }

                timelineItemBody(item)

                if !item.sources.isEmpty {
                    sourceChips(item.sources)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(timelineTint(item.kind).opacity(item.isFailure ? 0.025 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        item.isFailure ? VisualTokens.danger.opacity(0.28) : timelineTint(item.kind).opacity(0.14),
                        lineWidth: 0.5
                    )
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title)，\(item.body)")
    }

    @ViewBuilder
    func timelineItemBody(_ item: WorkspaceTimelineItem) -> some View {
        if item.kind == .screenshot {
            Text(item.body)
                .font(.system(size: 11))
                .foregroundStyle(VisualTokens.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownTextView(markdown: item.body, baseFontSize: 11)
                .foregroundStyle(VisualTokens.primaryText.opacity(item.isFailure ? 0.66 : 0.88))
        }
    }

    @ViewBuilder
    func screenshotPreview(_ screenshot: ScreenshotAsset) -> some View {
        if let url = screenshot.availableFileURL(), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 220)
                .background(Color.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("会议截图")
        } else {
            HStack(spacing: 9) {
                Image(systemName: "photo.badge.exclamationmark")
                Text("截图文件不可用，时间线和分析记录仍已保留")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(VisualTokens.amber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VisualTokens.amber.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    func sourceChips(_ sources: [EvidenceSource]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Text("[\(source.sourceID)] \(source.label)")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(VisualTokens.sky)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(VisualTokens.sky.opacity(0.09))
                        .clipShape(Capsule())
                        .help(source.label)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("回答来源")
    }

    func timelineIcon(_ kind: WorkspaceTimelineItemKind) -> String {
        switch kind {
        case .lifecycle: "circle.dotted"
        case .transcript: "waveform"
        case .screenshot: "photo"
        case .screenshotAnalysis: "viewfinder.circle"
        case .summary: "text.alignleft"
        }
    }

    func timelineTint(_ kind: WorkspaceTimelineItemKind) -> Color {
        switch kind {
        case .lifecycle: VisualTokens.secondaryText
        case .transcript: VisualTokens.live
        case .screenshot: VisualTokens.amber
        case .screenshotAnalysis: VisualTokens.sky
        case .summary: VisualTokens.cobalt
        }
    }
}
