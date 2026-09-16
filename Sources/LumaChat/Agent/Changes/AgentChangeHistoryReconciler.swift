import Foundation

/// The pure result of reconciling presentation-only session cards with the
/// authoritative, workspace-scoped Undo history.
///
/// `unavailableChangeIDs` deliberately stays separate from `kept`: absence
/// from durable history can also mean retention eviction, a completed Undo,
/// or a crash after disposing the snapshot. The view-model decides how to
/// present that distinction without ever offering an action that cannot run.
struct AgentChangeHistoryReconciliation: Equatable, Sendable {
    var changes: [AgentChangeRecord]
    var recoveredChangeIDs: Set<UUID>
    var unavailableChangeIDs: Set<UUID>
}

enum AgentChangeHistoryReconciler {
    /// Converts the durable record into the exact card shape emitted by native
    /// mutation tools. Keeping this mapping centralized makes crash recovery
    /// deterministic and prevents recovered cards from changing after relaunch.
    static func makeAgentChange(from record: FileChangeRecord) -> AgentChangeRecord {
        AgentChangeRecord(
            id: record.id,
            relativePath: record.paths.first ?? fallbackPath(for: record.operation),
            destinationRelativePath: destinationPath(for: record),
            kind: changeKind(for: record.operation),
            unifiedDiff: record.diffs.map(\.diff).joined(separator: "\n"),
            snapshotPath: nil,
            createdAt: record.createdAt,
            disposition: nil
        )
    }

    /// Reconciles one session without performing I/O.
    ///
    /// Durable records missing from the session are appended in durable commit
    /// order. Existing cards are never rewritten, so historical display data
    /// and explicit `kept` dispositions remain stable. An actionable card that
    /// has no durable record is returned as unavailable for the caller to mark
    /// non-actionable before saving the repaired session.
    static func reconcile(
        sessionChanges: [AgentChangeRecord],
        durableRecords: [FileChangeRecord],
        taskID: UUID
    ) -> AgentChangeHistoryReconciliation {
        var changes = sessionChanges
        var knownIDs = Set(sessionChanges.map(\.id))
        var durableIDs = Set<UUID>()
        var recoveredIDs = Set<UUID>()

        for record in durableRecords where record.taskID == taskID {
            guard durableIDs.insert(record.id).inserted else { continue }
            if knownIDs.insert(record.id).inserted {
                changes.append(makeAgentChange(from: record))
                recoveredIDs.insert(record.id)
            }
        }

        let unavailableIDs = Set(sessionChanges.lazy.compactMap { change in
            change.disposition == nil && !durableIDs.contains(change.id)
                ? change.id
                : nil
        })

        return AgentChangeHistoryReconciliation(
            changes: changes,
            recoveredChangeIDs: recoveredIDs,
            unavailableChangeIDs: unavailableIDs
        )
    }

    private static func changeKind(for operation: FileChangeOperation) -> AgentChangeKind {
        switch operation {
        case .create, .createDirectory:
            .create
        case .delete:
            .delete
        case .move:
            .move
        case .copy:
            .copy
        case .write, .edit, .patch, .git:
            .modify
        }
    }

    private static func fallbackPath(for operation: FileChangeOperation) -> String {
        operation == .git ? ".git" : "."
    }

    private static func destinationPath(for record: FileChangeRecord) -> String? {
        guard record.operation != .git, record.paths.count > 1 else { return nil }
        return record.paths[1]
    }
}
