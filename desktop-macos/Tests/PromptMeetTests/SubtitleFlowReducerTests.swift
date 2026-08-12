import Foundation
import XCTest
@testable import PromptMeet

final class SubtitleFlowReducerTests: XCTestCase {
    private func line(_ text: String, id: UUID = UUID()) -> TranscriptLine {
        TranscriptLine(id: id, speaker: "会议", text: text, timestamp: Date())
    }

    func testTranscriptFinalAppendsToSubtitleFlow() {
        var state = MeetingState()
        let first = line("第一段转写")
        let second = line("第二段转写")

        state.reduce(.transcriptFinal(first))
        state.reduce(.transcriptFinal(second))

        XCTAssertEqual(state.subtitleFlow.pages.map(\.text), ["第一段转写", "第二段转写"])
        XCTAssertEqual(state.subtitleFlow.pages.map(\.id), [first.id, second.id])
    }

    func testDuplicateFinalIsNotAppendedTwice() {
        var state = MeetingState()
        let duplicate = line("只出现一次")

        state.reduce(.transcriptFinal(duplicate))
        state.reduce(.transcriptFinal(duplicate))

        XCTAssertEqual(state.subtitleFlow.pages.count, 1)
        XCTAssertEqual(state.transcript.count, 1)
    }

    func testTranslationUpdateEnrichesBufferedPageInPlace() {
        var state = MeetingState()
        let original = line("今天讨论了项目进度")
        state.reduce(.transcriptFinal(original))

        state.reduce(.transcriptTranslated(id: original.id, text: "Today we discussed progress"))

        XCTAssertEqual(state.subtitleFlow.pages.first?.translation, "Today we discussed progress")
    }

    func testMeetingResetClearsSubtitleFlow() {
        var state = MeetingState()
        state.reduce(.transcriptFinal(line("会议中的转写")))

        state.reduce(.prepareNewMeeting)

        XCTAssertTrue(state.subtitleFlow.isEmpty)
    }
}
