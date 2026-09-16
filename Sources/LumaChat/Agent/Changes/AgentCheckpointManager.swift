import CryptoKit
import Darwin
import Foundation

enum AgentCheckpointError: LocalizedError, Equatable, Sendable {
    case workspaceRequired
    case workspaceMismatch
    case invalidGitMetadata(String)
    case invalidReference
    case invalidManifest
    case checkpointTooLarge(Int)
    case tooManyFileSnapshots(Int)
    case invalidFileSnapshot(String)
    case unsafeStorage(String)
    case storageLimit(Int)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            "Agent checkpoint requires an open workspace."
        case .workspaceMismatch:
            "Agent checkpoint refused a session/workspace identity mismatch."
        case .invalidGitMetadata(let detail):
            "Agent checkpoint could not safely capture Git metadata: \(detail)"
        case .invalidReference:
            "Agent checkpoint reference is invalid."
        case .invalidManifest:
            "Agent checkpoint manifest is invalid."
        case .checkpointTooLarge(let limit):
            "Agent checkpoint exceeds the \(limit)-byte safety limit."
        case .tooManyFileSnapshots(let limit):
            "Agent checkpoint contains more than \(limit) file snapshot paths."
        case .invalidFileSnapshot(let detail):
            "Agent checkpoint could not safely capture file snapshots: \(detail)"
        case .unsafeStorage(let detail):
            "Agent checkpoint storage is unavailable or unsafe: \(detail)"
        case .storageLimit(let limit):
            "Agent checkpoint storage exceeds the \(limit)-byte retention limit."
        case .posix(let operation, let code):
            "Agent checkpoint \(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

struct AgentCheckpointGitState: Codable, Equatable, Sendable {
    var head: String
    var symbolicReference: String?
    var objectID: String?
}

struct AgentCheckpointWorkspaceIdentity: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var canonicalRootPath: String
    var rootDevice: UInt64
    var rootInode: UInt64
    var authorizationDigest: String
}

struct AgentCheckpointManifestReference: Codable, Equatable, Sendable {
    var relativePath: String
    var workspaceIdentityDigest: String
}

struct AgentCheckpointReference: Codable, Equatable, Sendable {
    var checkpointID: UUID
    var sessionID: UUID
    var workspaceID: UUID
    var createdAt: Date
    var relativeManifestPath: String
    var gitState: AgentCheckpointGitState?
}

struct AgentCheckpointManifest: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let oldestSupportedVersion = 1

    var version: Int
    var reference: AgentCheckpointReference
    var workspaceIdentity: AgentCheckpointWorkspaceIdentity
    var gitState: AgentCheckpointGitState?
    var session: AgentSession
    var todos: [AgentTodo]
    var existingChangeIDs: [UUID]
    /// Bounded current contents for every path represented by this task's
    /// change cards. Version-1 manifests decode this as an empty collection;
    /// their existing Undo-history boundary remains readable.
    var fileSnapshots: [SecurePathSnapshot]
    var undoHistoryManifest: AgentCheckpointManifestReference
    var sanitizationTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case version, reference, workspaceIdentity, gitState, session, todos
        case existingChangeIDs, fileSnapshots, undoHistoryManifest
        case sanitizationTruncated
    }

    init(
        version: Int,
        reference: AgentCheckpointReference,
        workspaceIdentity: AgentCheckpointWorkspaceIdentity,
        gitState: AgentCheckpointGitState?,
        session: AgentSession,
        todos: [AgentTodo],
        existingChangeIDs: [UUID],
        fileSnapshots: [SecurePathSnapshot],
        undoHistoryManifest: AgentCheckpointManifestReference,
        sanitizationTruncated: Bool
    ) {
        self.version = version
        self.reference = reference
        self.workspaceIdentity = workspaceIdentity
        self.gitState = gitState
        self.session = session
        self.todos = todos
        self.existingChangeIDs = existingChangeIDs
        self.fileSnapshots = fileSnapshots
        self.undoHistoryManifest = undoHistoryManifest
        self.sanitizationTruncated = sanitizationTruncated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        reference = try container.decode(AgentCheckpointReference.self, forKey: .reference)
        workspaceIdentity = try container.decode(
            AgentCheckpointWorkspaceIdentity.self,
            forKey: .workspaceIdentity
        )
        gitState = try container.decodeIfPresent(AgentCheckpointGitState.self, forKey: .gitState)
        session = try container.decode(AgentSession.self, forKey: .session)
        todos = try container.decode([AgentTodo].self, forKey: .todos)
        existingChangeIDs = try container.decode([UUID].self, forKey: .existingChangeIDs)
        fileSnapshots = try container.decodeIfPresent(
            [SecurePathSnapshot].self,
            forKey: .fileSnapshots
        ) ?? []
        undoHistoryManifest = try container.decode(
            AgentCheckpointManifestReference.self,
            forKey: .undoHistoryManifest
        )
        sanitizationTruncated = try container.decode(
            Bool.self,
            forKey: .sanitizationTruncated
        )
    }
}

/// Creates a restart-safe pre-run checkpoint before an Agent can invoke tools.
///
/// The store is intentionally rooted at `AppPaths.agentSnapshots`. Directory
/// traversal and writes use pinned descriptors, every component is no-follow,
/// and the final JSON appears through a same-directory atomic rename. A caller
/// must treat every thrown error as fail-closed and not start the Agent runtime.
actor AgentCheckpointManager {
    private static let maximumChangeIDs = 10_000
    private static let maximumFileSnapshotPaths = 512
    private static let maximumFileSnapshotBytes = 4 * 1_024 * 1_024

    private let maximumCheckpointBytes: Int
    private let maximumStoredCheckpoints: Int
    private let maximumStorageBytes: Int
    private let redactor: SecretRedactor

    init(
        maximumCheckpointBytes: Int = 8 * 1_024 * 1_024,
        maximumStoredCheckpoints: Int = 128,
        maximumStorageBytes: Int = 128 * 1_024 * 1_024,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        self.maximumCheckpointBytes = max(64 * 1_024, maximumCheckpointBytes)
        self.maximumStoredCheckpoints = max(1, maximumStoredCheckpoints)
        self.maximumStorageBytes = max(self.maximumCheckpointBytes, maximumStorageBytes)
        self.redactor = redactor
    }

    /// Returns nil without touching storage when checkpoints are disabled or
    /// the session is not in Agent mode. Every enabled failure is propagated.
    func createCheckpointIfNeeded(
        settings: AgentSettings,
        session: AgentSession,
        todos: [AgentTodo],
        existingChangeIDs: [UUID]? = nil
    ) throws -> AgentCheckpointReference? {
        guard settings.gitCheckpoint, session.mode == .agent else { return nil }
        guard let workspace = session.workspace else {
            throw AgentCheckpointError.workspaceRequired
        }
        guard session.workspace?.id == workspace.id else {
            throw AgentCheckpointError.workspaceMismatch
        }

        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let io = try SecureWorkspaceIO(validator: validator)
        let identity = workspaceIdentity(workspace: workspace, validator: validator)
        let gitState = try captureGitState(validator: validator)
        let checkpointID = UUID()
        let createdAt = Date()
        let relativePath = Self.checkpointRelativePath(
            sessionID: session.id,
            workspaceID: workspace.id,
            checkpointID: checkpointID
        )
        let reference = AgentCheckpointReference(
            checkpointID: checkpointID,
            sessionID: session.id,
            workspaceID: workspace.id,
            createdAt: createdAt,
            relativeManifestPath: relativePath,
            gitState: gitState
        )

        var sanitizer = CheckpointSanitizer(redactor: redactor)
        let sanitizedTodos = sanitizer.sanitizeTodos(todos)
        let sanitizedSession = sanitizer.sanitizeSession(
            session,
            currentTodos: sanitizedTodos
        )
        let changeIDs = try boundedChangeIDs(existingChangeIDs ?? session.changes.map(\.id))
        let fileSnapshots = try captureFileSnapshots(
            paths: session.changes.flatMap { change in
                [change.relativePath] + (change.destinationRelativePath.map { [$0] } ?? [])
            },
            io: io,
            validator: validator
        )
        let historyReference = Self.undoHistoryReference(
            sessionID: session.id,
            workspaceID: workspace.id,
            workspaceIdentityDigest: identity.authorizationDigest
        )
        let manifest = AgentCheckpointManifest(
            version: AgentCheckpointManifest.currentVersion,
            reference: reference,
            workspaceIdentity: identity,
            gitState: gitState,
            session: sanitizedSession,
            todos: sanitizedTodos,
            existingChangeIDs: changeIDs,
            fileSnapshots: fileSnapshots,
            undoHistoryManifest: historyReference,
            sanitizationTruncated: sanitizer.truncated
        )

        let data = try encode(manifest)
        let storage = try SecureCheckpointStorage(
            sessionID: session.id,
            workspaceID: workspace.id,
            createDirectories: true
        )
        try storage.write(
            data,
            checkpointID: checkpointID,
            maximumFileBytes: maximumCheckpointBytes,
            maximumFiles: maximumStoredCheckpoints,
            maximumTotalBytes: maximumStorageBytes
        )
        return reference
    }

    func load(_ reference: AgentCheckpointReference) throws -> AgentCheckpointManifest {
        guard reference.relativeManifestPath == Self.checkpointRelativePath(
            sessionID: reference.sessionID,
            workspaceID: reference.workspaceID,
            checkpointID: reference.checkpointID
        ) else {
            throw AgentCheckpointError.invalidReference
        }
        let storage = try SecureCheckpointStorage(
            sessionID: reference.sessionID,
            workspaceID: reference.workspaceID,
            createDirectories: false
        )
        let data = try storage.read(
            checkpointID: reference.checkpointID,
            maximumBytes: maximumCheckpointBytes
        )
        let manifest: AgentCheckpointManifest
        do {
            manifest = try JSONDecoder().decode(AgentCheckpointManifest.self, from: data)
        } catch {
            throw AgentCheckpointError.invalidManifest
        }
        guard (AgentCheckpointManifest.oldestSupportedVersion
                ... AgentCheckpointManifest.currentVersion).contains(manifest.version),
              manifest.reference == reference,
              manifest.session.id == reference.sessionID,
              manifest.workspaceIdentity.workspaceID == reference.workspaceID,
              manifest.session.workspace?.id == reference.workspaceID,
              manifest.gitState == reference.gitState,
              manifest.existingChangeIDs.count <= Self.maximumChangeIDs,
              validateFileSnapshots(manifest.fileSnapshots),
              manifest.undoHistoryManifest == Self.undoHistoryReference(
                sessionID: reference.sessionID,
                workspaceID: reference.workspaceID,
                workspaceIdentityDigest: manifest.workspaceIdentity.authorizationDigest
              ) else {
            throw AgentCheckpointError.invalidManifest
        }
        return manifest
    }

    private func encode(_ manifest: AgentCheckpointManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumCheckpointBytes else {
            throw AgentCheckpointError.checkpointTooLarge(maximumCheckpointBytes)
        }
        return data
    }

    private func boundedChangeIDs(_ values: [UUID]) throws -> [UUID] {
        guard values.count <= Self.maximumChangeIDs else {
            throw AgentCheckpointError.invalidManifest
        }
        return Array(Set(values)).sorted { $0.uuidString < $1.uuidString }
    }

    private func captureFileSnapshots(
        paths: [String],
        io: SecureWorkspaceIO,
        validator: WorkspaceSecurityValidator
    ) throws -> [SecurePathSnapshot] {
        var seen: Set<String> = []
        var normalizedPaths: [String] = []
        for path in paths {
            let normalized: String
            do {
                normalized = try validator.secureRelativePath(for: path, access: .read)
            } catch {
                throw AgentCheckpointError.invalidFileSnapshot(error.localizedDescription)
            }
            // A root snapshot would turn the bounded per-change checkpoint into
            // an accidental whole-project archive. Native change records always
            // identify explicit paths, so fail closed on malformed legacy data.
            guard normalized != "." else {
                throw AgentCheckpointError.invalidFileSnapshot("workspace root is not an explicit change path")
            }
            if seen.insert(normalized).inserted {
                normalizedPaths.append(normalized)
            }
        }
        guard normalizedPaths.count <= Self.maximumFileSnapshotPaths else {
            throw AgentCheckpointError.tooManyFileSnapshots(Self.maximumFileSnapshotPaths)
        }

        var remainingBytes = Self.maximumFileSnapshotBytes
        var snapshots: [SecurePathSnapshot] = []
        for path in normalizedPaths {
            do {
                let snapshot = try io.snapshot(path: path, maximumBytes: remainingBytes)
                remainingBytes -= snapshot.entries.reduce(into: 0) { total, entry in
                    if case .file(let data) = entry.kind { total += data.count }
                }
                snapshots.append(snapshot)
            } catch SecureWorkspaceIOError.snapshotTooLarge {
                throw AgentCheckpointError.checkpointTooLarge(Self.maximumFileSnapshotBytes)
            } catch {
                throw AgentCheckpointError.invalidFileSnapshot(error.localizedDescription)
            }
        }
        guard validateFileSnapshots(snapshots) else {
            throw AgentCheckpointError.invalidFileSnapshot("snapshot metadata is invalid")
        }
        return snapshots
    }

    private func validateFileSnapshots(_ snapshots: [SecurePathSnapshot]) -> Bool {
        guard snapshots.count <= Self.maximumFileSnapshotPaths else { return false }
        var seen: Set<String> = []
        var totalBytes = 0
        var totalEntries = 0
        for snapshot in snapshots {
            guard snapshot.requestedPath != ".",
                  Self.isSafeWorkspaceRelativePath(snapshot.requestedPath),
                  seen.insert(snapshot.requestedPath).inserted,
                  snapshot.existed || snapshot.entries.isEmpty,
                  !snapshot.existed || !snapshot.entries.isEmpty else {
                return false
            }
            for entry in snapshot.entries {
                totalEntries += 1
                guard totalEntries <= 100_000,
                      (0...0o7777).contains(entry.permissions),
                      entry.relativePath.isEmpty
                        || Self.isSafeWorkspaceRelativePath(entry.relativePath) else {
                    return false
                }
                if case .file(let data) = entry.kind {
                    guard data.count <= Self.maximumFileSnapshotBytes - totalBytes else {
                        return false
                    }
                    totalBytes += data.count
                }
            }
        }
        return true
    }

    private static func isSafeWorkspaceRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func workspaceIdentity(
        workspace: AgentWorkspace,
        validator: WorkspaceSecurityValidator
    ) -> AgentCheckpointWorkspaceIdentity {
        let authorization = ([validator.secureRootPath] + workspace.allowedPaths.sorted())
            .joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(authorization.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return AgentCheckpointWorkspaceIdentity(
            workspaceID: workspace.id,
            canonicalRootPath: validator.secureRootPath,
            rootDevice: validator.secureRootIdentity.device,
            rootInode: validator.secureRootIdentity.inode,
            authorizationDigest: digest
        )
    }

    private func captureGitState(
        validator: WorkspaceSecurityValidator
    ) throws -> AgentCheckpointGitState? {
        do {
            guard let layout = try GitRepositoryLayout.inspect(
                workspaceRoot: URL(
                    fileURLWithPath: validator.secureRootPath,
                    isDirectory: true
                )
            ) else { return nil }
            return AgentCheckpointGitState(
                head: layout.head.rawValue,
                symbolicReference: layout.head.symbolicReference,
                objectID: layout.head.objectID
            )
        } catch {
            throw AgentCheckpointError.invalidGitMetadata(error.localizedDescription)
        }
    }

    private static func checkpointRelativePath(
        sessionID: UUID,
        workspaceID: UUID,
        checkpointID: UUID
    ) -> String {
        "\(component(sessionID))/\(component(workspaceID))/checkpoints/"
            + "\(component(checkpointID)).json"
    }

    private static func undoHistoryReference(
        sessionID: UUID,
        workspaceID: UUID,
        workspaceIdentityDigest: String
    ) -> AgentCheckpointManifestReference {
        AgentCheckpointManifestReference(
            relativePath: "\(component(sessionID))/\(component(workspaceID))/history.json",
            workspaceIdentityDigest: workspaceIdentityDigest
        )
    }

    private static func component(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

}

private struct CheckpointSanitizer {
    private static let maximumMessages = 1_000
    private static let maximumSteps = 1_000
    private static let maximumTodos = 1_000
    private static let maximumChanges = 2_000
    private static let maximumToolCallsPerMessage = 128
    private static let maximumTextCharacters = 256 * 1_024
    private static let maximumCheckpointReferences = 256
    private static let maximumBaselineSupplementalPaths = 10_000

    let redactor: SecretRedactor
    var truncated = false

    mutating func sanitizeSession(
        _ original: AgentSession,
        currentTodos: [AgentTodo]
    ) -> AgentSession {
        var session = original
        session.title = text(session.title)
        session.model = text(session.model)
        session.lastError = session.lastError.map { text($0) }
        session.localCheckoutBaselineFingerprint = session.localCheckoutBaselineFingerprint
            .map { text($0) }
        session.localCheckoutBaselineReference = session.localCheckoutBaselineReference
            .map { text($0) }
        session.localCheckoutBaselineSupplementalPaths = session
            .localCheckoutBaselineSupplementalPaths.map {
                limited($0, maximum: Self.maximumBaselineSupplementalPaths).map { text($0) }
            }
        session.workspace = session.workspace.map { sanitizeWorkspace($0) }
        session.localWorkspace = session.localWorkspace.map { sanitizeWorkspace($0) }
        session.executionLocation = session.executionLocation.map { location in
            var copy = location
            copy.label = copy.label.map { text($0) }
            return copy
        }
        session.lastHandoff = session.lastHandoff.map { handoff in
            var copy = handoff
            copy.from.label = copy.from.label.map { text($0) }
            copy.to.label = copy.to.label.map { text($0) }
            return copy
        }
        session.connection = session.connection.map { connection in
            var copy = connection
            copy.endpoint = text(copy.endpoint)
            return copy
        }
        session.messages = limited(session.messages, maximum: Self.maximumMessages).map { message in
            var copy = message
            copy.content = text(copy.content)
            copy.reasoningSummary = copy.reasoningSummary.map { text($0) }
            copy.toolCallID = copy.toolCallID.map { text($0) }
            copy.name = copy.name.map { text($0) }
            copy.toolCalls = limited(
                copy.toolCalls,
                maximum: Self.maximumToolCallsPerMessage
            ).map { sanitizeToolCall($0) }
            return copy
        }
        session.steps = limited(session.steps, maximum: Self.maximumSteps).map { step in
            var copy = step
            copy.title = text(copy.title)
            copy.detail = copy.detail.map { text($0) }
            copy.toolCall = copy.toolCall.map { sanitizeToolCall($0) }
            copy.toolResult = copy.toolResult.map { sanitizeToolResult($0) }
            return copy
        }
        session.todos = currentTodos
        session.changes = limited(session.changes, maximum: Self.maximumChanges)
            .map { sanitizeChange($0) }
        session.checkpointReferences = session.checkpointReferences.map {
            limited($0, maximum: Self.maximumCheckpointReferences)
        }
        // The current Last-Agent-Turn baseline can be much larger than an
        // 8 MiB checkpoint and describes a later Review boundary, not rollback
        // state. Restoring a checkpoint must capture a new baseline next run.
        session.lastAgentTurnReviewBaseline = nil
        session.pendingAgentTurnReviewBaseline = nil
        session.lastAgentTurnReviewSnapshot = nil
        return session
    }

    mutating func sanitizeTodos(_ values: [AgentTodo]) -> [AgentTodo] {
        limited(values, maximum: Self.maximumTodos).map { todo in
            var copy = todo
            copy.title = text(copy.title)
            copy.detail = copy.detail.map { text($0) }
            return copy
        }
    }

    private mutating func sanitizeWorkspace(_ workspace: AgentWorkspace) -> AgentWorkspace {
        var copy = workspace
        copy.name = text(copy.name)
        copy.rootPath = text(copy.rootPath)
        copy.allowedPaths = limited(copy.allowedPaths, maximum: 64).map { text($0) }
        // Security-scoped bookmark authority is never duplicated into tmp.
        copy.bookmarkData = nil
        copy.branch = copy.branch.map { text($0) }
        return copy
    }

    private mutating func sanitizeToolCall(_ call: AgentToolCall) -> AgentToolCall {
        var copy = call
        copy.id = text(copy.id)
        copy.name = text(copy.name)
        copy.arguments = redactor.redact(copy.arguments)
        return copy
    }

    private mutating func sanitizeToolResult(_ result: AgentToolResult) -> AgentToolResult {
        var copy = result
        copy.content = text(copy.content)
        copy.data = copy.data.map { redactor.redact($0) }
        copy.artifactPath = copy.artifactPath.map { text($0) }
        copy.change = copy.change.map { sanitizeChange($0) }
        return copy
    }

    private mutating func sanitizeChange(_ change: AgentChangeRecord) -> AgentChangeRecord {
        var copy = change
        copy.relativePath = text(copy.relativePath)
        copy.destinationRelativePath = copy.destinationRelativePath.map { text($0) }
        copy.unifiedDiff = text(copy.unifiedDiff)
        copy.snapshotPath = copy.snapshotPath.map { text($0) }
        return copy
    }

    private mutating func text(_ value: String) -> String {
        let bounded: String
        if value.count > Self.maximumTextCharacters {
            truncated = true
            bounded = String(value.prefix(Self.maximumTextCharacters)) + "\n[TRUNCATED]"
        } else {
            bounded = value
        }
        return redactor.redact(bounded)
    }

    private mutating func limited<Element>(
        _ values: [Element],
        maximum: Int
    ) -> [Element] {
        guard values.count > maximum else { return values }
        truncated = true
        return Array(values.prefix(maximum))
    }
}

private struct SecureCheckpointStorage {
    private final class Descriptor {
        let rawValue: Int32
        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { Darwin.close(rawValue) }
    }

    private struct StoredFile {
        var name: String
        var byteCount: Int
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    private static let maximumDirectoryEntries = 512

    private let checkpoints: Descriptor

    init(sessionID: UUID, workspaceID: UUID, createDirectories: Bool) throws {
        let temporaryRoot = AppPaths.projectTemporaryRoot.standardizedFileURL
        let projectRoot = temporaryRoot.deletingLastPathComponent()
        let snapshotsRoot = AppPaths.agentSnapshots.standardizedFileURL
        guard snapshotsRoot.deletingLastPathComponent() == temporaryRoot,
              !projectRoot.lastPathComponent.isEmpty,
              temporaryRoot.lastPathComponent == "tmp" else {
            throw AgentCheckpointError.unsafeStorage("unexpected project tmp layout")
        }

        let project = try Self.openDirectory(path: projectRoot.path, requirePrivate: false)
        let temporary = try Self.directory(
            parent: project,
            name: temporaryRoot.lastPathComponent,
            create: createDirectories
        )
        let snapshots = try Self.directory(
            parent: temporary,
            name: snapshotsRoot.lastPathComponent,
            create: createDirectories
        )
        let session = try Self.directory(
            parent: snapshots,
            name: sessionID.uuidString.lowercased(),
            create: createDirectories
        )
        let workspace = try Self.directory(
            parent: session,
            name: workspaceID.uuidString.lowercased(),
            create: createDirectories
        )
        checkpoints = try Self.directory(
            parent: workspace,
            name: "checkpoints",
            create: createDirectories
        )
    }

    func write(
        _ data: Data,
        checkpointID: UUID,
        maximumFileBytes: Int,
        maximumFiles: Int,
        maximumTotalBytes: Int
    ) throws {
        guard data.count <= maximumFileBytes else {
            throw AgentCheckpointError.checkpointTooLarge(maximumFileBytes)
        }
        try makeRoom(
            for: data.count,
            maximumFileBytes: maximumFileBytes,
            maximumFiles: maximumFiles,
            maximumTotalBytes: maximumTotalBytes
        )

        let finalName = Self.fileName(checkpointID)
        let temporaryName = ".temporary-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = Darwin.openat(
            checkpoints.rawValue,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.posix("openat temporary") }
        var renamed = false
        defer {
            Darwin.close(descriptor)
            if !renamed {
                _ = Darwin.unlinkat(checkpoints.rawValue, temporaryName, 0)
            }
        }

        try Self.writeAll(data, descriptor: descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.posix("fchmod checkpoint")
        }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.posix("fsync checkpoint") }
        guard Darwin.renameat(
            checkpoints.rawValue,
            temporaryName,
            checkpoints.rawValue,
            finalName
        ) == 0 else {
            throw Self.posix("renameat checkpoint")
        }
        renamed = true
        guard Darwin.fsync(checkpoints.rawValue) == 0 else {
            throw Self.posix("fsync checkpoint directory")
        }
    }

    func read(checkpointID: UUID, maximumBytes: Int) throws -> Data {
        let name = Self.fileName(checkpointID)
        let descriptor = Darwin.openat(
            checkpoints.rawValue,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw Self.posix("openat checkpoint") }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw Self.posix("fstat checkpoint") }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(maximumBytes),
              info.st_mode & 0o077 == 0 else {
            throw AgentCheckpointError.unsafeStorage("checkpoint is not a private bounded file")
        }
        return try Self.readAll(descriptor: descriptor, byteCount: Int(info.st_size))
    }

    private func makeRoom(
        for newBytes: Int,
        maximumFileBytes: Int,
        maximumFiles: Int,
        maximumTotalBytes: Int
    ) throws {
        var stored: [StoredFile] = []
        var totalBytes = 0
        for name in try Self.directoryNames(checkpoints.rawValue) {
            var info = Darwin.stat()
            guard Darwin.fstatat(
                checkpoints.rawValue,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else { throw Self.posix("fstatat checkpoint") }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw AgentCheckpointError.unsafeStorage("checkpoint directory contains a symbolic or special entry")
            }
            if name.hasPrefix(".temporary-") && name.hasSuffix(".tmp")
                || name.hasPrefix("._") {
                guard info.st_size >= 0, info.st_size <= Int64(maximumFileBytes) else {
                    throw AgentCheckpointError.unsafeStorage("temporary checkpoint entry is oversized")
                }
                guard Darwin.unlinkat(checkpoints.rawValue, name, 0) == 0 else {
                    throw Self.posix("unlinkat stale checkpoint")
                }
                continue
            }
            guard Self.isCheckpointFileName(name),
                  info.st_size >= 0,
                  info.st_size <= Int64(maximumFileBytes),
                  info.st_mode & 0o077 == 0 else {
                throw AgentCheckpointError.unsafeStorage("checkpoint directory contains an invalid entry")
            }
            let bytes = Int(info.st_size)
            guard totalBytes <= maximumTotalBytes - min(bytes, maximumTotalBytes) else {
                throw AgentCheckpointError.storageLimit(maximumTotalBytes)
            }
            totalBytes += bytes
            stored.append(StoredFile(
                name: name,
                byteCount: bytes,
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
            ))
        }
        stored.sort {
            if $0.modifiedSeconds != $1.modifiedSeconds {
                return $0.modifiedSeconds < $1.modifiedSeconds
            }
            if $0.modifiedNanoseconds != $1.modifiedNanoseconds {
                return $0.modifiedNanoseconds < $1.modifiedNanoseconds
            }
            return $0.name < $1.name
        }
        while let oldest = stored.first,
              stored.count >= maximumFiles
                || totalBytes > maximumTotalBytes - newBytes {
            guard Darwin.unlinkat(checkpoints.rawValue, oldest.name, 0) == 0 else {
                throw Self.posix("unlinkat retained checkpoint")
            }
            stored.removeFirst()
            totalBytes -= oldest.byteCount
        }
        guard newBytes <= maximumTotalBytes,
              stored.count < maximumFiles,
              totalBytes <= maximumTotalBytes - newBytes else {
            throw AgentCheckpointError.storageLimit(maximumTotalBytes)
        }
    }

    private static func directory(
        parent: Descriptor,
        name: String,
        create: Bool
    ) throws -> Descriptor {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw AgentCheckpointError.unsafeStorage("invalid directory component")
        }
        if create, Darwin.mkdirat(parent.rawValue, name, mode_t(0o700)) != 0,
           errno != EEXIST {
            throw posix("mkdirat checkpoint directory")
        }
        let descriptor = Darwin.openat(
            parent.rawValue,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw posix("openat checkpoint directory") }
        let result = Descriptor(descriptor)
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw AgentCheckpointError.unsafeStorage("checkpoint component is not a directory")
        }
        if create {
            guard Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw posix("fchmod checkpoint directory")
            }
        }
        var verified = Darwin.stat()
        guard Darwin.fstat(descriptor, &verified) == 0,
              verified.st_mode & 0o077 == 0 else {
            throw AgentCheckpointError.unsafeStorage("checkpoint directory is not private")
        }
        return result
    }

    private static func openDirectory(path: String, requirePrivate: Bool) throws -> Descriptor {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw posix("open checkpoint root") }
        let result = Descriptor(descriptor)
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              !requirePrivate || info.st_mode & 0o077 == 0 else {
            throw AgentCheckpointError.unsafeStorage("checkpoint root is not a private directory")
        }
        return result
    }

    private static func directoryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw posix("dup checkpoint directory") }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            errno = savedErrno
            throw posix("fdopendir checkpoint directory")
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." {
                guard names.count < maximumDirectoryEntries else {
                    throw AgentCheckpointError.unsafeStorage("checkpoint directory has too many entries")
                }
                names.append(name)
            }
            errno = 0
        }
        if errno != 0 { throw posix("readdir checkpoint directory") }
        return names.sorted()
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posix("write checkpoint") }
                offset += written
            }
        }
    }

    private static func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    byteCount - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posix("read checkpoint") }
                offset += count
            }
        }
        return data
    }

    private static func fileName(_ id: UUID) -> String {
        id.uuidString.lowercased() + ".json"
    }

    private static func isCheckpointFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropLast(".json".count))) != nil
    }

    private static func posix(_ operation: String) -> AgentCheckpointError {
        .posix(operation: operation, code: errno)
    }
}
