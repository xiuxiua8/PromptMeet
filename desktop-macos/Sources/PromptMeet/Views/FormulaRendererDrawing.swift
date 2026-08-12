import AppKit
import CoreText
import Foundation

/// Drawing pass for parsed formulas: every node renders glyph runs and
/// simple shapes (fraction rules, radical overlines) into a CGContext.
extension FormulaLayout {
    func draw(_ node: FormulaNode, in drawContext: DrawContext) {
        switch node {
        case .text(let string):
            drawRun(string, font: font(size: baseSize), in: drawContext)
        case .letter(let string):
            drawRun(string, font: font(size: baseSize, italic: true), in: drawContext)
        case .symbol(let string):
            drawRun(string, font: font(size: baseSize), in: drawContext)
        case .space:
            break
        case .mathOperator(let name, let lower, let upper):
            drawOperator(name: name, lower: lower, upper: upper, in: drawContext)
        case .script(let base, let lower, let upper):
            drawScript(base: base, lower: lower, upper: upper, in: drawContext)
        case .fraction(let numerator, let denominator):
            drawFraction(numerator: numerator, denominator: denominator, in: drawContext)
        case .radical(let base, let degree):
            drawRadical(base: base, degree: degree, in: drawContext)
        case .accent(let base, let mark):
            drawAccent(base: base, mark: mark, in: drawContext)
        case .delimiter(let open, let content, let close):
            drawDelimiter(open: open, content: content, close: close, in: drawContext)
        case .sequence(let nodes):
            var cursorX = drawContext.xPosition
            for child in nodes {
                guard let childBox = box(for: child) else { continue }
                draw(
                    child,
                    in: DrawContext(
                        context: drawContext.context,
                        xPosition: cursorX,
                        baselineY: drawContext.baselineY
                    )
                )
                cursorX += childBox.width
            }
        }
    }

    private func drawRun(_ string: String, font: NSFont, in drawContext: DrawContext) {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        drawContext.context.textPosition = CGPoint(x: drawContext.xPosition, y: drawContext.baselineY)
        CTLineDraw(line, drawContext.context)
    }

    private func drawOperator(
        name: String,
        lower: FormulaNode?,
        upper: FormulaNode?,
        in drawContext: DrawContext
    ) {
        let isLargeOperator = name.count == 1
        let opFontSize = isLargeOperator ? baseSize * 1.55 : baseSize
        let opFont = font(size: opFontSize, italic: !isLargeOperator)
        let opBox = runMetrics(name, font: opFont)
        drawRun(name, font: opFont, in: drawContext)
        var cursorX = drawContext.xPosition + opBox.width
        let scriptSize = max(6, baseSize * 0.72)
        let gap = baseSize * 0.08
        if let lower {
            guard let lowerBox = box(for: lower) else { return }
            let lowerBaseline = -(opBox.descent + gap + lowerBox.descent)
            var lowerLayout = self
            lowerLayout.baseSize = scriptSize
            lowerLayout.draw(
                lower,
                in: DrawContext(
                    context: drawContext.context,
                    xPosition: cursorX,
                    baselineY: drawContext.baselineY + lowerBaseline
                )
            )
            cursorX += gap + lowerBox.width
        }
        if let upper {
            guard let upperBox = box(for: upper) else { return }
            let upperBaseline = opBox.ascent + gap + upperBox.descent
            var upperLayout = self
            upperLayout.baseSize = scriptSize
            upperLayout.draw(
                upper,
                in: DrawContext(
                    context: drawContext.context,
                    xPosition: cursorX,
                    baselineY: drawContext.baselineY + upperBaseline
                )
            )
        }
    }

    private func drawScript(
        base: FormulaNode,
        lower: FormulaNode?,
        upper: FormulaNode?,
        in drawContext: DrawContext
    ) {
        guard let baseBox = box(for: base) else { return }
        draw(base, in: drawContext)
        let scriptSize = max(6, baseSize * 0.72)
        let gap = baseSize * 0.06
        var cursorX = drawContext.xPosition + baseBox.width
        if let lower {
            var lowerLayout = self
            lowerLayout.baseSize = scriptSize
            guard let lowerBox = lowerLayout.box(for: lower) else { return }
            let lowerBaseline = -(baseSize * 0.24)
            lowerLayout.draw(
                lower,
                in: DrawContext(
                    context: drawContext.context,
                    xPosition: cursorX,
                    baselineY: drawContext.baselineY + lowerBaseline
                )
            )
            cursorX += gap + lowerBox.width
        }
        if let upper {
            var upperLayout = self
            upperLayout.baseSize = scriptSize
            guard upperLayout.box(for: upper) != nil else { return }
            let upperBaseline = baseBox.ascent * 0.52
            upperLayout.draw(
                upper,
                in: DrawContext(
                    context: drawContext.context,
                    xPosition: cursorX,
                    baselineY: drawContext.baselineY + upperBaseline
                )
            )
        }
    }

    private func drawFraction(
        numerator: FormulaNode,
        denominator: FormulaNode,
        in drawContext: DrawContext
    ) {
        guard let numeratorBox = box(for: numerator),
            let denominatorBox = box(for: denominator) else { return }
        let padding = baseSize * 0.18
        let ruleThickness = baseSize * 0.07
        let gap = baseSize * 0.13
        let width = max(numeratorBox.width, denominatorBox.width) + padding * 2
        let totalHeight = numeratorBox.ascent + numeratorBox.descent
            + gap + ruleThickness + gap
            + denominatorBox.ascent + denominatorBox.descent
        let half = totalHeight / 2
        let numeratorBaseline = drawContext.baselineY + half - numeratorBox.ascent
        let denominatorBaseline = numeratorBaseline
            - numeratorBox.descent - gap - ruleThickness - gap

        draw(
            numerator,
            in: DrawContext(
                context: drawContext.context,
                xPosition: drawContext.xPosition + (width - numeratorBox.width) / 2,
                baselineY: numeratorBaseline
            )
        )
        draw(
            denominator,
            in: DrawContext(
                context: drawContext.context,
                xPosition: drawContext.xPosition + (width - denominatorBox.width) / 2,
                baselineY: denominatorBaseline
            )
        )

        let ruleY = denominatorBaseline + denominatorBox.ascent + gap + ruleThickness / 2
        drawContext.context.saveGState()
        drawContext.context.setFillColor(color.cgColor)
        drawContext.context.fill(
            CGRect(
                x: drawContext.xPosition,
                y: ruleY - ruleThickness / 2,
                width: width,
                height: ruleThickness
            )
        )
        drawContext.context.restoreGState()
    }

    private func drawRadical(
        base: FormulaNode,
        degree: FormulaNode?,
        in drawContext: DrawContext
    ) {
        guard let baseBox = box(for: base) else { return }
        let contentHeight = baseBox.ascent + baseBox.descent
        let radicalSize = max(8, contentHeight * 1.15)
        let radicalBox = runMetrics("√", font: font(size: radicalSize))
        let overlineGap = baseSize * 0.14
        let overlineThickness = baseSize * 0.07
        let gap = baseSize * 0.10

        let contentTop = baseBox.ascent + overlineGap + overlineThickness / 2
        let radicalBaseline = drawContext.baselineY + contentTop - radicalBox.ascent * 0.55
        drawRun("√", font: font(size: radicalSize), in: DrawContext(
            context: drawContext.context,
            xPosition: drawContext.xPosition,
            baselineY: radicalBaseline
        ))

        if let degree {
            var degreeLayout = self
            degreeLayout.baseSize = max(6, baseSize * 0.6)
            if let degreeBox = degreeLayout.box(for: degree) {
                degreeLayout.draw(
                    degree,
                    in: DrawContext(
                        context: drawContext.context,
                        xPosition: drawContext.xPosition + max(0, radicalBox.width * 0.2 - degreeBox.width),
                        baselineY: radicalBaseline + radicalBox.ascent - degreeBox.ascent
                    )
                )
            }
        }

        let contentX = drawContext.xPosition + radicalBox.width + gap
        draw(base, in: DrawContext(
            context: drawContext.context,
            xPosition: contentX,
            baselineY: drawContext.baselineY
        ))
        let overlineY = drawContext.baselineY + baseBox.ascent + overlineGap + overlineThickness / 2
        drawContext.context.saveGState()
        drawContext.context.setFillColor(color.cgColor)
        drawContext.context.fill(
            CGRect(
                x: contentX,
                y: overlineY - overlineThickness / 2,
                width: baseBox.width,
                height: overlineThickness
            )
        )
        drawContext.context.restoreGState()
    }

    private func drawAccent(base: FormulaNode, mark: String, in drawContext: DrawContext) {
        guard let baseBox = box(for: base) else { return }
        draw(base, in: drawContext)
        let markBox = runMetrics(mark, font: font(size: baseSize))
        let gap = baseSize * 0.10
        drawRun(
            mark,
            font: font(size: baseSize),
            in: DrawContext(
                context: drawContext.context,
                xPosition: drawContext.xPosition + (baseBox.width - markBox.width) / 2,
                baselineY: drawContext.baselineY + baseBox.ascent + gap + markBox.ascent
            )
        )
    }

    private func drawDelimiter(
        open: String,
        content: FormulaNode,
        close: String,
        in drawContext: DrawContext
    ) {
        guard let contentBox = box(for: content) else { return }
        let contentHeight = contentBox.ascent + contentBox.descent
        let parenFontSize = max(8, contentHeight * 0.92)
        let parenFont = font(size: parenFontSize)
        let openBox = open.isEmpty
            ? Box(width: 0, ascent: 0, descent: 0)
            : runMetrics(open, font: parenFont)
        let shift = ((contentBox.ascent - contentBox.descent) - (openBox.ascent - openBox.descent)) / 2

        if !open.isEmpty {
            drawRun(open, font: parenFont, in: DrawContext(
                context: drawContext.context,
                xPosition: drawContext.xPosition,
                baselineY: drawContext.baselineY + shift
            ))
        }
        draw(content, in: DrawContext(
            context: drawContext.context,
            xPosition: drawContext.xPosition + openBox.width,
            baselineY: drawContext.baselineY
        ))
        if !close.isEmpty {
            drawRun(close, font: parenFont, in: DrawContext(
                context: drawContext.context,
                xPosition: drawContext.xPosition + openBox.width + contentBox.width,
                baselineY: drawContext.baselineY + shift
            ))
        }
    }
}
