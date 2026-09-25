import Foundation
import XCTest
@testable import LumaChat

private final class RecordingPTYBackend: PTYBackend, @unchecked Sendable {
    struct Request: Equatable {
        var workspaceRoot: String
        var cwd: String?
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        lock.lock()
        requests.append(.init(
            workspaceRoot: validator.secureRootPath,
            cwd: cwd,
            environment: environment
        ))
        lock.unlock()
        return try DarwinPTYBackend().makeSession(
            validator: validator,
            cwd: cwd,
            environment: environment
        )
    }

    func snapshot() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class FailureInjectingTerminalMetadataWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    private var commitsBeforeFailure = false

    func setShouldFail(_ value: Bool, committingBeforeFailure: Bool = false) {
        lock.lock()
        shouldFail = value
        commitsBeforeFailure = value && committingBeforeFailure
        lock.unlock()
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let fail = shouldFail
        let commit = commitsBeforeFailure
        lock.unlock()
        if fail {
            if commit { try AtomicFileWriter.write(data, to: url) }
            throw POSIXError(.ENOSPC)
        }
        try AtomicFileWriter.write(data, to: url)
    }
}

final class TaskTerminalServiceTests: XCTestCase {
    func testClosePrecommitFailureRetainsTerminalUntilRemovalCanBePersisted() async throws {
        let fixture = try makeFixture("close-precommit-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )
        let terminal = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true)

        do {
            try await service.close(id: terminal.id)
            XCTFail("A close whose removal was not committed must report the failure.")
        } catch {
            // Expected injected pre-commit persistence failure.
        }
        guard case .retryRequired = await service.persistenceState() else {
            return XCTFail("The pending close must remain observable until retry.")
        }
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.map(\.id),
            [terminal.id]
        )
        let pending = try await service.list()
        XCTAssertEqual(pending.map(\.id), [terminal.id])
        let pendingState = await service.persistenceState()
        XCTAssertEqual(pending.first?.persistenceState, pendingState)

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals,
            []
        )
        let remaining = try await service.list()
        XCTAssertEqual(remaining, [])
        await service.disposeAll()
    }

    func testClosePostRenameFailureDefersInMemoryRemovalUntilDurabilityRetry() async throws {
        let fixture = try makeFixture("close-post-rename-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )
        let terminal = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true, committingBeforeFailure: true)

        try await service.close(id: terminal.id)

        guard case .retryRequired = await service.persistenceState() else {
            return XCTFail("A post-rename failure must expose its durability warning.")
        }
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals,
            [],
            "The requested removal was already semantically committed."
        )
        let pending = try await service.list()
        XCTAssertEqual(
            pending.map(\.id),
            [terminal.id],
            "The live descriptor must remain available until durability retry finishes."
        )

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        let remaining = try await service.list()
        XCTAssertEqual(remaining, [])
        await service.disposeAll()
    }

    func testCreatePostRenameFailureKeepsCommittedTerminalAndExposesRetryState() async throws {
        let fixture = try makeFixture("create-post-rename-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        writer.setShouldFail(true, committingBeforeFailure: true)
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )

        let terminal = try await service.create(shell: "/bin/sh")
        guard case .retryRequired = terminal.persistenceState else {
            return XCTFail("A post-rename failure must remain observable.")
        }
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.map(\.id),
            [terminal.id]
        )
        let listed = try await service.list()
        XCTAssertEqual(listed.map(\.id), [terminal.id])

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        await service.disposeAll()
    }

    func testResizePrecommitFailureIsNotReportedDurableAndCanRetry() async throws {
        let fixture = try makeFixture("resize-precommit-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )
        let terminal = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true)

        do {
            _ = try await service.resize(id: terminal.id, rows: 40, columns: 100)
            XCTFail("A pre-commit metadata failure must be reported.")
        } catch {
            // Expected injected persistence failure.
        }
        guard case .retryRequired = await service.persistenceState() else {
            return XCTFail("The mutated runtime state must remain pending, not durable.")
        }
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.first?.rows,
            24
        )

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.first?.rows,
            40
        )
        await service.disposeAll()
    }

    func testNaturalExitPersistenceFailureIsObservableAndRetryable() async throws {
        let fixture = try makeFixture("natural-exit-persistence-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )
        let terminal = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true)
        _ = try await service.write(id: terminal.id, text: "exit 23\n")

        let failedState = try await waitForPersistenceRetry(service)
        guard case .retryRequired(let detail) = failedState else {
            return XCTFail("Expected retry-required persistence state.")
        }
        XCTAssertFalse(detail.isEmpty)
        let descriptors = try await service.list()
        let descriptor = try XCTUnwrap(descriptors.first(where: { $0.id == terminal.id }))
        XCTAssertEqual(descriptor.metadata.state, .exited)
        XCTAssertEqual(descriptor.persistenceState, failedState)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.first?.state,
            .running
        )

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.first?.state,
            .exited
        )
        await service.disposeAll()
    }

    func testDisposeAllPersistenceFailureReturnsRetryableRetainedSnapshot() async throws {
        let fixture = try makeFixture("dispose-persistence-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let writer = FailureInjectingTerminalMetadataWriter()
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot,
            metadataWriter: writer.write
        )
        _ = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true)

        let disposalState = await service.disposeAll()
        guard case .retryRequired = disposalState else {
            return XCTFail("disposeAll must report that its stopped snapshot is not durable.")
        }
        let retainedState = await service.persistenceState()
        XCTAssertEqual(retainedState, disposalState)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
                .terminals.first?.state,
            .running
        )

        writer.setShouldFail(false)
        let retryState = try await service.retryPendingPersistence()
        XCTAssertEqual(retryState, .durable)
        let persistedState = try readMetadata(
            taskID: taskID,
            sessionsRoot: fixture.sessionsRoot
        ).terminals.first?.state
        XCTAssertNotEqual(persistedState, .running)
        let finalState = await service.persistenceState()
        XCTAssertEqual(finalState, .durable)
    }

    func testToolEnvironmentRetainsDisposedServiceUntilShutdownSnapshotIsDurable() async throws {
        let fixture = try makeFixture("environment-dispose-persistence-failure")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let writer = FailureInjectingTerminalMetadataWriter()
        let sessionsRoot = fixture.sessionsRoot
        let environment = BuiltinToolEnvironment(
            taskTerminalServiceFactory: { taskID, validator in
                TaskTerminalService(
                    taskID: taskID,
                    validator: validator,
                    sessionsRoot: sessionsRoot,
                    metadataWriter: writer.write
                )
            }
        )
        let sessionID = UUID()
        let taskID = UUID()
        let context = AgentToolContext(
            sessionID: sessionID,
            taskID: taskID,
            mode: .agent,
            workspace: fixture.workspace,
            temporaryRoot: fixture.scratch
        )
        let service = try await environment.taskTerminalService(for: context)
        _ = try await service.create(shell: "/bin/sh")
        writer.setShouldFail(true)

        do {
            try await environment.remove(sessionID: sessionID)
            XCTFail("A nondurable terminal snapshot must block Session removal.")
        } catch let error as BuiltinToolEnvironmentConfigurationError {
            guard case .terminalPersistencePending = error else {
                return XCTFail("Expected terminalPersistencePending, got \(error)")
            }
        }
        let retainedCount = await environment.pendingTaskTerminalPersistenceCount()
        XCTAssertEqual(retainedCount, 1)
        XCTAssertEqual(
            try readMetadata(taskID: taskID, sessionsRoot: sessionsRoot).terminals.first?.state,
            .running
        )
        do {
            _ = try await environment.taskTerminalService(for: context)
            XCTFail("A task must not reopen while its stopped snapshot is nondurable.")
        } catch let error as BuiltinToolEnvironmentConfigurationError {
            guard case .terminalPersistencePending = error else {
                return XCTFail("Expected terminalPersistencePending, got \(error)")
            }
        }

        var reboundWorkspace = fixture.workspace
        reboundWorkspace.id = UUID()
        let reboundContext = AgentToolContext(
            sessionID: sessionID,
            taskID: taskID,
            mode: .agent,
            workspace: reboundWorkspace,
            temporaryRoot: fixture.scratch
        )
        do {
            _ = try await environment.taskTerminalService(for: reboundContext)
            XCTFail("A workspace rebind must not bypass a pending Task Terminal disposal.")
        } catch let error as BuiltinToolEnvironmentConfigurationError {
            guard case .terminalPersistencePending = error else {
                return XCTFail("Expected terminalPersistencePending, got \(error)")
            }
        }

        writer.setShouldFail(false)
        try await environment.remove(sessionID: sessionID)
        let finalCount = await environment.pendingTaskTerminalPersistenceCount()
        XCTAssertEqual(finalCount, 0)
        XCTAssertNotEqual(
            try readMetadata(taskID: taskID, sessionsRoot: sessionsRoot).terminals.first?.state,
            .running
        )
    }

    func testTaskServiceCreatesTransportOnlyThroughInjectedPTYBackend() async throws {
        let fixture = try makeFixture("backend-seam")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let backend = RecordingPTYBackend()
        let service = TaskTerminalService(
            taskID: UUID(),
            validator: fixture.validator,
            backend: backend,
            sessionsRoot: fixture.sessionsRoot
        )
        do {
            let descriptor = try await service.create(
                cwd: ".",
                environment: ["BACKEND_PROBE": "safe"],
                shell: "/bin/sh"
            )
            XCTAssertEqual(backend.snapshot(), [
                .init(
                    workspaceRoot: fixture.validator.secureRootPath,
                    cwd: ".",
                    environment: ["BACKEND_PROBE": "safe"]
                )
            ])
            try await service.close(id: descriptor.id)
        } catch {
            await service.disposeAll()
            throw error
        }
        await service.disposeAll()
    }

    func testMetadataRoundTripAndRunningStateBecomesDisconnected() async throws {
        let fixture = try makeFixture("metadata-roundtrip")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let exitedID = UUID()
        let runningID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let exited = makeMetadata(
            id: exitedID,
            taskID: taskID,
            title: "Finished shell",
            state: .exited,
            now: now,
            workspace: fixture.workspace
        )
        let running = makeMetadata(
            id: runningID,
            taskID: taskID,
            title: "Previously running",
            state: .running,
            now: now,
            workspace: fixture.workspace
        )
        try writeMetadata([exited, running], taskID: taskID, sessionsRoot: fixture.sessionsRoot)

        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot
        )
        let firstLoad = try await service.list()
        XCTAssertEqual(firstLoad.map(\.id), [exitedID, runningID])
        XCTAssertEqual(firstLoad[0].metadata.state, .exited)
        XCTAssertEqual(firstLoad[1].metadata.state, .disconnected)
        XCTAssertNil(firstLoad[1].processIdentifier)

        let renamed = try await service.rename(id: exitedID, title: "  Renamed shell  ")
        XCTAssertEqual(renamed.title, "Renamed shell")

        let reloadedService = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot
        )
        let reloaded = try await reloadedService.list()
        XCTAssertEqual(reloaded.first(where: { $0.id == exitedID })?.metadata.title, "Renamed shell")
        XCTAssertEqual(
            reloaded.first(where: { $0.id == runningID })?.metadata.state,
            .disconnected
        )

        let persisted = try readMetadata(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
        XCTAssertEqual(persisted.terminals.first(where: { $0.id == exitedID })?.title, "Renamed shell")
        XCTAssertEqual(
            persisted.terminals.first(where: { $0.id == runningID })?.state,
            .disconnected
        )
        await service.disposeAll()
        await reloadedService.disposeAll()
    }

    func testCorruptMetadataIsRejected() async throws {
        let fixture = try makeFixture("corrupt-metadata")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let file = try metadataFile(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
        try Data("{ definitely-not-json".utf8).write(to: file)
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot
        )

        do {
            _ = try await service.list()
            XCTFail("Corrupt terminal metadata must not be accepted.")
        } catch {
            XCTAssertTrue(error is DecodingError, "unexpected error: \(error)")
        }
        await service.disposeAll()
    }

    func testOversizedMetadataFileIsRejectedBeforeDecode() async throws {
        let fixture = try makeFixture("oversized-metadata")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let taskID = UUID()
        let file = try metadataFile(taskID: taskID, sessionsRoot: fixture.sessionsRoot)
        try Data(repeating: 0x20, count: 256 * 1_024 + 1).write(to: file)
        let service = TaskTerminalService(
            taskID: taskID,
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot
        )

        do {
            _ = try await service.list()
            XCTFail("Oversized terminal metadata must not be decoded.")
        } catch let error as TaskTerminalError {
            XCTAssertEqual(
                error,
                .corruptMetadata("metadata is not a bounded regular file")
            )
        }
        await service.disposeAll()
    }

    func testMultipleTerminalsKeepInputOutputClearAndLifecycleIsolated() async throws {
        let fixture = try makeFixture("multiple-terminals")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let service = TaskTerminalService(
            taskID: UUID(),
            validator: fixture.validator,
            sessionsRoot: fixture.sessionsRoot
        )
        do {
            let first = try await service.create(title: "Alpha", shell: "/bin/sh")
            let second = try await service.create(title: "Beta", shell: "/bin/sh")
            XCTAssertNotEqual(first.id, second.id)
            XCTAssertNotEqual(first.processIdentifier, second.processIdentifier)

            // Do not let terminal echo satisfy marker assertions before the
            // shell has actually executed the corresponding command.
            _ = try await service.write(id: first.id, text: "stty -echo\n")
            _ = try await service.write(id: second.id, text: "stty -echo\n")
            try await Task.sleep(for: .milliseconds(100))

            // The first write intentionally leaves a canonical line incomplete.
            // The second call must append after it, preserving service input order.
            _ = try await service.write(
                id: first.id,
                text: "printf 'ALPHA-FIRST\\n'; "
            )
            _ = try await service.write(
                id: first.id,
                text: "printf 'ALPHA-SECOND\\n'\n"
            )
            _ = try await service.write(
                id: second.id,
                text: "printf 'BETA-ONLY\\n'\n"
            )

            let alpha = try await waitForOutput(
                service,
                id: first.id,
                containing: "ALPHA-SECOND"
            )
            let beta = try await waitForOutput(
                service,
                id: second.id,
                containing: "BETA-ONLY"
            )
            let alphaText = String(decoding: alpha.data, as: UTF8.self)
            let betaText = String(decoding: beta.data, as: UTF8.self)
            let firstRange = try XCTUnwrap(alphaText.range(of: "ALPHA-FIRST"))
            let secondRange = try XCTUnwrap(alphaText.range(of: "ALPHA-SECOND"))
            XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
            XCTAssertFalse(alphaText.contains("BETA-ONLY"))
            XCTAssertFalse(betaText.contains("ALPHA-FIRST"))

            let renamed = try await service.rename(id: first.id, title: "  Build shell  ")
            XCTAssertEqual(renamed.title, "Build shell")
            let cleared = try await service.clear(id: first.id)
            XCTAssertEqual(cleared.metadata.clearGeneration, 1)
            _ = try await service.write(
                id: first.id,
                text: "printf 'ALPHA-AFTER-CLEAR\\n'\n"
            )
            let afterClear = try await waitForOutput(
                service,
                id: first.id,
                containing: "ALPHA-AFTER-CLEAR"
            )
            let afterClearText = String(decoding: afterClear.data, as: UTF8.self)
            XCTAssertFalse(afterClearText.contains("ALPHA-FIRST"))
            XCTAssertTrue(afterClear.truncatedBeforeOffset)
            XCTAssertEqual(afterClear.clearGeneration, 1)

            _ = try await service.kill(id: first.id)
            _ = try await service.write(
                id: second.id,
                text: "printf 'BETA-STILL-ALIVE\\n'\n"
            )
            _ = try await waitForOutput(
                service,
                id: second.id,
                containing: "BETA-STILL-ALIVE"
            )

            let reconnected = try await service.reconnect(
                id: first.id,
                shell: "/bin/sh"
            )
            XCTAssertEqual(reconnected.id, first.id)
            XCTAssertEqual(reconnected.metadata.title, "Build shell")
            XCTAssertEqual(reconnected.metadata.state, .running)
            XCTAssertEqual(reconnected.metadata.reconnectCount, 1)
            XCTAssertNotNil(reconnected.processIdentifier)
            _ = try await service.write(id: first.id, text: "stty -echo\n")
            try await Task.sleep(for: .milliseconds(100))
            _ = try await service.write(
                id: first.id,
                text: "printf 'ALPHA-RECONNECTED\\n'\n"
            )
            _ = try await waitForOutput(
                service,
                id: first.id,
                containing: "ALPHA-RECONNECTED"
            )

            try await service.close(id: first.id)
            let remaining = try await service.list()
            XCTAssertEqual(remaining.map(\.id), [second.id])
        } catch {
            await service.disposeAll()
            throw error
        }
        await service.disposeAll()
    }

    private struct Fixture {
        var scratch: URL
        var sessionsRoot: URL
        var workspace: AgentWorkspace
        var validator: WorkspaceSecurityValidator
    }

    private struct MetadataDocument: Codable {
        var version: Int
        var terminals: [TaskTerminalMetadata]
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let scratch = AppPaths.projectTemporaryRoot
            .appendingPathComponent("task-terminal-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = scratch.appendingPathComponent("workspace", isDirectory: true)
        let sessionsRoot = scratch.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )
        let workspace = AgentWorkspace(
            name: workspaceRoot.lastPathComponent,
            rootPath: workspaceRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        return Fixture(
            scratch: scratch,
            sessionsRoot: sessionsRoot,
            workspace: workspace,
            validator: try WorkspaceSecurityValidator(workspace: workspace)
        )
    }

    private func makeMetadata(
        id: UUID,
        taskID: UUID,
        title: String,
        state: TaskTerminalLifecycleState,
        now: Date,
        workspace: AgentWorkspace
    ) -> TaskTerminalMetadata {
        TaskTerminalMetadata(
            id: id,
            taskID: taskID,
            title: title,
            createdAt: now,
            updatedAt: now,
            lastStartedAt: now,
            state: state,
            rows: 24,
            columns: 80,
            exitCode: state == .exited ? 0 : nil,
            terminationSignal: nil,
            clearGeneration: 0,
            reconnectCount: 0,
            workspaceID: workspace.id,
            workspaceRootPath: workspace.rootPath,
            workingDirectory: workspace.rootPath,
            shell: "/bin/sh",
            capabilities: TaskTerminalCapabilities(
                network: false,
                gitMetadataRead: false,
                gitMetadataWrite: false,
                workspaceWrite: true
            ),
            earliestAvailableOffset: 0,
            nextOffset: 0
        )
    }

    private func metadataFile(taskID: UUID, sessionsRoot: URL) throws -> URL {
        let directory = sessionsRoot
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
            .appendingPathComponent("Terminals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("metadata.json")
    }

    private func writeMetadata(
        _ terminals: [TaskTerminalMetadata],
        taskID: UUID,
        sessionsRoot: URL
    ) throws {
        let data = try JSONEncoder().encode(
            MetadataDocument(version: 1, terminals: terminals)
        )
        try data.write(to: metadataFile(taskID: taskID, sessionsRoot: sessionsRoot))
    }

    private func readMetadata(
        taskID: UUID,
        sessionsRoot: URL
    ) throws -> MetadataDocument {
        let file = try metadataFile(taskID: taskID, sessionsRoot: sessionsRoot)
        return try JSONDecoder().decode(MetadataDocument.self, from: Data(contentsOf: file))
    }

    private func waitForOutput(
        _ service: TaskTerminalService,
        id: UUID,
        containing expected: String,
        timeout: Duration = .seconds(5)
    ) async throws -> TaskTerminalOutput {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            let output = try await service.read(id: id, offset: 0, maxBytes: 1 * 1_024 * 1_024)
            if String(decoding: output.data, as: UTF8.self).contains(expected) {
                return output
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Task terminal output: \(expected)")
        return try await service.read(id: id, offset: 0, maxBytes: 1 * 1_024 * 1_024)
    }

    private func waitForPersistenceRetry(
        _ service: TaskTerminalService,
        timeout: Duration = .seconds(5)
    ) async throws -> TaskTerminalPersistenceState {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            let state = await service.persistenceState()
            if case .retryRequired = state { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for terminal metadata persistence failure.")
        return await service.persistenceState()
    }
}
