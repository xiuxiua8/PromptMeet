import AppKit
import ServiceManagement
import SwiftUI

extension PromptMeetSettingsView {
    var summaryCadenceBinding: Binding<SummaryCadence> {
        Binding(
            get: { SummaryCadence(rawValue: summaryCadenceMinutes) ?? .fiveMinutes },
            set: { summaryCadenceMinutes = $0.rawValue }
        )
    }

    var workflowRoutingPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作流模型路由")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("凭据与端点由提供方复用，模型按用途独立选择。模型标识允许手动输入。")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(VisualTokens.secondaryText)

            ForEach(AIWorkflow.allCases) { workflow in
                let selection = workflowSelection(workflow)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(workflow.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .frame(width: 86, alignment: .leading)
                        Picker("提供方", selection: workflowProviderBinding(workflow)) {
                            ForEach(AIProviderCatalog.providers) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 128)
                        .tint(VisualTokens.primaryText)
                        TextField("模型标识", text: workflowModelBinding(workflow))
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(Color(nsColor: SettingsInputAppearance.textColor))
                            .environment(\.colorScheme, SettingsInputAppearance.colorScheme)
                            .font(.system(size: 10, design: .monospaced))
                    }
                    if selection.providerID == "openai" {
                        Toggle("该端点与模型支持图像输入", isOn: workflowVisionBinding(workflow))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                    }
                    if workflow == .screenshotAnalysis && !selection.supportsVision {
                        Label(
                            "此模型不会收到截图像素。截图会保留，分析记录会明确标记为不支持，不会伪造视觉结论。",
                            systemImage: "eye.slash"
                        )
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if workflow == .conversation && !selection.supportsVision {
                        Label(
                            "问答会使用转写和已有截图分析文字，但模型不会看到原始截图像素。",
                            systemImage: "text.alignleft"
                        )
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(VisualTokens.secondaryText)
                    }
                }
                .padding(10)
                .background(VisualTokens.raised.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(12)
        .background(VisualTokens.raised.opacity(0.44))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func workflowSelection(_ workflow: AIWorkflow) -> AIWorkflowSelection {
        workflowSelections[workflow] ?? providerPreferences.selection(for: workflow)
    }

    func workflowProviderBinding(_ workflow: AIWorkflow) -> Binding<String> {
        Binding(
            get: { workflowSelection(workflow).providerID },
            set: { providerID in
                let current = workflowSelection(workflow)
                let modelID: String
                let supportsVision: Bool
                if providerID == "openai" {
                    modelID = OpenAICompatibleConfiguration.defaultModelID
                    supportsVision = true
                } else {
                    modelID = DeepSeekConfiguration.defaultModelID
                    supportsVision = false
                }
                workflowSelections[workflow] = AIWorkflowSelection(
                    providerID: providerID,
                    modelID: current.providerID == providerID ? current.modelID : modelID,
                    supportsVision: current.providerID == providerID ? current.supportsVision : supportsVision
                )
                aiFeedback = ""
            }
        )
    }

    func workflowModelBinding(_ workflow: AIWorkflow) -> Binding<String> {
        Binding(
            get: { workflowSelection(workflow).modelID },
            set: { modelID in
                let current = workflowSelection(workflow)
                workflowSelections[workflow] = AIWorkflowSelection(
                    providerID: current.providerID,
                    modelID: modelID,
                    supportsVision: current.supportsVision
                )
                aiFeedback = ""
            }
        )
    }

    func workflowVisionBinding(_ workflow: AIWorkflow) -> Binding<Bool> {
        Binding(
            get: { workflowSelection(workflow).supportsVision },
            set: { supportsVision in
                let current = workflowSelection(workflow)
                workflowSelections[workflow] = AIWorkflowSelection(
                    providerID: current.providerID,
                    modelID: current.modelID,
                    supportsVision: supportsVision
                )
                aiFeedback = ""
            }
        )
    }

    var selectedProvider: AIProviderDescriptor? {
        AIProviderCatalog.provider(id: aiProvider)
    }

    var selectedModelID: String {
        aiProvider == "openai" ? openAIModelDraft : deepSeekAnswerModel
    }

    var selectedModel: AIModelDescriptor? {
        selectedProvider?.models.first { $0.id == selectedModelID }
    }

    var selectedModelBinding: Binding<String> {
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

    func normalizeSelectedModel() {
        guard let provider = selectedProvider,
              !provider.models.contains(where: { $0.id == selectedModelID }),
              let fallback = provider.models.first
        else { return }
        selectedModelBinding.wrappedValue = fallback.id
    }

    func saveSelectedKey() {
        do {
            let trimmedSecret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSecret.isEmpty && credentialStatus != .configured {
                throw AIProviderConfigurationError.emptySecret
            }
            let openAIConfiguration = try OpenAICompatibleConfiguration(
                baseURL: openAIBaseURLDraft,
                modelID: openAIModelDraft
            )
            let deepSeekConfiguration = try DeepSeekConfiguration(
                baseURL: deepSeekBaseURLDraft,
                modelID: representativeModel(for: "deepseek")
            )
            for workflow in AIWorkflow.allCases {
                try providerPreferences.save(workflowSelection(workflow), for: workflow)
            }
            if !trimmedSecret.isEmpty {
                try secretManager.save(providerID: aiProvider, secret: trimmedSecret)
                credentialStatus = .configured
            }
            providerPreferences.saveOpenAICompatible(openAIConfiguration)
            providerPreferences.saveDeepSeek(deepSeekConfiguration)
            openAIBaseURLDraft = openAIConfiguration.baseURL.absoluteString
            openAIModelDraft = openAIConfiguration.modelID
            deepSeekBaseURLDraft = deepSeekConfiguration.baseURL.absoluteString
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

    func loadKeyStatus() {
        do {
            credentialStatus = try secretManager.status(providerID: aiProvider)
        } catch {
            credentialStatus = .notConfigured
            aiFeedback = error.localizedDescription
            aiFeedbackIsSuccess = false
        }
    }

    func loadOpenAICompatiblePreferences() {
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
        if let configuration = try? providerPreferences.loadDeepSeek() {
            deepSeekBaseURLDraft = configuration.baseURL.absoluteString
        }
    }

    func loadWorkflowPreferences() {
        workflowSelections = Dictionary(
            uniqueKeysWithValues: AIWorkflow.allCases.map {
                ($0, providerPreferences.selection(for: $0))
            }
        )
    }

    func representativeModel(for providerID: String) -> String {
        AIWorkflow.allCases
            .map(workflowSelection)
            .first(where: { $0.providerID == providerID })?
            .modelID
            ?? (providerID == "openai"
                ? OpenAICompatibleConfiguration.defaultModelID
                : DeepSeekConfiguration.defaultModelID)
    }

    func validateSelectedKey() {
        do {
            let draft = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let credential = draft.isEmpty
                ? try secretManager.credential(providerID: aiProvider)
                : draft
            guard let credential, !credential.isEmpty else {
                throw AIProviderConfigurationError.emptySecret
            }
            let providerID = aiProvider
            let workflow = AIWorkflow.allCases.first {
                workflowSelection($0).providerID == providerID
            } ?? .conversation
            let modelID = workflowSelection(workflow).modelID
            let baseURL = providerID == "openai" ? openAIBaseURLDraft : deepSeekBaseURLDraft
            isValidatingAI = true
            aiFeedback = "正在验证连接"
            Task {
                let result = await providerValidator.validate(
                    workflow: workflow,
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

    func removeSelectedKey() {
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

}
