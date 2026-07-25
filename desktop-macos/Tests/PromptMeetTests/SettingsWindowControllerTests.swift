import XCTest
@testable import PromptMeet

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsControllerCreatesReusableNativeWindow() {
        let controller = SettingsWindowController()

        controller.show()
        let firstWindow = controller.window
        controller.show()

        XCTAssertEqual(firstWindow?.title, "PromptMeet 设置")
        XCTAssertTrue(firstWindow === controller.window)
        XCTAssertTrue(controller.window?.isVisible == true)
        controller.close()
    }
}
