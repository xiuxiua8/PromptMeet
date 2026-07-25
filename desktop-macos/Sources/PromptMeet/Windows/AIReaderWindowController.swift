import AppKit
import SwiftUI

enum AIReaderLayout {
    static func targetSize(content: String, isStreaming: Bool) -> CGSize {
        let characterCount = content.count
        let width: CGFloat = characterCount > 600 ? 460 : (characterCount > 180 ? 420 : 380)
        let estimatedLines = max(1, Int(ceil(Double(characterCount) / 42.0)))
        let estimatedHeight = CGFloat(190 + estimatedLines * 22 + (isStreaming ? 18 : 0))
        return CGSize(width: width, height: min(620, max(240, estimatedHeight)))
    }
}

@MainActor
final class AIReaderWindowController: NSWindowController, NSWindowDelegate {
    private let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.minSize = CGSize(width: 380, height: 240)
        panel.maxSize = CGSize(width: 460, height: 620)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AIReaderView(store: store))
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func syncVisibility() {
        guard let window else { return }
        if store.state.aiReader.isVisible {
            resizeForCurrentAnswer()
            if !window.isVisible {
                restorePositionOrPlaceAtRightEdge()
                window.orderFrontRegardless()
            }
        } else {
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.hideReader()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = window.screen else { return }
        UserDefaults.standard.set(
            NSStringFromPoint(window.frame.origin),
            forKey: positionKey(for: screen)
        )
    }

    private func restorePositionOrPlaceAtRightEdge() {
        guard let window, let screen = NSScreen.main else { return }
        if let value = UserDefaults.standard.string(forKey: positionKey(for: screen)) {
            let origin = NSPointFromString(value)
            let candidate = CGRect(origin: origin, size: window.frame.size)
            if screen.visibleFrame.intersects(candidate) {
                window.setFrameOrigin(origin)
                return
            }
        }
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            CGPoint(x: visible.maxX - window.frame.width - 16, y: visible.maxY - window.frame.height - 16)
        )
    }


    private func resizeForCurrentAnswer() {
        guard let window else { return }
        let size = AIReaderLayout.targetSize(
            content: store.state.aiReader.content,
            isStreaming: store.state.aiReader.isStreaming
        )
        guard window.frame.size != size else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func positionKey(for screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "aiReaderPosition.\(screenNumber?.stringValue ?? screen.localizedName)"
    }
}
