import ScreenCaptureKit
import XCTest
@testable import PromptMeet

@MainActor
final class ScreenCapturePickerTests: XCTestCase {
    func testPickerIsActivatedBeforeNativeWindowIsPresented() {
        let contentPicker = ContentSharingPickerSpy()
        let picker = ScreenCapturePicker(contentPicker: contentPicker)

        picker.beginPickerPresentation()

        XCTAssertEqual(contentPicker.operations, ["configure", "add", "activate", "present"])
        XCTAssertTrue(contentPicker.isActive)
    }
}

@MainActor
private final class ContentSharingPickerSpy: ContentSharingPickerPresenting {
    var operations: [String] = []
    var configuration: SCContentSharingPickerConfiguration? {
        didSet { operations.append("configure") }
    }
    var isActive = false {
        didSet { operations.append(isActive ? "activate" : "deactivate") }
    }

    func add(_ observer: any SCContentSharingPickerObserver) {
        operations.append("add")
    }

    func remove(_ observer: any SCContentSharingPickerObserver) {
        operations.append("remove")
    }

    func present() {
        operations.append("present")
    }
}
