import Foundation
import XCTest
@testable import LumaChat

final class ManagedWorktreeServiceLifecycleTests: XCTestCase {
    func testCreatePersistsLeaseLifecycleAndRemove() async throws {
        let fixture = try makeFixture("lifecycle")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeService(fixture)
        let firstTaskID = UUID()

        let created = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: firstTaskID,
            options: ManagedWorktreeCreateOptions(
                preferredBranchName: "feature/parity",
                detached: false
            )
        )

        XCTAssertEqual(created.repositoryRootPath, fixture.repository.path)
        XCTAssertEqual(created.sourceCheckoutPath, fixture.repository.path)
        XCTAssertEqual(created.state, .ready)
        XCTAssertEqual(created.lease?.taskID, firstTaskID)
        XCTAssertTrue(created.branchName?.hasPrefix("feature/parity-") == true)
        XCTAssertEqual(
            created.worktreePath,
            fixture.managedRoot
                .appendingPathComponent(created.id.uuidString.lowercased(), isDirectory: true)
                .path
        )
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: created.worktreePath)
                    .appendingPathComponent(".git")
                    .path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertFalse(isDirectory.boolValue, "A linked worktree must use a .git pointer file.")

        // A newly constructed service must recover the durable record and lease.
        let restored = makeService(fixture)
        let restoredRecords = try await restored.list()
        XCTAssertEqual(restoredRecords.map(\.id), [created.id])
        XCTAssertEqual(restoredRecords.first?.lease, created.lease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.registryFile.path))

        do {
            _ = try await restored.reuse(id: created.id, taskID: UUID())
            XCTFail("A live lease must not be stolen by another Task.")
        } catch ManagedWorktreeError.leaseConflict(let worktreeID, let taskID) {
            XCTAssertEqual(worktreeID, created.id)
            XCTAssertEqual(taskID, firstTaskID)
        }

        let renewed = try await restored.reuse(id: created.id, taskID: firstTaskID)
        let originalLease = try XCTUnwrap(created.lease)
        XCTAssertEqual(renewed.lease?.id, originalLease.id)
        let renewedAgain = try await restored.reuse(id: created.id, taskID: firstTaskID)
        XCTAssertEqual(renewedAgain.lease?.id, originalLease.id)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(renewedAgain.lease).renewedAt,
            try XCTUnwrap(renewed.lease).renewedAt
        )

        var forged = originalLease
        forged.id = UUID()
        do {
            _ = try await restored.release(forged)
            XCTFail("A different random lease token must not release the checkout.")
        } catch ManagedWorktreeError.invalidLease(let id) {
            XCTAssertEqual(id, created.id)
        }
        // A renewal changes only freshness metadata. An earlier durable copy
        // of the same immutable token remains valid for cleanup/recovery.
        _ = try await restored.release(originalLease)

        let secondTaskID = UUID()
        let reassigned = try await restored.reuse(id: created.id, taskID: secondTaskID)
        XCTAssertEqual(reassigned.lease?.taskID, secondTaskID)
        XCTAssertNotEqual(reassigned.lease?.id, originalLease.id)
        _ = try await restored.release(try XCTUnwrap(reassigned.lease))

        try await restored.remove(id: created.id, lease: nil, force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.worktreePath))
        let recordsAfterRemoval = try await restored.list()
        XCTAssertTrue(recordsAfterRemoval.isEmpty)
        XCTAssertFalse(
            try git(fixture.repository, ["worktree", "list", "--porcelain"])
                .contains(created.worktreePath)
        )
    }

    func testCleanupRemovesOnlyOldCleanUnleasedWorktrees() async throws {
        let fixture = try makeFixture("cleanup")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let service = makeService(fixture, now: { createdAt })

        let clean = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: UUID(),
            options: ManagedWorktreeCreateOptions(detached: true)
        )
        let dirty = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: UUID(),
            options: ManagedWorktreeCreateOptions(detached: true)
        )
        _ = try await service.release(try XCTUnwrap(clean.lease))
        _ = try await service.release(try XCTUnwrap(dirty.lease))
        try Data("task-owned change\n".utf8).write(
            to: URL(fileURLWithPath: dirty.worktreePath)
                .appendingPathComponent("dirty.txt")
        )

        let report = try await service.cleanup(
            olderThan: 60,
            now: createdAt.addingTimeInterval(61)
        )

        XCTAssertEqual(report.removedIDs, [clean.id])
        XCTAssertTrue(report.skippedIDs.contains(dirty.id))
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.worktreePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirty.worktreePath))
        let recordsAfterCleanup = try await service.list()
        XCTAssertEqual(recordsAfterCleanup.map(\.id), [dirty.id])

        // Explicit forced cleanup keeps the fixture and the source repository tidy.
        try await service.remove(id: dirty.id, lease: nil, force: true)
    }

    func testBranchCollisionResolverUsesDeterministicNumericFallback() throws {
        let resolver = WorktreeConflictResolver()
        let taskID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let worktreeID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let first = try resolver.branchName(
            preferredName: "feature/shared",
            taskID: taskID,
            worktreeID: worktreeID,
            existingBranches: []
        )
        let collision = try resolver.branchName(
            preferredName: "feature/shared",
            taskID: taskID,
            worktreeID: worktreeID,
            existingBranches: [first]
        )

        XCTAssertEqual(first, "feature/shared-bbbbbbbb")
        XCTAssertEqual(collision, "feature/shared-bbbbbbbb-2")
    }

    func testCreateUsesDurablePlannedIdentityAndRejectsReuse() async throws {
        let fixture = try makeFixture("planned-identity")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeService(fixture)
        let plannedID = UUID()
        let created = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: UUID(),
            options: ManagedWorktreeCreateOptions(
                detached: true,
                plannedWorktreeID: plannedID
            )
        )
        XCTAssertEqual(created.id, plannedID)
        XCTAssertEqual(
            created.worktreePath,
            fixture.managedRoot
                .appendingPathComponent(plannedID.uuidString.lowercased(), isDirectory: true)
                .path
        )

        do {
            _ = try await service.create(
                repositoryRoot: fixture.repository,
                taskID: UUID(),
                options: ManagedWorktreeCreateOptions(
                    detached: true,
                    plannedWorktreeID: plannedID
                )
            )
            XCTFail("A durable planned identity must never be reused.")
        } catch ManagedWorktreeError.invalidConfiguration {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        try await service.remove(
            id: created.id,
            lease: try XCTUnwrap(created.lease),
            force: true
        )
    }

    func testRepairMarksExternallyDeletedCheckoutMissingWithoutReleasingLease() async throws {
        let fixture = try makeFixture("external-deletion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeService(fixture)
        let taskID = UUID()
        let created = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: taskID,
            options: ManagedWorktreeCreateOptions(detached: true)
        )
        try git(
            fixture.repository,
            ["worktree", "remove", "--force", created.worktreePath]
        )

        let report = try await service.repair()

        XCTAssertEqual(report.missingIDs, [created.id])
        XCTAssertTrue(report.failures.isEmpty)
        let records = try await service.list()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .missing)
        XCTAssertEqual(records[0].lease?.taskID, taskID)
        do {
            _ = try await service.reuse(id: created.id, taskID: taskID)
            XCTFail("A missing checkout must never be reused from its stale lease.")
        } catch ManagedWorktreeError.unavailableWorktree(let id, let state) {
            XCTAssertEqual(id, created.id)
            XCTAssertEqual(state, .missing)
        }
    }

    func testRepairPreservesLeasedPendingRemovalForTaskRecovery() async throws {
        let fixture = try makeFixture("leased-pending-removal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = makeService(fixture)
        let created = try await service.create(
            repositoryRoot: fixture.repository,
            taskID: UUID(),
            options: ManagedWorktreeCreateOptions(detached: true)
        )
        let registry = WorktreeRegistry(
            registryFile: fixture.registryFile,
            managedRoot: fixture.managedRoot
        )
        var pending = created
        pending.state = .removalPending
        try await registry.save(pending)

        let report = try await service.repair()

        XCTAssertEqual(report.skippedIDs, [created.id])
        XCTAssertTrue(report.removedIDs.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.worktreePath))
        let records = try await service.list()
        let retained = try XCTUnwrap(records.first)
        XCTAssertEqual(retained.state, .removalPending)
        XCTAssertEqual(retained.lease, created.lease)

        // An exact transaction owner can still explicitly complete removal.
        try await service.remove(id: created.id, lease: created.lease, force: true)
    }

    private struct Fixture {
        var root: URL
        var repository: URL
        var managedRoot: URL
        var registryFile: URL
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("managed-worktree-service-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        let registryFile = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("registry.json", isDirectory: false)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(repository, ["init", "-q"])
        try git(repository, ["config", "user.name", "Luma Tests"])
        try git(repository, ["config", "user.email", "luma@example.invalid"])
        try Data("initial\n".utf8).write(
            to: repository.appendingPathComponent("tracked.txt")
        )
        try git(repository, ["add", "tracked.txt"])
        try git(repository, ["commit", "--no-gpg-sign", "-q", "-m", "initial"])
        return Fixture(
            root: root,
            repository: repository,
            managedRoot: managedRoot,
            registryFile: registryFile
        )
    }

    private func makeService(
        _ fixture: Fixture,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ManagedWorktreeService {
        let registry = WorktreeRegistry(
            registryFile: fixture.registryFile,
            managedRoot: fixture.managedRoot
        )
        return ManagedWorktreeService(
            registry: registry,
            managedRoot: fixture.managedRoot,
            now: now
        )
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
            "-c", "core.fsmonitor=false",
            "-c", "gc.auto=0",
            "-C", root.path
        ] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "TMPDIR": AppPaths.projectTemporaryRoot.path
        ]
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManagedWorktreeServiceLifecycleTests",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)
                ]
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
