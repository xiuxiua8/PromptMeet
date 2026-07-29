import Foundation

enum AIProviderPreferenceKey {
    static let provider = "aiProvider"
    static let deepSeekAnswerModel = "deepSeekAnswerModel"
    static let openAIBaseURL = "openAIBaseURL"
    static let openAIModel = "openAIAnswerModel"
}

struct OpenAICompatibleConfiguration: Equatable, Sendable {
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModelID = "gpt-4o"

    let baseURL: URL
    let modelID: String

    init(baseURL: String, modelID: String) throws {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBaseURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || loopbackHosts.contains(host) else {
            throw AIProviderConfigurationError.insecureBaseURL
        }
        components.scheme = scheme
        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }
        guard let normalizedBaseURL = components.url else {
            throw AIProviderConfigurationError.invalidBaseURL
        }
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            throw AIProviderConfigurationError.emptyModel
        }
        self.baseURL = normalizedBaseURL
        self.modelID = trimmedModelID
    }

    var chatCompletionsURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.percentEncodedPath
        components.percentEncodedPath = prefix.isEmpty
            ? "/chat/completions"
            : "\(prefix)/chat/completions"
        return components.url!
    }
}

struct AIProviderPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadOpenAICompatible() throws -> OpenAICompatibleConfiguration {
        try OpenAICompatibleConfiguration(
            baseURL: defaults.string(forKey: AIProviderPreferenceKey.openAIBaseURL)
                ?? OpenAICompatibleConfiguration.defaultBaseURL,
            modelID: defaults.string(forKey: AIProviderPreferenceKey.openAIModel)
                ?? OpenAICompatibleConfiguration.defaultModelID
        )
    }

    func saveOpenAICompatible(_ configuration: OpenAICompatibleConfiguration) {
        defaults.set(
            configuration.baseURL.absoluteString,
            forKey: AIProviderPreferenceKey.openAIBaseURL
        )
        defaults.set(configuration.modelID, forKey: AIProviderPreferenceKey.openAIModel)
    }

    func runtimeEnvironment(providerID: String) throws -> [String: String] {
        switch providerID {
        case "openai":
            let configuration = try loadOpenAICompatible()
            return [
                "PROMPTMEET_AI_PROVIDER": "openai",
                "OPENAI_API_BASE": configuration.baseURL.absoluteString,
                "OPENAI_ANSWER_MODEL": configuration.modelID,
                "OPENAI_QUESTION_MODEL": configuration.modelID
            ]
        case "deepseek":
            return [
                "PROMPTMEET_AI_PROVIDER": "deepseek",
                "DEEPSEEK_ANSWER_MODEL": defaults.string(
                    forKey: AIProviderPreferenceKey.deepSeekAnswerModel
                ) ?? "deepseek-v4-pro",
                "DEEPSEEK_QUESTION_MODEL": "deepseek-v4-flash"
            ]
        default:
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
    }
}

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
    case invalidBaseURL
    case insecureBaseURL
    case emptyModel

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider): "不支持的 AI 提供方：\(provider)"
        case let .unsupportedModel(provider, model): "\(provider) 不支持模型 \(model)"
        case .emptySecret: "请输入 API Key"
        case .invalidBaseURL: "请输入有效的 OpenAI 兼容 Base URL"
        case .insecureBaseURL: "非本机 OpenAI 兼容服务必须使用 HTTPS"
        case .emptyModel: "请输入模型标识"
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

    func credential(providerID: String) throws -> String? {
        guard let provider = AIProviderCatalog.provider(id: providerID) else {
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
        return try keychain.read(
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

    func validate(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        secret: String
    ) async -> AIProviderValidationResult {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !trimmedSecret.isEmpty else {
                throw AIProviderConfigurationError.emptySecret
            }
            let normalizedModelID: String
            var request: URLRequest
            if providerID == "openai" {
                let configuration = try OpenAICompatibleConfiguration(
                    baseURL: baseURL ?? OpenAICompatibleConfiguration.defaultBaseURL,
                    modelID: modelID
                )
                normalizedModelID = configuration.modelID
                request = URLRequest(url: configuration.chatCompletionsURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": configuration.modelID,
                    "messages": [
                        ["role": "user", "content": "Reply with OK."]
                    ],
                    "stream": false
                ])
            } else {
                let configuration = try AIProviderCatalog.validated(
                    providerID: providerID,
                    modelID: modelID
                )
                normalizedModelID = configuration.model.id
                request = URLRequest(url: configuration.provider.validationURL)
            }
            request.timeoutInterval = 20
            request.setValue("Bearer \(trimmedSecret)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return AIProviderValidationResult(isValid: false, message: "提供方返回无效响应")
            }
            if (200..<300).contains(response.statusCode) {
                return AIProviderValidationResult(
                    isValid: true,
                    message: "连接成功，\(normalizedModelID) 可用"
                )
            }
            let providerMessage = Self.providerMessage(
                from: data,
                secret: trimmedSecret
            )
            let suffix = providerMessage.map { "：\($0)" } ?? ""
            return AIProviderValidationResult(
                isValid: false,
                message: "连接失败，提供方返回 \(response.statusCode)\(suffix)"
            )
        } catch {
            return AIProviderValidationResult(
                isValid: false,
                message: Self.redact(error.localizedDescription, secret: trimmedSecret)
            )
        }
    }

    private static func providerMessage(from data: Data, secret: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let message: String?
        if let object = json as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                message = error["message"] as? String
            } else if let error = object["error"] as? String {
                message = error
            } else {
                message = (object["message"] as? String) ?? (object["detail"] as? String)
            }
        } else {
            message = nil
        }
        guard let message else { return nil }
        let compact = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        guard !compact.isEmpty else { return nil }
        return redact(String(compact), secret: secret)
    }

    private static func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "••••••••")
    }
}
