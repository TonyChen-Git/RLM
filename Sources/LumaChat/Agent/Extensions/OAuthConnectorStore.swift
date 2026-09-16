import CryptoKit
import Foundation
import Security

struct OAuthAuthorizationRequest: Equatable, Sendable {
    var url: URL
    var state: String
    var codeVerifier: String
}

protocol OAuthCredentialStoring: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

struct OAuthKeychainCredentialStore: OAuthCredentialStoring {
    private let keychain = KeychainStore(service: "LumaChat.OAuthConnectors")

    func save(_ value: String, account: String) throws { try keychain.save(value, account: account) }
    func load(account: String) throws -> String? { try keychain.load(account: account) }
    func delete(account: String) throws { try keychain.delete(account: account) }
}

actor OAuthConnectorStore {
    private struct PendingAuthorization: Sendable {
        var state: String
        var verifierDigest: Data
        var configuration: OAuthConnectorConfiguration
        var expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    private struct StoredCredential: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var tokenType: String
    }

    static let maximumConnectors = 64
    static let maximumSettingsBytes = 1 * 1_024 * 1_024

    private let fileURL: URL
    private let secretStore: any OAuthCredentialStoring
    private let session: URLSession
    private var configurations: [OAuthConnectorConfiguration] = []
    private var pendingAuthorizations: [UUID: PendingAuthorization] = [:]
    private var activeExchanges: [UUID: UUID] = [:]

    init(
        fileURL: URL = AppPaths.oauthConnectorsFile,
        secretStore: any OAuthCredentialStoring = OAuthKeychainCredentialStore(),
        session: URLSession? = nil
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func load() throws -> [OAuthConnectorConfiguration] {
        pendingAuthorizations = [:]
        activeExchanges = [:]
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            configurations = []
            return []
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumSettingsBytes else {
            throw ExtensionSubsystemError.sizeLimit("OAuth connector settings 超過 1 MiB")
        }
        let decoded = try JSONDecoder().decode([OAuthConnectorConfiguration].self, from: data)
        guard decoded.count <= Self.maximumConnectors else {
            throw ExtensionSubsystemError.sizeLimit("OAuth connector 超過 64 組")
        }
        var seen: Set<UUID> = []
        configurations = try decoded.compactMap { configuration in
            guard seen.insert(configuration.id).inserted else { return nil }
            try Self.validate(configuration)
            return configuration
        }
        return configurations
    }

    func save(_ configuration: OAuthConnectorConfiguration) throws -> [OAuthConnectorConfiguration] {
        var configuration = configuration
        try Self.validate(configuration)
        guard configurations.contains(where: { $0.id == configuration.id })
                || configurations.count < Self.maximumConnectors else {
            throw ExtensionSubsystemError.sizeLimit("OAuth connector 超過 64 組")
        }
        let account = Self.credentialAccount(configuration.id)
        let credentialExists = try secretStore.load(account: account) != nil
        if let existing = configurations.first(where: { $0.id == configuration.id }),
           !Self.hasSameAuthorizationBinding(existing, configuration) {
            if credentialExists {
                throw ExtensionSubsystemError.invalidConnector(
                    "請先中斷連線，再修改 OAuth endpoint、client、scope 或 redirect URI"
                )
            }
            pendingAuthorizations.removeValue(forKey: configuration.id)
            activeExchanges.removeValue(forKey: configuration.id)
        }
        if !credentialExists {
            configuration.connectedAt = nil
            configuration.accountLabel = nil
        }
        let previous = configurations
        configurations.removeAll { $0.id == configuration.id }
        configurations.append(configuration)
        do { try persist() } catch {
            configurations = previous
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    func setEnabled(
        _ enabled: Bool,
        id: UUID
    ) throws -> [OAuthConnectorConfiguration] {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else {
            throw ExtensionSubsystemError.invalidConnector("找不到 connector")
        }
        let previous = configurations
        configurations[index].enabled = enabled
        if !enabled {
            pendingAuthorizations.removeValue(forKey: id)
            activeExchanges.removeValue(forKey: id)
        }
        do { try persist() } catch {
            configurations = previous
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    func authorizationRequest(
        for id: UUID,
        state: String? = nil
    ) throws -> OAuthAuthorizationRequest {
        guard let configuration = configurations.first(where: { $0.id == id }),
              configuration.enabled else {
            throw ExtensionSubsystemError.invalidConnector("Connector 不存在或已停用")
        }
        let state = try state ?? Self.randomURLSafeString(byteCount: 24)
        guard Self.isBoundedOpaqueValue(state, maximumBytes: 512) else {
            throw ExtensionSubsystemError.invalidConnector("OAuth state 無效")
        }
        let verifier = try Self.randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        let reservedNames: Set<String> = [
            "response_type", "client_id", "redirect_uri", "scope", "state",
            "code_challenge", "code_challenge_method"
        ]
        var items = (components?.queryItems ?? []).filter {
            !reservedNames.contains($0.name.lowercased())
        }
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ])
        components?.queryItems = items
        guard let url = components?.url else {
            throw ExtensionSubsystemError.invalidConnector("無法建立 authorization URL")
        }
        activeExchanges.removeValue(forKey: id)
        pendingAuthorizations[id] = PendingAuthorization(
            state: state,
            verifierDigest: Data(SHA256.hash(data: Data(verifier.utf8))),
            configuration: configuration,
            expiresAt: Date().addingTimeInterval(10 * 60)
        )
        return OAuthAuthorizationRequest(url: url, state: state, codeVerifier: verifier)
    }

    func exchangeAuthorizationCode(
        connectorID: UUID,
        code: String,
        codeVerifier: String,
        state: String,
        accountLabel: String? = nil
    ) async throws -> [OAuthConnectorConfiguration] {
        guard var configuration = configurations.first(where: { $0.id == connectorID }),
              configuration.enabled else {
            throw ExtensionSubsystemError.invalidConnector("Connector 不存在或已停用")
        }
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVerifier = codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedState = state
        guard let pending = pendingAuthorizations.removeValue(forKey: connectorID),
              pending.expiresAt > Date(),
              pending.state == normalizedState,
              Self.hasSameAuthorizationBinding(pending.configuration, configuration),
              pending.verifierDigest == Data(SHA256.hash(data: Data(normalizedVerifier.utf8))),
              Self.isBoundedOpaqueValue(normalizedState, maximumBytes: 512),
              Self.isBoundedOpaqueValue(normalizedCode, maximumBytes: 8_192),
              (43...128).contains(normalizedVerifier.utf8.count),
              normalizedVerifier.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                    .contains($0)
              }) else {
            throw ExtensionSubsystemError.invalidConnector("Authorization code/PKCE verifier 無效")
        }
        let exchangeID = UUID()
        activeExchanges[connectorID] = exchangeID
        defer {
            if activeExchanges[connectorID] == exchangeID {
                activeExchanges.removeValue(forKey: connectorID)
            }
        }
        var request = URLRequest(url: configuration.tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded([
            "grant_type": "authorization_code",
            "code": normalizedCode,
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": normalizedVerifier
        ])
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1 * 1_024 * 1_024,
              let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              (200..<300).contains(http.statusCode) else {
            throw ExtensionSubsystemError.invalidConnector("Token endpoint 回應失敗")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let tokenType = token.tokenType ?? "Bearer"
        guard Self.isBoundedOpaqueValue(token.accessToken, maximumBytes: 64 * 1_024),
              token.refreshToken.map({
                Self.isBoundedOpaqueValue($0, maximumBytes: 64 * 1_024)
              }) ?? true,
              tokenType.range(
                of: #"^[A-Za-z][A-Za-z0-9._-]{0,31}$"#,
                options: .regularExpression
              ) != nil else {
            throw ExtensionSubsystemError.invalidConnector("Token endpoint 未回傳安全的 access token")
        }
        guard activeExchanges[connectorID] == exchangeID,
              let current = configurations.first(where: { $0.id == connectorID }),
              current.enabled,
              Self.hasSameAuthorizationBinding(current, configuration) else {
            throw ExtensionSubsystemError.invalidConnector(
                "OAuth 交換期間 connector 已變更或中斷"
            )
        }
        configuration = current
        let credential = StoredCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.flatMap { seconds in
                guard seconds.isFinite, seconds > 0 else { return nil }
                return Date().addingTimeInterval(min(seconds, 10 * 365 * 24 * 60 * 60))
            },
            tokenType: tokenType
        )
        let encoded = try JSONEncoder().encode(credential)
        let credentialAccount = Self.credentialAccount(connectorID)
        let previousCredential = try secretStore.load(account: credentialAccount)
        try secretStore.save(String(decoding: encoded, as: UTF8.self), account: credentialAccount)
        configuration.connectedAt = Date()
        configuration.accountLabel = accountLabel.flatMap(Self.normalizedAccountLabel)
        do {
            return try save(configuration)
        } catch {
            do {
                if let previousCredential {
                    try secretStore.save(previousCredential, account: credentialAccount)
                } else {
                    try secretStore.delete(account: credentialAccount)
                }
            } catch {
                throw ExtensionSubsystemError.invalidConnector(
                    "Connector 設定寫入失敗，Keychain 回復也失敗"
                )
            }
            throw error
        }
    }

    /// Returns a credential only to a bounded connector tool after its normal
    /// ToolExecutor network authorization. Callers must never log this value.
    func credential(for connectorID: UUID) throws -> OAuthCredential? {
        guard configurations.contains(where: { $0.id == connectorID && $0.enabled }),
              let raw = try secretStore.load(
                account: Self.credentialAccount(connectorID)
              ), let data = raw.data(using: .utf8) else { return nil }
        guard data.count <= 256 * 1_024 else {
            throw ExtensionSubsystemError.sizeLimit("OAuth credential 超過安全上限")
        }
        let stored = try JSONDecoder().decode(StoredCredential.self, from: data)
        guard Self.isBoundedOpaqueValue(stored.accessToken, maximumBytes: 64 * 1_024),
              stored.refreshToken.map({
                Self.isBoundedOpaqueValue($0, maximumBytes: 64 * 1_024)
              }) ?? true,
              stored.tokenType.range(
                of: #"^[A-Za-z][A-Za-z0-9._-]{0,31}$"#,
                options: .regularExpression
              ) != nil else {
            throw ExtensionSubsystemError.invalidConnector("Keychain credential 已損壞")
        }
        return OAuthCredential(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiresAt,
            tokenType: stored.tokenType
        )
    }

    func disconnect(_ id: UUID) throws -> [OAuthConnectorConfiguration] {
        guard let index = configurations.firstIndex(where: { $0.id == id }) else {
            throw ExtensionSubsystemError.invalidConnector("找不到 connector")
        }
        let account = Self.credentialAccount(id)
        let previousCredential = try secretStore.load(account: account)
        try secretStore.delete(account: account)
        let previous = configurations
        configurations[index].connectedAt = nil
        configurations[index].accountLabel = nil
        pendingAuthorizations.removeValue(forKey: id)
        activeExchanges.removeValue(forKey: id)
        do { try persist() } catch {
            configurations = previous
            if let previousCredential {
                do {
                    try secretStore.save(previousCredential, account: account)
                } catch {
                    throw ExtensionSubsystemError.invalidConnector(
                        "Connector 設定回復，但 Keychain token 無法回復"
                    )
                }
            }
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    func delete(_ id: UUID) throws -> [OAuthConnectorConfiguration] {
        guard configurations.contains(where: { $0.id == id }) else {
            throw ExtensionSubsystemError.invalidConnector("找不到 connector")
        }
        let account = Self.credentialAccount(id)
        let previousCredential = try secretStore.load(account: account)
        try secretStore.delete(account: account)
        let previous = configurations
        configurations.removeAll { $0.id == id }
        pendingAuthorizations.removeValue(forKey: id)
        activeExchanges.removeValue(forKey: id)
        do {
            try persist()
        } catch {
            configurations = previous
            if let previousCredential {
                do {
                    try secretStore.save(previousCredential, account: account)
                } catch {
                    throw ExtensionSubsystemError.invalidConnector(
                        "Connector 刪除失敗，Keychain token 無法回復"
                    )
                }
            }
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configurations.sorted(by: Self.sort))
        guard data.count <= Self.maximumSettingsBytes else {
            throw ExtensionSubsystemError.sizeLimit("OAuth connector settings 超過 1 MiB")
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private static func validate(_ configuration: OAuthConnectorConfiguration) throws {
        let normalizedName = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedClientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              configuration.name.utf8.count <= 256,
              !configuration.name.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }),
              !normalizedClientID.isEmpty,
              configuration.clientID.utf8.count <= 2_048,
              !configuration.clientID.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }),
              configuration.accountLabel.map({
                $0.utf8.count <= 256
                    && !$0.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    })
              }) ?? true,
              configuration.scopes.count <= 64,
              Set(configuration.scopes).count == configuration.scopes.count,
              configuration.scopes.allSatisfy(Self.isValidScope),
              Self.isSecureEndpoint(configuration.authorizationEndpoint),
              Self.isSecureEndpoint(configuration.tokenEndpoint),
              Self.isValidRedirect(configuration.redirectURI)
        else {
            throw ExtensionSubsystemError.invalidConnector("名稱、client、scope 或 HTTPS endpoint 無效")
        }
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.sorted { $0.key < $1.key }.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ExtensionSubsystemError.invalidConnector("無法產生安全的 OAuth 隨機值")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func isBoundedOpaqueValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }

    private static func isValidScope(_ scope: String) -> Bool {
        !scope.isEmpty
            && scope.utf8.count <= 256
            && !scope.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && !(url.host ?? "").isEmpty
            && url.user == nil
            && url.password == nil
            && url.fragment == nil
    }

    private static func isValidRedirect(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host == "::1" { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components.first == "127" else { return false }
        return components.allSatisfy {
            guard let value = Int($0) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func hasSameAuthorizationBinding(
        _ lhs: OAuthConnectorConfiguration,
        _ rhs: OAuthConnectorConfiguration
    ) -> Bool {
        lhs.authorizationEndpoint == rhs.authorizationEndpoint
            && lhs.tokenEndpoint == rhs.tokenEndpoint
            && lhs.clientID == rhs.clientID
            && lhs.scopes == rhs.scopes
            && lhs.redirectURI == rhs.redirectURI
    }

    private static func normalizedAccountLabel(_ value: String) -> String? {
        let normalized = String(
            value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)
        )
        guard !normalized.isEmpty,
              !normalized.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return normalized
    }

    private static func credentialAccount(_ id: UUID) -> String {
        "oauth|\(id.uuidString.lowercased())"
    }

    private static func sort(
        _ lhs: OAuthConnectorConfiguration,
        _ rhs: OAuthConnectorConfiguration
    ) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
