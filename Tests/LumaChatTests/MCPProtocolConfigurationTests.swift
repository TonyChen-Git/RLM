import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class MCPProtocolConfigurationTests: XCTestCase {
    func testIdenticalSettingsRetryStillConfirmsDurability() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-durability-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let config = MCPServerConfiguration(name: "No secrets", protocolMode: .stateless,
            transport: .stdio(.init(command: "/usr/bin/example")))
        let store = MCPSettingsStore(fileURL: file, writeData: { data, url in
            try AtomicFileWriter.write(data, to: url)
            throw CocoaError(.fileWriteUnknown)
        })
        for _ in 0..<2 {
            do {
                try await store.save([config])
                XCTFail("Identical visible bytes must not hide a repeated durability failure")
            } catch is MCPSettingsStoreDurabilityError {}
        }
        let durable = MCPSettingsStore(fileURL: file)
        try await durable.save([config])
        let restored = try await durable.load()
        XCTAssertEqual(restored, [config])
    }

    func testExistingNestedAndConventionalImportsKeepLegacyLifecycle() throws {
        let data = Data(#"""
        {
          "mcpServers": {
            "Nested": {
              "transport": { "type": "stdio", "command": "/usr/bin/example" }
            },
            "Conventional": {
              "url": "https://mcp.example.test"
            }
          }
        }
        """#.utf8)
        let document = try JSONDecoder().decode(MCPConfigurationDocument.self, from: data)
        XCTAssertEqual(document.servers.count, 2)
        XCTAssertTrue(document.servers.allSatisfy { $0.protocolMode == .legacy })
        let configuration = MCPServerConfiguration(
            name: "Existing initializer",
            transport: .stdio(.init(command: "/usr/bin/example"))
        )
        XCTAssertEqual(configuration.protocolMode, .legacy)
    }

    func testAllProtocolModesRoundTripForBothTransports() throws {
        let transports: [MCPTransportConfiguration] = [
            .stdio(.init(command: "/usr/bin/example")),
            .streamableHTTP(.init(endpoint: URL(string: "https://mcp.example.test")!))
        ]
        for mode in MCPProtocolMode.allCases {
            for transport in transports {
                let configuration = MCPServerConfiguration(
                    name: "Configured",
                    enabled: false,
                    protocolMode: mode,
                    permissionLevel: .dangerous,
                    scope: .projectOnly,
                    projectPath: "/project",
                    transport: transport
                )
                let data = try JSONEncoder().encode(configuration)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object["protocolMode"] as? String, mode.rawValue)
                XCTAssertEqual(
                    try JSONDecoder().decode(MCPServerConfiguration.self, from: data),
                    configuration
                )
            }
        }
    }

    func testConventionalImportPreservesExplicitStatelessMode() throws {
        let data = Data(#"""
        { "mcpServers": {
          "Modern": { "url": "https://mcp.example.test", "protocolMode": "stateless" }
        } }
        """#.utf8)
        let document = try JSONDecoder().decode(MCPConfigurationDocument.self, from: data)
        XCTAssertEqual(document.servers.first?.protocolMode, .stateless)
    }

    func testUnknownModeIsRejectedInsteadOfSilentlyChangingLifecycle() throws {
        let invalidModes: [Any] = ["future-version", 7]
        for mode in invalidModes {
            let object: [String: Any] = [
                "name": "Invalid",
                "protocolMode": mode,
                "transport": ["type": "stdio", "command": "/usr/bin/example"]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(MCPServerConfiguration.self, from: data))
            XCTAssertThrowsError(try JSONDecoder().decode(PluginMCPServerDeclaration.self, from: data))
        }
    }

    func testPluginDeclarationsPreserveLegacyDefaultAndExplicitMode() throws {
        let oldData = Data(#"""
        {
          "name": "Plugin server",
          "transport": { "type": "stdio", "command": "bin/server" },
          "permissionLevel": "execute"
        }
        """#.utf8)
        let old = try JSONDecoder().decode(PluginMCPServerDeclaration.self, from: oldData)
        XCTAssertEqual(old.protocolMode, .legacy)

        for mode in MCPProtocolMode.allCases {
            var declaration = old
            declaration.protocolMode = mode
            let data = try JSONEncoder().encode(declaration)
            XCTAssertEqual(
                try JSONDecoder().decode(PluginMCPServerDeclaration.self, from: data),
                declaration
            )
        }
        XCTAssertEqual(
            PluginMCPServerDeclaration(name: old.name, transport: old.transport).protocolMode,
            .legacy
        )
    }

    func testSettingsRestartRetainsProtocolModesAndKeepsCredentialsInSecretStore() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-protocol-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = ProtocolConfigurationSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let local = MCPServerConfiguration(
            name: "Local modern",
            protocolMode: .stateless,
            transport: .stdio(.init(
                command: "/usr/bin/example",
                environment: ["API_TOKEN": "private-local-credential"]
            ))
        )
        let remote = MCPServerConfiguration(
            name: "Remote automatic",
            protocolMode: .automatic,
            transport: .streamableHTTP(.init(
                endpoint: URL(string: "https://mcp.example.test")!,
                headers: ["Authorization": "Bearer private-remote-credential"]
            ))
        )
        try await store.save([local, remote])
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("private-local-credential"))
        XCTAssertFalse(text.contains("private-remote-credential"))
        XCTAssertTrue(text.contains("LUMACHAT_MCP_KEYCHAIN"))

        let restarted = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded, [local, remote])

        var updated = remote
        updated.protocolMode = .legacy
        try await restarted.save([local, updated])
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, [local, updated])
        let updatedText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(updatedText.contains("private-local-credential"))
        XCTAssertFalse(updatedText.contains("private-remote-credential"))
    }
}

private final class ProtocolConfigurationSecretStore: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.withLock { values[account] = value }
    }

    func load(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}
