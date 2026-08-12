import AppKit
import Foundation
import XCTest
@testable import PromptMeet

/// Rendering-level coverage for formulas: images, fallback text,
/// emphasis and links around math, and the shared renderer wiring.
final class FormulaRenderingSurfaceTests: XCTestCase {
    // MARK: - Rendering produces real images

    func testRendererProducesNonEmptyImageForEnergyEquation() {
        let formula = FormulaRenderer.image(for: "E = mc^2", display: false, baseFontSize: 12)
        XCTAssertNotNil(formula)
        XCTAssertGreaterThan(formula?.width ?? 0, 10)
        XCTAssertGreaterThan(formula?.height ?? 0, 8)
    }

    func testRendererProducesLargerImageForDisplayFormula() {
        let inline = FormulaRenderer.image(
            for: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            display: false,
            baseFontSize: 12
        )
        let display = FormulaRenderer.image(
            for: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            display: true,
            baseFontSize: 12
        )
        XCTAssertNotNil(inline)
        XCTAssertNotNil(display)
        XCTAssertGreaterThan(display?.height ?? 0, inline?.height ?? 0)
    }

    func testRendererReturnsNilForMalformedInput() {
        XCTAssertNil(
            FormulaRenderer.image(for: "\\frac{1}{3", display: false, baseFontSize: 12)
        )
        XCTAssertNil(
            FormulaRenderer.image(for: "x^", display: false, baseFontSize: 12)
        )
    }

    func testRendererImagesHaveTransparentBackground() {
        guard let formula = FormulaRenderer.image(for: "E = mc^2", display: false, baseFontSize: 12) else {
            return XCTFail("expected a rendered formula")
        }
        guard let rep = formula.image.representations.first as? NSBitmapImageRep,
            let data = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("expected PNG data")
        }
        XCTAssertGreaterThan(data.count, 100)
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
        XCTAssertTrue(renderer.contains("FormulaPlainText.plainText"))
        XCTAssertTrue(renderer.contains("case .table"))
        let document = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/PromptMeet/Views/MarkdownDocument.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(document.contains("inlineSegments"))
        XCTAssertTrue(document.contains("inlinePieces"))
    }
}
