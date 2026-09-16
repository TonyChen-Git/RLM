import Foundation

protocol AutomationServicing: Sendable {
    func start(onUpdate: AutomationSnapshotUpdateHandler?) async throws
    func shutdown() async throws
    func refresh() async throws
    func create(_ definition: AutomationDefinition) async throws -> AutomationDefinition
    func update(_ definition: AutomationDefinition) async throws -> AutomationDefinition
    func setEnabled(id: UUID, enabled: Bool) async throws -> AutomationDefinition
    func remove(id: UUID) async throws
    func automations() async -> [AutomationDefinition]
    func runs(automationID: UUID?, limit: Int) async throws -> [AutomationRunRecord]
    func snapshot() async throws -> AutomationSnapshot
    func runNow(automationID: UUID, idempotencyKey: String?) async throws -> AutomationRunRecord
    func emit(_ event: AutomationEvent) async throws -> [AutomationRunRecord]
    func appendLog(
        runID: UUID,
        level: AutomationLogLevel,
        message: String
    ) async throws -> AutomationRunRecord
    func cancel(runID: UUID) async throws -> AutomationRunRecord
    func markWorktreeDiscarded(runID: UUID) async throws -> AutomationRunRecord
}

/// Thin application-facing facade. UI integration only needs this protocol and
/// the value models; Agent execution remains injected through the callback.
actor AutomationService: AutomationServicing {
    private let scheduler: AutomationScheduler
    private let executor: AutomationExecutionHandler

    init(
        store: any AutomationPersisting = AutomationStore(),
        artifactRoot: URL = AppPaths.projectTemporaryRoot
            .appendingPathComponent("automation-runs", isDirectory: true),
        pollingSeconds: TimeInterval = AutomationScheduler.defaultPollingSeconds,
        maximumConcurrentRuns: Int = AutomationScheduler.defaultMaximumConcurrentRuns,
        now: @escaping @Sendable () -> Date = { Date() },
        executor: @escaping AutomationExecutionHandler
    ) {
        self.executor = executor
        scheduler = AutomationScheduler(
            store: store,
            executor: executor,
            artifactRoot: artifactRoot,
            pollingSeconds: pollingSeconds,
            maximumConcurrentRuns: maximumConcurrentRuns,
            now: now
        )
    }

    func start(onUpdate: AutomationSnapshotUpdateHandler? = nil) async throws {
        try await scheduler.configure(executor: executor, onUpdate: onUpdate)
    }

    func shutdown() async throws {
        try await scheduler.shutdown()
    }

    func refresh() async throws {
        try await scheduler.tick()
    }

    func create(_ definition: AutomationDefinition) async throws -> AutomationDefinition {
        try await scheduler.createAutomation(definition)
    }

    func update(_ definition: AutomationDefinition) async throws -> AutomationDefinition {
        try await scheduler.updateAutomation(definition)
    }

    func setEnabled(id: UUID, enabled: Bool) async throws -> AutomationDefinition {
        try await scheduler.setAutomationEnabled(id: id, enabled: enabled)
    }

    func remove(id: UUID) async throws {
        try await scheduler.removeAutomation(id: id)
    }

    func automations() async -> [AutomationDefinition] {
        await scheduler.listAutomations()
    }

    func runs(
        automationID: UUID? = nil,
        limit: Int = 100
    ) async throws -> [AutomationRunRecord] {
        try await scheduler.listRuns(automationID: automationID, limit: limit)
    }

    func snapshot() async throws -> AutomationSnapshot {
        try await scheduler.currentSnapshot()
    }

    func runNow(
        automationID: UUID,
        idempotencyKey: String? = nil
    ) async throws -> AutomationRunRecord {
        try await scheduler.runNow(
            automationID: automationID,
            idempotencyKey: idempotencyKey
        )
    }

    func emit(_ event: AutomationEvent) async throws -> [AutomationRunRecord] {
        try await scheduler.emitEvent(event)
    }

    func appendLog(
        runID: UUID,
        level: AutomationLogLevel,
        message: String
    ) async throws -> AutomationRunRecord {
        try await scheduler.appendLog(runID: runID, level: level, message: message)
    }

    func cancel(runID: UUID) async throws -> AutomationRunRecord {
        try await scheduler.cancelRun(id: runID)
    }

    func markWorktreeDiscarded(runID: UUID) async throws -> AutomationRunRecord {
        try await scheduler.markWorktreeDiscarded(runID: runID)
    }
}

extension AutomationServicing {
    func start() async throws {
        try await start(onUpdate: nil)
    }

    func runs() async throws -> [AutomationRunRecord] {
        try await runs(automationID: nil, limit: 100)
    }

    func runNow(automationID: UUID) async throws -> AutomationRunRecord {
        try await runNow(automationID: automationID, idempotencyKey: nil)
    }
}
