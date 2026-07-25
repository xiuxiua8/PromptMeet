import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSWindowController {
    init(store: MeetingStore, openSettings: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PromptMeet"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.minSize = CGSize(width: 980, height: 640)
        window.backgroundColor = NSColor(red: 0.012, green: 0.016, blue: 0.020, alpha: 1)
        window.contentView = NSHostingView(
            rootView: WorkspaceView(store: store, openSettings: openSettings)
        )
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
