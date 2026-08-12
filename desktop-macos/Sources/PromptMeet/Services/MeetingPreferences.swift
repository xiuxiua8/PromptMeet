import Foundation

enum SummaryCadence: Int, CaseIterable, Codable, Equatable, Sendable {
    case off = 0
    case threeMinutes = 3
    case fiveMinutes = 5
    case tenMinutes = 10

    var displayName: String {
        switch self {
        case .off: "关闭"
        case .threeMinutes: "每 3 分钟"
        case .fiveMinutes: "每 5 分钟"
        case .tenMinutes: "每 10 分钟"
        }
    }
}

enum MeetingPreferenceKey {
    static let summaryCadenceMinutes = "summaryCadenceMinutes"
    static let includeLocalMicrophone = "includeLocalMicrophone"
}

struct MeetingPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var summaryCadence: SummaryCadence {
        get {
            let stored = defaults.object(forKey: MeetingPreferenceKey.summaryCadenceMinutes) as? Int
            return stored.flatMap(SummaryCadence.init(rawValue:)) ?? .fiveMinutes
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: MeetingPreferenceKey.summaryCadenceMinutes)
        }
    }

    var includeLocalMicrophone: Bool {
        get {
            guard defaults.object(forKey: MeetingPreferenceKey.includeLocalMicrophone) != nil else {
                return true
            }
            return defaults.bool(forKey: MeetingPreferenceKey.includeLocalMicrophone)
        }
        nonmutating set {
            defaults.set(newValue, forKey: MeetingPreferenceKey.includeLocalMicrophone)
        }
    }
}
