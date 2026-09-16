import Foundation
import XCTest
@testable import LumaChat

final class AgentTaskHandoffJournalTests: XCTestCase {
    func testReverseHandoffPersistsRecoveryCapabilityAndOrderedStages() async throws {
        let root = makeRoot("reverse-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let sessionID = UUID()
        let worktreeID = UUID()
        let transactionID = UUID()
        let digest = String(repeating: "a", count: 64)
        let desiredDigest = String(repeating: "b", count: 64)
        let lease = WorktreeLease(
            id: UUID(),
            worktreeID: worktreeID,
            taskID: sessionID,
            acquiredAt: Date(timeIntervalSince1970: 1)
        )
        var session = AgentSession(mode: .agent)
        session.id = sessionID
        session.workspace = workspace("managed", path: "/repo/managed")
        session.executionLocation = .worktree(id: worktreeID, label: "managed")
        session.localWorkspace = workspace("local", path: "/repo/local")
        let reference = WorktreeStateRecoveryReference(
            transactionID: transactionID,
            relativePath: transactionID.uuidString.lowercased() + ".snapshot",
            byteCount: 128,
            sha256: String(repeating: "c", count: 64),
            snapshotFingerprint: digest
        )

        var entry = try await journal.beginHandoffToLocal(
            session: session,
            sourceWorktreeID: worktreeID,
            sourceWorktreeLease: lease,
            recoverySnapshot: reference,
            expectedDestinationFingerprint: digest,
            desiredDestinationFingerprint: desiredDigest,
            id: transactionID,
            now: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(entry.resolvedTransitionKind, .handoffToLocal)
        XCTAssertEqual(entry.recoverySnapshot, reference)
        XCTAssertEqual(entry.sourceWorktreeLease, lease)

        entry = try await journal.markDestinationAllocated(
            entry,
            binding: binding(workspace: session.localWorkspace!, location: .local),
            createdWorktreeID: nil,
            now: Date(timeIntervalSince1970: 3)
        )
        entry = try await journal.markDestinationReady(
            entry,
            now: Date(timeIntervalSince1970: 4)
        )
        entry = try await journal.markSessionCommitted(
            entry,
            now: Date(timeIntervalSince1970: 5)
        )

        let pending = try await journal.pendingEntries()
        XCTAssertEqual(pending, [entry])
    }

    func testReverseHandoffRejectsMismatchedRecoveryFingerprint() async throws {
        let root = makeRoot("reverse-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let worktreeID = UUID()
        let transactionID = UUID()
        var session = AgentSession(mode: .agent)
        session.workspace = workspace("managed", path: "/repo/managed")
        session.executionLocation = .worktree(id: worktreeID, label: "managed")
        let lease = WorktreeLease(
            id: UUID(),
            worktreeID: worktreeID,
            taskID: session.id,
            acquiredAt: Date()
        )
        let reference = WorktreeStateRecoveryReference(
            transactionID: transactionID,
            relativePath: transactionID.uuidString.lowercased() + ".snapshot",
            byteCount: 128,
            sha256: String(repeating: "c", count: 64),
            snapshotFingerprint: String(repeating: "a", count: 64)
        )

        do {
            _ = try await journal.beginHandoffToLocal(
                session: session,
                sourceWorktreeID: worktreeID,
                sourceWorktreeLease: lease,
                recoverySnapshot: reference,
                expectedDestinationFingerprint: String(repeating: "b", count: 64),
                desiredDestinationFingerprint: String(repeating: "d", count: 64),
                id: transactionID
            )
            XCTFail("A recovery reference must describe the exact rollback fingerprint.")
        } catch AgentTaskHandoffJournalError.invalidEntry {
            // Expected.
        }
    }

    func testPlannedWorktreeIDRoundTripsThroughStagesAndRejectsMismatch() async throws {
        let root = makeRoot("planned-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let local = workspace("local", path: "/repo/local")
        let plannedWorktreeID = UUID()
        var session = AgentSession(mode: .agent)
        session.workspace = local
        session.projectFolderID = UUID()

        var entry = try await journal.begin(
            session: session,
            plannedWorktreeID: plannedWorktreeID,
            id: UUID(),
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(entry.stage, .prepared)
        XCTAssertEqual(entry.plannedWorktreeID, plannedWorktreeID)
        var pendingEntries = try await journal.pendingEntries()
        XCTAssertEqual(pendingEntries, [entry])

        let managed = workspace("managed", path: "/repo/managed")
        let destination = binding(
            workspace: managed,
            location: .worktree(id: plannedWorktreeID, label: "task"),
            localWorkspace: local,
            localProjectFolderID: session.projectFolderID
        )
        do {
            _ = try await journal.markDestinationAllocated(
                entry,
                binding: destination,
                createdWorktreeID: UUID()
            )
            XCTFail("A created checkout must match the durable planned identity.")
        } catch AgentTaskHandoffJournalError.invalidEntry {
            // Expected.
        }
        pendingEntries = try await journal.pendingEntries()
        XCTAssertEqual(pendingEntries, [entry])

        entry = try await journal.markDestinationAllocated(
            entry,
            binding: destination,
            createdWorktreeID: plannedWorktreeID,
            now: Date(timeIntervalSince1970: 11)
        )
        XCTAssertEqual(entry.stage, .destinationAllocated)
        XCTAssertEqual(entry.plannedWorktreeID, plannedWorktreeID)
        XCTAssertEqual(entry.createdWorktreeID, plannedWorktreeID)
        entry = try await journal.markDestinationReady(
            entry,
            now: Date(timeIntervalSince1970: 12)
        )
        entry = try await journal.markSessionCommitted(
            entry,
            now: Date(timeIntervalSince1970: 13)
        )

        pendingEntries = try await journal.pendingEntries()
        XCTAssertEqual(pendingEntries, [entry])
        try await journal.remove(id: entry.id)
        pendingEntries = try await journal.pendingEntries()
        XCTAssertTrue(pendingEntries.isEmpty)
    }

    func testForkPersistsSourceAndForkIdentityAcrossOrderedStages() async throws {
        let root = makeRoot("fork-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let sourceWorkspace = workspace("source", path: "/repo/source")
        let forkWorkspace = workspace("fork", path: "/repo/fork")
        let forkSessionID = UUID()
        let plannedWorktreeID = UUID()
        var source = AgentSession(mode: .plan)
        source.workspace = sourceWorkspace
        source.projectFolderID = UUID()

        var entry = try await journal.beginFork(
            source: source,
            forkSessionID: forkSessionID,
            plannedWorktreeID: plannedWorktreeID,
            id: UUID(),
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(entry.resolvedTransitionKind, .fork)
        XCTAssertEqual(entry.sourceSessionID, source.id)
        XCTAssertEqual(entry.sessionID, forkSessionID)
        XCTAssertEqual(entry.plannedWorktreeID, plannedWorktreeID)
        XCTAssertEqual(entry.from.workspace, sourceWorkspace)
        XCTAssertEqual(entry.stage, .prepared)

        entry = try await journal.markDestinationAllocated(
            entry,
            binding: binding(
                workspace: forkWorkspace,
                location: .worktree(id: plannedWorktreeID, label: "fork"),
                localWorkspace: sourceWorkspace,
                localProjectFolderID: source.projectFolderID
            ),
            createdWorktreeID: plannedWorktreeID,
            now: Date(timeIntervalSince1970: 21)
        )
        entry = try await journal.markDestinationReady(
            entry,
            now: Date(timeIntervalSince1970: 22)
        )
        entry = try await journal.markSessionCommitted(
            entry,
            now: Date(timeIntervalSince1970: 23)
        )

        XCTAssertEqual(entry.stage, .sessionCommitted)
        let pendingEntries = try await journal.pendingEntries()
        XCTAssertEqual(pendingEntries, [entry])
    }

    func testForkRejectsReusingSourceTaskIdentity() async throws {
        let root = makeRoot("fork-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        var source = AgentSession(mode: .agent)
        source.workspace = workspace("source", path: "/repo/source")

        do {
            _ = try await journal.beginFork(
                source: source,
                forkSessionID: source.id,
                plannedWorktreeID: UUID()
            )
            XCTFail("A fork must never reuse the source Task identity.")
        } catch AgentTaskHandoffJournalError.invalidEntry {
            // Expected.
        }
        let pendingEntries = try await journal.pendingEntries()
        XCTAssertTrue(pendingEntries.isEmpty)
    }

    func testRejectsOutOfOrderTransition() async throws {
        let root = makeRoot("stage-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        var session = AgentSession(mode: .agent)
        session.workspace = workspace("local", path: "/repo/local")
        let entry = try await journal.begin(session: session)

        do {
            _ = try await journal.markDestinationReady(entry)
            XCTFail("Destination cannot become ready before allocation.")
        } catch AgentTaskHandoffJournalError.invalidEntry {
            // Expected.
        }
    }

    func testTamperedEntryFailsClosed() async throws {
        let root = makeRoot("tampered")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        var session = AgentSession(mode: .agent)
        session.workspace = workspace("local", path: "/repo/local")
        let entry = try await journal.begin(session: session)
        var tampered = entry
        tampered.id = UUID()
        let file = entryFile(root: root, id: entry.id)
        try JSONEncoder().encode(tampered).write(to: file)

        await assertInvalidJournal(journal, message: "A filename/transaction mismatch must fail closed.")
    }

    func testSymlinkJournalRootFailsClosed() async throws {
        let parent = makeRoot("symlink-root")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let symlink = parent.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.path,
            withDestinationPath: destination.path
        )
        let journal = AgentTaskHandoffJournal(root: symlink)

        await assertInvalidJournal(journal, message: "A symlink journal root must fail closed.")
    }

    func testSymlinkInJournalParentChainAndEntryFailClosed() async throws {
        let parent = makeRoot("symlink-parent")
        let outside = makeRoot("symlink-parent-outside")
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bridge = parent.appendingPathComponent("bridge", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: bridge.path,
            withDestinationPath: outside.path
        )
        let escaped = AgentTaskHandoffJournal(
            root: bridge.appendingPathComponent("journal", isDirectory: true)
        )
        await assertInvalidJournal(
            escaped,
            message: "A symlink in the journal parent chain must fail closed."
        )

        let safeRoot = parent.appendingPathComponent("safe", isDirectory: true)
        let safe = AgentTaskHandoffJournal(root: safeRoot)
        let initial = try await safe.pendingEntries()
        XCTAssertTrue(initial.isEmpty)
        let linkedEntry = entryFile(root: safeRoot, id: UUID())
        let outsideFile = outside.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            atPath: linkedEntry.path,
            withDestinationPath: outsideFile.path
        )
        await assertInvalidJournal(
            safe,
            message: "A symbolic-link journal entry must fail closed before decode."
        )
    }

    func testOversizedEntryFailsClosedBeforeDecode() async throws {
        let root = makeRoot("oversized")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let pendingEntries = try await journal.pendingEntries()
        XCTAssertTrue(pendingEntries.isEmpty)
        let file = entryFile(root: root, id: UUID())
        try Data(repeating: 0x41, count: AgentTaskHandoffJournal.maximumEntryBytes + 1)
            .write(to: file)

        await assertInvalidJournal(journal, message: "An oversized entry must fail closed.")
    }

    private func assertInvalidJournal(
        _ journal: AgentTaskHandoffJournal,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await journal.pendingEntries()
            XCTFail(message, file: file, line: line)
        } catch {
            XCTAssertTrue(
                error is AgentTaskHandoffJournalError || error is DecodingError,
                "Unexpected error: \(error)",
                file: file,
                line: line
            )
        }
    }

    private func makeRoot(_ label: String) -> URL {
        AppPaths.projectTemporaryRoot
            .appendingPathComponent("handoff-journal-tests", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func entryFile(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func binding(
        workspace: AgentWorkspace,
        location: AgentExecutionLocation,
        localWorkspace: AgentWorkspace? = nil,
        localProjectFolderID: UUID? = nil
    ) -> AgentTaskBindingSnapshot {
        AgentTaskBindingSnapshot(
            workspace: workspace,
            location: location,
            projectFolderID: nil,
            localWorkspace: localWorkspace,
            localProjectFolderID: localProjectFolderID
        )
    }

    private func workspace(_ name: String, path: String) -> AgentWorkspace {
        AgentWorkspace(
            name: name,
            rootPath: path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
    }
}
