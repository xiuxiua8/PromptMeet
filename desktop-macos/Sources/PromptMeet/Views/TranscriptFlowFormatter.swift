import Foundation

enum TranscriptFlowFormatter {
    static func text(
        lines: [TranscriptLine],
        activeText: String,
        maximumLines: Int = 8
    ) -> String {
        let visibleLines = Array(lines.suffix(maximumLines))
        var result = ""
        var previousTimestamp: Date?

        for line in visibleLines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previousTimestamp, line.timestamp.timeIntervalSince(previousTimestamp) >= 60 {
                result += "  · \(timeFormatter.string(from: line.timestamp))  "
            } else if !result.isEmpty {
                result += " "
            }
            result += text
            previousTimestamp = line.timestamp
        }

        let active = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty {
            if !result.isEmpty { result += " " }
            result += active
        }
        return result
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
