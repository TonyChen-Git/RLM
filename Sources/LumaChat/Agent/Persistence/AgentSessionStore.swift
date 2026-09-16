import Darwin
import Foundation

enum AgentSessionStoreError: LocalizedError, Equatable, Sendable {
    case sessionDeleted(UUID)
    case staleSnapshot(UUID)

    var errorDescription: String? {
        switch self {
        case .sessionDeleted(let id):
            "Session \(id.uuidString) 已刪除，拒絕延遲寫入。"
        case .staleSnapshot(let id):
            "Session \(id.uuidString) 的舊快照晚於新狀態抵達，已拒絕倒退覆寫。"
        }
    }
}

enum AgentSessionPresence: Equatable, Sendable {
    case found
    case absent
    case corrupt
    case unknown
}

actor AgentSessionStore {
    private static let maximumSessionBytes = 64 * 1_024 * 1_024
    private let fileManager: FileManager
    private let sessionsRoot: URL
    private var deletedSessionIDs = Set<UUID>()

    init(
        fileManager: FileManager = .default,
        sessionsRoot: URL = AppPaths.agentSessions
    ) {
        self.fileManager = fileManager
        self.sessionsRoot = sessionsRoot.standardizedFileURL
    }

    func loadSessions() throws -> [AgentSession] {
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return entries.compactMap { directory -> AgentSession? in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let file = directory.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: file),
                  let session = try? JSONDecoder().decode(AgentSession.self, from: data),
                  session.id.uuidString == directory.lastPathComponent else { return nil }
            return session
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.createdAt > $1.createdAt }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func save(_ session: AgentSession) throws {
        guard !deletedSessionIDs.contains(session.id) else {
            throw AgentSessionStoreError.sessionDeleted(session.id)
        }
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let directory = sessionDirectory(session.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: file),
           let persisted = try? JSONDecoder().decode(AgentSession.self, from: data),
           persisted.id == session.id,
           persisted.updatedAt > session.updatedAt {
            throw AgentSessionStoreError.staleSnapshot(session.id)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(
            try encoder.encode(session),
            to: file
        )
    }

    func delete(id: UUID) throws {
        let directory = sessionDirectory(id).standardizedFileURL
        guard directory.deletingLastPathComponent() == sessionsRoot else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(directory.path)
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        // Do not tombstone the in-process ID until durable removal succeeds;
        // otherwise a transient filesystem error leaves a visible Task that
        // this process can never save again.
        deletedSessionIDs.insert(id)
    }

    func presence(id: UUID) async -> AgentSessionPresence {
        let directory = sessionDirectory(id).standardizedFileURL
        guard directory.deletingLastPathComponent() == sessionsRoot else { return .corrupt }
        var directoryInfo = Darwin.stat()
        if Darwin.lstat(directory.path, &directoryInfo) != 0 {
            return errno == ENOENT ? .absent : .corrupt
        }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR else { return .corrupt }
        let file = directory.appendingPathComponent("session.json", isDirectory: false)
        var fileInfo = Darwin.stat()
        guard Darwin.lstat(file.path, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= Int64(Self.maximumSessionBytes),
              let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              let session = try? JSONDecoder().decode(AgentSession.self, from: data),
              session.id == id else {
            return .corrupt
        }
        return .found
    }

    private func sessionDirectory(_ id: UUID) -> URL {
        sessionsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

actor AgentSettingsStore {
    func load() throws -> AgentSettings {
        try AppPaths.ensureAgentDirectories()
        guard FileManager.default.fileExists(atPath: AppPaths.agentSettingsFile.path) else {
            return AgentSettings()
        }
        return try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(contentsOf: AppPaths.agentSettingsFile)
        )
    }

    func save(_ settings: AgentSettings) throws {
        try AppPaths.ensureAgentDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(try encoder.encode(settings), to: AppPaths.agentSettingsFile)
    }
}
