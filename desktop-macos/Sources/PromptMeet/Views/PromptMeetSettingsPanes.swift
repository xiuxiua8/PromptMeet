import AppKit
import ServiceManagement
import SwiftUI

extension PromptMeetSettingsView {
    var dataPane: some View {
        settingsGroup("本地数据") {
            Text("默认存储位置")
                .font(.system(size: 11, weight: .semibold))
            Text("~/Library/Application Support/PromptMeet/meetings/v2 + assets")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(VisualTokens.secondaryText)
            HStack {
                Button("在 Finder 中显示") {
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("PromptMeet")
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                Button("导出…", action: exportHistory)
                Button("删除历史…", action: deleteHistory)
                    .foregroundStyle(VisualTokens.danger)
                    .disabled(!store.canDeleteMeetingHistory)
            }
        }
    }

    var shortcutsPane: some View {
        settingsGroup("快捷键") {
            shortcutRow("快速提问", keys: "⌘ ⇧ P")
            shortcutRow("打开工作台", keys: "⌘ ⇧ M")
            shortcutRow("显示 / 隐藏 AI 阅读器", keys: "⌘ ⇧ A")
            shortcutRow("开始 / 停止录制", keys: "⌘ ⇧ R")
        }
    }

    func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func permissionRow(
        _ title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(VisualTokens.secondaryText)
            }
            Spacer()
            Button("系统设置", action: action)
        }
    }

    func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

}
