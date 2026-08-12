import Foundation

protocol TranscriptOutboxStoring: Sendable {
    func enqueue(_ transcript: LocalTranscript, meetingID: String) async throws
    func pending(meetingID: String) async throws -> [LocalTranscript]
    func acknowledge(_ transcriptID: UUID, meetingID: String) async throws
    func markActiveMeeting(_ meeting: ActiveMeetingEnvelope) async throws
    func markPendingFinalization(_ finalization: PendingMeetingFinalization) async throws
    func pendingFinalizations() async throws -> [PendingMeetingFinalization]
    func completeFinalization(meetingID: String) async throws
}

struct ActiveMeetingEnvelope: Codable, Equatable, Sendable {
    let meetingID: String
    let startedAt: Date
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
        var activeMeetings: [ActiveMeetingEnvelope]?
        var finalizations: [PendingMeetingFinalization]?
    }

    private let fileURL: URL
    private var entries: [Entry] = []
    private var activeMeetings: [ActiveMeetingEnvelope] = []
    private var finalizations: [PendingMeetingFinalization] = []
    private var loaded = false

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else if ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] != nil {
            // Test instances each get an isolated temporary file. The production
            // default path is shared app data, so without this an offline-ended
            // meeting left by one test would be re-finalized by another test and
            // inflate its backend call counts (and pollute real app data).
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PromptMeet-TestOutbox", isDirectory: true)
            self.fileURL = directory.appendingPathComponent(UUID().uuidString + ".json")
        } else {
            self.fileURL = Self.defaultFileURL()
        }
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

    func markActiveMeeting(_ meeting: ActiveMeetingEnvelope) async throws {
        try loadIfNeeded()
        guard !activeMeetings.contains(where: { $0.meetingID == meeting.meetingID }),
              !finalizations.contains(where: { $0.meetingID == meeting.meetingID }) else {
            return
        }
        activeMeetings.append(meeting)
        do {
            try persist()
        } catch {
            activeMeetings.removeAll { $0.meetingID == meeting.meetingID }
            throw error
        }
    }

    func markPendingFinalization(
        _ finalization: PendingMeetingFinalization
    ) async throws {
        try loadIfNeeded()
        let previousActive = activeMeetings
        let previousFinalizations = finalizations
        activeMeetings.removeAll { $0.meetingID == finalization.meetingID }
        if !finalizations.contains(where: { $0.meetingID == finalization.meetingID }) {
            finalizations.append(finalization)
        }
        guard activeMeetings != previousActive || finalizations != previousFinalizations else {
            return
        }
        do {
            try persist()
        } catch {
            activeMeetings = previousActive
            finalizations = previousFinalizations
            throw error
        }
    }

    func pendingFinalizations() async throws -> [PendingMeetingFinalization] {
        try loadIfNeeded()
        if !activeMeetings.isEmpty {
            let previousActive = activeMeetings
            let previousFinalizations = finalizations
            for meeting in activeMeetings where !finalizations.contains(
                where: { $0.meetingID == meeting.meetingID }
            ) {
                finalizations.append(
                    PendingMeetingFinalization(
                        meetingID: meeting.meetingID,
                        startedAt: meeting.startedAt
                    )
                )
            }
            activeMeetings.removeAll()
            do {
                try persist()
            } catch {
                activeMeetings = previousActive
                finalizations = previousFinalizations
                throw error
            }
        }
        return finalizations.sorted { $0.startedAt < $1.startedAt }
    }

    func completeFinalization(meetingID: String) async throws {
        try loadIfNeeded()
        let previousActive = activeMeetings
        let previousFinalizations = finalizations
        activeMeetings.removeAll { $0.meetingID == meetingID }
        finalizations.removeAll { $0.meetingID == meetingID }
        guard activeMeetings != previousActive || finalizations != previousFinalizations else {
            return
        }
        do {
            try persist()
        } catch {
            activeMeetings = previousActive
            finalizations = previousFinalizations
            throw error
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
            guard (1...3).contains(document.version) else {
                throw TranscriptOutboxError.invalidData
            }
            entries = document.entries
            activeMeetings = document.activeMeetings ?? []
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
            Document(
                version: 3,
                entries: entries,
                activeMeetings: activeMeetings,
                finalizations: finalizations
            )
        )
        try data.write(to: fileURL, options: .atomic)
    }

    static func defaultFileURL() -> URL {
        // PROMPTMEET_DATA_DIR isolates the outbox per instance so packaged
        // launches never drain another lane's pending work.
        if let dataDirectory = ProcessInfo.processInfo.environment["PROMPTMEET_DATA_DIR"],
           !dataDirectory.isEmpty {
            return URL(fileURLWithPath: dataDirectory)
                .appendingPathComponent("transcript-outbox.json")
        }
        let base: URL
        if Bundle.main.bundleIdentifier == "com.apple.dt.xctest.tool" {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "promptmeet-tests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PromptMeet", isDirectory: true)
        }
        return base.appendingPathComponent("transcript-outbox.json")
    }
}
