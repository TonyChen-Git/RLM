import Foundation
import XCTest
@testable import LumaChat

private actor TaskTerminalLifecycleSessionStore: AgentSessionPersisting {
    private var values: [AgentSession]

    init(_ values: [AgentSession]) {
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

    func presence(id: UUID) async -> AgentSessionPresence {
        values.contains(where: { $0.id == id }) ? .found : .absent
    }
}

private actor TaskTerminalLifecycleProjectStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject]

    init(_ values: [AgentProject]) {
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
        var rebound = workspace
        rebound.id = values[projectIndex].folders[folderIndex].workspace.id
        rebound.allowedPaths = []
        values[projectIndex].folders[folderIndex].workspace = rebound
        values[projectIndex].folders[folderIndex].lastOpenedAt = openedAt
        values[projectIndex].lastOpenedAt = openedAt
    }
}

final class AgentViewModelTaskTerminalLifecycleTests: XCTestCase {
    @MainActor
    func testLiveTerminalBlocksRebindAndArchiveWhileForkStartsIsolated() async throws {
        let fixture = try makeFixture("guards")
        var taskIDsToRemove = [fixture.session.id]
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            for taskID in taskIDsToRemove {
                try? FileManager.default.removeItem(at: terminalStateRoot(taskID))
            }
        }
        let viewModel = fixture.viewModel
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectedSessionID = fixture.session.id
        viewModel.activeMode = .plan

        let sourceService = try await viewModel.taskTerminalService(
            for: fixture.session.id
        )
        let terminal = try await sourceService.create(
            title: "Lifecycle shell",
            shell: "/bin/sh"
        )
        let initiallyHasLiveTerminal = try await viewModel.hasLiveTaskTerminals(
            for: fixture.session.id
        )
        XCTAssertTrue(initiallyHasLiveTerminal)

        viewModel.selectedSessionID = fixture.session.id
        await viewModel.assignSelectedSession(
            toProjectFolder: fixture.secondFolder.id
        )
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == fixture.session.id })?
                .projectFolderID,
            fixture.firstFolder.id
        )
        XCTAssertTrue(viewModel.errorMessage?.contains("Kill/Close") == true)

        viewModel.errorMessage = nil
        await viewModel.handoffSessionToWorktree(id: fixture.session.id)
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == fixture.session.id })?
                .resolvedExecutionLocation.kind,
            .local
        )
        XCTAssertTrue(viewModel.errorMessage?.contains("Kill/Close") == true)

        viewModel.errorMessage = nil
        await viewModel.forkSession(id: fixture.session.id)
        let fork = try XCTUnwrap(viewModel.sessions.first(where: {
            $0.forkOrigin?.sourceSessionID == fixture.session.id
        }))
        taskIDsToRemove.append(fork.id)
        let forkService = try await viewModel.taskTerminalService(for: fork.id)
        let forkTerminals = try await forkService.list()
        let sourceTerminalIDs = try await sourceService.list().map(\.id)
        XCTAssertTrue(forkTerminals.isEmpty)
        XCTAssertEqual(sourceTerminalIDs, [terminal.id])

        await viewModel.setSessionArchived(id: fixture.session.id, archived: true)
        XCTAssertNil(
            viewModel.sessions.first(where: { $0.id == fixture.session.id })?.archivedAt
        )
        XCTAssertTrue(viewModel.errorMessage?.contains("Kill/Close") == true)

        viewModel.errorMessage = nil
        await viewModel.setProjectArchived(id: fixture.project.id, archived: true)
        XCTAssertNil(viewModel.projects.first(where: { $0.id == fixture.project.id })?.archivedAt)
        XCTAssertTrue(viewModel.errorMessage?.contains("Kill/Close") == true)

        try await sourceService.close(id: terminal.id)
        viewModel.errorMessage = nil
        viewModel.selectedSessionID = fixture.session.id
        await viewModel.assignSelectedSession(
            toProjectFolder: fixture.secondFolder.id
        )
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == fixture.session.id })?
                .projectFolderID,
            fixture.secondFolder.id
        )
        let reboundService = try await viewModel.taskTerminalService(
            for: fixture.session.id
        )

        await viewModel.setSessionArchived(id: fixture.session.id, archived: true)
        XCTAssertNotNil(
            viewModel.sessions.first(where: { $0.id == fixture.session.id })?.archivedAt
        )
        do {
            _ = try await reboundService.create(shell: "/bin/sh")
            XCTFail("Archive must invalidate every retained pre-archive service reference.")
        } catch let error as PseudoTerminalError {
            XCTAssertEqual(error, .disposed)
        }

        await viewModel.setProjectArchived(id: fixture.project.id, archived: true)
        XCTAssertNotNil(
            viewModel.projects.first(where: { $0.id == fixture.project.id })?.archivedAt
        )
        do {
            _ = try await forkService.create(shell: "/bin/sh")
            XCTFail("Project archive must dispose every Task Terminal service in the project.")
        } catch let error as PseudoTerminalError {
            XCTAssertEqual(error, .disposed)
        }
    }

    @MainActor
    func testAgentStopDoesNotStopTaskOwnedTerminal() async throws {
        let fixture = try makeFixture("agent-stop")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(
                at: terminalStateRoot(fixture.session.id)
            )
        }
        let viewModel = fixture.viewModel
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectedSessionID = fixture.session.id
        viewModel.activeMode = .plan

        let service = try await viewModel.taskTerminalService(
            for: fixture.session.id
        )
        let terminal = try await service.create(
            title: "Agent-independent shell",
            shell: "/bin/sh"
        )

        var running = try XCTUnwrap(viewModel.selectedSession)
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runID)
        viewModel.stop(sessionID: running.id)
        try await waitUntil(timeout: .seconds(3)) {
            !viewModel.isRunning(sessionID: running.id)
        }

        let terminalState = try await service.list()
            .first(where: { $0.id == terminal.id })?
            .metadata.state
        XCTAssertEqual(
            terminalState,
            .running,
            "Agent Stop must not stop a Task-owned PTY"
        )
        try await service.close(id: terminal.id)
        await viewModel.shutdown()
    }

    @MainActor
    func testDeleteAndShutdownDisposeTerminalServicesBeforeSessionAuthorityEnds() async throws {
        let fixture = try makeFixture("dispose-order", sessionCount: 2)
        let taskIDs = fixture.allSessions.map(\.id)
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            for taskID in taskIDs {
                try? FileManager.default.removeItem(at: terminalStateRoot(taskID))
            }
        }
        let viewModel = fixture.viewModel
        try await viewModel.restoreProjectCatalogState()
        let first = try XCTUnwrap(fixture.allSessions.first)
        let second = try XCTUnwrap(fixture.allSessions.last)
        let deletedService = try await viewModel.taskTerminalService(for: first.id)
        let shutdownService = try await viewModel.taskTerminalService(for: second.id)

        await viewModel.deleteSession(id: first.id)
        XCTAssertFalse(viewModel.sessions.contains(where: { $0.id == first.id }))
        do {
            _ = try await deletedService.create(shell: "/bin/sh")
            XCTFail("Session deletion returned before its Terminal service was disposed.")
        } catch let error as PseudoTerminalError {
            XCTAssertEqual(error, .disposed)
        }

        await viewModel.shutdown()
        do {
            _ = try await shutdownService.create(shell: "/bin/sh")
            XCTFail("Shutdown returned before Task Terminal disposal completed.")
        } catch let error as PseudoTerminalError {
            XCTAssertEqual(error, .disposed)
        }
    }

    private struct Fixture {
        var root: URL
        var project: AgentProject
        var firstFolder: AgentProjectFolder
        var secondFolder: AgentProjectFolder
        var session: AgentSession
        var allSessions: [AgentSession]
        var viewModel: AgentViewModel
    }

    @MainActor
    private func makeFixture(
        _ label: String,
        sessionCount: Int = 1
    ) throws -> Fixture {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "agent-vm-task-terminal-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstRoot = root.appendingPathComponent("first", isDirectory: true)
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let firstFolder = AgentProjectFolder(
            workspace: workspace(firstRoot, gitRepository: true)
        )
        let secondFolder = AgentProjectFolder(workspace: workspace(secondRoot))
        let project = AgentProject(
            name: "Terminal lifecycle",
            folders: [firstFolder, secondFolder],
            primaryFolderID: firstFolder.id
        )
        var sessions: [AgentSession] = []
        for ordinal in 0..<sessionCount {
            var session = AgentSession(mode: .plan)
            session.title = "Terminal task \(ordinal + 1)"
            session.projectID = project.id
            session.projectFolderID = firstFolder.id
            session.workspace = firstFolder.workspace
            session.model = "test-model"
            sessions.append(session)
        }
        let sessionStore = TaskTerminalLifecycleSessionStore(sessions)
        let viewModel = AgentViewModel(
            sessionStore: sessionStore,
            projectCatalogStore: TaskTerminalLifecycleProjectStore([project])
        )
        return Fixture(
            root: root,
            project: project,
            firstFolder: firstFolder,
            secondFolder: secondFolder,
            session: sessions[0],
            allSessions: sessions,
            viewModel: viewModel
        )
    }

    private func workspace(
        _ root: URL,
        gitRepository: Bool = false
    ) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: gitRepository,
            branch: nil
        )
    }

    private func terminalStateRoot(_ taskID: UUID) -> URL {
        AppPaths.agentSessions.appendingPathComponent(
            taskID.uuidString,
            isDirectory: true
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for AgentViewModel lifecycle transition.")
    }
}
