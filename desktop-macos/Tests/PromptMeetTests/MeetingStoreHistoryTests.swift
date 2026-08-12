import XCTest

@testable import PromptMeet

extension MeetingStoreTests {
    func testQuickPromptUsesSharedDraftAndClosesShelfAfterSending() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        store.setQuickPromptDraft("  谁负责上线？  ")
        store.setQuickAskPresented(true)

        await store.submitQuickPromptNow()

        XCTAssertEqual(backend.prompts.map(\.prompt), ["谁负责上线？"])
        XCTAssertTrue(store.state.quickPromptDraft.isEmpty)
        XCTAssertFalse(store.state.isQuickAskPresented)
    }

    func testMeetingHistoryLoadsAndCanBeSelectedWithoutChangingLivePhase() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "历史", text: "旧会议内容")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )

        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        XCTAssertEqual(store.state.meetingHistory.map(\.id), ["archived-1"])
        XCTAssertEqual(store.state.displayedTranscript.first?.text, "旧会议内容")
        XCTAssertEqual(store.state.phase, .idle)
    }

    func testHistoricalQuestionUsesSelectedMeetingAndRefreshesDurableRecord() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "历史", text: "周岚负责回滚")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        await store.submitPromptNow("谁负责回滚？")

        XCTAssertEqual(backend.historicalQuestions.map(\.meetingID), ["archived-1"])
        XCTAssertEqual(
            store.state.conversationTurn(requestID: backend.historicalQuestions[0].requestID)?.answer, "历史回答")
    }

    func testViewingHistoryWhileLiveKeepsQuestionsScopedToArchivedMeeting() async {
        let backend = BackendClientSpy()
        backend.history = [
            StoredMeeting(
                id: "archived-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                transcript: [TranscriptLine(speaker: "会议", text: "历史会议内容")],
                summary: nil
            )
        ]
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()
        await store.loadMeetingHistoryNow()
        store.selectArchivedMeeting("archived-1")

        await store.submitPromptNow("历史会议里谁负责？")

        XCTAssertEqual(backend.historicalQuestions.map(\.meetingID), ["archived-1"])
        XCTAssertTrue(backend.prompts.isEmpty)
        XCTAssertEqual(store.state.phase, .live)
    }

    func testStartingNewMeetingWhileLiveProtectsCurrentContext() async {
        let backend = BackendClientSpy()
        let store = MeetingStore(
            backend: backend,
            capture: NativeAudioCaptureSpy(),
            companion: CompanionLauncherSpy(),
            transcriptOutbox: TranscriptOutboxSpy(),
        )
        await store.startMeetingNow()

        await store.startMeetingNow()

        XCTAssertEqual(backend.createSessionCount, 1)
        XCTAssertEqual(store.state.latestInsight, "当前会议仍在进行，请先结束后再开始新会议")
    }
}
