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
        let x0: CGFloat
        let y0: CGFloat  // top, y-down
        let x1: CGFloat
        let y1: CGFloat  // bottom, y-down
        var width: CGFloat { x1 - x0 }
        var height: CGFloat { y1 - y0 }
        var centerX: CGFloat { (x0 + x1) / 2 }
        var centerY: CGFloat { (y0 + y1) / 2 }
    }

    /// Renders a formula via KaTeX and returns its glyph clusters plus the
    /// baseline y-coordinate (y-down, points) and image height.
    private func render(_ source: String, display: Bool = false) async throws
        -> (clusters: [GlyphBox], baselineY: CGFloat, height: CGFloat) {
        let rendered = await FormulaImageStore.shared.render(
            content: source, display: display, baseFontSize: 14
        )
        let formula = try XCTUnwrap(rendered, "render failed for \(source)")
        let rep = try XCTUnwrap(formula.image.representations.first as? NSBitmapImageRep)
        let width = rep.pixelsWide
        let height = rep.pixelsHigh

        func isBright(_ x: Int, _ y: Int) -> Bool {
            guard let color = rep.colorAt(x: x, y: y) else { return false }
            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
            return r > 0.3 && g > 0.3 && b > 0.3
        }

        var visited = Set<Int>()
        var clusters: [GlyphBox] = []
        for y in 0..<height {
            for x in 0..<width {
                let key = y * width + x
                guard !visited.contains(key), isBright(x, y) else { continue }
                var stack = [key]
                visited.insert(key)
                var minX = x, maxX = x, minY = y, maxY = y
                while let current = stack.popLast() {
                    let cx = current % width, cy = current / width
                    for dx in -1...1 {
                        for dy in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let nkey = ny * width + nx
                            guard !visited.contains(nkey), isBright(nx, ny) else { continue }
                            visited.insert(nkey)
                            stack.append(nkey)
                            minX = min(minX, nx); maxX = max(maxX, nx)
                            minY = min(minY, ny); maxY = max(maxY, ny)
                        }
                    }
                }
                clusters.append(
                    GlyphBox(
                        x0: CGFloat(minX) / scale,
                        y0: CGFloat(minY) / scale,
                        x1: CGFloat(maxX + 1) / scale,
                        y1: CGFloat(maxY + 1) / scale
                    )
                )
            }
        }
        clusters.sort { $0.y0 < $1.y0 || ($0.y0 == $1.y0 && $0.x0 < $1.x0) }
        let baselineY = formula.height - formula.baselineShift
        return (clusters, baselineY, formula.height)
    }

    private func clustersRightOf(_ x: CGFloat, _ clusters: [GlyphBox]) -> [GlyphBox] {
        clusters.filter { $0.x0 >= x }
    }

    // MARK: - Fraction

    func testFractionRuleSitsBetweenNumeratorAndDenominator() async throws {
        let (clusters, baselineY, _) = try await render("\\frac{1}{3}")

        // The rule is the widest, thinnest component.
        let rule = try XCTUnwrap(clusters.max(by: { $0.width < $1.width }))
        XCTAssertLessThan(rule.height, 2, "rule should be a thin line")
        // The rule sits above the baseline (math axis) between the parts.
        XCTAssertLessThan(rule.centerY, baselineY, "rule must be above the baseline")

        let numerator = try XCTUnwrap(clusters.first { $0.y1 <= rule.y0 + 0.5 })
        let denominator = try XCTUnwrap(clusters.first { $0.y1 > rule.y1 + 1 })
        XCTAssertLessThan(numerator.y1, rule.y0, "numerator must be above the rule")
        XCTAssertGreaterThan(denominator.y0, rule.y1, "denominator must be below the rule")
        // The denominator hangs down to the baseline.
        XCTAssertGreaterThan(denominator.y1, baselineY - 4)
    }

    // MARK: - Superscript and subscript

    func testSuperscriptSitsAboveTheBase() async throws {
        let (clusters, _, _) = try await render("x^2")
        let base = try XCTUnwrap(clusters.first { $0.x1 <= 15 })
        let script = try XCTUnwrap(clusters.first { $0.x0 >= 15 })

        XCTAssertLessThan(script.y0, base.y0, "superscript top must be above the base top")
        XCTAssertLessThan(script.y1, base.y1, "superscript must sit above the base bottom")
    }

    func testSubscriptSitsBelowTheBaseNearTheBaseline() async throws {
        let (clusters, baselineY, _) = try await render("x_1")
        let base = try XCTUnwrap(clusters.first { $0.x1 <= 15 })
        let script = try XCTUnwrap(clusters.first { $0.x0 >= 15 })

        XCTAssertGreaterThan(script.y0, base.y0, "subscript must start below the base top")
        XCTAssertLessThan(abs(script.y1 - baselineY), 6, "subscript must sit near the baseline")
    }

    // MARK: - Integral bounds (inline style: side limits)

    func testInlineIntegralBoundsFlankTheGlyphOnTheRight() async throws {
        let (clusters, baselineY, _) = try await render("\\int_0^1")
        let glyph = try XCTUnwrap(clusters.first { $0.height > 15 })
        let bounds = clustersRightOf(glyph.x0 + 2, clusters)
        XCTAssertEqual(bounds.count, 2, "expected exactly two bound clusters")

        let upper = try XCTUnwrap(bounds.first { $0.centerY < baselineY - 8 })
        let lower = try XCTUnwrap(bounds.first { $0.centerY > baselineY - 8 })
        XCTAssertLessThan(upper.y1, lower.y0, "upper bound must be above the lower bound")
        XCTAssertLessThan(upper.y1, baselineY, "upper bound must be above the baseline")
        XCTAssertGreaterThan(lower.y1, baselineY - 2, "lower bound must reach the baseline")
    }

    func testDisplayIntegralBoundsStackAboveAndBelow() async throws {
        let (clusters, _, _) = try await render("\\int_0^1", display: true)
        let glyph = try XCTUnwrap(clusters.first { $0.height > 30 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.centerY })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.centerY })

        XCTAssertLessThan(upper.y1, lower.y0, "upper bound must be above the lower bound")
        XCTAssertLessThan(upper.centerY, glyph.centerY, "upper bound must be above the glyph center")
        XCTAssertGreaterThan(lower.centerY, glyph.centerY, "lower bound must be below the glyph center")
        XCTAssertTrue(abs(upper.centerX - glyph.centerX) < glyph.width * 1.5, "bounds must be centered")
        XCTAssertTrue(abs(lower.centerX - glyph.centerX) < glyph.width * 1.5, "bounds must be centered")
    }

    // MARK: - Sum bounds

    func testInlineSumBoundsFlankTheGlyph() async throws {
        let (clusters, baselineY, _) = try await render("\\sum_{i=1}^{n}")
        let glyph = try XCTUnwrap(clusters.first { $0.height > 15 && $0.width > 10 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.y0 + 6 })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.y1 - 4 })

        XCTAssertLessThan(upper.y0, glyph.y0 + 6, "upper bound must start above the glyph top")
        XCTAssertGreaterThan(lower.y1, baselineY - 4, "lower bound must reach the baseline")
        XCTAssertGreaterThan(lower.y0, glyph.y0, "lower bound must start below the glyph top")
    }

    func testDisplaySumBoundsStackAboveAndBelowCentered() async throws {
        let (clusters, _, _) = try await render("\\sum_{i=1}^{n}", display: true)
        let glyph = try XCTUnwrap(clusters.first { $0.height > 20 && $0.width > 10 })
        let upper = try XCTUnwrap(clusters.first { $0.centerY < glyph.y0 })
        let lower = try XCTUnwrap(clusters.first { $0.centerY > glyph.y1 })
        XCTAssertLessThan(upper.y1, glyph.y0, "upper bound must be above the glyph")
        XCTAssertGreaterThan(lower.y0, glyph.y1, "lower bound must be below the glyph")
        XCTAssertTrue(abs(upper.centerX - glyph.centerX) < glyph.width, "upper bound must be centered")
        XCTAssertTrue(abs(lower.centerX - glyph.centerX) < glyph.width, "lower bound must be centered")
    }

    // MARK: - Operator names with limits

    func testLimitBelowOperatorName() async throws {
        let (clusters, _, _) = try await render("\\lim_{x \\to 0}")
        let name = try XCTUnwrap(clusters.first { $0.x1 <= 15 })
        let limit = try XCTUnwrap(clusters.first { $0.centerY > name.centerY && $0.height > 8 })

        XCTAssertGreaterThan(limit.centerY, name.centerY, "limit must sit below the operator name")
        XCTAssertGreaterThan(limit.y1, name.y1 - 1, "limit must extend below the name")
    }

    // MARK: - Radical

    func testRadicalExtendsAboveAndBelowTheContent() async throws {
        let (clusters, baselineY, _) = try await render("\\sqrt{x^2+y^2}")
        // The radical and its content render as one connected cluster.
        let radical = try XCTUnwrap(clusters.first { $0.width > 30 })
        // The radical tip reaches well above the baseline...
        XCTAssertLessThan(radical.y0, baselineY - 15, "radical tip must reach above the content")
        // ...and the tail extends below the baseline.
        XCTAssertGreaterThan(radical.y1, baselineY, "radical tail must extend below the baseline")
    }

    // MARK: - Delimiters

    func testDelimitersExtendBeyondContent() async throws {
        let (clusters, _, _) = try await render("\\left( \\frac{a}{b} \\right)")
        let left = try XCTUnwrap(clusters.first { $0.x0 < 6 && $0.height > 15 })
        let right = try XCTUnwrap(clusters.first { $0.x1 > 20 && $0.height > 15 })
        let content = try XCTUnwrap(clusters.first { $0.x0 > 6 && $0.x1 < 26 })

        XCTAssertLessThan(left.y0, content.y0, "delimiter must extend above the content")
        XCTAssertGreaterThan(left.y1, content.y1 - 1, "delimiter must extend below the content")
        XCTAssertLessThan(right.y0, content.y0, "delimiter must extend above the content")
        XCTAssertGreaterThan(right.y1, content.y1 - 1, "delimiter must extend below the content")
    }

    // MARK: - Mixed constructs keep operator relations

    func testEnergyEquationHasLevelRelations() async throws {
        let (clusters, _, _) = try await render("E = mc^2")
        // The '=' renders as one or two thin bars; it must sit within the
        // vertical band of the letters' x-height, not at the baseline.
        let equals = try XCTUnwrap(clusters.first { $0.height < 5 && $0.width > 5 })
        let baseLetters = clusters.filter { $0.y1 > equals.centerY + 4 }
        XCTAssertFalse(baseLetters.isEmpty, "letters must extend below the '='")
        XCTAssertLessThan(equals.centerY, (baseLetters.first?.y1 ?? 0), "'=' must sit above the letter bottoms")
        // The superscript '2' is above-right of the letters.
        let superscript = try XCTUnwrap(clusters.first { $0.y0 < equals.y0 - 8 })
        XCTAssertLessThan(superscript.y1, equals.y1, "superscript must sit above the operator")
    }
}
