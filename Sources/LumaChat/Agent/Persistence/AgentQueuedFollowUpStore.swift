import Darwin
import Foundation

enum AgentQueuedFollowUpError: LocalizedError, Equatable, Sendable {
    case invalidPrompt
    case capacityExceeded
    case corruptQueue
    case staleClaim

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: "排隊訊息必須有文字，且不得超過 16 KiB。"
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
        let file = queueFile(sessionID: sessionID)
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return [] }
            throw AgentQueuedFollowUpError.corruptQueue
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumFileBytes else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AgentQueuedFollowUpError.corruptQueue }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else {
                throw AgentQueuedFollowUpError.corruptQueue
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let entries = try? JSONDecoder().decode([AgentQueuedFollowUp].self, from: data) else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        try validate(entries)
        return entries
    }

    func enqueue(_ entry: AgentQueuedFollowUp, sessionID: UUID) throws -> [AgentQueuedFollowUp] {
        guard entry.claimID == nil else { throw AgentQueuedFollowUpError.staleClaim }
        var entries = try load(sessionID: sessionID)
        guard entries.count < Self.maximumEntries else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        entries.append(entry)
        do {
            try save(entries, sessionID: sessionID)
        } catch {
            if let durable = try? load(sessionID: sessionID),
               durable.contains(where: { $0.id == entry.id && $0 == entry }) {
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
            if let durable = try? load(sessionID: sessionID), durable.first == claimed {
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
               !durable.contains(where: { $0.id == id }) {
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
        var entries = try load(sessionID: sessionID)
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].claimID == nil else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        entries[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func queueFile(sessionID: UUID) -> URL {
        sessionsRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("queued-followups.json", isDirectory: false)
    }

    private func save(_ entries: [AgentQueuedFollowUp], sessionID: UUID) throws {
        try validate(entries)
        let directory = queueFile(sessionID: sessionID).deletingLastPathComponent()
        var metadata = Darwin.stat()
        guard Darwin.lstat(directory.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumFileBytes else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        try AtomicFileWriter.write(data, to: queueFile(sessionID: sessionID))
    }

    private func saveReconciled(
        _ entries: [AgentQueuedFollowUp],
        sessionID: UUID
    ) throws -> [AgentQueuedFollowUp] {
        do {
            try save(entries, sessionID: sessionID)
            return entries
        } catch {
            if let durable = try? load(sessionID: sessionID), durable == entries {
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
                  !text.isEmpty,
                  text.utf8.count <= Self.maximumPromptBytes else {
                throw AgentQueuedFollowUpError.invalidPrompt
            }
            try AgentImageAttachmentLimits.validate(entry.imageAttachments)
        }
    }
}
