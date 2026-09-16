import Foundation
import XCTest
@testable import LumaChat

private actor Projects2SessionStore: AgentSessionPersisting {
    private var values: [AgentSession]

    init(_ values: [AgentSession] = []) {
        self.values = values
    }

    func loadSessions() async throws -> [AgentSession] { values }

    func save(_ session: AgentSession) async throws {
        if let index = values.firstIndex(where: { $0.id == session.id }) {
            values[index] = session
        } else {
            values.append(session)
        }
    }

    func delete(id: UUID) async throws {
        values.removeAll { $0.id == id }
    }

    func snapshot() -> [AgentSession] { values }
}

private actor Projects2CatalogStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject]

    init(_ values: [AgentProject] = []) {
        self.values = values
    }

    func loadProjects() async throws -> [AgentProject] { values }

    func saveProjects(_ projects: [AgentProject]) async throws {
        try AgentProjectCatalogValidation.validate(projects)
        values = projects
    }

    func touchProject(id: UUID, openedAt: Date) async throws {
        guard let index = values.firstIndex(where: { $0.id == id }),
              openedAt > values[index].lastOpenedAt else { return }
        values[index].lastOpenedAt = openedAt
    }

    func refreshFolder(
        projectID: UUID,
        folderID: UUID,
        workspace: AgentWorkspace,
        openedAt: Date
    ) async throws {
        guard let projectIndex = values.firstIndex(where: { $0.id == projectID }),
              let folderIndex = values[projectIndex].folders.firstIndex(
                where: { $0.id == folderID }
              ) else { return }
        var workspace = workspace
        workspace.id = values[projectIndex].folders[folderIndex].workspace.id
        workspace.allowedPaths = []
        values[projectIndex].folders[folderIndex].workspace = workspace
        values[projectIndex].folders[folderIndex].lastOpenedAt = openedAt
        values[projectIndex].lastOpenedAt = openedAt
    }

    func snapshot() -> [AgentProject] { values }
}

final class AgentProjects2Tests: XCTestCase {
    func testCatalogStoreRoundTripsMultipleFoldersAndRejectsAuthorityExpansion() async throws {
        let root = try makeTemporaryDirectory("catalog-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = try makeFolder("first", under: root)
        let secondRoot = try makeFolder("second", under: root)
        let firstWorkspace = makeWorkspace(firstRoot)
        let secondWorkspace = makeWorkspace(secondRoot)
        let firstFolder = AgentProjectFolder(workspace: firstWorkspace)
        let secondFolder = AgentProjectFolder(workspace: secondWorkspace)
        let project = AgentProject(
            name: "自訂 Project",
            folders: [firstFolder, secondFolder],
            primaryFolderID: secondFolder.id,
            pinnedAt: Date()
        )
        let store = AgentProjectCatalogStore(
            catalogFile: root.appendingPathComponent("state/catalog.json")
        )

        try await store.saveProjects([project])
        let loaded = try await store.loadProjects()

        XCTAssertEqual(loaded, [project])
        XCTAssertEqual(loaded.first?.primaryFolder?.workspace.rootPath, secondRoot.path)

        var expandedWorkspace = firstWorkspace
        expandedWorkspace.allowedPaths = [secondRoot.path]
        let invalid = AgentProject(name: "Invalid", primaryWorkspace: expandedWorkspace)
        do {
            try await store.saveProjects([invalid])
            XCTFail("Persisted allowedPaths must never turn a catalog into cross-root authority")
        } catch let error as AgentProjectCatalogError {
            guard case .invalidCatalog = error else {
                return XCTFail("Unexpected catalog error: \(error)")
            }
        }
    }

    func testLegacyMigrationGroupsTasksByCanonicalWorkspaceAndIsIdempotent() throws {
        let root = try makeTemporaryDirectory("migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = try makeFolder("shared", under: root)
        let secondRoot = try makeFolder("other", under: root)
        var first = AgentSession(mode: .agent)
        var second = AgentSession(mode: .plan)
        var third = AgentSession(mode: .agent)
        first.workspace = makeWorkspace(firstRoot)
        second.workspace = makeWorkspace(firstRoot)
        third.workspace = makeWorkspace(secondRoot)
        let firstUpdatedAt = first.updatedAt
        let sharedCanonical = try AgentProjectCatalogValidation.canonicalRoot(firstRoot.path)

        let migrated = AgentProjectMigrator.migrate(
            sessions: [first, second, third],
            projects: [],
            legacyDisplayNamesByCanonicalRoot: [sharedCanonical: "Legacy Alias"]
        )

        XCTAssertEqual(migrated.projects.count, 2)
        XCTAssertEqual(migrated.changedSessionIDs, Set([first.id, second.id, third.id]))
        XCTAssertEqual(migrated.sessions[0].projectID, migrated.sessions[1].projectID)
        XCTAssertEqual(migrated.sessions[0].projectFolderID, migrated.sessions[1].projectFolderID)
        XCTAssertNotEqual(migrated.sessions[0].projectID, migrated.sessions[2].projectID)
        XCTAssertEqual(
            migrated.projects.first(where: { $0.id == migrated.sessions[0].projectID })?.name,
            "Legacy Alias"
        )
        XCTAssertEqual(migrated.sessions[0].updatedAt, firstUpdatedAt)

        let repeated = AgentProjectMigrator.migrate(
            sessions: migrated.sessions,
            projects: migrated.projects
        )
        XCTAssertFalse(repeated.catalogChanged)
        XCTAssertTrue(repeated.changedSessionIDs.isEmpty)
        XCTAssertEqual(repeated.projects, migrated.projects)
        XCTAssertEqual(repeated.sessions, migrated.sessions)
    }

    func testAtomicRecencyTouchPreservesLatestFolderStructure() async throws {
        let root = try makeTemporaryDirectory("touch")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = try makeFolder("first", under: root)
        let secondRoot = try makeFolder("second", under: root)
        var project = AgentProject(name: "Touch", primaryWorkspace: makeWorkspace(firstRoot))
        let store = AgentProjectCatalogStore(
            catalogFile: root.appendingPathComponent("state/catalog.json")
        )
        try await store.saveProjects([project])

        project.folders.append(AgentProjectFolder(workspace: makeWorkspace(secondRoot)))
        project.updatedAt = Date()
        try await store.saveProjects([project])
        let openedAt = Date().addingTimeInterval(5)
        try await store.touchProject(id: project.id, openedAt: openedAt)
        let loaded = try await store.loadProjects()

        XCTAssertEqual(loaded.first?.folders.count, 2)
        XCTAssertEqual(loaded.first?.lastOpenedAt, openedAt)

        var rebound = try XCTUnwrap(loaded.first?.primaryFolder?.workspace)
        rebound.rootPath = secondRoot.path
        rebound.name = secondRoot.lastPathComponent
        do {
            try await store.refreshFolder(
                projectID: project.id,
                folderID: project.primaryFolderID,
                workspace: rebound,
                openedAt: Date().addingTimeInterval(10)
            )
            XCTFail("Bookmark refresh must not rebind a folder to another checkout")
        } catch let error as AgentProjectCatalogError {
            guard case .invalidCatalog = error else {
                return XCTFail("Unexpected refresh error: \(error)")
            }
        }
    }

    func testSessionDecoderKeepsPreProjects2JSONCompatible() throws {
        let original = AgentSession(mode: .agent)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "projectID")
        object.removeValue(forKey: "projectFolderID")
        object.removeValue(forKey: "pinnedAt")
        object.removeValue(forKey: "archivedAt")

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.projectID)
        XCTAssertNil(decoded.projectFolderID)
        XCTAssertNil(decoded.pinnedAt)
        XCTAssertNil(decoded.archivedAt)
    }

    @MainActor
    func testRestorePersistsLegacyProjectAssignmentBeforeUse() async throws {
        let root = try makeTemporaryDirectory("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = try makeFolder("workspace", under: root)
        var first = AgentSession(mode: .agent)
        var second = AgentSession(mode: .plan)
        first.workspace = makeWorkspace(workspaceRoot)
        second.workspace = makeWorkspace(workspaceRoot)
        let sessions = Projects2SessionStore([first, second])
        let catalog = Projects2CatalogStore()
        let viewModel = AgentViewModel(
            sessionStore: sessions,
            projectCatalogStore: catalog
        )

        try await viewModel.restoreProjectCatalogState()

        XCTAssertEqual(viewModel.projects.count, 1)
        XCTAssertEqual(viewModel.sessions.count, 2)
        XCTAssertEqual(viewModel.sessions[0].projectID, viewModel.sessions[1].projectID)
        let catalogSnapshot = await catalog.snapshot()
        XCTAssertEqual(catalogSnapshot, viewModel.projects)
        let persisted = await sessions.snapshot()
        XCTAssertTrue(persisted.allSatisfy { $0.projectID != nil && $0.projectFolderID != nil })
    }

    @MainActor
    func testSelectingProjectNeverCreatesTaskAndExplicitTaskUsesPrimaryFolder() async throws {
        let root = try makeTemporaryDirectory("explicit-task")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = try makeFolder("workspace", under: root)
        let project = AgentProject(
            name: "My Project",
            primaryWorkspace: makeWorkspace(workspaceRoot)
        )
        let sessions = Projects2SessionStore()
        let catalog = Projects2CatalogStore([project])
        let viewModel = AgentViewModel(
            sessionStore: sessions,
            projectCatalogStore: catalog
        )
        try await viewModel.restoreProjectCatalogState()
        viewModel.switchMode(.agent, route: AppSettings(selectedModel: "qa-model"))

        viewModel.selectProject(project.id)
        XCTAssertTrue(viewModel.sessions.isEmpty, "Opening a project must not create a task")
        XCTAssertNil(viewModel.selectedSessionID)

        let taskID = viewModel.createSession(
            mode: .agent,
            route: AppSettings(selectedModel: "qa-model")
        )
        let task = try XCTUnwrap(viewModel.sessions.first(where: { $0.id == taskID }))
        XCTAssertEqual(task.projectID, project.id)
        XCTAssertEqual(task.projectFolderID, project.primaryFolderID)
        XCTAssertEqual(task.workspace?.rootPath, workspaceRoot.path)
    }

    @MainActor
    func testProjectScopedSearchPinAndArchiveAreIndependent() async throws {
        let root = try makeTemporaryDirectory("search")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = try makeFolder("first", under: root)
        let secondRoot = try makeFolder("second", under: root)
        let firstProject = AgentProject(name: "First", primaryWorkspace: makeWorkspace(firstRoot))
        let secondProject = AgentProject(name: "Second", primaryWorkspace: makeWorkspace(secondRoot))
        var pinned = assignedSession(title: "needle pinned", project: firstProject)
        pinned.pinnedAt = Date()
        var archived = assignedSession(title: "needle archived", project: firstProject)
        archived.archivedAt = Date()
        let other = assignedSession(title: "needle other", project: secondProject)
        let viewModel = AgentViewModel(
            sessionStore: Projects2SessionStore([archived, other, pinned]),
            projectCatalogStore: Projects2CatalogStore([firstProject, secondProject])
        )
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectProject(firstProject.id)
        viewModel.sidebarSearch = "needle"

        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [pinned.id])
        viewModel.showArchivedTasks = true
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [pinned.id, archived.id])
        viewModel.selectProject(secondProject.id)
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [other.id])
    }

    @MainActor
    func testTaskCannotBeReboundAfterDurableHistory() async throws {
        let root = try makeTemporaryDirectory("rebind")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = try makeFolder("first", under: root)
        let secondRoot = try makeFolder("second", under: root)
        let firstFolder = AgentProjectFolder(workspace: makeWorkspace(firstRoot))
        let secondFolder = AgentProjectFolder(workspace: makeWorkspace(secondRoot))
        let project = AgentProject(
            name: "Multi",
            folders: [firstFolder, secondFolder],
            primaryFolderID: firstFolder.id
        )
        var session = assignedSession(title: "Task", project: project)
        session.projectFolderID = firstFolder.id
        session.workspace = firstFolder.workspace
        let viewModel = AgentViewModel(
            sessionStore: Projects2SessionStore([session]),
            projectCatalogStore: Projects2CatalogStore([project])
        )
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectedSessionID = session.id

        await viewModel.assignSelectedSession(toProjectFolder: secondFolder.id)
        XCTAssertEqual(viewModel.selectedSession?.workspace?.rootPath, secondRoot.path)

        var withHistory = try XCTUnwrap(viewModel.selectedSession)
        withHistory.messages.append(AgentMessage(role: .user, content: "durable"))
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: withHistory, userRequest: nil)
        withHistory.state = .completed
        await viewModel.finish(withHistory, runID: runID)

        await viewModel.assignSelectedSession(toProjectFolder: firstFolder.id)
        XCTAssertEqual(viewModel.selectedSession?.workspace?.rootPath, secondRoot.path)
        XCTAssertTrue(viewModel.errorMessage?.contains("已有執行歷史") == true)
    }

    @MainActor
    func testTaskAndProjectPinArchiveMutationsPersistIndependently() async throws {
        let root = try makeTemporaryDirectory("lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceRoot = try makeFolder("workspace", under: root)
        let project = AgentProject(name: "Lifecycle", primaryWorkspace: makeWorkspace(workspaceRoot))
        let task = assignedSession(title: "Lifecycle Task", project: project)
        let sessionStore = Projects2SessionStore([task])
        let catalogStore = Projects2CatalogStore([project])
        let viewModel = AgentViewModel(
            sessionStore: sessionStore,
            projectCatalogStore: catalogStore
        )
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectProject(project.id)
        viewModel.selectedSessionID = task.id

        await viewModel.toggleSessionPinned(id: task.id)
        XCTAssertNotNil(viewModel.selectedSession?.pinnedAt)
        await viewModel.setSessionArchived(id: task.id, archived: true)
        XCTAssertNotNil(viewModel.sessions.first(where: { $0.id == task.id })?.archivedAt)

        let renamed = await viewModel.renameProject(id: project.id, to: "Renamed")
        XCTAssertTrue(renamed)
        await viewModel.toggleProjectPinned(id: project.id)
        XCTAssertEqual(viewModel.projects.first?.name, "Renamed")
        XCTAssertTrue(viewModel.projects.first?.isPinned == true)

        let persistedTasks = await sessionStore.snapshot()
        let persistedProjects = await catalogStore.snapshot()
        XCTAssertNotNil(persistedTasks.first?.pinnedAt)
        XCTAssertNotNil(persistedTasks.first?.archivedAt)
        XCTAssertEqual(persistedProjects.first?.name, "Renamed")
        XCTAssertTrue(persistedProjects.first?.isPinned == true)
    }

    @MainActor
    func testConcurrentWritableTasksRequireDistinctCheckoutRoots() async throws {
        let root = try makeTemporaryDirectory("checkout")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedRoot = try makeFolder("shared", under: root)
        let independentRoot = try makeFolder("independent", under: root)
        let viewModel = AgentViewModel(
            sessionStore: Projects2SessionStore(),
            projectCatalogStore: Projects2CatalogStore()
        )
        viewModel.activeMode = .agent
        var running = AgentSession(mode: .agent)
        running.workspace = makeWorkspace(sharedRoot)
        running.model = "qa-model"
        running.state = .running
        let runningRunID = UUID()
        viewModel.beginRunTracking(runID: runningRunID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runningRunID)

        var conflicting = AgentSession(mode: .agent)
        conflicting.workspace = makeWorkspace(sharedRoot)
        conflicting.model = "qa-model"
        let conflictingRunID = UUID()
        viewModel.beginRunTracking(
            runID: conflictingRunID,
            session: conflicting,
            userRequest: nil
        )
        await viewModel.handle(.sessionUpdated(conflicting), runID: conflictingRunID)
        await viewModel.finish(conflicting, runID: conflictingRunID)
        viewModel.selectedSessionID = conflicting.id
        viewModel.draft = "write"
        XCTAssertFalse(viewModel.canSend)

        var independent = AgentSession(mode: .agent)
        independent.workspace = makeWorkspace(independentRoot)
        independent.model = "qa-model"
        let independentRunID = UUID()
        viewModel.beginRunTracking(
            runID: independentRunID,
            session: independent,
            userRequest: nil
        )
        await viewModel.handle(.sessionUpdated(independent), runID: independentRunID)
        await viewModel.finish(independent, runID: independentRunID)
        viewModel.selectedSessionID = independent.id
        viewModel.draft = "write"
        XCTAssertTrue(viewModel.canSend)
    }

    private func assignedSession(title: String, project: AgentProject) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.title = title
        session.projectID = project.id
        session.projectFolderID = project.primaryFolderID
        session.workspace = project.primaryFolder?.workspace
        session.model = "qa-model"
        return session
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "projects-v2-tests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFolder(_ name: String, under root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeWorkspace(_ root: URL) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
    }
}
