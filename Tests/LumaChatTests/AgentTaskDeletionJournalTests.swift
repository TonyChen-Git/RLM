import Foundation
import XCTest
@testable import LumaChat

final class AgentTaskDeletionJournalTests: XCTestCase {
    func testExactManagedBindingAndLeaseRoundTripThenRemove() async throws {
        let root = makeRoot("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskDeletionJournal(root: root)
        let worktreeID = UUID()
        var session = makeSession(worktreeID: worktreeID)
        session.localWorkspace = workspace("local", path: "/repo/local")
        let lease = WorktreeLease(
            id: UUID(),
            worktreeID: worktreeID,
            taskID: session.id,
            acquiredAt: Date(timeIntervalSince1970: 10)
        )

        let entry = try await journal.begin(
            session: session,
            worktreeID: worktreeID,
            lease: lease,
            id: UUID(),
            now: Date(timeIntervalSince1970: 20)
        )
        let pending = try await journal.pendingEntries()
        XCTAssertEqual(pending, [entry])
        XCTAssertEqual(entry.binding.workspace, session.workspace)
        XCTAssertEqual(entry.binding.localWorkspace, session.localWorkspace)
        XCTAssertEqual(entry.lease, lease)

        try await journal.remove(id: entry.id)
        let afterRemoval = try await journal.pendingEntries()
        XCTAssertTrue(afterRemoval.isEmpty)
    }

    func testRejectsLeaseForAnotherTaskOrWorktree() async throws {
        let root = makeRoot("mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskDeletionJournal(root: root)
        let worktreeID = UUID()
        let session = makeSession(worktreeID: worktreeID)
        let mismatched = WorktreeLease(
            id: UUID(),
            worktreeID: worktreeID,
            taskID: UUID(),
            acquiredAt: Date()
        )

        do {
            _ = try await journal.begin(
                session: session,
                worktreeID: worktreeID,
                lease: mismatched
            )
            XCTFail("Deletion intent must never persist a lease for another Task.")
        } catch AgentTaskDeletionJournalError.invalidEntry {
            // Expected.
        }
        let pending = try await journal.pendingEntries()
        XCTAssertTrue(pending.isEmpty)
    }

    func testTamperedFilenameIdentityFailsClosed() async throws {
        let root = makeRoot("tampered")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = AgentTaskDeletionJournal(root: root)
        let worktreeID = UUID()
        let session = makeSession(worktreeID: worktreeID)
        let lease = WorktreeLease(
            id: UUID(),
            worktreeID: worktreeID,
            taskID: session.id,
            acquiredAt: Date()
        )
        let entry = try await journal.begin(
            session: session,
            worktreeID: worktreeID,
            lease: lease
        )
        let source = root.appendingPathComponent(entry.id.uuidString.lowercased() + ".json")
        let tamperedID = UUID()
        let destination = root.appendingPathComponent(tamperedID.uuidString.lowercased() + ".json")
        try FileManager.default.moveItem(at: source, to: destination)

        do {
            _ = try await journal.pendingEntries()
            XCTFail("A filename/payload transaction mismatch must fail closed.")
        } catch AgentTaskDeletionJournalError.invalidEntry {
            // Expected.
        }
    }

    func testSymlinkJournalRootFailsClosed() async throws {
        let parent = makeRoot("symlink")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: destination.path
        )
        let journal = AgentTaskDeletionJournal(root: link)

        do {
            _ = try await journal.pendingEntries()
            XCTFail("A symlink journal root must fail closed.")
        } catch AgentTaskDeletionJournalError.invalidEntry {
            // Expected.
        }
    }

    func testSymlinkInJournalParentChainFailsClosed() async throws {
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
        let journal = AgentTaskDeletionJournal(
            root: bridge.appendingPathComponent("journal", isDirectory: true)
        )

        do {
            _ = try await journal.pendingEntries()
            XCTFail("A symlink in the journal parent chain must fail closed.")
        } catch AgentTaskDeletionJournalError.invalidEntry {
            // Expected.
        }
    }

    private func makeSession(worktreeID: UUID) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.workspace = workspace("managed", path: "/repo/managed")
        session.executionLocation = .worktree(id: worktreeID, label: "managed")
        return session
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

    private func makeRoot(_ label: String) -> URL {
        AppPaths.projectTemporaryRoot
            .appendingPathComponent("deletion-journal-tests", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
