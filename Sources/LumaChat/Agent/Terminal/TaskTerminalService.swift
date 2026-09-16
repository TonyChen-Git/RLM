import Darwin
import Foundation

enum TaskTerminalError: LocalizedError, Equatable, Sendable {
    case terminalNotFound(UUID)
    case terminalLimit(Int)
    case terminalBusy(UUID)
    case invalidTitle
    case invalidSignal(String)
    case corruptMetadata(String)
    case metadataTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .terminalNotFound(let id):
            "Terminal \(id.uuidString) does not belong to this Task."
        case .terminalLimit(let limit):
            "A Task can keep at most \(limit) terminal sessions."
        case .terminalBusy(let id):
            "Terminal \(id.uuidString) is already changing lifecycle state."
        case .invalidTitle:
            "Terminal title is empty, oversized, or contains control characters."
        case .invalidSignal(let value):
            "Unsupported terminal signal: \(value)"
        case .corruptMetadata(let detail):
            "Terminal metadata is invalid: \(detail)"
        case .metadataTooLarge(let maximum):
            "Terminal metadata exceeds the \(maximum)-byte limit."
        }
    }
}

enum TaskTerminalLifecycleState: String, Codable, Equatable, Sendable {
    case running
    case exited
    case stopped
    /// A previous app process owned the PTY. The process is never guessed to
    /// still exist; the user can explicitly reconnect into a fresh shell.
    case disconnected
    case failed
}

enum TaskTerminalSignal: String, Codable, CaseIterable, Sendable {
    case interrupt
    case quit
    case hangup
    case terminate
    case kill
    case suspend
    case resume

    var posixValue: Int32 {
        switch self {
        case .interrupt: SIGINT
        case .quit: SIGQUIT
        case .hangup: SIGHUP
        case .terminate: SIGTERM
        case .kill: SIGKILL
        case .suspend: SIGTSTP
        case .resume: SIGCONT
        }
    }
}

struct TaskTerminalCapabilities: Codable, Equatable, Sendable {
    var network: Bool
    var gitMetadataRead: Bool
    var gitMetadataWrite: Bool
    var workspaceWrite: Bool
}

struct TaskTerminalMetadata: Codable, Equatable, Identifiable, Sendable {
    static let maximumTitleBytes = 160

    var id: UUID
    var taskID: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var lastStartedAt: Date?
    var state: TaskTerminalLifecycleState
    var rows: UInt16
    var columns: UInt16
    var exitCode: Int32?
    var terminationSignal: Int32?
    var clearGeneration: UInt64
    var reconnectCount: UInt32
    /// Durable binding evidence only. Environment values, commands, PIDs and
    /// raw scrollback are deliberately never persisted.
    var workspaceID: UUID?
    var workspaceRootPath: String?
    var workingDirectory: String?
    var shell: String?
    var capabilities: TaskTerminalCapabilities?
    var earliestAvailableOffset: Int64?
    var nextOffset: Int64?

    static func normalizedTitle(_ proposed: String) -> String? {
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumTitleBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return value
    }
}

struct TaskTerminalDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { metadata.id }
    var metadata: TaskTerminalMetadata
    var processIdentifier: Int32?
    var duration: TimeInterval
    var transportErrorCode: Int32?
    var earliestAvailableOffset: Int64
    var nextOffset: Int64
}

struct TaskTerminalOutput: Codable, Equatable, Sendable {
    var terminalID: UUID
    var data: Data
    var offset: Int64
    var nextOffset: Int64
    var earliestAvailableOffset: Int64
    var hasMore: Bool
    var truncatedBeforeOffset: Bool
    var clearGeneration: UInt64
}

enum TaskTerminalEventKind: String, Codable, Equatable, Sendable {
    case snapshot
    case output
    case removed
}

struct TaskTerminalEvent: Codable, Equatable, Sendable {
    var taskID: UUID
    var terminalID: UUID
    var kind: TaskTerminalEventKind
    var descriptor: TaskTerminalDescriptor?
    var output: TaskTerminalOutput?
}

private struct TaskTerminalMetadataDocument: Codable, Sendable {
    var version: Int
    var terminals: [TaskTerminalMetadata]
}

private struct TaskTerminalMetadataStore: Sendable {
    static let maximumDocumentBytes = 256 * 1_024
    let taskID: UUID
    let root: URL

    init(taskID: UUID, sessionsRoot: URL = AppPaths.agentSessions) {
        self.taskID = taskID
        root = sessionsRoot.standardizedFileURL
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
            .appendingPathComponent("Terminals", isDirectory: true)
    }

    func load() throws -> [TaskTerminalMetadata] {
        let file = metadataFile
        let descriptor = Darwin.open(
            file.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw TaskTerminalError.corruptMetadata("metadata cannot be inspected")
        }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumDocumentBytes else {
            throw TaskTerminalError.corruptMetadata("metadata is not a bounded regular file")
        }
        let expectedBytes = Int(info.st_size)
        var data = Data(count: expectedBytes)
        var offset = 0
        while offset < expectedBytes {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    expectedBytes - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw TaskTerminalError.corruptMetadata("metadata changed while being read")
            }
            offset += count
        }
        var finalInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_mode & S_IFMT == S_IFREG,
              finalInfo.st_nlink == 1,
              finalInfo.st_size == info.st_size,
              finalInfo.st_dev == info.st_dev,
              finalInfo.st_ino == info.st_ino else {
            throw TaskTerminalError.corruptMetadata("metadata changed while being read")
        }
        let document = try JSONDecoder().decode(TaskTerminalMetadataDocument.self, from: data)
        guard document.version == 1,
              document.terminals.count <= TaskTerminalService.maximumTerminals,
              Set(document.terminals.map(\.id)).count == document.terminals.count,
              document.terminals.allSatisfy({ metadata in
                  metadata.taskID == taskID
                      && TaskTerminalMetadata.normalizedTitle(metadata.title) == metadata.title
                      && (1...1_000).contains(Int(metadata.rows))
                      && (1...1_000).contains(Int(metadata.columns))
              }) else {
            throw TaskTerminalError.corruptMetadata("identity, title, dimensions, or count failed validation")
        }
        return document.terminals
    }

    func save(_ terminals: [TaskTerminalMetadata]) throws {
        guard terminals.count <= TaskTerminalService.maximumTerminals,
              Set(terminals.map(\.id)).count == terminals.count,
              terminals.allSatisfy({ $0.taskID == taskID }) else {
            throw TaskTerminalError.corruptMetadata("refusing to persist an invalid Task terminal set")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonicalParent = root.deletingLastPathComponent().standardizedFileURL
        guard root.standardizedFileURL.deletingLastPathComponent() == canonicalParent,
              root.lastPathComponent == "Terminals",
              canonicalParent.lastPathComponent == taskID.uuidString else {
            throw TaskTerminalError.corruptMetadata("metadata root escaped the Task directory")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(
            TaskTerminalMetadataDocument(version: 1, terminals: terminals)
        )
        guard data.count <= Self.maximumDocumentBytes else {
            throw TaskTerminalError.metadataTooLarge(Self.maximumDocumentBytes)
        }
        try AtomicFileWriter.write(data, to: metadataFile)
    }

    private var metadataFile: URL {
        root.appendingPathComponent("metadata.json", isDirectory: false)
    }
}

/// Owns all interactive PTYs for one Task/workspace binding. This actor is
/// shared by the Task Terminal pane and structured Agent tools, so a terminal
/// handle always resolves within exactly one Task and cannot be guessed across
/// workspaces.
actor TaskTerminalService {
    static let maximumTerminals = 16
    static let defaultRows = 24
    static let defaultColumns = 80

    private final class Entry: @unchecked Sendable {
        var metadata: TaskTerminalMetadata
        var transport: (any PTYSessionTransport)?
        var visibleStartOffset: Int64 = 0
        var exitObserver: Task<Void, Never>?
        var outputPump: Task<Void, Never>?
        var writeTail: Task<Void, Never>?
        var pumpOffset: Int64 = 0
        var isTransitioning = false

        init(
            metadata: TaskTerminalMetadata,
            transport: (any PTYSessionTransport)? = nil
        ) {
            self.metadata = metadata
            self.transport = transport
        }
    }

    private let taskID: UUID
    private let validator: WorkspaceSecurityValidator
    private let backend: any PTYBackend
    private let store: TaskTerminalMetadataStore
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var didLoad = false
    private var isDisposed = false
    private var pendingCreations = 0
    private var subscribers: [UUID: AsyncStream<TaskTerminalEvent>.Continuation] = [:]

    init(
        taskID: UUID,
        validator: WorkspaceSecurityValidator,
        backend: any PTYBackend = DarwinPTYBackend(),
        sessionsRoot: URL = AppPaths.agentSessions
    ) {
        self.taskID = taskID
        self.validator = validator
        self.backend = backend
        store = TaskTerminalMetadataStore(taskID: taskID, sessionsRoot: sessionsRoot)
    }

    deinit {
        for entry in entries.values {
            entry.exitObserver?.cancel()
            entry.outputPump?.cancel()
            if let transport = entry.transport {
                Task { await transport.dispose() }
            }
        }
    }

    func list() async throws -> [TaskTerminalDescriptor] {
        try loadIfNeeded()
        var result: [TaskTerminalDescriptor] = []
        for id in order {
            guard let entry = entries[id] else { continue }
            result.append(await descriptor(for: entry))
        }
        return result
    }

    /// A view attaches once, obtains a bounded replay with read(), then consumes
    /// this push stream. Navigation only removes the continuation; PTYs and
    /// their output pumps remain Task-owned.
    func events() throws -> AsyncStream<TaskTerminalEvent> {
        try loadIfNeeded()
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            subscribers[subscriberID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    func create(
        title proposedTitle: String? = nil,
        cwd: String? = nil,
        environment: [String: String] = [:],
        shell: String = "/bin/zsh",
        rows: Int = defaultRows,
        columns: Int = defaultColumns,
        allowsNetwork: Bool = false
    ) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        guard !isDisposed else { throw PseudoTerminalError.disposed }
        guard (1...1_000).contains(rows), (1...1_000).contains(columns) else {
            throw PseudoTerminalError.invalidDimensions
        }
        guard entries.count + pendingCreations < Self.maximumTerminals else {
            throw TaskTerminalError.terminalLimit(Self.maximumTerminals)
        }
        pendingCreations += 1
        defer { pendingCreations -= 1 }
        let validatedDirectory: URL
        do {
            validatedDirectory = try validator.validate(cwd: cwd)
        } catch {
            throw PseudoTerminalError.workspaceBoundary(cwd ?? ".")
        }
        let durableWorkingDirectory = validator.relativePath(for: validatedDirectory)
        let ordinal = entries.count + 1
        let title = try normalizedTitle(proposedTitle ?? "Terminal \(ordinal)")
        let id = UUID()
        let now = Date()
        let metadata = TaskTerminalMetadata(
            id: id,
            taskID: taskID,
            title: title,
            createdAt: now,
            updatedAt: now,
            lastStartedAt: now,
            state: .running,
            rows: UInt16(rows),
            columns: UInt16(columns),
            exitCode: nil,
            terminationSignal: nil,
            clearGeneration: 0,
            reconnectCount: 0,
            workspaceID: validator.workspace.id,
            workspaceRootPath: validator.secureRootPath,
            workingDirectory: durableWorkingDirectory,
            shell: shell,
            capabilities: TaskTerminalCapabilities(
                network: allowsNetwork,
                gitMetadataRead: validator.workspace.gitRepository,
                gitMetadataWrite: validator.workspace.gitRepository,
                workspaceWrite: true
            ),
            earliestAvailableOffset: 0,
            nextOffset: 0
        )
        let transport = try backend.makeSession(
            validator: validator,
            cwd: durableWorkingDirectory,
            environment: environment
        )
        do {
            _ = try await transport.start(
                command: nil,
                cwd: durableWorkingDirectory,
                environment: environment,
                shell: shell,
                rows: rows,
                columns: columns,
                allowsNetwork: allowsNetwork,
                allowsGitMetadata: validator.workspace.gitRepository,
                allowsGitMetadataWrite: validator.workspace.gitRepository
            )
        } catch {
            await transport.dispose()
            throw error
        }
        let entry = Entry(metadata: metadata, transport: transport)
        entries[id] = entry
        order.append(id)
        do {
            try persist()
        } catch {
            entries.removeValue(forKey: id)
            order.removeAll { $0 == id }
            await transport.dispose()
            throw error
        }
        observeExit(id: id, entry: entry, transport: transport)
        startOutputPump(id: id, entry: entry, transport: transport)
        let result = await descriptor(for: entry)
        emit(.init(
            taskID: taskID,
            terminalID: id,
            kind: .snapshot,
            descriptor: result,
            output: nil
        ))
        return result
    }

    func reconnect(
        id: UUID,
        environment: [String: String] = [:],
        shell requestedShell: String? = nil,
        allowsNetwork requestedNetwork: Bool? = nil
    ) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try beginTransition(entry, id: id)
        defer { entry.isTransitioning = false }
        if let transport = entry.transport,
           (try? await transport.status().state) == .running {
            return await descriptor(for: entry)
        }
        let previousMetadata = entry.metadata
        let previousVisibleStartOffset = entry.visibleStartOffset
        let previousPumpOffset = entry.pumpOffset
        if let oldTransport = entry.transport {
            entry.exitObserver?.cancel()
            entry.outputPump?.cancel()
            await oldTransport.dispose()
            entry.transport = nil
        }
        let shell = requestedShell ?? entry.metadata.shell ?? "/bin/zsh"
        let allowsNetwork = requestedNetwork
            ?? entry.metadata.capabilities?.network
            ?? false
        let transport = try backend.makeSession(
            validator: validator,
            cwd: entry.metadata.workingDirectory,
            environment: environment
        )
        do {
            _ = try await transport.start(
                command: nil,
                cwd: entry.metadata.workingDirectory,
                environment: environment,
                shell: shell,
                rows: Int(entry.metadata.rows),
                columns: Int(entry.metadata.columns),
                allowsNetwork: allowsNetwork,
                allowsGitMetadata: entry.metadata.capabilities?.gitMetadataRead
                    ?? validator.workspace.gitRepository,
                allowsGitMetadataWrite: entry.metadata.capabilities?.gitMetadataWrite
                    ?? validator.workspace.gitRepository
            )
        } catch {
            await transport.dispose()
            throw error
        }
        let now = Date()
        entry.transport = transport
        entry.visibleStartOffset = 0
        entry.metadata.state = .running
        entry.metadata.updatedAt = now
        entry.metadata.lastStartedAt = now
        entry.metadata.exitCode = nil
        entry.metadata.terminationSignal = nil
        entry.metadata.clearGeneration &+= 1
        entry.metadata.reconnectCount &+= 1
        entry.metadata.shell = shell
        entry.metadata.capabilities = TaskTerminalCapabilities(
            network: allowsNetwork,
            gitMetadataRead: entry.metadata.capabilities?.gitMetadataRead
                ?? validator.workspace.gitRepository,
            gitMetadataWrite: entry.metadata.capabilities?.gitMetadataWrite
                ?? validator.workspace.gitRepository,
            workspaceWrite: true
        )
        do {
            try persist()
        } catch {
            entry.exitObserver?.cancel()
            entry.outputPump?.cancel()
            entry.transport = nil
            entry.metadata = previousMetadata
            entry.visibleStartOffset = previousVisibleStartOffset
            entry.pumpOffset = previousPumpOffset
            await transport.dispose()
            throw error
        }
        observeExit(id: id, entry: entry, transport: transport)
        startOutputPump(id: id, entry: entry, transport: transport)
        let result = await descriptor(for: entry)
        emit(.init(
            taskID: taskID,
            terminalID: id,
            kind: .snapshot,
            descriptor: result,
            output: nil
        ))
        return result
    }

    func rename(id: UUID, title: String) async throws -> TaskTerminalMetadata {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        let previousMetadata = entry.metadata
        entry.metadata.title = try normalizedTitle(title)
        entry.metadata.updatedAt = Date()
        do {
            try persist()
        } catch {
            entry.metadata = previousMetadata
            throw error
        }
        let descriptor = await descriptor(for: entry)
        emit(.init(
            taskID: taskID,
            terminalID: id,
            kind: .snapshot,
            descriptor: descriptor,
            output: nil
        ))
        return entry.metadata
    }

    func read(
        id: UUID,
        offset requestedOffset: Int64,
        maxBytes: Int = 64 * 1_024
    ) async throws -> TaskTerminalOutput {
        try loadIfNeeded()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        guard let transport = entry.transport else {
            let unavailableOffset = max(
                0,
                entry.metadata.nextOffset ?? entry.visibleStartOffset
            )
            return TaskTerminalOutput(
                terminalID: id,
                data: Data(),
                offset: unavailableOffset,
                nextOffset: unavailableOffset,
                earliestAvailableOffset: unavailableOffset,
                hasMore: false,
                truncatedBeforeOffset: requestedOffset < unavailableOffset,
                clearGeneration: entry.metadata.clearGeneration
            )
        }
        let effectiveOffset = max(requestedOffset, entry.visibleStartOffset)
        let output = try await transport.readOutput(
            offset: effectiveOffset,
            maxBytes: maxBytes
        )
        let earliest = max(output.earliestAvailableOffset, entry.visibleStartOffset)
        return TaskTerminalOutput(
            terminalID: id,
            data: output.data,
            offset: output.offset,
            nextOffset: output.nextOffset,
            earliestAvailableOffset: earliest,
            hasMore: output.hasMore,
            truncatedBeforeOffset: requestedOffset < earliest
                || output.truncatedBeforeOffset,
            clearGeneration: entry.metadata.clearGeneration
        )
    }

    func write(id: UUID, data: Data) async throws -> PseudoTerminalWriteResult {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        guard let transport = entry.transport else {
            throw PseudoTerminalError.notRunning
        }
        let predecessor = entry.writeTail
        let operation = Task<PseudoTerminalWriteResult, Error> {
            if let predecessor { await predecessor.value }
            return try await transport.write(data)
        }
        entry.writeTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    func write(id: UUID, text: String) async throws -> PseudoTerminalWriteResult {
        try await write(id: id, data: Data(text.utf8))
    }

    func sendEOF(id: UUID) async throws -> PseudoTerminalWriteResult {
        try await write(id: id, data: Data([0x04]))
    }

    func resize(id: UUID, rows: Int, columns: Int) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        guard let transport = entry.transport else {
            throw PseudoTerminalError.notRunning
        }
        let status = try await transport.resize(rows: rows, columns: columns)
        entry.metadata.rows = status.dimensions.rows
        entry.metadata.columns = status.dimensions.columns
        entry.metadata.updatedAt = Date()
        try persist()
        let result = await descriptor(for: entry)
        emit(.init(taskID: taskID, terminalID: id, kind: .snapshot, descriptor: result, output: nil))
        return result
    }

    func signal(id: UUID, signal: TaskTerminalSignal) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        guard let transport = entry.transport else {
            throw PseudoTerminalError.notRunning
        }
        _ = try await transport.signal(signal.posixValue)
        let result = await descriptor(for: entry)
        emit(.init(taskID: taskID, terminalID: id, kind: .snapshot, descriptor: result, output: nil))
        return result
    }

    func clear(id: UUID) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try requireStable(entry, id: id)
        if let transport = entry.transport {
            if let bounds = try? await transport.outputBounds() {
                entry.visibleStartOffset = bounds.nextOffset
                entry.pumpOffset = bounds.nextOffset
                entry.metadata.earliestAvailableOffset = bounds.nextOffset
                entry.metadata.nextOffset = bounds.nextOffset
            }
        }
        entry.metadata.clearGeneration &+= 1
        entry.metadata.updatedAt = Date()
        try persist()
        let result = await descriptor(for: entry)
        emit(.init(taskID: taskID, terminalID: id, kind: .snapshot, descriptor: result, output: nil))
        return result
    }

    func kill(id: UUID) async throws -> TaskTerminalDescriptor {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try beginTransition(entry, id: id)
        defer { entry.isTransitioning = false }
        if let transport = entry.transport {
            _ = try? await transport.signal(SIGKILL)
            // stop() is bounded and closes the master if a descendant keeps the
            // slave open; never wait forever on an untrusted job tree.
            _ = try? await transport.stop()
        }
        await refreshMetadata(entry)
        if entry.metadata.state == .running { entry.metadata.state = .stopped }
        entry.metadata.updatedAt = Date()
        try persist()
        let result = await descriptor(for: entry)
        emit(.init(taskID: taskID, terminalID: id, kind: .snapshot, descriptor: result, output: nil))
        return result
    }

    func close(id: UUID) async throws {
        try loadIfNeeded()
        try ensureActive()
        let entry = try entry(id)
        try beginTransition(entry, id: id)
        defer { entry.isTransitioning = false }
        entry.exitObserver?.cancel()
        entry.outputPump?.cancel()
        if let transport = entry.transport {
            await transport.dispose()
            await refreshMetadata(entry)
            entry.transport = nil
        }
        let remainingOrder = order.filter { $0 != id }
        try store.save(remainingOrder.compactMap { entries[$0]?.metadata })
        entries.removeValue(forKey: id)
        order = remainingOrder
        emit(.init(taskID: taskID, terminalID: id, kind: .removed, descriptor: nil, output: nil))
    }

    func disposeAll() async {
        guard !isDisposed else { return }
        isDisposed = true
        try? loadIfNeeded()
        for id in order {
            guard let entry = entries[id] else { continue }
            entry.exitObserver?.cancel()
            entry.outputPump?.cancel()
            if let transport = entry.transport {
                _ = try? await transport.stop()
                await refreshMetadata(entry)
                await transport.dispose()
                entry.transport = nil
            }
            if entry.metadata.state == .running {
                entry.metadata.state = .stopped
            }
            entry.metadata.updatedAt = Date()
        }
        try? persist()
        let activeSubscribers = Array(subscribers.values)
        subscribers.removeAll()
        for continuation in activeSubscribers { continuation.finish() }
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        let stored = try store.load()
        for var metadata in stored {
            try reconcilePersistedBinding(&metadata)
            if metadata.state == .running {
                metadata.state = .disconnected
                metadata.updatedAt = Date()
            }
            let entry = Entry(metadata: metadata)
            // Raw scrollback belongs to the previous app process and is not
            // persisted. Resume offsets after it so no consumer mistakes old
            // unavailable bytes for an empty live stream.
            entry.visibleStartOffset = max(0, metadata.nextOffset ?? 0)
            entry.pumpOffset = entry.visibleStartOffset
            entries[metadata.id] = entry
            order.append(metadata.id)
        }
        didLoad = true
        if stored.contains(where: { $0.state == .running }) { try persist() }
    }

    private func normalizedTitle(_ value: String) throws -> String {
        guard let title = TaskTerminalMetadata.normalizedTitle(value) else {
            throw TaskTerminalError.invalidTitle
        }
        return title
    }

    private func entry(_ id: UUID) throws -> Entry {
        guard let entry = entries[id] else {
            throw TaskTerminalError.terminalNotFound(id)
        }
        return entry
    }

    private func ensureActive() throws {
        guard !isDisposed else { throw PseudoTerminalError.disposed }
    }

    private func requireStable(_ entry: Entry, id: UUID) throws {
        guard !entry.isTransitioning else {
            throw TaskTerminalError.terminalBusy(id)
        }
    }

    private func beginTransition(_ entry: Entry, id: UUID) throws {
        try requireStable(entry, id: id)
        entry.isTransitioning = true
    }

    private func reconcilePersistedBinding(
        _ metadata: inout TaskTerminalMetadata
    ) throws {
        guard metadata.shell.map({ ["/bin/zsh", "/bin/bash", "/bin/sh"].contains($0) })
                ?? true,
              metadata.workingDirectory.map({
                  !$0.contains("\0") && $0.utf8.count <= 4_096
              }) ?? true,
              metadata.earliestAvailableOffset.map({ $0 >= 0 }) ?? true,
              metadata.nextOffset.map({ $0 >= 0 }) ?? true,
              (metadata.earliestAvailableOffset ?? 0)
                <= (metadata.nextOffset ?? Int64.max),
              metadata.capabilities.map({ !$0.gitMetadataWrite || $0.gitMetadataRead })
                ?? true else {
            throw TaskTerminalError.corruptMetadata(
                "shell, working directory, capabilities, or offsets failed validation"
            )
        }

        let bindingChanged = metadata.workspaceID != nil
            && metadata.workspaceID != validator.workspace.id
            || metadata.workspaceRootPath != nil
            && URL(fileURLWithPath: metadata.workspaceRootPath!).standardizedFileURL.path
                != URL(fileURLWithPath: validator.secureRootPath).standardizedFileURL.path
        if bindingChanged {
            metadata.workspaceID = validator.workspace.id
            metadata.workspaceRootPath = validator.secureRootPath
            metadata.workingDirectory = "."
            metadata.state = .disconnected
            metadata.exitCode = nil
            metadata.terminationSignal = nil
            metadata.clearGeneration &+= 1
            metadata.updatedAt = Date()
            return
        }

        if let workingDirectory = metadata.workingDirectory {
            do {
                let directory = try validator.validate(cwd: workingDirectory)
                metadata.workingDirectory = validator.relativePath(for: directory)
            } catch {
                throw TaskTerminalError.corruptMetadata(
                    "working directory is outside the current workspace"
                )
            }
        } else {
            metadata.workingDirectory = "."
        }
        metadata.workspaceID = validator.workspace.id
        metadata.workspaceRootPath = validator.secureRootPath
    }

    private func observeExit(
        id: UUID,
        entry: Entry,
        transport: any PTYSessionTransport
    ) {
        entry.exitObserver?.cancel()
        entry.exitObserver = Task { [weak self, weak entry] in
            _ = try? await transport.waitForExit()
            guard let self, let entry else { return }
            await self.didExit(id: id, expected: entry, transport: transport)
        }
    }

    private func didExit(
        id: UUID,
        expected entry: Entry,
        transport: any PTYSessionTransport
    ) async {
        guard !isDisposed,
              entries[id] === entry,
              entry.transport === transport else { return }
        await refreshMetadata(entry)
        entry.metadata.updatedAt = Date()
        let result = await descriptor(for: entry)
        try? persist()
        emit(.init(taskID: taskID, terminalID: id, kind: .snapshot, descriptor: result, output: nil))
    }

    private func refreshMetadata(_ entry: Entry) async {
        guard let transport = entry.transport,
              let status = try? await transport.status() else { return }
        switch status.state {
        case .running: entry.metadata.state = .running
        case .exited: entry.metadata.state = .exited
        case .stopped: entry.metadata.state = .stopped
        case .failed: entry.metadata.state = .failed
        }
        entry.metadata.rows = status.dimensions.rows
        entry.metadata.columns = status.dimensions.columns
        entry.metadata.exitCode = status.exitCode
        entry.metadata.terminationSignal = status.terminationSignal
        if let bounds = try? await transport.outputBounds() {
            entry.metadata.earliestAvailableOffset = max(
                bounds.earliestAvailableOffset,
                entry.visibleStartOffset
            )
            entry.metadata.nextOffset = bounds.nextOffset
        }
    }

    private func descriptor(for entry: Entry) async -> TaskTerminalDescriptor {
        await refreshMetadata(entry)
        guard let transport = entry.transport else {
            let earliest = max(
                entry.visibleStartOffset,
                entry.metadata.earliestAvailableOffset ?? 0
            )
            let next = max(earliest, entry.metadata.nextOffset ?? earliest)
            return TaskTerminalDescriptor(
                metadata: entry.metadata,
                processIdentifier: nil,
                duration: 0,
                transportErrorCode: nil,
                earliestAvailableOffset: earliest,
                nextOffset: next
            )
        }
        let status = try? await transport.status()
        let bounds = try? await transport.outputBounds()
        entry.metadata.earliestAvailableOffset = bounds?.earliestAvailableOffset
        entry.metadata.nextOffset = bounds?.nextOffset
        return TaskTerminalDescriptor(
            metadata: entry.metadata,
            processIdentifier: status?.processIdentifier,
            duration: status?.duration ?? 0,
            transportErrorCode: status?.transportErrorCode,
            earliestAvailableOffset: max(
                bounds?.earliestAvailableOffset ?? entry.visibleStartOffset,
                entry.visibleStartOffset
            ),
            nextOffset: bounds?.nextOffset ?? entry.visibleStartOffset
        )
    }

    private func startOutputPump(
        id: UUID,
        entry: Entry,
        transport: any PTYSessionTransport
    ) {
        entry.outputPump?.cancel()
        entry.pumpOffset = entry.visibleStartOffset
        entry.outputPump = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            await self.pumpOutput(id: id, entry: entry, transport: transport)
        }
    }

    private func pumpOutput(
        id: UUID,
        entry: Entry,
        transport: any PTYSessionTransport
    ) async {
        guard let stream = try? await transport.outputEvents() else { return }
        await drainOutput(id: id, entry: entry, transport: transport)
        for await _ in stream {
            if Task.isCancelled { return }
            guard entries[id] === entry, entry.transport === transport else { return }
            await drainOutput(id: id, entry: entry, transport: transport)
        }
    }

    private func drainOutput(
        id: UUID,
        entry: Entry,
        transport: any PTYSessionTransport
    ) async {
        do {
            while !Task.isCancelled {
                guard !isDisposed,
                      entries[id] === entry,
                      entry.transport === transport else { return }
                let requestedOffset = entry.pumpOffset
                let clearGeneration = entry.metadata.clearGeneration
                let output = try await transport.readOutput(
                    offset: requestedOffset,
                    maxBytes: 64 * 1_024
                )
                guard !isDisposed,
                      entries[id] === entry,
                      entry.transport === transport else { return }
                // clear() may advance the cursor while the transport actor was
                // being awaited. Discard that stale read rather than replaying
                // bytes the user explicitly cleared.
                guard entry.pumpOffset == requestedOffset,
                      entry.metadata.clearGeneration == clearGeneration else {
                    continue
                }
                entry.pumpOffset = output.nextOffset
                entry.metadata.earliestAvailableOffset = max(
                    output.earliestAvailableOffset,
                    entry.visibleStartOffset
                )
                entry.metadata.nextOffset = output.nextOffset
                if !output.data.isEmpty || output.truncatedBeforeOffset {
                    emit(.init(
                        taskID: taskID,
                        terminalID: id,
                        kind: .output,
                        descriptor: nil,
                        output: TaskTerminalOutput(
                            terminalID: id,
                            data: output.data,
                            offset: output.offset,
                            nextOffset: output.nextOffset,
                            earliestAvailableOffset: max(
                                output.earliestAvailableOffset,
                                entry.visibleStartOffset
                            ),
                            hasMore: output.hasMore,
                            truncatedBeforeOffset: output.truncatedBeforeOffset,
                            clearGeneration: clearGeneration
                        )
                    ))
                }
                if !output.hasMore { return }
            }
        } catch {
            return
        }
    }

    private func emit(_ event: TaskTerminalEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func persist() throws {
        try store.save(order.compactMap { entries[$0]?.metadata })
    }
}
