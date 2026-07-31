import CoreGraphics
import Foundation

struct SubtitleTickerState: Equatable {
    private(set) var contentWidth: CGFloat = 0
    private(set) var cycleStartedAt: Date

    init(cycleStartedAt: Date = Date()) {
        self.cycleStartedAt = cycleStartedAt
    }

    mutating func updateContentWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        contentWidth = width
    }

    mutating func restartCycle(at date: Date) {
        cycleStartedAt = date
    }
}

enum SubtitleTickerMetrics {
    static let pointsPerSecond: CGFloat = 30
    static let leadingPause: TimeInterval = 1
    static let loopGap: CGFloat = 42

    static func shouldScroll(contentWidth: CGFloat, viewportWidth: CGFloat) -> Bool {
        contentWidth > viewportWidth + 1
    }

    static func offset(
        elapsed: TimeInterval,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        guard shouldScroll(contentWidth: contentWidth, viewportWidth: viewportWidth) else {
            return 0
        }
        let travel = contentWidth + loopGap
        let movingTime = max(0, elapsed - leadingPause)
        let distance = CGFloat(movingTime) * pointsPerSecond
        return -distance.truncatingRemainder(dividingBy: travel)
    }
}
