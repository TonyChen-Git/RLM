import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AgentLocalMemoryStoreTests: XCTestCase {
    func testDisabledByDefaultAndRequiresReviewBeforeContextUse() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectID = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)

        let initial = try await store.load(projectID: projectID)
        XCTAssertFalse(initial.enabled)
        XCTAssertTrue(initial.entries.isEmpty)
        do {
            _ = try await store.propose("Remember this", projectID: projectID)
            XCTFail("A new project must not capture memory without opt-in")
        } catch AgentLocalMemoryError.disabled {}

        _ = try await store.setEnabled(true, projectID: projectID)
        let proposed = try await store.propose(
            "Use token=super-secret-value in the fixture",
            projectID: projectID
        )
        XCTAssertEqual(proposed.status, .proposed)
        XCTAssertFalse(proposed.text.contains("super-secret-value"))
        let beforeApproval = try await store.approvedForContext(projectID: projectID)
        XCTAssertTrue(beforeApproval.isEmpty)

        let approved = try await store.approve(id: proposed.id, projectID: projectID)
        XCTAssertEqual(approved.status, .approved)
        let reopened = AgentLocalMemoryStore(storageRoot: root)
        let persisted = try await reopened.load(projectID: projectID)
        XCTAssertEqual(persisted.entries, [approved])
        let reopenedContext = try await reopened.approvedForContext(projectID: projectID)
        XCTAssertEqual(reopenedContext, [approved])

        _ = try await reopened.setEnabled(false, projectID: projectID)
        let disabledContext = try await reopened.approvedForContext(projectID: projectID)
        XCTAssertTrue(disabledContext.isEmpty)
        let disabledSnapshot = try await reopened.load(projectID: projectID)
        XCTAssertEqual(disabledSnapshot.entries.count, 1)
    }

    func testEditingApprovedMemoryReturnsItToReviewAndSupportsRemoveAndClear() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectID = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)
        _ = try await store.setEnabled(true, projectID: projectID)
        let first = try await store.propose("First note", projectID: projectID)
        _ = try await store.approve(id: first.id, projectID: projectID)

        let edited = try await store.update(
            id: first.id, text: " Revised note ", projectID: projectID
        )
        XCTAssertEqual(edited.text, "Revised note")
        XCTAssertEqual(edited.status, .proposed)
        let contextBeforeReview = try await store.approvedForContext(projectID: projectID)
        XCTAssertTrue(contextBeforeReview.isEmpty)
        _ = try await store.approve(id: first.id, projectID: projectID)
        let second = try await store.propose("Second note", projectID: projectID)

        let afterRemove = try await store.remove(id: second.id, projectID: projectID)
        XCTAssertEqual(afterRemove.entries.map(\.id), [first.id])
        let afterClear = try await store.clear(projectID: projectID)
        XCTAssertTrue(afterClear.enabled)
        XCTAssertTrue(afterClear.entries.isEmpty)
        let contextAfterClear = try await store.approvedForContext(projectID: projectID)
        XCTAssertTrue(contextAfterClear.isEmpty)
    }

    func testProjectScopesAndContextBudget() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let firstProject = UUID()
        let secondProject = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)
        _ = try await store.setEnabled(true, projectID: firstProject)
        for index in 0..<8 {
            let entry = try await store.propose(
                "Note \(index) " + String(repeating: "x", count: 3_000),
                projectID: firstProject
            )
            _ = try await store.approve(id: entry.id, projectID: firstProject)
        }

        let context = try await store.approvedForContext(projectID: firstProject)
        XCTAssertLessThan(context.reduce(0) { $0 + $1.text.utf8.count },
                          AgentLocalMemoryStore.maximumContextBytes + 1)
        XCTAssertLessThan(context.count, 8)
        let unrelatedContext = try await store.approvedForContext(projectID: secondProject)
        XCTAssertTrue(unrelatedContext.isEmpty)
        let unrelatedSnapshot = try await store.load(projectID: secondProject)
        XCTAssertFalse(unrelatedSnapshot.enabled)
    }

    func testRejectsInvalidTextCorruptionAndSymlinksWithoutOverwriting() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectID = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)
        _ = try await store.setEnabled(true, projectID: projectID)
        do {
            _ = try await store.propose(
                String(repeating: "x", count: AgentLocalMemoryStore.maximumTextBytes + 1),
                projectID: projectID
            )
            XCTFail("Expected text limit")
        } catch AgentLocalMemoryError.invalidText {}

        let file = root.appendingPathComponent(projectID.uuidString.lowercased())
            .appendingPathComponent("memories.json")
        let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((metadata[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try Data("broken".utf8).write(to: file)
        do {
            _ = try await store.load(projectID: projectID)
            XCTFail("Expected corrupt document rejection")
        } catch AgentLocalMemoryError.corruptStore {}
        do {
            _ = try await store.clear(projectID: projectID)
            XCTFail("Mutations must not overwrite a corrupt document")
        } catch AgentLocalMemoryError.corruptStore {}
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))

        let outside = base.appendingPathComponent("outside.json")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do {
            _ = try await store.load(projectID: projectID)
            XCTFail("Expected symlink rejection")
        } catch AgentLocalMemoryError.unsafeStorage {}
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testRejectsSymlinkedStorageRootAndProjectDirectory() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let projectID = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)
        do {
            _ = try await store.setEnabled(true, projectID: projectID)
            XCTFail("Expected symlinked root rejection")
        } catch AgentLocalMemoryError.unsafeStorage {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectDirectory = root.appendingPathComponent(
            projectID.uuidString.lowercased(), isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: outside)
        do {
            _ = try await store.load(projectID: projectID)
            XCTFail("Expected symlinked project directory rejection")
        } catch AgentLocalMemoryError.unsafeStorage {}
    }

    func testProjectDeletionRemovesEvenCorruptMemoryFile() async throws {
        let (base, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectID = UUID()
        let store = AgentLocalMemoryStore(storageRoot: root)
        _ = try await store.setEnabled(true, projectID: projectID)
        let file = root.appendingPathComponent(projectID.uuidString.lowercased())
            .appendingPathComponent("memories.json")
        try Data("broken".utf8).write(to: file)
        try await store.delete(projectID: projectID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let restored = try await store.load(projectID: projectID)
        XCTAssertFalse(restored.enabled)
        XCTAssertTrue(restored.entries.isEmpty)
    }

    private func makeRoot() throws -> (URL, URL) {
        let base = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "local-memory-tests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, base.appendingPathComponent("AgentMemories", isDirectory: true))
    }
}
