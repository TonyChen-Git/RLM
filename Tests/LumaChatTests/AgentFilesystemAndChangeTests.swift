import Darwin
import Foundation
import XCTest
@testable import LumaChat

final class AgentFilesystemAndChangeTests: XCTestCase {
    func testReadRangesBinaryGuardEditDiffAndUndo() async throws {
        let root = try makeWorkspaceRoot("filesystem")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/example.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: source)
        try Data([0, 1, 2, 3, 4]).write(to: root.appendingPathComponent("image.bin"))

        let workspace = makeWorkspace(root)
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)

        let range = try files.readFile(path: "Sources/example.swift", startLine: 2, endLine: 3)
        XCTAssertEqual(range.content, "two\nthree\n")
        XCTAssertEqual(range.startLine, 2)
        XCTAssertEqual(range.endLine, 3)

        let binary = try files.readFile(path: "image.bin")
        XCTAssertTrue(binary.isBinary)
        XCTAssertNil(binary.content)
        XCTAssertThrowsError(try files.readFile(path: "../outside.txt"))

        let taskID = UUID()
        let edit = try await files.editFile(
            path: "Sources/example.swift",
            exactText: "two\nthree",
            replacement: "TWO\nTHREE",
            taskID: taskID
        )
        XCTAssertTrue(edit.change.diffs.first?.diff.contains("-two") == true)
        XCTAssertTrue(edit.change.diffs.first?.diff.contains("+TWO") == true)
        XCTAssertTrue(try String(contentsOf: source, encoding: .utf8).contains("TWO"))

        _ = try await changes.undoLast()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "one\ntwo\nthree\nfour\n")
    }

    func testUnifiedPatchSupportsModifyCreateDeleteAndRejectsTraversal() async throws {
        let root = try makeWorkspaceRoot("patch")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("alpha\nbeta\n".utf8).write(to: root.appendingPathComponent("old.txt"))
        try Data("remove me\n".utf8).write(to: root.appendingPathComponent("delete.txt"))

        let workspace = makeWorkspace(root)
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let patch = """
        --- a/old.txt
        +++ b/old.txt
        @@ -1,2 +1,2 @@
         alpha
        -beta
        +gamma
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,1 @@
        +created
        --- a/delete.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -remove me
        """

        let result = try await files.applyPatch(patch, taskID: UUID())
        XCTAssertEqual(Set(result.paths), Set(["old.txt", "new.txt", "delete.txt"]))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("old.txt"), encoding: .utf8), "alpha\ngamma\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "created\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("delete.txt").path))

        XCTAssertThrowsError(
            try UnifiedDiffParser().parse("--- a/ok.txt\n+++ b/../escape.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n")
        )
    }

    func testSearchHonorsIgnoredDirectoriesAndResultLimit() throws {
        let root = try makeWorkspaceRoot("search")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/pkg"),
            withIntermediateDirectories: true
        )
        try Data("struct VisibleSymbol {}\n".utf8).write(
            to: root.appendingPathComponent("Sources/Visible.swift")
        )
        try Data("struct HiddenSymbol {}\n".utf8).write(
            to: root.appendingPathComponent("node_modules/pkg/Hidden.swift")
        )

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let search = WorkspaceSearchService(validator: validator)
        let symbols = try search.findSymbol(name: "VisibleSymbol", kind: .struct)
        XCTAssertEqual(symbols.matches.count, 1)
        XCTAssertEqual(symbols.matches.first?.path, "Sources/Visible.swift")

        let hidden = try search.grep(pattern: "HiddenSymbol")
        XCTAssertTrue(hidden.matches.isEmpty)
        let limited = try search.searchFiles(extension: "swift", maximumResults: 1)
        XCTAssertEqual(limited.matches.count, 1)
    }

    func testAncestorSymlinkSwapFailsClosedForEveryNativeMutation() async throws {
        let root = try makeWorkspaceRoot("ancestor-swap")
        let outside = try makeWorkspaceRoot("ancestor-swap-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let safe = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try Data("workspace\n".utf8).write(to: safe.appendingPathComponent("victim.txt"))
        try Data("outside\n".utf8).write(to: outside.appendingPathComponent("victim.txt"))
        try Data("local\n".utf8).write(to: root.appendingPathComponent("local.txt"))

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)

        // Swap the already-validated ancestor after both native boundaries have
        // pinned the workspace root. Every operation must reject the symlink
        // instead of reaching the outside directory.
        try FileManager.default.moveItem(
            at: safe,
            to: root.appendingPathComponent("displaced-safe", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(at: safe, withDestinationURL: outside)

        await assertAsyncThrows {
            _ = try await files.createFile(path: "safe/new.txt", content: "bad", taskID: UUID())
        }
        await assertAsyncThrows {
            _ = try await files.writeFile(path: "safe/victim.txt", content: "bad", taskID: UUID())
        }
        await assertAsyncThrows {
            _ = try await files.editFile(
                path: "safe/victim.txt",
                exactText: "outside",
                replacement: "bad",
                taskID: UUID()
            )
        }
        await assertAsyncThrows {
            _ = try await files.applyPatch(
                "--- a/safe/victim.txt\n+++ b/safe/victim.txt\n@@ -1,1 +1,1 @@\n-outside\n+bad\n",
                taskID: UUID()
            )
        }
        await assertAsyncThrows {
            _ = try await files.deleteFile(path: "safe/victim.txt", taskID: UUID())
        }
        await assertAsyncThrows {
            _ = try await files.moveFile(
                source: "local.txt",
                destination: "safe/moved.txt",
                taskID: UUID()
            )
        }
        await assertAsyncThrows {
            _ = try await files.copyFile(
                source: "local.txt",
                destination: "safe/copied.txt",
                taskID: UUID()
            )
        }
        await assertAsyncThrows {
            _ = try await files.createDirectory(path: "safe/new-directory", taskID: UUID())
        }

        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("victim.txt"), encoding: .utf8),
            "outside\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("moved.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("copied.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new-directory").path))
    }

    func testUndoAndTaskScopedUndoFailClosedAcrossSymlinkAndTaskBoundaries() async throws {
        let root = try makeWorkspaceRoot("undo-boundary")
        let outside = try makeWorkspaceRoot("undo-boundary-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let safe = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        try Data("before\n".utf8).write(to: safe.appendingPathComponent("value.txt"))
        try Data("outside\n".utf8).write(to: outside.appendingPathComponent("value.txt"))

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let firstTask = UUID()
        let secondTask = UUID()
        _ = try await files.writeFile(path: "safe/value.txt", content: "first\n", taskID: firstTask)
        _ = try await files.writeFile(path: "safe/value.txt", content: "second\n", taskID: secondTask)

        await assertAsyncThrows {
            _ = try await changes.undoLast(taskID: firstTask)
        }
        XCTAssertEqual(try String(contentsOf: safe.appendingPathComponent("value.txt"), encoding: .utf8), "second\n")

        try FileManager.default.moveItem(
            at: safe,
            to: root.appendingPathComponent("displaced-safe", isDirectory: true)
        )
        try FileManager.default.createSymbolicLink(at: safe, withDestinationURL: outside)
        await assertAsyncThrows {
            _ = try await changes.undoLast(taskID: secondTask)
        }
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("value.txt"), encoding: .utf8),
            "outside\n"
        )
    }

    func testUndoRefusesToOverwriteAUserChangeMadeAfterAgentCommit() async throws {
        let root = try makeWorkspaceRoot("undo-conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()

        _ = try await files.writeFile(path: "value.txt", content: "agent\n", taskID: taskID)
        try Data("user edit\n".utf8).write(to: file)

        await assertAsyncThrows {
            _ = try await changes.undoLast(taskID: taskID)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user edit\n")
    }

    func testSpecificUndoRequiresExactLatestTaskAndChangeIdentity() async throws {
        let root = try makeWorkspaceRoot("specific-undo")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()

        let first = try await files.writeFile(
            path: "value.txt",
            content: "first\n",
            taskID: taskID
        ).change
        let second = try await files.writeFile(
            path: "value.txt",
            content: "second\n",
            taskID: taskID
        ).change

        do {
            _ = try await changes.undoSpecific(taskID: taskID, changeID: first.id)
            XCTFail("An older change must not be restored through a newer change")
        } catch let error as ChangeManagerError {
            guard case .changeNotLatest(let changeID) = error,
                  changeID == first.id else {
                return XCTFail("Unexpected non-latest error: \(error)")
            }
        }
        do {
            _ = try await changes.undoSpecific(taskID: UUID(), changeID: second.id)
            XCTFail("A change must not be disposed by another task")
        } catch let error as ChangeManagerError {
            guard case .changeIdentityMismatch = error else {
                return XCTFail("Unexpected identity error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second\n")

        let undoneSecond = try await changes.undoSpecific(taskID: taskID, changeID: second.id)
        XCTAssertEqual(undoneSecond, second)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\n")
        let undoneFirst = try await changes.undoSpecific(taskID: taskID, changeID: first.id)
        XCTAssertEqual(undoneFirst, first)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")
    }

    func testKeepSpecificDropsOnlyLatestSnapshotWithoutChangingWorkspace() async throws {
        let root = try makeWorkspaceRoot("specific-keep")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try Data("first-before\n".utf8).write(to: firstFile)
        try Data("second-before\n".utf8).write(to: secondFile)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()

        let first = try await files.writeFile(
            path: "first.txt",
            content: "first-agent\n",
            taskID: taskID
        ).change
        let second = try await files.writeFile(
            path: "second.txt",
            content: "second-agent\n",
            taskID: taskID
        ).change

        do {
            _ = try await changes.keepSpecific(taskID: taskID, changeID: first.id)
            XCTFail("An older snapshot must not be kept through a newer change")
        } catch let error as ChangeManagerError {
            guard case .changeNotLatest(let changeID) = error,
                  changeID == first.id else {
                return XCTFail("Unexpected non-latest error: \(error)")
            }
        }
        let keptSecond = try await changes.keepSpecific(taskID: taskID, changeID: second.id)
        XCTAssertEqual(keptSecond, second)
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "second-agent\n")
        let recordsAfterKeep = await changes.records()
        XCTAssertEqual(recordsAfterKeep, [first])

        _ = try await changes.undoSpecific(taskID: taskID, changeID: first.id)
        XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), "first-before\n")
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "second-agent\n")
    }

    func testKeepSpecificPersistenceFailureLeavesInMemoryHistoryRetryable() async throws {
        try AppPaths.ensureAgentDirectories()
        let fixtureID = UUID()
        let root = try makeWorkspaceRoot("specific-keep-persistence")
        let historyDirectory = AppPaths.agentSnapshots.appendingPathComponent(
            "specific-keep-persistence-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: validator.secureRootPath
        )
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()
        let record = try await files.writeFile(
            path: "value.txt",
            content: "agent\n",
            taskID: taskID
        ).change

        try FileManager.default.removeItem(at: historyDirectory)
        try Data("blocks-directory-recreation".utf8).write(to: historyDirectory)
        await assertAsyncThrows {
            _ = try await changes.keepSpecific(taskID: taskID, changeID: record.id)
        }
        let recordsAfterFailure = await changes.records()
        XCTAssertEqual(recordsAfterFailure, [record])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "agent\n")

        try FileManager.default.removeItem(at: historyDirectory)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let keptRecord = try await changes.keepSpecific(taskID: taskID, changeID: record.id)
        XCTAssertEqual(keptRecord, record)
        let recordsAfterRetry = await changes.records()
        XCTAssertTrue(recordsAfterRetry.isEmpty)
    }

    func testParameterlessUndoPersistenceFailureCompensatesAndRemainsRetryable() async throws {
        try AppPaths.ensureAgentDirectories()
        let fixtureID = UUID()
        let root = try makeWorkspaceRoot("undo-save-failure")
        let historyDirectory = AppPaths.agentSnapshots.appendingPathComponent(
            "undo-save-failure-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: validator.secureRootPath
        )
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let record = try await files.writeFile(
            path: "value.txt",
            content: "agent\n",
            taskID: UUID()
        ).change

        try FileManager.default.removeItem(at: historyDirectory)
        try Data("blocks-directory-recreation".utf8).write(to: historyDirectory)
        do {
            _ = try await changes.undoLast()
            XCTFail("Undo must report that durable history could not be updated")
        } catch let error as ChangeManagerError {
            guard case .persistentHistoryUnavailable = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "agent\n")
        let recordsAfterFailedSave = await changes.records()
        XCTAssertEqual(recordsAfterFailedSave, [record])

        try FileManager.default.removeItem(at: historyDirectory)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let retried = try await changes.undoLast()
        XCTAssertEqual(retried, record)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")
        let recordsAfterRetry = await changes.records()
        XCTAssertTrue(recordsAfterRetry.isEmpty)
    }

    func testSpecificUndoPreservesCompareAndSwapConflictGuard() async throws {
        let root = try makeWorkspaceRoot("specific-undo-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()
        let record = try await files.writeFile(
            path: "value.txt",
            content: "agent\n",
            taskID: taskID
        ).change
        try Data("user\n".utf8).write(to: file)

        do {
            _ = try await changes.undoSpecific(taskID: taskID, changeID: record.id)
            XCTFail("Specific Undo must preserve the post-edit CAS guard")
        } catch let error as ChangeManagerError {
            guard case .undoConflict = error else {
                return XCTFail("Unexpected CAS error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user\n")
        let recordsAfterConflict = await changes.records()
        XCTAssertEqual(recordsAfterConflict, [record])
    }

    func testHostRuntimeRootsAreHiddenFromWorkspaceReadListAndSearch() throws {
        try AppPaths.ensureAgentDirectories()
        let marker = "runtime-secret-\(UUID().uuidString)"
        let artifact = AppPaths.agentArtifacts.appendingPathComponent(
            "workspace-protection-\(UUID().uuidString).txt"
        )
        let alias = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "runtime-alias-\(UUID().uuidString).txt"
        )
        try Data(marker.utf8).write(to: artifact)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: artifact)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: artifact)
        }

        let projectRoot = AppPaths.projectTemporaryRoot.deletingLastPathComponent()
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(projectRoot))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let search = WorkspaceSearchService(validator: validator)

        XCTAssertThrowsError(try files.readFile(path: artifact.path))
        let alternateCaseArtifact = AppPaths.agentArtifacts
            .deletingLastPathComponent()
            .appendingPathComponent("AGENT-ARTIFACTS", isDirectory: true)
            .appendingPathComponent(artifact.lastPathComponent)
        XCTAssertThrowsError(try files.readFile(path: alternateCaseArtifact.path))
        XCTAssertThrowsError(try validator.validate(path: alias.path, access: .read))
        XCTAssertThrowsError(try files.listDirectory(path: AppPaths.agentArtifacts.path))
        XCTAssertThrowsError(try validator.validate(path: "tmp", access: .write))

        let listing = try files.listDirectory(path: "tmp", depth: 2, includeHidden: true)
        XCTAssertFalse(listing.entries.contains { entry in
            let path = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            return path == "agent-artifacts"
                || path.hasPrefix("agent-artifacts/")
                || path == "tmp/agent-artifacts"
                || path.hasPrefix("tmp/agent-artifacts/")
        })
        let grep = try search.grep(path: ".", pattern: marker, isRegularExpression: false)
        XCTAssertTrue(grep.matches.isEmpty)
    }

    func testHostRuntimeDirectoryCannotBecomeAWorkspaceRoot() throws {
        try AppPaths.ensureAgentDirectories()
        let mcpRuntime = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "mcp-runtime",
            isDirectory: true
        )
        let nestedArtifact = AppPaths.agentArtifacts.appendingPathComponent(
            "workspace-root-rejection-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: mcpRuntime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedArtifact, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nestedArtifact) }

        for root in [
            AppPaths.projectTemporaryRoot,
            AppPaths.agentArtifacts,
            AppPaths.agentSnapshots,
            AppPaths.agentProcesses,
            AppPaths.agentLogs,
            mcpRuntime,
            nestedArtifact
        ] {
            XCTAssertThrowsError(
                try WorkspaceSecurityValidator(workspace: makeWorkspace(root)),
                "Host runtime root unexpectedly became a workspace: \(root.path)"
            )
        }
        let alternateCaseRuntimeRoot = AppPaths.agentArtifacts
            .deletingLastPathComponent()
            .appendingPathComponent("AGENT-ARTIFACTS", isDirectory: true)
        XCTAssertThrowsError(
            try WorkspaceSecurityValidator(workspace: makeWorkspace(alternateCaseRuntimeRoot))
        )
    }

    func testDescriptorTraversalHasDepthByteAndCancellationLimits() async throws {
        let root = try makeWorkspaceRoot("descriptor-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let io = try SecureWorkspaceIO(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )

        let oversized = root.appendingPathComponent("oversized.bin")
        try Data(repeating: 0x41, count: 2_048).write(to: oversized)
        XCTAssertThrowsError(try io.snapshot(path: "oversized.bin", maximumBytes: 1_024))

        var directory = root.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for index in 0...SecureWorkspaceIO.maximumTreeDepthForTesting {
            directory.appendPathComponent("d\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try io.snapshot(path: "deep", maximumBytes: 1_024 * 1_024))

        let cancelled = Task { () throws -> SecureWorkspaceEnumeration in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try io.enumerate(
                path: ".",
                maximumDepth: 20,
                maximumEntries: 1_000,
                includeHidden: true
            )
        }
        await assertAsyncThrows {
            _ = try await cancelled.value
        }
    }

    func testPinnedRootIdentityRejectsDirectoryReplacementAfterValidation() throws {
        let root = try makeWorkspaceRoot("root-identity")
        let displaced = root.deletingLastPathComponent().appendingPathComponent(
            "displaced-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: displaced)
        }
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))

        try FileManager.default.moveItem(at: root, to: displaced)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SecureWorkspaceIO(validator: validator))
    }

    func testSecureReadIdentityRejectsSameLengthRewriteAndEveryMutationSignal() throws {
        let root = try makeWorkspaceRoot("read-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("same-length.txt")
        try Data("original".utf8).write(to: file)

        let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var initial = Darwin.stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &initial), 0)
        XCTAssertTrue(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: initial))

        var changed = initial
        changed.st_dev &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_ino &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_size &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_mtimespec.tv_sec &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_mtimespec.tv_nsec &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_ctimespec.tv_sec &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        changed = initial
        changed.st_ctimespec.tv_nsec &+= 1
        XCTAssertFalse(SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: changed))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: file.path
        )
        XCTAssertEqual(Darwin.fstat(descriptor, &initial), 0)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seek(toOffset: 0)
        try writer.write(contentsOf: Data("replaced".utf8))
        try writer.synchronize()
        try writer.close()

        var rewritten = Darwin.stat()
        XCTAssertEqual(Darwin.fstat(descriptor, &rewritten), 0)
        XCTAssertEqual(initial.st_dev, rewritten.st_dev)
        XCTAssertEqual(initial.st_ino, rewritten.st_ino)
        XCTAssertEqual(initial.st_size, rewritten.st_size)
        XCTAssertFalse(
            SecureWorkspaceIO.hasStableReadIdentity(initial: initial, final: rewritten),
            "An in-place same-length rewrite must be detected by nanosecond mtime/ctime."
        )
    }

    func testBuiltinToolsRegisterDynamicallyAndExecuteAgainstContextWorkspace() async throws {
        let root = try makeWorkspaceRoot("registry")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("hello.txt"))

        let registry = ToolRegistry()
        let todoManager = TodoManager()
        try await BuiltinToolFactory.register(in: registry, todoManager: todoManager)
        let metadata = await registry.allMetadata()
        let names = Set(metadata.map(\.name))
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("run_command"))
        XCTAssertTrue(names.contains("git_status"))
        XCTAssertTrue(names.contains("todo_create"))
        let pushTool = await registry.tool(named: "git_push")
        XCTAssertNotNil(pushTool)
        let pushMetadata = metadata.first(where: { $0.name == "git_push" })
        XCTAssertEqual(pushMetadata?.permissionLevel, .dangerous)
        XCTAssertEqual(pushMetadata?.requiresNetwork, true)

        let workspace = makeWorkspace(root)
        let context = AgentToolContext(sessionID: UUID(), mode: .agent, workspace: workspace)
        let registeredReadTool = await registry.tool(named: "read_file")
        let readTool = try XCTUnwrap(registeredReadTool)
        let result = try await readTool.execute(
            arguments: .object(["path": .string("hello.txt")]),
            context: context
        )
        XCTAssertEqual(result.content, "hello\n")
    }

    private func makeWorkspaceRoot(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-tests", isDirectory: true)
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
            gitRepository: false,
            branch: nil
        )
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected: the descriptor boundary failed closed.
        }
    }
}
