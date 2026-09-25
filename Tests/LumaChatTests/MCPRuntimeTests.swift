import Darwin
import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class MCPRuntimeTests: XCTestCase {
    func testConventionalConfigurationImportSupportsBothTransports() throws {
        let data = Data(#"""
        {
          "mcpServers": {
            "Local Tools": {
              "command": "/usr/bin/example-mcp",
              "args": ["--stdio"],
              "env": {"EXAMPLE_TOKEN": "secret"}
            },
            "Remote Tools": {
              "type": "streamable-http",
              "url": "https://mcp.example.test/rpc",
              "headers": {"Authorization": "Bearer secret"}
            }
          }
        }
        """#.utf8)

        let document = try JSONDecoder().decode(MCPConfigurationDocument.self, from: data)
        XCTAssertEqual(document.servers.map(\.name), ["Local Tools", "Remote Tools"])
        XCTAssertTrue(document.servers.allSatisfy { $0.scope == .global && $0.projectPath == nil })

        guard case .stdio(let local) = document.servers[0].transport else {
            return XCTFail("Expected stdio configuration")
        }
        XCTAssertEqual(local.command, "/usr/bin/example-mcp")
        XCTAssertEqual(local.arguments, ["--stdio"])
        XCTAssertEqual(local.environment["EXAMPLE_TOKEN"], "secret")

        guard case .streamableHTTP(let remote) = document.servers[1].transport else {
            return XCTFail("Expected streamable HTTP configuration")
        }
        XCTAssertEqual(remote.endpoint.absoluteString, "https://mcp.example.test/rpc")

        let projectScoped = MCPServerConfiguration(
            name: "Project",
            scope: .projectOnly,
            projectPath: "/Volumes/SD/Code/RLM",
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/example-mcp"))
        )
        let restored = try JSONDecoder().decode(
            MCPServerConfiguration.self,
            from: JSONEncoder().encode(projectScoped)
        )
        XCTAssertEqual(restored.scope, .projectOnly)
        XCTAssertEqual(restored.projectPath, "/Volumes/SD/Code/RLM")
    }

    func testNewlineFramerAndSSEParserHandleChunkedMessages() throws {
        var framer = MCPNewlineFramer()
        XCTAssertTrue(try framer.append(Data(#"{"jsonrpc":"2.0","id":1,"res"#.utf8)).isEmpty)
        let frames = try framer.append(
            Data("ult\":{\"ok\":true}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}\n".utf8)
        )
        XCTAssertEqual(frames.count, 2)

        let first = try MCPWireCodec.decode(MCPJSONRPCResponse.self, from: frames[0])
        XCTAssertEqual(first.id, .integer(1))
        XCTAssertEqual(first.result?["ok"]?.boolValue, true)

        let sse = Data(#"""
        event: message
        data: {"jsonrpc":"2.0","id":"abc","result":{"value":7}}

        """#.utf8)
        let events = try MCPSSEParser.responseEvents(from: sse)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, .string("abc"))
        XCTAssertEqual(events[0].result?["value"]?.intValue, 7)
    }

    func testRealStdioTransportUsesIsolatedRuntimeAndPreservesChunkOrder() async throws {
        let script = #"""
        while IFS= read -r request; do
            if [[ "$request" == *'"id":1'* ]]; then
                response='{"jsonrpc":"2.0","id":1,"result":{"method":"first"}}'
            elif [[ "$request" == *'"id":2'* ]]; then
                response='{"jsonrpc":"2.0","id":2,"result":{"method":"second"}}'
            else
                continue
            fi
            printf '%s' "${response[1,20]}"
            printf '%s\n' "${response[21,-1]}"
        done
        """#
        let transport = MCPStdioTransport(
            serverID: UUID(),
            configuration: MCPStdioConfiguration(
                command: "/bin/zsh",
                arguments: ["-c", script]
            ),
            allowsNetwork: false
        )

        try await transport.start()
        do {
            async let first = transport.send(
                MCPJSONRPCRequest(id: .integer(1), method: "first")
            )
            async let second = transport.send(
                MCPJSONRPCRequest(id: .integer(2), method: "second")
            )
            let firstResponse = try await first
            let secondResponse = try await second
            XCTAssertEqual(firstResponse?.id, .integer(1))
            XCTAssertEqual(firstResponse?.result?["method"]?.stringValue, "first")
            XCTAssertEqual(secondResponse?.id, .integer(2))
            XCTAssertEqual(secondResponse?.result?["method"]?.stringValue, "second")
        } catch {
            await transport.stop()
            throw error
        }
        await transport.stop()
    }

    func testDiscoveryRegistersNamespacedToolAndExecutionUsesToolExecutor() async throws {
        let transport = MockMCPTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(
            registry: registry,
            transportFactory: MockMCPTransportFactory(transport: transport)
        )
        let configuration = MCPServerConfiguration(
            name: "My Server",
            permissionLevel: .read,
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )

        let snapshot = try await manager.connect(configuration)
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.tools.map(\.name), ["Read File"])
        XCTAssertEqual(snapshot.resources.map(\.uri), ["file:///README.md"])
        XCTAssertEqual(snapshot.prompts.map(\.name), ["review"])

        let definitions = await registry.definitions(for: .agent)
        XCTAssertTrue(definitions.contains { $0.name == "mcp.my_server.read_file" })
        let mapping = await manager.registeredToolMapping(serverID: configuration.id)
        XCTAssertEqual(mapping["mcp.my_server.read_file"], "Read File")

        let workspace = AgentWorkspace(
            name: "RLM",
            rootPath: "/Volumes/SD/Code/RLM",
            allowedPaths: ["/Volumes/SD/Code/RLM"],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            temporaryRoot: AppPaths.projectTemporaryRoot
        )
        let executor = ToolExecutor(registry: registry)
        let result = try await executor.execute(
            AgentToolCall(
                name: "mcp.my_server.read_file",
                arguments: .object(["path": .string("README.md")])
            ),
            context: context,
            permissionMode: .autoApproveSafe,
            networkAccess: false,
            approvalHandler: { request in
                XCTAssertEqual(request.permissionLevel, .execute)
                return .allowOnce
            }
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "opened README.md")
        let calledTool = await transport.lastCalledTool()
        XCTAssertEqual(calledTool, "Read File")

        let resource = try await manager.readResource(
            serverID: configuration.id,
            uri: "file:///README.md"
        )
        XCTAssertEqual(resource.contents.first?["text"]?.stringValue, "hello")

        await manager.disconnect(serverID: configuration.id)
        let afterDisconnect = await registry.definitions(for: .agent)
        XCTAssertFalse(afterDisconnect.contains { $0.name.hasPrefix("mcp.my_server.") })
        let stopCount = await transport.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testProjectScopedToolIsHiddenAndRejectedOutsideCapturedWorkspace() async throws {
        let transport = MockMCPTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(
            registry: registry,
            transportFactory: MockMCPTransportFactory(transport: transport)
        )
        let projectRoot = "/Volumes/SD/Code/RLM"
        let configuration = MCPServerConfiguration(
            name: "Project Tools",
            permissionLevel: .read,
            scope: .projectOnly,
            projectPath: projectRoot,
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )
        _ = try await manager.connect(configuration)

        let allowedContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "RLM",
                rootPath: projectRoot,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            ),
            allowedMCPServerIDs: [configuration.id]
        )
        let otherProjectContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "Other",
                rootPath: "/Volumes/SD/Code/Other",
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            ),
            allowedMCPServerIDs: [configuration.id]
        )
        let disabledContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: allowedContext.workspace,
            allowedMCPServerIDs: []
        )

        let allowedDefinitions = await registry.definitions(for: .agent, context: allowedContext)
        XCTAssertTrue(allowedDefinitions.contains { $0.name == "mcp.project_tools.read_file" })
        let otherDefinitions = await registry.definitions(for: .agent, context: otherProjectContext)
        XCTAssertFalse(otherDefinitions.contains { $0.name.hasPrefix("mcp.project_tools.") })
        let disabledDefinitions = await registry.definitions(for: .agent, context: disabledContext)
        XCTAssertFalse(disabledDefinitions.contains { $0.name.hasPrefix("mcp.project_tools.") })

        let executor = ToolExecutor(registry: registry)
        let rejected = try await executor.execute(
            AgentToolCall(
                name: "mcp.project_tools.read_file",
                arguments: .object(["path": .string("README.md")])
            ),
            context: otherProjectContext,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: { _ in
                XCTFail("An out-of-scope MCP tool must fail before approval")
                return .allowOnce
            }
        )
        XCTAssertTrue(rejected.isError)
        let calledTool = await transport.lastCalledTool()
        XCTAssertNil(calledTool)
        await manager.disconnect(serverID: configuration.id)
    }

    func testReconnectRunsLifecycleAgainAndRestoresTools() async throws {
        let transport = MockMCPTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(
            registry: registry,
            transportFactory: MockMCPTransportFactory(transport: transport)
        )
        let configuration = MCPServerConfiguration(
            name: "Lifecycle",
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )

        _ = try await manager.connect(configuration)
        _ = try await manager.reconnect(serverID: configuration.id)
        let startCount = await transport.startCount()
        let initializeCount = await transport.methodCount("initialize")
        let toolsListCount = await transport.methodCount("tools/list")
        let resourcesListCount = await transport.methodCount("resources/list")
        let promptsListCount = await transport.methodCount("prompts/list")
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(initializeCount, 2)
        XCTAssertEqual(toolsListCount, 2)
        XCTAssertGreaterThanOrEqual(resourcesListCount, 2)
        XCTAssertGreaterThanOrEqual(promptsListCount, 2)
        let definitions = await registry.definitions(for: .agent)
        XCTAssertTrue(definitions.contains { $0.name == "mcp.lifecycle.read_file" })
    }

    func testOptionalDiscoveryFailuresAreVisibleWithoutDiscardingTools() async throws {
        let transport = MockMCPTransport(failingMethod: "resources/list")
        let registry = ToolRegistry()
        let manager = MCPManager(
            registry: registry,
            transportFactory: MockMCPTransportFactory(transport: transport)
        )
        let configuration = MCPServerConfiguration(
            name: "Partial Discovery",
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )

        let snapshot = try await manager.connect(configuration)
        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertEqual(snapshot.tools.count, 1)
        XCTAssertTrue(snapshot.resources.isEmpty)
        XCTAssertEqual(snapshot.prompts.count, 1)
        XCTAssertTrue(snapshot.lastError?.contains("Resources discovery failed") == true)
    }

    func testSettingsPersistenceKeepsSecretsOutOfJSON() async throws {
        let directory = URL(
            fileURLWithPath: "/Volumes/SD/Code/RLM/tmp/mcp-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let local = MCPServerConfiguration(
            name: "Local",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    arguments: [
                        "--token", "argument-secret",
                        "--key", "generic-key-secret",
                        "--mode=read"
                    ],
                    environment: [
                        "LOG_LEVEL": "debug",
                        "API_TOKEN": "local-secret",
                        "DATABASE_URL": "postgres://db-user:db-password@db.invalid/app"
                    ]
                )
            )
        )
        let remote = MCPServerConfiguration(
            name: "Remote",
            transport: .streamableHTTP(
                MCPStreamableHTTPConfiguration(
                    endpoint: URL(string: "https://mcp.example.test")!,
                    headers: ["Authorization": "Bearer remote-secret"]
                )
            )
        )

        try await store.save([local, remote])
        let persistedText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("local-secret"))
        XCTAssertFalse(persistedText.contains("remote-secret"))
        XCTAssertFalse(persistedText.contains("argument-secret"))
        XCTAssertFalse(persistedText.contains("generic-key-secret"))
        XCTAssertFalse(persistedText.contains("db-password"))
        XCTAssertTrue(persistedText.contains("LUMACHAT_MCP_KEYCHAIN"))
        XCTAssertFalse(persistedText.contains("debug"))

        let loaded = try await store.load()
        guard let loadedLocalConfiguration = loaded.first(where: { $0.id == local.id }),
              case .stdio(let loadedLocal) = loadedLocalConfiguration.transport,
              let loadedRemoteConfiguration = loaded.first(where: { $0.id == remote.id }),
              case .streamableHTTP(let loadedRemote) = loadedRemoteConfiguration.transport else {
            return XCTFail("Expected both persisted MCP transports")
        }
        XCTAssertEqual(loadedLocal.environment["API_TOKEN"], "local-secret")
        XCTAssertEqual(loadedLocal.environment["LOG_LEVEL"], "debug")
        XCTAssertEqual(
            loadedLocal.environment["DATABASE_URL"],
            "postgres://db-user:db-password@db.invalid/app"
        )
        XCTAssertEqual(
            loadedLocal.arguments,
            ["--token", "argument-secret", "--key", "generic-key-secret", "--mode=read"]
        )
        XCTAssertEqual(loadedRemote.headers["Authorization"], "Bearer remote-secret")
    }

    func testFailedSecretUpdateRollsBackOverwrittenKeychainValues() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-rollback-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(
            fileURL: directory.appendingPathComponent("servers.json"),
            secretStore: secrets
        )
        let serverID = UUID()
        let original = MCPServerConfiguration(
            id: serverID,
            name: "Rollback",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN_A": "old-a", "TOKEN_B": "old-b"]
                )
            )
        )
        try await store.save([original])
        secrets.failAfterSuccessfulSaves(1)

        var updated = original
        updated.name = "Persist failure updated"
        updated.transport = .stdio(
            MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN_A": "new-a", "TOKEN_B": "new-b"]
            )
        )
        do {
            try await store.save([updated])
            XCTFail("Injected Keychain failure should abort the settings transaction")
        } catch {
            // Expected.
        }
        let loaded = try await store.load()
        guard case .stdio(let configuration) = try XCTUnwrap(loaded.first).transport else {
            return XCTFail("Expected STDIO configuration")
        }
        XCTAssertEqual(configuration.environment["TOKEN_A"], "old-a")
        XCTAssertEqual(configuration.environment["TOKEN_B"], "old-b")
    }

    func testSettingsPersistFailureRollsBackCredentialAndKeepsPreviousDocument() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-persist-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let normalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let serverID = UUID()
        let original = MCPServerConfiguration(
            id: serverID,
            name: "Persist failure",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN": "old-secret"]
                )
            )
        )
        try await normalStore.save([original])
        let failingStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            writeData: { _, _ in throw InjectedMCPPersistenceError.failure }
        )
        var updated = original
        updated.name = "Rollback failure updated"
        updated.transport = .stdio(
            MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "new-secret"]
            )
        )

        do {
            try await failingStore.save([updated])
            XCTFail("Injected persistence failure should abort the transaction")
        } catch {
            XCTAssertTrue(error is InjectedMCPPersistenceError)
        }

        let loaded = try await normalStore.load()
        guard case .stdio(let configuration) = try XCTUnwrap(loaded.first).transport else {
            return XCTFail("Expected STDIO configuration")
        }
        XCTAssertEqual(configuration.environment["TOKEN"], "old-secret")
    }

    func testSettingsReportsCombinedErrorWhenPersistAndFreshCredentialCleanupBothFail() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-rollback-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let normalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let serverID = UUID()
        let original = MCPServerConfiguration(
            id: serverID,
            name: "Rollback failure",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN": "old-secret"]
                )
            )
        )
        try await normalStore.save([original])
        // The fresh updated credential is written without touching the old
        // generation. Inject failure while deleting that fresh account after
        // the metadata writer fails before commit.
        secrets.failNextDelete()
        let failingStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            writeData: { _, _ in throw InjectedMCPPersistenceError.failure }
        )
        var updated = original
        updated.name = "Rollback failure updated"
        updated.transport = .stdio(
            MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "new-secret"]
            )
        )

        do {
            try await failingStore.save([updated])
            XCTFail("A failed rollback must not be reported as an ordinary persist failure")
        } catch let error as MCPSettingsStoreTransactionError {
            XCTAssertEqual(error.operation, .save)
            XCTAssertTrue(error.primaryError is InjectedMCPPersistenceError)
            XCTAssertEqual(error.recoveryFailures.count, 1)
            XCTAssertTrue(error.recoveryFailures[0].underlyingError is MockMCPSecretStoreError)
            XCTAssertFalse(error.localizedDescription.contains("old-secret"))
            XCTAssertFalse(error.localizedDescription.contains("new-secret"))
        } catch {
            XCTFail("Expected combined MCP transaction error, got \(type(of: error))")
        }

        let values = secrets.snapshot()
        XCTAssertEqual(Set(values.values), ["old-secret", "new-secret"])
        let persistedText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(persistedText.contains("new-secret"))
        let loaded = try await normalStore.load()
        guard case .stdio(let configuration) = try XCTUnwrap(loaded.first).transport else {
            return XCTFail("Expected STDIO configuration")
        }
        XCTAssertEqual(configuration.environment["TOKEN"], "old-secret")
    }

    func testObsoleteCredentialCleanupFailureLeavesCommittedDocumentUsable() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-cleanup-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let original = MCPServerConfiguration(
            name: "Cleanup failure",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN": "retained-secret"]
                )
            )
        )
        try await store.save([original])
        secrets.failNextDelete()

        do {
            try await store.save([])
            XCTFail("Committed cleanup failure must remain visible")
        } catch let error as MCPSettingsStoreCredentialCleanupError {
            XCTAssertEqual(error.operation, .save)
            XCTAssertEqual(error.failures.count, 1)
            XCTAssertFalse(error.localizedDescription.contains("retained-secret"))
        }

        let loaded = try await store.load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(Set(secrets.snapshot().values), ["retained-secret"])
    }

    func testMissingPersistedCredentialReferenceFailsClosed() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-missing-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let server = MCPServerConfiguration(
            name: "Missing reference",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN": "unavailable-secret"]
                )
            )
        )
        try await store.save([server])
        let account = try XCTUnwrap(secrets.snapshot().first(where: {
            $0.value == "unavailable-secret"
        })?.key)
        try secrets.delete(account: account)

        do {
            _ = try await store.load()
            XCTFail("A missing persisted credential must not hydrate as an empty value")
        } catch let error as MCPError {
            guard case .invalidConfiguration(let detail) = error else {
                return XCTFail("Expected invalid configuration error")
            }
            XCTAssertTrue(detail.contains("cannot be resolved"))
            XCTAssertFalse(error.localizedDescription.contains("unavailable-secret"))
        }
    }

    func testUnreadablePersistedReferencesPreventOverwriteAndCredentialMutation() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-invalid-references-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("servers.json")
        let invalidDocument = Data("not valid MCP settings".utf8)
        try invalidDocument.write(to: file)
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let server = MCPServerConfiguration(
            name: "Must not overwrite",
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/example",
                    environment: ["TOKEN": "must-not-be-saved"]
                )
            )
        )

        do {
            try await store.save([server])
            XCTFail("Unreadable persisted references must stop the transaction")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }

        XCTAssertEqual(try Data(contentsOf: file), invalidDocument)
        XCTAssertTrue(secrets.snapshot().isEmpty)
    }

    func testDuplicateServerIdentifiersAreRejectedBeforeCredentialMutationAndImport() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-duplicate-id-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let duplicateID = UUID()
        let first = MCPServerConfiguration(
            id: duplicateID,
            name: "First",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "first-secret"]
            ))
        )
        let second = MCPServerConfiguration(
            id: duplicateID,
            name: "Second",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "second-secret"]
            ))
        )

        do {
            try await store.save([first, second])
            XCTFail("Duplicate MCP identifiers must fail before Keychain writes.")
        } catch let error as MCPError {
            guard case .invalidConfiguration(let detail) = error else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
            XCTAssertTrue(detail.contains("duplicate"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(secrets.snapshot().isEmpty)

        let imported = Data(#"""
        {"mcpServers":{
          "First":{"id":"\#(duplicateID.uuidString)","command":"/usr/bin/first"},
          "Second":{"id":"\#(duplicateID.uuidString)","command":"/usr/bin/second"}
        }}
        """#.utf8)
        do {
            _ = try await store.decodeImport(imported)
            XCTFail("Duplicate identifiers in imported MCP JSON must fail closed.")
        } catch let error as MCPError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
        }
    }

    func testCommittedThenThrowKeepsMCPDocumentAndCredentialsAligned() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-post-commit-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let normalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let serverID = UUID()
        let original = MCPServerConfiguration(
            id: serverID,
            name: "Before commit",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "old-secret"]
            ))
        )
        try await normalStore.save([original])
        let uncertainStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            writeData: { data, url in
                try AtomicFileWriter.write(data, to: url)
                throw InjectedMCPPersistenceError.failure
            }
        )
        var updated = original
        updated.name = "After commit"
        updated.transport = .stdio(MCPStdioConfiguration(
            command: "/usr/bin/example",
            environment: ["TOKEN": "new-secret"]
        ))

        // The replacement is visible, but a late durability error means a
        // restart could still reveal the old document. Both generations remain.
        do {
            try await uncertainStore.save([updated])
            XCTFail("Post-commit durability uncertainty must remain visible.")
        } catch let error as MCPSettingsStoreDurabilityError {
            XCTAssertTrue(error.primaryError is InjectedMCPPersistenceError)
            XCTAssertFalse(error.localizedDescription.contains("new-secret"))
        }

        let loaded = try await normalStore.load()
        XCTAssertEqual(loaded.first?.name, "After commit")
        guard case .stdio(let configuration) = try XCTUnwrap(loaded.first).transport else {
            return XCTFail("Expected STDIO configuration")
        }
        XCTAssertEqual(configuration.environment["TOKEN"], "new-secret")
        XCTAssertEqual(Set(secrets.snapshot().values), ["old-secret", "new-secret"])
    }

    func testThirdPartyMCPDocumentAfterWriterFailureNeverRollsCredentialsBackward() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-third-version-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let originalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let serverID = UUID()
        let original = MCPServerConfiguration(
            id: serverID,
            name: "Original",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "old-secret"]
            ))
        )
        try await originalStore.save([original])
        let thirdDocument = Data(#"{"version":1,"servers":[]}"#.utf8)
        let ambiguousStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            writeData: { _, url in
                try AtomicFileWriter.write(thirdDocument, to: url)
                throw InjectedMCPPersistenceError.failure
            }
        )
        var updated = original
        updated.name = "Requested"
        updated.transport = .stdio(MCPStdioConfiguration(
            command: "/usr/bin/example",
            environment: ["TOKEN": "new-secret"]
        ))

        do {
            try await ambiguousStore.save([updated])
            XCTFail("A third visible document must report durability uncertainty.")
        } catch let error as MCPSettingsStoreDurabilityError {
            XCTAssertTrue(error.primaryError is InjectedMCPPersistenceError)
        }

        XCTAssertEqual(try Data(contentsOf: file), thirdDocument)
        XCTAssertEqual(Set(secrets.snapshot().values), ["old-secret", "new-secret"])
    }

    func testMCPDeleteCommittedThenThrowKeepsDeletedDocumentAndCredentialsAligned() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-delete-post-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let server = MCPServerConfiguration(
            name: "Delete me",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "delete-secret"]
            ))
        )
        let normalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        try await normalStore.save([server])
        let uncertainStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            removeData: { url in
                try FileManager.default.removeItem(at: url)
                throw InjectedMCPPersistenceError.failure
            }
        )

        // Visible absence is not enough to prove the parent-directory update is
        // crash-durable. The credential must survive a possible metadata rollback.
        do {
            try await uncertainStore.deleteAll()
            XCTFail("A post-delete durability failure must remain visible.")
        } catch let error as MCPSettingsStoreDurabilityError {
            XCTAssertTrue(error.primaryError is InjectedMCPPersistenceError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Array(secrets.snapshot().values), ["delete-secret"])
    }

    func testMCPDeleteFailureBeforeUnlinkRestoresCredentials() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-delete-pre-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let server = MCPServerConfiguration(
            name: "Retain me",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "retained-secret"]
            ))
        )
        let normalStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        try await normalStore.save([server])
        let failingStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            removeData: { _ in throw InjectedMCPPersistenceError.failure }
        )

        do {
            try await failingStore.deleteAll()
            XCTFail("A pre-delete failure must abort deletion.")
        } catch {
            XCTAssertTrue(error is InjectedMCPPersistenceError)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Array(secrets.snapshot().values), ["retained-secret"])
    }

    func testMCPDeleteCleanupFailureOccursOnlyAfterMetadataCommit() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-delete-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let server = MCPServerConfiguration(
            name: "Delete cleanup",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "orphan-safe-secret"]
            ))
        )
        try await store.save([server])
        secrets.failNextDelete()

        do {
            try await store.deleteAll()
            XCTFail("A post-commit credential cleanup failure must remain visible.")
        } catch let error as MCPSettingsStoreCredentialCleanupError {
            XCTAssertEqual(error.operation, .deleteAll)
            XCTAssertEqual(error.failures.count, 1)
            XCTAssertFalse(error.localizedDescription.contains("orphan-safe-secret"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Array(secrets.snapshot().values), ["orphan-safe-secret"])
        let afterDelete = try await store.load()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testLegacyFixedMarkerLoadsAndMigratesToVersionedCredentialReference() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-legacy-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let serverID = UUID()
        let legacyAccount = "mcp|\(serverID.uuidString.lowercased())|env|TOKEN"
        try secrets.save("legacy-secret", account: legacyAccount)
        let persistedServer = MCPServerConfiguration(
            id: serverID,
            name: "Legacy",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN": "${LUMACHAT_MCP_KEYCHAIN}"]
            ))
        )
        let serverObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(persistedServer)
        )
        let legacyDocument = try JSONSerialization.data(
            withJSONObject: ["version": 1, "servers": [serverObject]],
            options: [.sortedKeys]
        )
        try legacyDocument.write(to: file)

        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let loaded = try await store.load()
        guard case .stdio(let loadedConfiguration) = try XCTUnwrap(loaded.first).transport else {
            return XCTFail("Expected STDIO configuration")
        }
        XCTAssertEqual(loadedConfiguration.environment["TOKEN"], "legacy-secret")

        try await store.save(loaded)
        let migratedText = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(migratedText.contains("${LUMACHAT_MCP_KEYCHAIN:"))
        XCTAssertNil(try secrets.load(account: legacyAccount))
        XCTAssertEqual(Array(secrets.snapshot().values), ["legacy-secret"])
        let migrated = try await store.load()
        XCTAssertEqual(migrated, loaded)
    }

    func testVersionedMarkerCannotReferenceAnotherLogicalCredentialField() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-cross-field-reference-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let store = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let server = MCPServerConfiguration(
            name: "Scoped references",
            transport: .stdio(MCPStdioConfiguration(
                command: "/usr/bin/example",
                environment: ["TOKEN_A": "secret-a", "TOKEN_B": "secret-b"]
            ))
        )
        try await store.save([server])
        let accountA = try XCTUnwrap(secrets.snapshot().first(where: { $0.value == "secret-a" })?.key)
        let markerA = testVersionedMCPMarker(account: accountA)

        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var servers = try XCTUnwrap(document["servers"] as? [[String: Any]])
        var persistedServer = try XCTUnwrap(servers.first)
        var transport = try XCTUnwrap(persistedServer["transport"] as? [String: Any])
        var environment = try XCTUnwrap(transport["env"] as? [String: String])
        environment["TOKEN_B"] = markerA
        transport["env"] = environment
        persistedServer["transport"] = transport
        servers[0] = persistedServer
        document["servers"] = servers
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: file)

        do {
            _ = try await store.load()
            XCTFail("A versioned marker must be scoped to its exact logical field.")
        } catch let error as MCPError {
            guard case .invalidConfiguration(let detail) = error else {
                return XCTFail("Expected invalid configuration, got \(error)")
            }
            XCTAssertTrue(detail.contains("reference is invalid"))
            XCTAssertFalse(error.localizedDescription.contains("secret-a"))
        }
    }

    func testConcurrentMCPStoreInstancesSerializeMergeTransactions() async throws {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-settings-concurrent-stores-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("servers.json")
        let secrets = MockMCPSecretStore()
        let firstWriterEntered = expectation(description: "first MCP writer entered")
        let firstStore = MCPSettingsStore(
            fileURL: file,
            secretStore: secrets,
            writeData: { data, url in
                firstWriterEntered.fulfill()
                Darwin.usleep(150_000)
                try AtomicFileWriter.write(data, to: url)
            }
        )
        let secondStore = MCPSettingsStore(fileURL: file, secretStore: secrets)
        let firstDocument = Data(#"{"mcpServers":{"First":{"command":"/usr/bin/first"}}}"#.utf8)
        let secondDocument = Data(#"{"mcpServers":{"Second":{"command":"/usr/bin/second"}}}"#.utf8)

        let firstTask = Task { try await firstStore.importAndSave(firstDocument) }
        await fulfillment(of: [firstWriterEntered], timeout: 2)
        let secondTask = Task { try await secondStore.importAndSave(secondDocument) }
        _ = try await firstTask.value
        _ = try await secondTask.value

        let loadedNames = Set(try await secondStore.load().map(\.name))
        XCTAssertEqual(loadedNames, ["First", "Second"])
    }
}

private func testVersionedMCPMarker(account: String) -> String {
    let encoded = Data(account.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "${LUMACHAT_MCP_KEYCHAIN:\(encoded)}"
}

private struct MockMCPTransportFactory: MCPTransportFactory {
    let transport: MockMCPTransport

    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport {
        transport
    }
}

private actor MockMCPTransport: MCPTransport {
    private let failingMethod: String?
    private var started = false
    private var starts = 0
    private var stops = 0
    private var methods: [String] = []
    private var calledTool: String?

    init(failingMethod: String? = nil) {
        self.failingMethod = failingMethod
    }

    func start() async throws {
        guard !started else { throw MCPError.alreadyRunning }
        started = true
        starts += 1
    }

    func stop() async {
        if started { stops += 1 }
        started = false
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        guard started else { throw MCPError.notConnected }
        methods.append(request.method)
        guard let id = request.id else { return nil }

        if request.method == failingMethod {
            return MCPJSONRPCResponse(
                jsonrpc: "2.0",
                id: id,
                result: nil,
                error: MCPJSONRPCError(code: -32_000, message: "Injected discovery failure", data: nil)
            )
        }

        let result: JSONValue
        switch request.method {
        case "initialize":
            result = .object([
                "protocolVersion": .string(MCPClient.protocolVersion),
                "capabilities": .object([
                    "tools": .object([:]),
                    "resources": .object([:]),
                    "prompts": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("Mock MCP"),
                    "version": .string("1.0")
                ])
            ])
        case "tools/list":
            result = .object([
                "tools": .array([
                    .object([
                        "name": .string("Read File"),
                        "description": .string("Read a fixture"),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object(["type": .string("string")])
                            ]),
                            "required": .array([.string("path")])
                        ]),
                        "annotations": .object([
                            "readOnlyHint": .bool(true),
                            "destructiveHint": .bool(false)
                        ])
                    ])
                ])
            ])
        case "resources/list":
            result = .object([
                "resources": .array([
                    .object([
                        "uri": .string("file:///README.md"),
                        "name": .string("README")
                    ])
                ])
            ])
        case "prompts/list":
            result = .object([
                "prompts": .array([
                    .object(["name": .string("review")])
                ])
            ])
        case "tools/call":
            calledTool = request.params?["name"]?.stringValue
            let path = request.params?["arguments"]?["path"]?.stringValue ?? "unknown"
            result = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("opened \(path)")
                    ])
                ]),
                "isError": .bool(false)
            ])
        case "resources/read":
            result = .object([
                "contents": .array([
                    .object([
                        "uri": .string(request.params?["uri"]?.stringValue ?? ""),
                        "mimeType": .string("text/plain"),
                        "text": .string("hello")
                    ])
                ])
            ])
        default:
            return MCPJSONRPCResponse(
                jsonrpc: "2.0",
                id: id,
                result: nil,
                error: MCPJSONRPCError(code: -32601, message: "Method not found", data: nil)
            )
        }
        return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func lastCalledTool() -> String? { calledTool }
    func methodCount(_ method: String) -> Int { methods.filter { $0 == method }.count }
}

private final class MockMCPSecretStore: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var saves = 0
    private var failAtSave: Int?
    private var failDelete = false

    func save(_ value: String, account: String) throws {
        try lock.withLock {
            saves += 1
            if failAtSave == saves {
                failAtSave = nil
                throw MockMCPSecretStoreError.injectedFailure
            }
            values[account] = value
        }
    }

    func load(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func delete(account: String) throws {
        try lock.withLock {
            if failDelete {
                failDelete = false
                throw MockMCPSecretStoreError.injectedFailure
            }
            values.removeValue(forKey: account)
        }
    }

    func failAfterSuccessfulSaves(_ count: Int) {
        lock.withLock { failAtSave = saves + max(0, count) + 1 }
    }

    func failNextDelete() {
        lock.withLock { failDelete = true }
    }

    func snapshot() -> [String: String] {
        lock.withLock { values }
    }
}

private enum MockMCPSecretStoreError: Error {
    case injectedFailure
}

private enum InjectedMCPPersistenceError: Error {
    case failure
}
