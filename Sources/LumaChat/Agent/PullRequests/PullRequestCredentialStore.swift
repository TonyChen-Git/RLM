import Foundation

/// Provider-agnostic credential storage seam for Pull Request integrations.
/// Callers can depend on this protocol without learning how secrets are stored.
protocol PullRequestCredentialStorage: Sendable {
    func saveToken(
        _ token: String,
        configuration: PullRequestProviderConfiguration
    ) throws

    func loadToken(
        configuration: PullRequestProviderConfiguration
    ) throws -> String?

    func deleteToken(
        configuration: PullRequestProviderConfiguration
    ) throws
}

/// Narrow secure-storage seam used to test credential lifecycle behavior
/// without reading or writing the user's Keychain.
protocol PullRequestCredentialSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

private struct PullRequestKeychainSecretStore: PullRequestCredentialSecretStore {
    let keychain: KeychainStore

    func save(_ value: String, account: String) throws {
        try keychain.save(value, account: account)
    }

    func load(account: String) throws -> String? {
        try keychain.load(account: account)
    }

    func delete(account: String) throws {
        try keychain.delete(account: account)
    }
}

/// Pull Request credentials share the App's Keychain service but use a
/// provider-specific account namespace. Provider configuration is non-secret;
/// the token itself never enters Settings JSON or Agent/model context.
struct PullRequestCredentialStore: PullRequestCredentialStorage, Sendable {
    static let maximumTokenBytes = 4_096

    private let secretStore: any PullRequestCredentialSecretStore

    init(keychain: KeychainStore = KeychainStore()) {
        secretStore = PullRequestKeychainSecretStore(keychain: keychain)
    }

    init(secretStore: any PullRequestCredentialSecretStore) {
        self.secretStore = secretStore
    }

    func saveToken(
        _ token: String,
        configuration: PullRequestProviderConfiguration
    ) throws {
        let account = try Self.account(configuration: configuration)
        let normalized = try Self.normalizedToken(token)
        try secretStore.save(normalized, account: account)
    }

    func loadToken(
        configuration: PullRequestProviderConfiguration
    ) throws -> String? {
        guard let token = try secretStore.load(
            account: Self.account(configuration: configuration)
        ) else {
            return nil
        }
        return try Self.normalizedToken(token)
    }

    func deleteToken(
        configuration: PullRequestProviderConfiguration
    ) throws {
        try secretStore.delete(account: Self.account(configuration: configuration))
    }

    /// Trims common copy/paste padding while rejecting blank, embedded
    /// whitespace, control characters (including NUL), and oversized secrets.
    /// Error details intentionally never contain any portion of the token.
    static func normalizedToken(_ token: String) throws -> String {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count >= 4 else {
            throw PullRequestProviderError.invalidRequest(
                "credential token must contain at least 4 bytes"
            )
        }
        guard normalized.utf8.count <= maximumTokenBytes else {
            throw PullRequestProviderError.invalidRequest(
                "credential token exceeds the 4096-byte limit"
            )
        }
        guard normalized.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }) else {
            throw PullRequestProviderError.invalidRequest(
                "credential token contains whitespace or control characters"
            )
        }
        return normalized
    }

    static func account(
        configuration: PullRequestProviderConfiguration
    ) throws -> String {
        let normalized = try configuration.normalized()
        return "pull-request|\(normalized.providerID)|\(normalized.apiEndpoint)"
    }

    static func apiBaseURL(
        configuration: PullRequestProviderConfiguration
    ) throws -> URL {
        let normalized = try configuration.normalized()
        guard let url = URL(
            string: normalized.apiEndpoint,
            encodingInvalidCharacters: false
        ) else {
            throw PullRequestProviderError.invalidEndpoint
        }
        return url
    }
}
