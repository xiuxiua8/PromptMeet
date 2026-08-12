import SwiftUI

struct IslandKeyboardShortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers
}

struct IslandControlPresentation: Equatable {
    let accessibilityLabel: String
    let help: String
    let shortcut: IslandKeyboardShortcut

    static let workspace = IslandControlPresentation(
        accessibilityLabel: "打开工作台和采集状态",
        help: "打开工作台和采集状态",
        shortcut: IslandKeyboardShortcut(key: "m", modifiers: [.command, .shift])
    )

    static let quickAsk = IslandControlPresentation(
        accessibilityLabel: "快速提问",
        help: "打开快速提问",
        shortcut: IslandKeyboardShortcut(key: "p", modifiers: [.command, .shift])
    )

    static func pauseResume(recordingActivity: RecordingActivity) -> IslandControlPresentation {
        let isPaused = recordingActivity == .paused
        return IslandControlPresentation(
            accessibilityLabel: isPaused ? "继续录音" : "暂停录音",
            help: isPaused ? "继续录音" : "暂停录音",
            shortcut: IslandKeyboardShortcut(key: " ", modifiers: [.command, .shift])
        )
    }
}
