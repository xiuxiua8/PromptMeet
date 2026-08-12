import Foundation

struct BackendEventBatcher: Sendable {
    static let defaultMaximumBufferedCharacters = 32

    private let maximumBufferedCharacters: Int
    private var pending: [UUID?: String] = [:]
    private var pendingOrder: [UUID?] = []

    init(maximumBufferedCharacters: Int = defaultMaximumBufferedCharacters) {
        self.maximumBufferedCharacters = max(1, maximumBufferedCharacters)
    }

    mutating func consume(_ event: BackendEvent) -> [BackendEvent] {
        switch event {
        case .answerDelta(let requestID, let delta):
            return append(delta, requestID: requestID)
        case .answerFinal(let requestID, _):
            removePending(requestID)
            return [event]
        case .aiFailure(let requestID, _):
            return drain(requestID) + [event]
        default:
            return finish() + [event]
        }
    }

    mutating func finish() -> [BackendEvent] {
        let events = pendingOrder.compactMap { requestID -> BackendEvent? in
            guard let delta = pending[requestID], !delta.isEmpty else { return nil }
            return .answerDelta(requestID: requestID, delta: delta)
        }
        pending.removeAll(keepingCapacity: true)
        pendingOrder.removeAll(keepingCapacity: true)
        return events
    }

    private mutating func append(_ delta: String, requestID: UUID?) -> [BackendEvent] {
        guard !delta.isEmpty else { return [] }
        if pending[requestID] == nil {
            pendingOrder.append(requestID)
        }
        pending[requestID, default: ""] += delta
        guard let buffered = pending[requestID],
              buffered.count >= maximumBufferedCharacters else { return [] }
        removePending(requestID)
        return [.answerDelta(requestID: requestID, delta: buffered)]
    }

    private mutating func drain(_ requestID: UUID?) -> [BackendEvent] {
        guard let delta = pending[requestID], !delta.isEmpty else { return [] }
        removePending(requestID)
        return [.answerDelta(requestID: requestID, delta: delta)]
    }

    private mutating func removePending(_ requestID: UUID?) {
        pending.removeValue(forKey: requestID)
        pendingOrder.removeAll { $0 == requestID }
    }
}
