import Darwin
import Foundation

enum AgentTaskHandoffStage: String, Codable, Sendable {
    case prepared
    case destinationAllocated
    case destinationReady
    case sessionCommitted
}

enum AgentTaskTransitionKind: String, Codable, Sendable {
    case handoff
    case handoffToLocal
    case handoffToRemote
    case handoffFromRemote
    case fork
}

struct AgentTaskBindingSnapshot: Codable, Equatable, Sendable {
    var workspace: AgentWorkspace
    var location: AgentExecutionLocation
    var projectFolderID: UUID?
    var localWorkspace: AgentWorkspace?
    var localProjectFolderID: UUID?
}

struct AgentTaskHandoffJournalEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var transitionKind: AgentTaskTransitionKind?
    var sourceSessionID: UUID?
    var sessionID: UUID
    var from: AgentTaskBindingSnapshot
    var to: AgentTaskBindingSnapshot?
    var plannedWorktreeID: UUID?
    var createdWorktreeID: UUID?
    var sourceWorktreeID: UUID?
    var sourceWorktreeLease: WorktreeLease?
    var recoverySnapshot: WorktreeStateRecoveryReference?
    var expectedDestinationFingerprint: String?
    var desiredDestinationFingerprint: String?
    /// Full clean remote baseline and runner authority are retained so crash
    /// recovery can restore exactly what existed and cannot follow a reused
    /// runner UUID to a different endpoint.
    var remoteBaselineSnapshot: RemoteWorkspaceStateSnapshot? = nil
    var remoteExecutionIdentity: AgentRemoteExecutionIdentity? = nil
    var stage: AgentTaskHandoffStage
    var startedAt: Date
    var updatedAt: Date

    var resolvedTransitionKind: AgentTaskTransitionKind {
        transitionKind ?? .handoff
    }
}

enum AgentTaskHandoffJournalError: LocalizedError, Equatable {
    case invalidEntry(String)
    case oversized(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEntry(let detail): "Task handoff journal is invalid: \(detail)"
        case .oversized(let maximum): "Task handoff journal exceeds \(maximum) bytes."
        }
    }
}

/// A small durable intent log closes the crash window between preparing a
/// destination checkout and atomically replacing the Task session JSON. On
/// launch, the coordinator compares the persisted Task binding with `from` and
/// `to`: it can compensate an uncommitted destination or finalize a committed
/// registry lease without guessing.
actor AgentTaskHandoffJournal {
    static let maximumEntryBytes = 12 * 1_024 * 1_024
    static let maximumEntries = 256

    private let fileManager: FileManager
    private let root: URL

    init(
        fileManager: FileManager = .default,
        root: URL = AppPaths.appSupport.appendingPathComponent(
            "AgentHandoffs",
            isDirectory: true
        )
    ) {
        self.fileManager = fileManager
        self.root = root.standardizedFileURL
    }

    func begin(
        session: AgentSession,
        plannedWorktreeID: UUID? = nil,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard let workspace = session.workspace else {
            throw AgentTaskHandoffJournalError.invalidEntry("source workspace is missing")
        }
        let entry = AgentTaskHandoffJournalEntry(
            id: id,
            transitionKind: .handoff,
            sourceSessionID: session.id,
            sessionID: session.id,
            from: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: session.resolvedExecutionLocation,
                projectFolderID: session.projectFolderID,
                localWorkspace: session.localWorkspace,
                localProjectFolderID: session.localProjectFolderID
            ),
            to: nil,
            plannedWorktreeID: plannedWorktreeID,
            createdWorktreeID: nil,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            recoverySnapshot: nil,
            expectedDestinationFingerprint: nil,
            desiredDestinationFingerprint: nil,
            stage: .prepared,
            startedAt: now,
            updatedAt: now
        )
        try save(entry)
        return entry
    }

    func beginFork(
        source: AgentSession,
        forkSessionID: UUID,
        plannedWorktreeID: UUID,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard forkSessionID != source.id,
              let workspace = source.workspace else {
            throw AgentTaskHandoffJournalError.invalidEntry("fork identity or source workspace is invalid")
        }
        let entry = AgentTaskHandoffJournalEntry(
            id: id,
            transitionKind: .fork,
            sourceSessionID: source.id,
            sessionID: forkSessionID,
            from: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: source.resolvedExecutionLocation,
                projectFolderID: source.projectFolderID,
                localWorkspace: source.localWorkspace,
                localProjectFolderID: source.localProjectFolderID
            ),
            to: nil,
            plannedWorktreeID: plannedWorktreeID,
            createdWorktreeID: nil,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            recoverySnapshot: nil,
            expectedDestinationFingerprint: nil,
            desiredDestinationFingerprint: nil,
            stage: .prepared,
            startedAt: now,
            updatedAt: now
        )
        try save(entry)
        return entry
    }

    func beginHandoffToLocal(
        session: AgentSession,
        sourceWorktreeID: UUID,
        sourceWorktreeLease: WorktreeLease,
        recoverySnapshot: WorktreeStateRecoveryReference,
        expectedDestinationFingerprint: String,
        desiredDestinationFingerprint: String,
        id: UUID,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard let workspace = session.workspace,
              session.resolvedExecutionLocation.kind == .worktree,
              session.resolvedExecutionLocation.managedWorktreeID == sourceWorktreeID,
              sourceWorktreeLease.worktreeID == sourceWorktreeID,
              sourceWorktreeLease.taskID == session.id,
              recoverySnapshot.transactionID == id else {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "reverse handoff source capability is invalid"
            )
        }
        let entry = AgentTaskHandoffJournalEntry(
            id: id,
            transitionKind: .handoffToLocal,
            sourceSessionID: session.id,
            sessionID: session.id,
            from: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: session.resolvedExecutionLocation,
                projectFolderID: session.projectFolderID,
                localWorkspace: session.localWorkspace,
                localProjectFolderID: session.localProjectFolderID
            ),
            to: nil,
            plannedWorktreeID: nil,
            createdWorktreeID: nil,
            sourceWorktreeID: sourceWorktreeID,
            sourceWorktreeLease: sourceWorktreeLease,
            recoverySnapshot: recoverySnapshot,
            expectedDestinationFingerprint: expectedDestinationFingerprint,
            desiredDestinationFingerprint: desiredDestinationFingerprint,
            stage: .prepared,
            startedAt: now,
            updatedAt: now
        )
        try save(entry)
        return entry
    }

    func beginHandoffToRemote(
        session: AgentSession,
        sourceWorktreeID: UUID?,
        sourceWorktreeLease: WorktreeLease?,
        desiredSnapshot: WorktreeStateRecoveryReference,
        remoteBaselineFingerprint: String,
        remoteBaselineSnapshot: RemoteWorkspaceStateSnapshot,
        remoteExecutionIdentity: AgentRemoteExecutionIdentity,
        id: UUID,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard let workspace = session.workspace,
              (session.resolvedExecutionLocation.kind == .local
                || session.resolvedExecutionLocation.kind == .worktree),
              desiredSnapshot.transactionID == id else {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "remote handoff source capability is invalid"
            )
        }
        if session.resolvedExecutionLocation.kind == .worktree {
            guard let sourceWorktreeID,
                  let sourceWorktreeLease,
                  session.resolvedExecutionLocation.managedWorktreeID == sourceWorktreeID,
                  sourceWorktreeLease.worktreeID == sourceWorktreeID,
                  sourceWorktreeLease.taskID == session.id else {
                throw AgentTaskHandoffJournalError.invalidEntry(
                    "remote handoff worktree lease is invalid"
                )
            }
        } else if sourceWorktreeID != nil || sourceWorktreeLease != nil {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "local remote handoff cannot carry a worktree lease"
            )
        }
        let entry = AgentTaskHandoffJournalEntry(
            id: id,
            transitionKind: .handoffToRemote,
            sourceSessionID: session.id,
            sessionID: session.id,
            from: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: session.resolvedExecutionLocation,
                projectFolderID: session.projectFolderID,
                localWorkspace: session.localWorkspace,
                localProjectFolderID: session.localProjectFolderID
            ),
            to: nil,
            plannedWorktreeID: nil,
            createdWorktreeID: nil,
            sourceWorktreeID: sourceWorktreeID,
            sourceWorktreeLease: sourceWorktreeLease,
            recoverySnapshot: desiredSnapshot,
            expectedDestinationFingerprint: remoteBaselineFingerprint,
            desiredDestinationFingerprint: desiredSnapshot.snapshotFingerprint,
            remoteBaselineSnapshot: remoteBaselineSnapshot,
            remoteExecutionIdentity: remoteExecutionIdentity,
            stage: .prepared,
            startedAt: now,
            updatedAt: now
        )
        try save(entry)
        return entry
    }

    func beginHandoffFromRemote(
        session: AgentSession,
        localRecoverySnapshot: WorktreeStateRecoveryReference,
        desiredDestinationFingerprint: String,
        id: UUID,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard let workspace = session.workspace,
              session.resolvedExecutionLocation.kind == .ssh,
              session.resolvedExecutionLocation.remoteRunnerID != nil,
              localRecoverySnapshot.transactionID == id else {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "SSH-to-Local handoff source capability is invalid"
            )
        }
        let entry = AgentTaskHandoffJournalEntry(
            id: id,
            transitionKind: .handoffFromRemote,
            sourceSessionID: session.id,
            sessionID: session.id,
            from: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: session.resolvedExecutionLocation,
                projectFolderID: session.projectFolderID,
                localWorkspace: session.localWorkspace,
                localProjectFolderID: session.localProjectFolderID
            ),
            to: nil,
            plannedWorktreeID: nil,
            createdWorktreeID: nil,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            recoverySnapshot: localRecoverySnapshot,
            expectedDestinationFingerprint: localRecoverySnapshot.snapshotFingerprint,
            desiredDestinationFingerprint: desiredDestinationFingerprint,
            stage: .prepared,
            startedAt: now,
            updatedAt: now
        )
        try save(entry)
        return entry
    }

    func markDestinationAllocated(
        _ entry: AgentTaskHandoffJournalEntry,
        binding: AgentTaskBindingSnapshot,
        createdWorktreeID: UUID?,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard entry.stage == .prepared else {
            throw AgentTaskHandoffJournalError.invalidEntry("destination transition is out of order")
        }
        if let planned = entry.plannedWorktreeID,
           let createdWorktreeID,
           planned != createdWorktreeID {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "created worktree ID differs from durable plan"
            )
        }
        var updated = entry
        updated.to = binding
        updated.createdWorktreeID = createdWorktreeID
        updated.stage = .destinationAllocated
        updated.updatedAt = now
        try save(updated)
        return updated
    }

    func markDestinationReady(
        _ entry: AgentTaskHandoffJournalEntry,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard entry.stage == .destinationAllocated, entry.to != nil else {
            throw AgentTaskHandoffJournalError.invalidEntry("destination-ready transition is out of order")
        }
        var updated = entry
        updated.stage = .destinationReady
        updated.updatedAt = now
        try save(updated)
        return updated
    }

    func markSessionCommitted(
        _ entry: AgentTaskHandoffJournalEntry,
        now: Date = Date()
    ) throws -> AgentTaskHandoffJournalEntry {
        guard entry.stage == .destinationReady, entry.to != nil else {
            throw AgentTaskHandoffJournalError.invalidEntry("session transition is out of order")
        }
        var updated = entry
        updated.stage = .sessionCommitted
        updated.updatedAt = now
        try save(updated)
        return updated
    }

    func pendingEntries() throws -> [AgentTaskHandoffJournalEntry] {
        try ensureRoot()
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        guard urls.count <= Self.maximumEntries else {
            throw AgentTaskHandoffJournalError.invalidEntry("entry count exceeds the safety limit")
        }
        var entries: [AgentTaskHandoffJournalEntry] = []
        for url in urls where url.pathExtension == "json" {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size <= Self.maximumEntryBytes else {
                throw AgentTaskHandoffJournalError.invalidEntry("entry is not a bounded regular file")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Self.maximumEntryBytes else {
                throw AgentTaskHandoffJournalError.oversized(Self.maximumEntryBytes)
            }
            let entry = try JSONDecoder().decode(AgentTaskHandoffJournalEntry.self, from: data)
            guard entry.id.uuidString.lowercased()
                    == url.deletingPathExtension().lastPathComponent.lowercased() else {
                throw AgentTaskHandoffJournalError.invalidEntry("filename and transaction ID differ")
            }
            try Self.validate(entry)
            entries.append(entry)
        }
        return entries.sorted { $0.startedAt < $1.startedAt }
    }

    func remove(id: UUID) throws {
        try ensureRoot()
        let file = entryFile(id)
        guard file.deletingLastPathComponent() == root else {
            throw AgentTaskHandoffJournalError.invalidEntry("entry path escaped journal root")
        }
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    private func save(_ entry: AgentTaskHandoffJournalEntry) throws {
        try Self.validate(entry)
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry)
        guard data.count <= Self.maximumEntryBytes else {
            throw AgentTaskHandoffJournalError.oversized(Self.maximumEntryBytes)
        }
        try AtomicFileWriter.write(data, to: entryFile(entry.id))
    }

    private func ensureRoot() throws {
        let allowedParents = [
            AppPaths.appSupport.standardizedFileURL,
            AppPaths.projectTemporaryRoot.standardizedFileURL
        ]
        guard let parent = allowedParents
            .filter({ root.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else {
            throw AgentTaskHandoffJournalError.invalidEntry("journal root escaped Application Support")
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = Darwin.stat()
        guard Darwin.lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "allowed journal storage is not a directory"
            )
        }
        let suffix = String(root.path.dropFirst(parent.path.count + 1))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentTaskHandoffJournalError.invalidEntry("journal root path is malformed")
        }
        var cursor = parent
        for component in components {
            cursor.appendPathComponent(String(component), isDirectory: true)
            var info = Darwin.stat()
            if Darwin.lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "journal root contains a link or non-directory component"
                    )
                }
            } else {
                guard errno == ENOENT,
                      Darwin.mkdir(cursor.path, mode_t(0o700)) == 0 || errno == EEXIST,
                      Darwin.lstat(cursor.path, &info) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "journal root could not be created safely"
                    )
                }
            }
        }
    }

    private func entryFile(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased() + ".json", isDirectory: false)
    }

    private static func validate(_ entry: AgentTaskHandoffJournalEntry) throws {
        guard entry.updatedAt >= entry.startedAt else {
            throw AgentTaskHandoffJournalError.invalidEntry("timestamps are inverted")
        }
        switch entry.resolvedTransitionKind {
        case .handoff:
            guard entry.sourceSessionID == nil
                    || entry.sourceSessionID == entry.sessionID else {
                throw AgentTaskHandoffJournalError.invalidEntry("handoff source and target Task differ")
            }
        case .handoffToLocal:
            guard entry.sourceSessionID == entry.sessionID,
                  entry.plannedWorktreeID == nil,
                  entry.createdWorktreeID == nil,
                  let sourceWorktreeID = entry.sourceWorktreeID,
                  let lease = entry.sourceWorktreeLease,
                  lease.worktreeID == sourceWorktreeID,
                  lease.taskID == entry.sessionID,
                  let recovery = entry.recoverySnapshot,
                  recovery.transactionID == entry.id,
                  recovery.relativePath
                    == entry.id.uuidString.lowercased() + ".snapshot",
                  recovery.byteCount > 0,
                  recovery.byteCount <= WorktreeStateRecoveryStore.maximumEncodedBytes,
                  isDigest(recovery.sha256),
                  isDigest(recovery.snapshotFingerprint),
                  let expectedFingerprint = entry.expectedDestinationFingerprint,
                  recovery.snapshotFingerprint == expectedFingerprint,
                  isDigest(expectedFingerprint),
                  let desiredFingerprint = entry.desiredDestinationFingerprint,
                  isDigest(desiredFingerprint) else {
                throw AgentTaskHandoffJournalError.invalidEntry(
                    "reverse handoff recovery capability is missing"
                )
            }
        case .handoffToRemote:
            guard entry.sourceSessionID == entry.sessionID,
                  (entry.from.location.kind == .local
                    || entry.from.location.kind == .worktree),
                  entry.plannedWorktreeID == nil,
                  entry.createdWorktreeID == nil,
                  let recovery = entry.recoverySnapshot,
                  recovery.transactionID == entry.id,
                  recovery.relativePath
                    == entry.id.uuidString.lowercased() + ".snapshot",
                  recovery.byteCount > 0,
                  recovery.byteCount <= WorktreeStateRecoveryStore.maximumEncodedBytes,
                  isDigest(recovery.sha256),
                  isDigest(recovery.snapshotFingerprint),
                  let baseline = entry.expectedDestinationFingerprint,
                  isDigest(baseline),
                  let desired = entry.desiredDestinationFingerprint,
                  desired == recovery.snapshotFingerprint,
                  isDigest(desired) else {
                throw AgentTaskHandoffJournalError.invalidEntry(
                    "remote handoff recovery capability is missing"
                )
            }
            if let baselineSnapshot = entry.remoteBaselineSnapshot {
                let baseline = try baselineSnapshot.validated()
                guard baseline.fingerprint == entry.expectedDestinationFingerprint,
                      baseline.isClean else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "remote handoff baseline snapshot is invalid"
                    )
                }
            }
            if let identity = entry.remoteExecutionIdentity {
                guard isDigest(identity.configurationFingerprint),
                      !identity.host.isEmpty,
                      !identity.user.isEmpty,
                      identity.port > 0,
                      !identity.workspaceRoot.isEmpty else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "remote handoff runner identity is invalid"
                    )
                }
                if let destination = entry.to {
                    guard destination.location.remoteRunnerID == identity.runnerID else {
                        throw AgentTaskHandoffJournalError.invalidEntry(
                            "remote handoff runner identity does not match its destination"
                        )
                    }
                }
            }
            if entry.from.location.kind == .worktree {
                guard let sourceID = entry.sourceWorktreeID,
                      let lease = entry.sourceWorktreeLease,
                      entry.from.location.managedWorktreeID == sourceID,
                      lease.worktreeID == sourceID,
                      lease.taskID == entry.sessionID else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "remote handoff worktree capability is missing"
                    )
                }
            } else if entry.sourceWorktreeID != nil || entry.sourceWorktreeLease != nil {
                throw AgentTaskHandoffJournalError.invalidEntry(
                    "local remote handoff carries an unexpected worktree capability"
                )
            }
        case .handoffFromRemote:
            guard entry.sourceSessionID == entry.sessionID,
                  entry.from.location.kind == .ssh,
                  entry.from.location.remoteRunnerID != nil,
                  entry.plannedWorktreeID == nil,
                  entry.createdWorktreeID == nil,
                  entry.sourceWorktreeID == nil,
                  entry.sourceWorktreeLease == nil,
                  let recovery = entry.recoverySnapshot,
                  recovery.transactionID == entry.id,
                  recovery.relativePath
                    == entry.id.uuidString.lowercased() + ".snapshot",
                  recovery.byteCount > 0,
                  recovery.byteCount <= WorktreeStateRecoveryStore.maximumEncodedBytes,
                  isDigest(recovery.sha256),
                  isDigest(recovery.snapshotFingerprint),
                  let expected = entry.expectedDestinationFingerprint,
                  expected == recovery.snapshotFingerprint,
                  isDigest(expected),
                  let desired = entry.desiredDestinationFingerprint,
                  isDigest(desired) else {
                throw AgentTaskHandoffJournalError.invalidEntry(
                    "SSH-to-Local recovery capability is missing"
                )
            }
        case .fork:
            guard let sourceSessionID = entry.sourceSessionID,
                  sourceSessionID != entry.sessionID,
                  entry.plannedWorktreeID != nil else {
                throw AgentTaskHandoffJournalError.invalidEntry("fork source or planned checkout is missing")
            }
        }
        if let planned = entry.plannedWorktreeID,
           let created = entry.createdWorktreeID,
           planned != created {
            throw AgentTaskHandoffJournalError.invalidEntry(
                "planned and created worktree IDs differ"
            )
        }
        switch entry.stage {
        case .prepared:
            guard entry.to == nil, entry.createdWorktreeID == nil else {
                throw AgentTaskHandoffJournalError.invalidEntry("prepared entry already has a destination")
            }
        case .destinationAllocated, .destinationReady, .sessionCommitted:
            guard entry.to != nil else {
                throw AgentTaskHandoffJournalError.invalidEntry("destination binding is missing")
            }
        }
        if let destination = entry.to {
            switch entry.resolvedTransitionKind {
            case .handoffToRemote:
                guard destination.location.kind == .ssh,
                      destination.location.remoteRunnerID != nil else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "remote handoff destination is not an SSH runner"
                    )
                }
            case .handoffFromRemote:
                guard destination.location.kind == .local else {
                    throw AgentTaskHandoffJournalError.invalidEntry(
                        "SSH-to-Local destination is not Local"
                    )
                }
            case .handoff, .handoffToLocal, .fork:
                break
            }
        }
        for workspace in [entry.from.workspace, entry.to?.workspace].compactMap({ $0 }) {
            guard !workspace.rootPath.isEmpty,
                  workspace.rootPath.hasPrefix("/"),
                  workspace.rootPath != "/",
                  workspace.rootPath.utf8.count <= AgentProjectCatalogLimits.maximumPathBytes,
                  workspace.allowedPaths.isEmpty else {
                throw AgentTaskHandoffJournalError.invalidEntry("workspace authorization is invalid")
            }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }
}
