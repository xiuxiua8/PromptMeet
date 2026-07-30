import Foundation
import ScreenCaptureKit
import XCTest

@testable import PromptMeet

@MainActor
final class ScreenCapturePickerTests: XCTestCase {
    func testPresentationLifecycleReturnsToReusableIdleAfterCancellation() throws {
        var lifecycle = PickerPresentationLifecycle()
        let first = try lifecycle.begin()

        XCTAssertTrue(lifecycle.isPresenting)
        XCTAssertTrue(lifecycle.finish(generation: first))
        XCTAssertFalse(lifecycle.isPresenting)

        let second = try lifecycle.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(lifecycle.isPresenting)
    }

    func testPresentationLifecycleRejectsDuplicatePresentation() throws {
        var lifecycle = PickerPresentationLifecycle()
        _ = try lifecycle.begin()

        XCTAssertThrowsError(try lifecycle.begin()) { error in
            XCTAssertEqual(error as? ScreenshotPickerError, .selectionInProgress)
        }
    }

    func testStalePickerCallbackCannotFinishNewPresentation() throws {
        var lifecycle = PickerPresentationLifecycle()
        let stale = try lifecycle.begin()
        XCTAssertTrue(lifecycle.finish(generation: stale))
        let current = try lifecycle.begin()

        XCTAssertFalse(lifecycle.finish(generation: stale))
        XCTAssertTrue(lifecycle.isPresenting)
        XCTAssertEqual(lifecycle.activeGeneration, current)
    }

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

    func testCapturedChineseTextIsUploadedWithLocalOCRProvenance() async throws {
        let uploader = NativeScreenshotUploaderSpy()
        let ocr = ScreenshotOCRRecognizerSpy(
            text: "截图证据：青岚计划在 14:30 部署，负责人周岚。"
        )
        let controller = ScreenCaptureController(
            targetPicker: ScreenshotTargetPickerSpy(),
            targetCapturer: ScreenshotTargetCapturerSpy(),
            uploader: uploader,
            ocrRecognizer: ocr
        )
        _ = try await controller.selectTarget()

        try await controller.captureSelected(sessionID: "meeting-ocr")

        XCTAssertEqual(ocr.recognizeCount, 1)
        XCTAssertEqual(
            uploader.ocrTexts,
            ["截图证据：青岚计划在 14:30 部署，负责人周岚。"]
        )
    }

    func testUploadFailurePreservesSelectedTargetAndSurfacesAccurateError() async throws {
        let picker = ScreenshotTargetPickerSpy()
        let uploader = NativeScreenshotUploaderSpy(
            stubbedError: BackendClientError.serviceRejected(503)
        )
        let controller = ScreenCaptureController(
            targetPicker: picker,
            targetCapturer: ScreenshotTargetCapturerSpy(),
            uploader: uploader
        )
        _ = try await controller.selectTarget()

        do {
            try await controller.captureSelected(sessionID: "meeting-1")
            XCTFail("Expected upload failure")
        } catch let error as ScreenshotPickerError {
            guard case .uploadFailed(let reason) = error else {
                XCTFail("Expected uploadFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("503"), "Upload error should surface the underlying status code")
        } catch {
            XCTFail("Expected ScreenshotPickerError, got \(error)")
        }

        XCTAssertEqual(controller.targetState, .selected(label: "测试窗口"))
        XCTAssertEqual(uploader.uploadCount, 1)
    }

    func testCaptureTargetUnavailableMarksTargetInvalidAndRethrows() async throws {
        let capturer = ScreenshotTargetCapturerSpy(
            stubbedError: .selectedTargetUnavailable("已关闭的窗口")
        )
        let controller = ScreenCaptureController(
            targetPicker: ScreenshotTargetPickerSpy(),
            targetCapturer: capturer,
            uploader: NativeScreenshotUploaderSpy()
        )
        _ = try await controller.selectTarget()

        do {
            try await controller.captureSelected(sessionID: "meeting-1")
            XCTFail("Expected capture failure")
        } catch let error as ScreenshotPickerError {
            XCTAssertEqual(error, .selectedTargetUnavailable("已关闭的窗口"))
        } catch {
            XCTFail("Expected ScreenshotPickerError, got \(error)")
        }

        guard case .invalid(let label, let reason) = controller.targetState else {
            XCTFail("Expected targetState .invalid, got \(controller.targetState)")
            return
        }
        XCTAssertEqual(label, "测试窗口")
        XCTAssertTrue(reason.contains("已关闭的窗口"))
    }

    func testCaptureEncodingFailureDoesNotMarkTargetInvalid() async throws {
        let capturer = ScreenshotTargetCapturerSpy(stubbedError: .encodingFailed)
        let controller = ScreenCaptureController(
            targetPicker: ScreenshotTargetPickerSpy(),
            targetCapturer: capturer,
            uploader: NativeScreenshotUploaderSpy()
        )
        _ = try await controller.selectTarget()

        do {
            try await controller.captureSelected(sessionID: "meeting-1")
            XCTFail("Expected capture encoding failure")
        } catch {
            XCTAssertEqual(error as? ScreenshotPickerError, .encodingFailed)
        }

        XCTAssertEqual(controller.targetState, .selected(label: "测试窗口"))
    }

    func testCaptureNonPickerErrorPreservesTargetAndPropagatesError() async throws {
        struct TransientCaptureFailure: Error, Equatable {
            let detail: String
        }
        let capturer = ScreenshotTargetCapturerSpy(
            stubbedCaptureError: TransientCaptureFailure(detail: "SCK timeout")
        )
        let controller = ScreenCaptureController(
            targetPicker: ScreenshotTargetPickerSpy(),
            targetCapturer: capturer,
            uploader: NativeScreenshotUploaderSpy()
        )
        _ = try await controller.selectTarget()

        do {
            try await controller.captureSelected(sessionID: "meeting-1")
            XCTFail("Expected capture failure")
        } catch let error as TransientCaptureFailure {
            XCTAssertEqual(error.detail, "SCK timeout")
        } catch {
            XCTFail("Expected TransientCaptureFailure, got \(error)")
        }

        XCTAssertEqual(controller.targetState, .selected(label: "测试窗口"))
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
    private let stubbedError: ScreenshotPickerError?
    private let stubbedCaptureError: (any Error)?

    init(stubbedError: ScreenshotPickerError? = nil, stubbedCaptureError: (any Error)? = nil) {
        self.stubbedError = stubbedError
        self.stubbedCaptureError = stubbedCaptureError
    }

    func capture(_ target: ScreenshotTargetHandle) async throws -> Data {
        captureCount += 1
        if let stubbedCaptureError { throw stubbedCaptureError }
        if let stubbedError { throw stubbedError }
        return Data([0, 1, 2])
    }
}

private final class NativeScreenshotUploaderSpy: NativeScreenshotUploading, @unchecked Sendable {
    private(set) var uploadCount = 0
    private(set) var sessionIDs: [String] = []
    private(set) var ocrTexts: [String?] = []
    private let stubbedError: (any Error)?

    init(stubbedError: (any Error)? = nil) {
        self.stubbedError = stubbedError
    }

    func upload(_ pngData: Data, sessionID: String, localOCRText: String?) async throws {
        uploadCount += 1
        sessionIDs.append(sessionID)
        ocrTexts.append(localOCRText)
        if let stubbedError { throw stubbedError }
    }
}

private final class ScreenshotOCRRecognizerSpy: ScreenshotOCRRecognizing, @unchecked Sendable {
    private(set) var recognizeCount = 0
    private let text: String?

    init(text: String?) {
        self.text = text
    }

    func recognize(_ pngData: Data) async throws -> String? {
        recognizeCount += 1
        return text
    }
}
