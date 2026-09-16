import CryptoKit
import Darwin
import Foundation

enum ChangeManagerError: LocalizedError, Sendable {
    case unsupportedSymbolicLink(String)
    case unsupportedFileType(String)
    case snapshotTooLarge(Int)
    case transactionNotFound
    case noChangesToUndo
    case secureBoundaryUnavailable
    case historyEntryTooLarge(Int)
    case undoConflict([String])
    case changeNotLatest(UUID)
    case changeIdentityMismatch
    case persistentHistoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSymbolicLink(let path):
            "Cannot snapshot symbolic link: \(path)"
        case .unsupportedFileType(let path):
            "Cannot safely snapshot non-regular file: \(path)"
        case .snapshotTooLarge(let limit):
            "Change snapshot exceeds the \(limit)-byte safety limit."
        case .transactionNotFound:
            "The file change transaction is no longer active."
        case .noChangesToUndo:
            "There are no file changes to undo."
        case .secureBoundaryUnavailable:
            "The workspace security boundary is unavailable."
        case .historyEntryTooLarge(let limit):
            "The change history entry exceeds the \(limit)-byte safety limit."
        case .undoConflict(let paths):
            "Undo was refused because files changed after the Agent edit: \(paths.joined(separator: ", "))."
        case .changeNotLatest(let changeID):
            "Change \(changeID.uuidString) is not the most recent change. Dispose of newer changes first."
        case .changeIdentityMismatch:
            "The requested change does not belong to this task, or is no longer available."
        case .persistentHistoryUnavailable(let detail):
            "The durable Undo history is unavailable: \(detail)"
        }
    }
}

enum FileChangeOperation: String, Codable, Sendable {
    case create
    case write
    case edit
    case patch
    case delete
    case move
    case copy
    case createDirectory
    case git
}

struct ChangedFileDiff: Codable, Sendable, Equatable {
    var path: String
    var diff: String
}

struct FileChangeRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var taskID: UUID
    var operation: FileChangeOperation
    var paths: [String]
    var diffs: [ChangedFileDiff]
    var createdAt: Date
}

struct FileChangeTransaction: Sendable {
    fileprivate var id: UUID
}

private struct PendingChange: Sendable {
    var taskID: UUID
    var operation: FileChangeOperation
    var snapshots: [SecurePathSnapshot]
}

fileprivate struct HistoryEntry: Codable, Sendable, Equatable {
    var record: FileChangeRecord
    var before: [SecurePathSnapshot]
    var afterFingerprints: [SecureSnapshotFingerprint]
    var storageBytes: Int
}

fileprivate struct SecureSnapshotFingerprint: Codable, Sendable, Equatable {
    var requestedPath: String
    var existed: Bool
    var entries: [SecureSnapshotEntryFingerprint]
}

fileprivate struct SecureSnapshotEntryFingerprint: Codable, Sendable, Equatable {
    enum Kind: Codable, Sendable, Equatable {
        case directory
        case file(byteCount: Int, sha256: Data)
    }

    var relativePath: String
    var permissions: Int
    var kind: Kind
}

/// Opaque in-process handoff payload. Snapshot bytes never enter the Task JSON
/// or model context; they move directly between two task-owned ChangeManagers
/// while the durable handoff journal protects the surrounding transaction.
struct ChangeHistoryTransfer: Sendable {
    fileprivate var entries: [HistoryEntry]
    var droppedChangeIDs: Set<UUID>

    var transferredChangeIDs: Set<UUID> {
        Set(entries.map(\.record.id))
    }
}

private struct PersistedChangeHistory: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var workspaceIdentity: String
    var entries: [HistoryEntry]
}

/// A narrowly-scoped store for restart-safe Undo state. Its destination is a
/// UUID-derived direct descendant of project `tmp/agent-snapshots`; source and
/// persistent app settings never move into this disposable tree.
private struct ChangeHistoryPersistence: Sendable {
    let fileURL: URL
    let workspaceIdentity: String

    init(fileURL: URL, workspaceIdentity: String) throws {
        let root = AppPaths.agentSnapshots.standardizedFileURL
        let candidate = fileURL.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              candidate.lastPathComponent == "history.json" else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(candidate.path)
        }
        self.fileURL = candidate
        self.workspaceIdentity = workspaceIdentity
    }

    func load(maximumBytes: Int) throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try validateSafeStoragePath(createDirectories: false)
        var info = Darwin.stat()
        guard Darwin.lstat(fileURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(maximumBytes) else {
            throw ChangeManagerError.persistentHistoryUnavailable("history file is not a bounded regular file")
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw ChangeManagerError.persistentHistoryUnavailable("history file exceeds the safety limit")
        }
        let manifest = try JSONDecoder().decode(PersistedChangeHistory.self, from: data)
        guard manifest.version == PersistedChangeHistory.currentVersion,
              manifest.workspaceIdentity == workspaceIdentity else {
            throw ChangeManagerError.persistentHistoryUnavailable("history identity does not match this workspace")
        }
        return manifest.entries
    }

    func save(_ entries: [HistoryEntry], maximumBytes: Int) throws {
        try validateSafeStoragePath(createDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(PersistedChangeHistory(
            version: PersistedChangeHistory.currentVersion,
            workspaceIdentity: workspaceIdentity,
            entries: entries
        ))
        guard data.count <= maximumBytes else {
            throw ChangeManagerError.persistentHistoryUnavailable("encoded history exceeds the safety limit")
        }
        try AtomicFileWriter.write(data, to: fileURL)
        _ = Darwin.chmod(fileURL.path, S_IRUSR | S_IWUSR)
    }

    private func validateSafeStoragePath(createDirectories: Bool) throws {
        let root = AppPaths.agentSnapshots.standardizedFileURL
        let parent = fileURL.deletingLastPathComponent()
        if createDirectories {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        for directory in [root, parent.deletingLastPathComponent(), parent] {
            var info = Darwin.stat()
            guard Darwin.lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw ChangeManagerError.persistentHistoryUnavailable("snapshot directory is missing, unsafe, or symbolic")
            }
            _ = Darwin.chmod(directory.path, S_IRWXU)
        }
        guard parent.path.hasPrefix(root.path + "/") else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(parent.path)
        }
    }
}

/// Records every filesystem mutation before it runs and creates a displayable
/// diff after it succeeds. Undo uses the snapshots directly and therefore works
/// without requiring the workspace to be a Git repository.
actor ChangeManager {
    typealias HistorySaveHook = @Sendable () throws -> Void

    private let validator: WorkspaceSecurityValidator
    private let secureIO: SecureWorkspaceIO?
    private let maximumSnapshotBytes: Int
    private let maximumHistoryRecords: Int
    private let maximumHistoryBytes: Int
    private let persistence: ChangeHistoryPersistence?
    private let historySaveHook: HistorySaveHook?
    private var pending: [UUID: PendingChange] = [:]
    private var history: [HistoryEntry] = []
    private var historyStorageBytes = 0
    private var persistenceLoadError: String?

    init(
        validator: WorkspaceSecurityValidator,
        fileManager: FileManager = .default,
        maximumSnapshotBytes: Int = 64 * 1_024 * 1_024,
        maximumHistoryRecords: Int = 100,
        maximumHistoryBytes: Int = 128 * 1_024 * 1_024,
        historyFileURL: URL? = nil,
        workspaceIdentity: String? = nil,
        historySaveHook: HistorySaveHook? = nil
    ) {
        self.validator = validator
        _ = fileManager // Kept for source compatibility with existing callers.
        secureIO = try? SecureWorkspaceIO(validator: validator)
        self.maximumSnapshotBytes = max(1_024, maximumSnapshotBytes)
        self.maximumHistoryRecords = max(1, maximumHistoryRecords)
        self.maximumHistoryBytes = max(1, maximumHistoryBytes)
        self.historySaveHook = historySaveHook
        if let historyFileURL, let workspaceIdentity {
            persistence = try? ChangeHistoryPersistence(
                fileURL: historyFileURL,
                workspaceIdentity: workspaceIdentity
            )
        } else {
            persistence = nil
        }

        if let persistence {
            do {
                let wireLimit = Self.persistenceWireLimit(historyBytes: self.maximumHistoryBytes)
                let loaded = try persistence.load(maximumBytes: wireLimit)
                var validated: [HistoryEntry] = []
                var total = 0
                var entryCount = 0
                for var entry in loaded.suffix(self.maximumHistoryRecords) {
                    guard entry.record.paths == entry.before.map(\.requestedPath),
                          entry.afterFingerprints.map(\.requestedPath) == entry.record.paths else {
                        throw ChangeManagerError.persistentHistoryUnavailable("history paths are inconsistent")
                    }
                    for path in entry.record.paths {
                        _ = try validator.secureRelativePath(for: path, access: .write)
                    }
                    for snapshot in entry.before {
                        for item in snapshot.entries {
                            entryCount += 1
                            guard entryCount <= 100_000,
                                  Self.isSafeSnapshotRelativePath(item.relativePath),
                                  (0...0o7777).contains(item.permissions) else {
                                throw ChangeManagerError.persistentHistoryUnavailable("snapshot entry metadata is unsafe")
                            }
                        }
                    }
                    for fingerprint in entry.afterFingerprints {
                        for item in fingerprint.entries {
                            entryCount += 1
                            guard entryCount <= 200_000,
                                  Self.isSafeSnapshotRelativePath(item.relativePath),
                                  (0...0o7777).contains(item.permissions) else {
                                throw ChangeManagerError.persistentHistoryUnavailable("snapshot fingerprint metadata is unsafe")
                            }
                            if case .file(let byteCount, let digest) = item.kind {
                                guard byteCount >= 0, digest.count == 32 else {
                                    throw ChangeManagerError.persistentHistoryUnavailable("snapshot fingerprint is malformed")
                                }
                            }
                        }
                    }
                    let cost = try Self.historyStorageCost(
                        snapshots: entry.before,
                        afterFingerprints: entry.afterFingerprints,
                        diffs: entry.record.diffs,
                        maximumBytes: self.maximumHistoryBytes
                    )
                    guard total <= self.maximumHistoryBytes - cost else {
                        throw ChangeManagerError.persistentHistoryUnavailable("history exceeds retention limits")
                    }
                    entry.storageBytes = cost
                    total += cost
                    validated.append(entry)
                }
                history = validated
                historyStorageBytes = total
            } catch {
                persistenceLoadError = error.localizedDescription
            }
        }
    }

    func beginChange(
        paths: [String],
        operation: FileChangeOperation,
        taskID: UUID
    ) throws -> FileChangeTransaction {
        // Path order is part of the mutation contract. In particular, move
        // records must retain [source, destination] so snapshot restore order
        // cannot be inverted by a Set or lexical sort.
        let uniquePaths = Self.orderedUniquePaths(paths)
        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }
        var remainingBytes = maximumSnapshotBytes
        let snapshots = try uniquePaths.map { path in
            _ = try validator.secureRelativePath(for: path, access: .write)
            let snapshot: SecurePathSnapshot
            do {
                snapshot = try secureIO.snapshot(path: path, maximumBytes: remainingBytes)
            } catch SecureWorkspaceIOError.symbolicLink(let unsafePath) {
                throw ChangeManagerError.unsupportedSymbolicLink(unsafePath)
            } catch SecureWorkspaceIOError.unsupportedFileType(let unsafePath) {
                throw ChangeManagerError.unsupportedFileType(unsafePath)
            } catch SecureWorkspaceIOError.snapshotTooLarge {
                throw ChangeManagerError.snapshotTooLarge(maximumSnapshotBytes)
            }
            remainingBytes -= snapshot.entries.reduce(into: 0) { total, entry in
                if case .file(let data) = entry.kind { total += data.count }
            }
            return snapshot
        }
        let transaction = FileChangeTransaction(id: UUID())
        pending[transaction.id] = PendingChange(
            taskID: taskID,
            operation: operation,
            snapshots: snapshots
        )
        return transaction
    }

    func commitChange(_ transaction: FileChangeTransaction) throws -> FileChangeRecord {
        guard let change = pending[transaction.id] else {
            throw ChangeManagerError.transactionNotFound
        }
        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }

        var remainingBytes = maximumSnapshotBytes
        let after = try change.snapshots.map { before in
            let snapshot = try secureIO.snapshot(
                path: before.requestedPath,
                maximumBytes: remainingBytes,
                honorCancellation: false
            )
            remainingBytes -= snapshot.entries.reduce(into: 0) { total, entry in
                if case .file(let data) = entry.kind { total += data.count }
            }
            return snapshot
        }
        let diffs = try makeDiffs(before: change.snapshots, after: after)
        let record = FileChangeRecord(
            id: transaction.id,
            taskID: change.taskID,
            operation: change.operation,
            paths: change.snapshots.map(\.requestedPath),
            diffs: diffs,
            createdAt: Date()
        )
        let afterFingerprints = after.map(Self.fingerprint)
        let storageBytes = try Self.historyStorageCost(
            snapshots: change.snapshots,
            afterFingerprints: afterFingerprints,
            diffs: diffs,
            maximumBytes: maximumHistoryBytes
        )
        guard storageBytes <= maximumHistoryBytes else {
            // Keep the pending transaction alive so the caller can restore the
            // pre-mutation snapshot after this fail-closed commit error.
            throw ChangeManagerError.historyEntryTooLarge(maximumHistoryBytes)
        }

        var nextHistory = history
        var nextStorageBytes = historyStorageBytes
        while let oldest = nextHistory.first,
              nextHistory.count >= maximumHistoryRecords
                || nextStorageBytes > maximumHistoryBytes - storageBytes {
            nextHistory.removeFirst()
            nextStorageBytes = max(0, nextStorageBytes - oldest.storageBytes)
        }
        nextHistory.append(HistoryEntry(
            record: record,
            before: change.snapshots,
            afterFingerprints: afterFingerprints,
            storageBytes: storageBytes
        ))
        nextStorageBytes += storageBytes

        // Persist first. If durable history cannot be committed, the pending
        // transaction remains available for the filesystem layer to roll back.
        try historySaveHook?()
        try persistence?.save(
            nextHistory,
            maximumBytes: Self.persistenceWireLimit(historyBytes: maximumHistoryBytes)
        )
        pending.removeValue(forKey: transaction.id)
        history = nextHistory
        historyStorageBytes = nextStorageBytes
        persistenceLoadError = nil
        return record
    }

    /// Rolls back a mutation that succeeded but could not be committed to the
    /// change history. Calling this before the mutation is also harmless.
    func rollbackChange(_ transaction: FileChangeTransaction) throws {
        guard let change = pending[transaction.id] else {
            throw ChangeManagerError.transactionNotFound
        }
        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }
        try secureIO.restore(change.snapshots)
        pending.removeValue(forKey: transaction.id)
    }

    /// Drops a transaction when its atomic mutation never committed. This
    /// avoids restoring an old snapshot over a concurrent writer that caused
    /// an exclusive create/rename to fail.
    func abandonChange(_ transaction: FileChangeTransaction) throws {
        guard pending.removeValue(forKey: transaction.id) != nil else {
            throw ChangeManagerError.transactionNotFound
        }
    }

    func records() -> [FileChangeRecord] {
        history.map(\.record)
    }

    /// Returns the restart-safe Undo records owned by one Agent task while
    /// preserving their global commit order. Session recovery uses this view
    /// to repair the small crash window between committing an Undo snapshot
    /// and durably saving its corresponding change card.
    func records(taskID: UUID) -> [FileChangeRecord] {
        history.lazy
            .map(\.record)
            .filter { $0.taskID == taskID }
    }

    /// Exports workspace-relative native file snapshots for a Task handoff.
    /// Git metadata snapshots are intentionally excluded: a linked worktree's
    /// `.git` is a pointer, so importing `.git/index` or refs as workspace files
    /// would be both incorrect and unsafe. The handoff's Git state migrator
    /// handles the actual index/HEAD state and the UI marks those old metadata
    /// cards read-only.
    func exportForHandoff(taskID: UUID) throws -> ChangeHistoryTransfer {
        if let persistenceLoadError {
            throw ChangeManagerError.persistentHistoryUnavailable(persistenceLoadError)
        }
        let taskEntries = history.filter { $0.record.taskID == taskID }
        let lastNontransferableIndex = taskEntries.lastIndex { entry in
            entry.record.paths.contains { $0 == ".git" || $0.hasPrefix(".git/") }
        }
        let transferStart = lastNontransferableIndex.map { $0 + 1 } ?? 0
        let transferable = Array(taskEntries.dropFirst(transferStart))
        // Undo is a LIFO chain. Once one entry cannot move, that entry and every
        // older entry must be unavailable at the destination; retaining older
        // snapshots across the gap would create a false future Undo promise.
        let dropped = Set(taskEntries.prefix(transferStart).map(\.record.id))
        return ChangeHistoryTransfer(entries: transferable, droppedChangeIDs: dropped)
    }

    /// Imports a handoff payload only when every current destination path has
    /// the exact after-fingerprint recorded at the source. This compare-and-
    /// swap check prevents an imported Undo entry from overwriting divergent
    /// destination work.
    func importFromHandoff(
        _ transfer: ChangeHistoryTransfer,
        taskID: UUID,
        discardChangeIDs: Set<UUID> = []
    ) throws -> Set<UUID> {
        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }
        var imported: [HistoryEntry] = []
        var importedBytes = 0
        for entry in transfer.entries {
            guard entry.record.taskID == taskID,
                  entry.record.paths == entry.before.map(\.requestedPath),
                  entry.afterFingerprints.map(\.requestedPath) == entry.record.paths else {
                throw ChangeManagerError.changeIdentityMismatch
            }
            for path in entry.record.paths {
                _ = try validator.secureRelativePath(for: path, access: .write)
            }
            let cost = try Self.historyStorageCost(
                snapshots: entry.before,
                afterFingerprints: entry.afterFingerprints,
                diffs: entry.record.diffs,
                maximumBytes: maximumHistoryBytes
            )
            guard imported.count < maximumHistoryRecords,
                  importedBytes <= maximumHistoryBytes - cost else {
                throw ChangeManagerError.historyEntryTooLarge(maximumHistoryBytes)
            }
            var normalized = entry
            normalized.storageBytes = cost
            imported.append(normalized)
            importedBytes += cost
        }
        let discardedPrefixCount = history.prefix {
            discardChangeIDs.contains($0.record.id)
        }.count
        guard !history.dropFirst(discardedPrefixCount).contains(where: {
            discardChangeIDs.contains($0.record.id)
        }) else {
            throw ChangeManagerError.persistentHistoryUnavailable(
                "discarded Undo entries are not a contiguous oldest prefix"
            )
        }
        let destinationHistory = Array(history.dropFirst(discardedPrefixCount))
        let merged: [HistoryEntry]
        if destinationHistory.isEmpty {
            merged = imported
        } else if imported.isEmpty {
            merged = destinationHistory
        } else if let overlap = destinationHistory.firstIndex(where: {
            $0.record.id == imported[0].record.id
        }) {
            let existingSuffix = Array(destinationHistory[overlap...])
            guard existingSuffix.count <= imported.count,
                  Array(imported.prefix(existingSuffix.count)) == existingSuffix else {
                throw ChangeManagerError.persistentHistoryUnavailable(
                    "destination Undo lineage diverged"
                )
            }
            merged = Array(destinationHistory[..<overlap]) + imported
        } else {
            throw ChangeManagerError.persistentHistoryUnavailable(
                "destination Undo history has no verified handoff overlap"
            )
        }
        guard merged.count <= maximumHistoryRecords else {
            throw ChangeManagerError.historyEntryTooLarge(maximumHistoryBytes)
        }
        let mergedBytes = merged.reduce(0) { $0 + $1.storageBytes }
        guard mergedBytes <= maximumHistoryBytes else {
            throw ChangeManagerError.historyEntryTooLarge(maximumHistoryBytes)
        }
        if let latest = merged.last {
            try verifyCurrentState(of: latest, secureIO: secureIO)
        }
        try saveHistory(merged)
        history = merged
        historyStorageBytes = mergedBytes
        persistenceLoadError = nil
        return Set(imported.map(\.record.id))
    }

    @discardableResult
    func undoLast() throws -> FileChangeRecord {
        try undoLatest(requireLatestEntry())
    }

    /// Restores only the most recent change belonging to the requesting task.
    /// Tool callers should use this overload so one Agent session cannot undo
    /// another session/task's workspace mutation. The parameterless overload
    /// remains for host-level compatibility and tests.
    @discardableResult
    func undoLast(taskID: UUID) throws -> FileChangeRecord {
        let item = try requireLatestEntry()
        guard item.record.taskID == taskID else {
            throw ChangeManagerError.noChangesToUndo
        }
        return try undoLatest(item)
    }

    /// Restores exactly one known change. Disposition is deliberately LIFO:
    /// restoring an older snapshot through newer edits could overwrite valid
    /// Agent or user work. Both identifiers must match the latest record.
    @discardableResult
    func undoSpecific(taskID: UUID, changeID: UUID) throws -> FileChangeRecord {
        try undoLatest(requireLatestEntry(taskID: taskID, changeID: changeID))
    }

    /// Accepts the latest Agent change by discarding only its Undo snapshot.
    /// The workspace is never read or written. Durable history is committed
    /// before the actor's in-memory history changes, so a failed save leaves
    /// the disposition retryable in this process.
    @discardableResult
    func keepSpecific(taskID: UUID, changeID: UUID) throws -> FileChangeRecord {
        let item = try requireLatestEntry(taskID: taskID, changeID: changeID)
        var nextHistory = history
        nextHistory.removeLast()
        try saveHistory(nextHistory)
        history = nextHistory
        historyStorageBytes = max(0, historyStorageBytes - item.storageBytes)
        persistenceLoadError = nil
        return item.record
    }

    @discardableResult
    func undoTask(_ taskID: UUID) throws -> [FileChangeRecord] {
        let matchingIndices = history.indices.filter { history[$0].record.taskID == taskID }
        if matchingIndices.isEmpty, let persistenceLoadError {
            throw ChangeManagerError.persistentHistoryUnavailable(persistenceLoadError)
        }
        guard let firstMatchingIndex = matchingIndices.first,
              history[firstMatchingIndex...].allSatisfy({ $0.record.taskID == taskID }) else {
            throw ChangeManagerError.noChangesToUndo
        }

        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }

        let items = matchingIndices.reversed().map { history[$0] }
        let compensationPaths = Self.orderedUniquePaths(
            items.flatMap { $0.record.paths }
        )
        let compensation = try snapshotCurrentState(
            paths: compensationPaths,
            maximumBytes: maximumHistoryBytes,
            secureIO: secureIO,
            conflictPaths: compensationPaths
        )
        var mutationAttempted = false
        do {
            // Verification remains sequential because two retained entries may
            // touch the same path: restoring the newest entry exposes exactly
            // the fingerprint expected by the preceding entry.
            for item in items {
                try verifyCurrentState(of: item, secureIO: secureIO)
                mutationAttempted = true
                try secureIO.restore(item.before)
            }

            var nextHistory = history
            for index in matchingIndices.reversed() {
                nextHistory.remove(at: index)
            }
            try saveHistory(nextHistory)
            history = nextHistory
            let removedBytes = items.reduce(into: 0) { $0 += $1.storageBytes }
            historyStorageBytes = max(0, historyStorageBytes - removedBytes)
            persistenceLoadError = nil
            return items.map(\.record)
        } catch {
            try compensateUndoIfNeeded(
                mutationAttempted: mutationAttempted,
                snapshots: compensation,
                secureIO: secureIO,
                originalError: error
            )
        }
    }

    func historyStorageByteCountForTesting() -> Int {
        historyStorageBytes
    }

    private func makeDiffs(
        before: [SecurePathSnapshot],
        after: [SecurePathSnapshot]
    ) throws -> [ChangedFileDiff] {
        let builder = UnifiedDiffBuilder()
        var output: [ChangedFileDiff] = []
        var outputBytes = 0
        for (oldSnapshot, newSnapshot) in zip(before, after) {
            if Task.isCancelled { throw CancellationError() }
            let oldFiles = flattenedFiles(oldSnapshot)
            let newFiles = flattenedFiles(newSnapshot)
            let paths = Set(oldFiles.keys).union(newFiles.keys).sorted()
            for relativePath in paths where oldFiles[relativePath] != newFiles[relativePath] {
                if Task.isCancelled { throw CancellationError() }
                let displayPath = relativePath.isEmpty
                    ? oldSnapshot.requestedPath
                    : oldSnapshot.requestedPath + "/" + relativePath
                let diff = builder.make(
                    path: displayPath,
                    old: oldFiles[relativePath],
                    new: newFiles[relativePath]
                )
                let diffBytes = diff.utf8.count
                guard diffBytes <= maximumHistoryBytes,
                      outputBytes <= maximumHistoryBytes - diffBytes else {
                    throw ChangeManagerError.historyEntryTooLarge(maximumHistoryBytes)
                }
                outputBytes += diffBytes
                output.append(ChangedFileDiff(
                    path: displayPath,
                    diff: diff
                ))
            }
        }
        return output
    }

    private static func historyStorageCost(
        snapshots: [SecurePathSnapshot],
        afterFingerprints: [SecureSnapshotFingerprint],
        diffs: [ChangedFileDiff],
        maximumBytes: Int
    ) throws -> Int {
        var total = 0

        func add(_ bytes: Int) throws {
            guard bytes >= 0,
                  bytes <= maximumBytes,
                  total <= maximumBytes - bytes else {
                throw ChangeManagerError.historyEntryTooLarge(maximumBytes)
            }
            total += bytes
        }

        for snapshot in snapshots {
            try add(snapshot.requestedPath.utf8.count + 64)
            for entry in snapshot.entries {
                try add(entry.relativePath.utf8.count + 96)
                if case .file(let data) = entry.kind {
                    try add(data.count)
                }
            }
        }
        for snapshot in afterFingerprints {
            try add(snapshot.requestedPath.utf8.count + 64)
            for entry in snapshot.entries {
                try add(entry.relativePath.utf8.count + 128)
            }
        }
        for diff in diffs {
            try add(diff.diff.utf8.count)
        }
        return total
    }

    private static func persistenceWireLimit(historyBytes: Int) -> Int {
        // JSON base64 expansion is < 4/3. Two times the bounded logical history
        // leaves metadata headroom without permitting unbounded decoding.
        let (doubled, overflow) = historyBytes.multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : max(2_048, doubled)
    }

    private static func isSafeSnapshotRelativePath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        guard !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func orderedUniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private func requireLatestEntry() throws -> HistoryEntry {
        guard let item = history.last else {
            if let persistenceLoadError {
                throw ChangeManagerError.persistentHistoryUnavailable(persistenceLoadError)
            }
            throw ChangeManagerError.noChangesToUndo
        }
        return item
    }

    private func requireLatestEntry(taskID: UUID, changeID: UUID) throws -> HistoryEntry {
        let latest = try requireLatestEntry()
        guard latest.record.id == changeID else {
            if history.contains(where: {
                $0.record.id == changeID && $0.record.taskID == taskID
            }) {
                throw ChangeManagerError.changeNotLatest(changeID)
            }
            throw ChangeManagerError.changeIdentityMismatch
        }
        guard latest.record.taskID == taskID else {
            throw ChangeManagerError.changeIdentityMismatch
        }
        return latest
    }

    private func undoLatest(_ item: HistoryEntry) throws -> FileChangeRecord {
        guard history.last?.record.id == item.record.id else {
            throw ChangeManagerError.changeNotLatest(item.record.id)
        }
        guard let secureIO else { throw ChangeManagerError.secureBoundaryUnavailable }
        let compensation = try verifiedCurrentSnapshots(of: item, secureIO: secureIO)

        var nextHistory = history
        nextHistory.removeLast()
        var mutationAttempted = false
        do {
            // Restore necessarily precedes persistence: dropping the durable
            // record first could lose recovery if restore itself failed. The
            // current post-change snapshot compensates any restore/save error,
            // keeping filesystem, memory, and durable history in one state.
            mutationAttempted = true
            try secureIO.restore(item.before)
            try saveHistory(nextHistory)
        } catch {
            try compensateUndoIfNeeded(
                mutationAttempted: mutationAttempted,
                snapshots: compensation,
                secureIO: secureIO,
                originalError: error
            )
        }
        history = nextHistory
        historyStorageBytes = max(0, historyStorageBytes - item.storageBytes)
        persistenceLoadError = nil
        return item.record
    }

    private func saveHistory(_ entries: [HistoryEntry]) throws {
        do {
            try historySaveHook?()
            try persistence?.save(
                entries,
                maximumBytes: Self.persistenceWireLimit(historyBytes: maximumHistoryBytes)
            )
        } catch {
            throw ChangeManagerError.persistentHistoryUnavailable(error.localizedDescription)
        }
    }

    private func verifyCurrentState(
        of item: HistoryEntry,
        secureIO: SecureWorkspaceIO
    ) throws {
        _ = try verifiedCurrentSnapshots(of: item, secureIO: secureIO)
    }

    private func verifiedCurrentSnapshots(
        of item: HistoryEntry,
        secureIO: SecureWorkspaceIO
    ) throws -> [SecurePathSnapshot] {
        let snapshots = try snapshotCurrentState(
            paths: item.record.paths,
            maximumBytes: maximumSnapshotBytes,
            secureIO: secureIO,
            conflictPaths: item.record.paths
        )
        guard snapshots.map(Self.fingerprint) == item.afterFingerprints else {
            throw ChangeManagerError.undoConflict(item.record.paths)
        }
        return snapshots
    }

    private func snapshotCurrentState(
        paths: [String],
        maximumBytes: Int,
        secureIO: SecureWorkspaceIO,
        conflictPaths: [String]
    ) throws -> [SecurePathSnapshot] {
        var remainingBytes = max(1, maximumBytes)
        var current: [SecurePathSnapshot] = []
        do {
            for path in paths {
                let snapshot = try secureIO.snapshot(
                    path: path,
                    maximumBytes: remainingBytes,
                    honorCancellation: false
                )
                remainingBytes -= snapshot.entries.reduce(into: 0) { total, entry in
                    if case .file(let data) = entry.kind { total += data.count }
                }
                current.append(snapshot)
            }
        } catch {
            throw ChangeManagerError.undoConflict(conflictPaths)
        }
        return current
    }

    private func compensateUndoIfNeeded(
        mutationAttempted: Bool,
        snapshots: [SecurePathSnapshot],
        secureIO: SecureWorkspaceIO,
        originalError: Error
    ) throws -> Never {
        guard mutationAttempted else { throw originalError }
        do {
            try secureIO.restore(snapshots)
        } catch {
            throw ChangeManagerError.persistentHistoryUnavailable(
                "Undo failed (\(originalError.localizedDescription)); restoring the pre-Undo workspace also failed (\(error.localizedDescription))."
            )
        }
        throw originalError
    }

    private static func fingerprint(_ snapshot: SecurePathSnapshot) -> SecureSnapshotFingerprint {
        SecureSnapshotFingerprint(
            requestedPath: snapshot.requestedPath,
            existed: snapshot.existed,
            entries: snapshot.entries.map { entry in
                let kind: SecureSnapshotEntryFingerprint.Kind
                switch entry.kind {
                case .directory:
                    kind = .directory
                case .file(let data):
                    kind = .file(
                        byteCount: data.count,
                        sha256: Data(SHA256.hash(data: data))
                    )
                }
                return SecureSnapshotEntryFingerprint(
                    relativePath: entry.relativePath,
                    permissions: entry.permissions,
                    kind: kind
                )
            }
            .sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        )
    }

    private func flattenedFiles(_ snapshot: SecurePathSnapshot) -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in snapshot.entries {
            if case .file(let data) = entry.kind { result[entry.relativePath] = data }
        }
        return result
    }

}
