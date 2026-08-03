import Combine
import Foundation
import XCTest

@testable import PromptMeet

@MainActor
final class MeetingStoreTests: XCTestCase {
    func testSyntheticUIPreviewModesCoverStableIslandPresentationsWithoutStartingCapture() {
        let capture = NativeAudioCaptureSpy()
        let companion = CompanionLauncherSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: companion
        )

        store.configureUIPreview("live")
        XCTAssertEqual(store.state.recordingActivity, .recording)
        XCTAssertEqual(store.presentation, .live)

        store.configureUIPreview("paused")
        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(store.presentation, .live)

        store.configureUIPreview("hover")
        XCTAssertTrue(store.isHovered)
        XCTAssertEqual(store.presentation, .hoverLive)

        store.configureUIPreview("quick-ask")
        XCTAssertTrue(store.state.isQuickAskPresented)
        XCTAssertEqual(store.presentation, .hoverLive)

        store.configureUIPreview("workspace-compact")
        XCTAssertEqual(store.state.timeline.map(\.kind), [
            .lifecycle,
            .transcript,
            .transcript,
            .transcript,
            .screenshot,
            .screenshotAnalysis,
            .screenshotAnalysis,
            .summary
        ])

        store.configureUIPreview("workspace-large")
        XCTAssertFalse(store.state.timeline.isEmpty)

        XCTAssertNil(capture.startedSessionID)
        XCTAssertEqual(companion.ensureCount, 0)
    }

    func testSharedDraftAndGeneratedQuestionsPublishImmediately() {
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        var snapshots: [MeetingState] = []
        let cancellable = store.$state
            .dropFirst()
            .sink { snapshots.append($0) }

        store.setQuickPromptDraft("谁负责上线？")
        store.receive(.question("截止日期是什么时候？"))

        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].quickPromptDraft, "谁负责上线？")
        XCTAssertEqual(snapshots[1].generatedQuestions, ["截止日期是什么时候？"])
        withExtendedLifetime(cancellable) {}
    }

    func testStartMeetingCreatesSessionConnectsAndStartsRecording() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let companion = CompanionLauncherSpy()
        let store = MeetingStore(backend: backend, capture: capture, companion: companion)

        await store.startMeetingNow()

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertTrue(store.sessionID?.hasPrefix("local-") == true)
        XCTAssertEqual(backend.performedActions, ["start-native-recording"])
        XCTAssertEqual(backend.connectedSessionID, "session-1")
        XCTAssertEqual(capture.backendSessionID, "session-1")
        XCTAssertTrue(capture.startedSessionID?.hasPrefix("local-") == true)
        XCTAssertEqual(companion.ensureCount, 1)
    }

    func testMeetingStartPassesPersistedMicrophoneOptOutToFutureCaptureOnly() async throws {
        let suiteName = "MeetingMicrophonePreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: MeetingPreferenceKey.includeLocalMicrophone)
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: CompanionLauncherSpy(),
            meetingPreferences: MeetingPreferences(defaults: defaults)
        )

        await store.startMeetingNow()

        XCTAssertEqual(capture.includedLocalMicrophone, false)
        XCTAssertTrue(store.nextMeetingCaptureDescription.contains("不会请求麦克风权限"))
    }

    func testCompanionCanBePrewarmedBeforeMeetingStarts() async {
        let companion = CompanionLauncherSpy()
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "retained-meeting",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: companion
        )

        await store.prepareCompanionNow()

        XCTAssertEqual(companion.ensureCount, 1)
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.meetingHistory.map(\.id), ["retained-meeting"])
    }

    func testAIConfigurationReloadRestartsOwnedCompanion() async {
        let companion = CompanionLauncherSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: NativeAudioCaptureSpy(),
            companion: companion
        )

        await store.reloadCompanionConfigurationNow()

        XCTAssertEqual(companion.reloadCount, 1)
        XCTAssertEqual(store.state.latestInsight, "AI 服务配置已更新")
    }

    func testAIConfigurationReloadDefersThroughLiveAndPausedMeetingUntilEnd() async {
        let backend = BackendClientSpy()
        var actionsAtReload: [String] = []
        var disconnectsAtReload = 0
        let companion = CompanionLauncherSpy(onReload: {
            actionsAtReload = backend.performedActions
            disconnectsAtReload = backend.disconnectCount
        })
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: companion
        )
        await store.startMeetingNow()

        await store.reloadCompanionConfigurationNow()
        await store.pauseMeetingNow()
        await store.reloadCompanionConfigurationNow()

        XCTAssertEqual(companion.reloadCount, 0)
        XCTAssertTrue(store.pendingCompanionConfigurationReload)
        XCTAssertFalse(store.canDeleteMeetingHistory)
        XCTAssertEqual(store.state.latestInsight, "AI 服务配置已保存，将在会议结束后应用")

        await store.endMeetingNow()

        XCTAssertEqual(companion.reloadCount, 1)
        XCTAssertEqual(actionsAtReload.last, "store-session")
        XCTAssertEqual(disconnectsAtReload, 1)
        XCTAssertEqual(backend.disconnectCount, 1)
        XCTAssertEqual(backend.healthCheckCount, 2)
        XCTAssertEqual(backend.fetchHistoryCount, 1)
        XCTAssertNil(store.backendSessionID)
        XCTAssertFalse(store.pendingCompanionConfigurationReload)
        XCTAssertTrue(store.canDeleteMeetingHistory)
        XCTAssertEqual(store.state.latestInsight, "AI 服务配置已更新")
    }

    func testCompanionTransportLossPreservesRecordingAndOffersReconnect() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.submitPromptNow("总结当前风险")

        backend.emit(.companionDisconnected("连接已关闭"))
        await Task.yield()

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertEqual(store.state.recordingActivity, .recording)
        XCTAssertEqual(capture.stopCount, 0)
        XCTAssertFalse(store.canDeleteMeetingHistory)
        XCTAssertFalse(store.state.isCompanionConnected)
        XCTAssertEqual(store.state.aiRequest.phase, .failed)
        XCTAssertEqual(store.state.conversationTurns.last?.phase, .failed)
        XCTAssertTrue(store.state.latestInsight?.contains("重新连接 AI 服务") == true)
        XCTAssertTrue(WorkspaceView(store: store, openSettings: {}).showsCompanionReconnectAction)
        XCTAssertTrue(
            MeetingControlPresentation(
                phase: store.state.phase,
                recordingActivity: store.state.recordingActivity
            ).canStop
        )

        await store.pauseMeetingNow()
        backend.emit(.companionDisconnected("消息解析失败"))
        await Task.yield()

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertEqual(store.state.recordingActivity, .paused)

        await store.reconnectCompanionNow()
        XCTAssertFalse(store.state.isCompanionConnected)
        XCTAssertEqual(backend.connectCount, 2)
        backend.emit(.connectionEstablished)
        await Task.yield()

        XCTAssertTrue(store.state.isCompanionConnected)
        XCTAssertNil(store.state.latestInsight)
        XCTAssertFalse(WorkspaceView(store: store, openSettings: {}).showsCompanionReconnectAction)
        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.stopCount, 0)
    }

    func testBackendEventsDriveTranscriptAndReader() async throws {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.submitPromptNow("整理要点")
        let requestID = try XCTUnwrap(backend.prompts.first?.id)

        backend.emit(.transcript(TranscriptLine(speaker: "林晨", text: "确认范围")))
        backend.emit(.answerDelta(requestID: requestID, delta: "已整理"))

        await Task.yield()
        XCTAssertEqual(store.state.transcript.last?.text, "确认范围")
        XCTAssertTrue(store.state.aiReader.isVisible)
        XCTAssertEqual(backend.prompts.map(\.prompt), ["整理要点"])
    }

    func testLocalTranscriptAppearsImmediatelyAndIsSubmittedToBackend() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emit(LocalTranscript(id: UUID(), source: .microphone, text: "本地识别完成"))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.transcript.last?.text, "本地识别完成")
        XCTAssertEqual(store.state.transcript.last?.speaker, "我")
        XCTAssertEqual(backend.submittedTranscripts.map(\.text), ["本地识别完成"])
    }

    func testLocalPartialTranscriptStreamsIntoActiveCaption() async {
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emitPartial("这是正在连续识别的内容")
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.activeTranscript, "这是正在连续识别的内容")
        XCTAssertTrue(store.state.transcript.isEmpty)
    }

    func testCaptureSetupFailureRollsBackRecordingAndMarksDurableMeetingIncomplete() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy(startError: LocalTranscriptionError.modelNotInstalled)
        let store = MeetingStore(backend: backend, capture: capture, companion: CompanionLauncherSpy())

        await store.startMeetingNow()

        guard case .failed = store.state.phase else {
            return XCTFail("Expected failed meeting state")
        }
        XCTAssertEqual(
            backend.performedActions,
            ["start-native-recording", "stop-native-recording", "mark-incomplete"]
        )
        XCTAssertEqual(backend.createSessionCount, 1)
        XCTAssertEqual(backend.connectedSessionID, "session-1")
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(backend.disconnectCount, 0)
    }

    func testLocalTranscriptionStartsWhenCompanionIsUnavailable() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let companion = CompanionLauncherSpy(error: CompanionLauncherError.startupTimedOut)
        let store = MeetingStore(backend: backend, capture: capture, companion: companion)

        await store.startMeetingNow()
        capture.emit(LocalTranscript(source: .microphone, text: "离线字幕可用"))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(store.state.phase, .live)
        XCTAssertNotNil(capture.startedSessionID)
        XCTAssertNil(backend.connectedSessionID)
        XCTAssertTrue(backend.performedActions.isEmpty)
        XCTAssertEqual(store.state.transcript.last?.text, "离线字幕可用")
        XCTAssertTrue(backend.submittedTranscripts.isEmpty)
    }

    func testSourceStatusIsPublishedAndMicrophoneCanRecoverIndependently() async {
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: BackendClientSpy(),
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        capture.emitStatus(AudioCaptureSnapshot(microphone: .denied, system: .active))
        await Task.yield()
        XCTAssertEqual(store.state.audioCapture.microphone, .denied)
        XCTAssertEqual(store.state.audioCapture.system, .active)

        await store.retryMicrophoneNow()
        XCTAssertEqual(capture.retriedSources, [.microphone])
    }

    func testEndingMeetingStoresSessionAndKeepsCompanionContextAvailable() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.endMeetingNow()
        await store.requestSummaryNow()
        await store.submitPromptNow("会后还可以提问吗？")

        XCTAssertEqual(
            backend.performedActions,
            ["start-native-recording", "stop-native-recording", "store-session", "generate-summary"]
        )
        XCTAssertEqual(backend.disconnectCount, 0)
        XCTAssertEqual(backend.prompts.map(\.prompt), ["会后还可以提问吗？"])
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertTrue(store.hasMeetingContext)
    }

}

extension MeetingStoreTests {
    func testFiveMinuteMilestoneRequestsSummaryOnceWhenInputChanged() async throws {
        let suiteName = "MeetingAutomationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(5, forKey: MeetingPreferenceKey.summaryCadenceMinutes)
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let start = Date(timeIntervalSince1970: 10_000)
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy(),
            meetingPreferences: MeetingPreferences(defaults: defaults),
            now: { start }
        )
        await store.startMeetingNow()
        capture.emit(LocalTranscript(source: .system, text: "确认周五发布"))
        try? await Task.sleep(for: .milliseconds(20))

        await store.evaluateAutomationNow(at: start.addingTimeInterval(300))
        await store.evaluateAutomationNow(at: start.addingTimeInterval(301))

        XCTAssertEqual(backend.summaryRequests.count, 1)
        XCTAssertEqual(backend.summaryRequests.first?.activeMinutes, 5)
        XCTAssertEqual(backend.summaryRequests.first?.clientInputRevision, 1)
    }

    func testPauseResumeKeepsMeetingContextAndStopWhilePausedEndsNormally() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy()
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.pauseMeetingNow()
        XCTAssertEqual(store.state.phase, .live)
        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.pauseCount, 1)

        await store.resumeMeetingNow()
        XCTAssertEqual(store.state.recordingActivity, .recording)
        XCTAssertEqual(capture.resumeCount, 1)

        await store.pauseMeetingNow()
        await store.endMeetingNow()
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.recordingActivity, .inactive)
        XCTAssertEqual(
            backend.performedActions,
            [
                "start-native-recording",
                "pause-native-recording",
                "resume-native-recording",
                "pause-native-recording",
                "stop-native-recording",
                "store-session"
            ]
        )
    }

    func testResumeRollsBackendBackToPausedWhenLocalSourcesCannotRestart() async {
        let backend = BackendClientSpy()
        let capture = NativeAudioCaptureSpy(
            resumeError: CaptureError.systemAudioRuntimeFailure("restart failed")
        )
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()
        await store.pauseMeetingNow()

        await store.resumeMeetingNow()

        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.resumeCount, 1)
        XCTAssertEqual(
            backend.performedActions,
            [
                "start-native-recording",
                "pause-native-recording",
                "resume-native-recording",
                "pause-native-recording"
            ]
        )
    }

    func testSaveMeetingStoresCurrentBackendSession() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy()
        )
        await store.startMeetingNow()

        await store.saveMeetingNow()

        XCTAssertEqual(backend.performedActions.last, "store-session")
        XCTAssertEqual(store.state.latestInsight, "会议已保存")
    }

}
