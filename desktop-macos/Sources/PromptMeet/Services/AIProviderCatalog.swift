import Foundation

struct AIModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let supportsVision: Bool
    let detail: String
}

struct AIProviderDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let keychainAccount: String
    let models: [AIModelDescriptor]
    let validationURL: URL
    let capabilitySummary: String
}

struct ValidatedAIProvider: Equatable, Sendable {
    let provider: AIProviderDescriptor
    let model: AIModelDescriptor
}

enum AIProviderCatalog {
    static let providers = [deepSeek, openAI]

    static func provider(id: String) -> AIProviderDescriptor? {
        providers.first { $0.id == id }
    }

    static func validated(providerID: String, modelID: String) throws -> ValidatedAIProvider {
        guard let provider = provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { throw AIProviderConfigurationError.emptyModel }
        let model = provider.models.first(where: { $0.id == normalizedModelID })
            ?? AIModelDescriptor(
                id: normalizedModelID,
                displayName: normalizedModelID,
                supportsVision: false,
                detail: "手动输入的提供方模型标识"
            )
        return ValidatedAIProvider(provider: provider, model: model)
    }

    private static let deepSeek = AIProviderDescriptor(
        id: "deepseek",
        displayName: "DeepSeek",
        keychainAccount: "DEEPSEEK_API_KEY",
        models: [
            AIModelDescriptor(
                id: DeepSeekConfiguration.defaultModelID,
                displayName: "DeepSeek Chat",
                supportsVision: false,
                detail: "DeepSeek API 的既有文字模型标识，不接收截图像素"
            )
        ],
        validationURL: URL(string: "https://api.deepseek.com/models")!,
        capabilitySummary: "转写、摘要与文字问答。截图会保留，但当前模型只使用分析文字。"
    )

    private static let openAI = AIProviderDescriptor(
        id: "openai",
        displayName: "OpenAI 兼容",
        keychainAccount: "OPENAI_API_KEY",
        models: [
            AIModelDescriptor(
                id: "gpt-4o",
                displayName: "GPT-4o",
                supportsVision: true,
                detail: "文字推理与原始截图理解"
            ),
            AIModelDescriptor(
                id: "gpt-4o-mini",
                displayName: "GPT-4o mini",
                supportsVision: true,
                detail: "更快的文字与截图理解"
            )
        ],
        validationURL: URL(string: "https://api.openai.com/v1/models")!,
        capabilitySummary: "可连接官方 OpenAI 或兼容服务。PromptMeet 会尝试发送原始截图，并在端点或模型拒绝图像时透明降级。"
    )
}
