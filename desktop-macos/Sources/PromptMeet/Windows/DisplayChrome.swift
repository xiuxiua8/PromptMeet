import AppKit

struct NotchInfo: Equatable {
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func detect(from screen: NSScreen?) -> NotchInfo {
        guard let screen else {
            return NotchInfo(width: 100, height: max(24, NSStatusBar.system.thickness), hasNotch: false)
        }
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            let width = leftWidth > 0 && rightWidth > 0
                ? screen.frame.width - leftWidth - rightWidth
                : 200
            return NotchInfo(width: width, height: safeTop, hasNotch: true)
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchInfo(
            width: 100,
            height: menuBarHeight > 0 ? menuBarHeight : max(24, NSStatusBar.system.thickness),
            hasNotch: false
        )
    }
}

@MainActor
enum IslandTargetScreen {
    static func current() -> NSScreen? {
        if UserDefaults.standard.string(forKey: "targetDisplay") == "跟随鼠标" {
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
