import AppKit
import SwiftUI

final class BorderlessIslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandWindowController: NSWindowController {
    static let panelStyleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
    private let store: MeetingStore
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var trackingTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    private var screenChangeObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var isMouseInsideIsland = false

    init(store: MeetingStore, openWorkspace: @escaping () -> Void) {
        self.store = store
        let panel = BorderlessIslandPanel(
            contentRect: CGRect(origin: .zero, size: IslandGeometry.hostSize),
            styleMask: Self.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let rootView = IslandRootView(store: store, openWorkspace: openWorkspace)
        let host = IslandHostingView(rootView: rootView, store: store)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        super.init(window: panel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        repositionForCurrentScreen()
        window?.orderFrontRegardless()
        installMouseTracking()
        observeDisplayChanges()
    }

    func focusQuickAsk() {
        store.setQuickAskPresented(true)
        repositionForCurrentScreen()
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
    }

    private func repositionForCurrentScreen() {
        guard let window, let screen = IslandTargetScreen.current() else { return }
        store.updateNotchInfo(NotchInfo.detect(from: screen))
        window.setFrame(IslandGeometry.hostFrame(in: screen.frame), display: true)
    }

    private func installMouseTracking() {
        window?.ignoresMouseEvents = true

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.trackingTimer?.invalidate()
                self.trackingTimer = nil
                self.updateMouseState()
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved],
            handler: handler
        )
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        }

        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMouseState() }
        }
    }

    private func updateMouseState() {
        guard let window else { return }

        if ProcessInfo.processInfo.environment["PROMPTMEET_UI_PREVIEW"] == "hover" {
            window.ignoresMouseEvents = false
            if !store.isHovered { store.setHovered(true) }
            return
        }

        let cursor = NSEvent.mouseLocation
        let windowFrame = window.frame
        let localPoint = CGPoint(
            x: cursor.x - windowFrame.minX,
            y: cursor.y - windowFrame.minY
        )
        let visibleRect = IslandGeometry.visibleRect(
            for: store.presentation,
            inHost: windowFrame.size,
            topChromeWidth: store.topChromeWidth,
            topChromeHeight: store.topChromeHeight
        )
        let isInside = visibleRect.contains(localPoint)

        window.ignoresMouseEvents = !isInside
        if isInside != isMouseInsideIsland {
            isMouseInsideIsland = isInside
            if isInside {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
            }
        }
        if UserDefaults.standard.string(forKey: "targetDisplay") == "跟随鼠标",
           let target = IslandTargetScreen.current(),
           window.screen != target {
            repositionForCurrentScreen()
        }

        if store.state.isQuickAskPresented {
            hoverTask?.cancel()
            hoverTask = nil
            if store.isHovered { store.setHovered(false) }
            return
        }

        if isInside, !store.isHovered, hoverTask == nil {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                self.hoverTask = nil
                self.updateHoverAfterDelay()
            }
        } else if !isInside {
            hoverTask?.cancel()
            hoverTask = nil
            if store.isHovered { store.setHovered(false) }
        }
    }

    private func updateHoverAfterDelay() {
        guard let window else { return }
        let cursor = NSEvent.mouseLocation
        let localPoint = CGPoint(x: cursor.x - window.frame.minX, y: cursor.y - window.frame.minY)
        let visibleRect = IslandGeometry.visibleRect(
            for: store.presentation,
            inHost: window.frame.size,
            topChromeWidth: store.topChromeWidth,
            topChromeHeight: store.topChromeHeight
        )
        if visibleRect.contains(localPoint) {
            store.setHovered(true)
        }
    }

    private func observeDisplayChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionForCurrentScreen() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionForCurrentScreen() }
        }
    }

    isolated deinit {
        hoverTask?.cancel()
        trackingTimer?.invalidate()
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = screenChangeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = defaultsObserver { NotificationCenter.default.removeObserver(observer) }
    }
}
