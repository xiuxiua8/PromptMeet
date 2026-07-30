import Foundation

extension StoredMeeting {
    var displayTitle: String {
        MeetingTitleFallback.title(
            storedTitle: title,
            transcript: transcript,
            summary: summary,
            startedAt: startTime
        )
    }

    var searchableText: String {
        var values = [title, displayTitle].compactMap { $0 }
        values.append(contentsOf: transcript.flatMap { line in
            [line.speaker, line.text, line.translatedText].compactMap { $0 }
        })
        if let summary {
            values.append(summary.summaryText)
            values.append(contentsOf: summary.keyPoints)
            values.append(contentsOf: summary.decisions)
            for task in summary.tasks {
                values.append(task.title)
                values.append(task.details)
                values.append(task.priority)
                values.append(task.status)
                if let assignee = task.assignee { values.append(assignee) }
                if let deadline = task.deadline { values.append(deadline) }
            }
        }
        return values.joined(separator: "\n")
    }
}

enum MeetingHistorySearch {
    private struct RankedMeeting {
        let rank: Int
        let index: Int
        let meeting: StoredMeeting
    }

    static func results(
        in meetings: [StoredMeeting],
        query: String
    ) -> [StoredMeeting] {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return meetings }

        var ranked: [RankedMeeting] = []
        for (index, meeting) in meetings.enumerated() {
            let body = normalized(meeting.searchableText)
            guard terms.allSatisfy(body.contains) else { continue }
            let titleValues = [meeting.title, meeting.displayTitle].compactMap { $0 }
            let title = normalized(titleValues.joined(separator: " "))
            let rank = terms.allSatisfy(title.contains) ? 0 : 1
            ranked.append(RankedMeeting(rank: rank, index: index, meeting: meeting))
        }

        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.index < rhs.index
        }
        .map(\.meeting)
    }

    private static func normalizedTerms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
    }
}

private enum MeetingTitleFallback {
    static let maximumLength = 18
    static let genericTitles: Set<String> = [
        "会议",
        "会议记录",
        "会议总结",
        "历史会议",
        "新会议",
        "未命名会议"
    ]
    static let fillerContent: Set<String> = [
        "ok",
        "okay",
        "um",
        "just",
        "shh",
        "嗯",
        "好",
        "好的",
        "对",
        "是",
        "是的",
        "行"
    ]

    static func title(
        storedTitle: String?,
        transcript: [TranscriptLine],
        summary: MeetingSummaryContent?,
        startedAt: Date
    ) -> String {
        if let storedTitle,
           let title = concise(storedTitle),
           !genericTitles.contains(normalizedKey(title)) {
            return title
        }

        var candidates = transcript.map(\.text)
        if let summary {
            candidates.append(summary.summaryText)
            candidates.append(contentsOf: summary.decisions)
            candidates.append(contentsOf: summary.tasks.map(\.title))
        }
        for candidate in candidates {
            if let title = concise(candidate),
               !genericTitles.contains(normalizedKey(title)) {
                return title
            }
        }

        let timestamp = startedAt.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
        return "\(timestamp) 空会议"
    }

    private static func concise(_ value: String) -> String? {
        var candidate = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(
                of: #"\[([^\]]+)]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.replacingOccurrences(
            of: #"^(?:会议)?标题\s*[:：]\s*"#,
            with: "",
            options: .regularExpression
        )
        for prefix in ["###### ", "##### ", "#### ", "### ", "## ", "# ", "- ", "* ", "+ ", "> "]
            where candidate.hasPrefix(prefix) {
            candidate.removeFirst(prefix.count)
            break
        }
        candidate = candidate.replacingOccurrences(
            of: #"^\[[ xX]]\s*"#,
            with: "",
            options: .regularExpression
        )
        for marker in ["**", "__", "*", "_", "`", "~"] {
            candidate = candidate.replacingOccurrences(of: marker, with: "")
        }
        candidate = candidate
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
            .first?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t，,、；;：:.。'\"“”‘’"))
            ?? ""
        let key = normalizedKey(candidate)
        guard key.count >= 2, !fillerContent.contains(key) else { return nil }
        return String(candidate.prefix(maximumLength))
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }
}
