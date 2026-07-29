import XCTest
@testable import PromptMeet

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsInputTextUsesReadableColorOnNativeWhiteFields() {
        XCTAssertEqual(SettingsInputAppearance.textColor, .black)
        XCTAssertEqual(SettingsInputAppearance.colorScheme, .light)
        XCTAssertEqual(SettingsInputAppearance.surfaceColorScheme, .dark)
    }

    func testSettingsControllerCreatesReusableNativeWindow() {
        let controller = SettingsWindowController()

        controller.show()
        let firstWindow = controller.window
        controller.show()

        XCTAssertEqual(firstWindow?.title, "PromptMeet 设置")
        XCTAssertEqual(firstWindow?.appearance?.name, .darkAqua)
        XCTAssertTrue(firstWindow === controller.window)
        XCTAssertTrue(controller.window?.isVisible == true)
        controller.close()
    }
}
