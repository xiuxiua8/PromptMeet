import Foundation

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
