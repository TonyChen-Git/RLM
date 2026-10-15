import Foundation
import XCTest
@testable import LumaChat

private final class PhaseDOAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []
    nonisolated(unsafe) private static var holdNext = false
    nonisolated(unsafe) private static var held: [PhaseDOAuthURLProtocol] = []
    private static let defaultTokenResponse = #"{"access_token":"oauth-access-secret-123456","refresh_token":"oauth-refresh-secret-123456","expires_in":3600,"token_type":"Bearer"}"#
    nonisolated(unsafe) private static var tokenResponse = defaultTokenResponse

    static func reset() {
        lock.lock()
        captured = []
        holdNext = false
        held = []
        tokenResponse = defaultTokenResponse
        lock.unlock()
    }

    static func setTokenResponse(_ response: String) {
        lock.lock()
        tokenResponse = response
        lock.unlock()
    }

    static func holdNextResponse() {
        lock.lock()
        holdNext = true
        lock.unlock()
    }

    static func releaseHeldResponses() {
        lock.lock()
        let requests = held
        held = []
        lock.unlock()
        requests.forEach { $0.complete() }
    }

    static func requests() -> [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        Self.captured.append((request, body))
        let shouldHold = Self.holdNext
        if shouldHold {
            Self.holdNext = false
            Self.held.append(self)
        }
        Self.lock.unlock()
        if shouldHold { return }
        complete()
    }

    private func complete() {
        Self.lock.lock()
        let responseBody = Self.tokenResponse
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(responseBody.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class PhaseDSecretVault: OAuthCredentialStoring, MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.lock()
        values[account] = value
        lock.unlock()
    }

    func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }

    func allValues() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }
}

@MainActor
final class PhaseDOAuthAndMCPTests: XCTestCase {
    func testOAuthPKCEExchangeKeepsTokensOutOfPlainJSONAndSupportsDisconnect() async throws {
        PhaseDOAuthURLProtocol.reset()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oauth/connectors.json")
        let vault = PhaseDSecretVault()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhaseDOAuthURLProtocol.self]
        let connectorStore = OAuthConnectorStore(
            fileURL: file,
            secretStore: vault,
            session: URLSession(configuration: configuration)
        )
        let connector = OAuthConnectorConfiguration(
            name: "GitHub Test",
            kind: .github,
            authorizationEndpoint: URL(string: "https://auth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.test/token")!,
            clientID: "phase-d-client",
            scopes: ["repo", "read:user"],
            redirectURI: URL(string: "http://127.0.0.1:8765/oauth/callback")!
        )
        _ = try await connectorStore.save(connector)

        let authorization = try await connectorStore.authorizationRequest(
            for: connector.id,
            state: "known-state"
        )
        let query = try XCTUnwrap(
            URLComponents(url: authorization.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["client_id"], "phase-d-client")
        XCTAssertEqual(values["state"], "known-state")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertFalse(authorization.codeVerifier.isEmpty)
        XCTAssertFalse(authorization.codeVerifier.contains("="))
        XCTAssertNotEqual(values["code_challenge"], authorization.codeVerifier)

        let connected = try await connectorStore.exchangeAuthorizationCode(
            connectorID: connector.id,
            code: "authorization-code",
            codeVerifier: authorization.codeVerifier,
            state: authorization.state,
            accountLabel: "octocat"
        )
        XCTAssertNotNil(connected.first?.connectedAt)
        XCTAssertEqual(connected.first?.accountLabel, "octocat")
        let request = try XCTUnwrap(PhaseDOAuthURLProtocol.requests().first)
        XCTAssertEqual(request.0.httpMethod, "POST")
        let form = String(decoding: request.1, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("code=authorization-code"))
        XCTAssertTrue(form.contains("code_verifier="))

        let plainSettings = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(plainSettings.contains("oauth-access-secret-123456"))
        XCTAssertFalse(plainSettings.contains("oauth-refresh-secret-123456"))
        XCTAssertTrue(vault.allValues().contains { $0.contains("oauth-access-secret-123456") })
        let credential = try await connectorStore.credential(for: connector.id)
        XCTAssertEqual(credential?.accessToken, "oauth-access-secret-123456")
        XCTAssertEqual(credential?.refreshToken, "oauth-refresh-secret-123456")

        let reloadedStore = OAuthConnectorStore(
            fileURL: file,
            secretStore: vault,
            session: URLSession(configuration: configuration)
        )
        let reloaded = try await reloadedStore.load()
        XCTAssertEqual(reloaded.first?.id, connector.id)
        XCTAssertNotNil(reloaded.first?.connectedAt)
        let reloadedCredential = try await reloadedStore.credential(for: connector.id)
        XCTAssertEqual(reloadedCredential?.accessToken, "oauth-access-secret-123456")

        let disconnected = try await reloadedStore.disconnect(connector.id)
        XCTAssertNil(disconnected.first?.connectedAt)
        let disconnectedCredential = try await reloadedStore.credential(for: connector.id)
        XCTAssertNil(disconnectedCredential)
        XCTAssertTrue(vault.allValues().isEmpty)

        let deleted = try await reloadedStore.delete(connector.id)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testOAuthRejectsInsecureAuthorizationAndTokenEndpoints() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OAuthConnectorStore(
            fileURL: root.appendingPathComponent("connectors.json"),
            secretStore: PhaseDSecretVault()
        )
        let invalid = OAuthConnectorConfiguration(
            name: "Unsafe",
            kind: .custom,
            authorizationEndpoint: URL(string: "http://auth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.test/token")!,
            clientID: "client",
            scopes: ["read"],
            redirectURI: URL(string: "http://127.0.0.1/callback")!
        )
        await assertAsyncThrows {
            _ = try await store.save(invalid)
        }
    }

    func testOAuthRefreshAndRevocationKeepSecretsInVault() async throws {
        PhaseDOAuthURLProtocol.reset()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = PhaseDSecretVault()
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [PhaseDOAuthURLProtocol.self]
        let store = OAuthConnectorStore(
            fileURL: root.appendingPathComponent("oauth.json"),
            secretStore: vault, session: URLSession(configuration: transport)
        )
        let connector = OAuthConnectorConfiguration(
            name: "Refreshable", kind: .custom,
            authorizationEndpoint: URL(string: "https://oauth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://oauth.example.test/token")!,
            revocationEndpoint: URL(string: "https://oauth.example.test/revoke")!,
            clientID: "test-client", scopes: ["read"],
            redirectURI: URL(string: "http://127.0.0.1/callback")!
        )
        _ = try await store.save(connector)
        let authorization = try await store.authorizationRequest(for: connector.id)
        _ = try await store.exchangeAuthorizationCode(
            connectorID: connector.id, code: "code",
            codeVerifier: authorization.codeVerifier, state: authorization.state
        )
        _ = try await store.refresh(connector.id)
        let forms = PhaseDOAuthURLProtocol.requests().map {
            String(decoding: $0.1, as: UTF8.self)
        }
        XCTAssertTrue(forms.contains { $0.contains("grant_type=refresh_token") })
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("oauth.json"), encoding: .utf8)
            .contains("oauth-refresh-secret"))
        _ = try await store.setEnabled(false, id: connector.id)
        _ = try await store.revoke(connector.id)
        XCTAssertTrue(PhaseDOAuthURLProtocol.requests().contains {
            $0.0.url?.path == "/revoke"
        })
        XCTAssertTrue(vault.allValues().isEmpty)
        let disconnectedCredential = try await store.credential(for: connector.id)
        XCTAssertNil(disconnectedCredential)
    }

    func testOAuthRejectsAlreadyExpiredAuthorizationTokensInsteadOfStoringUnlimitedExpiry() async throws {
        PhaseDOAuthURLProtocol.reset()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = PhaseDSecretVault()
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [PhaseDOAuthURLProtocol.self]
        let store = OAuthConnectorStore(
            fileURL: root.appendingPathComponent("oauth.json"),
            secretStore: vault, session: URLSession(configuration: transport)
        )
        let connector = OAuthConnectorConfiguration(
            name: "Expired", kind: .custom,
            authorizationEndpoint: URL(string: "https://oauth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://oauth.example.test/token")!,
            clientID: "test-client", scopes: ["read"],
            redirectURI: URL(string: "http://127.0.0.1/callback")!
        )
        _ = try await store.save(connector)
        for lifetime in [0, -1] {
            PhaseDOAuthURLProtocol.setTokenResponse(
                "{\"access_token\":\"already-expired\",\"expires_in\":\(lifetime)}"
            )
            let authorization = try await store.authorizationRequest(for: connector.id)
            await assertAsyncThrows {
                _ = try await store.exchangeAuthorizationCode(
                    connectorID: connector.id, code: "code",
                    codeVerifier: authorization.codeVerifier, state: authorization.state
                )
            }
            XCTAssertTrue(vault.allValues().isEmpty)
        }
    }

    func testInFlightRefreshAndRevokeCannotOverwriteReauthorization() async throws {
        PhaseDOAuthURLProtocol.reset()
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = PhaseDSecretVault()
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [PhaseDOAuthURLProtocol.self]
        let store = OAuthConnectorStore(
            fileURL: root.appendingPathComponent("oauth.json"),
            secretStore: vault, session: URLSession(configuration: transport)
        )
        let connector = OAuthConnectorConfiguration(
            name: "Race", kind: .custom,
            authorizationEndpoint: URL(string: "https://oauth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://oauth.example.test/token")!,
            revocationEndpoint: URL(string: "https://oauth.example.test/revoke")!,
            clientID: "test-client", scopes: ["read"],
            redirectURI: URL(string: "http://127.0.0.1/callback")!
        )
        _ = try await store.save(connector)
        let initial = try await store.authorizationRequest(for: connector.id)
        _ = try await store.exchangeAuthorizationCode(
            connectorID: connector.id, code: "initial",
            codeVerifier: initial.codeVerifier, state: initial.state
        )

        PhaseDOAuthURLProtocol.holdNextResponse()
        let refresh = Task { try await store.refresh(connector.id) }
        try await waitForOAuthRequestCount(2)
        _ = try await store.disconnect(connector.id)
        let renewed = try await store.authorizationRequest(for: connector.id)
        _ = try await store.exchangeAuthorizationCode(
            connectorID: connector.id, code: "renewed",
            codeVerifier: renewed.codeVerifier, state: renewed.state
        )
        PhaseDOAuthURLProtocol.releaseHeldResponses()
        await assertAsyncThrows { _ = try await refresh.value }
        let credentialAfterRefresh = try await store.credential(for: connector.id)
        XCTAssertNotNil(credentialAfterRefresh)

        PhaseDOAuthURLProtocol.holdNextResponse()
        let revoke = Task { try await store.revoke(connector.id) }
        try await waitForOAuthRequestCount(4)
        _ = try await store.disconnect(connector.id)
        let newest = try await store.authorizationRequest(for: connector.id)
        _ = try await store.exchangeAuthorizationCode(
            connectorID: connector.id, code: "newest",
            codeVerifier: newest.codeVerifier, state: newest.state
        )
        PhaseDOAuthURLProtocol.releaseHeldResponses()
        await assertAsyncThrows { _ = try await revoke.value }
        let credentialAfterRevoke = try await store.credential(for: connector.id)
        XCTAssertNotNil(credentialAfterRevoke)
    }

    private func waitForOAuthRequestCount(_ count: Int) async throws {
        for _ in 0..<100 {
            if PhaseDOAuthURLProtocol.requests().count >= count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for OAuth request")
    }

    func testPluginMCPServerOwnershipPersistsWithoutAffectingManualServers() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mcp/servers.json")
        let vault = PhaseDSecretVault()
        let store = MCPSettingsStore(fileURL: file, secretStore: vault)
        let ownedID = UUID()
        let manualID = UUID()
        let owned = MCPServerConfiguration(
            id: ownedID,
            name: "Plugin Search",
            permissionLevel: .network,
            ownerPluginID: "com.example.search",
            transport: .streamableHTTP(
                MCPStreamableHTTPConfiguration(
                    endpoint: URL(string: "https://mcp.example.test/rpc")!,
                    headers: ["Authorization": "Bearer mcp-secret-123456"]
                )
            )
        )
        let manual = MCPServerConfiguration(
            id: manualID,
            name: "Manual Local",
            transport: .stdio(
                MCPStdioConfiguration(command: "/usr/bin/example-mcp")
            )
        )
        try await store.save([owned, manual])

        let persisted = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(persisted.contains("com.example.search"))
        XCTAssertFalse(persisted.contains("mcp-secret-123456"))
        let restored = try await store.load()
        XCTAssertEqual(
            restored.first(where: { $0.id == ownedID })?.ownerPluginID,
            "com.example.search"
        )
        XCTAssertEqual(
            restored.first(where: { $0.id == ownedID }).flatMap { server -> String? in
                guard case .streamableHTTP(let configuration) = server.transport else {
                    return nil
                }
                return configuration.headers["Authorization"]
            },
            "Bearer mcp-secret-123456"
        )
        XCTAssertNil(restored.first(where: { $0.id == manualID })?.ownerPluginID)

        let legacyData = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","transport":{"type":"stdio","command":"/usr/bin/legacy"}}"#.utf8)
        let legacy = try JSONDecoder().decode(MCPServerConfiguration.self, from: legacyData)
        XCTAssertNil(legacy.ownerPluginID)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-d-oauth-mcp-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
