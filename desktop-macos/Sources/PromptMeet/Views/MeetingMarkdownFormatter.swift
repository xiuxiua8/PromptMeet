import Foundation

enum MeetingMarkdownFormatter {
    static func summary(_ summary: MeetingSummaryContent) -> String {
        var sections = ["# 会议摘要", normalizedMarkdown(summary.summaryText)]
        if !summary.keyPoints.isEmpty {
            sections.append("## 关键点")
            sections.append(markdownList(summary.keyPoints))
        }
        if !summary.decisions.isEmpty {
            sections.append("## 已确认")
            sections.append(markdownList(summary.decisions))
        }
        return sections.joined(separator: "\n\n")
    }

    static func tasks(_ tasks: [MeetingTask]) -> String {
        tasks.map(taskLine).joined(separator: "\n")
    }

    private static func taskLine(_ task: MeetingTask) -> String {
        let checkbox = completedStatuses.contains(task.status.casefolded) ? "[x]" : "[ ]"
        var details: [String] = []
        if let assignee = task.assignee, !assignee.isEmpty {
            details.append("负责人：\(normalizedInline(assignee))")
        }
        if let deadline = task.deadline, !deadline.isEmpty {
            details.append("截止：\(normalizedInline(deadline))")
        }
        details.append("状态：\(statusLabel(task.status))")
        details.append("优先级：\(priorityLabel(task.priority))")
        if !task.details.isEmpty {
            details.append("说明：\(normalizedInline(task.details))")
        }
        return "- \(checkbox) **\(normalizedInline(task.title))** · \(details.joined(separator: " · "))"
    }

    private static func markdownList(_ values: [String]) -> String {
        values.map { "- \(normalizedInline($0))" }.joined(separator: "\n")
    }

    private static func statusLabel(_ status: String) -> String {
        switch status.casefolded {
        case "pending", "todo", "open": "待处理"
        case "in_progress", "in progress", "doing": "进行中"
        case "completed", "complete", "done", "已完成": "已完成"
        case "blocked", "受阻": "受阻"
        default: normalizedInline(status)
        }
    }

    private static func priorityLabel(_ priority: String) -> String {
        switch priority.casefolded {
        case "high", "urgent": "高"
        case "medium", "normal": "中"
        case "low": "低"
        default: normalizedInline(priority)
        }
    }

    private static func normalizedMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedInline(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let completedStatuses: Set<String> = [
        "completed",
        "complete",
        "done",
        "已完成"
    ]
}

private extension String {
    var casefolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
