import Foundation
import XCTest
@testable import LumaChat

private actor HandoffIntegrationSessionStore: AgentSessionPersisting {
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

    func session(id: UUID) -> AgentSession? {
        values.first(where: { $0.id == id })
    }
}

private actor HandoffIntegrationProjectStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject] = []

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

final class AgentViewModelWorktreeHandoffTests: XCTestCase {
    @MainActor
    func testForwardForkConflictAndReversePreserveStateAndCapabilities() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try git(repository, ["init"])
        try git(repository, ["config", "user.name", "Luma Tests"])
        try git(repository, ["config", "user.email", "luma@example.invalid"])
        try Data("base\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        try git(repository, ["add", "tracked.txt"])
        try git(repository, ["commit", "--no-gpg-sign", "-m", "initial"])

        try Data("local dirty\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        try Data("local untracked\n".utf8).write(
            to: repository.appendingPathComponent("notes.txt")
        )

        var session = AgentSession(mode: .agent)
        session.title = "Handoff integration"
        session.workspace = AgentWorkspace(
            name: repository.lastPathComponent,
            rootPath: repository.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: nil
        )
        session.executionLocation = .local

        let sessionStore = HandoffIntegrationSessionStore([session])
        let registryRoot = root.appendingPathComponent("managed", isDirectory: true)
        let checkouts = registryRoot.appendingPathComponent("checkouts", isDirectory: true)
        let registry = WorktreeRegistry(
            registryFile: registryRoot.appendingPathComponent("registry.json"),
            managedRoot: checkouts
        )
        let worktrees = ManagedWorktreeService(
            registry: registry,
            managedRoot: checkouts
        )
        let handoffs = AgentTaskHandoffJournal(
            root: root.appendingPathComponent("handoffs", isDirectory: true)
        )
        let deletions = AgentTaskDeletionJournal(
            root: root.appendingPathComponent("deletions", isDirectory: true)
        )
        let recovery = WorktreeStateRecoveryStore(
            root: root.appendingPathComponent("recovery", isDirectory: true)
        )
        let viewModel = AgentViewModel(
            sessionStore: sessionStore,
            projectCatalogStore: HandoffIntegrationProjectStore(),
            worktreeService: worktrees,
            handoffJournal: handoffs,
            deletionJournal: deletions,
            worktreeRecoveryStore: recovery
        )

        try await viewModel.restoreProjectCatalogState()
        await viewModel.handoffSessionToWorktree(id: session.id)

        let handedOff = try XCTUnwrap(
            viewModel.sessions.first(where: { $0.id == session.id })
        )
        XCTAssertEqual(handedOff.resolvedExecutionLocation.kind, .worktree)
        XCTAssertEqual(handedOff.localWorkspace?.rootPath, repository.path)
        XCTAssertNotNil(handedOff.localCheckoutBaselineFingerprint)
        XCTAssertNil(viewModel.errorMessage)
        let worktreeID = try XCTUnwrap(
            handedOff.resolvedExecutionLocation.managedWorktreeID
        )
        let recordsAfterForward = try await worktrees.list()
        let record = try XCTUnwrap(
            recordsAfterForward.first(where: { $0.id == worktreeID })
        )
        XCTAssertEqual(record.lease?.taskID, session.id)
        XCTAssertEqual(record.lease?.worktreeID, worktreeID)
        XCTAssertEqual(
            try read("tracked.txt", below: URL(fileURLWithPath: record.worktreePath)),
            "local dirty\n"
        )
        XCTAssertEqual(
            try read("notes.txt", below: URL(fileURLWithPath: record.worktreePath)),
            "local untracked\n"
        )
        let journalsAfterForward = try await handoffs.pendingEntries()
        XCTAssertTrue(journalsAfterForward.isEmpty)

        // Fork is a second durable Task and checkout, never a shared Runtime or
        // lease. It starts from the exact source worktree state.
        await viewModel.forkSession(id: session.id)
        let fork = try XCTUnwrap(
            viewModel.sessions.first(where: {
                $0.forkOrigin?.sourceSessionID == session.id
            })
        )
        XCTAssertNotEqual(fork.id, session.id)
        XCTAssertEqual(fork.resolvedExecutionLocation.kind, .worktree)
        let forkWorktreeID = try XCTUnwrap(
            fork.resolvedExecutionLocation.managedWorktreeID
        )
        XCTAssertNotEqual(forkWorktreeID, worktreeID)
        let recordsAfterFork = try await worktrees.list()
        let forkRecord = try XCTUnwrap(
            recordsAfterFork.first(where: { $0.id == forkWorktreeID })
        )
        XCTAssertEqual(forkRecord.lease?.taskID, fork.id)
        XCTAssertEqual(
            try read(
                "tracked.txt",
                below: URL(fileURLWithPath: forkRecord.worktreePath)
            ),
            "local dirty\n"
        )
        XCTAssertEqual(
            try read(
                "notes.txt",
                below: URL(fileURLWithPath: forkRecord.worktreePath)
            ),
            "local untracked\n"
        )
        let journalsAfterFork = try await handoffs.pendingEntries()
        XCTAssertTrue(journalsAfterFork.isEmpty)

        let worktreeRoot = URL(fileURLWithPath: record.worktreePath, isDirectory: true)
        try Data("worktree final\n".utf8).write(
            to: worktreeRoot.appendingPathComponent("tracked.txt")
        )
        try Data("worktree addition\n".utf8).write(
            to: worktreeRoot.appendingPathComponent("added.txt")
        )

        // The reverse transaction is a compare-and-swap against the exact
        // Local baseline. An external Local edit must leave both sides and the
        // managed lease untouched.
        try Data("external local edit\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        await viewModel.handoffSessionToLocal(id: session.id)

        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == session.id })?
                .resolvedExecutionLocation.kind,
            .worktree
        )
        XCTAssertTrue(viewModel.errorMessage?.contains("baseline") == true)
        XCTAssertEqual(try read("tracked.txt", below: repository), "external local edit\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.worktreePath))
        let recordsAfterConflict = try await worktrees.list()
        let sourceAfterConflict = try XCTUnwrap(
            recordsAfterConflict.first(where: { $0.id == worktreeID })
        )
        XCTAssertEqual(sourceAfterConflict.lease?.id, record.lease?.id)
        XCTAssertEqual(
            sourceAfterConflict.lease?.worktreeID,
            record.lease?.worktreeID
        )
        XCTAssertEqual(sourceAfterConflict.lease?.taskID, record.lease?.taskID)

        // Put Local back at the proven baseline and complete the reverse
        // handoff. The desired worktree state must become durable at Local
        // before the exact leased source checkout is reclaimed.
        try Data("local dirty\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        viewModel.errorMessage = nil
        await viewModel.handoffSessionToLocal(id: session.id)

        let returned = try XCTUnwrap(
            viewModel.sessions.first(where: { $0.id == session.id })
        )
        XCTAssertEqual(returned.resolvedExecutionLocation, .local)
        XCTAssertEqual(returned.workspace?.rootPath, repository.path)
        XCTAssertNil(returned.localWorkspace)
        XCTAssertNil(returned.localCheckoutBaselineFingerprint)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(try read("tracked.txt", below: repository), "worktree final\n")
        XCTAssertEqual(try read("notes.txt", below: repository), "local untracked\n")
        XCTAssertEqual(try read("added.txt", below: repository), "worktree addition\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.worktreePath))
        let recordsAfterReverse = try await worktrees.list()
        let journalsAfterReverse = try await handoffs.pendingEntries()
        let persistedSession = await sessionStore.session(id: session.id)
        XCTAssertNil(recordsAfterReverse.first(where: { $0.id == worktreeID }))
        XCTAssertEqual(
            recordsAfterReverse.first(where: { $0.id == forkWorktreeID })?.lease?.taskID,
            fork.id
        )
        XCTAssertTrue(journalsAfterReverse.isEmpty)
        XCTAssertEqual(persistedSession?.resolvedExecutionLocation, .local)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("handoff-integration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ path: String, below root: URL) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    @discardableResult
    private func git(_ root: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "-C", root.path
        ] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "TMPDIR": AppPaths.projectTemporaryRoot.path
        ]
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentViewModelWorktreeHandoffTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)
                ]
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
