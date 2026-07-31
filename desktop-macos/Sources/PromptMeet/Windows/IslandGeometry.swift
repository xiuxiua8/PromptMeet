import CoreGraphics

enum IslandPresentation: Equatable {
    case idle
    case connecting
    case live
    case answering
    case hoverIdle
    case hoverLive
}

struct IslandControlAnchors: Equatable {
    let workspace: CGPoint
    let pauseResume: CGPoint
    let quickAsk: CGPoint
}

struct IslandControlHitRects: Equatable {
    let workspace: CGRect
    let pauseResume: CGRect
    let quickAsk: CGRect
}

enum IslandGeometry {
    static let topInset: CGFloat = 0
    static let hostSize = CGSize(width: 1_440, height: 640)
    static let controlRailWidth: CGFloat = 460
    static let controlHitSize: CGFloat = 32
    static let controlInset: CGFloat = 22
    static let controlSpacing: CGFloat = 4

    static func size(
        for presentation: IslandPresentation,
        topChromeWidth: CGFloat = 200,
        topChromeHeight: CGFloat = 34
    ) -> CGSize {
        let effectiveTopChromeHeight = max(controlHitSize, topChromeHeight)
        let compactWidth = max(
            controlRailWidth,
            max(100, topChromeWidth) + controlHitSize * 3 + controlInset * 2
        )
        return switch presentation {
        case .idle:
            CGSize(width: compactWidth, height: effectiveTopChromeHeight)
        case .connecting:
            CGSize(width: compactWidth, height: max(effectiveTopChromeHeight, 42))
        case .live:
            CGSize(width: compactWidth, height: max(effectiveTopChromeHeight, 54))
        case .answering:
            CGSize(width: compactWidth, height: max(effectiveTopChromeHeight, 54))
        case .hoverIdle:
            CGSize(width: 760, height: 300)
        case .hoverLive:
            CGSize(width: 760, height: 300)
        }
    }

    static func frame(for presentation: IslandPresentation, in screen: CGRect) -> CGRect {
        let size = size(for: presentation)
        return CGRect(
            x: screen.midX - size.width / 2,
            y: screen.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func visibleRect(
        for presentation: IslandPresentation,
        inHost hostSize: CGSize,
        topChromeWidth: CGFloat = 200,
        topChromeHeight: CGFloat = 34
    ) -> CGRect {
        let islandSize = size(
            for: presentation,
            topChromeWidth: topChromeWidth,
            topChromeHeight: topChromeHeight
        )
        return CGRect(
            x: hostSize.width / 2 - islandSize.width / 2,
            y: hostSize.height - islandSize.height,
            width: islandSize.width,
            height: islandSize.height
        )
    }

    static func interactiveRect(
        for presentation: IslandPresentation,
        inHost hostSize: CGSize,
        topChromeWidth: CGFloat = 200,
        topChromeHeight: CGFloat = 34
    ) -> CGRect {
        visibleRect(
            for: presentation,
            inHost: hostSize,
            topChromeWidth: topChromeWidth,
            topChromeHeight: topChromeHeight
        )
    }

    static func controlAnchors(
        inHost hostSize: CGSize,
        topChromeHeight: CGFloat = 34
    ) -> IslandControlAnchors {
        let centerX = hostSize.width / 2
        let centerY = hostSize.height - max(controlHitSize, topChromeHeight) / 2
        let halfHitSize = controlHitSize / 2
        let workspaceX = centerX - controlRailWidth / 2 + controlInset + halfHitSize
        let quickAskX = centerX + controlRailWidth / 2 - controlInset - halfHitSize
        let pauseResumeX = quickAskX - controlHitSize - controlSpacing
        return IslandControlAnchors(
            workspace: CGPoint(x: workspaceX, y: centerY),
            pauseResume: CGPoint(x: pauseResumeX, y: centerY),
            quickAsk: CGPoint(x: quickAskX, y: centerY)
        )
    }

    static func controlAnchors(
        for presentation: IslandPresentation,
        inHost hostSize: CGSize,
        topChromeHeight: CGFloat = 34
    ) -> IslandControlAnchors {
        _ = presentation
        return controlAnchors(inHost: hostSize, topChromeHeight: topChromeHeight)
    }

    static func controlHitRects(
        inHost hostSize: CGSize,
        topChromeHeight: CGFloat = 34
    ) -> IslandControlHitRects {
        let anchors = controlAnchors(inHost: hostSize, topChromeHeight: topChromeHeight)
        return IslandControlHitRects(
            workspace: hitRect(center: anchors.workspace),
            pauseResume: hitRect(center: anchors.pauseResume),
            quickAsk: hitRect(center: anchors.quickAsk)
        )
    }

    static func controlHitRects(
        for presentation: IslandPresentation,
        inHost hostSize: CGSize,
        topChromeHeight: CGFloat = 34
    ) -> IslandControlHitRects {
        _ = presentation
        return controlHitRects(inHost: hostSize, topChromeHeight: topChromeHeight)
    }

    private static func hitRect(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - controlHitSize / 2,
            y: center.y - controlHitSize / 2,
            width: controlHitSize,
            height: controlHitSize
        )
    }

    static func hostFrame(in screen: CGRect) -> CGRect {
        let width = min(hostSize.width, screen.width)
        let height = min(hostSize.height, screen.height)
        return CGRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height,
            width: width,
            height: height
        )
    }
}
