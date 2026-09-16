import Foundation

protocol TaskWorktreeManaging: Sendable {
    func create(
        repositoryRoot: URL,
        taskID: UUID,
        options: ManagedWorktreeCreateOptions
    ) async throws -> ManagedWorktreeRecord
    func reuse(id: UUID, taskID: UUID) async throws -> ManagedWorktreeRecord
    func release(_ lease: WorktreeLease) async throws -> ManagedWorktreeRecord
    func list() async throws -> [ManagedWorktreeRecord]
    func inspect(id: UUID) async throws -> ManagedWorktreeInspection
    func remove(id: UUID, lease: WorktreeLease?, force: Bool) async throws
    func cleanup(olderThan age: TimeInterval, now: Date?) async throws -> WorktreeMaintenanceReport
    func repair() async throws -> WorktreeMaintenanceReport
}

extension ManagedWorktreeService: TaskWorktreeManaging {}
