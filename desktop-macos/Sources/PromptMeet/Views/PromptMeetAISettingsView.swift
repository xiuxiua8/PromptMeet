import AppKit
import ServiceManagement
import SwiftUI

extension PromptMeetSettingsView {
    var aiPane: some View {
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

            workflowRoutingPane

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
                        Text("DeepSeek Base URL")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(VisualTokens.secondaryText)
                        TextField("https://api.deepseek.com", text: $deepSeekBaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(Color(nsColor: SettingsInputAppearance.textColor))
                            .environment(\.colorScheme, SettingsInputAppearance.colorScheme)
                            .font(.system(size: 11, design: .monospaced))
                        Label("DeepSeek 端点必须使用 HTTPS；每个工作流的模型标识在上方单独配置", systemImage: "lock.shield")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(VisualTokens.secondaryText)
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

}
