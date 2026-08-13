import Foundation
import XCTest
@testable import PromptMeet

@MainActor
final class SubtitleStreamDriverTests: XCTestCase {
    private func line(_ text: String, id: UUID = UUID()) -> TranscriptLine {
        TranscriptLine(id: id, speaker: "会议", text: text, timestamp: Date())
    }

    private func makeStore(sessionID: String? = "meeting-1") -> MeetingStore {
        let store = MeetingStore(transcriptOutbox: TranscriptOutboxSpy())
        store.sessionID = sessionID
        return store
    }

    func testStartKeepsMeasuredWidthsWhenViewReappears() {
        let store = makeStore()
        let first = line("第一段转写")
        store.dispatch(.transcriptFinal(first))
        store.dispatch(.transcriptFinal(line("第二段转写")))
        let driver = SubtitleStreamDriver()

        driver.start(store: store)
        driver.updateWidth(120, for: first.id)

        driver.start(store: store)

        XCTAssertEqual(driver.flow.pages.map(\.text), ["第一段转写", "第二段转写"])
        XCTAssertEqual(driver.flow.pages.first?.width ?? 0, 120, accuracy: 0.001)
        driver.stop()
    }

    func testSyncPagesCopiesLateTranslationOntoBufferedPage() {
        let store = makeStore()
        let first = line("今天讨论了项目进度")
        store.dispatch(.transcriptFinal(first))
        let driver = SubtitleStreamDriver()
        driver.start(store: store)

        store.dispatch(.transcriptTranslated(id: first.id, text: "Today we discussed progress"))
        driver.syncPages(store.state.subtitleFlow.pages, sessionID: store.sessionID)

        XCTAssertEqual(driver.flow.pages.first?.translation, "Today we discussed progress")
        driver.stop()
    }

    func testSyncPagesResetsWhenMeetingChanges() {
        let store = makeStore(sessionID: "meeting-1")
        store.dispatch(.transcriptFinal(line("旧会议内容")))
        let driver = SubtitleStreamDriver()
        driver.start(store: store)

        store.sessionID = "meeting-2"
        store.dispatch(.prepareNewMeeting)
        driver.syncPages(store.state.subtitleFlow.pages, sessionID: store.sessionID)

        XCTAssertTrue(driver.flow.isEmpty)
        driver.stop()
    }
}
