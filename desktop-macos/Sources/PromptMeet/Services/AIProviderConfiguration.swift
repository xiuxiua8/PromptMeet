import Foundation

enum AIProviderPreferenceKey {
    static let provider = "aiProvider"
    static let deepSeekAnswerModel = "deepSeekAnswerModel"
    static let deepSeekBaseURL = "deepSeekBaseURL"
    static let openAIBaseURL = "openAIBaseURL"
    static let openAIModel = "openAIAnswerModel"
    static let conversationProvider = "aiWorkflow.conversation.provider"
    static let conversationModel = "aiWorkflow.conversation.model"
    static let conversationVision = "aiWorkflow.conversation.supportsVision"
    static let suggestedQuestionsProvider = "aiWorkflow.suggestedQuestions.provider"
    static let suggestedQuestionsModel = "aiWorkflow.suggestedQuestions.model"
    static let suggestedQuestionsVision = "aiWorkflow.suggestedQuestions.supportsVision"
    static let summariesAndTasksProvider = "aiWorkflow.summariesAndTasks.provider"
    static let summariesAndTasksModel = "aiWorkflow.summariesAndTasks.model"
    static let summariesAndTasksVision = "aiWorkflow.summariesAndTasks.supportsVision"
    static let screenshotAnalysisProvider = "aiWorkflow.screenshotAnalysis.provider"
    static let screenshotAnalysisModel = "aiWorkflow.screenshotAnalysis.model"
    static let screenshotAnalysisVision = "aiWorkflow.screenshotAnalysis.supportsVision"
    static let translationProvider = "aiWorkflow.translation.provider"
    static let translationModel = "aiWorkflow.translation.model"
    static let translationVision = "aiWorkflow.translation.supportsVision"
}

enum AIWorkflow: String, CaseIterable, Identifiable, Codable, Sendable {
    case conversation
    case suggestedQuestions
    case summariesAndTasks
    case screenshotAnalysis
    case translation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conversation: "对话回答"
        case .suggestedQuestions: "猜你想问"
        case .summariesAndTasks: "摘要与待办"
        case .screenshotAnalysis: "截图分析"
        case .translation: "实时翻译"
        }
    }

    var environmentPrefix: String {
        switch self {
        case .conversation: "ANSWER"
        case .suggestedQuestions: "QUESTION"
        case .summariesAndTasks: "SUMMARY"
        case .screenshotAnalysis: "SCREENSHOT"
        case .translation: "TRANSLATION"
        }
    }

    var preferenceKeys: AIWorkflowPreferenceKeys {
        switch self {
        case .conversation:
            AIWorkflowPreferenceKeys(
                provider: AIProviderPreferenceKey.conversationProvider,
                model: AIProviderPreferenceKey.conversationModel,
                vision: AIProviderPreferenceKey.conversationVision
            )
        case .suggestedQuestions:
            AIWorkflowPreferenceKeys(
                provider: AIProviderPreferenceKey.suggestedQuestionsProvider,
                model: AIProviderPreferenceKey.suggestedQuestionsModel,
                vision: AIProviderPreferenceKey.suggestedQuestionsVision
            )
        case .summariesAndTasks:
            AIWorkflowPreferenceKeys(
                provider: AIProviderPreferenceKey.summariesAndTasksProvider,
                model: AIProviderPreferenceKey.summariesAndTasksModel,
                vision: AIProviderPreferenceKey.summariesAndTasksVision
            )
        case .screenshotAnalysis:
            AIWorkflowPreferenceKeys(
                provider: AIProviderPreferenceKey.screenshotAnalysisProvider,
                model: AIProviderPreferenceKey.screenshotAnalysisModel,
                vision: AIProviderPreferenceKey.screenshotAnalysisVision
            )
        case .translation:
            AIWorkflowPreferenceKeys(
                provider: AIProviderPreferenceKey.translationProvider,
                model: AIProviderPreferenceKey.translationModel,
                vision: AIProviderPreferenceKey.translationVision
            )
        }
    }
}

struct AIWorkflowSelection: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let supportsVision: Bool
}

struct AIWorkflowPreferenceKeys {
    let provider: String
    let model: String
    let vision: String
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

struct DeepSeekConfiguration: Equatable, Sendable {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModelID = "deepseek-chat"

    let baseURL: URL
    let modelID: String

    init(baseURL: String, modelID: String) throws {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBaseURL),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AIProviderConfigurationError.invalidDeepSeekBaseURL
        }
        components.scheme = "https"
        while components.percentEncodedPath.count > 1,
              components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }
        guard let normalizedURL = components.url else {
            throw AIProviderConfigurationError.invalidDeepSeekBaseURL
        }
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { throw AIProviderConfigurationError.emptyModel }
        self.baseURL = normalizedURL
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

enum AIProviderConfigurationError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case unsupportedModel(provider: String, model: String)
    case emptySecret
    case invalidBaseURL
    case insecureBaseURL
    case emptyModel
    case invalidDeepSeekBaseURL

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider): "不支持的 AI 提供方：\(provider)"
        case let .unsupportedModel(provider, model): "\(provider) 不支持模型 \(model)"
        case .emptySecret: "请输入 API Key"
        case .invalidBaseURL: "请输入有效的 OpenAI 兼容 Base URL"
        case .insecureBaseURL: "非本机 OpenAI 兼容服务必须使用 HTTPS"
        case .emptyModel: "请输入模型标识"
        case .invalidDeepSeekBaseURL: "请输入有效且安全的 DeepSeek HTTPS Base URL"
        }
    }
}
