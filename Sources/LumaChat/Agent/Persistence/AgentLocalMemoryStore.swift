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

enum AgentLocalMemoryCategory: String, Codable, CaseIterable, Sendable {
    case preference
    case projectFact
    case workflow
    case other

    var title: String {
        switch self {
        case .preference: "偏好"
        case .projectFact: "專案事實"
        case .workflow: "工作流程"
        case .other: "其他"
        }
    }
}

enum AgentLocalMemorySort: String, CaseIterable, Sendable {
    case relevance
    case recent

    var title: String {
        switch self {
        case .relevance: "相關"
        case .recent: "最近"
        }
    }
}

struct AgentLocalMemorySource: Codable, Equatable, Sendable {
    var taskID: UUID
    var messageID: UUID
    var taskTitle: String
    var excerpt: String
}

struct AgentLocalMemoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var status: AgentLocalMemoryStatus
    var createdAt: Date
    var updatedAt: Date
    var category: AgentLocalMemoryCategory? = nil
    var source: AgentLocalMemorySource? = nil
}

struct AgentLocalMemorySnapshot: Equatable, Sendable {
    var enabled: Bool = false
    var entries: [AgentLocalMemoryEntry] = []
    /// Tombstones prevent a deleted or cleared suggestion from reappearing on
    /// restart. They are stored in the same atomic project document.
    var processedSourceIDs: [UUID] = []
}

struct AgentLocalMemorySearchResult: Identifiable, Sendable {
    var projectID: UUID
    var projectName: String
    var entry: AgentLocalMemoryEntry
    var id: UUID { entry.id }
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
    static let maximumProcessedSources = 4_096
    static let maximumContextEntriesPerCategory = 6

    private struct Document: Codable {
        var version: Int
        var projectID: UUID
        var enabled: Bool
        var entries: [AgentLocalMemoryEntry]
        var processedSourceIDs: [UUID]?
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
            entries: document.entries,
            processedSourceIDs: document.processedSourceIDs ?? []
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
    func propose(
        _ text: String, category: AgentLocalMemoryCategory = .other,
        projectID: UUID
    ) throws -> AgentLocalMemoryEntry {
        var snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { throw AgentLocalMemoryError.disabled }
        guard snapshot.entries.count < Self.maximumEntries else {
            throw AgentLocalMemoryError.capacityExceeded
        }
        let clean = try sanitizedText(text)
        let now = Date()
        let entry = AgentLocalMemoryEntry(
            id: UUID(), text: clean, status: .proposed,
            createdAt: now, updatedAt: now, category: category
        )
        snapshot.entries.append(entry)
        try saveReconciled(snapshot, projectID: projectID)
        return entry
    }

    /// Idempotent suggestion commit. Source acknowledgement and entry are
    /// written together; deletion/clear retain the acknowledgement.
    @discardableResult
    func suggest(
        _ text: String,
        category: AgentLocalMemoryCategory,
        source: AgentLocalMemorySource,
        projectID: UUID
    ) throws -> AgentLocalMemoryEntry? {
        var snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { throw AgentLocalMemoryError.disabled }
        guard !snapshot.processedSourceIDs.contains(source.messageID) else { return nil }
        guard snapshot.processedSourceIDs.count < Self.maximumProcessedSources else {
            throw AgentLocalMemoryError.capacityExceeded
        }
        let clean = try sanitizedText(text)
        let evidence = AgentLocalMemorySource(
            taskID: source.taskID,
            messageID: source.messageID,
            taskTitle: try sanitizedEvidence(source.taskTitle, maximumBytes: 256),
            excerpt: try sanitizedEvidence(source.excerpt, maximumBytes: 1_024)
        )
        snapshot.processedSourceIDs.append(source.messageID)
        let duplicate = snapshot.entries.contains {
            $0.text.localizedStandardCompare(clean) == .orderedSame
        }
        var added: AgentLocalMemoryEntry?
        if !duplicate {
            guard snapshot.entries.count < Self.maximumEntries else {
                throw AgentLocalMemoryError.capacityExceeded
            }
            let now = Date()
            added = AgentLocalMemoryEntry(
                id: UUID(), text: clean, status: .proposed,
                createdAt: now, updatedAt: now, category: category, source: evidence
            )
            snapshot.entries.append(added!)
        }
        try saveReconciled(snapshot, projectID: projectID)
        return added
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
    func update(
        id: UUID, text: String,
        category: AgentLocalMemoryCategory? = nil,
        projectID: UUID
    ) throws -> AgentLocalMemoryEntry {
        var snapshot = try load(projectID: projectID)
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else {
            throw AgentLocalMemoryError.notFound
        }
        snapshot.entries[index].text = try sanitizedText(text)
        if let category { snapshot.entries[index].category = category }
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

    /// Returns a bounded, query-ranked slice of approved Project items.
    /// The caller must also check global and per-Task memory-use preferences.
    func approvedForContext(projectID: UUID, query: String = "") throws -> [AgentLocalMemoryEntry] {
        let snapshot = try load(projectID: projectID)
        guard snapshot.enabled else { return [] }
        var selected: [AgentLocalMemoryEntry] = []
        var bytes = 0
        var categoryCounts: [AgentLocalMemoryCategory: Int] = [:]
        let ranked = Self.rank(
            snapshot.entries.filter { $0.status == .approved }, query: query
        )
        for entry in ranked {
            let count = entry.text.utf8.count
            if selected.count >= Self.maximumContextEntries { break }
            if bytes + count > Self.maximumContextBytes { continue }
            let category = entry.category ?? .other
            if categoryCounts[category, default: 0] >= Self.maximumContextEntriesPerCategory {
                continue
            }
            selected.append(entry)
            bytes += count
            categoryCounts[category, default: 0] += 1
        }
        return selected
    }

    func search(
        projectIDs: [UUID], query: String,
        category: AgentLocalMemoryCategory? = nil,
        sort: AgentLocalMemorySort = .relevance
    ) throws -> [(UUID, AgentLocalMemoryEntry)] {
        var matches: [(UUID, AgentLocalMemoryEntry)] = []
        for projectID in Set(projectIDs) {
            let snapshot = try load(projectID: projectID)
            for entry in snapshot.entries where category == nil || entry.category == category {
                if query.isEmpty || entry.text.localizedStandardContains(query)
                    || (entry.source?.taskTitle.localizedStandardContains(query) == true) {
                    matches.append((projectID, entry))
                }
            }
        }
        return matches.sorted {
            if sort == .relevance {
                let firstScore = Self.relevance($0.1.text, query: query)
                let secondScore = Self.relevance($1.1.text, query: query)
                if firstScore != secondScore { return firstScore > secondScore }
            }
            return $0.1.updatedAt > $1.1.updatedAt
        }
    }

    private static func rank(
        _ entries: [AgentLocalMemoryEntry], query: String
    ) -> [AgentLocalMemoryEntry] {
        entries.sorted {
            let left = relevance($0.text, query: query)
            let right = relevance($1.text, query: query)
            if left != right { return left > right }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private static func relevance(_ text: String, query: String) -> Int {
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .prefix(24).filter { $0.count >= 2 }
        let value = text.lowercased()
        return terms.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
    }

    private func sanitizedEvidence(_ value: String, maximumBytes: Int) throws -> String {
        let clean = redactor.redact(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.contains("\0"), clean.utf8.count <= maximumBytes else {
            throw AgentLocalMemoryError.invalidText
        }
        return clean
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
        guard snapshot.processedSourceIDs.count <= Self.maximumProcessedSources,
              Set(snapshot.processedSourceIDs).count == snapshot.processedSourceIDs.count else {
            throw AgentLocalMemoryError.corruptStore
        }
        var IDs = Set<UUID>()
        for entry in snapshot.entries {
            let sanitized = try? sanitizedText(entry.text)
            guard IDs.insert(entry.id).inserted,
                  entry.text == sanitized else {
                throw AgentLocalMemoryError.corruptStore
            }
            if let source = entry.source {
                guard source.taskTitle == (try? sanitizedEvidence(source.taskTitle, maximumBytes: 256)),
                      source.excerpt == (try? sanitizedEvidence(source.excerpt, maximumBytes: 1_024))
                else { throw AgentLocalMemoryError.corruptStore }
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
            enabled: snapshot.enabled, entries: snapshot.entries,
            processedSourceIDs: snapshot.processedSourceIDs
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
