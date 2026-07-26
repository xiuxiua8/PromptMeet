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

enum AIProviderConfigurationError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case unsupportedModel(provider: String, model: String)
    case emptySecret

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider): "不支持的 AI 提供方：\(provider)"
        case let .unsupportedModel(provider, model): "\(provider) 不支持模型 \(model)"
        case .emptySecret: "请输入 API Key"
        }
    }
}

enum AIProviderCatalog {
    static let providers = [
        AIProviderDescriptor(
            id: "deepseek",
            displayName: "DeepSeek",
            keychainAccount: "DEEPSEEK_API_KEY",
            models: [
                AIModelDescriptor(
                    id: "deepseek-v4-pro",
                    displayName: "DeepSeek V4 Pro",
                    supportsVision: false,
                    detail: "高质量文字推理，不接收截图像素"
                ),
                AIModelDescriptor(
                    id: "deepseek-v4-flash",
                    displayName: "DeepSeek V4 Flash",
                    supportsVision: false,
                    detail: "快速文字问答，不接收截图像素"
                )
            ],
            validationURL: URL(string: "https://api.deepseek.com/models")!,
            capabilitySummary: "转写、摘要与文字问答。截图会保留，但当前模型只使用分析文字。"
        ),
        AIProviderDescriptor(
            id: "openai",
            displayName: "OpenAI",
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
            capabilitySummary: "转写、摘要、文字问答与原始截图多模态理解。"
        )
    ]

    static func provider(id: String) -> AIProviderDescriptor? {
        providers.first { $0.id == id }
    }

    static func validated(providerID: String, modelID: String) throws -> ValidatedAIProvider {
        guard let provider = provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        guard let model = provider.models.first(where: { $0.id == modelID }) else {
            throw AIProviderConfigurationError.unsupportedModel(
                provider: provider.displayName,
                model: modelID
            )
        }
        return ValidatedAIProvider(provider: provider, model: model)
    }
}

enum AIProviderCredentialStatus: Equatable {
    case notConfigured
    case configured
}

struct AIProviderSecretManager: CustomStringConvertible {
    static let service = "com.promptmeet.desktop"

    private let keychain: any KeychainStoring
    private let defaults: UserDefaults

    init(
        keychain: any KeychainStoring = KeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults
    }

    var description: String { "AIProviderSecretManager(Keychain only)" }

    func status(providerID: String) throws -> AIProviderCredentialStatus {
        guard let provider = AIProviderCatalog.provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        return try keychain.contains(
            service: Self.service,
            account: provider.keychainAccount
        ) ? .configured : .notConfigured
    }

    func save(providerID: String, secret: String) throws {
        guard let provider = AIProviderCatalog.provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderConfigurationError.emptySecret }
        try keychain.write(
            trimmed,
            service: Self.service,
            account: provider.keychainAccount
        )
    }

    func remove(providerID: String) throws {
        guard let provider = AIProviderCatalog.provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        try keychain.delete(service: Self.service, account: provider.keychainAccount)
    }
}

struct AIProviderValidationResult: Equatable, Sendable {
    let isValid: Bool
    let message: String
}

struct AIProviderConnectionValidator: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(providerID: String, modelID: String, secret: String) async -> AIProviderValidationResult {
        do {
            let configuration = try AIProviderCatalog.validated(
                providerID: providerID,
                modelID: modelID
            )
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AIProviderConfigurationError.emptySecret }
            var request = URLRequest(url: configuration.provider.validationURL)
            request.timeoutInterval = 20
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return AIProviderValidationResult(isValid: false, message: "提供方返回无效响应")
            }
            if (200..<300).contains(response.statusCode) {
                return AIProviderValidationResult(
                    isValid: true,
                    message: "连接成功，\(configuration.model.displayName) 可用"
                )
            }
            return AIProviderValidationResult(
                isValid: false,
                message: "连接失败，提供方返回 \(response.statusCode)"
            )
        } catch {
            return AIProviderValidationResult(isValid: false, message: error.localizedDescription)
        }
    }
}
