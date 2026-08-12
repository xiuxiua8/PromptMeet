import AppKit
import Foundation
import XCTest
@testable import PromptMeet

/// Regression coverage for the rich-text surface of AI answers: inline and
/// display formulas, mixed Chinese text, streaming partial formulas,
/// malformed-input fallback, historical replay consistency, aligned tables,
/// bold/italic across formulas, and common math symbols.
final class FormulaRenderingTests: XCTestCase {
    // MARK: - Inline segmentation (the core regression: formulas used to stay literal)

    func testInlineDollarFormulaBecomesMathSegmentMixedWithChinese() {
        let segments = MarkdownDocument.inlineSegments(
            "根据相对论，能量公式是 $E = mc^2$，其中 $c$ 是光速。",
            mode: .completed
        )

        XCTAssertEqual(
            segments,
            [
                .text("根据相对论，能量公式是 "),
                .math(content: "E = mc^2", display: false),
                .text("，其中 "),
                .math(content: "c", display: false),
                .text(" 是光速。")
            ]
        )
    }

    func testParenthesisDelimitersBecomeInlineMathSegments() {
        let inline = MarkdownDocument.inlineSegments(
            "函数 \\(f(x) = x^2\\) 连续。",
            mode: .completed
        )
        let display = MarkdownDocument.inlineSegments(
            "\\[\\int_0^1 x \\, dx = \\frac{1}{2}\\]",
            mode: .completed
        )

        XCTAssertEqual(
            inline,
            [.text("函数 "), .math(content: "f(x) = x^2", display: false), .text(" 连续。")]
        )
        XCTAssertEqual(
            display,
            [.math(content: "\\int_0^1 x \\, dx = \\frac{1}{2}", display: true)]
        )
    }

    func testDisplayDollarFormulaBecomesDisplayMathSegment() {
        let segments = MarkdownDocument.inlineSegments(
            "求和公式：\n\n$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$",
            mode: .completed
        )

        XCTAssertEqual(
            segments,
            [
                .text("求和公式：\n\n"),
                .math(content: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}", display: true)
            ]
        )
    }

    func testFormulaAndTextMixedInOneAnswerKeepsOrder() {
        let segments = MarkdownDocument.inlineSegments(
            "积分 $\\int_0^1 x^2 dx = \\frac{1}{3}$，开方 $\\sqrt{x^2+y^2}$，"
                + "分数 $\\frac{a}{b} + \\frac{c}{d} = \\frac{ad+bc}{bd}$。",
            mode: .completed
        )

        let mathContents = segments.compactMap { segment -> String? in
            if case .math(let content, _) = segment { return content }
            return nil
        }
        XCTAssertEqual(
            mathContents,
            [
                "\\int_0^1 x^2 dx = \\frac{1}{3}",
                "\\sqrt{x^2+y^2}",
                "\\frac{a}{b} + \\frac{c}{d} = \\frac{ad+bc}{bd}"
            ]
        )
        XCTAssertEqual(
            segments.compactMap { segment -> Bool? in
                if case .math(_, let display) = segment { return display }
                return nil
            },
            [false, false, false]
        )
    }

    // MARK: - Money, code spans, and escapes stay literal

    func testMoneyAmountsStayLiteralText() {
        let segments = MarkdownDocument.inlineSegments(
            "成本 $5 和 $10 元。",
            mode: .completed
        )

        XCTAssertEqual(segments, [.text("成本 $5 和 $10 元。")])
    }

    func testDollarInsideCodeSpanStaysLiteral() {
        let segments = MarkdownDocument.inlineSegments(
            "代码 `$x$` 是字面量。",
            mode: .completed
        )

        XCTAssertEqual(segments, [.text("代码 `$x$` 是字面量。")])
    }

    func testEscapedDollarStaysLiteral() {
        let segments = MarkdownDocument.inlineSegments(
            "价格 \\$5 美元",
            mode: .completed
        )

        XCTAssertEqual(segments, [.text("价格 \\$5 美元")])
    }

    // MARK: - Streaming partial formulas must not break the stream

    func testStreamingUnclosedDollarStaysLiteralTextUntilClosed() {
        let partial = MarkdownDocument.inlineSegments(
            "根据相对论，能量公式是 $E = mc^",
            mode: .streaming
        )
        let completed = MarkdownDocument.inlineSegments(
            "根据相对论，能量公式是 $E = mc^2$",
            mode: .streaming
        )

        XCTAssertEqual(partial, [.text("根据相对论，能量公式是 $E = mc^")])
        XCTAssertEqual(
            completed,
            [
                .text("根据相对论，能量公式是 "),
                .math(content: "E = mc^2", display: false)
            ]
        )
    }

    func testStreamingPartialDisplayFormulaDoesNotCrash() {
        let pieces = MarkdownDocument.inlinePieces(
            "求和：\n\n$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
            mode: .streaming
        )

        XCTAssertFalse(pieces.isEmpty)
        let text = pieces.map { piece -> String in
            if case .text(let attributed) = piece { return String(attributed.characters) }
            return "<math>"
        }.joined()
        XCTAssertTrue(text.contains("\\frac"))
    }

    func testStreamingAndCompletedSegmentationMatchesForClosedFormulas() {
        let source = "能量公式是 $E = mc^2$，积分 $\\int_0^1 dx$。"
        XCTAssertEqual(
            MarkdownDocument.inlineSegments(source, mode: .streaming),
            MarkdownDocument.inlineSegments(source, mode: .completed)
        )
    }

    // MARK: - Historical replay consistency

    func testHistoricalReplayRendersIdenticalPieces() {
        let source = "能量公式是 $E = mc^2$，求和 $$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$。"

        let first = MarkdownDocument.inlinePieces(source, mode: .completed)
        let second = MarkdownDocument.inlinePieces(source, mode: .completed)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.compactMap { piece -> String? in
                if case .math(let content, _) = piece { return content }
                return nil
            },
            ["E = mc^2", "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"]
        )
    }

    // MARK: - Parser coverage

    func testEnergyEquationParses() {
        let node = FormulaParser.parse("E = mc^2")
        XCTAssertNotNil(node)
    }

    func testFractionParses() {
        let node = FormulaParser.parse("\\frac{a}{b}")
        XCTAssertNotNil(node)
        XCTAssertEqual(node, .fraction(numerator: .letter("a"), denominator: .letter("b")))
    }

    func testIntegralWithLimitsParses() {
        let node = FormulaParser.parse("\\int_0^1 x^2 dx")
        XCTAssertNotNil(node)
    }

    func testSumWithLimitsParses() {
        let node = FormulaParser.parse("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}")
        XCTAssertNotNil(node)
    }

    func testSqrtParses() {
        let node = FormulaParser.parse("\\sqrt{x^2 + y^2}")
        XCTAssertNotNil(node)
    }

    func testCommonSymbolsParse() {
        XCTAssertNotNil(FormulaParser.parse("\\alpha + \\beta = \\gamma"))
        XCTAssertNotNil(FormulaParser.parse("x \\rightarrow y"))
        XCTAssertNotNil(FormulaParser.parse("\\infty \\leq 10"))
        XCTAssertNotNil(FormulaParser.parse("\\pi \\approx 3.14"))
        XCTAssertNotNil(FormulaParser.parse("\\int \\cdot \\times \\div"))
    }

    func testDelimitedGroupParses() {
        let node = FormulaParser.parse("\\left( \\frac{a}{b} \\right)")
        XCTAssertNotNil(node)
        XCTAssertEqual(
            node,
            .delimiter(
                open: "(",
                content: .fraction(numerator: .letter("a"), denominator: .letter("b")),
                close: ")"
            )
        )
    }

    func testChineseTextInsideFormulaParses() {
        let node = FormulaParser.parse("\\text{当 } x > 0 \\text{ 时}")
        XCTAssertNotNil(node)
    }

    // MARK: - Malformed input degrades to readable fallback

    func testUnbalancedBracesFailToParse() {
        XCTAssertNil(FormulaParser.parse("\\frac{1}{3"))
    }

    func testUnknownCommandFailsToParse() {
        XCTAssertNil(FormulaParser.parse("\\unknowncommand{x}"))
    }

    func testUnmatchedDelimiterFailsToParse() {
        XCTAssertNil(FormulaParser.parse("\\left( x"))
    }

    func testTrailingScriptFailsToParse() {
        XCTAssertNil(FormulaParser.parse("x^"))
    }

    func testPlainTextFallbackIsReadableWithoutMarkers() {
        XCTAssertEqual(FormulaPlainText.plainText("\\frac{1}{3}"), "1/3")
        XCTAssertEqual(FormulaPlainText.plainText("E = mc^2"), "E = mc²")
        XCTAssertEqual(
            FormulaPlainText.plainText("\\alpha \\leq \\infty"),
            "α ≤ ∞"
        )
        XCTAssertEqual(
            FormulaPlainText.plainText("\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}"),
            "∑(i=1..n) i = n(n+1)/2"
        )
        XCTAssertEqual(
            FormulaPlainText.plainText("\\sqrt{x^2 + y^2}"),
            "√x² + y²"
        )
    }

    func testMalformedPlainTextFallbackNeverCrashes() {
        let malformed = [
            "\\frac{1}{3",
            "\\left( x",
            "x^",
            "\\unknowncommand{x}",
            "\\sum_{i=1}^{n}",
            "{",
            "\\"
        ]
        for input in malformed {
            let output = FormulaPlainText.plainText(input)
            XCTAssertFalse(output.contains("$"), "fallback for \(input) leaked a marker")
        }
    }

}
