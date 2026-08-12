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

    func testChecklistMarkersBecomeSemanticTaskListContent() {
        let blocks = MarkdownDocument.parse(
            "- [ ] 准备发布\n- [x] 完成回滚演练",
            mode: .completed
        )

        XCTAssertEqual(blocks.map(\.kind), [.taskList(completed: [false, true])])
        XCTAssertEqual(blocks.first?.lines, ["准备发布", "完成回滚演练"])
        XCTAssertFalse(blocks.first?.text.contains("[ ]") ?? true)
        XCTAssertFalse(blocks.first?.text.contains("[x]") ?? true)
    }

    func testStreamingPartialInlineMarkdownDoesNotExposeDanglingMarker() {
        let stable = MarkdownDocument.stableInlineSource(
            "结论 **重要**，后续 **"
        )
        let attributed = MarkdownDocument.inline(stable)

        XCTAssertEqual(String(attributed.characters), "结论 重要，后续 ")
        XCTAssertFalse(String(attributed.characters).contains("**"))
    }

    func testStreamingBalancedInlineMarkdownKeepsItsClosingMarkerForRendering() {
        let stable = MarkdownDocument.stableInlineSource(
            "结论 **重要**"
        )
        let attributed = MarkdownDocument.inline(stable)

        XCTAssertEqual(stable, "结论 **重要**")
        XCTAssertEqual(String(attributed.characters), "结论 重要")
    }

    func testUnmatchedOpeningMarkersAreHiddenForStreamingAndHistoricalReplay() {
        let sources = [
            "结论 **重要",
            "结论 *重要",
            "代码 `rollback --dry-run"
        ]

        let rendered = sources.map {
            String(MarkdownDocument.inline(MarkdownDocument.stableInlineSource($0)).characters)
        }

        XCTAssertEqual(rendered, ["结论 重要", "结论 重要", "代码 rollback --dry-run"])
    }

    func testInlineCodePreservesLiteralAsteriskWhileBalancedMarkdownStillRenders() {
        let source = "`a*b`、\\`字面反引号 与 **重点**"
        let stable = MarkdownDocument.stableInlineSource(source)

        XCTAssertEqual(stable, source)
        XCTAssertEqual(
            String(MarkdownDocument.inline(stable).characters),
            "a*b、`字面反引号 与 重点"
        )
    }
}
