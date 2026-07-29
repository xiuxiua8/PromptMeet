import AppKit
import SwiftUI

extension WorkspaceView {
    func summaryPanel(_ summary: MeetingSummaryContent) -> some View {
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

    var tasksPanel: some View {
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

    func summaryList(_ title: String, values: [String], tint: Color) -> some View {
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

    func emptyActionPanel(
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

    func emptyState(icon: String, text: String) -> some View {
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

}
