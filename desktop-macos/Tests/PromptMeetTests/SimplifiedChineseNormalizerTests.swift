import Foundation
import XCTest
@testable import PromptMeet

final class SimplifiedChineseNormalizerTests: XCTestCase {
    func testTraditionalMeetingVocabularyConvertsToSimplified() {
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize(
                "今天下午的會議主要討論了項目進度和下一步計劃，大家對新版本的功能提出了很多建議。"
            ),
            "今天下午的会议主要讨论了项目进度和下一步计划，大家对新版本的功能提出了很多建议。"
        )
    }

    func testPhraseContextPreservesReadingsThatWouldCorruptAtCharLevel() {
        // 著作 must NOT become 着作 (char-level 著 would corrupt it).
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("這本著作的內容很豐富。"),
            "这本著作的内容很丰富。"
        )
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("請看下一頁。"),
            "请看下一页。"
        )
    }

    func testAmbiguousCharactersResolveToSimplified() {
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("發"), "发")
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("髮"), "发")
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("乾燥"), "干燥")
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("幹部"), "干部")
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("裏面"), "里面")
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize("後臺"), "后台")
    }

    func testSimplifiedAndPunctuationPassThrough() {
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("好的，明白了。"),
            "好的，明白了。"
        )
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("今天下午的会议主要讨论了项目进度。"),
            "今天下午的会议主要讨论了项目进度。"
        )
    }

    func testEnglishTextIsUntouched() {
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("The meeting covered the project timeline."),
            "The meeting covered the project timeline."
        )
    }

    func testCodeSwitchedTextConvertsOnlyHanRanges() {
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("這個季度我們完成了主要功能,The next quarter."),
            "这个季度我们完成了主要功能,The next quarter."
        )
    }

    func testEmptyTextIsUnchanged() {
        XCTAssertEqual(SimplifiedChineseNormalizer.normalize(""), "")
    }

    func testCommonMeetingVariantCharacters() {
        // Traditional forms of common meeting vocabulary all convert.
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("會議記錄"),
            "会议记录"
        )
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("用戶反饋"),
            "用户反馈"
        )
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("發佈儀表盤"),
            "发布仪表盘"
        )
        XCTAssertEqual(
            SimplifiedChineseNormalizer.normalize("時間安排"),
            "时间安排"
        )
    }
}
