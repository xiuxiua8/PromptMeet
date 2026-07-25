import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSWindowController {
    init(store: MeetingStore, openSettings: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PromptMeet"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.035, green: 0.038, blue: 0.045, alpha: 1)
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
