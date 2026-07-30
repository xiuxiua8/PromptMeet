import Foundation

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

    func loadDeepSeek() throws -> DeepSeekConfiguration {
        try DeepSeekConfiguration(
            baseURL: defaults.string(forKey: AIProviderPreferenceKey.deepSeekBaseURL)
                ?? DeepSeekConfiguration.defaultBaseURL,
            modelID: defaults.string(forKey: AIProviderPreferenceKey.deepSeekAnswerModel)
                ?? DeepSeekConfiguration.defaultModelID
        )
    }

    func saveDeepSeek(_ configuration: DeepSeekConfiguration) {
        defaults.set(configuration.baseURL.absoluteString, forKey: AIProviderPreferenceKey.deepSeekBaseURL)
        defaults.set(configuration.modelID, forKey: AIProviderPreferenceKey.deepSeekAnswerModel)
    }

    func selection(for workflow: AIWorkflow) -> AIWorkflowSelection {
        let keys = workflow.preferenceKeys
        if let provider = defaults.string(forKey: keys.provider),
            let model = defaults.string(forKey: keys.model)
        {
            let vision =
                defaults.object(forKey: keys.vision) == nil
                ? Self.inferredVision(
                    providerID: provider,
                    modelID: model,
                    workflow: workflow
                )
                : defaults.bool(forKey: keys.vision)
            return AIWorkflowSelection(
                providerID: provider,
                modelID: model,
                supportsVision: provider == "openai" && vision
            )
        }

        let legacyProvider = defaults.string(forKey: AIProviderPreferenceKey.provider) ?? "deepseek"
        let model: String
        if legacyProvider == "openai" {
            model =
                defaults.string(forKey: AIProviderPreferenceKey.openAIModel)
                ?? OpenAICompatibleConfiguration.defaultModelID
        } else {
            model =
                defaults.string(forKey: AIProviderPreferenceKey.deepSeekAnswerModel)
                ?? DeepSeekConfiguration.defaultModelID
        }
        let migrated = AIWorkflowSelection(
            providerID: legacyProvider,
            modelID: model,
            supportsVision: Self.inferredVision(
                providerID: legacyProvider,
                modelID: model,
                workflow: workflow
            )
        )
        defaults.set(migrated.providerID, forKey: keys.provider)
        defaults.set(migrated.modelID, forKey: keys.model)
        defaults.set(migrated.supportsVision, forKey: keys.vision)
        return migrated
    }

    func save(_ selection: AIWorkflowSelection, for workflow: AIWorkflow) throws {
        guard AIProviderCatalog.provider(id: selection.providerID) != nil else {
            throw AIProviderConfigurationError.unsupportedProvider(selection.providerID)
        }
        let model = selection.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIProviderConfigurationError.emptyModel }
        let keys = workflow.preferenceKeys
        defaults.set(selection.providerID, forKey: keys.provider)
        defaults.set(model, forKey: keys.model)
        defaults.set(selection.providerID == "openai" && selection.supportsVision, forKey: keys.vision)
    }

    func runtimeEnvironment() throws -> [String: String] {
        let openAI = try loadOpenAICompatible()
        let deepSeek = try loadDeepSeek()
        var environment = [
            "OPENAI_API_BASE": openAI.baseURL.absoluteString,
            "DEEPSEEK_API_BASE": deepSeek.baseURL.absoluteString,
        ]
        for workflow in AIWorkflow.allCases {
            let selection = selection(for: workflow)
            let prefix = "PROMPTMEET_\(workflow.environmentPrefix)"
            environment["\(prefix)_PROVIDER"] = selection.providerID
            environment["\(prefix)_MODEL"] = selection.modelID
            environment["\(prefix)_SUPPORTS_VISION"] = selection.supportsVision ? "1" : "0"
        }
        return environment
    }

    func runtimeEnvironment(providerID: String) throws -> [String: String] {
        switch providerID {
        case "openai":
            let configuration = try loadOpenAICompatible()
            return [
                "PROMPTMEET_AI_PROVIDER": "openai",
                "OPENAI_API_BASE": configuration.baseURL.absoluteString,
                "OPENAI_ANSWER_MODEL": configuration.modelID,
                "OPENAI_QUESTION_MODEL": configuration.modelID,
            ]
        case "deepseek":
            let configuration = try loadDeepSeek()
            return [
                "PROMPTMEET_AI_PROVIDER": "deepseek",
                "DEEPSEEK_ANSWER_MODEL": configuration.modelID,
                "DEEPSEEK_QUESTION_MODEL": configuration.modelID,
            ]
        default:
            throw AIProviderConfigurationError.unsupportedProvider(providerID)
        }
    }

    private static func inferredVision(
        providerID: String,
        modelID: String,
        workflow: AIWorkflow
    ) -> Bool {
        guard providerID == "openai" else { return false }
        if workflow == .screenshotAnalysis { return true }
        let knownVisionPrefixes = ["gpt-4o", "gpt-4.1", "o3", "o4"]
        return knownVisionPrefixes.contains { modelID.lowercased().hasPrefix($0) }
    }
}
