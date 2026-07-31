import Foundation

extension MeetingStore {
    func evaluateAutomationNow(at date: Date) async {
        guard state.phase == .live, state.recordingActivity == .recording else { return }
        guard var scheduler = automationScheduler else { return }
        let decision = scheduler.evaluate(at: date, inputRevision: meetingInputRevision)
        automationScheduler = scheduler
        guard let decision else { return }
        switch decision {
        case .noAction(let milestone):
            modify(\.summaryAutomation, to: .noAction(
                activeMinute: milestone.activeMinutes,
                message: "没有新的会议输入，已跳过本次生成"
            ))
        case .generate(let milestone):
            await generateMilestoneSummary(milestone)
        }
    }

    private func generateMilestoneSummary(_ milestone: MeetingMilestone) async {
        guard let backendSessionID else { return }
        modify(\.summaryAutomation, to: .generating(activeMinute: milestone.activeMinutes))
        do {
            let response = try await backend.generateSummary(
                sessionID: backendSessionID,
                request: SummaryGenerationRequest(
                    trigger: .milestone,
                    activeMinutes: milestone.activeMinutes,
                    clientInputRevision: milestone.inputRevision
                )
            )
            applySummaryResponse(response, activeMinute: milestone.activeMinutes)
        } catch {
            modify(\.summaryAutomation, to: .failed(error.localizedDescription))
        }
    }

    func startAutomationClock(at date: Date) {
        let cadence = meetingPreferences.summaryCadence
        var scheduler = MeetingAutomationScheduler(cadence: cadence)
        scheduler.start(at: date)
        automationScheduler = scheduler
        automationClockTask?.cancel()
        guard cadence != .off else {
            modify(\.summaryAutomation, to: .off)
            return
        }
        modify(\.summaryAutomation, to: .waiting(nextActiveMinute: cadence.rawValue))
        automationClockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                await self.evaluateAutomationNow(at: self.now())
            }
        }
    }

    func registerMeetingInput(token: String) {
        if meetingInputTokens.insert(token).inserted {
            meetingInputRevision += 1
        }
    }

    func applySummaryResponse(
        _ response: SummaryGenerationResponse,
        activeMinute: Int?
    ) {
        switch response.status {
        case .generated:
            dispatch(.suggestion("会议摘要与待办已更新"))
        case .noAction:
            modify(\.summaryAutomation, to: .noAction(
                activeMinute: activeMinute ?? 0,
                message: response.message
            ))
        case .failed:
            modify(\.summaryAutomation, to: .failed(response.message))
        }
    }
}
