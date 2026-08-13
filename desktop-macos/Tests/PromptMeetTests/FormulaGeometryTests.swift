import AppKit
import XCTest
@testable import PromptMeet

/// Pixel-geometry regression tests for formula rendering via the bundled
/// KaTeX renderer. The captain rejected the first build because symbol
/// positions were wrong (fractions floated, integral and sum bounds were
/// misplaced, radical signs were too high); every construct below asserts
/// the standard math-typography relationships in rendered pixels, with
/// KaTeX's proven layout as the reference.
@MainActor
final class FormulaGeometryTests: XCTestCase {
    private let scale: CGFloat = 2

    // MARK: - Helpers

    private struct GlyphBox {
        let left: CGFloat
        let top: CGFloat  // top, y-down
        let right: CGFloat
        let bottom: CGFloat  // bottom, y-down
        var width: CGFloat { right - left }
        var height: CGFloat { bottom - top }
        var centerX: CGFloat { (left + right) / 2 }
        var centerY: CGFloat { (top + bottom) / 2 }
    }

    /// Rendered geometry: glyph clusters plus the baseline y-coordinate
    /// (y-down, points).
    private struct RenderResult {
        let clusters: [GlyphBox]
        let baselineY: CGFloat
    }

    private func render(_ source: String, display: Bool = false) async throws -> RenderResult {
        let rendered = await FormulaImageStore.shared.render(
            content: source, display: display, baseFontSize: 14
        )
        let formula = try XCTUnwrap(rendered, "render failed for \(source)")
        let rep = try XCTUnwrap(formula.image.representations.first as? NSBitmapImageRep)
        let clusters = detectClusters(in: rep)
        let baselineY = formula.height - formula.baselineShift
        return RenderResult(clusters: clusters, baselineY: baselineY)
    }

    /// Connected bright-pixel components of a rendered formula image.
    private func detectClusters(in rep: NSBitmapImageRep) -> [GlyphBox] {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh

        func isBright(_ column: Int, _ row: Int) -> Bool {
            guard let color = rep.colorAt(x: column, y: row) else { return false }
            let red = color.redComponent
            let green = color.greenComponent
            let blue = color.blueComponent
            return red > 0.3 && green > 0.3 && blue > 0.3
        }

        var visited = Set<Int>()
        var clusters: [GlyphBox] = []
        for row in 0..<height {
            for column in 0..<width {
                let key = row * width + column
                guard !visited.contains(key), isBright(column, row) else { continue }
                var stack = [key]
                visited.insert(key)
                var minX = column, maxX = column, minY = row, maxY = row
                while let current = stack.popLast() {
                    let currentX = current % width
                    let currentY = current / width
                    for offsetX in -1...1 {
                        for offsetY in -1...1 {
                            let neighborX = currentX + offsetX
                            let neighborY = currentY + offsetY
                            guard neighborX >= 0, neighborY >= 0,
                                neighborX < width, neighborY < height else { continue }
                            let neighborKey = neighborY * width + neighborX
                            guard !visited.contains(neighborKey), isBright(neighborX, neighborY) else { continue }
                            visited.insert(neighborKey)
                            stack.append(neighborKey)
                            minX = min(minX, neighborX); maxX = max(maxX, neighborX)
                            minY = min(minY, neighborY); maxY = max(maxY, neighborY)
                        }
                    }
                }
                clusters.append(
                    GlyphBox(
                        left: CGFloat(minX) / scale,
                        top: CGFloat(minY) / scale,
                        right: CGFloat(maxX + 1) / scale,
                        bottom: CGFloat(maxY + 1) / scale
                    )
                )
            }
        }
        return clusters.sorted { $0.top < $1.top || ($0.top == $1.top && $0.left < $1.left) }
    }

    private func clustersRightOf(_ threshold: CGFloat, _ clusters: [GlyphBox]) -> [GlyphBox] {
        clusters.filter { $0.left >= threshold }
    }

    // MARK: - Fraction

    func testFractionRuleSitsBetweenNumeratorAndDenominator() async throws {
        let result = try await render("\\frac{1}{3}")
        let clusters = result.clusters
        let baselineY = result.baselineY

        // The rule is the widest, thinnest component.
        let rule = try XCTUnwrap(clusters.max(by: { $0.width < $1.width }))
        XCTAssertLessThan(rule.height, 2, "rule should be a thin line")
        // The rule sits above the baseline (math axis) between the parts.
        XCTAssertLessThan(rule.centerY, baselineY, "rule must be above the baseline")

        let numerator = try XCTUnwrap(clusters.first { $0.bottom <= rule.top + 0.5 })
        let denominator = try XCTUnwrap(clusters.first { $0.bottom > rule.bottom + 1 })
        XCTAssertLessThan(numerator.bottom, rule.top, "numerator must be above the rule")
        XCTAssertGreaterThan(denominator.top, rule.bottom, "denominator must be below the rule")
        // The denominator hangs down to the baseline.
        XCTAssertGreaterThan(denominator.bottom, baselineY - 4)
    }

    // MARK: - Superscript and subscript

    func testSuperscriptSitsAboveTheBase() async throws {
        let result = try await render("x^2")
        let clusters = result.clusters
        _ = result.baselineY
        let base = try XCTUnwrap(clusters.first { $0.right <= 15 })
        let script = try XCTUnwrap(clusters.first { $0.left >= 15 })

        XCTAssertLessThan(script.top, base.top, "superscript top must be above the base top")
        XCTAssertLessThan(script.bottom, base.bottom, "superscript must sit above the base bottom")
    }

    func testSubscriptSitsBelowTheBaseNearTheBaseline() async throws {
        let result = try await render("x_1")
        let clusters = result.clusters
        let baselineY = result.baselineY
        let base = try XCTUnwrap(clusters.first { $0.right <= 15 })
        let script = try XCTUnwrap(clusters.first { $0.left >= 15 })

        XCTAssertGreaterThan(script.top, base.top, "subscript must start below the base top")
        XCTAssertLessThan(abs(script.bottom - baselineY), 6, "subscript must sit near the baseline")
    }

    // MARK: - Integral bounds (inline style: side limits)

    func testInlineIntegralBoundsFlankTheGlyphOnTheRight() async throws {
        let result = try await render("\\int_0^1")
        let clusters = result.clusters
        let baselineY = result.baselineY
        let glyph = try XCTUnwrap(clusters.first { $0.height > 15 })
        let bounds = clustersRightOf(glyph.left + 2, clusters)
        XCTAssertEqual(bounds.count, 2, "expected exactly two bound clusters")

        let upper = try XCTUnwrap(bounds.first { $0.centerY < baselineY - 8 })
        let lower = try XCTUnwrap(bounds.first { $0.centerY > baselineY - 8 })
        XCTAssertLessThan(upper.bottom, lower.top, "upper bound must be above the lower bound")
        XCTAssertLessThan(upper.bottom, baselineY, "upper bound must be above the baseline")
        XCTAssertGreaterThan(lower.bottom, baselineY - 2, "lower bound must reach the baseline")
    }

    func testDisplayIntegralBoundsStackAboveAndBelow() async throws {
        let result = try await render("\\int_0^1", display: true)
        let clusters = result.clusters
        _ = result.baselineY
        let glyph = try XCTUnwrap(clusters.first { $0.height > 30 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.centerY })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.centerY })

        XCTAssertLessThan(upper.bottom, lower.top, "upper bound must be above the lower bound")
        XCTAssertLessThan(upper.centerY, glyph.centerY, "upper bound must be above the glyph center")
        XCTAssertGreaterThan(lower.centerY, glyph.centerY, "lower bound must be below the glyph center")
        XCTAssertTrue(abs(upper.centerX - glyph.centerX) < glyph.width * 1.5, "bounds must be centered")
        XCTAssertTrue(abs(lower.centerX - glyph.centerX) < glyph.width * 1.5, "bounds must be centered")
    }

    // MARK: - Sum bounds

    func testInlineSumBoundsFlankTheGlyph() async throws {
        let result = try await render("\\sum_{i=1}^{n}")
        let clusters = result.clusters
        let baselineY = result.baselineY
        let glyph = try XCTUnwrap(clusters.first { $0.height > 15 && $0.width > 10 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.top + 6 })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.bottom - 4 })

        XCTAssertLessThan(upper.top, glyph.top + 6, "upper bound must start above the glyph top")
        XCTAssertGreaterThan(lower.bottom, baselineY - 4, "lower bound must reach the baseline")
        XCTAssertGreaterThan(lower.top, glyph.top, "lower bound must start below the glyph top")
    }

    func testDisplaySumBoundsStackAboveAndBelowCentered() async throws {
        let result = try await render("\\sum_{i=1}^{n}", display: true)
        let clusters = result.clusters
        _ = result.baselineY
        let glyph = try XCTUnwrap(clusters.first { $0.height > 20 && $0.width > 10 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.top })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.bottom })
        XCTAssertLessThan(upper.bottom, glyph.top, "upper bound must be above the glyph")
        XCTAssertGreaterThan(lower.top, glyph.bottom, "lower bound must be below the glyph")
        XCTAssertTrue(abs(upper.centerX - glyph.centerX) < glyph.width, "upper bound must be centered")
        XCTAssertTrue(abs(lower.centerX - glyph.centerX) < glyph.width, "lower bound must be centered")
    }

    // MARK: - Operator names with limits

    func testLimitBelowOperatorName() async throws {
        let result = try await render("\\lim_{x \\to 0}")
        let clusters = result.clusters
        _ = result.baselineY
        let name = try XCTUnwrap(clusters.first { $0.right <= 15 })
        let limit = try XCTUnwrap(clusters.first { $0.centerY > name.centerY && $0.height > 8 })

        XCTAssertGreaterThan(limit.centerY, name.centerY, "limit must sit below the operator name")
        XCTAssertGreaterThan(limit.bottom, name.bottom - 1, "limit must extend below the name")
    }

    // MARK: - Radical

    func testRadicalExtendsAboveAndBelowTheContent() async throws {
        let result = try await render("\\sqrt{x^2+y^2}")
        let clusters = result.clusters
        let baselineY = result.baselineY
        // The radical and its content render as one connected cluster.
        let radical = try XCTUnwrap(clusters.first { $0.width > 30 })
        // The radical tip reaches well above the baseline...
        XCTAssertLessThan(radical.top, baselineY - 15, "radical tip must reach above the content")
        // ...and the tail extends below the baseline.
        XCTAssertGreaterThan(radical.bottom, baselineY, "radical tail must extend below the baseline")
    }

    // MARK: - Delimiters

    func testDelimitersExtendBeyondContent() async throws {
        let result = try await render("\\left( \\frac{a}{b} \\right)")
        let clusters = result.clusters
        _ = result.baselineY
        let left = try XCTUnwrap(clusters.first { $0.left < 6 && $0.height > 15 })
        let right = try XCTUnwrap(clusters.first { $0.right > 20 && $0.height > 15 })
        let content = try XCTUnwrap(clusters.first { $0.left > 6 && $0.right < 26 })

        XCTAssertLessThan(left.top, content.top, "delimiter must extend above the content")
        XCTAssertGreaterThan(left.bottom, content.bottom - 1, "delimiter must extend below the content")
        XCTAssertLessThan(right.top, content.top, "delimiter must extend above the content")
        XCTAssertGreaterThan(right.bottom, content.bottom - 1, "delimiter must extend below the content")
    }

    // MARK: - Mixed constructs keep operator relations

    func testEnergyEquationHasLevelRelations() async throws {
        let result = try await render("E = mc^2")
        let clusters = result.clusters
        _ = result.baselineY
        // The '=' renders as one or two thin bars; it must sit within the
        // vertical band of the letters' x-height, not at the baseline.
        let equals = try XCTUnwrap(clusters.first { $0.height < 5 && $0.width > 5 })
        let baseLetters = clusters.filter { $0.bottom > equals.centerY + 4 }
        XCTAssertFalse(baseLetters.isEmpty, "letters must extend below the '='")
        XCTAssertLessThan(equals.centerY, (baseLetters.first?.bottom ?? 0), "'=' must sit above the letter bottoms")
        // The superscript '2' is above-right of the letters.
        let superscript = try XCTUnwrap(clusters.first { $0.top < equals.top - 8 })
        XCTAssertLessThan(superscript.bottom, equals.bottom, "superscript must sit above the operator")
    }
}
