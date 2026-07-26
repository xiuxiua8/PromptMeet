import Foundation
import ScreenCaptureKit
import XCTest

@testable import PromptMeet

@MainActor
final class ScreenCapturePickerTests: XCTestCase {
    func testPickerIsActivatedBeforeNativeWindowIsPresented() {
        let contentPicker = ContentSharingPickerSpy()
        let picker = SystemContentSharingTargetPicker(contentPicker: contentPicker)

        picker.beginPickerPresentation()

        XCTAssertEqual(contentPicker.operations, ["configure", "add", "activate", "present"])
        XCTAssertTrue(contentPicker.isActive)
        XCTAssertEqual(contentPicker.configuration?.allowedPickerModes, [.singleWindow])
    }

    func testSelectingTargetDoesNotCaptureOrUpload() async throws {
        let picker = ScreenshotTargetPickerSpy()
        let capturer = ScreenshotTargetCapturerSpy()
        let uploader = NativeScreenshotUploaderSpy()
        let controller = ScreenCaptureController(
            targetPicker: picker,
            targetCapturer: capturer,
            uploader: uploader
        )

        let selection = try await controller.selectTarget()

        XCTAssertEqual(selection, .selected(label: "测试窗口"))
        XCTAssertEqual(picker.pickCount, 1)
        XCTAssertEqual(capturer.captureCount, 0)
        XCTAssertEqual(uploader.uploadCount, 0)
    }

    func testRepeatedScreenshotsReuseCurrentTargetWithoutPickerChurn() async throws {
        let picker = ScreenshotTargetPickerSpy()
        let capturer = ScreenshotTargetCapturerSpy()
        let uploader = NativeScreenshotUploaderSpy()
        let controller = ScreenCaptureController(
            targetPicker: picker,
            targetCapturer: capturer,
            uploader: uploader
        )
        _ = try await controller.selectTarget()

        try await controller.captureSelected(sessionID: "meeting-1")
        try await controller.captureSelected(sessionID: "meeting-1")

        XCTAssertEqual(picker.pickCount, 1)
        XCTAssertEqual(capturer.captureCount, 2)
        XCTAssertEqual(uploader.uploadCount, 2)
        XCTAssertEqual(uploader.sessionIDs, ["meeting-1", "meeting-1"])
    }

    func testCaptureWithoutSelectionExplainsThatSelectionIsRequired() async {
        let controller = ScreenCaptureController(
            targetPicker: ScreenshotTargetPickerSpy(),
            targetCapturer: ScreenshotTargetCapturerSpy(),
            uploader: NativeScreenshotUploaderSpy()
        )

        do {
            try await controller.captureSelected(sessionID: "meeting-1")
            XCTFail("Expected missing selection")
        } catch {
            XCTAssertEqual(error as? ScreenshotPickerError, .noSelectedTarget)
        }
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

    func add(_ observer: any SCContentSharingPickerObserver) { operations.append("add") }
    func remove(_ observer: any SCContentSharingPickerObserver) { operations.append("remove") }
    func present() { operations.append("present") }
}

@MainActor
private final class ScreenshotTargetPickerSpy: ScreenshotTargetPicking {
    private(set) var pickCount = 0

    func pickTarget() async throws -> ScreenshotTargetHandle {
        pickCount += 1
        return ScreenshotTargetHandle(label: "测试窗口")
    }
}

@MainActor
private final class ScreenshotTargetCapturerSpy: ScreenshotTargetCapturing {
    private(set) var captureCount = 0

    func capture(_ target: ScreenshotTargetHandle) async throws -> Data {
        captureCount += 1
        return Data([0, 1, 2])
    }
}

private final class NativeScreenshotUploaderSpy: NativeScreenshotUploading, @unchecked Sendable {
    private(set) var uploadCount = 0
    private(set) var sessionIDs: [String] = []

    func upload(_ pngData: Data, sessionID: String) async throws {
        uploadCount += 1
        sessionIDs.append(sessionID)
    }
}
