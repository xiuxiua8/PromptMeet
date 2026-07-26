import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private let onAIConfigurationChanged: () -> Void

    init(onAIConfigurationChanged: @escaping () -> Void = {}) {
        self.onAIConfigurationChanged = onAIConfigurationChanged
    }

    func show() {
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            created.title = "PromptMeet 设置"
            created.contentViewController = NSHostingController(
                rootView: PromptMeetSettingsView(
                    onAIConfigurationChanged: onAIConfigurationChanged
                )
            )
            created.isReleasedWhenClosed = false
            created.titlebarAppearsTransparent = true
            created.delegate = self
            created.center()
            self.window = created
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
