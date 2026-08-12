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
            companion: companion,
            transcriptOutbox: TranscriptOutboxSpy(),
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
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
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
        let store = MeetingStore(
            backend: backend,
            capture: capture,
            companion: companion,
            transcriptOutbox: TranscriptOutboxSpy()
        )

        await store.startMeetingNow()

        XCTAssertEqual(store.state.phase, .live)
        let meetingID = store.sessionID
        XCTAssertNotNil(meetingID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(backend.performedActions, ["start-native-recording"])
        XCTAssertEqual(backend.connectedSessionID, meetingID)
        XCTAssertEqual(capture.backendSessionID, meetingID)
        XCTAssertEqual(capture.startedSessionID, meetingID)
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
            meetingPreferences: MeetingPreferences(defaults: defaults),
            transcriptOutbox: TranscriptOutboxSpy(),
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
            companion: companion,
            transcriptOutbox: TranscriptOutboxSpy(),
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
            companion: companion,
            transcriptOutbox: TranscriptOutboxSpy(),
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
            companion: companion,
            transcriptOutbox: TranscriptOutboxSpy(),
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
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        let meetingID = store.sessionID
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
        XCTAssertEqual(
            backend.rehydrateRequests,
            meetingID.map { [.init(sessionID: $0, isPaused: true)] } ?? []
        )
        XCTAssertEqual(backend.createSessionCount, 1)
        backend.emit(.connectionEstablished)
        await Task.yield()

        XCTAssertTrue(store.state.isCompanionConnected)
        XCTAssertNil(store.state.latestInsight)
        XCTAssertFalse(WorkspaceView(store: store, openSettings: {}).showsCompanionReconnectAction)
        XCTAssertEqual(store.state.recordingActivity, .paused)
        XCTAssertEqual(capture.stopCount, 0)
    }

}
