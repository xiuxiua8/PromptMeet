import Foundation

extension MeetingStore {
    func requestScreenshotNow() async {
        guard let backendSessionID else {
            dispatch(.suggestion(state.phase == .live ? "AI companion 暂未连接" : "请先开始会议"))
            return
        }
        modify(\.screenshotOperation, to: .capturing)
        do {
            try await screenshotController.captureSelected(sessionID: backendSessionID)
            modify(\.screenshotTarget, to: screenshotController.targetState)
            modify(\.screenshotOperation, to: .succeeded)
            dispatch(.suggestion("截图已保存，正在分析"))
        } catch ScreenshotPickerError.noSelectedTarget {
            modify(\.screenshotOperation, to: .failed("请先选择窗口"))
            dispatch(.suggestion("请先选择窗口"))
        } catch {
            modify(\.screenshotTarget, to: screenshotController.targetState)
            modify(\.screenshotOperation, to: .failed(error.localizedDescription))
            dispatch(.suggestion(error.localizedDescription))
        }
    }

    func selectCaptureTargetNow() async {
        modify(\.screenshotOperation, to: .selecting)
        do {
            modify(\.screenshotTarget, to: try await screenshotController.selectTarget())
            modify(\.screenshotOperation, to: .idle)
            dispatch(.suggestion("已选择截图窗口"))
        } catch ScreenshotPickerError.cancelled {
            modify(\.screenshotOperation, to: .idle)
            dispatch(.suggestion("窗口选择已取消"))
        } catch {
            modify(\.screenshotTarget, to: screenshotController.targetState)
            modify(\.screenshotOperation, to: .failed(error.localizedDescription))
            dispatch(.suggestion(error.localizedDescription))
        }
    }

    func openScreenRecordingSettings() {
        screenshotController.openScreenRecordingSettings()
    }
}
