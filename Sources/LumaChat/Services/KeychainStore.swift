import Foundation

struct KeychainStore: Sendable {
    static let defaultService = "LumaChat.APIKeys"

    let service: String
    private let backend: any SecureStorageBackend

    init(
        service: String = KeychainStore.defaultService,
        backend: any SecureStorageBackend = SystemSecureStorageBackend()
    ) {
        self.service = service
        self.backend = backend
    }

    func saveAPIKey(_ apiKey: String, for settings: AppSettings) throws {
        try saveAPIKey(
            apiKey,
            provider: settings.provider,
            endpoint: settings.endpoint
        )
    }

    func loadAPIKey(for settings: AppSettings) throws -> String? {
        try loadAPIKey(provider: settings.provider, endpoint: settings.endpoint)
    }

    func deleteAPIKey(for settings: AppSettings) throws {
        try deleteAPIKey(provider: settings.provider, endpoint: settings.endpoint)
    }

    func saveAPIKey(_ apiKey: String, for profile: ConnectionProfile) throws {
        try saveAPIKey(apiKey, provider: profile.provider, endpoint: profile.endpoint)
    }

    func loadAPIKey(for profile: ConnectionProfile) throws -> String? {
        try loadAPIKey(provider: profile.provider, endpoint: profile.endpoint)
    }

    func deleteAPIKey(for profile: ConnectionProfile) throws {
        try deleteAPIKey(provider: profile.provider, endpoint: profile.endpoint)
    }

    func save(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidUTF8
        }

        try backend.save(data, service: service, account: account)
    }

    func load(account: String) throws -> String? {
        guard let data = try backend.load(service: service, account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainError.invalidUTF8 }
        return value
    }

    func delete(account: String) throws {
        try backend.delete(service: service, account: account)
    }

    static func account(for settings: AppSettings) -> String {
        account(provider: settings.provider, endpoint: settings.endpoint)
    }

    static func account(for profile: ConnectionProfile) -> String {
        account(provider: profile.provider, endpoint: profile.endpoint)
    }

    static func account(provider: ProviderKind, endpoint: String) -> String {
        let canonicalEndpoint = EndpointNormalizer.normalized(endpoint)
            ?? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(provider.rawValue)|\(canonicalEndpoint)"
    }

    private func saveAPIKey(
        _ apiKey: String,
        provider: ProviderKind,
        endpoint: String
    ) throws {
        let canonicalAccount = Self.account(provider: provider, endpoint: endpoint)
        let legacyAccount = Self.legacyAccount(provider: provider, endpoint: endpoint)

        if apiKey.isEmpty {
            try delete(account: canonicalAccount)
            if legacyAccount != canonicalAccount {
                try delete(account: legacyAccount)
            }
            return
        }

        try save(apiKey, account: canonicalAccount)
        if legacyAccount != canonicalAccount {
            try delete(account: legacyAccount)
        }
    }

    private func loadAPIKey(provider: ProviderKind, endpoint: String) throws -> String? {
        let canonicalAccount = Self.account(provider: provider, endpoint: endpoint)
        if let value = try load(account: canonicalAccount) {
            return value
        }

        let legacyAccount = Self.legacyAccount(provider: provider, endpoint: endpoint)
        guard legacyAccount != canonicalAccount,
              let value = try load(account: legacyAccount) else {
            return nil
        }

        // Copy first so an interrupted migration never loses the credential.
        try save(value, account: canonicalAccount)
        try delete(account: legacyAccount)
        return value
    }

    private func deleteAPIKey(provider: ProviderKind, endpoint: String) throws {
        let canonicalAccount = Self.account(provider: provider, endpoint: endpoint)
        let legacyAccount = Self.legacyAccount(provider: provider, endpoint: endpoint)

        try delete(account: canonicalAccount)
        if legacyAccount != canonicalAccount {
            try delete(account: legacyAccount)
        }
    }

    /// Reproduces the account spelling used before endpoint canonicalization so
    /// an existing credential can be migrated on first use.
    private static func legacyAccount(provider: ProviderKind, endpoint value: String) -> String {
        var endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while endpoint.count > 1, endpoint.hasSuffix("/") {
            endpoint.removeLast()
        }
        return "\(provider.rawValue)|\(endpoint)"
    }

}

enum KeychainError: LocalizedError, Sendable {
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "API Key 不是有效的 UTF-8 文字。"
        }
    }
}
