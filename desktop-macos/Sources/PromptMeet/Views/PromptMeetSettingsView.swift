import AppKit
import ServiceManagement
import SwiftUI

enum SettingsInputAppearance {
    static let textColor = NSColor.black
    static let colorScheme: ColorScheme = .light
    static let surfaceColorScheme: ColorScheme = .dark
}

struct PromptMeetSettingsView: View {
    var onAIConfigurationChanged: () -> Void = {}
    enum Pane: String, CaseIterable, Identifiable {
        case general = "通用"
        case capture = "采集"
        case aiService = "AI 服务"
        case data = "数据"
        case shortcuts = "快捷键"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .capture: "waveform"
            case .aiService: "sparkles"
            case .data: "externaldrive"
            case .shortcuts: "command"
            }
        }
    }

    @State var selectedPane = Pane.general
    @State var secretDraft = ""
    @State var credentialStatus = AIProviderCredentialStatus.notConfigured
    @State var aiFeedback = ""
    @State var aiFeedbackIsSuccess = false
    @State var isValidatingAI = false
    @State var openAIBaseURLDraft = OpenAICompatibleConfiguration.defaultBaseURL
    @State var openAIModelDraft = OpenAICompatibleConfiguration.defaultModelID
    @State var deepSeekBaseURLDraft = DeepSeekConfiguration.defaultBaseURL
    @State var workflowSelections: [AIWorkflow: AIWorkflowSelection] = [:]
    @State var saveStatus = ""
    @StateObject var modelLibrary = WhisperModelLibrary()
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("interfaceLanguage") var interfaceLanguage = "简体中文"
    @AppStorage("targetDisplay") var targetDisplay = "主显示器"
    @AppStorage(AIProviderPreferenceKey.provider) var aiProvider = "deepseek"
    @AppStorage(AIProviderPreferenceKey.deepSeekAnswerModel) var deepSeekAnswerModel =
        DeepSeekConfiguration.defaultModelID
    @AppStorage(MeetingPreferenceKey.summaryCadenceMinutes) var summaryCadenceMinutes = 5
    @AppStorage(MeetingPreferenceKey.includeLocalMicrophone) var includeLocalMicrophone = true
    let secretManager = AIProviderSecretManager()
    let providerPreferences = AIProviderPreferences()
    let providerValidator = AIProviderConnectionValidator()

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
                    case .aiService: aiPane
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
        .environment(\.colorScheme, SettingsInputAppearance.surfaceColorScheme)
        .task {
            loadOpenAICompatiblePreferences()
            loadWorkflowPreferences()
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

    var generalPane: some View {
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

}
