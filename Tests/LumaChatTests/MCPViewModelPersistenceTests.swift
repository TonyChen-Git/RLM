import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class MCPViewModelPersistenceTests: XCTestCase {
    func testFailedEditDeleteAndDisableRetainPersistedSettingsWithoutReconnecting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        await fixture.viewModel.connectMCP(serverID: original.id)
        let initialStarts = await fixture.transport.starts
        XCTAssertEqual(initialStarts, 1)

        var replacement = original
        replacement.protocolMode = .stateless
        fixture.writer.mode = .failBeforeWrite
        let edited = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertFalse(edited)
        XCTAssertEqual(fixture.viewModel.mcpServers, [original])
        await fixture.viewModel.connectMCP(serverID: original.id)
        await fixture.viewModel.deleteMCPServer(id: original.id)
        XCTAssertEqual(fixture.viewModel.mcpServers, [original])
        await fixture.viewModel.setMCPServerEnabled(id: original.id, enabled: false)
        XCTAssertEqual(fixture.viewModel.mcpServers, [original])
        await fixture.viewModel.reconnectMCP(serverID: original.id)
        let stored = try await fixture.store.load()
        let starts = await fixture.transport.starts
        let snapshot = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(stored, [original])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(snapshot?.state, .disconnected)

        fixture.writer.mode = .success
        let saved = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertTrue(saved)
        await fixture.viewModel.connectMCP(serverID: original.id)
        let recovered = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(recovered?.negotiatedProtocolVersion, MCPClient.statelessProtocolVersion)
        await fixture.viewModel.disconnectMCP(serverID: original.id)
    }

    func testCommittedCleanupFailureAdoptsNewConfigurationAndProtectedCredentials() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var original = configuration()
        original.enabled = false
        original.transport = .streamableHTTP(.init(
            endpoint: URL(string: "https://example.test/mcp")!,
            headers: ["Authorization": "Bearer old-private-credential"]
        ))
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        fixture.secrets.failDeletes = true
        var replacement = original
        replacement.protocolMode = .stateless
        replacement.transport = .streamableHTTP(.init(
            endpoint: URL(string: "https://example.test/mcp")!,
            headers: ["Authorization": "Bearer new-private-credential"]
        ))
        let saved = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.viewModel.mcpServers, [replacement])
        XCTAssertTrue(fixture.viewModel.statusMessage?.contains("舊憑證清理") == true)
        let loaded = try await fixture.store.load()
        XCTAssertEqual(loaded, [replacement])
        let persisted = try String(contentsOf: fixture.file, encoding: .utf8)
        XCTAssertFalse(persisted.contains("old-private-credential"))
        XCTAssertFalse(persisted.contains("new-private-credential"))
    }

    func testExplicitReconnectUsesSavedProtocolAndTransportInsteadOfOldSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        await fixture.viewModel.connectMCP(serverID: original.id)
        let originalSnapshot = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(originalSnapshot?.negotiatedProtocolVersion, MCPClient.protocolVersion)

        var replacement = original
        replacement.protocolMode = .stateless
        replacement.transport = .streamableHTTP(.init(
            endpoint: URL(string: "https://updated.example.test/mcp")!,
            headers: ["Authorization": "Bearer replacement-private-credential"]
        ))
        let saved = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.viewModel.activeMode, .chat)
        let disconnected = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(disconnected?.state, .disconnected)

        await fixture.viewModel.reconnectMCP(serverID: original.id)
        let reconnected = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(reconnected?.state, .connected)
        XCTAssertEqual(reconnected?.configuration, replacement)
        XCTAssertEqual(reconnected?.negotiatedProtocolVersion, MCPClient.statelessProtocolVersion)
        await fixture.viewModel.disconnectMCP(serverID: original.id)
    }

    func testUncertainCommitLoadsPersistedGenerationButBlocksUntilConfirmedSave() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        await fixture.viewModel.connectMCP(serverID: original.id)
        var replacement = original
        replacement.protocolMode = .stateless
        fixture.writer.mode = .commitThenFail
        let uncertain = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertFalse(uncertain)
        XCTAssertEqual(fixture.viewModel.mcpServers, [replacement])
        let loaded = try await fixture.store.load()
        XCTAssertEqual(loaded, [replacement])
        await fixture.viewModel.connectMCP(serverID: original.id)
        let starts = await fixture.transport.starts
        XCTAssertEqual(starts, 1)

        let writesBeforeConfirmation = fixture.writer.writes
        fixture.writer.mode = .success
        let confirmed = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(fixture.writer.writes, writesBeforeConfirmation + 1,
                       "Re-saving an uncertain identical document must confirm filesystem durability.")
        await fixture.viewModel.connectMCP(serverID: original.id)
        let snapshot = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(snapshot?.state, .connected)
        XCTAssertEqual(snapshot?.configuration, replacement)
        await fixture.viewModel.disconnectMCP(serverID: original.id)
    }

    func testUnreadableUncertainCommitKeepsPriorDisplayAndStopsAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        await fixture.viewModel.connectMCP(serverID: original.id)
        fixture.writer.mode = .corruptThenFail
        var replacement = original
        replacement.protocolMode = .stateless
        let saved = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertFalse(saved)
        XCTAssertEqual(fixture.viewModel.mcpServers, [original])
        await fixture.viewModel.connectMCP(serverID: original.id)
        let starts = await fixture.transport.starts
        let snapshot = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(snapshot?.state, .disconnected)
    }

    func testChangingProtocolDisconnectsInitializationBeforeLateResponse() async throws {
        let fixture = try Fixture(holdInitialization: true)
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        let connection = Task { await fixture.viewModel.connectMCP(serverID: original.id) }
        try await fixture.transport.waitUntilHeld()
        var replacement = original
        replacement.protocolMode = .stateless
        replacement.enabled = false
        let saved = await fixture.viewModel.saveMCPServer(replacement)
        XCTAssertTrue(saved)
        let stopCount = await fixture.transport.stops
        XCTAssertGreaterThanOrEqual(stopCount, 1)
        await fixture.transport.release()
        await connection.value
        let snapshot = await fixture.manager.snapshot(serverID: original.id)
        XCTAssertEqual(snapshot?.state, .disconnected)
        XCTAssertEqual(fixture.viewModel.mcpServers, [replacement])
    }

    func testConcurrentSettingsMutationCannotPublishOrOverwriteSuspendedSave() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = configuration()
        let initialSaved = await fixture.viewModel.saveMCPServer(original)
        XCTAssertTrue(initialSaved)
        var replacement = original
        replacement.protocolMode = .stateless
        fixture.writer.mode = .hold
        let save = Task { await fixture.viewModel.saveMCPServer(replacement) }
        try await fixture.writer.waitUntilHeld()
        XCTAssertEqual(fixture.viewModel.mcpServers, [original], "No optimistic publication before durable save.")
        await fixture.viewModel.deleteMCPServer(id: original.id)
        XCTAssertTrue(fixture.viewModel.errorMessage?.contains("正在儲存") == true)
        fixture.writer.release()
        let saved = await save.value
        XCTAssertTrue(saved)
        let loaded = try await fixture.store.load()
        XCTAssertEqual(loaded, [replacement])
        XCTAssertEqual(fixture.viewModel.mcpServers, [replacement])
    }

    private func configuration() -> MCPServerConfiguration {
        .init(name: "Persistence fixture", transport: .stdio(.init(command: "/usr/bin/true")))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: URL
        let writer: PersistenceFixtureWriter
        let secrets: PersistenceFixtureSecrets
        let store: MCPSettingsStore
        let transport: PersistenceFixtureTransport
        let manager: MCPManager
        let viewModel: AgentViewModel

        init(holdInitialization: Bool = false) throws {
            root = AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-viewmodel-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("servers.json")
            writer = PersistenceFixtureWriter()
            secrets = PersistenceFixtureSecrets()
            let fixtureWriter = writer
            store = MCPSettingsStore(fileURL: file, secretStore: secrets, writeData: { data, url in
                try fixtureWriter.write(data, to: url)
            })
            transport = PersistenceFixtureTransport(holdInitialization: holdInitialization)
            let registry = ToolRegistry()
            manager = MCPManager(registry: registry, transportFactory: PersistenceFixtureFactory(transport: transport))
            viewModel = AgentViewModel(registry: registry, mcpSettingsStore: store, mcpManager: manager)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class PersistenceFixtureWriter: @unchecked Sendable {
    enum Mode { case success, failBeforeWrite, commitThenFail, corruptThenFail, hold }
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var currentMode: Mode = .success
    private var held = false
    private var count = 0
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }
    var writes: Int { lock.withLock { count } }

    func write(_ data: Data, to url: URL) throws {
        let mode = lock.withLock { count += 1; return currentMode }
        if mode == .failBeforeWrite { throw POSIXError(.EIO) }
        if mode == .hold {
            lock.withLock { held = true }
            guard gate.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        }
        try AtomicFileWriter.write(mode == .corruptThenFail ? Data("invalid JSON".utf8) : data, to: url)
        if mode == .commitThenFail || mode == .corruptThenFail { throw POSIXError(.EIO) }
    }

    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !lock.withLock({ held }) {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() { gate.signal() }
}

private final class PersistenceFixtureSecrets: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failing = false
    var failDeletes: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    func load(account: String) throws -> String? { lock.withLock { values[account] } }
    func delete(account: String) throws {
        try lock.withLock {
            if failing { throw POSIXError(.EIO) }
            values.removeValue(forKey: account)
        }
    }
}

private struct PersistenceFixtureFactory: MCPTransportFactory {
    let transport: PersistenceFixtureTransport
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport { transport }
}

private actor PersistenceFixtureTransport: MCPTransport {
    private(set) var starts = 0
    private(set) var stops = 0
    private var holdInitialization: Bool
    private var held: CheckedContinuation<Void, Never>?

    init(holdInitialization: Bool) { self.holdInitialization = holdInitialization }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        guard request.id != nil else { return nil }
        if request.method == "initialize" {
            if holdInitialization {
                holdInitialization = false
                await withCheckedContinuation { held = $0 }
            }
            return MCPJSONRPCResponse(jsonrpc: "2.0", id: request.id, result: .object([
                "protocolVersion": .string(MCPClient.protocolVersion), "capabilities": .emptyObject,
                "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])
            ]))
        }
        if request.method == "server/discover" {
            return MCPJSONRPCResponse(jsonrpc: "2.0", id: request.id, result: .object([
                "resultType": .string("complete"),
                "supportedVersions": .array([.string(MCPClient.statelessProtocolVersion)]),
                "capabilities": .emptyObject
            ]))
        }
        throw MCPError.transport("Unexpected fixture request.")
    }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while held == nil {
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func release() { held?.resume(); held = nil }
}
