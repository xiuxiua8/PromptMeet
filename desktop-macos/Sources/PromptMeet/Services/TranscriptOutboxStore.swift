import Foundation

protocol TranscriptOutboxStoring: Sendable {
    func enqueue(_ transcript: LocalTranscript, meetingID: String) async throws
    func pending(meetingID: String) async throws -> [LocalTranscript]
    func acknowledge(_ transcriptID: UUID, meetingID: String) async throws
    func markPendingFinalization(_ finalization: PendingMeetingFinalization) async throws
    func pendingFinalizations() async throws -> [PendingMeetingFinalization]
    func completeFinalization(meetingID: String) async throws
}

struct PendingMeetingFinalization: Codable, Equatable, Sendable {
    let meetingID: String
    let startedAt: Date
}

enum TranscriptOutboxError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData: "本机转写同步队列无法读取"
        }
    }
}

actor TranscriptOutboxStore: TranscriptOutboxStoring {
    private struct Entry: Codable, Equatable {
        let meetingID: String
        let id: UUID
        let source: NativeAudioSource
        let text: String
        let timestamp: Date
        let meetingTimeMilliseconds: Int64?
        let translationTarget: String?

        init(meetingID: String, transcript: LocalTranscript) {
            self.meetingID = meetingID
            id = transcript.id
            source = transcript.source
            text = transcript.text
            timestamp = transcript.timestamp
            meetingTimeMilliseconds = transcript.meetingTime?.millisecondsValue
            translationTarget = transcript.translationTarget
        }

        var transcript: LocalTranscript {
            LocalTranscript(
                id: id,
                source: source,
                text: text,
                timestamp: timestamp,
                meetingTime: meetingTimeMilliseconds.map { .milliseconds($0) },
                translationTarget: translationTarget
            )
        }
    }

    private struct Document: Codable {
        let version: Int
        var entries: [Entry]
        var finalizations: [PendingMeetingFinalization]?
    }

    private let fileURL: URL
    private var entries: [Entry] = []
    private var finalizations: [PendingMeetingFinalization] = []
    private var loaded = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    func enqueue(_ transcript: LocalTranscript, meetingID: String) async throws {
        try loadIfNeeded()
        guard !entries.contains(where: { $0.meetingID == meetingID && $0.id == transcript.id }) else {
            return
        }
        entries.append(Entry(meetingID: meetingID, transcript: transcript))
        try persist()
    }

    func pending(meetingID: String) async throws -> [LocalTranscript] {
        try loadIfNeeded()
        return entries.enumerated()
            .filter { $0.element.meetingID == meetingID }
            .sorted { lhs, rhs in
                if let left = lhs.element.meetingTimeMilliseconds,
                   let right = rhs.element.meetingTimeMilliseconds,
                   left != right {
                    return left < right
                }
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.transcript }
    }

    func acknowledge(_ transcriptID: UUID, meetingID: String) async throws {
        try loadIfNeeded()
        let previousCount = entries.count
        entries.removeAll { $0.meetingID == meetingID && $0.id == transcriptID }
        if entries.count != previousCount {
            try persist()
        }
    }

    func markPendingFinalization(
        _ finalization: PendingMeetingFinalization
    ) async throws {
        try loadIfNeeded()
        guard !finalizations.contains(where: { $0.meetingID == finalization.meetingID }) else {
            return
        }
        finalizations.append(finalization)
        try persist()
    }

    func pendingFinalizations() async throws -> [PendingMeetingFinalization] {
        try loadIfNeeded()
        return finalizations.sorted { $0.startedAt < $1.startedAt }
    }

    func completeFinalization(meetingID: String) async throws {
        try loadIfNeeded()
        let previousCount = finalizations.count
        finalizations.removeAll { $0.meetingID == meetingID }
        if finalizations.count != previousCount {
            try persist()
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(
                Document.self,
                from: Data(contentsOf: fileURL)
            )
            guard (1...2).contains(document.version) else {
                throw TranscriptOutboxError.invalidData
            }
            entries = document.entries
            finalizations = document.finalizations ?? []
        } catch {
            loaded = false
            throw TranscriptOutboxError.invalidData
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Document(version: 2, entries: entries, finalizations: finalizations)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
            .appendingPathComponent("transcript-outbox.json")
    }
}
