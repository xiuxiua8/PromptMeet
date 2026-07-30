import XCTest

@testable import PromptMeet

final class MeetingMarkdownFormatterTests: XCTestCase {
    func testSummaryFormatterKeepsRichSummaryAndStructuresKeyPointsAndDecisions() {
        let summary = MeetingSummaryContent(
            summaryText: "发布窗口已 **确认**，参考 [方案](https://example.com/plan)。",
            tasks: [],
            keyPoints: ["`API` 冻结", "保持 *灰度*"],
            decisions: ["周五上线"]
        )

        let markdown = MeetingMarkdownFormatter.summary(summary)
        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading(level: 1), .paragraph, .heading(level: 2), .unorderedList,
             .heading(level: 2), .unorderedList]
        )
        XCTAssertTrue(markdown.contains("发布窗口已 **确认**"))
        XCTAssertEqual(blocks[3].lines, ["`API` 冻结", "保持 *灰度*"])
        XCTAssertEqual(blocks[5].lines, ["周五上线"])
    }

    func testSummaryFormatterPreservesBlockMarkdownAndFencedCode() {
        let summary = MeetingSummaryContent(
            summaryText: """
            ### 发布步骤

            > 先验证灰度环境

            ```sh
            rollback --dry-run
            ```
            """,
            tasks: [],
            keyPoints: [],
            decisions: []
        )

        let markdown = MeetingMarkdownFormatter.summary(summary)
        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading(level: 1), .heading(level: 3), .quote, .code(language: "sh")]
        )
        XCTAssertEqual(blocks.last?.text, "rollback --dry-run")
        XCTAssertFalse(markdown.contains("### 发布步骤 >"))
    }

    func testTaskFormatterIncludesAssigneeDeadlineStatusPriorityAndDetails() {
        let tasks = [
            MeetingTask(
                title: "准备发布",
                deadline: "周五",
                details: "覆盖 **支付链路**",
                priority: "high",
                assignee: "周岚",
                status: "pending"
            ),
            MeetingTask(
                title: "完成回滚演练",
                priority: "low",
                status: "completed"
            )
        ]

        let markdown = MeetingMarkdownFormatter.tasks(tasks)
        let block = MarkdownDocument.parse(markdown, mode: .completed).first

        XCTAssertTrue(markdown.contains("- [ ] **准备发布**"))
        XCTAssertTrue(markdown.contains("负责人：周岚"))
        XCTAssertTrue(markdown.contains("截止：周五"))
        XCTAssertTrue(markdown.contains("状态：待处理"))
        XCTAssertTrue(markdown.contains("优先级：高"))
        XCTAssertTrue(markdown.contains("说明：覆盖 **支付链路**"))
        XCTAssertTrue(markdown.contains("- [x] **完成回滚演练**"))
        XCTAssertEqual(block?.kind, .taskList(completed: [false, true]))
        XCTAssertFalse(block?.text.contains("[ ]") ?? true)
    }

    func testEmptyStructuredSectionsDoNotCreateEmptyMarkdownHeadings() {
        let summary = MeetingSummaryContent(
            summaryText: "只有摘要正文",
            tasks: [],
            keyPoints: [],
            decisions: []
        )

        let markdown = MeetingMarkdownFormatter.summary(summary)

        XCTAssertEqual(markdown, "# 会议摘要\n\n只有摘要正文")
        XCTAssertFalse(markdown.contains("关键点"))
        XCTAssertFalse(markdown.contains("已确认"))
    }
}
