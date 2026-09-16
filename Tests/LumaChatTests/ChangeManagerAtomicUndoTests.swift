import Foundation
import XCTest
@testable import LumaChat

private final class ChangeHistorySaveFailureProbe: @unchecked Sendable {
    enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private var failureEnabled = false

    func setFailureEnabled(_ enabled: Bool) {
        lock.lock()
        failureEnabled = enabled
        lock.unlock()
    }

    func interceptSave() throws {
        lock.lock()
        let shouldFail = failureEnabled
        lock.unlock()
        if shouldFail { throw Failure.injected }
    }
}

final class ChangeManagerAtomicUndoTests: XCTestCase {
    func testMoveRecordPreservesSourceDestinationOrderAndUndoRestoresBoth() async throws {
        let root = try makeWorkspaceRoot("move-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("z-source.txt")
        let destination = root.appendingPathComponent("a-destination.txt")
        try Data("source\n".utf8).write(to: source)

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()

        let record = try await files.moveFile(
            source: "z-source.txt",
            destination: "a-destination.txt",
            taskID: taskID
        ).change

        XCTAssertEqual(record.paths, ["z-source.txt", "a-destination.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "source\n")

        _ = try await changes.undoSpecific(taskID: taskID, changeID: record.id)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDirectoryMoveAndUndoWorkOnFilesystemsWithoutExclusiveRename() async throws {
        let root = try makeWorkspaceRoot("directory-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("payload\n".utf8).write(to: nested.appendingPathComponent("value.txt"))

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()

        let record = try await files.moveFile(
            source: "source",
            destination: "destination",
            taskID: taskID
        ).change

        XCTAssertEqual(record.paths, ["source", "destination"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("nested/value.txt"),
                encoding: .utf8
            ),
            "payload\n"
        )

        _ = try await changes.undoSpecific(taskID: taskID, changeID: record.id)
        XCTAssertEqual(
            try String(contentsOf: nested.appendingPathComponent("value.txt"), encoding: .utf8),
            "payload\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testMoveNeverOverwritesExistingDestination() async throws {
        let root = try makeWorkspaceRoot("move-no-overwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        try Data("source\n".utf8).write(to: source)
        try Data("user destination\n".utf8).write(to: destination)

        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(validator: validator)
        let files = WorkspaceFileSystem(validator: validator, changes: changes)

        await XCTAssertThrowsErrorAsync {
            _ = try await files.moveFile(
                source: "source.txt",
                destination: "destination.txt",
                taskID: UUID()
            )
        }

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source\n")
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "user destination\n"
        )
        let records = await changes.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testInjectedSaveFailureCompensatesSpecificUndoAndRetainsHistory() async throws {
        let root = try makeWorkspaceRoot("specific-save-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let probe = ChangeHistorySaveFailureProbe()
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(
            validator: validator,
            historySaveHook: { try probe.interceptSave() }
        )
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()
        let record = try await files.writeFile(
            path: "value.txt",
            content: "agent\n",
            taskID: taskID
        ).change

        probe.setFailureEnabled(true)
        do {
            _ = try await changes.undoSpecific(taskID: taskID, changeID: record.id)
            XCTFail("Injected durable-save failure must fail Undo")
        } catch let error as ChangeManagerError {
            guard case .persistentHistoryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "agent\n")
        let recordsAfterFailure = await changes.records()
        XCTAssertEqual(recordsAfterFailure, [record])

        probe.setFailureEnabled(false)
        _ = try await changes.undoSpecific(taskID: taskID, changeID: record.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")
        let recordsAfterRetry = await changes.records()
        XCTAssertTrue(recordsAfterRetry.isEmpty)
    }

    func testInjectedSaveFailureCompensatesWholeTaskUndoAllOrNothing() async throws {
        let root = try makeWorkspaceRoot("task-save-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try Data("first-before\n".utf8).write(to: firstFile)
        try Data("second-before\n".utf8).write(to: secondFile)
        let probe = ChangeHistorySaveFailureProbe()
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(
            validator: validator,
            historySaveHook: { try probe.interceptSave() }
        )
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()
        let firstRecord = try await files.writeFile(
            path: "first.txt",
            content: "first-agent\n",
            taskID: taskID
        ).change
        let secondRecord = try await files.writeFile(
            path: "second.txt",
            content: "second-agent\n",
            taskID: taskID
        ).change

        probe.setFailureEnabled(true)
        do {
            _ = try await changes.undoTask(taskID)
            XCTFail("Injected durable-save failure must fail the batch Undo")
        } catch let error as ChangeManagerError {
            guard case .persistentHistoryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), "first-agent\n")
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "second-agent\n")
        let recordsAfterFailure = await changes.records()
        XCTAssertEqual(recordsAfterFailure, [firstRecord, secondRecord])

        probe.setFailureEnabled(false)
        let undone = try await changes.undoTask(taskID)
        XCTAssertEqual(undone, [secondRecord, firstRecord])
        XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), "first-before\n")
        XCTAssertEqual(try String(contentsOf: secondFile, encoding: .utf8), "second-before\n")
        let recordsAfterRetry = await changes.records()
        XCTAssertTrue(recordsAfterRetry.isEmpty)
    }

    func testTaskUndoCompensationRestoresNewestStateForRepeatedPath() async throws {
        let root = try makeWorkspaceRoot("task-overlap-save-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("value.txt")
        try Data("before\n".utf8).write(to: file)
        let probe = ChangeHistorySaveFailureProbe()
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let changes = ChangeManager(
            validator: validator,
            historySaveHook: { try probe.interceptSave() }
        )
        let files = WorkspaceFileSystem(validator: validator, changes: changes)
        let taskID = UUID()
        let firstRecord = try await files.writeFile(
            path: "value.txt",
            content: "first-agent\n",
            taskID: taskID
        ).change
        let secondRecord = try await files.writeFile(
            path: "value.txt",
            content: "second-agent\n",
            taskID: taskID
        ).change

        probe.setFailureEnabled(true)
        await XCTAssertThrowsErrorAsync {
            _ = try await changes.undoTask(taskID)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second-agent\n")
        let recordsAfterFailure = await changes.records()
        XCTAssertEqual(recordsAfterFailure, [firstRecord, secondRecord])
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
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
