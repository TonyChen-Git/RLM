import Darwin
import Foundation

struct AgentTaskDeletionJournalEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sessionID: UUID
    var binding: AgentTaskBindingSnapshot
    var worktreeID: UUID
    var lease: WorktreeLease
    var startedAt: Date
}

enum AgentTaskDeletionJournalError: LocalizedError, Equatable {
    case invalidEntry(String)
    case oversized(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEntry(let detail):
            return "Task deletion journal is invalid: \(detail)"
        case .oversized(let maximum):
            return "Task deletion journal exceeds \(maximum) bytes."
        }
    }
}

/// Durable intent for the only external resource retained by Task deletion: a
/// managed checkout lease. The checkout itself is never deleted here because
/// it may contain user work; recovery merely releases the exact lease after it
/// can prove the Session directory is durably absent.
actor AgentTaskDeletionJournal {
    static let maximumEntryBytes = 1 * 1_024 * 1_024
    static let maximumEntries = 256

    private let fileManager: FileManager
    private let root: URL

    init(
        fileManager: FileManager = .default,
        root: URL = AppPaths.appSupport.appendingPathComponent(
            "AgentDeletions",
            isDirectory: true
        )
    ) {
        self.fileManager = fileManager
        self.root = root.standardizedFileURL
    }

    func begin(
        session: AgentSession,
        worktreeID: UUID,
        lease: WorktreeLease,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> AgentTaskDeletionJournalEntry {
        guard let workspace = session.workspace,
              session.resolvedExecutionLocation.kind == .worktree,
              session.resolvedExecutionLocation.managedWorktreeID == worktreeID,
              lease.worktreeID == worktreeID,
              lease.taskID == session.id else {
            throw AgentTaskDeletionJournalError.invalidEntry(
                "Session binding and lease do not match"
            )
        }
        let entry = AgentTaskDeletionJournalEntry(
            id: id,
            sessionID: session.id,
            binding: AgentTaskBindingSnapshot(
                workspace: workspace,
                location: session.resolvedExecutionLocation,
                projectFolderID: session.projectFolderID,
                localWorkspace: session.localWorkspace,
                localProjectFolderID: session.localProjectFolderID
            ),
            worktreeID: worktreeID,
            lease: lease,
            startedAt: now
        )
        try save(entry)
        return entry
    }

    func pendingEntries() throws -> [AgentTaskDeletionJournalEntry] {
        try ensureRoot()
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { $0.pathExtension == "json" }
        guard urls.count <= Self.maximumEntries else {
            throw AgentTaskDeletionJournalError.invalidEntry("entry count exceeds limit")
        }
        var entries: [AgentTaskDeletionJournalEntry] = []
        for url in urls {
            guard let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size <= Self.maximumEntryBytes else {
                throw AgentTaskDeletionJournalError.invalidEntry("entry is not a bounded regular file")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Self.maximumEntryBytes else {
                throw AgentTaskDeletionJournalError.oversized(Self.maximumEntryBytes)
            }
            let entry = try JSONDecoder().decode(AgentTaskDeletionJournalEntry.self, from: data)
            guard entry.id == fileID else {
                throw AgentTaskDeletionJournalError.invalidEntry("filename and transaction ID differ")
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
            throw AgentTaskDeletionJournalError.invalidEntry("entry path escaped journal root")
        }
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    private func save(_ entry: AgentTaskDeletionJournalEntry) throws {
        try Self.validate(entry)
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(entry)
        guard data.count <= Self.maximumEntryBytes else {
            throw AgentTaskDeletionJournalError.oversized(Self.maximumEntryBytes)
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
            throw AgentTaskDeletionJournalError.invalidEntry("journal root escaped allowed storage")
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = Darwin.stat()
        guard Darwin.lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw AgentTaskDeletionJournalError.invalidEntry(
                "allowed journal storage is not a directory"
            )
        }
        let suffix = String(root.path.dropFirst(parent.path.count + 1))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentTaskDeletionJournalError.invalidEntry("journal root path is malformed")
        }
        var cursor = parent
        for component in components {
            cursor.appendPathComponent(String(component), isDirectory: true)
            var info = Darwin.stat()
            if Darwin.lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw AgentTaskDeletionJournalError.invalidEntry(
                        "journal root contains a link or non-directory component"
                    )
                }
            } else {
                guard errno == ENOENT,
                      Darwin.mkdir(cursor.path, mode_t(0o700)) == 0 || errno == EEXIST,
                      Darwin.lstat(cursor.path, &info) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else {
                    throw AgentTaskDeletionJournalError.invalidEntry(
                        "journal root could not be created safely"
                    )
                }
            }
        }
    }

    private func entryFile(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private static func validate(_ entry: AgentTaskDeletionJournalEntry) throws {
        guard entry.binding.location.kind == .worktree,
              entry.binding.location.managedWorktreeID == entry.worktreeID,
              entry.lease.worktreeID == entry.worktreeID,
              entry.lease.taskID == entry.sessionID,
              !entry.binding.workspace.rootPath.isEmpty,
              entry.binding.workspace.rootPath.hasPrefix("/"),
              entry.binding.workspace.rootPath != "/",
              entry.binding.workspace.allowedPaths.isEmpty,
              entry.startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw AgentTaskDeletionJournalError.invalidEntry("binding or lease is invalid")
        }
        try ManagedWorktreeValidation.validate(lease: entry.lease, expectedWorktreeID: entry.worktreeID)
    }
}
