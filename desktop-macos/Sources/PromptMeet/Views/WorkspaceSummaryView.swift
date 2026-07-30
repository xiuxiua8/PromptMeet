import AppKit
import SwiftUI

extension WorkspaceView {
    func summaryPanel(_ summary: MeetingSummaryContent) -> some View {
        ScrollView {
            MarkdownTextView(
                markdown: MeetingMarkdownFormatter.summary(summary),
                baseFontSize: 13
            )
            .foregroundStyle(VisualTokens.primaryText.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    var tasksPanel: some View {
        Group {
            if let tasks = store.state.displayedSummary?.tasks, !tasks.isEmpty {
                ScrollView {
                    MarkdownTextView(
                        markdown: MeetingMarkdownFormatter.tasks(tasks),
                        baseFontSize: 12
                    )
                    .foregroundStyle(VisualTokens.primaryText.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState(icon: "checklist", text: "摘要生成后，识别出的待办会显示在这里")
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
