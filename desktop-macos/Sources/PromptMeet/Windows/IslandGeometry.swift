import CoreGraphics

enum IslandPresentation: Equatable {
    case idle
    case connecting
    case live
    case answering
    case hoverIdle
    case hoverLive
}

enum IslandGeometry {
    static let topInset: CGFloat = 0
    static let hostSize = CGSize(width: 1_440, height: 640)
    static let compactTabWidth: CGFloat = 38

    static func size(
        for presentation: IslandPresentation,
        topChromeWidth: CGFloat = 200,
        topChromeHeight: CGFloat = 34
    ) -> CGSize {
        let compactWidth = max(
            300,
            max(100, topChromeWidth) + compactTabWidth * 2 + IslandShape.topCurl * 2
        )
        return switch presentation {
        case .idle:
            CGSize(width: compactWidth, height: topChromeHeight)
        case .connecting:
            CGSize(width: max(compactWidth, 300), height: max(topChromeHeight, 42))
        case .live:
            CGSize(width: max(compactWidth, 520), height: max(topChromeHeight, 82))
        case .answering:
            CGSize(width: max(compactWidth, 520), height: max(topChromeHeight, 82))
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
