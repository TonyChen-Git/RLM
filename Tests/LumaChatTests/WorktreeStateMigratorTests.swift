import Foundation
import XCTest
@testable import LumaChat

final class WorktreeStateMigratorTests: XCTestCase {
    func testTransfersStagedUnstagedUntrackedAndExplicitIgnoredState() async throws {
        let root = try makeRoot("state-source")
        let destination = try makeRoot("state-target", create: false)
        defer {
            removeWorktreeIfPresent(repository: root, checkout: destination)
            removeIfPresent(root)
            removeIfPresent(destination)
        }
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Luma Tests"])
        try git(root, ["config", "user.email", "luma@example.invalid"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("ignored.txt\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try git(root, ["add", ".gitignore", "tracked.txt"])
        try git(root, ["commit", "--no-gpg-sign", "-m", "initial"])

        try Data("base\nstaged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(root, ["add", "tracked.txt"])
        try Data("base\nstaged\nunstaged\n".utf8)
            .write(to: root.appendingPathComponent("tracked.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        try Data("ignored but task-owned\n".utf8)
            .write(to: root.appendingPathComponent("ignored.txt"))

        let migrator = WorktreeStateMigrator()
        let snapshot = try await migrator.capture(
            sourceRoot: root,
            supplementalPaths: ["ignored.txt", "tracked.txt"]
        )
        try git(root, ["worktree", "add", "--detach", destination.path, "HEAD"])
        try await migrator.apply(snapshot, destinationRoot: destination)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "base\nstaged\nunstaged\n"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("new.txt"), encoding: .utf8),
            "untracked\n"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("ignored.txt"), encoding: .utf8),
            "ignored but task-owned\n"
        )
        let staged = try git(destination, ["diff", "--cached", "HEAD", "--"])
        XCTAssertTrue(staged.contains("+staged"))
        XCTAssertFalse(staged.contains("+unstaged"))
        let isEquivalent = try await migrator.isEquivalent(snapshot, checkoutRoot: destination)
        XCTAssertTrue(isEquivalent)
    }

    func testRefusesDirtyDestinationWithoutChangingIt() async throws {
        let root = try makeRoot("dirty-source")
        let destination = try makeRoot("dirty-target", create: false)
        defer {
            removeWorktreeIfPresent(repository: root, checkout: destination)
            removeIfPresent(root)
            removeIfPresent(destination)
        }
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Luma Tests"])
        try git(root, ["config", "user.email", "luma@example.invalid"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try git(root, ["add", "file.txt"])
        try git(root, ["commit", "--no-gpg-sign", "-m", "initial"])
        try Data("source\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let snapshot = try await WorktreeStateMigrator().capture(sourceRoot: root)
        try git(root, ["worktree", "add", "--detach", destination.path, "HEAD"])
        try Data("destination\n".utf8).write(to: destination.appendingPathComponent("file.txt"))

        do {
            try await WorktreeStateMigrator().apply(snapshot, destinationRoot: destination)
            XCTFail("A dirty destination must be refused.")
        } catch WorktreeStateMigrationError.targetNotClean {
            // Expected.
        }
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8),
            "destination\n"
        )
    }

    func testRollbackDoesNotDeletePreexistingIgnoredFile() async throws {
        let root = try makeRoot("rollback-source")
        let destination = try makeRoot("rollback-target", create: false)
        defer {
            removeWorktreeIfPresent(repository: root, checkout: destination)
            removeIfPresent(root)
            removeIfPresent(destination)
        }
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Luma Tests"])
        try git(root, ["config", "user.email", "luma@example.invalid"])
        try Data("cache.bin\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(root, ["add", ".gitignore", "tracked.txt"])
        try git(root, ["commit", "--no-gpg-sign", "-m", "initial"])
        let ignoredData = Data("preexisting and task-owned\n".utf8)
        try ignoredData.write(to: root.appendingPathComponent("cache.bin"))

        var snapshot = try await WorktreeStateMigrator().capture(
            sourceRoot: root,
            supplementalPaths: ["cache.bin"]
        )
        try git(root, ["worktree", "add", "--detach", destination.path, "HEAD"])
        let destinationIgnored = destination.appendingPathComponent("cache.bin")
        try ignoredData.write(to: destinationIgnored)
        snapshot.workingTreePatch = Data("this is not a Git patch".utf8)

        do {
            try await WorktreeStateMigrator().apply(snapshot, destinationRoot: destination)
            XCTFail("An invalid patch must fail.")
        } catch WorktreeStateMigrationError.commandFailed {
            // Expected after supplemental preflight has accepted the existing file.
        }
        XCTAssertEqual(try Data(contentsOf: destinationIgnored), ignoredData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationIgnored.path))
    }

    func testCaptureRejectsSymlinkInSupplementalParentChain() async throws {
        let root = try makeRoot("symlink-source")
        let outside = try makeRoot("symlink-outside")
        defer {
            removeIfPresent(root)
            removeIfPresent(outside)
        }
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Luma Tests"])
        try git(root, ["config", "user.email", "luma@example.invalid"])
        try Data("escape/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(root, ["add", ".gitignore", "tracked.txt"])
        try git(root, ["commit", "--no-gpg-sign", "-m", "initial"])
        try Data("outside\n".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        do {
            _ = try await WorktreeStateMigrator().capture(
                sourceRoot: root,
                supplementalPaths: ["escape/secret.txt"]
            )
            XCTFail("A symlink parent must be rejected.")
        } catch WorktreeStateMigrationError.unsafePath {
            // Expected.
        }
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8),
            "outside\n"
        )
    }

    func testAbsentAndEmptyDirectoryManifestAffectEquivalence() async throws {
        let root = try makeRoot("manifest-source")
        let destination = try makeRoot("manifest-target", create: false)
        defer {
            removeWorktreeIfPresent(repository: root, checkout: destination)
            removeIfPresent(root)
            removeIfPresent(destination)
        }
        try git(root, ["init"])
        try git(root, ["config", "user.name", "Luma Tests"])
        try git(root, ["config", "user.email", "luma@example.invalid"])
        try Data("gone.txt\nempty/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git(root, ["add", ".gitignore", "tracked.txt"])
        try git(root, ["commit", "--no-gpg-sign", "-m", "initial"])
        let emptyDirectory = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)

        let migrator = WorktreeStateMigrator()
        let snapshot = try await migrator.capture(
            sourceRoot: root,
            supplementalPaths: ["gone.txt", "empty"]
        )
        XCTAssertTrue(snapshot.supplementalManifest.contains {
            $0.relativePath == "gone.txt" && $0.kind == .absent
        })
        XCTAssertTrue(snapshot.supplementalManifest.contains {
            $0.relativePath == "empty" && $0.kind == .directory
        })
        XCTAssertEqual(snapshot.fingerprint.count, 64)

        try git(root, ["worktree", "add", "--detach", destination.path, "HEAD"])
        try await migrator.apply(snapshot, destinationRoot: destination)
        let isInitiallyEquivalent = try await migrator.isEquivalent(snapshot, checkoutRoot: destination)
        XCTAssertTrue(isInitiallyEquivalent)
        let destinationSnapshot = try await migrator.capture(
            sourceRoot: destination,
            supplementalPaths: snapshot.supplementalRoots
        )
        XCTAssertEqual(destinationSnapshot.fingerprint, snapshot.fingerprint)

        try FileManager.default.removeItem(at: destination.appendingPathComponent("empty"))
        let isEquivalentWithoutDirectory = try await migrator.isEquivalent(
            snapshot,
            checkoutRoot: destination
        )
        XCTAssertFalse(isEquivalentWithoutDirectory)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("empty"),
            withIntermediateDirectories: false
        )
        try Data("unexpected\n".utf8).write(to: destination.appendingPathComponent("gone.txt"))
        let isEquivalentWithUnexpectedFile = try await migrator.isEquivalent(
            snapshot,
            checkoutRoot: destination
        )
        XCTAssertFalse(isEquivalentWithUnexpectedFile)
    }

    func testReplaceSameHeadDirtyBaselineWithDesiredDirtyState() async throws {
        let local = try makeRoot("replace-dirty-local")
        let source = try makeRoot("replace-dirty-source", create: false)
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("cache.bin\n".utf8).write(to: local.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", ".gitignore", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "--detach", source.path, "HEAD"])

        try Data("base\nlocal staged\n".utf8)
            .write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", "tracked.txt"])
        try Data("base\nlocal staged\nlocal unstaged\n".utf8)
            .write(to: local.appendingPathComponent("tracked.txt"))
        try Data("local cache\n".utf8)
            .write(to: local.appendingPathComponent("cache.bin"))
        try Data("local only\n".utf8)
            .write(to: local.appendingPathComponent("local-only.txt"))

        try Data("base\ndesired staged\n".utf8)
            .write(to: source.appendingPathComponent("tracked.txt"))
        try git(source, ["add", "tracked.txt"])
        try Data("base\ndesired staged\ndesired unstaged\n".utf8)
            .write(to: source.appendingPathComponent("tracked.txt"))
        try Data("desired cache\n".utf8)
            .write(to: source.appendingPathComponent("cache.bin"))
        try Data("desired only\n".utf8)
            .write(to: source.appendingPathComponent("desired-only.txt"))

        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(
            sourceRoot: local,
            supplementalPaths: ["cache.bin"]
        )
        let desired = try await migrator.capture(
            sourceRoot: source,
            supplementalPaths: ["cache.bin"]
        )

        try await migrator.replace(
            expectedCurrent: expected,
            with: desired,
            destinationRoot: local
        )

        let matchesDesired = try await migrator.isEquivalent(desired, checkoutRoot: local)
        XCTAssertTrue(matchesDesired)
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "base\ndesired staged\ndesired unstaged\n"
        )
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("cache.bin"), encoding: .utf8),
            "desired cache\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("local-only.txt").path
        ))
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("desired-only.txt"), encoding: .utf8),
            "desired only\n"
        )
        let staged = try git(local, ["diff", "--cached", "HEAD", "--"])
        XCTAssertTrue(staged.contains("+desired staged"))
        XCTAssertFalse(staged.contains("+desired unstaged"))
    }

    func testReplaceFastForwardsSymbolicLocalReference() async throws {
        let local = try makeRoot("replace-ff-local")
        let source = try makeRoot("replace-ff-source", create: false)
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "-b", "managed-ff", source.path, "HEAD"])

        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(sourceRoot: local)
        try Data("fast forward\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try git(source, ["add", "tracked.txt"])
        try git(source, ["commit", "--no-gpg-sign", "-m", "managed commit"])
        let desired = try await migrator.capture(sourceRoot: source)

        try await migrator.replace(
            expectedCurrent: expected,
            with: desired,
            destinationRoot: local
        )

        XCTAssertEqual(
            try git(local, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            desired.headObjectID
        )
        XCTAssertEqual(
            try git(local, ["symbolic-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            expected.symbolicReference
        )
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "fast forward\n"
        )
    }

    func testReplaceRefusesNonFastForwardWithoutMutation() async throws {
        let local = try makeRoot("replace-non-ff-local")
        let source = try makeRoot("replace-non-ff-source", create: false)
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "-b", "managed-diverged", source.path, "HEAD"])

        try Data("local commit\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "local commit"])
        try Data("source commit\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try git(source, ["add", "tracked.txt"])
        try git(source, ["commit", "--no-gpg-sign", "-m", "source commit"])

        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(sourceRoot: local)
        let desired = try await migrator.capture(sourceRoot: source)
        do {
            try await migrator.replace(
                expectedCurrent: expected,
                with: desired,
                destinationRoot: local
            )
            XCTFail("A non-fast-forward replacement must be refused.")
        } catch WorktreeStateMigrationError.nonFastForward {
            // Expected.
        }

        let after = try await migrator.capture(sourceRoot: local)
        XCTAssertEqual(after.fingerprint, expected.fingerprint)
        XCTAssertEqual(after.symbolicReference, expected.symbolicReference)
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("tracked.txt"), encoding: .utf8),
            "local commit\n"
        )
    }

    func testReplacePreservesTombstonesAndEmptyDirectories() async throws {
        let local = try makeRoot("replace-manifest-local")
        let source = try makeRoot("replace-manifest-source", create: false)
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("state/\n".utf8).write(to: local.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", ".gitignore", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "--detach", source.path, "HEAD"])

        let localState = local.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localState.appendingPathComponent("old-empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("remove me\n".utf8)
            .write(to: localState.appendingPathComponent("remove.txt"))
        let sourceState = source.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceState.appendingPathComponent("new-empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(
            sourceRoot: local,
            supplementalPaths: ["state"]
        )
        let desired = try await migrator.capture(
            sourceRoot: source,
            supplementalPaths: ["state"]
        )
        try await migrator.replace(
            expectedCurrent: expected,
            with: desired,
            destinationRoot: local
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localState.appendingPathComponent("remove.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localState.appendingPathComponent("old-empty").path
        ))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: localState.appendingPathComponent("new-empty").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        let matchesDesired = try await migrator.isEquivalent(desired, checkoutRoot: local)
        XCTAssertTrue(matchesDesired)
    }

    func testReplaceFailureRollsBackExpectedSnapshotAndReference() async throws {
        let local = try makeRoot("replace-rollback-local")
        let source = try makeRoot("replace-rollback-source", create: false)
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("cache.bin\n".utf8).write(to: local.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", ".gitignore", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "-b", "managed-rollback", source.path, "HEAD"])

        try Data("expected dirty\n".utf8)
            .write(to: local.appendingPathComponent("tracked.txt"))
        try Data("expected cache\n".utf8)
            .write(to: local.appendingPathComponent("cache.bin"))
        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(
            sourceRoot: local,
            supplementalPaths: ["cache.bin"]
        )

        try Data("new commit\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try git(source, ["add", "tracked.txt"])
        try git(source, ["commit", "--no-gpg-sign", "-m", "managed commit"])
        try Data("desired cache\n".utf8)
            .write(to: source.appendingPathComponent("cache.bin"))
        var desired = try await migrator.capture(
            sourceRoot: source,
            supplementalPaths: ["cache.bin"]
        )
        desired.workingTreePatch = Data("not a valid Git patch".utf8)

        do {
            try await migrator.replace(
                expectedCurrent: expected,
                with: desired,
                destinationRoot: local
            )
            XCTFail("An invalid desired patch must fail and roll back.")
        } catch WorktreeStateMigrationError.commandFailed {
            // Expected after the ref and supplemental state have mutated.
        }

        let restoredExpected = try await migrator.isEquivalent(expected, checkoutRoot: local)
        XCTAssertTrue(restoredExpected)
        XCTAssertEqual(
            try git(local, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
            expected.headObjectID
        )
        XCTAssertEqual(
            try String(contentsOf: local.appendingPathComponent("cache.bin"), encoding: .utf8),
            "expected cache\n"
        )
    }

    func testReplaceRefusesSymlinkSwapWithoutTouchingExternalData() async throws {
        let local = try makeRoot("replace-symlink-local")
        let source = try makeRoot("replace-symlink-source", create: false)
        let outside = try makeRoot("replace-symlink-outside")
        defer {
            removeWorktreeIfPresent(repository: local, checkout: source)
            removeIfPresent(local)
            removeIfPresent(source)
            removeIfPresent(outside)
        }
        try git(local, ["init"])
        try git(local, ["config", "user.name", "Luma Tests"])
        try git(local, ["config", "user.email", "luma@example.invalid"])
        try Data("owned.txt\n".utf8).write(to: local.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to: local.appendingPathComponent("tracked.txt"))
        try git(local, ["add", ".gitignore", "tracked.txt"])
        try git(local, ["commit", "--no-gpg-sign", "-m", "initial"])
        try git(local, ["worktree", "add", "--detach", source.path, "HEAD"])

        let owned = local.appendingPathComponent("owned.txt")
        try Data("owned\n".utf8).write(to: owned)
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("outside must survive\n".utf8).write(to: outsideFile)
        let migrator = WorktreeStateMigrator()
        let expected = try await migrator.capture(
            sourceRoot: local,
            supplementalPaths: ["owned.txt"]
        )
        let desired = try await migrator.capture(
            sourceRoot: source,
            supplementalPaths: ["owned.txt"]
        )
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outsideFile)

        do {
            try await migrator.replace(
                expectedCurrent: expected,
                with: desired,
                destinationRoot: local
            )
            XCTFail("A supplemental symlink swap must fail CAS preflight.")
        } catch WorktreeStateMigrationError.unsafePath {
            // Expected.
        } catch WorktreeStateMigrationError.unsupportedFile {
            // Also an acceptable fail-closed classification.
        }

        XCTAssertEqual(
            try String(contentsOf: outsideFile, encoding: .utf8),
            "outside must survive\n"
        )
        let values = try owned.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
    }

    private func makeRoot(_ label: String, create: Bool = true) throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("worktree-state-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                at: root.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeWorktreeIfPresent(repository: URL, checkout: URL) {
        guard FileManager.default.fileExists(atPath: checkout.path) else { return }
        _ = try? git(repository, ["worktree", "remove", "--force", checkout.path])
    }

    @discardableResult
    private func git(_ root: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "-C", root.path
        ] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "TMPDIR": AppPaths.projectTemporaryRoot.path
        ]
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WorktreeStateMigratorTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
