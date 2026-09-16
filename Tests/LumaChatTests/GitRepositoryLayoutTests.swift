import Foundation
import XCTest
@testable import LumaChat

final class GitRepositoryLayoutTests: XCTestCase {
    func testNormalCheckoutAndDetachedHEADAreInspected() throws {
        let fixture = try makeFixture("normal")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let repository = fixture.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: repository)
        try runGit(["commit", "--allow-empty", "-q", "-m", "initial"], at: repository)

        let symbolic = try XCTUnwrap(
            GitRepositoryLayout.inspect(workspaceRoot: repository)
        )
        XCTAssertEqual(symbolic.kind, .normalCheckout)
        XCTAssertEqual(
            symbolic.worktreeGitDirectory.standardizedFileURL.path,
            repository.appendingPathComponent(".git").standardizedFileURL.path
        )
        XCTAssertEqual(symbolic.commonGitDirectory, symbolic.worktreeGitDirectory)
        XCTAssertTrue(symbolic.head.symbolicReference?.hasPrefix("refs/heads/") == true)
        XCTAssertEqual(symbolic.head.objectID?.count, 40)
        XCTAssertTrue(symbolic.supportsWorkspaceMetadataSnapshots)
        XCTAssertTrue(WorkspaceManager.isGitRepository(at: repository.path))

        try runGit(["checkout", "--detach", "-q"], at: repository)
        let detached = try XCTUnwrap(
            GitRepositoryLayout.inspect(workspaceRoot: repository)
        )
        XCTAssertNil(detached.head.symbolicReference)
        XCTAssertEqual(detached.head.rawValue, detached.head.objectID)
        XCTAssertEqual(detached.head.objectID?.count, 40)
    }

    func testLinkedWorktreeReadToolsAndCheckpointUseVerifiedExternalMetadata() async throws {
        let fixture = try makeFixture("linked")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let main = fixture.appendingPathComponent("main", isDirectory: true)
        let linked = fixture.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: main)
        try runGit(["commit", "--allow-empty", "-q", "-m", "initial"], at: main)
        try runGit(["worktree", "add", "-q", "-b", "linked-branch", linked.path], at: main)

        let layout = try XCTUnwrap(
            GitRepositoryLayout.inspect(workspaceRoot: linked)
        )
        XCTAssertEqual(layout.kind, .linkedWorktree)
        XCTAssertEqual(layout.head.symbolicReference, "refs/heads/linked-branch")
        XCTAssertEqual(layout.commonGitDirectory, main.appendingPathComponent(".git"))
        XCTAssertFalse(layout.supportsWorkspaceMetadataSnapshots)
        XCTAssertTrue(WorkspaceManager.isGitRepository(at: linked.path))

        let workspace = makeWorkspace(linked)
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        XCTAssertThrowsError(
            try validator.validate(path: layout.commonGitDirectory.path, access: .read)
        )
        let terminal = try TerminalSession(validator: validator)

        // Merely discovering the pointer must not turn the main checkout's
        // metadata into general model-authored terminal authority.
        let directRead = try await terminal.run(
            command: "/bin/cat \(shellQuote(layout.commonGitDirectory.appendingPathComponent("HEAD").path))",
            timeout: 5
        )
        XCTAssertNotEqual(directRead.exitCode, 0)
        XCTAssertFalse(directRead.stdout.contains("refs/heads"))

        let changes = ChangeManager(validator: validator)
        let git = try GitService(validator: validator, terminal: terminal, changes: changes)
        let status = try await git.status()
        XCTAssertTrue(status.output.contains("## linked-branch"), status.output)
        let branch = try await git.currentBranch()
        XCTAssertEqual(
            branch.output.trimmingCharacters(in: .whitespacesAndNewlines),
            "linked-branch"
        )

        try Data("not staged\n".utf8).write(
            to: linked.appendingPathComponent("pointer-mutation.txt")
        )
        let mutation = try await git.add(
            paths: ["pointer-mutation.txt"],
            taskID: UUID()
        )
        XCTAssertNil(mutation.change)
        XCTAssertTrue(mutation.output.contains("Undo unavailable"), mutation.output)
        let recordedChanges = await changes.records()
        XCTAssertTrue(recordedChanges.isEmpty)
        let afterMutation = try await git.status()
        XCTAssertTrue(afterMutation.output.contains("A  pointer-mutation.txt"), afterMutation.output)

        var session = AgentSession(mode: .agent)
        session.workspace = workspace
        let checkpointDirectory = AppPaths.agentSnapshots
            .appendingPathComponent(session.id.uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkpointDirectory) }
        let manager = AgentCheckpointManager()
        let createdReference = try await manager.createCheckpointIfNeeded(
            settings: AgentSettings(),
            session: session,
            todos: []
        )
        let reference = try XCTUnwrap(createdReference)
        let manifest = try await manager.load(reference)
        XCTAssertEqual(manifest.gitState?.symbolicReference, "refs/heads/linked-branch")
        XCTAssertEqual(manifest.gitState?.objectID, layout.head.objectID)
    }

    func testSubmodulePointerIsInspectedAndGitReadToolsRemainUsable() async throws {
        let fixture = try makeFixture("submodule")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let parent = fixture.appendingPathComponent("parent", isDirectory: true)
        let origin = fixture.appendingPathComponent("module-origin", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: parent)
        try runGit(["commit", "--allow-empty", "-q", "-m", "parent"], at: parent)
        try runGit(["init", "-q"], at: origin)
        try runGit(["commit", "--allow-empty", "-q", "-m", "module"], at: origin)
        try runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", "-q", origin.path, "module"],
            at: parent
        )
        let module = parent.appendingPathComponent("module", isDirectory: true)

        let layout = try XCTUnwrap(
            GitRepositoryLayout.inspect(workspaceRoot: module)
        )
        XCTAssertEqual(layout.kind, .gitDirectoryPointer)
        XCTAssertEqual(layout.head.objectID?.count, 40)
        XCTAssertTrue(
            layout.worktreeGitDirectory.path.hasPrefix(
                parent.appendingPathComponent(".git/modules/").path
            )
        )
        XCTAssertTrue(WorkspaceManager.isGitRepository(at: module.path))

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(module))
        let terminal = try TerminalSession(validator: validator)
        let directRead = try await terminal.run(
            command: "/bin/cat \(shellQuote(layout.worktreeGitDirectory.appendingPathComponent("config").path))",
            timeout: 5
        )
        XCTAssertNotEqual(directRead.exitCode, 0)

        let git = try GitService(
            validator: validator,
            terminal: terminal,
            changes: ChangeManager(validator: validator)
        )
        let status = try await git.status()
        XCTAssertTrue(status.output.contains("##"), status.output)
    }

    func testPointerCannotBorrowUnrelatedRepositoryMetadataAuthority() throws {
        let fixture = try makeFixture("forged")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let workspace = fixture.appendingPathComponent("workspace", isDirectory: true)
        let unrelated = fixture.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: unrelated)
        try Data("gitdir: \(unrelated.appendingPathComponent(".git").path)\n".utf8)
            .write(to: workspace.appendingPathComponent(".git"))

        XCTAssertThrowsError(
            try GitRepositoryLayout.inspect(workspaceRoot: workspace)
        )
        XCTAssertFalse(WorkspaceManager.isGitRepository(at: workspace.path))
    }

    func testPointerAndHeadReadsAreBoundedAndNoFollow() throws {
        let fixture = try makeFixture("unsafe")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let workspace = fixture.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: GitRepositoryLayout.maximumPointerBytes + 1)
            .write(to: workspace.appendingPathComponent(".git"))
        XCTAssertThrowsError(
            try GitRepositoryLayout.inspect(workspaceRoot: workspace)
        )

        try FileManager.default.removeItem(at: workspace.appendingPathComponent(".git"))
        let metadata = fixture.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("[core]\nworktree = ../workspace\n".utf8)
            .write(to: metadata.appendingPathComponent("config"))
        let outsideHead = fixture.appendingPathComponent("outside-HEAD")
        try Data("\(String(repeating: "a", count: 40))\n".utf8).write(to: outsideHead)
        try FileManager.default.createSymbolicLink(
            at: metadata.appendingPathComponent("HEAD"),
            withDestinationURL: outsideHead
        )
        try Data("gitdir: ../metadata\n".utf8)
            .write(to: workspace.appendingPathComponent(".git"))
        XCTAssertThrowsError(
            try GitRepositoryLayout.inspect(workspaceRoot: workspace)
        )
    }

    func testManagedCheckoutValidatorRequiresExactRegistryAuthorization() async throws {
        try AppPaths.ensureAgentDirectories()
        let checkout = AppPaths.managedWorktrees
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let sibling = AppPaths.managedWorktrees
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nonUUID = AppPaths.managedWorktrees
            .appendingPathComponent("not-a-managed-checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonUUID, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: checkout)
            try? FileManager.default.removeItem(at: sibling)
            try? FileManager.default.removeItem(at: nonUUID)
        }

        XCTAssertThrowsError(
            try WorkspaceSecurityValidator(workspace: makeWorkspace(checkout))
        )

        let worktreeID = try XCTUnwrap(UUID(uuidString: checkout.lastPathComponent))
        let now = Date()
        let registry = WorktreeRegistry()
        try await registry.save(ManagedWorktreeRecord(
            id: worktreeID,
            repositoryRootPath: checkout.path,
            sourceCheckoutPath: checkout.path,
            worktreePath: checkout.path,
            baseObjectID: String(repeating: "a", count: 40),
            headObjectID: String(repeating: "a", count: 40),
            branchName: nil,
            createdBranch: false,
            state: .ready,
            lease: WorktreeLease(
                worktreeID: worktreeID,
                taskID: UUID(),
                acquiredAt: now
            ),
            createdAt: now
        ))
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(checkout))
        XCTAssertEqual(validator.secureRootPath, checkout.resolvingSymlinksInPath().path)
        XCTAssertThrowsError(
            try validator.validate(path: sibling.path, access: .read)
        )
        XCTAssertThrowsError(
            try validator.validate(path: AppPaths.managedWorktreeRegistryFile.path, access: .read)
        )
        XCTAssertThrowsError(
            try WorkspaceSecurityValidator(workspace: makeWorkspace(nonUUID))
        )
        XCTAssertThrowsError(
            try WorkspaceSecurityValidator(workspace: makeWorkspace(AppPaths.managedWorktrees))
        )
        try await registry.remove(id: worktreeID)
    }

    private func makeFixture(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("git-layout-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeWorkspace(_ root: URL) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: nil
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "Luma Tests"
        environment["GIT_AUTHOR_EMAIL"] = "luma@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Luma Tests"
        environment["GIT_COMMITTER_EMAIL"] = "luma@example.invalid"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let error = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitRepositoryLayoutTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(error)"]
            )
        }
        return output
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
