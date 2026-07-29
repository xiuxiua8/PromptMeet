import Foundation
import XCTest
@testable import PromptMeet

final class MarkdownDocumentTests: XCTestCase {
    func testParserRecognizesRichBlockStructure() {
        let markdown = """
        ## 发布结论

        这是 **粗体**、*斜体*、`行内代码` 和 [OpenAI](https://openai.com)。

        - 第一项
        - 第二项

        1. 第一步
        2. 第二步

        > 这是引用

        ```swift
        let answer = 42
        ```
        """

        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading(level: 2), .paragraph, .unorderedList, .orderedList, .quote, .code(language: "swift")]
        )
        XCTAssertEqual(blocks[2].lines, ["第一项", "第二项"])
        XCTAssertEqual(blocks[3].lines, ["第一步", "第二步"])
        XCTAssertEqual(blocks[5].text, "let answer = 42")
        XCTAssertTrue(blocks[5].isComplete)
    }

    func testInlineParserStylesMarkdownWithoutLeavingSyntaxVisible() throws {
        let attributed = MarkdownDocument.inline(
            "这是 **粗体**、*斜体*、`代码` 和 [链接](https://openai.com)。"
        )

        XCTAssertEqual(String(attributed.characters), "这是 粗体、斜体、代码 和 链接。")
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://openai.com" })
    }

    func testUnsafeLinksAreRemovedWhileTextRemainsSelectable() {
        let attributed = MarkdownDocument.inline("[安全](https://openai.com) [危险](javascript:alert(1))")

        XCTAssertEqual(String(attributed.characters), "安全 危险")
        XCTAssertEqual(attributed.runs.compactMap(\.link).map(\.scheme), ["https"])
    }

    func testStreamingUnfinishedFenceBecomesStableCodeBlockWithoutRawFence() {
        let blocks = MarkdownDocument.parse("说明\n\n```swift\nlet value = 1", mode: .streaming)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .code(language: "swift")])
        XCTAssertEqual(blocks.last?.text, "let value = 1")
        XCTAssertFalse(blocks.last?.isComplete ?? true)
        XCTAssertFalse(blocks.last?.text.contains("```") ?? true)
    }

    func testBareFenceIsParsedAsCodeWithoutLanguageLabel() {
        let blocks = MarkdownDocument.parse("```\nplain code\n```", mode: .completed)

        XCTAssertEqual(blocks.map(\.kind), [.code(language: nil)])
        XCTAssertEqual(blocks.first?.text, "plain code")
    }

    func testLongUnbreakableLineIsPreservedForWrappingByTheView() {
        let line = String(repeating: "abcdef", count: 400)

        let block = MarkdownDocument.parse(line, mode: .completed).first

        XCTAssertEqual(block?.kind, .paragraph)
        XCTAssertEqual(block?.text, line)
    }
}
