import SwiftUI

// Adapted from agent-island's MIT-licensed IslandShape.
// See desktop-macos/THIRD_PARTY_NOTICES.md.
struct IslandShape: InsettableShape {
    var inset: CGFloat = 0

    static let topCurl: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: inset, dy: inset)
        guard bounds.width > 0, bounds.height > 0 else { return Path() }

        let curl = min(Self.topCurl, bounds.width / 4, bounds.height / 2)
        let preferredRadius = max(14, bounds.height * 0.12)
        let radius = min(26, preferredRadius, bounds.width / 2 - curl, bounds.height - curl)
        var path = Path()

        path.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - curl, y: bounds.minY + curl),
            control: CGPoint(x: bounds.maxX - curl, y: bounds.minY)
        )
        path.addLine(to: CGPoint(x: bounds.maxX - curl, y: bounds.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - curl - radius, y: bounds.maxY),
            control: CGPoint(x: bounds.maxX - curl, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX + curl + radius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX + curl, y: bounds.maxY - radius),
            control: CGPoint(x: bounds.minX + curl, y: bounds.maxY)
        )
        path.addLine(to: CGPoint(x: bounds.minX + curl, y: bounds.minY + curl))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: bounds.minY),
            control: CGPoint(x: bounds.minX + curl, y: bounds.minY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
