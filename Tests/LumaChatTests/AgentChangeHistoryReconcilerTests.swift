import Foundation
import XCTest
@testable import LumaChat

final class AgentChangeHistoryReconcilerTests: XCTestCase {
    func testCrashGapRecoversMissingCardInDurableCommitOrder() {
        let taskID = UUID()
        let first = durableRecord(
            taskID: taskID,
            operation: .write,
            paths: ["Sources/Existing.swift"],
            diff: "first",
            timestamp: 1
        )
        let second = durableRecord(
            taskID: taskID,
            operation: .move,
            paths: ["Sources/Old.swift", "Sources/New.swift"],
            diff: "second",
            timestamp: 2
        )
        let existing = AgentChangeHistoryReconciler.makeAgentChange(from: first)

        let result = AgentChangeHistoryReconciler.reconcile(
            sessionChanges: [existing],
            durableRecords: [first, second],
            taskID: taskID
        )

        XCTAssertEqual(result.changes.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.recoveredChangeIDs, [second.id])
        XCTAssertTrue(result.unavailableChangeIDs.isEmpty)
        XCTAssertEqual(result.changes.last?.relativePath, "Sources/Old.swift")
        XCTAssertEqual(result.changes.last?.destinationRelativePath, "Sources/New.swift")
        XCTAssertEqual(result.changes.last?.kind, .move)
        XCTAssertEqual(result.changes.last?.unifiedDiff, "second")
    }

    func testRetentionEvictionMarksOnlyMissingActionableCardsUnavailable() {
        let taskID = UUID()
        let evicted = card(id: UUID(), disposition: nil, timestamp: 1)
        let kept = card(id: UUID(), disposition: .kept, timestamp: 2)
        let retained = durableRecord(
            taskID: taskID,
            operation: .edit,
            paths: ["Sources/Retained.swift"],
            diff: "retained",
            timestamp: 3
        )
        let retainedCard = AgentChangeHistoryReconciler.makeAgentChange(from: retained)

        let result = AgentChangeHistoryReconciler.reconcile(
            sessionChanges: [evicted, kept, retainedCard],
            durableRecords: [retained],
            taskID: taskID
        )

        XCTAssertEqual(result.changes, [evicted, kept, retainedCard])
        XCTAssertEqual(result.unavailableChangeIDs, [evicted.id])
        XCTAssertTrue(result.recoveredChangeIDs.isEmpty)
    }

    func testCompletedKeepAndUndoDoNotCreateFalseRecoveredCards() {
        let taskID = UUID()
        let kept = card(id: UUID(), disposition: .kept, timestamp: 1)
        let undoneButSessionSaveCrashed = card(id: UUID(), disposition: nil, timestamp: 2)

        let result = AgentChangeHistoryReconciler.reconcile(
            sessionChanges: [kept, undoneButSessionSaveCrashed],
            durableRecords: [],
            taskID: taskID
        )

        XCTAssertTrue(result.recoveredChangeIDs.isEmpty)
        XCTAssertEqual(result.unavailableChangeIDs, [undoneButSessionSaveCrashed.id])
        XCTAssertEqual(result.changes, [kept, undoneButSessionSaveCrashed])
    }

    func testMappingCoversEveryFileOperationAndIgnoresOtherTasks() {
        let taskID = UUID()
        let expectedKinds: [(FileChangeOperation, AgentChangeKind)] = [
            (.create, .create), (.createDirectory, .create),
            (.write, .modify), (.edit, .modify), (.patch, .modify),
            (.delete, .delete), (.move, .move), (.copy, .copy), (.git, .modify)
        ]

        for (operation, expectedKind) in expectedKinds {
            let record = durableRecord(
                taskID: taskID,
                operation: operation,
                paths: [],
                diff: "a\nb",
                timestamp: 1
            )
            let card = AgentChangeHistoryReconciler.makeAgentChange(from: record)
            XCTAssertEqual(card.kind, expectedKind, "Unexpected mapping for \(operation)")
            XCTAssertEqual(card.relativePath, operation == .git ? ".git" : ".")
            XCTAssertEqual(card.unifiedDiff, "a\nb")
        }

        let otherTaskRecord = durableRecord(
            taskID: UUID(),
            operation: .write,
            paths: ["Other.txt"],
            diff: "other",
            timestamp: 1
        )
        let result = AgentChangeHistoryReconciler.reconcile(
            sessionChanges: [],
            durableRecords: [otherTaskRecord],
            taskID: taskID
        )
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertTrue(result.recoveredChangeIDs.isEmpty)
    }

    func testChangeManagerReturnsOnlyRequestedTaskRecordsAfterRetention() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "change-reconcile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("zero\n".utf8).write(to: root.appendingPathComponent("value.txt"))
        let workspace = AgentWorkspace(
            name: "reconcile",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let manager = ChangeManager(validator: validator, maximumHistoryRecords: 2)
        let files = WorkspaceFileSystem(validator: validator, changes: manager)
        let firstTask = UUID()
        let secondTask = UUID()

        _ = try await files.writeFile(path: "value.txt", content: "one\n", taskID: firstTask)
        let retainedFirstTask = try await files.writeFile(
            path: "value.txt", content: "two\n", taskID: firstTask
        ).change
        let retainedSecondTask = try await files.writeFile(
            path: "value.txt", content: "three\n", taskID: secondTask
        ).change

        let firstTaskRecords = await manager.records(taskID: firstTask)
        let secondTaskRecords = await manager.records(taskID: secondTask)
        let allRecords = await manager.records()
        XCTAssertEqual(firstTaskRecords, [retainedFirstTask])
        XCTAssertEqual(secondTaskRecords, [retainedSecondTask])
        XCTAssertEqual(allRecords, [retainedFirstTask, retainedSecondTask])
    }

    func testHandoffImportRejectsDiscardIDsAcrossAnUndoLineageGap() async throws {
        let fixture = try makeChangeManagerFixture("handoff-gap")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let taskID = UUID()
        let first = try await fixture.files.writeFile(
            path: "value.txt",
            content: "one\n",
            taskID: taskID
        ).change
        let second = try await fixture.files.writeFile(
            path: "value.txt",
            content: "two\n",
            taskID: taskID
        ).change
        let third = try await fixture.files.writeFile(
            path: "value.txt",
            content: "three\n",
            taskID: taskID
        ).change
        let emptyTransfer = try await fixture.manager.exportForHandoff(taskID: UUID())

        do {
            _ = try await fixture.manager.importFromHandoff(
                emptyTransfer,
                taskID: taskID,
                discardChangeIDs: [first.id, third.id]
            )
            XCTFail("Discarding around a retained Undo record must fail closed.")
        } catch let error as ChangeManagerError {
            guard case .persistentHistoryUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let records = await fixture.manager.records()
        XCTAssertEqual(records, [first, second, third])
    }

    func testHandoffImportMayDiscardOnlyContiguousOldestUndoPrefix() async throws {
        let fixture = try makeChangeManagerFixture("handoff-prefix")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let taskID = UUID()
        let first = try await fixture.files.writeFile(
            path: "value.txt",
            content: "one\n",
            taskID: taskID
        ).change
        let second = try await fixture.files.writeFile(
            path: "value.txt",
            content: "two\n",
            taskID: taskID
        ).change
        let third = try await fixture.files.writeFile(
            path: "value.txt",
            content: "three\n",
            taskID: taskID
        ).change
        let emptyTransfer = try await fixture.manager.exportForHandoff(taskID: UUID())

        let imported = try await fixture.manager.importFromHandoff(
            emptyTransfer,
            taskID: taskID,
            discardChangeIDs: [first.id]
        )

        XCTAssertTrue(imported.isEmpty)
        let records = await fixture.manager.records()
        XCTAssertEqual(records, [second, third])
        XCTAssertEqual(
            try String(
                contentsOf: fixture.root.appendingPathComponent("value.txt"),
                encoding: .utf8
            ),
            "three\n"
        )
    }

    private func makeChangeManagerFixture(
        _ label: String
    ) throws -> (root: URL, manager: ChangeManager, files: WorkspaceFileSystem) {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("zero\n".utf8).write(to: root.appendingPathComponent("value.txt"))
        let validator = try WorkspaceSecurityValidator(workspace: AgentWorkspace(
            name: label,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        ))
        let manager = ChangeManager(validator: validator)
        return (
            root,
            manager,
            WorkspaceFileSystem(validator: validator, changes: manager)
        )
    }

    private func durableRecord(
        taskID: UUID,
        operation: FileChangeOperation,
        paths: [String],
        diff: String,
        timestamp: TimeInterval
    ) -> FileChangeRecord {
        FileChangeRecord(
            id: UUID(),
            taskID: taskID,
            operation: operation,
            paths: paths,
            diffs: [ChangedFileDiff(path: paths.first ?? ".", diff: diff)],
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func card(
        id: UUID,
        disposition: AgentChangeDisposition?,
        timestamp: TimeInterval
    ) -> AgentChangeRecord {
        AgentChangeRecord(
            id: id,
            relativePath: "Sources/Old.swift",
            destinationRelativePath: nil,
            kind: .modify,
            unifiedDiff: "old",
            snapshotPath: nil,
            createdAt: Date(timeIntervalSince1970: timestamp),
            disposition: disposition
        )
    }
}
