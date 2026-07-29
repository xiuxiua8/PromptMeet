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

    func testProviderModelPairingAndCapabilitiesAreExplicit() throws {
        let openAI = try AIProviderCatalog.validated(providerID: "openai", modelID: "gpt-4o")
        let deepSeek = try AIProviderCatalog.validated(
            providerID: "deepseek",
            modelID: "deepseek-v4-pro"
        )

        XCTAssertTrue(openAI.model.supportsVision)
        XCTAssertFalse(deepSeek.model.supportsVision)
        XCTAssertThrowsError(
            try AIProviderCatalog.validated(providerID: "deepseek", modelID: "gpt-4o")
        )
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

private final class AIProviderValidationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBodyData: Data?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBodyData = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class KeychainSpy: KeychainStoring {
    var containsResult = false
    var failOnRead = false
    var readCount = 0
    var containsCount = 0
    var writtenValues: [String] = []
    var deletedAccounts: [String] = []
    var readResult: String?

    func read(service: String, account: String) throws -> String? {
        readCount += 1
        if failOnRead { throw BackendClientError.serviceMessage("read must not be called") }
        return readResult
    }

    func contains(service: String, account: String) throws -> Bool {
        containsCount += 1
        return containsResult
    }

    func write(_ value: String, service: String, account: String) throws {
        writtenValues.append(value)
        readResult = value
        containsResult = true
    }

    func delete(service: String, account: String) throws {
        deletedAccounts.append(account)
        readResult = nil
        containsResult = false
    }
}
