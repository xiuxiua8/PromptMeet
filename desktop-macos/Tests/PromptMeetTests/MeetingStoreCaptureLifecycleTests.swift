import XCTest

@testable import PromptMeet

@MainActor
final class MeetingStoreCaptureLifecycleTests: XCTestCase {
    func testEndingMeetingCancelsActiveWindowSelectionAndReturnsToReusableIdle() async {
        let screenshot = BlockingScreenshotCaptureControllerSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            screenshotController: screenshot
        )
        await store.startMeetingNow()
        let selection = Task { await store.selectCaptureTargetNow() }
        while !screenshot.isSelecting {
            await Task.yield()
        }

        await store.endMeetingNow()

        XCTAssertEqual(screenshot.cancelSelectionCount, 1)
        XCTAssertEqual(store.state.screenshotOperation, .idle)
        screenshot.finishSelectionAsCancelled()
        await selection.value

        await store.selectCaptureTargetNow()
        XCTAssertEqual(store.state.screenshotOperation, .idle)
        XCTAssertEqual(store.state.screenshotTarget, .selected(label: "第二次选择"))
    }
}
