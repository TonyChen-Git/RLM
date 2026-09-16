import Foundation
import XCTest
@testable import LumaChat

private final class PhaseDOAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [(URLRequest, Data)] = []

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
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
            didLoad: Data(
                #"{"access_token":"oauth-access-secret-123456","refresh_token":"oauth-refresh-secret-123456","expires_in":3600,"token_type":"Bearer"}"#.utf8
            )
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
