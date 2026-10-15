import Darwin
import Foundation

enum AgentQueuedFollowUpError: LocalizedError, Equatable, Sendable {
    case invalidPrompt
    case capacityExceeded
    case corruptQueue
    case staleClaim

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: "排隊訊息需要文字或影像，文字不得超過 16 KiB。"
        case .capacityExceeded: "每個 Task 最多排隊 8 則訊息。"
        case .corruptQueue: "排隊訊息檔案無法安全讀取；請檢查 Task 資料。"
        case .staleClaim: "排隊訊息的執行狀態已變更；請重新整理。"
        }
    }
}

struct AgentQueuedFollowUp: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var imageAttachments: [AgentImageAttachmentReference]
    var queuedAt: Date
    /// A claimed entry is never replayed automatically after a crash. The
    /// prior run may have persisted its user message before the process died.
    var claimID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        imageAttachments: [AgentImageAttachmentReference] = [],
        queuedAt: Date = Date(),
        claimID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.imageAttachments = imageAttachments
        self.queuedAt = queuedAt
        self.claimID = claimID
    }
}

protocol AgentQueuedFollowUpPersisting: Sendable {
    func load(sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func enqueue(_ entry: AgentQueuedFollowUp, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func claimNext(sessionID: UUID) async throws -> AgentQueuedFollowUp?
    func acknowledge(id: UUID, claimID: UUID, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func release(id: UUID, claimID: UUID, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func removeQueued(id: UUID, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func updateQueued(id: UUID, text: String, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func updateQueued(id: UUID, text: String, imageAttachments: [AgentImageAttachmentReference], sessionID: UUID) async throws -> [AgentQueuedFollowUp]
    func moveQueued(id: UUID, by offset: Int, sessionID: UUID) async throws -> [AgentQueuedFollowUp]
}

/// Queue state lives beside, but outside, session.json. Runtime snapshots can
/// therefore be saved while a new follow-up is enqueued without overwriting it.
actor AgentQueuedFollowUpStore: AgentQueuedFollowUpPersisting {
    static let maximumEntries = 8
    static let maximumPromptBytes = 16 * 1_024
    static let maximumFileBytes = 256 * 1_024

    private let sessionsRoot: URL

    init(sessionsRoot: URL = AppPaths.agentSessions) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
    }

    func load(sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        guard let data = try AgentInteractionFileIO.read(
            sessionsRoot: sessionsRoot, sessionID: sessionID,
            name: "queued-followups.json", maximumBytes: Self.maximumFileBytes
        ) else { return [] }
        guard let decoded = try? JSONDecoder().decode([AgentQueuedFollowUp].self, from: data) else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        try validate(decoded)
        let entries = decoded.map(Self.redacted)
        try validate(entries)
        // Older queues may contain the original draft. Remove secrets before
        // returning or replaying their content, preserving any uncertain claim.
        if entries != decoded { try save(entries, sessionID: sessionID) }
        return entries
    }

    func enqueue(_ entry: AgentQueuedFollowUp, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        guard entry.claimID == nil else { throw AgentQueuedFollowUpError.staleClaim }
        try validate([entry])
        let entry = Self.redacted(entry)
        var entries = try load(sessionID: sessionID)
        guard entries.count < Self.maximumEntries else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        entries.append(entry)
        do {
            try save(entries, sessionID: sessionID)
        } catch {
            if let durable = try? load(sessionID: sessionID),
               durable.contains(where: { $0.id == entry.id && $0 == entry }),
               (try? AgentInteractionFileIO.synchronize(sessionsRoot: sessionsRoot, sessionID: sessionID)) != nil {
                return durable
            }
            throw error
        }
        return entries
    }

    func claimNext(sessionID: UUID) throws -> AgentQueuedFollowUp? {
        var entries = try load(sessionID: sessionID)
        guard !entries.isEmpty, entries[0].claimID == nil else { return nil }
        entries[0].claimID = UUID()
        let claimed = entries[0]
        do {
            try save(entries, sessionID: sessionID)
        } catch {
            if let durable = try? load(sessionID: sessionID), durable.first == claimed,
               (try? AgentInteractionFileIO.synchronize(sessionsRoot: sessionsRoot, sessionID: sessionID)) != nil {
                return claimed
            }
            throw error
        }
        return claimed
    }

    func acknowledge(
        id: UUID,
        claimID: UUID,
        sessionID: UUID
    ) throws -> [AgentQueuedFollowUp] {
        var entries = try load(sessionID: sessionID)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == claimID else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries.remove(at: index)
        do {
            try save(entries, sessionID: sessionID)
        } catch {
            if let durable = try? load(sessionID: sessionID),
               !durable.contains(where: { $0.id == id }),
               (try? AgentInteractionFileIO.synchronize(sessionsRoot: sessionsRoot, sessionID: sessionID)) != nil {
                return durable
            }
            throw error
        }
        return entries
    }

    func release(id: UUID, claimID: UUID, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        var entries = try load(sessionID: sessionID)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == claimID else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries[index].claimID = nil
        return try saveReconciled(entries, sessionID: sessionID)
    }

    func removeQueued(id: UUID, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        var entries = try load(sessionID: sessionID)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == nil else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries.remove(at: index)
        return try saveReconciled(entries, sessionID: sessionID)
    }

    func updateQueued(id: UUID, text: String, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        let entries = try load(sessionID: sessionID)
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        return try updateQueued(id: id, text: text, imageAttachments: entry.imageAttachments, sessionID: sessionID)
    }

    func updateQueued(
        id: UUID,
        text: String,
        imageAttachments: [AgentImageAttachmentReference],
        sessionID: UUID
    ) throws -> [AgentQueuedFollowUp] {
        var entries = try load(sessionID: sessionID)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == nil else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries[index].text = text
        entries[index].imageAttachments = imageAttachments
        try validate(entries)
        entries[index] = Self.redacted(entries[index])
        return try saveReconciled(entries, sessionID: sessionID)
    }

    func moveQueued(id: UUID, by offset: Int, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        var entries = try load(sessionID: sessionID)
        guard (offset == -1 || offset == 1),
              let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == nil,
              entries.indices.contains(index + offset),
              entries[index + offset].claimID == nil else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries.swapAt(index, index + offset)
        return try saveReconciled(entries, sessionID: sessionID)
    }

    private func save(_ entries: [AgentQueuedFollowUp], sessionID: UUID) throws {
        try validate(entries)
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumFileBytes else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        try AgentInteractionFileIO.write(
            data, sessionsRoot: sessionsRoot, sessionID: sessionID,
            name: "queued-followups.json"
        )
    }

    private func saveReconciled(
        _ entries: [AgentQueuedFollowUp],
        sessionID: UUID
    ) throws -> [AgentQueuedFollowUp] {
        do {
            try save(entries, sessionID: sessionID)
            return entries
        } catch {
            if let durable = try? load(sessionID: sessionID), durable == entries,
               (try? AgentInteractionFileIO.synchronize(sessionsRoot: sessionsRoot, sessionID: sessionID)) != nil {
                return durable
            }
            throw error
        }
    }

    private func validate(_ entries: [AgentQueuedFollowUp]) throws {
        guard entries.count <= Self.maximumEntries else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        var identifiers = Set<UUID>()
        for entry in entries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard identifiers.insert(entry.id).inserted,
                  (!text.isEmpty || !entry.imageAttachments.isEmpty),
                  entry.text.utf8.count <= Self.maximumPromptBytes,
                  !entry.text.contains("\0") else {
                throw AgentQueuedFollowUpError.invalidPrompt
            }
            try AgentImageAttachmentLimits.validate(entry.imageAttachments)
        }
    }

    private static func redacted(_ entry: AgentQueuedFollowUp) -> AgentQueuedFollowUp {
        var entry = entry
        entry.text = SecretRedactor().redact(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
        return entry
    }
}

/// Queue and Steer must never follow a substituted Task directory. Keep each
/// operation anchored to a directory descriptor, reject special/hard-linked
/// files, and bound reads before decoding private interaction state.
enum AgentInteractionFileIO {
    /// Create private state directories without following any ancestor link.
    /// mkdirat/openat keep a concurrently renamed ancestor from redirecting us.
    static func ensureDirectory(_ url: URL) throws {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentQueuedFollowUpError.corruptQueue }
        defer { _ = Darwin.close(descriptor) }
        for component in url.standardizedFileURL.path.split(separator: "/") {
            let name = String(component)
            if Darwin.mkdirat(descriptor, name, mode_t(0o700)) != 0, errno != EEXIST {
                throw AgentQueuedFollowUpError.corruptQueue
            }
            let child = Darwin.openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw AgentQueuedFollowUpError.corruptQueue }
            _ = Darwin.close(descriptor)
            descriptor = child
        }
    }

    static func read(
        sessionsRoot: URL, sessionID: UUID, name: String, maximumBytes: Int
    ) throws -> Data? {
        guard let directory = try openSession(sessionsRoot: sessionsRoot, sessionID: sessionID,
                                              allowMissing: true) else { return nil }
        defer { _ = Darwin.close(directory) }
        let file = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw AgentQueuedFollowUpError.corruptQueue
        }
        defer { _ = Darwin.close(file) }
        var before = Darwin.stat()
        guard Darwin.fstat(file, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= maximumBytes - data.count else {
                throw AgentQueuedFollowUpError.corruptQueue
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = Darwin.stat()
        var named = Darwin.stat()
        guard Darwin.fstat(file, &after) == 0,
              Darwin.fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, after), sameFile(before, named), data.count == before.st_size else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        return data
    }

    static func write(_ data: Data, sessionsRoot: URL, sessionID: UUID, name: String) throws {
        guard let directory = try openSession(sessionsRoot: sessionsRoot, sessionID: sessionID,
                                              allowMissing: false) else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        defer { _ = Darwin.close(directory) }
        try validateDestination(directory: directory, name: name)
        let temporaryName = ".interaction-\(UUID().uuidString).tmp"
        let file = Darwin.openat(directory, temporaryName,
                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw AgentQueuedFollowUpError.corruptQueue }
        defer {
            _ = Darwin.close(file)
            _ = Darwin.unlinkat(directory, temporaryName, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AgentQueuedFollowUpError.corruptQueue }
                offset += count
            }
        }
        guard Darwin.fsync(file) == 0 else { throw AgentQueuedFollowUpError.corruptQueue }
        try validateDestination(directory: directory, name: name)
        guard Darwin.renameat(directory, temporaryName, directory, name) == 0,
              Darwin.fsync(directory) == 0 else { throw AgentQueuedFollowUpError.corruptQueue }
    }

    static func synchronize(sessionsRoot: URL, sessionID: UUID) throws {
        guard let directory = try openSession(sessionsRoot: sessionsRoot, sessionID: sessionID,
                                              allowMissing: false) else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        defer { _ = Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else { throw AgentQueuedFollowUpError.corruptQueue }
    }

    private static func openSession(
        sessionsRoot: URL, sessionID: UUID, allowMissing: Bool
    ) throws -> Int32? {
        let root = Darwin.open(sessionsRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if root < 0 {
            if allowMissing, errno == ENOENT { return nil }
            throw AgentQueuedFollowUpError.corruptQueue
        }
        defer { _ = Darwin.close(root) }
        let directory = Darwin.openat(root, sessionID.uuidString,
                                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            if allowMissing, errno == ENOENT { return nil }
            throw AgentQueuedFollowUpError.corruptQueue
        }
        return directory
    }

    private static func validateDestination(directory: Int32, name: String) throws {
        var info = Darwin.stat()
        if Darwin.fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) < 0 {
            if errno == ENOENT { return }
            throw AgentQueuedFollowUpError.corruptQueue
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
    }

    private static func sameFile(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT && rhs.st_nlink == 1
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
