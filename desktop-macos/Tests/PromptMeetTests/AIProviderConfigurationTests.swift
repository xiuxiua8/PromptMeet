import Foundation
import XCTest
@testable import PromptMeet

final class AIProviderConfigurationTests: XCTestCase {
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

private final class KeychainSpy: KeychainStoring {
    var containsResult = false
    var failOnRead = false
    var readCount = 0
    var containsCount = 0
    var writtenValues: [String] = []
    var deletedAccounts: [String] = []

    func read(service: String, account: String) throws -> String? {
        readCount += 1
        if failOnRead { throw BackendClientError.serviceMessage("read must not be called") }
        return nil
    }

    func contains(service: String, account: String) throws -> Bool {
        containsCount += 1
        return containsResult
    }

    func write(_ value: String, service: String, account: String) throws {
        writtenValues.append(value)
    }

    func delete(service: String, account: String) throws {
        deletedAccounts.append(account)
    }
}
