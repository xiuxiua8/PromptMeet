import Foundation
import XCTest
@testable import PromptMeet

final class AIProviderConfigurationTests: XCTestCase {
    func testOpenAICompatibleConfigurationNormalizesOfficialHTTPSAndModel() throws {
        let configuration = try OpenAICompatibleConfiguration(
            baseURL: "  https://api.openai.com/v1/  ",
            modelID: "  gpt-4o  "
        )

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(configuration.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(configuration.modelID, "gpt-4o")
    }

    func testOpenAICompatibleConfigurationAcceptsHTTPForExactLoopbackHosts() throws {
        let inputsAndExpected = [
            ("http://localhost:52251/v1/", "http://localhost:52251/v1/chat/completions"),
            ("http://127.0.0.1:52251/v1//", "http://127.0.0.1:52251/v1/chat/completions"),
            ("http://[::1]:52251/v1/", "http://[::1]:52251/v1/chat/completions")
        ]

        for (input, expected) in inputsAndExpected {
            let configuration = try OpenAICompatibleConfiguration(
                baseURL: input,
                modelID: "local/model:latest"
            )
            XCTAssertEqual(configuration.chatCompletionsURL.absoluteString, expected)
        }
    }

    func testOpenAICompatibleConfigurationRejectsUnsafeOrAmbiguousURLs() {
        let rejected = [
            "http://proxy.example/v1",
            "http://127.0.0.2/v1",
            "ftp://localhost/v1",
            "https://user:password@proxy.example/v1",
            "https://proxy.example/v1?route=other",
            "https://proxy.example/v1#fragment",
            "https:///v1"
        ]

        for input in rejected {
            XCTAssertThrowsError(
                try OpenAICompatibleConfiguration(baseURL: input, modelID: "model"),
                "Expected rejection for \(input)"
            )
        }
    }

    func testOpenAICompatibleConfigurationRequiresNonEmptyModelIdentifier() {
        XCTAssertThrowsError(
            try OpenAICompatibleConfiguration(
                baseURL: OpenAICompatibleConfiguration.defaultBaseURL,
                modelID: "  \n  "
            )
        )
    }

    func testOpenAIPreferencesDefaultMissingBaseAndPreserveLegacySavedModel() throws {
        let suiteName = "AIProviderPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("captain-proxy-model", forKey: AIProviderPreferenceKey.openAIModel)

        let preferences = AIProviderPreferences(defaults: defaults)
        let configuration = try preferences.loadOpenAICompatible()

        XCTAssertEqual(configuration.baseURL.absoluteString, OpenAICompatibleConfiguration.defaultBaseURL)
        XCTAssertEqual(configuration.modelID, "captain-proxy-model")
    }

    func testOpenAIPreferencesPersistOnlyNormalizedNonSecretValues() throws {
        let suiteName = "AIProviderPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AIProviderPreferences(defaults: defaults)
        let configuration = try OpenAICompatibleConfiguration(
            baseURL: "http://localhost:52251/v1/",
            modelID: " proxy-model "
        )

        preferences.saveOpenAICompatible(configuration)

        XCTAssertEqual(defaults.string(forKey: AIProviderPreferenceKey.openAIBaseURL), "http://localhost:52251/v1")
        XCTAssertEqual(defaults.string(forKey: AIProviderPreferenceKey.openAIModel), "proxy-model")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("secret")
        })
    }

    func testOpenAIPreferencesReloadSavedValuesThroughFreshDefaultsInstance() throws {
        let suiteName = "AIProviderPreferencesRelaunchTests-\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { firstDefaults.removePersistentDomain(forName: suiteName) }
        let saved = try OpenAICompatibleConfiguration(
            baseURL: "http://127.0.0.1:52252/v1/",
            modelID: "lane-local-model"
        )

        AIProviderPreferences(defaults: firstDefaults).saveOpenAICompatible(saved)
        let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let reloaded = try AIProviderPreferences(defaults: reloadedDefaults)
            .loadOpenAICompatible()

        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.baseURL.absoluteString, "http://127.0.0.1:52252/v1")
        XCTAssertEqual(reloaded.modelID, "lane-local-model")
    }

    func testOpenAIKeychainCredentialAndPreferencesSurviveFreshManagers() throws {
        let keychain = KeychainSpy()
        let suiteName = "AIProviderRelaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = try OpenAICompatibleConfiguration(
            baseURL: "http://localhost:52252/v1/",
            modelID: "relaunch-model"
        )
        let firstSecretManager = AIProviderSecretManager(
            keychain: keychain,
            defaults: defaults
        )
        try firstSecretManager.save(
            providerID: "openai",
            secret: "placeholder-relaunch-key"
        )
        AIProviderPreferences(defaults: defaults).saveOpenAICompatible(configuration)

        let freshSecretManager = AIProviderSecretManager(
            keychain: keychain,
            defaults: defaults
        )
        let freshPreferences = AIProviderPreferences(defaults: defaults)

        XCTAssertEqual(try freshSecretManager.status(providerID: "openai"), .configured)
        XCTAssertEqual(
            try freshSecretManager.credential(providerID: "openai"),
            "placeholder-relaunch-key"
        )
        XCTAssertEqual(try freshPreferences.loadOpenAICompatible(), configuration)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("placeholder-relaunch-key")
        })
    }
}

extension AIProviderConfigurationTests {
    func testOpenAIValidationPostsConfiguredChatEndpointAndModel() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIProviderValidationURLProtocol.self]
        AIProviderValidationURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        let validator = AIProviderConnectionValidator(
            session: URLSession(configuration: sessionConfiguration)
        )

        let result = await validator.validate(
            providerID: "openai",
            modelID: "captain-proxy-model",
            baseURL: "http://127.0.0.1:52251/v1/",
            secret: "placeholder-key"
        )

        let request = try XCTUnwrap(AIProviderValidationURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:52251/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer placeholder-key")
        let body = try XCTUnwrap(AIProviderValidationURLProtocol.lastBodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "captain-proxy-model")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.message.contains("captain-proxy-model"))
        XCTAssertFalse(result.message.contains("placeholder-key"))
    }

    func testOpenAIValidationSurfacesUsefulProviderErrorWithCredentialRedacted() async {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIProviderValidationURLProtocol.self]
        AIProviderValidationURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"error":{"message":"model unavailable for placeholder-key"}}"#
            return (response, body.data(using: .utf8)!)
        }
        let validator = AIProviderConnectionValidator(
            session: URLSession(configuration: sessionConfiguration)
        )

        let result = await validator.validate(
            providerID: "openai",
            modelID: "missing-model",
            baseURL: "http://localhost:52251/v1",
            secret: "placeholder-key"
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.message.contains("model unavailable"))
        XCTAssertFalse(result.message.contains("placeholder-key"))
    }

    func testOpenAIValidationRejectsUnsafeBaseBeforeSendingCredential() async {
        AIProviderValidationURLProtocol.lastRequest = nil
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIProviderValidationURLProtocol.self]
        let validator = AIProviderConnectionValidator(
            session: URLSession(configuration: sessionConfiguration)
        )

        let result = await validator.validate(
            providerID: "openai",
            modelID: "model",
            baseURL: "http://proxy.example/v1",
            secret: "placeholder-key"
        )

        XCTAssertFalse(result.isValid)
        XCTAssertNil(AIProviderValidationURLProtocol.lastRequest)
        XCTAssertFalse(result.message.contains("placeholder-key"))
    }

    func testDeepSeekValidationUsesConfiguredEndpointCustomModelAndWorkflowLabel() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIProviderValidationURLProtocol.self]
        AIProviderValidationURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        }
        let validator = AIProviderConnectionValidator(
            session: URLSession(configuration: sessionConfiguration)
        )

        let result = await validator.validate(
            workflow: .summariesAndTasks,
            providerID: "deepseek",
            modelID: "future-custom-id",
            baseURL: "https://deepseek-proxy.example/v1/",
            secret: "deepseek-placeholder-key"
        )

        let request = try XCTUnwrap(AIProviderValidationURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://deepseek-proxy.example/v1/chat/completions")
        let body = try XCTUnwrap(AIProviderValidationURLProtocol.lastBodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "future-custom-id")
        XCTAssertTrue(result.message.contains("摘要与待办"))
        XCTAssertTrue(result.message.contains("DeepSeek"))
        XCTAssertTrue(result.message.contains("future-custom-id"))
        XCTAssertFalse(result.message.contains("deepseek-placeholder-key"))
    }

    func testProviderModelPairingAndCapabilitiesAreExplicit() throws {
        let openAI = try AIProviderCatalog.validated(providerID: "openai", modelID: "gpt-4o")
        let deepSeek = try AIProviderCatalog.validated(
            providerID: "deepseek",
            modelID: "deepseek-chat"
        )

        XCTAssertTrue(openAI.model.supportsVision)
        XCTAssertFalse(deepSeek.model.supportsVision)
        XCTAssertFalse(deepSeek.model.id.isEmpty)
    }

    func testOpenAIProviderIsClearlyLabeledCompatible() throws {
        let provider = try XCTUnwrap(AIProviderCatalog.provider(id: "openai"))

        XCTAssertEqual(provider.displayName, "OpenAI 兼容")
    }

    func testExplicitCredentialAccessReadsKeychainWithoutPersistingSecret() throws {
        let keychain = KeychainSpy()
        keychain.readResult = "stored-placeholder-key"
        let suiteName = "AIProviderCredentialTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AIProviderSecretManager(keychain: keychain, defaults: defaults)

        let credential = try manager.credential(providerID: "openai")

        XCTAssertEqual(credential, "stored-placeholder-key")
        XCTAssertEqual(keychain.readCount, 1)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("stored-placeholder-key")
        })
        XCTAssertFalse(String(describing: manager).contains("stored-placeholder-key"))
    }

    func testSavingSecretTrimsItAndNeverWritesItToUserDefaults() throws {
        let keychain = KeychainSpy()
        let suiteName = "AIProviderConfigurationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AIProviderSecretManager(keychain: keychain, defaults: defaults)

        try manager.save(providerID: "openai", secret: "  secret-value  ")

        XCTAssertEqual(keychain.writtenValues, ["secret-value"])
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("secret-value")
        })
        XCTAssertFalse(String(describing: manager).contains("secret-value"))
    }

    func testConfiguredStatusChecksMetadataWithoutReadingSecretValue() throws {
        let keychain = KeychainSpy()
        keychain.containsResult = true
        keychain.failOnRead = true
        let manager = AIProviderSecretManager(keychain: keychain)

        let status = try manager.status(providerID: "deepseek")

        XCTAssertEqual(status, .configured)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertEqual(keychain.containsCount, 1)
    }

    func testRemovingProviderSecretUsesKeychainDelete() throws {
        let keychain = KeychainSpy()
        let manager = AIProviderSecretManager(keychain: keychain)

        try manager.remove(providerID: "openai")

        XCTAssertEqual(keychain.deletedAccounts, ["OPENAI_API_KEY"])
    }
}
