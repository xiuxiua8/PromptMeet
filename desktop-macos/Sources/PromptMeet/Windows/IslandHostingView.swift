import AppKit
import SwiftUI

@MainActor
final class IslandHostingView: NSHostingView<IslandRootView> {
    private let store: MeetingStore

    init(rootView: IslandRootView, store: MeetingStore) {
        self.store = store
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init(rootView: IslandRootView) {
        fatalError("Use init(rootView:store:)")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let visible = IslandGeometry.interactiveRect(
            for: store.presentation,
            inHost: bounds.size,
            topChromeWidth: store.topChromeWidth,
            topChromeHeight: store.topChromeHeight
        )
        return visible.contains(point) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
