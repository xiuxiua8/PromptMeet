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
}
