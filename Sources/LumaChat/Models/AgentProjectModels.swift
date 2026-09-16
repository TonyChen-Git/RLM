import Foundation

enum AgentProjectCatalogLimits {
    static let maximumProjects = 256
    static let maximumFoldersPerProject = 32
    static let maximumNameBytes = 512
    static let maximumPathBytes = 4_096
    static let maximumBookmarkBytes = 4 * 1_024 * 1_024
    static let maximumCatalogBytes = 16 * 1_024 * 1_024
}

enum AgentProjectCatalogError: LocalizedError, Equatable, Sendable {
    case invalidCatalog(String)
    case unsupportedVersion(Int)
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog(let detail):
            "Projects catalog 無效：\(detail)"
        case .unsupportedVersion(let version):
            "Projects catalog 版本 \(version) 不受支援。"
        case .tooLarge(let maximum):
            "Projects catalog 超過 \(maximum) bytes 上限。"
        }
    }
}

struct AgentProjectFolder: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var workspace: AgentWorkspace
    var addedAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        workspace: AgentWorkspace,
        addedAt: Date = Date(),
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.workspace = workspace
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    var name: String { workspace.name }
}

struct AgentProject: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var folders: [AgentProjectFolder]
    var primaryFolderID: UUID
    var pinnedAt: Date?
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        folders: [AgentProjectFolder],
        primaryFolderID: UUID,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.primaryFolderID = primaryFolderID
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        primaryWorkspace: AgentWorkspace,
        createdAt: Date = Date()
    ) {
        let folder = AgentProjectFolder(
            workspace: primaryWorkspace,
            addedAt: createdAt,
            lastOpenedAt: createdAt
        )
        self.init(
            id: id,
            name: name,
            folders: [folder],
            primaryFolderID: folder.id,
            createdAt: createdAt,
            updatedAt: createdAt,
            lastOpenedAt: createdAt
        )
    }

    var primaryFolder: AgentProjectFolder? {
        folders.first(where: { $0.id == primaryFolderID })
    }

    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }
}

struct AgentProjectCatalogEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var projects: [AgentProject]

    init(version: Int = currentVersion, projects: [AgentProject]) {
        self.version = version
        self.projects = projects
    }
}

enum AgentProjectCatalogValidation {
    static func validate(_ projects: [AgentProject]) throws {
        guard projects.count <= AgentProjectCatalogLimits.maximumProjects else {
            throw AgentProjectCatalogError.invalidCatalog("專案數量超過安全上限。")
        }

        var projectIDs = Set<UUID>()
        var folderIDs = Set<UUID>()
        var canonicalRoots = Set<String>()
        for project in projects {
            guard projectIDs.insert(project.id).inserted else {
                throw AgentProjectCatalogError.invalidCatalog("包含重複的 project ID。")
            }
            try validateName(project.name)
            guard !project.folders.isEmpty,
                  project.folders.count <= AgentProjectCatalogLimits.maximumFoldersPerProject,
                  project.folders.contains(where: { $0.id == project.primaryFolderID }) else {
                throw AgentProjectCatalogError.invalidCatalog("專案 folder 或 primary folder 無效。")
            }

            for folder in project.folders {
                guard folderIDs.insert(folder.id).inserted else {
                    throw AgentProjectCatalogError.invalidCatalog("包含重複的 folder ID。")
                }
                let workspace = folder.workspace
                guard workspace.allowedPaths.isEmpty else {
                    throw AgentProjectCatalogError.invalidCatalog(
                        "Project folder 不得藉由 allowedPaths 擴張 task 權限。"
                    )
                }
                let root = try canonicalRoot(workspace.rootPath)
                guard canonicalRoots.insert(root).inserted else {
                    throw AgentProjectCatalogError.invalidCatalog("同一個 folder 被加入多個專案。")
                }
                guard !workspace.name.isEmpty,
                      workspace.name.utf8.count <= AgentProjectCatalogLimits.maximumNameBytes,
                      !containsControlCharacters(workspace.name) else {
                    throw AgentProjectCatalogError.invalidCatalog("Folder 名稱無效。")
                }
                if let bookmark = workspace.bookmarkData,
                   bookmark.count > AgentProjectCatalogLimits.maximumBookmarkBytes {
                    throw AgentProjectCatalogError.invalidCatalog("Folder bookmark 超過安全上限。")
                }
            }
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.isEmpty,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.utf8.count <= AgentProjectCatalogLimits.maximumNameBytes,
              !containsControlCharacters(name) else {
            throw AgentProjectCatalogError.invalidCatalog(
                "專案名稱不得空白、包含控制字元或超過 512 bytes。"
            )
        }
    }

    static func canonicalRoot(_ path: String) throws -> String {
        guard !path.isEmpty,
              path.hasPrefix("/"),
              path != "/",
              path.utf8.count <= AgentProjectCatalogLimits.maximumPathBytes,
              !containsControlCharacters(path) else {
            throw AgentProjectCatalogError.invalidCatalog("Folder 路徑無效。")
        }
        if let identity = try? AgentProjectIdentity.resolve(workspaceRootPath: path) {
            return identity.canonicalRootPath
        }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard canonical != "/" else {
            throw AgentProjectCatalogError.invalidCatalog("Folder 不得指向檔案系統根目錄。")
        }
        return canonical
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

protocol AgentProjectCatalogPersisting: Sendable {
    func loadProjects() async throws -> [AgentProject]
    func saveProjects(_ projects: [AgentProject]) async throws
    func touchProject(id: UUID, openedAt: Date) async throws
    func refreshFolder(
        projectID: UUID,
        folderID: UUID,
        workspace: AgentWorkspace,
        openedAt: Date
    ) async throws
}

actor AgentProjectCatalogStore: AgentProjectCatalogPersisting {
    private let fileManager: FileManager
    private let catalogFile: URL

    init(
        fileManager: FileManager = .default,
        catalogFile: URL = AppPaths.agentProjectCatalogFile
    ) {
        self.fileManager = fileManager
        self.catalogFile = catalogFile.standardizedFileURL
    }

    func loadProjects() throws -> [AgentProject] {
        let parent = catalogFile.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: catalogFile.path) else { return [] }
        let values = try catalogFile.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AgentProjectCatalogError.invalidCatalog("catalog.json 不是一般檔案。")
        }
        if let size = values.fileSize,
           size > AgentProjectCatalogLimits.maximumCatalogBytes {
            throw AgentProjectCatalogError.tooLarge(
                AgentProjectCatalogLimits.maximumCatalogBytes
            )
        }
        let data = try Data(contentsOf: catalogFile, options: [.mappedIfSafe])
        guard data.count <= AgentProjectCatalogLimits.maximumCatalogBytes else {
            throw AgentProjectCatalogError.tooLarge(
                AgentProjectCatalogLimits.maximumCatalogBytes
            )
        }
        let envelope = try JSONDecoder().decode(AgentProjectCatalogEnvelope.self, from: data)
        guard envelope.version == AgentProjectCatalogEnvelope.currentVersion else {
            throw AgentProjectCatalogError.unsupportedVersion(envelope.version)
        }
        try AgentProjectCatalogValidation.validate(envelope.projects)
        return envelope.projects
    }

    func saveProjects(_ projects: [AgentProject]) throws {
        try AgentProjectCatalogValidation.validate(projects)
        let parent = catalogFile.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let envelope = AgentProjectCatalogEnvelope(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= AgentProjectCatalogLimits.maximumCatalogBytes else {
            throw AgentProjectCatalogError.tooLarge(
                AgentProjectCatalogLimits.maximumCatalogBytes
            )
        }
        try AtomicFileWriter.write(data, to: catalogFile)
    }

    /// Updates only recency metadata from the actor's latest durable catalog.
    /// This avoids an asynchronous navigation touch overwriting a concurrent
    /// structural save that added or removed a folder.
    func touchProject(id: UUID, openedAt: Date) throws {
        var current = try loadProjects()
        guard let index = current.firstIndex(where: { $0.id == id }),
              openedAt > current[index].lastOpenedAt else { return }
        current[index].lastOpenedAt = openedAt
        try saveProjects(current)
    }

    /// Refreshes a security-scoped bookmark and folder metadata without
    /// permitting the task to rebind the catalog entry to another root.
    func refreshFolder(
        projectID: UUID,
        folderID: UUID,
        workspace: AgentWorkspace,
        openedAt: Date
    ) throws {
        var current = try loadProjects()
        guard let projectIndex = current.firstIndex(where: { $0.id == projectID }),
              let folderIndex = current[projectIndex].folders.firstIndex(
                where: { $0.id == folderID }
              ) else { return }
        let existingRoot = try AgentProjectCatalogValidation.canonicalRoot(
            current[projectIndex].folders[folderIndex].workspace.rootPath
        )
        let refreshedRoot = try AgentProjectCatalogValidation.canonicalRoot(
            workspace.rootPath
        )
        guard existingRoot == refreshedRoot else {
            throw AgentProjectCatalogError.invalidCatalog(
                "Task 嘗試把 folder metadata 改綁到另一個 checkout。"
            )
        }
        var safeWorkspace = workspace
        safeWorkspace.id = current[projectIndex].folders[folderIndex].workspace.id
        safeWorkspace.allowedPaths = []
        current[projectIndex].folders[folderIndex].workspace = safeWorkspace
        current[projectIndex].folders[folderIndex].lastOpenedAt = max(
            current[projectIndex].folders[folderIndex].lastOpenedAt,
            openedAt
        )
        current[projectIndex].lastOpenedAt = max(
            current[projectIndex].lastOpenedAt,
            openedAt
        )
        try saveProjects(current)
    }
}

struct AgentProjectMigrationResult: Equatable, Sendable {
    var projects: [AgentProject]
    var sessions: [AgentSession]
    var changedSessionIDs: Set<UUID>
    var catalogChanged: Bool
}

enum AgentProjectMigrator {
    static func migrate(
        sessions originalSessions: [AgentSession],
        projects originalProjects: [AgentProject],
        legacyDisplayNamesByCanonicalRoot: [String: String] = [:],
        migratedAt: Date = Date()
    ) -> AgentProjectMigrationResult {
        var projects = originalProjects
        var sessions = originalSessions
        var changedSessionIDs = Set<UUID>()
        var folderByRoot: [String: (projectID: UUID, folderID: UUID)] = [:]

        for project in projects {
            for folder in project.folders {
                let root = canonicalRoot(folder.workspace.rootPath)
                folderByRoot[root] = (project.id, folder.id)
            }
        }

        for index in sessions.indices {
            guard let workspace = sessions[index].workspace else { continue }
            if sessions[index].resolvedExecutionLocation.kind != .local {
                // Managed/remote execution checkouts are Task locations, not
                // user-authorized Project catalog folders. Preserve a valid
                // Project link and its remembered Local folder without
                // importing the ephemeral checkout as a new Project.
                if let projectID = sessions[index].projectID,
                   projects.contains(where: { $0.id == projectID }) {
                    continue
                }
                if let localWorkspace = sessions[index].localWorkspace {
                    let localRoot = canonicalRoot(localWorkspace.rootPath)
                    if let assignment = folderByRoot[localRoot] {
                        sessions[index].projectID = assignment.projectID
                        sessions[index].projectFolderID = nil
                        sessions[index].localProjectFolderID = assignment.folderID
                        changedSessionIDs.insert(sessions[index].id)
                    }
                }
                continue
            }
            let root = canonicalRoot(workspace.rootPath)
            if let projectID = sessions[index].projectID,
               let folderID = sessions[index].projectFolderID,
               projects.contains(where: { project in
                   project.id == projectID
                       && project.folders.contains(where: { folder in
                           folder.id == folderID
                               && canonicalRoot(folder.workspace.rootPath) == root
                       })
               }) {
                continue
            }

            let assignment: (projectID: UUID, folderID: UUID)
            if let existing = folderByRoot[root] {
                assignment = existing
            } else {
                var safeWorkspace = workspace
                safeWorkspace.allowedPaths = []
                let name = legacyDisplayNamesByCanonicalRoot[root]
                    ?? workspace.name
                let project = AgentProject(
                    name: name,
                    primaryWorkspace: safeWorkspace,
                    createdAt: min(workspace.createdAt, sessions[index].createdAt)
                )
                projects.append(project)
                assignment = (project.id, project.primaryFolderID)
                folderByRoot[root] = assignment
            }
            sessions[index].projectID = assignment.projectID
            sessions[index].projectFolderID = assignment.folderID
            changedSessionIDs.insert(sessions[index].id)

            if let projectIndex = projects.firstIndex(where: { $0.id == assignment.projectID }),
               projects[projectIndex].lastOpenedAt < sessions[index].updatedAt {
                projects[projectIndex].lastOpenedAt = sessions[index].updatedAt
                projects[projectIndex].updatedAt = max(
                    projects[projectIndex].updatedAt,
                    migratedAt
                )
            }
        }

        return AgentProjectMigrationResult(
            projects: projects,
            sessions: sessions,
            changedSessionIDs: changedSessionIDs,
            catalogChanged: projects != originalProjects
        )
    }

    private static func canonicalRoot(_ path: String) -> String {
        (try? AgentProjectCatalogValidation.canonicalRoot(path))
            ?? URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
    }
}
