import AppKit
import SwiftUI

final class AIReaderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum AIReaderLayout {
    static let minimumSize = CGSize(width: 380, height: 240)
    static let maximumSize = CGSize(width: 460, height: 620)

    static func targetSize(
        content: String,
        title: String = "",
        isStreaming: Bool
    ) -> CGSize {
        let characterCount = content.count
        let width: CGFloat = characterCount > 600 ? 460 : (characterCount > 220 ? 420 : 380)
        let measuredContent = content.isEmpty ? "正在思考" : content
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let textRect = (measuredContent as NSString).boundingRect(
            with: CGSize(width: width - 44, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont],
            context: nil
        )
        let lineHeight = max(1, bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let lineCount = max(1, ceil(textRect.height / lineHeight))
        let bodyHeight = max(42, ceil(textRect.height) + max(0, lineCount - 1) * 6)
        let titleRect = (title as NSString).boundingRect(
            with: CGSize(width: width - 132, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)],
            context: nil
        )
        let extraTitleHeight = max(0, ceil(titleRect.height) - 22)
        let chromeHeight: CGFloat = 170 + extraTitleHeight + (isStreaming ? 18 : 0)
        let height = min(maximumSize.height, max(minimumSize.height, bodyHeight + chromeHeight))
        return CGSize(width: width, height: height)
    }

    static func resizedFrame(
        currentFrame: CGRect,
        targetSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let proposedOrigin = CGPoint(
            x: currentFrame.maxX - targetSize.width,
            y: currentFrame.maxY - targetSize.height
        )
        let maximumX = visibleFrame.maxX - targetSize.width
        let maximumY = visibleFrame.maxY - targetSize.height
        let origin = CGPoint(
            x: min(maximumX, max(visibleFrame.minX, proposedOrigin.x)),
            y: min(maximumY, max(visibleFrame.minY, proposedOrigin.y))
        )
        return CGRect(origin: origin, size: targetSize)
    }
}

@MainActor
final class AIReaderWindowController: NSWindowController, NSWindowDelegate {
    private let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
        let panel = AIReaderPanel(
            contentRect: CGRect(origin: .zero, size: AIReaderLayout.minimumSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.minSize = AIReaderLayout.minimumSize
        panel.maxSize = AIReaderLayout.maximumSize
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AIReaderView(store: store))
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func syncVisibility(state: MeetingState) {
        guard let window else { return }
        if state.aiReader.isVisible {
            resize(for: state)
            if !window.isVisible {
                restorePositionOrPlaceAtRightEdge()
                window.orderFrontRegardless()
            }
        } else {
            window.orderOut(nil)
        }
    }

    func showPreview(state: MeetingState) {
        syncVisibility(state: state)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
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

    private func resize(for state: MeetingState) {
        guard let window else { return }
        let size = AIReaderLayout.targetSize(
            content: state.aiReader.content,
            title: state.aiReader.title,
            isStreaming: state.aiReader.isStreaming
        )
        guard window.frame.size != size else { return }
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let frame = AIReaderLayout.resizedFrame(
            currentFrame: window.frame,
            targetSize: size,
            visibleFrame: visibleFrame
        )
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func positionKey(for screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "aiReaderPosition.\(screenNumber?.stringValue ?? screen.localizedName)"
    }
}
