import Foundation

struct MeetingMilestone: Equatable, Sendable {
    let activeMinutes: Int
    let inputRevision: Int
}

enum MeetingMilestoneDecision: Equatable, Sendable {
    case generate(MeetingMilestone)
    case noAction(MeetingMilestone)
}

struct MeetingAutomationScheduler: Equatable, Sendable {
    let cadence: SummaryCadence
    private var accumulatedActiveSeconds: TimeInterval = 0
    private var activeSince: Date?
    private var nextMilestoneMinutes: Int?
    private var lastGeneratedInputRevision = 0

    init(cadence: SummaryCadence) {
        self.cadence = cadence
        nextMilestoneMinutes = cadence == .off ? nil : cadence.rawValue
    }

    mutating func start(at date: Date) {
        accumulatedActiveSeconds = 0
        activeSince = date
        nextMilestoneMinutes = cadence == .off ? nil : cadence.rawValue
        lastGeneratedInputRevision = 0
    }

    mutating func pause(at date: Date) {
        guard let activeSince else { return }
        accumulatedActiveSeconds += max(0, date.timeIntervalSince(activeSince))
        self.activeSince = nil
    }

    mutating func resume(at date: Date) {
        guard activeSince == nil else { return }
        activeSince = date
    }

    mutating func stop(at date: Date) {
        pause(at: date)
    }

    mutating func evaluate(
        at date: Date,
        inputRevision: Int
    ) -> MeetingMilestoneDecision? {
        guard let initialMilestone = nextMilestoneMinutes else { return nil }
        let activeSeconds = accumulatedActiveSeconds
            + (activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
        let elapsedMinutes = Int(activeSeconds / 60)
        guard elapsedMinutes >= initialMilestone else { return nil }

        var crossedMilestone = initialMilestone
        while crossedMilestone + cadence.rawValue <= elapsedMinutes {
            crossedMilestone += cadence.rawValue
        }
        nextMilestoneMinutes = crossedMilestone + cadence.rawValue
        let milestone = MeetingMilestone(
            activeMinutes: crossedMilestone,
            inputRevision: inputRevision
        )
        guard inputRevision > lastGeneratedInputRevision else {
            return .noAction(milestone)
        }
        lastGeneratedInputRevision = inputRevision
        return .generate(milestone)
    }
}
