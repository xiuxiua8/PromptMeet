import Foundation

extension MeetingStore {
    func requestScreenshotNow() async {
        guard let backendSessionID else {
            state.reduce(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        state.screenshotOperation = .capturing
        do {
            try await screenshotController.captureSelected(sessionID: backendSessionID)
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .succeeded
            state.reduce(.suggestion("截图已保存，正在分析"))
        } catch ScreenshotPickerError.noSelectedTarget {
            state.screenshotOperation = .failed("请先选择窗口")
            state.reduce(.suggestion("请先选择窗口"))
        } catch {
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .failed(error.localizedDescription)
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func selectCaptureTargetNow() async {
        state.screenshotOperation = .selecting
        do {
            state.screenshotTarget = try await screenshotController.selectTarget()
            state.screenshotOperation = .idle
            state.reduce(.suggestion("已选择截图窗口"))
        } catch ScreenshotPickerError.cancelled {
            state.screenshotOperation = .idle
            state.reduce(.suggestion("窗口选择已取消"))
        } catch {
            state.screenshotTarget = screenshotController.targetState
            state.screenshotOperation = .failed(error.localizedDescription)
            state.reduce(.suggestion(error.localizedDescription))
        }
    }

    func openScreenRecordingSettings() {
        screenshotController.openScreenRecordingSettings()
    }
}
