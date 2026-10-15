import Foundation
import XCTest
@testable import LumaChat

final class MCPConnectionLifecycleTests: XCTestCase {
    func testDisconnectRejectsLateInitializationWithoutRestoringConnection() async throws {
        let transport = SuspendedMCPTransport(heldMethod: "initialize")
        let client = MCPClient(configuration: configuration(), transport: transport)
        let connection = Task { try await client.connect() }
        try await transport.waitUntilHeld()
        await client.disconnect()
        await transport.release()
        do {
            _ = try await connection.value
            XCTFail("A late initialize result must not restore a disconnected client")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let connected = await client.isConnected
        let result = await client.initializeResult
        XCTAssertFalse(connected)
        XCTAssertNil(result)
    }

    func testExpiredSessionReplyAfterDisconnectCannotReconnect() async throws {
        let transport = SuspendedMCPTransport(heldMethod: "tools/list", expiresWhenReleased: true)
        let client = MCPClient(configuration: configuration(), transport: transport)
        _ = try await client.connect()
        let discovery = Task { try await client.listTools() }
        try await transport.waitUntilHeld()
        await client.disconnect()
        await transport.release()
        do {
            _ = try await discovery.value
            XCTFail("A stale expiration reply must not initiate a new session")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let starts = await transport.startCount
        let connected = await client.isConnected
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(connected)
    }

    func testManagerDisconnectStopsPendingTransportAndPreservesDisconnectedState() async throws {
        let transport = SuspendedMCPTransport(heldMethod: "initialize")
        let registry = ToolRegistry()
        let manager = MCPManager(
            registry: registry,
            transportFactory: SuspendedMCPTransportFactory(transport: transport)
        )
        let config = configuration()
        let connection = Task { try await manager.connect(config) }
        try await transport.waitUntilHeld()
        await manager.disconnect(serverID: config.id)
        let stoppedBeforeReply = await transport.stopCount
        XCTAssertEqual(stoppedBeforeReply, 1, "Disconnect must stop a transport still initializing")
        await transport.release()
        do {
            _ = try await connection.value
            XCTFail("A canceled manager connection must not finish")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let snapshot = await manager.snapshot(serverID: config.id)
        let definitions = await registry.definitions(for: .agent)
        XCTAssertEqual(snapshot?.state, .disconnected)
        XCTAssertTrue(definitions.isEmpty)
    }

    func testReplacementKeepsIndependentNamespaceUntilOldConnectionFinishesCleanup() async throws {
        let old = SuspendedMCPTransport(heldMethod: "tools/list", toolName: "old")
        let replacement = SuspendedMCPTransport(heldMethod: "never", toolName: "new")
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry,
            transportFactory: OrderedLifecycleTransportFactory([old, replacement]))
        let config = configuration()
        let first = Task { try await manager.connect(config) }
        try await old.waitUntilHeld()
        await manager.disconnect(serverID: config.id)
        _ = try await manager.connect(config)
        let before = await registry.definitions(for: .agent)
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(before.first?.name.hasPrefix("mcp.lifecycle_") == true,
                      "The old connection still owns the base namespace during cleanup")
        await old.release()
        do { _ = try await first.value; XCTFail("Old connection must be canceled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let after = await registry.definitions(for: .agent)
        XCTAssertEqual(after.map(\.name), before.map(\.name))
        await manager.disconnectAll()
        let empty = await registry.definitions(for: .agent)
        XCTAssertTrue(empty.isEmpty)
    }

    private func configuration() -> MCPServerConfiguration {
        MCPServerConfiguration(
            name: "Lifecycle",
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )
    }
}

private struct SuspendedMCPTransportFactory: MCPTransportFactory {
    let transport: SuspendedMCPTransport
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport {
        transport
    }
}

private final class OrderedLifecycleTransportFactory: MCPTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [SuspendedMCPTransport]
    init(_ transports: [SuspendedMCPTransport]) { self.transports = transports }
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport {
        lock.lock()
        defer { lock.unlock() }
        guard !transports.isEmpty else { throw MCPError.notConnected }
        return transports.removeFirst()
    }
}

/// Intentionally delivers a pending reply after stop, as a callback already in
/// flight may do. This tests authority at the client boundary independently of
/// whether a specific transport successfully cancels its network callback.
private actor SuspendedMCPTransport: MCPTransport {
    let heldMethod: String
    let expiresWhenReleased: Bool
    let toolName: String?
    private var held: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(heldMethod: String, expiresWhenReleased: Bool = false, toolName: String? = nil) {
        self.heldMethod = heldMethod
        self.expiresWhenReleased = expiresWhenReleased
        self.toolName = toolName
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func waitUntilHeld() async throws {
        for _ in 0..<500 {
            if held != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPError.transport("Test request did not reach its suspension point")
    }

    func release() {
        held?.resume()
        held = nil
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        if request.method == heldMethod {
            await withCheckedContinuation { continuation in
                held = continuation
            }
            if expiresWhenReleased { throw MCPError.sessionExpired }
        }
        guard let id = request.id else { return nil }
        let result: JSONValue = request.method == "initialize"
            ? .object([
                "protocolVersion": .string(MCPClient.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("Lifecycle"), "version": .string("1")])
            ])
            : .object(["tools": .array(toolName.map { name in [.object([
                "name": .string(name), "description": .string("Lifecycle test"),
                "inputSchema": .object(["type": .string("object")])
            ])] } ?? [])])
        return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }
}
