import CoreGraphics

struct TimelineFollowState: Equatable, Sendable {
    static let bottomTolerance: CGFloat = 48

    private(set) var isFollowing = true
    private(set) var isProgrammaticScroll = false

    mutating func contentDidChange() -> Bool {
        guard isFollowing else { return false }
        isProgrammaticScroll = true
        return true
    }

    mutating func update(bottomDistance: CGFloat) {
        if isProgrammaticScroll {
            guard bottomDistance <= Self.bottomTolerance else { return }
            isProgrammaticScroll = false
            isFollowing = true
            return
        }
        isFollowing = bottomDistance <= Self.bottomTolerance
    }

    mutating func resume() {
        isFollowing = true
        isProgrammaticScroll = true
    }

    mutating func pause() {
        isFollowing = false
        isProgrammaticScroll = false
    }

    mutating func toggleFollow() -> Bool {
        if isFollowing {
            pause()
            return false
        }
        resume()
        return true
    }
}

struct WorkspaceColumnWidths: Equatable, Sendable {
    let containerWidth: CGFloat
    let history: CGFloat
    let timeline: CGFloat
    let intelligence: CGFloat
    let dividerCount: Int

    var occupiedWidth: CGFloat {
        history + timeline + intelligence + CGFloat(dividerCount)
    }

    var remainingWidth: CGFloat {
        max(0, containerWidth - occupiedWidth)
    }
}

enum WorkspaceLayout {
    static let minimumWindowSize = CGSize(width: 980, height: 640)
    static let historyWidth: CGFloat = 176
    static let minimumTimelineWidth: CGFloat = 400
    static let maximumTimelineWidth: CGFloat = 720
    static let minimumIntelligenceWidth: CGFloat = 330
    static let actionHeight: CGFloat = 34

    static func columnWidths(
        totalWidth: CGFloat,
        showsHistory: Bool
    ) -> WorkspaceColumnWidths {
        let history = showsHistory ? historyWidth : 0
        let dividerCount = showsHistory ? 2 : 1
        let dividers = CGFloat(dividerCount)
        let available = max(0, totalWidth - history - dividers)
        let minimumContentWidth = minimumTimelineWidth + minimumIntelligenceWidth

        let timeline: CGFloat
        if available >= minimumContentWidth {
            timeline = min(
                maximumTimelineWidth,
                max(minimumTimelineWidth, available * 0.56)
            )
        } else if minimumContentWidth > 0 {
            timeline = available * minimumTimelineWidth / minimumContentWidth
        } else {
            timeline = 0
        }
        let intelligence = max(0, available - timeline)

        return WorkspaceColumnWidths(
            containerWidth: totalWidth,
            history: history,
            timeline: timeline,
            intelligence: intelligence,
            dividerCount: dividerCount
        )
    }
}
