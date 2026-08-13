import AppKit
import Foundation
import XCTest
@testable import PromptMeet

/// Rendering-level coverage for formulas: images, fallback text,
/// emphasis and links around math, and the shared renderer wiring.
@MainActor
final class FormulaRenderingSurfaceTests: XCTestCase {
    // MARK: - Rendering produces real images (KaTeX)

    func testRendererProducesNonEmptyImageForEnergyEquation() async throws {
        let rendered = await FormulaImageStore.shared.render(
            content: "E = mc^2", display: false, baseFontSize: 14
        )
        let formula = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(formula.width, 10)
        XCTAssertGreaterThan(formula.height, 8)
        XCTAssertGreaterThan(formula.image.size.width, 10)
    }

    func testRendererProducesLargerImageForDisplayFormula() async throws {
        let inlineRendered = await FormulaImageStore.shared.render(
            content: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            display: false,
            baseFontSize: 14
        )
        let displayRendered = await FormulaImageStore.shared.render(
            content: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            display: true,
            baseFontSize: 14
        )
        let inline = try XCTUnwrap(inlineRendered)
        let display = try XCTUnwrap(displayRendered)
        XCTAssertGreaterThan(display.height, inline.height)
    }

    func testRendererHandlesMixedChineseAndSymbols() async throws {
        let rendered = await FormulaImageStore.shared.render(
            content: "\\alpha + \\beta = \\gamma，\\infty",
            display: false,
            baseFontSize: 14
        )
        let formula = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(formula.width, 20)
    }

    func testRendererReturnsNilForMalformedInput() async throws {
        let malformed = try await FormulaImageStore.shared.render(
            content: "\\frac{1}{3",
            display: false,
            baseFontSize: 14
        )
        XCTAssertNil(malformed)
    }

    func testRendererImagesHaveTransparentBackground() async throws {
        let rendered = await FormulaImageStore.shared.render(
            content: "E = mc^2", display: false, baseFontSize: 14
        )
        let formula = try XCTUnwrap(rendered)
        let rep = try XCTUnwrap(formula.image.representations.first as? NSBitmapImageRep)
        let corner = rep.colorAt(x: 1, y: 1)
        XCTAssertLessThan(corner?.alphaComponent ?? 1, 0.5, "image corner must be transparent")
    }

    // MARK: - Pieces path: emphasis and links survive formulas

    func testBoldAndItalicSurviveAcrossFormula() {
        let pieces = MarkdownDocument.inlinePieces(
            "**能量公式**：$E = mc^2$，*质量能量等价*",
            mode: .completed
        )

        let boldRun = pieces.compactMap { piece -> String? in
            if case .text(let attributed) = piece,
                attributed.runs.contains(where: {
                    $0.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
                }) {
                return String(attributed.characters)
            }
            return nil
        }
        XCTAssertEqual(boldRun, ["能量公式："])
        XCTAssertEqual(
            pieces.compactMap { piece -> String? in
                if case .math(let content, _) = piece { return content }
                return nil
            },
            ["E = mc^2"]
        )
    }

    func testEmphasisSpanningFormulaStaysReadableWithoutMarkers() {
        let pieces = MarkdownDocument.inlinePieces(
            "**加粗 $x$ 加粗**",
            mode: .completed
        )
        let text = pieces.map { piece -> String in
            if case .text(let attributed) = piece { return String(attributed.characters) }
            return "<math>"
        }.joined()
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(text.contains("加粗"))
    }

    func testLinksStillRenderBesideFormulas() {
        let pieces = MarkdownDocument.inlinePieces(
            "参考 [文档](https://example.com) 与 $x^2$。",
            mode: .completed
        )
        XCTAssertTrue(
            pieces.contains { piece in
                if case .text(let attributed) = piece,
                    attributed.runs.contains(where: { $0.link != nil }) {
                    return true
                }
                return false
            }
        )
    }

    // MARK: - Tables: aligned and structured

    func testAlignedTableParsesWithColumnAlignments() throws {
        let markdown = """
        | 项目 | 数量 | 状态 |
        | :--- | ---: | :---: |
        | 发布 | 12 | 完成 |
        | 回滚 | 3 | 进行中 |
        """

        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        guard case .table(let columns) = blocks.first?.kind else {
            return XCTFail("expected a table block, got \(String(describing: blocks.first?.kind))")
        }
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns.map(\.header), ["项目", "数量", "状态"])
        XCTAssertEqual(columns.map(\.alignment), [.left, .right, .center])
        XCTAssertEqual(columns[0].cells, ["发布", "回滚"])
        XCTAssertEqual(columns[1].cells, ["12", "3"])
    }

    func testTableWithoutOuterPipesParses() {
        let markdown = """
        项目 | 数值
        --- | ---
        甲 | 1
        乙 | 2
        """

        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        guard case .table(let columns) = blocks.first?.kind else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(columns.map(\.header), ["项目", "数值"])
        XCTAssertEqual(columns[1].cells, ["1", "2"])
    }

    func testTableWithRichCellContentKeepsInlineMarkdown() {
        let markdown = """
        | 指标 | 值 |
        | --- | --- |
        | 能量 | $E = mc^2$ |
        | 倍率 | **两倍** |
        """

        let blocks = MarkdownDocument.parse(markdown, mode: .completed)
        guard case .table(let columns) = blocks.first?.kind else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(columns[0].cells, ["能量", "倍率"])
        XCTAssertEqual(columns[1].cells, ["$E = mc^2$", "**两倍**"])
    }

    func testNonTablePipeLinesRemainParagraphs() {
        let markdown = "管道符 | 不是表格"

        let blocks = MarkdownDocument.parse(markdown, mode: .completed)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    func testStreamingTableWithoutSeparatorRendersAsParagraph() {
        let markdown = "| 项目 | 数量 |\n| 发布 | 12 |"

        let blocks = MarkdownDocument.parse(markdown, mode: .streaming)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    // MARK: - Surface wiring

    func testMarkdownTextViewWiresFormulaImagesAndTables() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let renderer = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PromptMeet/Views/MarkdownTextView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(renderer.contains("inlinePieces"))
        XCTAssertTrue(renderer.contains("Image(nsImage:"))
        XCTAssertTrue(renderer.contains("FormulaImageStore"))
        XCTAssertTrue(renderer.contains("baselineOffset"))
        XCTAssertTrue(renderer.contains("case .table"))
        let document = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PromptMeet/Views/MarkdownDocument.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(document.contains("inlineSegments"))
        XCTAssertTrue(document.contains("inlinePieces"))
    }
}
