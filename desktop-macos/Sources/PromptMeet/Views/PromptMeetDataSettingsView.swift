import AppKit
import ServiceManagement
import SwiftUI

extension PromptMeetSettingsView {
    func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    var localDataURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            saveStatus = error.localizedDescription
        }
    }

    func exportHistory() {
        guard FileManager.default.fileExists(atPath: localDataURL.appendingPathComponent("meetings").path) else {
            saveStatus = "还没有可导出的本地会议"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent(
            "PromptMeet-MeetingData-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in ["meetings", "assets", "desktop-sessions.json"] {
                let source = localDataURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(
                        at: source,
                        to: destination.appendingPathComponent(name)
                    )
                }
            }
            saveStatus = "会议历史已导出"
        } catch {
            saveStatus = error.localizedDescription
        }
    }

    func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = "删除全部本地会议历史？"
        alert.informativeText = "此操作无法撤销。请先结束正在进行的会议，旧版记录也会一并删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for name in ["meetings", "assets", "desktop-sessions.json"] {
                let url = localDataURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            saveStatus = "本地会议历史已删除"
        } catch {
            saveStatus = error.localizedDescription
        }
    }}
