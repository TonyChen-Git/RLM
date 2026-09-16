import Foundation
import XCTest

@testable import LumaChat

private actor AgentTurnFinalizationMutationProbe {
    enum Behavior: Sendable {
        case replaceOnce(Data)
        case toggle(Data, Data)
    }

    private let file: URL
    private let behavior: Behavior
    private var callCount = 0

    init(file: URL, behavior: Behavior) {
        self.file = file
        self.behavior = behavior
    }

    func crossBoundary(attempt: Int) throws {
        callCount += 1
        switch behavior {
        case .replaceOnce(let replacement):
            if attempt == 0 { try replacement.write(to: file) }
        case .toggle(let first, let second):
            try (attempt.isMultiple(of: 2) ? second : first).write(to: file)
        }
    }

    func calls() -> Int { callCount }
}

final class AdvancedGitServiceTests: XCTestCase {
    func testSafetyTableAndRegisteredToolsRequireCorrectApprovalAndNetworkCapabilities() async throws {
        XCTAssertEqual(GitOperation.fetch.safety, .networkRead)
        XCTAssertEqual(GitOperation.fetch.safety.permissionLevel, .network)
        XCTAssertTrue(GitOperation.fetch.safety.requiresNetwork)
        for operation in [
            GitOperation.pull, .push, .rebase, .deleteBranch, .switchBranch,
            .hardReset, .mergeAbort, .rebaseContinue, .rebaseAbort,
            .cherryPickAbort, .stashDrop, .deleteTag, .removeRemote
        ] {
            XCTAssertTrue(operation.safety.requiresExplicitApproval, operation.rawValue)
        }
        XCTAssertEqual(GitOperation.merge.safety, .localMutation)
        XCTAssertEqual(GitOperation.mergeContinue.safety, .localMutation)
        XCTAssertEqual(GitOperation.cherryPickContinue.safety, .localMutation)
        XCTAssertFalse(GitOperation.merge.safety.requiresNetwork)

        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(in: registry, todoManager: TodoManager())
        let expected: [String: (AgentPermissionLevel, Bool)] = [
            "git_fetch": (.network, true),
            "git_pull": (.dangerous, true),
            "git_push": (.dangerous, true),
            "git_switch_branch": (.dangerous, false),
            "git_delete_branch": (.dangerous, false),
            "git_reset_hard": (.dangerous, false),
            "git_merge": (.write, false),
            "git_merge_continue": (.write, false),
            "git_merge_abort": (.dangerous, false),
            "git_rebase": (.dangerous, false),
            "git_rebase_continue": (.dangerous, false),
            "git_rebase_abort": (.dangerous, false),
            "git_cherry_pick": (.write, false),
            "git_cherry_pick_continue": (.write, false),
            "git_cherry_pick_abort": (.dangerous, false),
            "git_stash_push": (.write, false),
            "git_stash_apply": (.write, false),
            "git_stash_drop": (.dangerous, false),
            "git_create_tag": (.write, false),
            "git_delete_tag": (.dangerous, false),
            "git_add_remote": (.dangerous, false),
            "git_remove_remote": (.dangerous, false)
        ]
        for (name, expectedMetadata) in expected {
            let registered = await registry.metadata(named: name)
            let metadata = try XCTUnwrap(registered, name)
            XCTAssertEqual(metadata.permissionLevel, expectedMetadata.0, name)
            XCTAssertEqual(metadata.requiresNetwork, expectedMetadata.1, name)
        }

        let registeredPush = await registry.metadata(named: "git_push")
        let pushMetadata = try XCTUnwrap(registeredPush)
        let workspace = AgentWorkspace(
            name: "approval-fixture",
            rootPath: AppPaths.projectTemporaryRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            networkAccess: true
        )
        let authorization = await PermissionManager().authorize(
            metadata: pushMetadata,
            call: AgentToolCall(
                name: "git_push",
                arguments: .object([
                    "remote": .string("origin"),
                    "force_with_lease": .bool(false)
                ])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: true
        )
        guard case .requireApproval(let level, _) = authorization else {
            return XCTFail("remote mutation must require approval even in Full Access")
        }
        XCTAssertEqual(level, .dangerous)
    }

    func testReviewSourceReadsCompleteArtifactAndIncludesUntrackedFiles() async throws {
        let root = try makeRepository("review-complete-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "MIDDLE-OF-COMPLETE-REVIEW-ARTIFACT"
        let lines = (0..<12_000).map { index in
            index == 6_000 ? marker : "changed line \(index)"
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("seed.txt"))
        try Data("untracked review content\n".utf8).write(
            to: root.appendingPathComponent("Untracked.txt")
        )

        let result = try await makeService(root).reviewSource(for: .unstaged)
        let document = try ReviewDiffParser().parse(result.output, source: .unstaged)

        XCTAssertTrue(result.output.contains(marker))
        XCTAssertEqual(Set(document.files.map(\.displayPath)), ["seed.txt", "Untracked.txt"])
        XCTAssertEqual(document.files.first(where: { $0.displayPath == "Untracked.txt" })?.isUntracked, true)
    }

    func testTrackedBinaryDeletionFallbackStagesUnstagesRevertsAndRemainsUndoable() async throws {
        let root = try makeRepository("review-deleted-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = Data([0x00, 0xff, 0x10, 0x80, 0x42])
        let file = root.appendingPathComponent("Binary.dat")
        try binary.write(to: file)
        try runGit(["add", "Binary.dat"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "binary"], at: root)
        try FileManager.default.removeItem(at: file)

        let workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let changes = ChangeManager(validator: validator)
        let service = try GitService(
            validator: validator,
            terminal: TerminalSession(validator: validator),
            changes: changes,
            timeout: 20
        )
        let taskID = UUID()

        let unstaged = try await service.reviewSource(for: .unstaged)
        var fileDiff = try XCTUnwrap(
            ReviewDiffParser().parse(unstaged.output, source: .unstaged).files.first
        )
        XCTAssertEqual(fileDiff.change, .deleted)
        XCTAssertEqual(fileDiff.fallback, .binary)
        var selection = ReviewPatchSelection(
            fileID: fileDiff.id,
            fileFingerprint: fileDiff.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        let staged = try await service.applyReviewFileMutation(
            .stage,
            source: .unstaged,
            path: "Binary.dat",
            selection: selection,
            taskID: taskID
        )
        XCTAssertNotNil(staged.change)

        let stagedSource = try await service.reviewSource(for: .staged)
        fileDiff = try XCTUnwrap(
            ReviewDiffParser().parse(stagedSource.output, source: .staged).files.first
        )
        selection = ReviewPatchSelection(
            fileID: fileDiff.id,
            fileFingerprint: fileDiff.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        let unstagedAgain = try await service.applyReviewFileMutation(
            .unstage,
            source: .staged,
            path: "Binary.dat",
            selection: selection,
            taskID: taskID
        )
        XCTAssertNotNil(unstagedAgain.change)

        let refreshed = try await service.reviewSource(for: .unstaged)
        fileDiff = try XCTUnwrap(
            ReviewDiffParser().parse(refreshed.output, source: .unstaged).files.first
        )
        selection = ReviewPatchSelection(
            fileID: fileDiff.id,
            fileFingerprint: fileDiff.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        let reverted = try await service.applyReviewFileMutation(
            .revert,
            source: .unstaged,
            path: "Binary.dat",
            selection: selection,
            taskID: taskID
        )
        XCTAssertNotNil(reverted.change)
        XCTAssertEqual(try Data(contentsOf: file), binary)

        _ = try await changes.undoLast(taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLargeUntrackedFileUsesStreamingIdentityFallbackBeyondFormer64MiBLimit() async throws {
        let root = try makeRepository("review-large-untracked")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(65 * 1_024 * 1_024 + 1))
        try handle.close()

        let result = try await makeService(root).reviewSource(for: .unstaged)
        let parsed = try ReviewDiffParser().parse(result.output, source: .unstaged)
        let large = try XCTUnwrap(parsed.files.first(where: { $0.displayPath == "Large.bin" }))

        XCTAssertEqual(large.isUntracked, true)
        guard case .large(let byteCount, let limit) = large.fallback else {
            return XCTFail("Expected a large-file fallback")
        }
        XCTAssertEqual(byteCount, 65 * 1_024 * 1_024 + 1)
        XCTAssertEqual(limit, 2 * 1_024 * 1_024)
    }

    func testTransportOmittedTrackedLineGetsStableFallbackAndRejectsStaleAction() async throws {
        let root = try makeRepository("review-transport-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("HugeLine.txt")
        try Data("base\n".utf8).write(to: file)
        try runGit(["add", "HugeLine.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "huge line base"], at: root)
        try Data(String(repeating: "a", count: 3 * 1_024 * 1_024).utf8).write(to: file)

        let service = try makeService(root)
        let first = try await service.reviewSource(for: .unstaged)
        let firstFile = try XCTUnwrap(
            ReviewDiffParser().parse(first.output, source: .unstaged).files.first
        )
        XCTAssertNotNil(firstFile.fallback)
        XCTAssertTrue(first.output.contains("worktree-sha256="))
        XCTAssertFalse(first.output.contains("oversized terminal line omitted"))

        let stale = ReviewPatchSelection(
            fileID: firstFile.id,
            fileFingerprint: firstFile.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        try Data(String(repeating: "b", count: 3 * 1_024 * 1_024).utf8).write(to: file)
        do {
            _ = try await service.applyReviewFileMutation(
                .stage,
                source: .unstaged,
                path: "HugeLine.txt",
                selection: stale,
                taskID: UUID()
            )
            XCTFail("A changed fallback file must reject a stale identity")
        } catch let error as GitServiceError {
            guard case .unsafeReviewPatch = error else { throw error }
        }
    }

    func testLastAgentTurnBaselineIncludesShellWritesAndCommitsButExcludesPriorDirtyState() async throws {
        let root = try makeRepository("last-agent-turn")
        defer { try? FileManager.default.removeItem(at: root) }
        let dirty = root.appendingPathComponent("Dirty.txt")
        try Data("committed dirty base\n".utf8).write(to: dirty)
        try runGit(["add", "Dirty.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "dirty base"], at: root)

        try Data("dirty before turn\n".utf8).write(to: dirty)
        try Data("preexisting untracked\n".utf8).write(
            to: root.appendingPathComponent("Before.txt")
        )
        let service = try makeService(root)
        let sessionID = UUID()
        let captured = try await service.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: sessionID
        )
        let persisted = try JSONDecoder().decode(
            AgentTurnReviewBaseline.self,
            from: JSONEncoder().encode(captured)
        )

        try Data("seed changed and committed by agent\n".utf8).write(
            to: root.appendingPathComponent("seed.txt")
        )
        try Data("dirty after turn\n".utf8).write(to: dirty)
        try runGit(["add", "seed.txt", "Dirty.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "agent commit"], at: root)
        try Data("new untracked from shell\n".utf8).write(
            to: root.appendingPathComponent("After.txt")
        )

        let frozen = try await service.finalizeAgentTurnReviewSnapshot(since: persisted)
        let persistedSnapshot = try JSONDecoder().decode(
            AgentTurnReviewSnapshot.self,
            from: JSONEncoder().encode(frozen)
        )

        // Last Agent Turn is linearized at finalization. Later edits to the
        // checkout must not alter the already completed turn's Review source.
        try Data("post-run external edit\n".utf8).write(to: dirty)
        try Data("post-run only\n".utf8).write(
            to: root.appendingPathComponent("PostTurn.txt")
        )
        let result = try await service.reviewSource(from: persistedSnapshot)
        let document = try ReviewDiffParser().parse(
            result.output,
            source: .lastAgentTurn(taskID: sessionID)
        )
        XCTAssertEqual(Set(document.files.map(\.displayPath)), ["seed.txt", "Dirty.txt", "After.txt"])
        XCTAssertTrue(result.output.contains("-dirty before turn"))
        XCTAssertTrue(result.output.contains("+dirty after turn"))
        XCTAssertTrue(result.output.contains("seed changed and committed by agent"))
        XCTAssertFalse(result.output.contains("Before.txt"))
        XCTAssertFalse(result.output.contains("committed dirty base"))
        XCTAssertFalse(result.output.contains("post-run external edit"))
        XCTAssertFalse(result.output.contains("PostTurn.txt"))
    }

    func testLastAgentTurnFinalizationRetriesThenFreezesOneGloballyStableCheckout() async throws {
        let root = try makeRepository("last-agent-turn-stability-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("seed.txt")
        let replacement = Data("version-two\n".utf8)
        let probe = AgentTurnFinalizationMutationProbe(
            file: file,
            behavior: .replaceOnce(replacement)
        )
        let service = try makeService(root) { attempt in
            try await probe.crossBoundary(attempt: attempt)
        }
        let sessionID = UUID()
        let baseline = try await service.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: sessionID
        )
        try Data("version-one\n".utf8).write(to: file)

        let snapshot = try await service.finalizeAgentTurnReviewSnapshot(since: baseline)
        let result = try await service.reviewSource(from: snapshot)

        XCTAssertTrue(result.output.contains("version-two"))
        XCTAssertFalse(result.output.contains("version-one"))
        let retryBoundaryCount = await probe.calls()
        XCTAssertEqual(retryBoundaryCount, 2, "The first unstable pass must retry once")
    }

    func testLastAgentTurnFinalizationFailsClosedWhenCheckoutNeverQuiesces() async throws {
        let root = try makeRepository("last-agent-turn-stability-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("seed.txt")
        let first = Data("version-one\n".utf8)
        let second = Data("version-two\n".utf8)
        let probe = AgentTurnFinalizationMutationProbe(
            file: file,
            behavior: .toggle(first, second)
        )
        let service = try makeService(root) { attempt in
            try await probe.crossBoundary(attempt: attempt)
        }
        let baseline = try await service.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: UUID()
        )
        try first.write(to: file)

        do {
            _ = try await service.finalizeAgentTurnReviewSnapshot(since: baseline)
            XCTFail("A continuously changing checkout must never produce a mixed frozen source")
        } catch let error as GitServiceError {
            guard case .unsafeReviewSource(let detail) = error else { throw error }
            XCTAssertTrue(detail.contains("remained unstable"), detail)
        }
        let failedBoundaryCount = await probe.calls()
        XCTAssertEqual(failedBoundaryCount, 3)
    }

    func testLastAgentTurnFinalizationUsesContentIdentityWhenBinaryRenderIsUnchanged() async throws {
        let root = try makeRepository("last-agent-turn-binary-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: file)
        try runGit(["add", "blob.bin"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "binary seed"], at: root)

        let replacement = Data([0, 9, 8, 7])
        let probe = AgentTurnFinalizationMutationProbe(
            file: file,
            behavior: .replaceOnce(replacement)
        )
        let service = try makeService(root) { attempt in
            try await probe.crossBoundary(attempt: attempt)
        }
        let baseline = try await service.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: UUID()
        )
        try Data([0, 4, 5, 6]).write(to: file)

        let snapshot = try await service.finalizeAgentTurnReviewSnapshot(since: baseline)

        XCTAssertTrue(snapshot.source.contains("Binary files"), snapshot.source)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
        let boundaryCount = await probe.calls()
        XCTAssertEqual(
            boundaryCount,
            2,
            "Identical binary fallback text must not hide a content-identity change"
        )
    }

    func testCachedLastAgentTurnServiceRejectsWorkspaceRootReplacement() async throws {
        let root = try makeRepository("last-agent-turn-replaced-root")
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }

        let service = try makeService(root)
        let sessionID = UUID()
        let baseline = try await service.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: sessionID
        )
        try Data("agent edit\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        let snapshot = try await service.finalizeAgentTurnReviewSnapshot(since: baseline)

        // Keep the originally authorized inode alive at a different pathname,
        // then install a valid-looking repository at the old pathname. A
        // cached GitService must not combine its pinned descriptor with Git
        // subprocesses running in this replacement checkout.
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch=main"], at: root)
        try configureIdentity(at: root)
        try Data("replacement\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try runGit(["add", "seed.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "replacement"], at: root)

        do {
            _ = try await service.reviewSource(from: snapshot)
            XCTFail("A frozen snapshot must reject a replaced workspace root")
        } catch let error as GitServiceError {
            guard case .unsafeReviewSource = error else { throw error }
        }
        do {
            _ = try await service.finalizeAgentTurnReviewSnapshot(since: baseline)
            XCTFail("Finalization must reject a replaced workspace root")
        } catch let error as GitServiceError {
            guard case .unsafeReviewSource = error else { throw error }
        }
        do {
            _ = try await service.captureAgentTurnReviewBaseline(
                runID: UUID(),
                sessionID: sessionID
            )
            XCTFail("Baseline capture must reject a replaced workspace root")
        } catch let error as GitServiceError {
            guard case .unsafeReviewSource = error else { throw error }
        }
    }

    func testFetchPullAndPushUseOneValidatedLocalRemoteWithoutCredentialPrompts() async throws {
        let root = try makeRepository("remote-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["init", "--bare", "--initial-branch=main", "remote.git"], at: root)
        try appendGitExclude("remote.git/\nupdater/\n", at: root)
        try runGit(["remote", "add", "origin", "remote.git"], at: root)
        try runGit(["push", "--set-upstream", "origin", "main"], at: root)

        let updater = root.appendingPathComponent("updater", isDirectory: true)
        try runGit(["clone", "remote.git", "updater"], at: root)
        try configureIdentity(at: updater)
        try Data("from remote\n".utf8).write(
            to: updater.appendingPathComponent("remote-change.txt")
        )
        try runGit(["add", "remote-change.txt"], at: updater)
        try runGit(["commit", "--no-gpg-sign", "-m", "remote change"], at: updater)
        try runGit(["push", "origin", "main"], at: updater)

        let service = try makeService(root)
        let fetch = try await service.fetch(remote: "origin", branch: "main", taskID: UUID())
        XCTAssertEqual(fetch.exitCode, 0, fetch.output)
        XCTAssertNotNil(fetch.change)

        let pull = try await service.pull(
            remote: "origin",
            branch: "main",
            strategy: .fastForwardOnly,
            taskID: UUID()
        )
        XCTAssertEqual(pull.exitCode, 0, pull.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("remote-change.txt"), encoding: .utf8),
            "from remote\n"
        )

        try Data("from local\n".utf8).write(to: root.appendingPathComponent("local-change.txt"))
        _ = try await service.add(paths: ["local-change.txt"], taskID: UUID())
        _ = try await service.commit(message: "local change", taskID: UUID())
        let push = try await service.push(
            remote: "origin",
            branch: "main",
            destinationBranch: "main",
            setUpstream: true,
            forceWithLease: false,
            taskID: UUID()
        )
        XCTAssertEqual(push.exitCode, 0, push.output)
        XCTAssertTrue(push.output.contains("not covered by workspace Undo"), push.output)
        XCTAssertEqual(
            try runGit(["--git-dir", bare.path, "show", "main:local-change.txt"], at: root),
            "from local\n"
        )
    }

    func testPushValidatesDirectionalPushURLAndRejectsMultipleDestinations() async throws {
        let root = try makeRepository("pushurl-policy")
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--bare", "--initial-branch=main", "fetch.git"], at: root)
        try runGit(["init", "--bare", "--initial-branch=main", "push.git"], at: root)
        try runGit(["init", "--bare", "--initial-branch=main", "second.git"], at: root)
        try appendGitExclude("fetch.git/\npush.git/\nsecond.git/\n", at: root)
        try runGit(["remote", "add", "origin", "fetch.git"], at: root)
        try runGit(["config", "remote.origin.pushurl", "push.git"], at: root)

        let service = try makeService(root)
        let pushed = try await service.push(
            remote: "origin",
            branch: "main",
            destinationBranch: "main",
            taskID: UUID()
        )
        XCTAssertEqual(pushed.exitCode, 0, pushed.output)
        XCTAssertTrue(
            try runGit(["--git-dir", "push.git", "rev-parse", "main"], at: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count >= 40
        )

        try runGit(["config", "--add", "remote.origin.pushurl", "second.git"], at: root)
        do {
            _ = try await service.push(
                remote: "origin",
                branch: "main",
                destinationBranch: "main",
                taskID: UUID()
            )
            XCTFail("Multiple push URLs must be rejected before network mutation")
        } catch let error as GitServiceError {
            guard case .unsafeRemote = error else { throw error }
        }
    }

    func testBranchMergeRebaseCherryPickStashTagAndRemoteLifecycle() async throws {
        let root = try makeRepository("local-lifecycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)

        _ = try await service.createBranch(name: "feature", taskID: UUID())
        _ = try await service.switchBranch(name: "feature", taskID: UUID())
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature.txt"))
        _ = try await service.add(paths: ["feature.txt"], taskID: UUID())
        _ = try await service.commit(message: "feature", taskID: UUID())
        let branchReview = try await service.diff(
            baseRevision: "main",
            headRevision: "feature"
        )
        XCTAssertTrue(branchReview.output.contains("feature.txt"), branchReview.output)
        _ = try await service.switchBranch(name: "main", taskID: UUID())
        let merge = try await service.merge(reference: "feature", taskID: UUID())
        XCTAssertEqual(merge.exitCode, 0, merge.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("feature.txt"), encoding: .utf8),
            "feature\n"
        )
        _ = try await service.deleteBranch(name: "feature", taskID: UUID())

        _ = try await service.createBranch(name: "rebase-topic", taskID: UUID())
        _ = try await service.switchBranch(name: "rebase-topic", taskID: UUID())
        try Data("rebased\n".utf8).write(to: root.appendingPathComponent("rebased.txt"))
        _ = try await service.add(paths: ["rebased.txt"], taskID: UUID())
        _ = try await service.commit(message: "topic", taskID: UUID())
        _ = try await service.switchBranch(name: "main", taskID: UUID())
        try Data("main advanced\n".utf8).write(to: root.appendingPathComponent("main.txt"))
        _ = try await service.add(paths: ["main.txt"], taskID: UUID())
        _ = try await service.commit(message: "advance main", taskID: UUID())
        _ = try await service.switchBranch(name: "rebase-topic", taskID: UUID())
        let rebase = try await service.rebase(onto: "main", taskID: UUID())
        XCTAssertEqual(rebase.exitCode, 0, rebase.output)
        try runGit(["merge-base", "--is-ancestor", "main", "rebase-topic"], at: root)

        _ = try await service.switchBranch(name: "main", taskID: UUID())
        let cherryPick = try await service.cherryPick(
            reference: "rebase-topic",
            taskID: UUID()
        )
        XCTAssertEqual(cherryPick.exitCode, 0, cherryPick.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rebased.txt").path))
        // Cherry-picking the rebased tip creates a distinct commit identity,
        // so Git correctly considers the source branch unmerged even though
        // its patch is present on main. Exercise the explicit dangerous force
        // path rather than expecting `git branch -d` to bypass that invariant.
        _ = try await service.deleteBranch(
            name: "rebase-topic",
            force: true,
            taskID: UUID()
        )

        let createTag = try await service.createTag(
            name: "v-test",
            message: "test tag",
            taskID: UUID()
        )
        XCTAssertEqual(createTag.exitCode, 0, createTag.output)
        let tagsAfterCreate = try await service.tags()
        XCTAssertTrue(tagsAfterCreate.output.contains("v-test"))
        _ = try await service.deleteTag(name: "v-test", taskID: UUID())
        let tagsAfterDelete = try await service.tags()
        XCTAssertFalse(tagsAfterDelete.output.contains("v-test"))

        try Data("seed changed\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let stash = try await service.stashPush(
            message: "test stash",
            includeUntracked: true,
            taskID: UUID()
        )
        XCTAssertEqual(stash.exitCode, 0, stash.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("untracked.txt").path))
        let stashList = try await service.stashList()
        XCTAssertTrue(stashList.output.contains("test stash"))
        let apply = try await service.stashApply(taskID: UUID())
        XCTAssertEqual(apply.exitCode, 0, apply.output)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("seed.txt"), encoding: .utf8),
            "seed changed\n"
        )
        _ = try await service.stashDrop(taskID: UUID())

        try FileManager.default.removeItem(at: root.appendingPathComponent("untracked.txt"))
        _ = try await service.restore(paths: ["seed.txt"], source: "HEAD", taskID: UUID())

        try runGit(["init", "--bare", "--initial-branch=main", "secondary.git"], at: root)
        try appendGitExclude("secondary.git/\n", at: root)
        _ = try await service.addRemote(
            name: "secondary",
            url: "secondary.git",
            taskID: UUID()
        )
        let remotesAfterAdd = try await service.remotes()
        XCTAssertTrue(remotesAfterAdd.output.contains("secondary"))
        _ = try await service.removeRemote(name: "secondary", taskID: UUID())
        let remotesAfterRemove = try await service.remotes()
        XCTAssertFalse(remotesAfterRemove.output.contains("secondary"))
    }

    func testConflictStateIsRecordedAndUnsafeReferencesAndCredentialURLsFailClosed() async throws {
        let root = try makeRepository("conflict")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)

        _ = try await service.createBranch(name: "conflict-topic", taskID: UUID())
        _ = try await service.switchBranch(name: "conflict-topic", taskID: UUID())
        try Data("topic\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        _ = try await service.add(paths: ["seed.txt"], taskID: UUID())
        _ = try await service.commit(message: "topic conflict", taskID: UUID())
        _ = try await service.switchBranch(name: "main", taskID: UUID())
        try Data("main\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        _ = try await service.add(paths: ["seed.txt"], taskID: UUID())
        _ = try await service.commit(message: "main conflict", taskID: UUID())

        let conflict = try await service.merge(reference: "conflict-topic", taskID: UUID())
        XCTAssertNotEqual(conflict.exitCode, 0)
        XCTAssertNotNil(conflict.change, "conflict mutations must remain undo-visible")
        let conflictStatus = try await service.status()
        XCTAssertTrue(conflictStatus.output.contains("UU seed.txt"))

        do {
            _ = try await service.createBranch(name: "--upload-pack=hostile", taskID: UUID())
            XCTFail("option-like branch should be rejected")
        } catch GitServiceError.invalidReference {
            // Expected.
        }
        do {
            _ = try await service.addRemote(
                name: "credential-leak",
                url: "https://opaque-token@example.com/org/repository.git",
                taskID: UUID()
            )
            XCTFail("credential-bearing URLs should be rejected")
        } catch GitServiceError.unsafeRemote {
            // Expected.
        }
        let remotes = try await service.remotes()
        XCTAssertFalse(remotes.output.contains("credential-leak"))
    }

    func testHardResetSnapshotsTrackedIndexRefAndUntrackedObstructionAndDeniedApprovalDoesNothing() async throws {
        let root = try makeRepository("hard-reset")
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["switch", "--create", "reset-target"], at: root)
        try Data("target\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("target child\n".utf8).write(
            to: root.appendingPathComponent("nested/child.txt")
        )
        try runGit(["add", "seed.txt", "nested/child.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "reset target"], at: root)
        let target = try runGit(["rev-parse", "HEAD"], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["switch", "main"], at: root)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("nested").path) {
            try FileManager.default.removeItem(at: root.appendingPathComponent("nested"))
        }
        try Data("untracked obstruction\n".utf8).write(
            to: root.appendingPathComponent("nested")
        )
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try Data("staged only\n".utf8).write(to: root.appendingPathComponent("staged.txt"))
        try runGit(["add", "staged.txt"], at: root)

        let service = try makeService(root)
        let reset = try await service.hardReset(reference: target, taskID: UUID())
        XCTAssertEqual(reset.exitCode, 0, reset.output)
        let change = try XCTUnwrap(reset.change, "hard reset must remain Undo-visible")
        XCTAssertTrue(change.paths.contains("seed.txt"), change.paths.joined(separator: ", "))
        XCTAssertTrue(change.paths.contains("staged.txt"), change.paths.joined(separator: ", "))
        XCTAssertTrue(change.paths.contains("nested"), change.paths.joined(separator: ", "))
        XCTAssertTrue(change.paths.contains(".git/index"))
        XCTAssertTrue(change.paths.contains(".git/HEAD"))
        XCTAssertTrue(change.paths.contains(".git/refs/heads/main"))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("seed.txt"), encoding: .utf8),
            "target\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("nested/child.txt"),
                encoding: .utf8
            ),
            "target child\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staged.txt").path))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines), target)

        // Dangerous tools remain approval-gated even in Full Access. Treating
        // the approval sheet's Cancel as deny must leave both ref and files as-is.
        try Data("must survive denial\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        let secretReference = "sk-abcdefgh12345678"
        try runGit(["branch", secretReference, "HEAD"], at: root)
        let headBeforeDenial = try runGit(["rev-parse", "HEAD"], at: root)
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: BuiltinToolEnvironment(),
            todoManager: TodoManager()
        )
        let executor = ToolExecutor(registry: registry)
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: root.lastPathComponent,
                rootPath: root.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: true,
                branch: "main"
            )
        )
        let denied = try await executor.execute(
            AgentToolCall(
                name: "git_reset_hard",
                arguments: .object(["reference": .string(secretReference)])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: { request in
                XCTAssertEqual(request.permissionLevel, .dangerous)
                XCTAssertEqual(request.toolName, "git_reset_hard")
                XCTAssertEqual(request.arguments["reference"]?.stringValue, "[REDACTED]")
                return .deny
            }
        )
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.contains("使用者拒絕"), denied.content)
        XCTAssertFalse(denied.content.contains(secretReference))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], at: root), headBeforeDenial)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("seed.txt"), encoding: .utf8),
            "must survive denial\n"
        )
    }

    func testMergeConflictContinueFailureRecoveryAndAbortAreStateBoundedAndUndoVisible() async throws {
        let continueRoot = try makeRepository("merge-continue")
        defer { try? FileManager.default.removeItem(at: continueRoot) }
        try prepareConflictBranches(at: continueRoot, topic: "merge-topic")
        try configureHostileEditors(at: continueRoot)
        let continueService = try makeService(continueRoot)
        let conflict = try await continueService.merge(reference: "merge-topic", taskID: UUID())
        XCTAssertNotEqual(conflict.exitCode, 0)
        XCTAssertNotNil(conflict.change)

        let unresolved = try await continueService.mergeContinue(taskID: UUID())
        XCTAssertNotEqual(unresolved.exitCode, 0)
        XCTAssertFalse(unresolved.output.isEmpty)
        XCTAssertNotNil(unresolved.change, "failed continuation must preserve an Undo/diagnostic record")
        let unresolvedStatus = try await continueService.status()
        XCTAssertTrue(unresolvedStatus.output.contains("UU seed.txt"))

        try Data("resolved merge\n".utf8).write(to: continueRoot.appendingPathComponent("seed.txt"))
        _ = try await continueService.add(paths: ["seed.txt"], taskID: UUID())
        let continued = try await continueService.mergeContinue(taskID: UUID())
        XCTAssertEqual(continued.exitCode, 0, continued.output)
        XCTAssertNotNil(continued.change)
        XCTAssertEqual(
            try runGit(["rev-list", "--parents", "--max-count=1", "HEAD"], at: continueRoot)
                .split(separator: " ").count,
            3,
            "merge continuation must create a two-parent commit without opening an editor"
        )

        let abortRoot = try makeRepository("merge-abort")
        defer { try? FileManager.default.removeItem(at: abortRoot) }
        try prepareConflictBranches(at: abortRoot, topic: "merge-topic")
        let abortService = try makeService(abortRoot)
        _ = try await abortService.merge(reference: "merge-topic", taskID: UUID())
        do {
            _ = try await abortService.cherryPickAbort(taskID: UUID())
            XCTFail("a cherry-pick abort must not consume merge state")
        } catch GitServiceError.operationStateMismatch(let expected, let active) {
            XCTAssertEqual(expected, "cherry-pick")
            XCTAssertEqual(active, ["merge"])
        }
        let wrongAbortStatus = try await abortService.status()
        XCTAssertTrue(wrongAbortStatus.output.contains("UU seed.txt"))
        let aborted = try await abortService.mergeAbort(taskID: UUID())
        XCTAssertEqual(aborted.exitCode, 0, aborted.output)
        XCTAssertNotNil(aborted.change)
        XCTAssertEqual(
            try String(contentsOf: abortRoot.appendingPathComponent("seed.txt"), encoding: .utf8),
            "main\n"
        )
        let mergeAbortedStatus = try await abortService.status()
        XCTAssertFalse(mergeAbortedStatus.output.contains("UU"))
    }

    func testRebaseConflictContinueAndAbortUseExactStateAndNeverOpenConfiguredEditors() async throws {
        let continueRoot = try makeRepository("rebase-continue")
        defer { try? FileManager.default.removeItem(at: continueRoot) }
        try prepareRebaseConflict(at: continueRoot, topic: "rebase-topic")
        try configureHostileEditors(at: continueRoot)
        let continueService = try makeService(continueRoot)
        let conflict = try await continueService.rebase(onto: "main", taskID: UUID())
        XCTAssertNotEqual(conflict.exitCode, 0)
        XCTAssertNotNil(conflict.change)
        do {
            _ = try await continueService.mergeContinue(taskID: UUID())
            XCTFail("merge continuation must not consume rebase state")
        } catch GitServiceError.operationStateMismatch(let expected, let active) {
            XCTAssertEqual(expected, "merge")
            XCTAssertEqual(active, ["rebase"])
        }

        try Data("resolved rebase\n".utf8).write(to: continueRoot.appendingPathComponent("seed.txt"))
        _ = try await continueService.add(paths: ["seed.txt"], taskID: UUID())
        let continued = try await continueService.rebaseContinue(taskID: UUID())
        XCTAssertEqual(continued.exitCode, 0, continued.output)
        XCTAssertNotNil(continued.change)
        XCTAssertEqual(
            try String(contentsOf: continueRoot.appendingPathComponent("seed.txt"), encoding: .utf8),
            "resolved rebase\n"
        )
        XCTAssertEqual(
            try runGit(["branch", "--show-current"], at: continueRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "rebase-topic"
        )

        let abortRoot = try makeRepository("rebase-abort")
        defer { try? FileManager.default.removeItem(at: abortRoot) }
        try prepareRebaseConflict(at: abortRoot, topic: "rebase-topic")
        let abortService = try makeService(abortRoot)
        _ = try await abortService.rebase(onto: "main", taskID: UUID())
        let aborted = try await abortService.rebaseAbort(taskID: UUID())
        XCTAssertEqual(aborted.exitCode, 0, aborted.output)
        XCTAssertNotNil(aborted.change)
        XCTAssertEqual(
            try String(contentsOf: abortRoot.appendingPathComponent("seed.txt"), encoding: .utf8),
            "topic\n"
        )
        XCTAssertEqual(
            try runGit(["branch", "--show-current"], at: abortRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "rebase-topic"
        )
    }

    func testCherryPickConflictContinueAndAbortAreStateBoundedAndUndoVisible() async throws {
        let continueRoot = try makeRepository("cherry-continue")
        defer { try? FileManager.default.removeItem(at: continueRoot) }
        let commit = try prepareCherryPickConflict(at: continueRoot, topic: "cherry-topic")
        try configureHostileEditors(at: continueRoot)
        let continueService = try makeService(continueRoot)
        let conflict = try await continueService.cherryPick(reference: commit, taskID: UUID())
        XCTAssertNotEqual(conflict.exitCode, 0)
        XCTAssertNotNil(conflict.change)
        let unresolved = try await continueService.cherryPickContinue(taskID: UUID())
        XCTAssertNotEqual(unresolved.exitCode, 0)
        XCTAssertFalse(unresolved.output.isEmpty)
        XCTAssertNotNil(unresolved.change)

        try Data("resolved cherry\n".utf8).write(to: continueRoot.appendingPathComponent("seed.txt"))
        _ = try await continueService.add(paths: ["seed.txt"], taskID: UUID())
        let continued = try await continueService.cherryPickContinue(taskID: UUID())
        XCTAssertEqual(continued.exitCode, 0, continued.output)
        XCTAssertNotNil(continued.change)
        XCTAssertEqual(
            try String(contentsOf: continueRoot.appendingPathComponent("seed.txt"), encoding: .utf8),
            "resolved cherry\n"
        )

        let abortRoot = try makeRepository("cherry-abort")
        defer { try? FileManager.default.removeItem(at: abortRoot) }
        let abortCommit = try prepareCherryPickConflict(at: abortRoot, topic: "cherry-topic")
        let abortService = try makeService(abortRoot)
        _ = try await abortService.cherryPick(reference: abortCommit, taskID: UUID())
        let aborted = try await abortService.cherryPickAbort(taskID: UUID())
        XCTAssertEqual(aborted.exitCode, 0, aborted.output)
        XCTAssertNotNil(aborted.change)
        XCTAssertEqual(
            try String(contentsOf: abortRoot.appendingPathComponent("seed.txt"), encoding: .utf8),
            "main\n"
        )
        let cherryAbortedStatus = try await abortService.status()
        XCTAssertFalse(cherryAbortedStatus.output.contains("UU"))
    }

    func testLifecycleOperationsFailClosedWhenNoMatchingGitStateExists() async throws {
        let root = try makeRepository("state-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let operations: [(String, () async throws -> GitCommandResult)] = [
            ("merge", { try await service.mergeContinue(taskID: UUID()) }),
            ("merge", { try await service.mergeAbort(taskID: UUID()) }),
            ("rebase", { try await service.rebaseContinue(taskID: UUID()) }),
            ("rebase", { try await service.rebaseAbort(taskID: UUID()) }),
            ("cherry-pick", { try await service.cherryPickContinue(taskID: UUID()) }),
            ("cherry-pick", { try await service.cherryPickAbort(taskID: UUID()) })
        ]
        for (expected, operation) in operations {
            do {
                _ = try await operation()
                XCTFail("\(expected) lifecycle operation should require its state marker")
            } catch GitServiceError.operationStateMismatch(let actual, let active) {
                XCTAssertEqual(actual, expected)
                XCTAssertTrue(active.isEmpty)
            }
        }
    }

    func testCancelledHardResetStopsBeforeMutation() async throws {
        let root = try makeRepository("hard-reset-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preserve cancelled work\n".utf8).write(
            to: root.appendingPathComponent("seed.txt")
        )
        let head = try runGit(["rev-parse", "HEAD"], at: root)
        let service = try makeService(root)
        let cancelled = Task { () throws -> GitCommandResult in
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await service.hardReset(reference: "HEAD", taskID: UUID())
        }
        do {
            _ = try await cancelled.value
            XCTFail("cancelled hard reset should stop before inventory or mutation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], at: root), head)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("seed.txt"), encoding: .utf8),
            "preserve cancelled work\n"
        )
    }

    func testReviewPatchChecksAndAppliesIndexAndWorktreeWithoutStaleMutation() async throws {
        let root = try makeRepository("review-patch")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try makeService(root)
        let file = root.appendingPathComponent("seed.txt")

        try Data("seed\nstaged line\n".utf8).write(to: file)
        let unstaged = try await service.diff()
        let stagePayload = try reviewPatch(from: unstaged.output, direction: .forward)
        let stagedResult = try await service.applyReviewPatch(
            stagePayload,
            target: .index,
            taskID: UUID()
        )
        XCTAssertEqual(stagedResult.exitCode, 0, stagedResult.output)
        XCTAssertNotNil(stagedResult.change)
        let stagedDiff = try await service.diff(staged: true)
        XCTAssertTrue(stagedDiff.output.contains("+staged line"), stagedDiff.output)

        let unstagePayload = try reviewPatch(from: stagedDiff.output, direction: .reverse)
        let unstageResult = try await service.applyReviewPatch(
            unstagePayload,
            target: .index,
            taskID: UUID()
        )
        XCTAssertEqual(unstageResult.exitCode, 0, unstageResult.output)
        let stagedAfterUnstage = try await service.diff(staged: true)
        XCTAssertTrue(stagedAfterUnstage.output.isEmpty)

        let unstagedForRevert = try await service.diff()
        let revertPayload = try reviewPatch(
            from: unstagedForRevert.output,
            direction: .reverse
        )
        let revertResult = try await service.applyReviewPatch(
            revertPayload,
            target: .worktree,
            taskID: UUID()
        )
        XCTAssertEqual(revertResult.exitCode, 0, revertResult.output)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "seed\n")

        try Data("seed\nreviewed state\n".utf8).write(to: file)
        let reviewedDiff = try await service.diff()
        let stalePayload = try reviewPatch(
            from: reviewedDiff.output,
            direction: .reverse
        )
        try Data("seed\nchanged after review\n".utf8).write(to: file)
        do {
            _ = try await service.applyReviewPatch(
                stalePayload,
                target: .worktree,
                taskID: UUID()
            )
            XCTFail("git apply --check should reject stale worktree content")
        } catch GitServiceError.commandFailed(let command, _, _) {
            XCTAssertTrue(command.contains("--check"), command)
        }
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "seed\nchanged after review\n"
        )

        var binary = stalePayload
        binary.unifiedDiff += "GIT binary patch\n"
        do {
            _ = try await service.applyReviewPatch(binary, target: .worktree, taskID: UUID())
            XCTFail("binary patch payload should be rejected before Git")
        } catch GitServiceError.unsafeReviewPatch {
            // Expected.
        }
    }

    private func prepareConflictBranches(at root: URL, topic: String) throws {
        try runGit(["switch", "--create", topic], at: root)
        try Data("topic\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try runGit(["add", "seed.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "topic conflict"], at: root)
        try runGit(["switch", "main"], at: root)
        try Data("main\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try runGit(["add", "seed.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "main conflict"], at: root)
    }

    private func prepareRebaseConflict(at root: URL, topic: String) throws {
        try prepareConflictBranches(at: root, topic: topic)
        try runGit(["switch", topic], at: root)
    }

    private func prepareCherryPickConflict(at root: URL, topic: String) throws -> String {
        try prepareConflictBranches(at: root, topic: topic)
        return try runGit(["rev-parse", topic], at: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureHostileEditors(at root: URL) throws {
        // The closed Git service must override repository editor configuration;
        // `/usr/bin/false` makes any accidental editor invocation deterministic.
        try runGit(["config", "core.editor", "/usr/bin/false"], at: root)
        try runGit(["config", "sequence.editor", "/usr/bin/false"], at: root)
        try runGit(["config", "merge.autoEdit", "yes"], at: root)
    }

    private func makeRepository(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("advanced-git-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--initial-branch=main"], at: root)
        // The workspace may live on a filesystem that stores macOS extended
        // attributes as AppleDouble `._*` siblings. They are transport
        // metadata, not fixture changes, and otherwise make stash --include-
        // untracked attempt to restore sidecars that the filesystem recreated.
        try appendGitExclude("._*\n", at: root)
        try configureIdentity(at: root)
        try Data("seed\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
        try runGit(["add", "seed.txt"], at: root)
        try runGit(["commit", "--no-gpg-sign", "-m", "seed"], at: root)
        return root
    }

    private func makeService(
        _ root: URL,
        agentTurnFinalizationBoundaryHook: (@Sendable (Int) async throws -> Void)? = nil
    ) throws -> GitService {
        let workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        return try GitService(
            validator: validator,
            terminal: TerminalSession(validator: validator),
            changes: ChangeManager(validator: validator),
            timeout: 20,
            agentTurnFinalizationBoundaryHook: agentTurnFinalizationBoundaryHook
        )
    }

    private func configureIdentity(at root: URL) throws {
        try runGit(["config", "user.name", "Luma Advanced Git Tests"], at: root)
        try runGit(["config", "user.email", "advanced-git@invalid.local"], at: root)
    }

    private func reviewPatch(
        from unifiedDiff: String,
        direction: ReviewPatchDirection
    ) throws -> ReviewPatchPayload {
        let document = try ReviewDiffParser().parse(unifiedDiff, source: .unstaged)
        let file = try XCTUnwrap(document.files.first)
        return try ReviewPatchBuilder().make(
            file: file,
            expectedFileFingerprint: file.fingerprint,
            direction: direction
        )
    }

    private func appendGitExclude(_ text: String, at root: URL) throws {
        let url = root.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try Data((existing + text).utf8).write(to: url)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "credential.helper="
        ] + arguments
        process.currentDirectoryURL = root
        process.environment = (ProcessInfo.processInfo.environment).merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false"
        ]) { _, value in value }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw GitServiceError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                exitCode: process.terminationStatus,
                output: text
            )
        }
        return text
    }
}
