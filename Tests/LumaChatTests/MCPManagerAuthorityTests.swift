import Foundation
import XCTest
@testable import LumaChat

final class MCPManagerAuthorityTests: XCTestCase {
    func testFilteredDiscoveryWarningsRemovePreviouslyRegisteredInvalidTool() async throws {
        let transport = ManagerAuthorityTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry, transportFactory: ManagerAuthorityFactory(transport: transport))
        let configuration = configuration()
        _ = try await manager.connect(configuration)
        let oldValue = await registry.tool(named: "mcp.authority.echo")
        let old = try XCTUnwrap(oldValue)

        await transport.setInvalidHeader(true)
        let refreshed = try await manager.refreshDiscovery(serverID: configuration.id)
        XCTAssertEqual(refreshed.tools.map(\.name), ["valid"])
        XCTAssertNotNil(refreshed.lastError)
        let names = await registry.definitions(for: .agent).map(\.name)
        XCTAssertEqual(names, ["mcp.authority.valid"])
        await expectRejected(old)
        let validValue = await registry.tool(named: "mcp.authority.valid")
        let valid = try XCTUnwrap(validValue)
        _ = try await valid.execute(arguments: .object([:]), context: context())
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)
        await manager.disconnectAll()
    }

    func testRetainedAdapterCannotUseChangedPermissionsAfterRefresh() async throws {
        let transport = ManagerAuthorityTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry, transportFactory: ManagerAuthorityFactory(transport: transport))
        let configuration = configuration()
        _ = try await manager.connect(configuration)
        let oldValue = await registry.tool(named: "mcp.authority.echo")
        let old = try XCTUnwrap(oldValue)
        XCTAssertEqual(old.permissionLevel, .network)
        await transport.setDestructive(true)
        _ = try await manager.refreshDiscovery(serverID: configuration.id)
        await expectRejected(old)
        let currentValue = await registry.tool(named: "mcp.authority.echo")
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.permissionLevel, .dangerous)
        _ = try await current.execute(arguments: .object([:]), context: context())
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)
        await manager.disconnectAll()
    }

    func testSessionExpiryRevokesRegisteredToolsWithoutReplay() async throws {
        let transport = ManagerAuthorityTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry, transportFactory: ManagerAuthorityFactory(transport: transport))
        let configuration = configuration()
        _ = try await manager.connect(configuration)
        let oldValue = await registry.tool(named: "mcp.authority.echo")
        let old = try XCTUnwrap(oldValue)
        await transport.setExpireCall(true)
        await expectRejected(old)
        let snapshot = await manager.snapshot(serverID: configuration.id)
        XCTAssertEqual(snapshot?.state, .failed)
        XCTAssertTrue(snapshot?.lastError?.contains("Reconnect explicitly") == true)
        let names = await registry.definitions(for: .agent).map(\.name)
        let mapping = await manager.registeredToolMapping(serverID: configuration.id)
        XCTAssertTrue(names.isEmpty)
        XCTAssertTrue(mapping.isEmpty)
        await expectRejected(old)
        let callCount = await transport.callCount
        let startCount = await transport.startCount
        XCTAssertEqual(callCount, 1, "An uncertain tool result must never replay automatically")
        XCTAssertEqual(startCount, 1)
    }

    func testFailedRefreshDisablesRetainedAdaptersUntilSuccessfulDiscovery() async throws {
        let transport = ManagerAuthorityTransport()
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry, transportFactory: ManagerAuthorityFactory(transport: transport))
        let configuration = configuration()
        _ = try await manager.connect(configuration)
        let oldValue = await registry.tool(named: "mcp.authority.echo")
        let old = try XCTUnwrap(oldValue)
        await transport.setFailDiscovery(true)
        let failed = try await manager.refreshDiscovery(serverID: configuration.id)
        XCTAssertTrue(failed.lastError?.contains("Tool execution is disabled") == true)
        XCTAssertEqual(failed.tools.map(\.name), ["echo", "valid"])
        await expectRejected(old)
        let failedValue = await registry.tool(named: "mcp.authority.echo")
        let failedAdapter = try XCTUnwrap(failedValue)
        await expectRejected(failedAdapter)
        await transport.setFailDiscovery(false)
        _ = try await manager.refreshDiscovery(serverID: configuration.id)
        await expectRejected(failedAdapter)
        let currentValue = await registry.tool(named: "mcp.authority.echo")
        let current = try XCTUnwrap(currentValue)
        _ = try await current.execute(arguments: .object([:]), context: context())
        let callCount = await transport.callCount
        XCTAssertEqual(callCount, 1)
        await manager.disconnectAll()
    }

    private func expectRejected(_ tool: any AgentTool) async {
        do {
            _ = try await tool.execute(arguments: .object([:]), context: context())
            XCTFail("Retired or disconnected tool authority must be rejected")
        } catch {}
    }

    private func configuration() -> MCPServerConfiguration {
        MCPServerConfiguration(
            name: "Authority",
            protocolMode: .stateless,
            transport: .streamableHTTP(MCPStreamableHTTPConfiguration(endpoint: URL(string: "http://localhost:9876/mcp")!))
        )
    }

    private func context() -> AgentToolContext {
        AgentToolContext(
            sessionID: UUID(), mode: .agent,
            workspace: AgentWorkspace(name: "Fixture", rootPath: "/workspace", allowedPaths: ["/workspace"],
                                      bookmarkData: nil, gitRepository: false, branch: nil),
            temporaryRoot: AppPaths.projectTemporaryRoot
        )
    }
}

private struct ManagerAuthorityFactory: MCPTransportFactory {
    let transport: ManagerAuthorityTransport
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport { transport }
}

private actor ManagerAuthorityTransport: MCPTransport {
    private var invalidHeader = false
    private var destructive = false
    private var expireCall = false
    private var failDiscovery = false
    private(set) var callCount = 0
    private(set) var startCount = 0

    func start() { startCount += 1 }
    func stop() {}
    func setInvalidHeader(_ value: Bool) { invalidHeader = value }
    func setDestructive(_ value: Bool) { destructive = value }
    func setExpireCall(_ value: Bool) { expireCall = value }
    func setFailDiscovery(_ value: Bool) { failDiscovery = value }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        guard let id = request.id else { return nil }
        var result: [String: JSONValue] = ["resultType": .string("complete")]
        switch request.method {
        case "server/discover":
            result["supportedVersions"] = .array([.string(MCPClient.statelessProtocolVersion)])
            result["capabilities"] = .object(["tools": .object([:])])
        case "tools/list":
            if failDiscovery {
                return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: nil,
                    error: MCPJSONRPCError(code: -32000, message: "Temporary discovery failure", data: nil))
            }
            let property: JSONValue = invalidHeader
                ? .object(["type": .string("number"), "x-mcp-header": .string("Invalid")])
                : .object(["type": .string("string")])
            result["tools"] = .array([
                .object([
                    "name": .string("echo"),
                    "inputSchema": .object(["type": .string("object"), "properties": .object(["value": property])]),
                    "annotations": .object(["destructiveHint": .bool(destructive)])
                ]),
                .object(["name": .string("valid"), "inputSchema": .object(["type": .string("object")])])
            ])
        case "tools/call":
            callCount += 1
            if expireCall { throw MCPError.sessionExpired }
            result["content"] = .array([.object(["type": .string("text"), "text": .string("ok")])])
        default:
            throw MCPError.invalidResponse("Unexpected fixture method: \(request.method)")
        }
        return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: .object(result), error: nil)
    }
}
