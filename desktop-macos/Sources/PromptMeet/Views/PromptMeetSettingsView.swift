import AppKit
import ServiceManagement
import SwiftUI

enum SettingsInputAppearance {
    static let textColor = NSColor.black
    static let colorScheme: ColorScheme = .light
}

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
    @State private var secretDraft = ""
    @State private var credentialStatus = AIProviderCredentialStatus.notConfigured
    @State private var aiFeedback = ""
    @State private var aiFeedbackIsSuccess = false
    @State private var isValidatingAI = false
    @State private var openAIBaseURLDraft = OpenAICompatibleConfiguration.defaultBaseURL
    @State private var openAIModelDraft = OpenAICompatibleConfiguration.defaultModelID
    @State private var saveStatus = ""
    @StateObject private var modelLibrary = WhisperModelLibrary()
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "简体中文"
    @AppStorage("targetDisplay") private var targetDisplay = "主显示器"
    @AppStorage(AIProviderPreferenceKey.provider) private var aiProvider = "deepseek"
    @AppStorage(AIProviderPreferenceKey.deepSeekAnswerModel) private var deepSeekAnswerModel = "deepseek-v4-pro"
    private let secretManager = AIProviderSecretManager()
    private let providerPreferences = AIProviderPreferences()
    private let providerValidator = AIProviderConnectionValidator()

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

            ScrollView {
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 650, height: 540)
        .background(Color(red: 0.035, green: 0.038, blue: 0.045))
        .foregroundStyle(VisualTokens.primaryText)
        .task {
            loadOpenAICompatiblePreferences()
            loadKeyStatus()
        }
        .onChange(of: aiProvider) { _, _ in
            secretDraft = ""
            aiFeedback = ""
            loadKeyStatus()
            if aiProvider == "deepseek" {
                normalizeSelectedModel()
            }
        }
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
            HStack(spacing: 10) {
                ForEach(AIProviderCatalog.providers) { provider in
                    Button {
                        aiProvider = provider.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(provider.displayName)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Spacer()
                                if aiProvider == provider.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(VisualTokens.live)
                                }
                            }
                            Text(
                                provider.id == "openai"
                                    ? "可配置兼容端点"
                                    : "文字上下文"
                            )
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(VisualTokens.secondaryText)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            aiProvider == provider.id
                                ? VisualTokens.cobalt.opacity(0.16)
                                : VisualTokens.raised
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    aiProvider == provider.id
                                        ? VisualTokens.cobalt.opacity(0.50)
                                        : VisualTokens.line,
                                    lineWidth: 0.7
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择 \(provider.displayName)")
                }
            }

            if let provider = selectedProvider {
                VStack(alignment: .leading, spacing: 10) {
                    if provider.id == "openai" {
                        Text("OpenAI 兼容配置")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(VisualTokens.secondaryText)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Base URL")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(VisualTokens.secondaryText)
                            TextField("https://api.openai.com/v1", text: $openAIBaseURLDraft)
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(Color(nsColor: SettingsInputAppearance.textColor))
                                .environment(\.colorScheme, SettingsInputAppearance.colorScheme)
                                .font(.system(size: 11, design: .monospaced))
                            Text("模型标识")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(VisualTokens.secondaryText)
                            TextField("gpt-4o", text: $openAIModelDraft)
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(Color(nsColor: SettingsInputAppearance.textColor))
                                .environment(\.colorScheme, SettingsInputAppearance.colorScheme)
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Label(
                            "仅 localhost、127.0.0.1 和 ::1 可使用 HTTP，其他地址必须使用 HTTPS",
                            systemImage: "lock.shield"
                        )
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                    } else {
                        Text("回答模型")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(VisualTokens.secondaryText)
                        Picker("回答模型", selection: selectedModelBinding) {
                            ForEach(provider.models) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)

                        if let model = selectedModel {
                            Label(
                                model.detail,
                                systemImage: model.supportsVision ? "eye" : "text.alignleft"
                            )
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(model.supportsVision ? VisualTokens.live : VisualTokens.amber)
                        }
                    }

                    Text(provider.capabilitySummary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("API Key")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Spacer()
                        Label(
                            credentialStatus == .configured ? "已存储 ••••••••" : "尚未配置",
                            systemImage: credentialStatus == .configured ? "lock.fill" : "lock.open"
                        )
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            credentialStatus == .configured ? VisualTokens.live : VisualTokens.secondaryText
                        )
                    }

                    SecureField("输入新的 \(provider.displayName) API Key", text: $secretDraft)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(Color(nsColor: SettingsInputAppearance.textColor))
                        .environment(\.colorScheme, SettingsInputAppearance.colorScheme)

                    HStack(spacing: 10) {
                        if isValidatingAI {
                            ProgressView().controlSize(.small)
                        }
                        if !aiFeedback.isEmpty {
                            Text(aiFeedback)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(aiFeedbackIsSuccess ? VisualTokens.live : VisualTokens.danger)
                                .lineLimit(2)
                        }
                        Spacer()
                        if credentialStatus == .configured {
                            Button("移除", action: removeSelectedKey)
                                .foregroundStyle(VisualTokens.danger)
                        }
                        Button("验证连接", action: validateSelectedKey)
                            .disabled(
                                (secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && credentialStatus != .configured)
                                    || isValidatingAI
                            )
                        Button("保存并应用", action: saveSelectedKey)
                            .buttonStyle(.borderedProminent)
                            .tint(VisualTokens.cobalt)
                            .disabled(
                                secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && credentialStatus != .configured
                            )
                    }
                }
                .padding(14)
                .background(VisualTokens.raised)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var dataPane: some View {
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

    private var selectedProvider: AIProviderDescriptor? {
        AIProviderCatalog.provider(id: aiProvider)
    }

    private var selectedModelID: String {
        aiProvider == "openai" ? openAIModelDraft : deepSeekAnswerModel
    }

    private var selectedModel: AIModelDescriptor? {
        selectedProvider?.models.first { $0.id == selectedModelID }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { selectedModelID },
            set: { value in
                if aiProvider == "openai" {
                    openAIModelDraft = value
                } else {
                    deepSeekAnswerModel = value
                }
                aiFeedback = ""
            }
        )
    }

    private func normalizeSelectedModel() {
        guard let provider = selectedProvider,
              !provider.models.contains(where: { $0.id == selectedModelID }),
              let fallback = provider.models.first
        else { return }
        selectedModelBinding.wrappedValue = fallback.id
    }

    private func saveSelectedKey() {
        do {
            let trimmedSecret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSecret.isEmpty && credentialStatus != .configured {
                throw AIProviderConfigurationError.emptySecret
            }
            let openAIConfiguration: OpenAICompatibleConfiguration?
            if aiProvider == "openai" {
                openAIConfiguration = try OpenAICompatibleConfiguration(
                    baseURL: openAIBaseURLDraft,
                    modelID: openAIModelDraft
                )
            } else {
                _ = try AIProviderCatalog.validated(
                    providerID: aiProvider,
                    modelID: selectedModelID
                )
                openAIConfiguration = nil
            }
            if !trimmedSecret.isEmpty {
                try secretManager.save(providerID: aiProvider, secret: trimmedSecret)
                credentialStatus = .configured
            }
            if let openAIConfiguration {
                providerPreferences.saveOpenAICompatible(openAIConfiguration)
                openAIBaseURLDraft = openAIConfiguration.baseURL.absoluteString
                openAIModelDraft = openAIConfiguration.modelID
            }
            secretDraft = ""
            aiFeedback = trimmedSecret.isEmpty
                ? "兼容端点与模型已保存，正在应用配置"
                : "API Key 已安全保存到 macOS Keychain，正在应用配置"
            aiFeedbackIsSuccess = true
            onAIConfigurationChanged()
        } catch {
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    private func loadKeyStatus() {
        do {
            credentialStatus = try secretManager.status(providerID: aiProvider)
        } catch {
            credentialStatus = .notConfigured
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    private func loadOpenAICompatiblePreferences() {
        do {
            let configuration = try providerPreferences.loadOpenAICompatible()
            openAIBaseURLDraft = configuration.baseURL.absoluteString
            openAIModelDraft = configuration.modelID
        } catch {
            openAIBaseURLDraft = OpenAICompatibleConfiguration.defaultBaseURL
            openAIModelDraft = OpenAICompatibleConfiguration.defaultModelID
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    private func validateSelectedKey() {
        do {
            let draft = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = draft.isEmpty
                ? try secretManager.credential(providerID: aiProvider)
                : draft
            guard let credential, !credential.isEmpty else {
                throw AIProviderConfigurationError.emptySecret
            }
            let providerID = aiProvider
            let modelID = selectedModelID
            let baseURL = providerID == "openai" ? openAIBaseURLDraft : nil
            isValidatingAI = true
            aiFeedback = "正在验证连接"
            Task {
                let result = await providerValidator.validate(
                    providerID: providerID,
                    modelID: modelID,
                    baseURL: baseURL,
                    secret: credential
                )
                await MainActor.run {
                    isValidatingAI = false
                    aiFeedback = result.message
                    aiFeedbackIsSuccess = result.isValid
                }
            }
        } catch {
            isValidatingAI = false
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    private func removeSelectedKey() {
        do {
            try secretManager.remove(providerID: aiProvider)
            credentialStatus = .notConfigured
            secretDraft = ""
            aiFeedback = "密钥已从 macOS Keychain 移除"
            aiFeedbackIsSuccess = true
            onAIConfigurationChanged()
        } catch {
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private var localDataURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptMeet", isDirectory: true)
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

    private func deleteHistory() {
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
    }
}
