import Foundation
import XCTest
@testable import PromptMeet

final class TranscriptScriptTests: XCTestCase {
    func testSimplifiedChineseTextIsHanContent() {
        let profile = TranscriptScriptProfile.analyze("今天下午的会议主要讨论了项目进度。")

        XCTAssertTrue(profile.hasHan)
        XCTAssertFalse(profile.hasLatin)
        XCTAssertFalse(profile.hasThirdScript)
        XCTAssertTrue(profile.isChineseContent)
        XCTAssertGreaterThan(profile.hanCharacters, 0)
    }

    func testEnglishTextIsLatinContent() {
        let profile = TranscriptScriptProfile.analyze("The meeting covered the timeline.")

        XCTAssertTrue(profile.hasLatin)
        XCTAssertFalse(profile.hasHan)
        XCTAssertFalse(profile.hasThirdScript)
        XCTAssertFalse(profile.isChineseContent)
    }

    func testCodeSwitchedMixedTextCountsBothScripts() {
        let profile = TranscriptScriptProfile.analyze("这个季度我们完成了主要功能,The next quarter we will focus on performance.")

        XCTAssertTrue(profile.hasHan)
        XCTAssertTrue(profile.hasLatin)
        XCTAssertFalse(profile.hasThirdScript)
        XCTAssertTrue(profile.isChineseContent)
    }

    func testJapaneseKanaIsThirdScript() {
        let profile = TranscriptScriptProfile.analyze("今日の会議では、プロジェクトの進捗状況について話し合いました。")

        XCTAssertTrue(profile.hasThirdScript)
        XCTAssertTrue(profile.thirdScripts.contains(.japaneseKana))
        XCTAssertFalse(profile.isChineseContent)
    }

    func testGeorgianIsThirdScript() {
        let profile = TranscriptScriptProfile.analyze("ლლლლლ")

        XCTAssertTrue(profile.hasThirdScript)
        XCTAssertTrue(profile.thirdScripts.contains(.georgian))
        XCTAssertFalse(profile.hasHan)
        XCTAssertFalse(profile.hasLatin)
    }

    func testHangulIsThirdScript() {
        let profile = TranscriptScriptProfile.analyze("안녕하세요")

        XCTAssertTrue(profile.thirdScripts.contains(.hangul))
    }

    func testCyrillicAndArabicAreThirdScript() {
        XCTAssertTrue(TranscriptScriptProfile.analyze("привет").thirdScripts.contains(.cyrillic))
        XCTAssertTrue(TranscriptScriptProfile.analyze("مرحبا").thirdScripts.contains(.arabic))
    }

    func testHanContaminatedWithKanaIsNotPureChinese() {
        let profile = TranscriptScriptProfile.analyze("会议を開きます")

        XCTAssertTrue(profile.hasHan)
        XCTAssertTrue(profile.hasThirdScript)
        XCTAssertFalse(profile.isChineseContent)
    }

    func testEmptyAndPunctuationOnlyTextHasNoScript() {
        let empty = TranscriptScriptProfile.analyze("")
        XCTAssertFalse(empty.hasHan)
        XCTAssertFalse(empty.hasLatin)
        XCTAssertFalse(empty.hasThirdScript)

        let punctuation = TranscriptScriptProfile.analyze("，。！？ 123")
        XCTAssertFalse(punctuation.hasHan)
        XCTAssertFalse(punctuation.hasThirdScript)
        XCTAssertFalse(punctuation.hasLatin)
    }

    func testWhisperLanguageNameAndCodeMapping() {
        XCTAssertEqual(TranscriptLanguage.fromWhisperFullName("chinese"), .chinese)
        XCTAssertEqual(TranscriptLanguage.fromWhisperFullName("english"), .english)
        XCTAssertNil(TranscriptLanguage.fromWhisperFullName("japanese"))
        XCTAssertNil(TranscriptLanguage.fromWhisperFullName("georgian"))
        XCTAssertEqual(TranscriptLanguage.fromWhisperCode("zh"), .chinese)
        XCTAssertEqual(TranscriptLanguage.fromWhisperCode("en"), .english)
        XCTAssertEqual(TranscriptLanguage.fromWhisperCode("ja"), nil)
        XCTAssertEqual(TranscriptLanguage.chinese.whisperCode, "zh")
        XCTAssertEqual(TranscriptLanguage.english.whisperCode, "en")
    }
}
