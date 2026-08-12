import AppKit
import XCTest
@testable import PromptMeet

@MainActor
final class IslandWindowControllerTests: XCTestCase {
    func testIslandWindowCanBecomeKeyForPulseTextInput() throws {
        let panel = BorderlessIslandPanel(
            contentRect: .zero,
            styleMask: IslandWindowController.panelStyleMask,
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testPermanentControlsExposeLabelsAndKeyboardShortcuts() {
        XCTAssertEqual(IslandControlPresentation.workspace.accessibilityLabel, "打开工作台和采集状态")
        XCTAssertEqual(IslandControlPresentation.workspace.shortcut.key, "m")
        XCTAssertEqual(IslandControlPresentation.workspace.shortcut.modifiers, [.command, .shift])

        XCTAssertEqual(IslandControlPresentation.quickAsk.accessibilityLabel, "快速提问")
        XCTAssertEqual(IslandControlPresentation.quickAsk.shortcut.key, "p")
        XCTAssertEqual(IslandControlPresentation.quickAsk.shortcut.modifiers, [.command, .shift])

        let pause = IslandControlPresentation.pauseResume(recordingActivity: .recording)
        XCTAssertEqual(pause.accessibilityLabel, "暂停录音")
        XCTAssertEqual(pause.shortcut.key, " ")
        XCTAssertEqual(pause.shortcut.modifiers, [.command, .shift])

        let resume = IslandControlPresentation.pauseResume(recordingActivity: .paused)
        XCTAssertEqual(resume.accessibilityLabel, "继续录音")
        XCTAssertEqual(resume.shortcut, pause.shortcut)
    }
}
