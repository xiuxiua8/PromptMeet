import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MeetingStore()
    private var islandController: IslandWindowController?
    private var readerController: AIReaderWindowController?
    private var workspaceController: WorkspaceWindowController?
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var shortcutController: GlobalShortcutController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settings = SettingsWindowController {
            self.store.reloadCompanionConfiguration()
        }
        let workspace = WorkspaceWindowController(store: store) { settings.show() }
        let reader = AIReaderWindowController(store: store)
        let island = IslandWindowController(store: store) { workspace.show() }
        workspaceController = workspace
        settingsController = settings
        readerController = reader
        islandController = island

        store.$state
            .sink { [weak reader] state in reader?.syncVisibility(state: state) }
            .store(in: &cancellables)

        configureStatusItem()
        configureShortcuts()
        if let previewMode = ProcessInfo.processInfo.environment["PROMPTMEET_UI_PREVIEW"] {
            store.configureUIPreview(previewMode)
            if previewMode.hasPrefix("workspace") {
                workspace.show()
            } else if previewMode == "reader-short" || previewMode == "reader-long" {
                reader.showPreview(state: store.state)
            } else {
                island.show()
            }
        } else {
            island.show()
            store.prepareCompanion()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await store.shutdownNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.badge.mic", accessibilityDescription: "PromptMeet")

        let menu = NSMenu()
        let title = NSMenuItem(title: "PromptMeet", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let workspace = menu.addItem(withTitle: "打开工作台", action: #selector(openWorkspace), keyEquivalent: "m")
        let quickAsk = menu.addItem(withTitle: "快速提问", action: #selector(openQuickAsk), keyEquivalent: "p")
        let reader = menu.addItem(withTitle: "显示 / 隐藏 AI 阅读器", action: #selector(toggleReader), keyEquivalent: "a")
        let recording = menu.addItem(withTitle: "开始 / 结束会议", action: #selector(toggleMeeting), keyEquivalent: "r")
        [workspace, quickAsk, reader, recording].forEach {
            $0.keyEquivalentModifierMask = [.command, .shift]
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        menu.addItem(withTitle: "退出 PromptMeet", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openWorkspace() {
        workspaceController?.show()
    }

    @objc private func toggleMeeting() {
        if store.state.phase == .live { store.endMeeting() } else { store.startMeeting() }
    }

    @objc private func openQuickAsk() {
        islandController?.focusQuickAsk()
    }

    @objc private func toggleReader() {
        store.toggleReader()
    }

    @objc private func openSettings() {
        settingsController?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureShortcuts() {
        let controller = GlobalShortcutController(actions: [
            .quickAsk: { [weak self] in self?.openQuickAsk() },
            .workspace: { [weak self] in self?.openWorkspace() },
            .reader: { [weak self] in self?.toggleReader() },
            .recording: { [weak self] in self?.toggleMeeting() }
        ])
        controller.start()
        shortcutController = controller
    }
}
