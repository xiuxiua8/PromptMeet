import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct PromptMeetSettingsView: View {
    var onAIConfigurationChanged: () -> Void = {}
    private enum Pane: String, CaseIterable, Identifiable {
        case general = "通用"
        case capture = "采集"
        case ai = "AI 服务"
        case data = "数据"
        case shortcuts = "快捷键"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .capture: "waveform"
            case .ai: "sparkles"
            case .data: "externaldrive"
            case .shortcuts: "command"
            }
        }
    }

    @State private var selectedPane = Pane.general
    @State private var openAIKey = ""
    @State private var deepSeekKey = ""
    @State private var saveStatus = ""
    @StateObject private var modelLibrary = WhisperModelLibrary()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "简体中文"
    @AppStorage("targetDisplay") private var targetDisplay = "主显示器"
    @AppStorage("aiProvider") private var aiProvider = "deepseek"
    @AppStorage("deepSeekAnswerModel") private var deepSeekAnswerModel = "deepseek-v4-pro"
    @AppStorage("openAIAnswerModel") private var openAIAnswerModel = "gpt-4o"
    private let keychain = KeychainStore()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Pane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        Label(pane.rawValue, systemImage: pane.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selectedPane == pane ? VisualTokens.cobalt.opacity(0.25) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(14)
            .frame(width: 150)
            .background(Color.black.opacity(0.15))

            Divider().overlay(VisualTokens.line)

            Group {
                switch selectedPane {
                case .general: generalPane
                case .capture: capturePane
                case .ai: aiPane
                case .data: dataPane
                case .shortcuts: shortcutsPane
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 650, height: 540)
        .background(Color(red: 0.035, green: 0.038, blue: 0.045))
        .foregroundStyle(VisualTokens.primaryText)
        .task { loadKeyStatus() }
    }

    private var generalPane: some View {
        settingsGroup("通用") {
            Toggle("登录时启动 PromptMeet", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    updateLaunchAtLogin(enabled)
                }
            Picker("灵动岛显示器", selection: $targetDisplay) {
                Text("主显示器").tag("主显示器")
                Text("跟随鼠标").tag("跟随鼠标")
            }
            Picker("界面语言", selection: $interfaceLanguage) {
                Text("简体中文").tag("简体中文")
                Text("English").tag("English")
            }
        }
    }

    private var capturePane: some View {
        settingsGroup("采集与权限") {
            permissionRow("屏幕与系统音频", detail: "ScreenCaptureKit，不需要 BlackHole") {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            Divider().overlay(VisualTokens.line)
            permissionRow("麦克风", detail: "AVAudioEngine 使用当前默认输入设备") {
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            Divider().overlay(VisualTokens.line)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地转写")
                        .font(.system(size: 11, weight: .semibold))
                    Text("whisper.cpp · 音频不会离开本机")
                        .font(.system(size: 10))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
                Spacer()
                Picker("语言", selection: $modelLibrary.language) {
                    Text("自动").tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .labelsHidden()
                .frame(width: 105)
                Button {
                    NSWorkspace.shared.open(modelLibrary.repository.modelsDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
            }
            HStack {
                Toggle("实时翻译", isOn: $modelLibrary.translationEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Picker("目标语言", selection: $modelLibrary.translationTargetLanguage) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                    Text("한국어").tag("ko")
                }
                .disabled(!modelLibrary.translationEnabled)
                .frame(width: 150)
            }
            VStack(spacing: 6) {
                ForEach(WhisperModelCatalog.models) { model in
                    modelRow(model)
                }
            }
            if let message = modelLibrary.errorMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(VisualTokens.danger)
                    .lineLimit(2)
            }
        }
    }

    private func modelRow(_ model: WhisperModelDescriptor) -> some View {
        let installed = modelLibrary.isInstalled(model)
        let selected = installed && modelLibrary.selectedModelID == model.id
        let downloading = modelLibrary.downloadingModelID == model.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.sizeLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(VisualTokens.secondaryText)
                }
                Text(model.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(VisualTokens.secondaryText)
                if downloading {
                    ProgressView(value: modelLibrary.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(VisualTokens.cobalt)
                }
            }
            Spacer()
            if downloading {
                Button("取消") { modelLibrary.cancelDownload() }
                    .buttonStyle(.plain)
                    .foregroundStyle(VisualTokens.secondaryText)
            } else if selected {
                Label("使用中", systemImage: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VisualTokens.live)
            } else if installed {
                Button("使用") { modelLibrary.select(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    modelLibrary.remove(model)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualTokens.secondaryText)
            } else {
                Button("下载") { modelLibrary.download(model) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(modelLibrary.downloadingModelID != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VisualTokens.raised.opacity(selected ? 1 : 0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var aiPane: some View {
        settingsGroup("AI 服务") {
            Picker("服务提供方", selection: $aiProvider) {
                Text("DeepSeek").tag("deepseek")
                Text("OpenAI").tag("openai")
            }
            Picker("回答模型", selection: aiProvider == "deepseek" ? $deepSeekAnswerModel : $openAIAnswerModel) {
                if aiProvider == "deepseek" {
                    Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                    Text("DeepSeek V4 Flash").tag("deepseek-v4-flash")
                } else {
                    Text("GPT-4o").tag("gpt-4o")
                    Text("GPT-4o mini").tag("gpt-4o-mini")
                }
            }
            LabeledContent("猜你想问") {
                Text(aiProvider == "deepseek" ? "DeepSeek V4 Flash" : "GPT-4o mini")
                    .foregroundStyle(VisualTokens.secondaryText)
            }
            SecureField("OpenAI API Key", text: $openAIKey)
                .textFieldStyle(.roundedBorder)
            SecureField("DeepSeek API Key", text: $deepSeekKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(saveStatus).font(.system(size: 10)).foregroundStyle(VisualTokens.secondaryText)
                Spacer()
                Button("保存并应用", action: saveKeys)
                    .buttonStyle(.borderedProminent)
                    .tint(VisualTokens.cobalt)
            }
        }
    }

    private var dataPane: some View {
        settingsGroup("本地数据") {
            Text("默认存储位置")
                .font(.system(size: 11, weight: .semibold))
            Text("~/Library/Application Support/PromptMeet/desktop-sessions.json")
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
            }
        }
    }

    private var shortcutsPane: some View {
        settingsGroup("快捷键") {
            shortcutRow("快速提问", keys: "⌘ ⇧ P")
            shortcutRow("打开工作台", keys: "⌘ ⇧ M")
            shortcutRow("显示 / 隐藏 AI 阅读器", keys: "⌘ ⇧ A")
            shortcutRow("开始 / 停止录制", keys: "⌘ ⇧ R")
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(
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

    private func shortcutRow(_ title: String, keys: String) -> some View {
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

    private func saveKeys() {
        do {
            if !openAIKey.isEmpty {
                try keychain.write(openAIKey, service: "com.promptmeet.desktop", account: "OPENAI_API_KEY")
            }
            if !deepSeekKey.isEmpty {
                try keychain.write(deepSeekKey, service: "com.promptmeet.desktop", account: "DEEPSEEK_API_KEY")
            }
            openAIKey = ""
            deepSeekKey = ""
            saveStatus = "正在重新连接 AI 服务…"
            onAIConfigurationChanged()
        } catch {
            saveStatus = error.localizedDescription
        }
    }

    private func loadKeyStatus() {
        let hasOpenAI = (try? keychain.read(service: "com.promptmeet.desktop", account: "OPENAI_API_KEY")) != nil
        let hasDeepSeek = (try? keychain.read(service: "com.promptmeet.desktop", account: "DEEPSEEK_API_KEY")) != nil
        saveStatus = [hasOpenAI ? "OpenAI 已配置" : nil, hasDeepSeek ? "DeepSeek 已配置" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private var localHistoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet/desktop-sessions.json")
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
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

    private func exportHistory() {
        guard FileManager.default.fileExists(atPath: localHistoryURL.path) else {
            saveStatus = "还没有可导出的本地会议"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PromptMeet-会议历史.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: localHistoryURL, to: destination)
            saveStatus = "会议历史已导出"
        } catch {
            saveStatus = error.localizedDescription
        }
    }

    private func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = "删除全部本地会议历史？"
        alert.informativeText = "此操作无法撤销，当前正在进行的会议不会被终止。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if FileManager.default.fileExists(atPath: localHistoryURL.path) {
                try FileManager.default.removeItem(at: localHistoryURL)
            }
            saveStatus = "本地会议历史已删除"
        } catch {
            saveStatus = error.localizedDescription
        }
    }
}
