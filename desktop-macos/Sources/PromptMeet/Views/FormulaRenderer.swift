import AppKit
import CoreText
import Foundation

/// A rendered formula image plus the amount its baseline sits above the
/// image's bottom edge. The view shifts the image down by `baselineShift`
/// so the formula baseline aligns with the surrounding text baseline.
struct FormulaImage: Equatable {
    let image: NSImage
    let baselineShift: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// Renders parsed formulas to transparent NSImages via CoreText. Pure layout
/// against a fixed dark visual system: glyphs are drawn in a near-white color
/// that matches the workspace answer text.
enum FormulaRenderer {
    static let pixelScale: CGFloat = 2

    /// Parses `content` and renders it. Returns nil when the source is
    /// unsupported or malformed so callers can fall back to plain text.
    static func image(
        for content: String,
        display: Bool,
        baseFontSize: CGFloat,
        color: NSColor = NSColor(calibratedWhite: 0.96, alpha: 1)
    ) -> FormulaImage? {
        guard let node = FormulaParser.parse(content) else { return nil }
        let size = display ? baseFontSize * 1.35 : baseFontSize
        let layout = FormulaLayout(baseSize: size, color: color)
        guard let box = layout.box(for: node) else { return nil }
        let width = max(1, box.width)
        let height = max(1, box.ascent + box.descent)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(width * pixelScale)),
            pixelsHigh: Int(ceil(height * pixelScale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        let context = graphicsContext.cgContext
        context.saveGState()
        context.scaleBy(x: pixelScale, y: pixelScale)
        // Baseline sits `descent` above the image bottom so descenders fit.
        layout.draw(node, in: DrawContext(context: context, xPosition: 0, baselineY: box.descent))
        context.restoreGState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return FormulaImage(
            image: image,
            baselineShift: box.descent,
            width: width,
            height: height
        )
    }
}

/// Drawing position and target for one formula render pass.
struct DrawContext {
    let context: CGContext
    let xPosition: CGFloat
    let baselineY: CGFloat
}

/// Layout metrics for parsed formulas. All geometry is measured in points
/// with y-up coordinates from each node's baseline.
struct FormulaLayout {
    var baseSize: CGFloat
    let color: NSColor

    struct Box {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// CoreText line metrics for a glyph run.
    func runMetrics(_ string: String, font: NSFont) -> Box {
        let attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Box(width: max(0, CGFloat(width)), ascent: ascent, descent: descent)
    }

    /// Serif math font with good Greek and operator glyph coverage.
    /// Times New Roman ships with macOS; CoreText cascade covers any missing glyph.
    func font(size: CGFloat, italic: Bool = false) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if italic { traits.insert(.italic) }
        let descriptor = NSFontDescriptor(name: "TimesNewRomanPSMT", size: size)
            .withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    func box(for node: FormulaNode) -> Box? {
        switch node {
        case .text(let string):
            return runMetrics(string, font: font(size: baseSize))
        case .letter(let string):
            return runMetrics(string, font: font(size: baseSize, italic: true))
        case .symbol(let string):
            return runMetrics(string, font: font(size: baseSize))
        case .space(let width):
            return Box(width: max(0, width * baseSize), ascent: 0, descent: 0)
        case .mathOperator(let name, let lower, let upper):
            return opBox(name: name, lower: lower, upper: upper)
        case .script(let base, let lower, let upper):
            return scriptBox(base: base, lower: lower, upper: upper)
        case .fraction(let numerator, let denominator):
            return fractionBox(numerator: numerator, denominator: denominator)
        case .radical(let base, let degree):
            return radicalBox(base: base, _: degree)
        case .accent(let base, let mark):
            return accentBox(base: base, mark: mark)
        case .delimiter(let open, let content, let close):
            return delimiterBox(open: open, content: content, close: close)
        case .sequence(let nodes):
            var width: CGFloat = 0
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            for child in nodes {
                guard let childBox = box(for: child) else { return nil }
                width += childBox.width
                ascent = max(ascent, childBox.ascent)
                descent = max(descent, childBox.descent)
            }
            return Box(width: width, ascent: ascent, descent: descent)
        }
    }

    private func opBox(name: String, lower: FormulaNode?, upper: FormulaNode?) -> Box? {
        let isLargeOperator = name.count == 1
        let opFontSize = isLargeOperator ? baseSize * 1.55 : baseSize
        let opFont = font(size: opFontSize, italic: !isLargeOperator)
        let opBox = runMetrics(name, font: opFont)

        var width = opBox.width
        var ascent = opBox.ascent
        var descent = opBox.descent

        if let lower {
            guard let lowerBox = box(for: lower) else { return nil }
            let gap = baseSize * 0.08
            let lowerBaseline = -(opBox.descent + gap + lowerBox.descent)
            width += gap + lowerBox.width
            descent = max(descent, -lowerBaseline + lowerBox.descent)
        }
        if let upper {
            guard let upperBox = box(for: upper) else { return nil }
            let gap = baseSize * 0.08
            let upperBaseline = opBox.ascent + gap + upperBox.descent
            width += gap + upperBox.width
            ascent = max(ascent, upperBaseline + upperBox.ascent)
        }
        return Box(width: width, ascent: ascent, descent: descent)
    }

    private func scriptBox(base: FormulaNode, lower: FormulaNode?, upper: FormulaNode?) -> Box? {
        guard let baseBox = box(for: base) else { return nil }
        let scriptSize = max(6, baseSize * 0.72)
        let gap = baseSize * 0.06
        var width = baseBox.width
        var ascent = baseBox.ascent
        var descent = baseBox.descent

        if let lower {
            var lowerLayout = self
            lowerLayout.baseSize = scriptSize
            guard let lowerBox = lowerLayout.box(for: lower) else { return nil }
            let lowerBaseline = -(baseSize * 0.24)
            width += gap + lowerBox.width
            descent = max(descent, -lowerBaseline + lowerBox.descent)
        }
        if let upper {
            var upperLayout = self
            upperLayout.baseSize = scriptSize
            guard let upperBox = upperLayout.box(for: upper) else { return nil }
            let upperBaseline = baseBox.ascent * 0.52
            width += gap + upperBox.width
            ascent = max(ascent, upperBaseline + upperBox.ascent)
        }
        return Box(width: width, ascent: ascent, descent: descent)
    }

    private func fractionBox(numerator: FormulaNode, denominator: FormulaNode) -> Box? {
        guard let numeratorBox = box(for: numerator),
            let denominatorBox = box(for: denominator) else { return nil }
        let padding = baseSize * 0.18
        let ruleThickness = baseSize * 0.07
        let gap = baseSize * 0.13
        let width = max(numeratorBox.width, denominatorBox.width) + padding * 2
        let totalHeight = numeratorBox.ascent + numeratorBox.descent
            + gap + ruleThickness + gap
            + denominatorBox.ascent + denominatorBox.descent
        let half = totalHeight / 2
        return Box(width: width, ascent: half, descent: half)
    }

    private func radicalBox(base: FormulaNode, _ degree: FormulaNode?) -> Box? {
        guard let baseBox = box(for: base) else { return nil }
        let contentHeight = baseBox.ascent + baseBox.descent
        let radicalSize = max(8, contentHeight * 1.15)
        let radicalBox = runMetrics("√", font: font(size: radicalSize))
        let overlineGap = baseSize * 0.14
        let overlineThickness = baseSize * 0.07
        let gap = baseSize * 0.10

        let contentTop = baseBox.ascent + overlineGap + overlineThickness / 2
        let radicalBaseline = contentTop - radicalBox.ascent * 0.55
        let width = radicalBox.width + gap + baseBox.width
        let ascent = max(contentTop + overlineThickness / 2, radicalBaseline + radicalBox.ascent)
        let descent = max(baseBox.descent, radicalBaseline - radicalBox.descent)
        return Box(width: width, ascent: ascent, descent: descent)
    }

    private func accentBox(base: FormulaNode, mark: String) -> Box? {
        guard let baseBox = box(for: base) else { return nil }
        let markBox = runMetrics(mark, font: font(size: baseSize))
        let gap = baseSize * 0.10
        let ascent = baseBox.ascent + gap + markBox.ascent
        let width = max(baseBox.width, markBox.width)
        return Box(width: width, ascent: ascent, descent: baseBox.descent)
    }

    private func delimiterBox(open: String, content: FormulaNode, close: String) -> Box? {
        guard let contentBox = box(for: content) else { return nil }
        let contentHeight = contentBox.ascent + contentBox.descent
        let parenFontSize = max(8, contentHeight * 0.92)
        let parenFont = font(size: parenFontSize)
        let openBox = open.isEmpty
            ? Box(width: 0, ascent: 0, descent: 0)
            : runMetrics(open, font: parenFont)
        let closeBox = close.isEmpty
            ? Box(width: 0, ascent: 0, descent: 0)
            : runMetrics(close, font: parenFont)
        let shift = ((contentBox.ascent - contentBox.descent) - (openBox.ascent - openBox.descent)) / 2
        let width = openBox.width + contentBox.width + closeBox.width
        let ascent = max(contentBox.ascent, shift + openBox.ascent)
        let descent = max(contentBox.descent, -(shift - openBox.descent))
        return Box(width: width, ascent: ascent, descent: descent)
    }
}
