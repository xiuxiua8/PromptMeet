import AppKit
import SwiftUI

extension WorkspaceView {
    var historyColumn: some View {
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

    func historyItem(
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

    var workspaceProjection: WorkspaceProjection {
        WorkspaceProjection(
            events: store.state.displayedTimeline,
            conversation: store.state.displayedConversation
        )
    }

    @ViewBuilder
    var timelineColumn: some View {
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

    func timelineItem(_ item: WorkspaceTimelineItem) -> some View {
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

                timelineItemBody(item)

                if !item.sources.isEmpty {
                    sourceChips(item.sources)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(timelineTint(item.kind).opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(timelineTint(item.kind).opacity(0.12), lineWidth: 0.5)
            }
        }
    }

    @ViewBuilder
    func timelineItemBody(_ item: WorkspaceTimelineItem) -> some View {
        if item.kind == .transcript || item.kind == .lifecycle {
            Text(item.body)
                .font(.system(size: item.kind == .transcript ? 13 : 12, design: .rounded))
                .foregroundStyle(VisualTokens.primaryText.opacity(item.isFailure ? 0.66 : 0.90))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownTextView(markdown: item.body, baseFontSize: 12)
                .foregroundStyle(VisualTokens.primaryText.opacity(item.isFailure ? 0.66 : 0.90))
        }
    }

    @ViewBuilder
    func screenshotPreview(_ screenshot: ScreenshotAsset) -> some View {
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

    func sourceChips(_ sources: [EvidenceSource]) -> some View {
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
