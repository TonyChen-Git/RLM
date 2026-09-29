import Darwin
import Foundation

enum AgentLocalMemoryError: LocalizedError, Equatable, Sendable {
    case disabled
    case invalidText
    case capacityExceeded
    case notFound
    case corruptStore
    case unsafeStorage
    case durabilityUncertain

    var errorDescription: String? {
        switch self {
        case .disabled: "請先啟用此專案的本機記憶。"
        case .invalidText: "記憶內容為空白、包含 NUL，或超過長度上限。"
        case .capacityExceeded: "此專案的本機記憶已達容量上限。"
        case .notFound: "找不到此筆本機記憶或其審核狀態已變更。"
        case .corruptStore: "本機記憶檔案損毀；已停止讀寫，避免覆蓋原始資料。"
        case .unsafeStorage: "本機記憶儲存路徑不是安全的目錄或一般檔案。"
        case .durabilityUncertain: "本機記憶可能已寫入，但磁碟同步結果無法確認；請重新載入。"
        }
    }
}

enum AgentLocalMemoryStatus: String, Codable, Sendable {
    case proposed
    case approved
}

struct AgentLocalMemoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var status: AgentLocalMemoryStatus
    var createdAt: Date
    var updatedAt: Date
}

struct AgentLocalMemorySnapshot: Equatable, Sendable {
    var enabled: Bool = false
    var entries: [AgentLocalMemoryEntry] = []
}

/// Private, project-scoped memory storage. A new project starts disabled, and
/// proposed text never reaches approvedForContext until a separate approval.
/// Callers are responsible for the global and per-Task use/generation switches.
actor AgentLocalMemoryStore {
    static let maximumEntries = 128
    static let maximumTextBytes = 4 * 1_024
    static let maximumFileBytes = 512 * 1_024
    static let maximumContextEntries = 16
    static let maximumContextBytes = 16 * 1_024

    private struct Document: Codable {
        var version: Int
        var projectID: UUID
        var enabled: Bool
        var entries: [AgentLocalMemoryEntry]
    }

    private let storageRoot: URL
    private let redactor = SecretRedactor()
    private static let fileName = "memories.json"

    init(storageRoot: URL = AppPaths.appSupport.appendingPathComponent(
        "AgentMemories", isDirectory: true
    )) {
        self.storageRoot = storageRoot.standardizedFileURL
    }

    func load(projectID: UUID) throws -> AgentLocalMemorySnapshot {
        guard let root = try openRoot(createIfMissing: false) else {
            return AgentLocalMemorySnapshot()
        }
        defer { _ = Darwin.close(root) }
        guard let project = try openProject(below: root, id: projectID, createIfMissing: false) else {
            return AgentLocalMemorySnapshot()
        }
        defer { _ = Darwin.close(project) }
        let file = Self.withName(Self.fileName) {
            Darwin.openat(project, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        if file < 0 {
            if errno == ENOENT { return AgentLocalMemorySnapshot() }
            throw AgentLocalMemoryError.unsafeStorage
        }
        defer { _ = Darwin.close(file) }
        var info = Darwin.stat()
        guard Darwin.fstat(file, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= Self.maximumFileBytes else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        var data = Data(count: Int(info.st_size))
        let expectedCount = data.count
        var offset = 0
        while offset < expectedCount {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(file, base.advanced(by: offset), expectedCount - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AgentLocalMemoryError.corruptStore }
            offset += count
        }
        var extra: UInt8 = 0
        guard Darwin.read(file, &extra, 1) == 0 else {
            throw AgentLocalMemoryError.corruptStore
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1,
              document.projectID == projectID else {
            throw AgentLocalMemoryError.corruptStore
        }
        let snapshot = AgentLocalMemorySnapshot(
            enabled: document.enabled,
            entries: document.entries
        )
        try validate(snapshot)
        return snapshot
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, projectID: UUID) throws -> AgentLocalMemorySnapshot {
        var snapshot = try load(projectID: projectID)
        if snapshot.enabled == enabled { return snapshot }
        snapshot.enabled = enabled
        try saveReconciled(snapshot, projectID: projectID)
        return snapshot
    }

    @discardableResult
    func propose(_ text: String, projectID: UUID) throws -> AgentLocalMemoryEntry {
        var snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { throw AgentLocalMemoryError.disabled }
        guard snapshot.entries.count < Self.maximumEntries else {
            throw AgentLocalMemoryError.capacityExceeded
        }
        let clean = try sanitizedText(text)
        let now = Date()
        let entry = AgentLocalMemoryEntry(
            id: UUID(), text: clean, status: .proposed,
            createdAt: now, updatedAt: now
        )
        snapshot.entries.append(entry)
        try saveReconciled(snapshot, projectID: projectID)
        return entry
    }

    @discardableResult
    func approve(id: UUID, projectID: UUID) throws -> AgentLocalMemoryEntry {
        var snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { throw AgentLocalMemoryError.disabled }
        guard let index = snapshot.entries.firstIndex(where: {
            $0.id == id && $0.status == .proposed
        }) else { throw AgentLocalMemoryError.notFound }
        snapshot.entries[index].status = .approved
        snapshot.entries[index].updatedAt = Date()
        try saveReconciled(snapshot, projectID: projectID)
        return snapshot.entries[index]
    }

    /// Editing an approved memory returns it to review before it can be used.
    @discardableResult
    func update(id: UUID, text: String, projectID: UUID) throws -> AgentLocalMemoryEntry {
        var snapshot = try load(projectID: projectID)
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else {
            throw AgentLocalMemoryError.notFound
        }
        snapshot.entries[index].text = try sanitizedText(text)
        snapshot.entries[index].status = .proposed
        snapshot.entries[index].updatedAt = Date()
        try saveReconciled(snapshot, projectID: projectID)
        return snapshot.entries[index]
    }

    @discardableResult
    func remove(id: UUID, projectID: UUID) throws -> AgentLocalMemorySnapshot {
        var snapshot = try load(projectID: projectID)
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else {
            throw AgentLocalMemoryError.notFound
        }
        snapshot.entries.remove(at: index)
        try saveReconciled(snapshot, projectID: projectID)
        return snapshot
    }

    /// Clears entries while preserving the project's opt-in preference.
    @discardableResult
    func clear(projectID: UUID) throws -> AgentLocalMemorySnapshot {
        var snapshot = try load(projectID: projectID)
        if snapshot.entries.isEmpty { return snapshot }
        snapshot.entries.removeAll()
        try saveReconciled(snapshot, projectID: projectID)
        return snapshot
    }

    /// Removes private data when its Project catalog record is deleted. This
    /// does not decode the document, so a corrupt but safe regular file can
    /// still be removed. Unknown files in the directory are left untouched.
    func delete(projectID: UUID) throws {
        guard let root = try openRoot(createIfMissing: false) else { return }
        defer { _ = Darwin.close(root) }
        guard let project = try openProject(below: root, id: projectID, createIfMissing: false)
        else { return }
        defer { _ = Darwin.close(project) }
        var info = Darwin.stat()
        let status = Self.withName(Self.fileName) {
            Darwin.fstatat(project, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if status < 0 {
            if errno == ENOENT { return }
            throw AgentLocalMemoryError.unsafeStorage
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        let removed = Self.withName(Self.fileName) {
            Darwin.unlinkat(project, $0, 0)
        }
        guard removed == 0 else { throw AgentLocalMemoryError.unsafeStorage }
        guard Darwin.fsync(project) == 0 else {
            throw AgentLocalMemoryError.durabilityUncertain
        }
    }

    /// Returns a small, oldest-first slice of the most recent approved items.
    /// The caller must also check global and per-Task memory-use preferences.
    func approvedForContext(projectID: UUID) throws -> [AgentLocalMemoryEntry] {
        let snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { return [] }
        var selected: [AgentLocalMemoryEntry] = []
        var bytes = 0
        for entry in snapshot.entries.reversed() where entry.status == .approved {
            let count = entry.text.utf8.count
            if selected.count >= Self.maximumContextEntries { break }
            if bytes + count > Self.maximumContextBytes { continue }
            selected.append(entry)
            bytes += count
        }
        return selected.reversed()
    }

    private func sanitizedText(_ value: String) throws -> String {
        let clean = redactor.redact(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty,
              !clean.contains("\0"),
              clean.utf8.count <= Self.maximumTextBytes else {
            throw AgentLocalMemoryError.invalidText
        }
        return clean
    }

    private func validate(_ snapshot: AgentLocalMemorySnapshot) throws {
        guard snapshot.entries.count <= Self.maximumEntries else {
            throw AgentLocalMemoryError.capacityExceeded
        }
        var IDs = Set<UUID>()
        for entry in snapshot.entries {
            let sanitized = try? sanitizedText(entry.text)
            guard IDs.insert(entry.id).inserted,
                  entry.text == sanitized else {
                throw AgentLocalMemoryError.corruptStore
            }
        }
    }

    private func saveReconciled(_ snapshot: AgentLocalMemorySnapshot, projectID: UUID) throws {
        do {
            try save(snapshot, projectID: projectID)
        } catch {
            // A write can report failure after rename. An exact reload plus a
            // successful directory sync establishes the intended durable state.
            if let onDisk = try? load(projectID: projectID), onDisk == snapshot,
               (try? syncProjectDirectory(projectID: projectID)) != nil {
                return
            }
            throw error
        }
    }

    private func save(_ snapshot: AgentLocalMemorySnapshot, projectID: UUID) throws {
        try validate(snapshot)
        let document = Document(
            version: 1, projectID: projectID,
            enabled: snapshot.enabled, entries: snapshot.entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw AgentLocalMemoryError.capacityExceeded
        }
        guard let root = try openRoot(createIfMissing: true) else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        defer { _ = Darwin.close(root) }
        guard let project = try openProject(below: root, id: projectID, createIfMissing: true) else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        defer { _ = Darwin.close(project) }
        try validateDestination(below: project)

        let temporaryName = ".memories-\(UUID().uuidString.lowercased()).tmp"
        let temporary = Self.withName(temporaryName) {
            Darwin.openat(
                project, $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard temporary >= 0 else { throw AgentLocalMemoryError.unsafeStorage }
        var temporaryOpen = true
        var temporaryExists = true
        defer {
            if temporaryOpen { _ = Darwin.close(temporary) }
            if temporaryExists {
                _ = Self.withName(temporaryName) { Darwin.unlinkat(project, $0, 0) }
            }
        }
        var offset = 0
        let dataCount = data.count
        while offset < dataCount {
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.write(temporary, base.advanced(by: offset), dataCount - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AgentLocalMemoryError.unsafeStorage }
            offset += count
        }
        guard Darwin.fchmod(temporary, mode_t(0o600)) == 0,
              Darwin.fsync(temporary) == 0,
              Darwin.close(temporary) == 0 else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        temporaryOpen = false
        try validateDestination(below: project)
        let renamed = Self.withNames(temporaryName, Self.fileName) {
            Darwin.renameat(project, $0, project, $1)
        }
        guard renamed == 0 else { throw AgentLocalMemoryError.unsafeStorage }
        temporaryExists = false
        guard Darwin.fsync(project) == 0 else {
            throw AgentLocalMemoryError.durabilityUncertain
        }
    }

    private func syncProjectDirectory(projectID: UUID) throws {
        guard let root = try openRoot(createIfMissing: false) else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        defer { _ = Darwin.close(root) }
        guard let project = try openProject(below: root, id: projectID, createIfMissing: false) else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        defer { _ = Darwin.close(project) }
        guard Darwin.fsync(project) == 0 else {
            throw AgentLocalMemoryError.durabilityUncertain
        }
    }

    private func validateDestination(below project: Int32) throws {
        var info = Darwin.stat()
        let result = Self.withName(Self.fileName) {
            Darwin.fstatat(project, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if result < 0 {
            if errno == ENOENT { return }
            throw AgentLocalMemoryError.unsafeStorage
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            throw AgentLocalMemoryError.unsafeStorage
        }
    }

    private func openRoot(createIfMissing: Bool) throws -> Int32? {
        guard storageRoot.isFileURL,
              storageRoot.path.hasPrefix("/"),
              storageRoot.path != "/",
              !storageRoot.path.contains("\0") else {
            throw AgentLocalMemoryError.unsafeStorage
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentLocalMemoryError.unsafeStorage }
        for part in storageRoot.pathComponents.dropFirst() {
            if createIfMissing {
                let result = Self.withName(part) {
                    Darwin.mkdirat(descriptor, $0, mode_t(0o700))
                }
                if result != 0, errno != EEXIST {
                    _ = Darwin.close(descriptor)
                    throw AgentLocalMemoryError.unsafeStorage
                }
            }
            let next = Self.withName(part) {
                Darwin.openat(
                    descriptor, $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            let openError = errno
            _ = Darwin.close(descriptor)
            if next < 0 {
                if openError == ENOENT, !createIfMissing { return nil }
                throw AgentLocalMemoryError.unsafeStorage
            }
            descriptor = next
        }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == Darwin.geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            _ = Darwin.close(descriptor)
            throw AgentLocalMemoryError.unsafeStorage
        }
        return descriptor
    }

    private func openProject(
        below root: Int32,
        id: UUID,
        createIfMissing: Bool
    ) throws -> Int32? {
        let name = id.uuidString.lowercased()
        if createIfMissing {
            let result = Self.withName(name) { Darwin.mkdirat(root, $0, mode_t(0o700)) }
            if result != 0, errno != EEXIST { throw AgentLocalMemoryError.unsafeStorage }
        }
        let descriptor = Self.withName(name) {
            Darwin.openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT, !createIfMissing { return nil }
            throw AgentLocalMemoryError.unsafeStorage
        }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == Darwin.geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            _ = Darwin.close(descriptor)
            throw AgentLocalMemoryError.unsafeStorage
        }
        return descriptor
    }

    private static func withName<T>(_ name: String, _ body: (UnsafePointer<CChar>) -> T) -> T {
        name.withCString(body)
    }

    private static func withNames<T>(
        _ first: String,
        _ second: String,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> T
    ) -> T {
        first.withCString { firstName in
            second.withCString { secondName in body(firstName, secondName) }
        }
    }
}
