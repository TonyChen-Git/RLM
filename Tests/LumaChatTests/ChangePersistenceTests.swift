import Foundation
import XCTest
@testable import LumaChat

final class ChangePersistenceTests: XCTestCase {
    func testUndoHistorySurvivesManagerRecreationAndIsRemovedAfterUndo() async throws {
        try AppPaths.ensureAgentDirectories()
        let fixtureID = UUID()
        let workspaceURL = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "durable-undo-workspace-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyDirectory = AppPaths.agentSnapshots.appendingPathComponent(
            "durable-undo-test-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let fileURL = workspaceURL.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: fileURL)
        let workspace = AgentWorkspace(
            name: "durable-undo",
            rootPath: workspaceURL.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let identity = validator.secureRootPath
        let taskID = UUID()

        let firstManager = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: identity
        )
        let files = WorkspaceFileSystem(validator: validator, changes: firstManager)
        _ = try await files.writeFile(path: "value.txt", content: "agent\n", taskID: taskID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))

        let restoredManager = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: identity
        )
        let restoredRecords = await restoredManager.records()
        XCTAssertEqual(restoredRecords.count, 1)
        _ = try await restoredManager.undoLast(taskID: taskID)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "before\n")

        let thirdManager = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: identity
        )
        let recordsAfterUndo = await thirdManager.records()
        XCTAssertTrue(recordsAfterUndo.isEmpty)
    }

    func testPersistedHistoryWithAnotherWorkspaceIdentityFailsClosed() async throws {
        try AppPaths.ensureAgentDirectories()
        let fixtureID = UUID()
        let workspaceURL = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "durable-undo-identity-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyDirectory = AppPaths.agentSnapshots.appendingPathComponent(
            "durable-undo-identity-test-\(fixtureID.uuidString)",
            isDirectory: true
        )
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let fileURL = workspaceURL.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: fileURL)
        let validator = try WorkspaceSecurityValidator(workspace: AgentWorkspace(
            name: "identity",
            rootPath: workspaceURL.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        ))
        let taskID = UUID()
        let writer = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: "expected-identity"
        )
        let files = WorkspaceFileSystem(validator: validator, changes: writer)
        _ = try await files.writeFile(path: "value.txt", content: "agent\n", taskID: taskID)

        let mismatched = ChangeManager(
            validator: validator,
            historyFileURL: historyURL,
            workspaceIdentity: "different-identity"
        )
        do {
            _ = try await mismatched.undoLast(taskID: taskID)
            XCTFail("Mismatched durable history must not be restored")
        } catch let error as ChangeManagerError {
            guard case .persistentHistoryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "agent\n")
    }
}
