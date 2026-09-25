import Foundation

typealias SubagentLaunchHandler = @Sendable (SubagentRecord) async -> SubagentExecutionOutcome
typealias SubagentCancellationHandler = @Sendable (UUID) async -> Void
typealias SubagentRecordsUpdateHandler = @Sendable ([SubagentRecord]) async -> Void

enum SubagentPersistenceError: LocalizedError, Equatable, Sendable {
    case conflictingReadback
    case unreadableReadback
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .conflictingReadback:
            "Subagent 儲存出現第三方版本；已採用磁碟快照並停止後續寫入，請重新啟動 LumaChat。"
        case .unreadableReadback:
            "Subagent 儲存結果無法安全讀回；已停止後續寫入，請檢查磁碟後重新啟動 LumaChat。"
        case .recoveryRequired:
            "Subagent 儲存狀態需要重新啟動 LumaChat 後才能繼續。"
        }
    }
}

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
    private var cancellationDrainsInFlight: Set<UUID> = []
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCompletionRecords: [UUID: SubagentRecord] = [:]
    private var completionPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var schedulingPersistenceTask: Task<Void, Never>?
    private var pendingTokenUsage: [UUID: Int] = [:]
    private var tokenPersistenceInFlight: Set<UUID> = []
    private var tokenPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    /// Swift actors are re-entrant at every store await. Keep each complete
    /// in-memory mutation + durable snapshot write in one explicit critical
    /// section so a later mutation cannot be lost by an earlier rollback.
    private var persistenceMutationIsLocked = false
    private var persistenceMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var persistenceBlock: SubagentPersistenceError?
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
        await acquirePersistenceMutation()
        guard !isStarted else {
            releasePersistenceMutation()
            return
        }
        do {
            let loaded = try await store.loadRecords()
            let previousRecords = try Self.indexedRecords(loaded)
            let now = Date()
            recordsByID = try Self.indexedRecords(loaded.map { record in
                var recovered = record
                if recovered.status == .running {
                    recovered.status = .interrupted
                    recovered.error = "LumaChat 上次結束時 Subagent 尚在執行；可手動 Resume。"
                    recovered.endedAt = now
                    recovered.updatedAt = now
                }
                return recovered
            })
            try await persistTransition(from: previousRecords)
        } catch {
            releasePersistenceMutation()
            throw error
        }
        isStarted = true
        releasePersistenceMutation()
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
        let durableRecord = try await mutateAndPersist { records in
            let siblings = records.values.filter {
                $0.parentSessionID == authority.parentSessionID && $0.collectedAt == nil
            }
            guard siblings.count < SubagentValidation.maximumChildrenPerParent else {
                throw SubagentError.concurrencyLimit
            }
            guard siblings.filter({ !$0.status.isTerminal }).count
                    < SubagentValidation.maximumActiveChildrenPerParent else {
                throw SubagentError.concurrencyLimit
            }
            records[id] = record
            return record
        }
        await publish()
        await schedule()
        return recordsByID[id] ?? durableRecord
    }

    func sendSubagentMessage(
        id: UUID,
        parentSessionID: UUID,
        message rawMessage: String
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        let message = try SubagentValidation.validatedMessage(rawMessage)
        let record = try await mutateAndPersist { records in
            if let pending = pendingCompletionRecords[id] {
                throw SubagentError.invalidTransition(pending.status)
            }
            var record = try Self.ownedRecord(
                id: id,
                parentSessionID: parentSessionID,
                in: records
            )
            guard !record.status.isTerminal else {
                throw SubagentError.invalidTransition(record.status)
            }
            guard record.pendingMessages.count < 64 else {
                throw SubagentError.invalidRequest("待傳訊息已達 64 筆上限。")
            }
            record.pendingMessages.append(message)
            record.updatedAt = Date()
            records[id] = record
            return record
        }
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
            let record = try await durableRecordSnapshot(
                id: id,
                parentSessionID: parentSessionID
            )
            if record.status.isTerminal || record.status == .interrupted { return record }
            guard Date() < deadline else { throw SubagentError.waitTimedOut(timeoutSeconds) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func listSubagents(parentSessionID: UUID) async -> [SubagentRecord] {
        try? await ensureStarted()
        await waitForPersistenceMutation()
        return recordsByID.values
            .filter { $0.parentSessionID == parentSessionID }
            .sorted(by: Self.recordSort)
    }

    func cancelSubagent(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        if pendingCompletionRecords[id] != nil {
            await persistPendingCompletion(id: id)
            guard pendingCompletionRecords[id] == nil else {
                throw SubagentError.executionFailed(
                    "Subagent terminal state is still waiting for durable storage."
                )
            }
            return try await durableRecordSnapshot(id: id, parentSessionID: parentSessionID)
        }
        let cancellation = try await mutateAndPersist { records in
            if let pending = pendingCompletionRecords[id] {
                throw SubagentError.invalidTransition(pending.status)
            }
            var record = try Self.ownedRecord(
                id: id,
                parentSessionID: parentSessionID,
                in: records
            )
            guard !record.status.isTerminal else { return (record, false) }
            record.status = .cancelled
            record.error = nil
            record.endedAt = Date()
            record.updatedAt = record.endedAt ?? Date()
            records[id] = record
            return (record, true)
        }
        let record = cancellation.0
        guard cancellation.1 else { return record }
        pendingCompletionRecords.removeValue(forKey: id)
        completionPersistenceTasks.removeValue(forKey: id)?.cancel()
        pendingTokenUsage.removeValue(forKey: id)
        tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
        timeoutTasks.removeValue(forKey: id)?.cancel()
        // Cancelling the task requests shutdown; keeping it in this map retains
        // its global/provider/parent reservation until launchHandler returns.
        let execution = executionTasks[id]
        if execution != nil {
            cancellationDrainsInFlight.insert(id)
        }
        execution?.cancel()
        await cancellationHandler?(id)
        cancellationDrainsInFlight.remove(id)
        await publish()
        if executionTasks[id] == nil {
            await schedule()
        }
        return record
    }

    func resumeSubagent(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentRecord {
        try await ensureStarted()
        let record = try await mutateAndPersist { records in
            var record = try Self.ownedRecord(
                id: id,
                parentSessionID: parentSessionID,
                in: records
            )
            guard executionTasks[id] == nil else {
                throw SubagentError.executionFailed(
                    "Subagent executor is still draining cancellation."
                )
            }
            guard !cancellationDrainsInFlight.contains(id) else {
                throw SubagentError.executionFailed(
                    "Subagent cancellation cleanup is still draining."
                )
            }
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
            records[id] = record
            return record
        }
        await publish()
        await schedule()
        return record
    }

    func collectSubagentResult(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentStructuredResult {
        try await ensureStarted()
        let validated = try await mutateAndPersist { records in
            var record = try Self.ownedRecord(
                id: id,
                parentSessionID: parentSessionID,
                in: records
            )
            guard record.status.isTerminal, let result = record.result else {
                throw SubagentError.resultUnavailable
            }
            let validated = try SubagentValidation.validatedResult(result)
            record.collectedAt = Date()
            record.updatedAt = record.collectedAt ?? Date()
            records[id] = record
            return validated
        }
        await publish()
        return validated
    }

    func takePendingSubagentMessages(id: UUID) async -> [String] {
        do {
            let messages = try await mutateAndPersist { records in
                guard pendingCompletionRecords[id] == nil else { return [String]() }
                guard var record = records[id], !record.pendingMessages.isEmpty else {
                    return [String]()
                }
                let messages = record.pendingMessages
                record.pendingMessages = []
                record.updatedAt = Date()
                records[id] = record
                return messages
            }
            guard !messages.isEmpty else { return [] }
            await publish()
            return messages
        } catch {
            return []
        }
    }

    func recordSubagentTokenUsage(id: UUID, tokens: Int) async {
        guard tokens > 0 else { return }
        await waitForPersistenceMutation()
        guard pendingCompletionRecords[id] == nil,
              recordsByID[id]?.status == .running else { return }
        let existing = pendingTokenUsage[id] ?? 0
        pendingTokenUsage[id] = min(Int.max - tokens, existing) + tokens
        await flushPendingTokenUsage(id: id)
    }

    func hasOutstandingSubagents(parentSessionID: UUID) async -> Bool {
        await waitForPersistenceMutation()
        return recordsByID.values.contains {
            $0.parentSessionID == parentSessionID
                && $0.collectedAt == nil
                && (!$0.status.isTerminal || $0.result != nil)
        }
    }

    func cancelSubagents(parentSessionID: UUID) async throws {
        try await ensureStarted()
        await waitForPersistenceMutation()
        let ids = recordsByID.values
            .filter { $0.parentSessionID == parentSessionID && !$0.status.isTerminal }
            .map(\.id)
        var firstFailure: (any Error)?
        for id in ids {
            do {
                _ = try await cancelSubagent(id: id, parentSessionID: parentSessionID)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }

    // MARK: - Scheduling

    private func ensureStarted() async throws {
        if !isStarted { try await start() }
    }

    private func schedule() async {
        schedulingPersistenceTask?.cancel()
        schedulingPersistenceTask = nil
        guard let launchHandler else { return }
        while true {
            let next: SubagentRecord?
            do {
                next = try await reserveNextQueuedRecord()
            } catch {
                if persistenceBlock == nil {
                    scheduleSchedulingPersistenceRetry()
                }
                return
            }
            guard let record = next else { return }

            // Another actor message may have cancelled the durable reservation
            // after reserveNextQueuedRecord returned but before this continuation
            // resumed. Never launch a record that is no longer running.
            guard recordsByID[record.id]?.status == .running,
                  executionTasks[record.id] == nil else {
                continue
            }

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
            await publish()
        }
    }

    private func reserveNextQueuedRecord() async throws -> SubagentRecord? {
        await acquirePersistenceMutation()
        let reserved = activeReservationRecords()
        guard reserved.count < globalConcurrency else {
            releasePersistenceMutation()
            return nil
        }
        let providerCounts = Dictionary(grouping: reserved.map(\.providerKey), by: { $0 })
            .mapValues(\.count)
        let parentCounts = Dictionary(
            grouping: reserved.map(\.parentSessionID),
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
            .first else {
                releasePersistenceMutation()
                return nil
            }

        let previousRecords = recordsByID
        let now = Date()
        next.status = .running
        next.startedAt = now
        next.endedAt = nil
        next.updatedAt = now
        recordsByID[next.id] = next
        do {
            try await persistTransition(from: previousRecords)
            releasePersistenceMutation()
            return next
        } catch {
            releasePersistenceMutation()
            throw error
        }
    }

    /// `.running` covers the small durable-launch window before Task install;
    /// `executionTasks` additionally retains slots for terminal records whose
    /// cancelled executor has not returned yet.
    private func activeReservationRecords() -> [SubagentRecord] {
        recordsByID.values.filter {
            $0.status == .running
                || executionTasks[$0.id] != nil
                || cancellationDrainsInFlight.contains($0.id)
        }
    }

    private func completeExecution(id: UUID, outcome: SubagentExecutionOutcome) async {
        await acquirePersistenceMutation()
        executionTasks.removeValue(forKey: id)
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard var record = recordsByID[id], record.status == .running else {
            releasePersistenceMutation()
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
        let previousRecords = recordsByID
        recordsByID[id] = record
        do {
            try await persistTransition(from: previousRecords)
        } catch {
            pendingCompletionRecords[id] = record
            releasePersistenceMutation()
            if persistenceBlock == nil {
                scheduleCompletionPersistenceRetry(id: id)
            }
            return
        }
        pendingCompletionRecords.removeValue(forKey: id)
        pendingTokenUsage.removeValue(forKey: id)
        tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
        releasePersistenceMutation()
        await publish()
        await schedule()
    }

    private func timeOut(id: UUID) async {
        await acquirePersistenceMutation()
        guard var record = recordsByID[id], record.status == .running else {
            releasePersistenceMutation()
            return
        }
        let previousRecords = recordsByID
        record.status = .timedOut
        record.error = "Subagent 執行超過 \(record.budget.timeoutSeconds) 秒。"
        record.endedAt = Date()
        record.updatedAt = record.endedAt ?? Date()
        recordsByID[id] = record
        do {
            try await persistTransition(from: previousRecords)
        } catch {
            releasePersistenceMutation()
            if persistenceBlock == nil {
                scheduleTimeoutPersistenceRetry(id: id)
            }
            return
        }
        pendingCompletionRecords.removeValue(forKey: id)
        completionPersistenceTasks.removeValue(forKey: id)?.cancel()
        pendingTokenUsage.removeValue(forKey: id)
        tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
        let execution = executionTasks[id]
        if execution != nil {
            cancellationDrainsInFlight.insert(id)
        }
        execution?.cancel()
        timeoutTasks.removeValue(forKey: id)
        releasePersistenceMutation()
        await cancellationHandler?(id)
        cancellationDrainsInFlight.remove(id)
        await publish()
        if executionTasks[id] == nil {
            await schedule()
        }
    }

    private func persistPendingCompletion(id: UUID) async {
        completionPersistenceTasks.removeValue(forKey: id)
        await acquirePersistenceMutation()
        guard let completed = pendingCompletionRecords[id],
              let previous = recordsByID[id],
              previous.status == .running else {
            pendingCompletionRecords.removeValue(forKey: id)
            releasePersistenceMutation()
            return
        }
        let previousRecords = recordsByID
        recordsByID[id] = completed
        do {
            try await persistTransition(from: previousRecords)
        } catch {
            releasePersistenceMutation()
            if persistenceBlock == nil {
                scheduleCompletionPersistenceRetry(id: id)
            }
            return
        }
        pendingCompletionRecords.removeValue(forKey: id)
        pendingTokenUsage.removeValue(forKey: id)
        tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
        releasePersistenceMutation()
        await publish()
        await schedule()
    }

    private func scheduleCompletionPersistenceRetry(id: UUID) {
        guard completionPersistenceTasks[id] == nil else { return }
        completionPersistenceTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistPendingCompletion(id: id)
        }
    }

    private func scheduleTimeoutPersistenceRetry(id: UUID) {
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.timeOut(id: id)
        }
    }

    private func flushPendingTokenUsage(id: UUID) async {
        guard !tokenPersistenceInFlight.contains(id) else { return }
        tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
        tokenPersistenceInFlight.insert(id)
        defer { tokenPersistenceInFlight.remove(id) }

        while let tokens = pendingTokenUsage[id], tokens > 0 {
            await acquirePersistenceMutation()
            guard var record = recordsByID[id], record.status == .running else {
                releasePersistenceMutation()
                break
            }
            let previousRecords = recordsByID
            record.consumedTokens = min(Int.max - tokens, record.consumedTokens) + tokens
            record.updatedAt = Date()
            let exceededBudget = record.consumedTokens >= record.budget.totalTokens
            if exceededBudget {
                record.status = .failed
                record.error = "Subagent 已達總 token budget（\(record.budget.totalTokens)）。"
                record.endedAt = record.updatedAt
            }
            recordsByID[id] = record
            do {
                try await persistTransition(from: previousRecords)
            } catch {
                releasePersistenceMutation()
                if persistenceBlock == nil {
                    scheduleTokenPersistenceRetry(id: id)
                }
                return
            }

            let accumulated = pendingTokenUsage[id] ?? tokens
            let remaining = max(0, accumulated - tokens)
            pendingTokenUsage[id] = remaining == 0 ? nil : remaining
            if exceededBudget {
                pendingTokenUsage.removeValue(forKey: id)
                tokenPersistenceTasks.removeValue(forKey: id)?.cancel()
                pendingCompletionRecords.removeValue(forKey: id)
                completionPersistenceTasks.removeValue(forKey: id)?.cancel()
                timeoutTasks.removeValue(forKey: id)?.cancel()
                let execution = executionTasks[id]
                if execution != nil {
                    cancellationDrainsInFlight.insert(id)
                }
                execution?.cancel()
                releasePersistenceMutation()
                await cancellationHandler?(id)
                cancellationDrainsInFlight.remove(id)
                await publish()
                if executionTasks[id] == nil {
                    await schedule()
                }
                return
            }
            releasePersistenceMutation()
            await publish()
        }
        if recordsByID[id]?.status != .running {
            pendingTokenUsage.removeValue(forKey: id)
        }
        await schedule()
    }

    private func scheduleTokenPersistenceRetry(id: UUID) {
        guard tokenPersistenceTasks[id] == nil else { return }
        tokenPersistenceTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.retryPendingTokenUsage(id: id)
        }
    }

    private func retryPendingTokenUsage(id: UUID) async {
        // Clear the retry handle before entering `flushPendingTokenUsage` so
        // that function does not cancel the very Task performing the retry.
        tokenPersistenceTasks[id] = nil
        await flushPendingTokenUsage(id: id)
    }

    private func scheduleSchedulingPersistenceRetry() {
        guard schedulingPersistenceTask == nil else { return }
        schedulingPersistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.retrySchedulingAfterPersistenceFailure()
        }
    }

    private func retrySchedulingAfterPersistenceFailure() async {
        schedulingPersistenceTask = nil
        await schedule()
    }

    private func durableRecordSnapshot(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentRecord {
        await acquirePersistenceMutation()
        defer { releasePersistenceMutation() }
        return try Self.ownedRecord(
            id: id,
            parentSessionID: parentSessionID,
            in: recordsByID
        )
    }

    private nonisolated static func ownedRecord(
        id: UUID,
        parentSessionID: UUID,
        in records: [UUID: SubagentRecord]
    ) throws -> SubagentRecord {
        guard let record = records[id] else { throw SubagentError.recordNotFound(id) }
        guard record.parentSessionID == parentSessionID else { throw SubagentError.parentMismatch }
        return record
    }

    private func mutateAndPersist<Result: Sendable>(
        _ mutation: (inout [UUID: SubagentRecord]) throws -> Result
    ) async throws -> Result {
        await acquirePersistenceMutation()
        let previousRecords = recordsByID
        do {
            let result = try mutation(&recordsByID)
            try await persistTransition(from: previousRecords)
            releasePersistenceMutation()
            return result
        } catch {
            releasePersistenceMutation()
            throw error
        }
    }

    private func acquirePersistenceMutation() async {
        guard persistenceMutationIsLocked else {
            persistenceMutationIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            persistenceMutationWaiters.append(continuation)
        }
    }

    private func releasePersistenceMutation() {
        guard !persistenceMutationWaiters.isEmpty else {
            persistenceMutationIsLocked = false
            return
        }
        let continuation = persistenceMutationWaiters.removeFirst()
        continuation.resume()
    }

    private func waitForPersistenceMutation() async {
        await acquirePersistenceMutation()
        releasePersistenceMutation()
    }

    /// Resolve an atomic-write error by comparing the readable snapshot with
    /// both sides of the attempted transition. A post-rename fsync error can
    /// report failure after the proposed bytes are already authoritative; in
    /// that case rolling memory back would create a split brain.
    private func persistTransition(
        from previousRecords: [UUID: SubagentRecord]
    ) async throws {
        guard persistenceBlock == nil else {
            recordsByID = previousRecords
            throw SubagentPersistenceError.recoveryRequired
        }
        let proposedRecords = recordsByID
        do {
            try await store.saveRecords(Array(proposedRecords.values))
            return
        } catch {
            let originalError = error
            let readback: [UUID: SubagentRecord]
            do {
                readback = try Self.indexedRecords(try await store.loadRecords())
            } catch {
                recordsByID = previousRecords
                persistenceBlock = .unreadableReadback
                throw SubagentPersistenceError.unreadableReadback
            }

            if readback == proposedRecords {
                // The rename committed. Preserve the proposed state and allow
                // its corresponding side effects exactly once.
                recordsByID = proposedRecords
                return
            }
            if readback == previousRecords {
                recordsByID = previousRecords
                throw originalError
            }

            // A concurrent or otherwise unexpected writer won. Mirror the
            // actual readable snapshot, then fail closed so in-flight runtime
            // reservations cannot mutate a version they did not authorize.
            recordsByID = readback
            persistenceBlock = .conflictingReadback
            throw SubagentPersistenceError.conflictingReadback
        }
    }

    private nonisolated static func indexedRecords(
        _ records: [SubagentRecord]
    ) throws -> [UUID: SubagentRecord] {
        var indexed: [UUID: SubagentRecord] = [:]
        indexed.reserveCapacity(records.count)
        for record in records {
            guard indexed.updateValue(record, forKey: record.id) == nil else {
                throw SubagentPersistenceError.unreadableReadback
            }
        }
        return indexed
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
