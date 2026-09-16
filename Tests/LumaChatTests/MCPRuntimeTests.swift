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
                    arguments: ["--token", "argument-secret", "--mode=read"],
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
        XCTAssertEqual(loadedLocal.arguments, ["--token", "argument-secret", "--mode=read"])
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
        _ = lock.withLock { values.removeValue(forKey: account) }
    }

    func failAfterSuccessfulSaves(_ count: Int) {
        lock.withLock { failAtSave = saves + max(0, count) + 1 }
    }
}

private enum MockMCPSecretStoreError: Error {
    case injectedFailure
}
