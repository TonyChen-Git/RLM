import Foundation

typealias SubagentLaunchHandler = @Sendable (SubagentRecord) async -> SubagentExecutionOutcome
typealias SubagentCancellationHandler = @Sendable (UUID) async -> Void
typealias SubagentRecordsUpdateHandler = @Sendable ([SubagentRecord]) async -> Void

/// Durable local scheduler for bounded child Agent work. Queue ownership lives
/// in one actor so global/provider/parent limits cannot race across UI tasks.
actor SubagentScheduler: SubagentControlling {
    static let defaultGlobalConcurrency = 4
    static let defaultProviderConcurrency = 2

    private let store: any SubagentRecordPersisting
    private let globalConcurrency: Int
    private let providerConcurrency: Int
    private let timeoutNanosecondsPerSecond: UInt64
    private var recordsByID: [UUID: SubagentRecord] = [:]
    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var launchHandler: SubagentLaunchHandler?
    private var cancellationHandler: SubagentCancellationHandler?
    private var updateHandler: SubagentRecordsUpdateHandler?
    private var isStarted = false

    init(
        store: any SubagentRecordPersisting = SubagentRecordStore(),
        globalConcurrency: Int = defaultGlobalConcurrency,
        providerConcurrency: Int = defaultProviderConcurrency,
        timeoutNanosecondsPerSecond: UInt64 = 1_000_000_000
    ) {
        self.store = store
        self.globalConcurrency = max(1, min(globalConcurrency, 16))
        self.providerConcurrency = max(1, min(providerConcurrency, 8))
        self.timeoutNanosecondsPerSecond = max(
            1,
            min(timeoutNanosecondsPerSecond, 1_000_000_000)
        )
    }

    func configure(
        launch: @escaping SubagentLaunchHandler,
        cancel: @escaping SubagentCancellationHandler,
        onUpdate: @escaping SubagentRecordsUpdateHandler
    ) async throws {
        launchHandler = launch
        cancellationHandler = cancel
        updateHandler = onUpdate
        if !isStarted {
            try await start()
        } else {
            await publish()
            await schedule()
        }
    }

    func start() async throws {
        guard !isStarted else { return }
        let loaded = try await store.loadRecords()
        let now = Date()
        recordsByID = Dictionary(uniqueKeysWithValues: loaded.map { record in
            var recovered = record
            if recovered.status == .running {
                recovered.status = .interrupted
                recovered.error = "LumaChat 上次結束時 Subagent 尚在執行；可手動 Resume。"
                recovered.endedAt = now
                recovered.updatedAt = now
            }
            return (recovered.id, recovered)
        })
        isStarted = true
        try await persist()
        await publish()
        await schedule()
    }

    func spawnSubagent(
        _ rawRequest: SubagentSpawnRequest,
        authority: SubagentAuthority
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        guard launchHandler != nil else { throw SubagentError.unavailable }
        let request = try SubagentValidation.validated(rawRequest, authority: authority)
        let siblings = recordsByID.values.filter {
            $0.parentSessionID == authority.parentSessionID && $0.collectedAt == nil
        }
        guard siblings.count < SubagentValidation.maximumChildrenPerParent else {
            throw SubagentError.concurrencyLimit
        }
        guard siblings.filter({ !$0.status.isTerminal }).count
                < SubagentValidation.maximumActiveChildrenPerParent else {
            throw SubagentError.concurrencyLimit
        }

        let now = Date()
        let id = UUID()
        let record = SubagentRecord(
            id: id,
            parentSessionID: authority.parentSessionID,
            childSessionID: id,
            goal: request.goal,
            status: .queued,
            scope: request.scope,
            context: request.context,
            budget: request.budget,
            priority: request.priority,
            providerKey: authority.providerKey,
            depth: authority.parentDepth + 1,
            consumedTokens: 0,
            attempt: 1,
            pendingMessages: [],
            startedAt: nil,
            endedAt: nil,
            createdAt: now,
            updatedAt: now,
            result: nil,
            error: nil,
            collectedAt: nil
        )
        recordsByID[id] = record
        do {
            try await persist()
        } catch {
            recordsByID.removeValue(forKey: id)
            throw error
        }
        await publish()
        await schedule()
        return recordsByID[id] ?? record
    }

    func sendSubagentMessage(
        id: UUID,
        parentSessionID: UUID,
        message rawMessage: String
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        let message = try SubagentValidation.validatedMessage(rawMessage)
        var record = try ownedRecord(id: id, parentSessionID: parentSessionID)
        guard !record.status.isTerminal else {
            throw SubagentError.invalidTransition(record.status)
        }
        guard record.pendingMessages.count < 64 else {
            throw SubagentError.invalidRequest("待傳訊息已達 64 筆上限。")
        }
        record.pendingMessages.append(message)
        record.updatedAt = Date()
        recordsByID[id] = record
        try await persist()
        await publish()
        return record
    }

    func waitForSubagent(
        id: UUID,
        parentSessionID: UUID,
        timeoutSeconds: Int
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        guard (1...300).contains(timeoutSeconds) else {
            throw SubagentError.invalidRequest("wait timeout 必須介於 1...300 秒。")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            try Task.checkCancellation()
            let record = try ownedRecord(id: id, parentSessionID: parentSessionID)
            if record.status.isTerminal || record.status == .interrupted { return record }
            guard Date() < deadline else { throw SubagentError.waitTimedOut(timeoutSeconds) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func listSubagents(parentSessionID: UUID) async -> [SubagentRecord] {
        try? await ensureStarted()
        return recordsByID.values
            .filter { $0.parentSessionID == parentSessionID }
            .sorted(by: Self.recordSort)
    }

    func cancelSubagent(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        var record = try ownedRecord(id: id, parentSessionID: parentSessionID)
        guard !record.status.isTerminal else { return record }
        record.status = .cancelled
        record.error = nil
        record.endedAt = Date()
        record.updatedAt = record.endedAt ?? Date()
        recordsByID[id] = record
        timeoutTasks.removeValue(forKey: id)?.cancel()
        executionTasks.removeValue(forKey: id)?.cancel()
        await cancellationHandler?(id)
        try await persist()
        await publish()
        await schedule()
        return record
    }

    func resumeSubagent(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        var record = try ownedRecord(id: id, parentSessionID: parentSessionID)
        switch record.status {
        case .paused, .failed, .cancelled, .timedOut, .interrupted:
            break
        case .queued, .running, .completed:
            throw SubagentError.invalidTransition(record.status)
        }
        record.status = .queued
        record.consumedTokens = 0
        record.attempt += 1
        record.startedAt = nil
        record.endedAt = nil
        record.result = nil
        record.error = nil
        record.collectedAt = nil
        record.updatedAt = Date()
        recordsByID[id] = record
        try await persist()
        await publish()
        await schedule()
        return record
    }

    func collectSubagentResult(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentStructuredResult {
        try await ensureStarted()
        var record = try ownedRecord(id: id, parentSessionID: parentSessionID)
        guard record.status.isTerminal, let result = record.result else {
            throw SubagentError.resultUnavailable
        }
        let validated = try SubagentValidation.validatedResult(result)
        record.collectedAt = Date()
        record.updatedAt = record.collectedAt ?? Date()
        recordsByID[id] = record
        try await persist()
        await publish()
        return validated
    }

    func takePendingSubagentMessages(id: UUID) async -> [String] {
        guard var record = recordsByID[id], !record.pendingMessages.isEmpty else { return [] }
        let messages = record.pendingMessages
        record.pendingMessages = []
        record.updatedAt = Date()
        recordsByID[id] = record
        try? await persist()
        await publish()
        return messages
    }

    func recordSubagentTokenUsage(id: UUID, tokens: Int) async {
        guard tokens > 0, var record = recordsByID[id], record.status == .running else { return }
        record.consumedTokens = min(Int.max - tokens, record.consumedTokens) + tokens
        record.updatedAt = Date()
        if record.consumedTokens >= record.budget.totalTokens {
            record.status = .failed
            record.error = "Subagent 已達總 token budget（\(record.budget.totalTokens)）。"
            record.endedAt = record.updatedAt
            timeoutTasks.removeValue(forKey: id)?.cancel()
            executionTasks.removeValue(forKey: id)?.cancel()
            await cancellationHandler?(id)
        }
        recordsByID[id] = record
        try? await persist()
        await publish()
        await schedule()
    }

    func hasOutstandingSubagents(parentSessionID: UUID) async -> Bool {
        recordsByID.values.contains {
            $0.parentSessionID == parentSessionID
                && $0.collectedAt == nil
                && (!$0.status.isTerminal || $0.result != nil)
        }
    }

    func cancelSubagents(parentSessionID: UUID) async {
        let ids = recordsByID.values
            .filter { $0.parentSessionID == parentSessionID && !$0.status.isTerminal }
            .map(\.id)
        for id in ids {
            _ = try? await cancelSubagent(id: id, parentSessionID: parentSessionID)
        }
    }

    // MARK: - Scheduling

    private func ensureStarted() async throws {
        if !isStarted { try await start() }
    }

    private func schedule() async {
        guard let launchHandler else { return }
        while recordsByID.values.filter({ $0.status == .running }).count < globalConcurrency {
            // Running status is the reservation. It is set before persistence
            // yields, so a re-entrant schedule call cannot over-admit work in
            // the window before the corresponding Task is installed.
            let running = recordsByID.values.filter { $0.status == .running }
            let providerCounts = Dictionary(grouping: running.map(\.providerKey), by: { $0 })
                .mapValues(\.count)
            let parentCounts = Dictionary(
                grouping: running.map(\.parentSessionID),
                by: { $0 }
            ).mapValues(\.count)
            guard var next = recordsByID.values
                .filter({ record in
                    record.status == .queued
                        && (providerCounts[record.providerKey] ?? 0) < providerConcurrency
                        && (parentCounts[record.parentSessionID] ?? 0)
                            < SubagentValidation.maximumActiveChildrenPerParent
                })
                .sorted(by: Self.queueSort)
                .first else { break }

            let now = Date()
            next.status = .running
            next.startedAt = now
            next.endedAt = nil
            next.updatedAt = now
            recordsByID[next.id] = next
            try? await persist()
            await publish()

            let record = next
            let execution = Task { [weak self] in
                let outcome = await launchHandler(record)
                await self?.completeExecution(id: record.id, outcome: outcome)
            }
            executionTasks[record.id] = execution
            let timeoutUnit = timeoutNanosecondsPerSecond
            timeoutTasks[record.id] = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(record.budget.timeoutSeconds)
                            * timeoutUnit
                    )
                    await self?.timeOut(id: record.id)
                } catch {
                    // Normal completion/cancellation owns the terminal state.
                }
            }
        }
    }

    private func completeExecution(id: UUID, outcome: SubagentExecutionOutcome) async {
        executionTasks.removeValue(forKey: id)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard var record = recordsByID[id], record.status == .running else {
            await schedule()
            return
        }
        let allowed: Set<SubagentStatus> = [.completed, .failed, .cancelled, .paused, .timedOut]
        let requested = allowed.contains(outcome.status) ? outcome.status : .failed
        record.status = requested
        let proposedResult = outcome.result ?? SubagentStructuredResult(
            summary: outcome.error ?? "Subagent ended without a structured result.",
            findings: [],
            files: [],
            commands: [],
            tests: [],
            artifacts: [],
            confidence: 0,
            unresolved: outcome.error.map { [$0] } ?? []
        )
        record.result = try? SubagentValidation.validatedResult(proposedResult)
        record.error = outcome.error
        if record.result == nil {
            record.status = .failed
            record.error = "Subagent structured result 未通過安全驗證。"
        }
        record.endedAt = Date()
        record.updatedAt = record.endedAt ?? Date()
        recordsByID[id] = record
        try? await persist()
        await publish()
        await schedule()
    }

    private func timeOut(id: UUID) async {
        guard var record = recordsByID[id], record.status == .running else { return }
        record.status = .timedOut
        record.error = "Subagent 執行超過 \(record.budget.timeoutSeconds) 秒。"
        record.endedAt = Date()
        record.updatedAt = record.endedAt ?? Date()
        recordsByID[id] = record
        executionTasks.removeValue(forKey: id)?.cancel()
        timeoutTasks.removeValue(forKey: id)?.cancel()
        await cancellationHandler?(id)
        try? await persist()
        await publish()
        await schedule()
    }

    private func ownedRecord(id: UUID, parentSessionID: UUID) throws -> SubagentRecord {
        guard let record = recordsByID[id] else { throw SubagentError.recordNotFound(id) }
        guard record.parentSessionID == parentSessionID else { throw SubagentError.parentMismatch }
        return record
    }

    private func persist() async throws {
        try await store.saveRecords(Array(recordsByID.values))
    }

    private func publish() async {
        await updateHandler?(recordsByID.values.sorted(by: Self.recordSort))
    }

    private nonisolated static func queueSort(_ lhs: SubagentRecord, _ rhs: SubagentRecord) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func recordSort(_ lhs: SubagentRecord, _ rhs: SubagentRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
