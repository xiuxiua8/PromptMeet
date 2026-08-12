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

        if isHoverPreview {
            window.ignoresMouseEvents = false
            if !store.isHovered { store.setHovered(true) }
            return
        }

        let isInside = islandContainsCursor(in: window)
        window.ignoresMouseEvents = !isInside
        updateKeyWindow(window, isInside: isInside)
        followCursorToAnotherDisplay(from: window)

        if store.state.isQuickAskPresented {
            cancelPendingHover(resetPresentation: true)
            return
        }

        updateHoverTracking(isInside: isInside)
    }

    private var isHoverPreview: Bool {
        ProcessInfo.processInfo.environment["PROMPTMEET_UI_PREVIEW"] == "hover"
    }

    private func islandContainsCursor(in window: NSWindow) -> Bool {
        let cursor = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: cursor.x - window.frame.minX,
            y: cursor.y - window.frame.minY
        )
        return IslandGeometry.interactiveRect(
            for: store.presentation,
            inHost: window.frame.size,
            topChromeWidth: store.topChromeWidth,
            topChromeHeight: store.topChromeHeight
        ).contains(localPoint)
    }

    private func updateKeyWindow(_ window: NSWindow, isInside: Bool) {
        guard isInside != isMouseInsideIsland else { return }
        isMouseInsideIsland = isInside
        guard isInside else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
    }

    private func followCursorToAnotherDisplay(from window: NSWindow) {
        guard UserDefaults.standard.string(forKey: "targetDisplay") == "跟随鼠标",
              let target = IslandTargetScreen.current(),
              window.screen != target else { return }
        repositionForCurrentScreen()
    }

    private func updateHoverTracking(isInside: Bool) {
        if isInside, !store.isHovered, hoverTask == nil {
            scheduleHoverPresentation()
        } else if !isInside {
            cancelPendingHover(resetPresentation: true)
        }
    }

    private func scheduleHoverPresentation() {
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.hoverTask = nil
            self.updateHoverAfterDelay()
        }
    }

    private func cancelPendingHover(resetPresentation: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        if resetPresentation, store.isHovered { store.setHovered(false) }
    }

    private func updateHoverAfterDelay() {
        guard let window else { return }
        let cursor = NSEvent.mouseLocation
        let localPoint = CGPoint(x: cursor.x - window.frame.minX, y: cursor.y - window.frame.minY)
        let visibleRect = IslandGeometry.interactiveRect(
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
