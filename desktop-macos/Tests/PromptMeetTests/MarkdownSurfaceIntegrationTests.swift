import Foundation
import XCTest

final class MarkdownSurfaceIntegrationTests: XCTestCase {
    func testAIReaderConversationSummaryAndTasksUseSharedMarkdownRenderer() throws {
        let reader = try source("Sources/PromptMeet/Views/AIReaderView.swift")
        let conversation = try source("Sources/PromptMeet/Views/WorkspaceAIView.swift")
        let summaryAndTasks = try source("Sources/PromptMeet/Views/WorkspaceSummaryView.swift")

        XCTAssertTrue(reader.contains("MarkdownTextView("))
        XCTAssertTrue(conversation.contains("MarkdownTextView("))
        XCTAssertGreaterThanOrEqual(
            summaryAndTasks.components(separatedBy: "MarkdownTextView(").count - 1,
            2
        )
    }

    func testSharedRendererKeepsSelectionAccessibilityAndVerticalWrapping() throws {
        let renderer = try source("Sources/PromptMeet/Views/MarkdownTextView.swift")

        XCTAssertTrue(renderer.contains(".textSelection(.enabled)"))
        XCTAssertTrue(renderer.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(renderer.contains(".accessibilityLabel("))
        XCTAssertTrue(renderer.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    func testSuggestionSurfaceOmitsCompetingHeadingAndKeepsRefreshAffordance() throws {
        let workspace = try source("Sources/PromptMeet/Views/WorkspaceAIView.swift")
        let suggestions = try XCTUnwrap(
            workspace.components(separatedBy: "var suggestionsSection: some View").last?
                .components(separatedBy: "var visibleSuggestionQuestions").first
        )

        XCTAssertFalse(suggestions.contains("Text(\"猜你想问\")"))
        XCTAssertTrue(suggestions.contains("Button(action: store.requestQuestions)"))
        XCTAssertTrue(suggestions.contains("visibleSuggestionQuestions"))
    }

    private func source(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
