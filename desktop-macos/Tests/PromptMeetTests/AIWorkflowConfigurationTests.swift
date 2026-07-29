import Foundation
import XCTest

@testable import PromptMeet

final class AIWorkflowConfigurationTests: XCTestCase {
    func testDeepSeekDefaultsUseEstablishedIdentifierAndAllowProviderScopedCustomModels() throws {
        let suiteName = "DeepSeekDefaultsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AIProviderPreferences(defaults: defaults)

        XCTAssertEqual(DeepSeekConfiguration.defaultModelID, "deepseek-chat")
        XCTAssertEqual(preferences.selection(for: .conversation).modelID, "deepseek-chat")
        XCTAssertEqual(preferences.selection(for: .suggestedQuestions).modelID, "deepseek-chat")

        try preferences.save(
            AIWorkflowSelection(
                providerID: "deepseek",
                modelID: "future-custom-id",
                supportsVision: false
            ),
            for: .conversation
        )
        XCTAssertEqual(preferences.selection(for: .conversation).modelID, "future-custom-id")

        let custom = try AIProviderCatalog.validated(
            providerID: "deepseek",
            modelID: "future-custom-id"
        )
        XCTAssertEqual(custom.model.id, "future-custom-id")
        XCTAssertFalse(custom.model.supportsVision)
    }

    func testWorkflowSelectionsMigrateLegacyProviderAndModelsThenPersistIndependently() throws {
        let suiteName = "AIWorkflowMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("openai", forKey: AIProviderPreferenceKey.provider)
        defaults.set("legacy-proxy-model", forKey: AIProviderPreferenceKey.openAIModel)
        let preferences = AIProviderPreferences(defaults: defaults)

        let migrated = preferences.selection(for: .conversation)
        XCTAssertEqual(migrated.providerID, "openai")
        XCTAssertEqual(migrated.modelID, "legacy-proxy-model")

        try preferences.save(
            AIWorkflowSelection(
                providerID: "deepseek",
                modelID: "deepseek-summary",
                supportsVision: false
            ),
            for: .summariesAndTasks
        )

        XCTAssertEqual(preferences.selection(for: .conversation).modelID, "legacy-proxy-model")
        XCTAssertEqual(preferences.selection(for: .summariesAndTasks).modelID, "deepseek-summary")
    }

    func testRuntimeEnvironmentInventoriesEveryWorkflowWithoutSecrets() throws {
        let suiteName = "AIWorkflowRuntimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AIProviderPreferences(defaults: defaults)
        try saveWorkflowSelections(to: preferences)

        let environment = try preferences.runtimeEnvironment()

        XCTAssertEqual(environment["PROMPTMEET_ANSWER_MODEL"], "answer-model")
        XCTAssertEqual(environment["PROMPTMEET_QUESTION_MODEL"], "deepseek-question")
        XCTAssertEqual(environment["PROMPTMEET_SUMMARY_MODEL"], "summary-model")
        XCTAssertEqual(environment["PROMPTMEET_SCREENSHOT_MODEL"], "vision-model")
        XCTAssertEqual(environment["PROMPTMEET_TRANSLATION_MODEL"], "translation-model")
        XCTAssertEqual(environment["PROMPTMEET_SCREENSHOT_SUPPORTS_VISION"], "1")
        XCTAssertFalse(environment.keys.contains { $0.contains("API_KEY") })
    }

    func testDeepSeekEndpointIsNormalizedAndRejectsUnsafeRemoteHTTP() throws {
        let normalized = try DeepSeekConfiguration(
            baseURL: "https://api.deepseek.com/v1/",
            modelID: "deepseek-chat"
        )
        XCTAssertEqual(normalized.baseURL.absoluteString, "https://api.deepseek.com/v1")
        XCTAssertEqual(
            normalized.chatCompletionsURL.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
        XCTAssertThrowsError(
            try DeepSeekConfiguration(
                baseURL: "http://api.deepseek.com/v1",
                modelID: "deepseek-chat"
            )
        )
    }

    private func saveWorkflowSelections(to preferences: AIProviderPreferences) throws {
        let selections: [(AIWorkflow, AIWorkflowSelection)] = [
            (.conversation, .init(providerID: "openai", modelID: "answer-model", supportsVision: true)),
            (
                .suggestedQuestions,
                .init(providerID: "deepseek", modelID: "deepseek-question", supportsVision: false)
            ),
            (
                .summariesAndTasks,
                .init(providerID: "openai", modelID: "summary-model", supportsVision: false)
            ),
            (
                .screenshotAnalysis,
                .init(providerID: "openai", modelID: "vision-model", supportsVision: true)
            ),
            (
                .translation,
                .init(providerID: "deepseek", modelID: "translation-model", supportsVision: false)
            )
        ]
        for (workflow, selection) in selections {
            try preferences.save(selection, for: workflow)
        }
    }
}
