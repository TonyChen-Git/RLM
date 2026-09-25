import Darwin
import Foundation

typealias AutomationSnapshotUpdateHandler = @Sendable (AutomationSnapshot) async -> Void

/// Owns all schedule evaluation and run transitions in one actor. A queued run
/// and its occurrence claim are durably saved together before an executor is
/// allowed to observe it, which is the duplicate-prevention boundary.
actor AutomationScheduler {
    static let defaultPollingSeconds: TimeInterval = 30
    static let defaultMaximumConcurrentRuns = 2

    private let store: any AutomationPersisting
    private let now: @Sendable () -> Date
    private let artifactRoot: URL
    private let pollingSeconds: TimeInterval
    private let pollingNanoseconds: UInt64
    private let maximumConcurrentRuns: Int

    private var executor: AutomationExecutionHandler?
    private var updateHandler: AutomationSnapshotUpdateHandler?
    private var snapshot = AutomationSnapshot()
    private var timerTask: Task<Void, Never>?
    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    private var executionAutomationIDs: [UUID: UUID] = [:]
    private var pendingCompletionRecords: [UUID: AutomationRunRecord] = [:]
    private var completionPersistenceTasks: [UUID: Task<Void, Never>] = [:]
    private var isStarted = false
    private var isStarting = false
    private var isShuttingDown = false
    private var persistenceRecoveryRequired = false
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        store: any AutomationPersisting = AutomationStore(),
        executor: AutomationExecutionHandler? = nil,
        artifactRoot: URL = AppPaths.projectTemporaryRoot
            .appendingPathComponent("automation-runs", isDirectory: true),
        pollingSeconds: TimeInterval = defaultPollingSeconds,
        maximumConcurrentRuns: Int = defaultMaximumConcurrentRuns,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.executor = executor
        self.artifactRoot = artifactRoot.standardizedFileURL
        self.pollingSeconds = max(1, min(pollingSeconds, 300))
        self.pollingNanoseconds = UInt64(
            max(1, min(pollingSeconds, 300)) * 1_000_000_000
        )
        self.maximumConcurrentRuns = max(1, min(maximumConcurrentRuns, 16))
        self.now = now
    }

    func configure(
        executor: @escaping AutomationExecutionHandler,
        onUpdate: AutomationSnapshotUpdateHandler? = nil
    ) async throws {
        guard !isShuttingDown, !persistenceRecoveryRequired else {
            throw AutomationError.unavailable
        }
        self.executor = executor
        updateHandler = onUpdate
        if !isStarted {
            try await start()
        } else {
            await publish()
            await launchQueuedRuns()
        }
    }

    func start() async throws {
        guard !isShuttingDown, !persistenceRecoveryRequired else {
            throw AutomationError.unavailable
        }
        guard !isStarted else { return }
        isStarting = true
        await acquireMutationPermit()
        let durableLoaded: AutomationSnapshot
        do {
            guard !isStarted else {
                isStarting = false
                releaseMutationPermit()
                return
            }
            guard !isShuttingDown else { throw AutomationError.unavailable }
            try validateArtifactRoot()
            var loaded = try await store.loadSnapshot()
            durableLoaded = loaded
            guard !isShuttingDown else { throw AutomationError.unavailable }
            let current = now()
            for index in loaded.runs.indices where loaded.runs[index].status == .running {
                loaded.runs[index].status = .interrupted
                loaded.runs[index].endedAt = current
                loaded.runs[index].errorMessage = "App 結束時 run 尚在執行；未自動偽造或重跑結果。"
                Self.appendBoundedLog(
                    AutomationLogEntry(
                        timestamp: current,
                        level: .warning,
                        message: "Run recovered as interrupted after restart."
                    ),
                    to: &loaded.runs[index]
                )
            }
            snapshot = loaded
            try evaluateDueSchedules(at: current, recovery: true)
            pruneBoundedHistory()
        } catch {
            snapshot = AutomationSnapshot()
            isStarting = false
            releaseMutationPermit()
            throw error
        }

        do {
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(
                error,
                previous: durableLoaded
            )
            if disposition == .committed, !isShuttingDown {
                isStarted = true
                isStarting = false
                timerTask = makeTimerTask()
                releaseMutationPermit()
                await publish()
                await launchQueuedRuns()
                return
            } else {
                isStarting = false
                releaseMutationPermit()
            }
            throw error
        }
        guard !isShuttingDown else {
            isStarting = false
            releaseMutationPermit()
            throw AutomationError.unavailable
        }
        isStarted = true
        isStarting = false
        timerTask = makeTimerTask()
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
    }

    /// Graceful shutdown preserves queued work and records currently executing
    /// callbacks as interrupted. It never removes run artifacts or worktrees.
    func shutdown() async throws {
        guard isStarted || isStarting || isShuttingDown else { return }
        isShuttingDown = true
        timerTask?.cancel()
        timerTask = nil
        for task in completionPersistenceTasks.values { task.cancel() }
        completionPersistenceTasks.removeAll()
        for task in executionTasks.values { task.cancel() }

        await acquireMutationPermit()
        guard isStarted else {
            isStarting = false
            if executionTasks.isEmpty { isShuttingDown = false }
            releaseMutationPermit()
            return
        }
        let previous = snapshot
        for (id, completed) in pendingCompletionRecords {
            if let index = snapshot.runs.firstIndex(where: { $0.id == id }) {
                snapshot.runs[index] = completed
            }
        }
        let current = now()
        for index in snapshot.runs.indices where snapshot.runs[index].status == .running {
            snapshot.runs[index].status = .interrupted
            snapshot.runs[index].endedAt = current
            snapshot.runs[index].errorMessage = "Scheduler shutdown interrupted this run."
            Self.appendBoundedLog(
                AutomationLogEntry(
                    timestamp: current,
                    level: .warning,
                    message: "Run interrupted by scheduler shutdown."
                ),
                to: &snapshot.runs[index]
            )
        }
        do {
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            if disposition == .committed {
                pendingCompletionRecords.removeAll()
                persistenceRecoveryRequired = false
                isStarted = false
                let executorsDrained = executionTasks.isEmpty
                releaseMutationPermit()
                await publish()
                if executorsDrained { isShuttingDown = false }
                return
            } else {
                releaseMutationPermit()
            }
            throw error
        }
        pendingCompletionRecords.removeAll()
        persistenceRecoveryRequired = false
        isStarted = false
        let executorsDrained = executionTasks.isEmpty
        releaseMutationPermit()
        await publish()
        if executorsDrained { isShuttingDown = false }
    }

    func tick() async throws {
        try await acquireActiveMutationPermit()
        let previous = snapshot
        do {
            try evaluateDueSchedules(at: now(), recovery: false)
            pruneBoundedHistory()
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition, launchQueuedRuns: true)
            if disposition == .committed { return }
            throw error
        }
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
    }

    func createAutomation(_ input: AutomationDefinition) async throws -> AutomationDefinition {
        try await acquireActiveMutationPermit()
        guard snapshot.automations.count < AutomationLimits.maximumAutomations else {
            releaseMutationPermit()
            throw AutomationError.capacityExceeded("最多 256 個 Automation。")
        }
        let definition: AutomationDefinition
        do {
            definition = try AutomationValidation.validatedDefinition(input)
        } catch {
            releaseMutationPermit()
            throw error
        }
        guard !snapshot.automations.contains(where: { $0.id == definition.id }) else {
            releaseMutationPermit()
            throw AutomationError.duplicateAutomation(definition.id)
        }
        let previous = snapshot
        snapshot.automations.append(definition)
        do {
            try evaluateDueSchedules(at: now(), recovery: false)
            pruneBoundedHistory()
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition, launchQueuedRuns: true)
            if disposition == .committed { return definition }
            throw error
        }
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
        return definition
    }

    func updateAutomation(_ input: AutomationDefinition) async throws -> AutomationDefinition {
        try await acquireActiveMutationPermit()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == input.id }) else {
            releaseMutationPermit()
            throw AutomationError.automationNotFound(input.id)
        }
        let old = snapshot.automations[index]
        var candidate = input
        candidate.createdAt = old.createdAt
        candidate.updatedAt = max(now(), old.createdAt)
        do {
            candidate = try AutomationValidation.validatedDefinition(candidate)
        } catch {
            releaseMutationPermit()
            throw error
        }
        let previous = snapshot
        snapshot.automations[index] = candidate
        if old.schedule != candidate.schedule {
            snapshot.schedulerState.lastScheduledAtByAutomation.removeValue(forKey: candidate.id)
        }
        do {
            try evaluateDueSchedules(at: now(), recovery: false)
            pruneBoundedHistory()
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition, launchQueuedRuns: true)
            if disposition == .committed { return candidate }
            throw error
        }
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
        return candidate
    }

    @discardableResult
    func setAutomationEnabled(id: UUID, enabled: Bool) async throws -> AutomationDefinition {
        try await acquireActiveMutationPermit()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == id }) else {
            releaseMutationPermit()
            throw AutomationError.automationNotFound(id)
        }
        let previous = snapshot
        snapshot.automations[index].isEnabled = enabled
        snapshot.automations[index].updatedAt = max(now(), snapshot.automations[index].createdAt)
        let updated = snapshot.automations[index]
        do { try await persist() } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition)
            if disposition == .committed { return updated }
            throw error
        }
        releaseMutationPermit()
        await publish()
        return updated
    }

    /// Removes only the definition. History, worktrees and artifacts are
    /// deliberately retained. Active or queued runs must be resolved first.
    func removeAutomation(id: UUID) async throws {
        try await acquireActiveMutationPermit()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == id }) else {
            releaseMutationPermit()
            throw AutomationError.automationNotFound(id)
        }
        guard !snapshot.runs.contains(where: { $0.automationID == id && !$0.status.isTerminal }) else {
            releaseMutationPermit()
            throw AutomationError.activeRuns(id)
        }
        let previous = snapshot
        snapshot.automations.remove(at: index)
        snapshot.schedulerState.lastScheduledAtByAutomation.removeValue(forKey: id)
        do { try await persist() } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition)
            if disposition == .committed { return }
            throw error
        }
        releaseMutationPermit()
        await publish()
    }

    func automation(id: UUID) throws -> AutomationDefinition {
        try ensureStarted()
        guard let definition = snapshot.automations.first(where: { $0.id == id }) else {
            throw AutomationError.automationNotFound(id)
        }
        return definition
    }

    func listAutomations() -> [AutomationDefinition] {
        snapshot.automations.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
    }

    func listRuns(automationID: UUID? = nil, limit: Int = 100) throws -> [AutomationRunRecord] {
        try ensureStarted()
        guard (1...AutomationLimits.maximumRuns).contains(limit) else {
            throw AutomationError.invalidRun("history limit 超出範圍。")
        }
        return visibleSnapshot().runs
            .filter { automationID == nil || $0.automationID == automationID }
            .sorted {
                if $0.scheduledAt == $1.scheduledAt { return $0.id.uuidString > $1.id.uuidString }
                return $0.scheduledAt > $1.scheduledAt
            }
            .prefix(limit)
            .map { $0 }
    }

    func run(id: UUID) throws -> AutomationRunRecord {
        try ensureStarted()
        guard let run = visibleSnapshot().runs.first(where: { $0.id == id }) else {
            throw AutomationError.runNotFound(id)
        }
        return run
    }

    func currentSnapshot() throws -> AutomationSnapshot {
        try ensureStarted()
        return visibleSnapshot()
    }

    /// A supplied idempotency key is stable across caller retries. Without one,
    /// every manual request is intentionally a new occurrence.
    func runNow(
        automationID: UUID,
        idempotencyKey: String? = nil
    ) async throws -> AutomationRunRecord {
        try await acquireActiveMutationPermit()
        guard executor != nil else {
            releaseMutationPermit()
            throw AutomationError.unavailable
        }
        guard let definition = snapshot.automations.first(where: { $0.id == automationID }) else {
            releaseMutationPermit()
            throw AutomationError.automationNotFound(automationID)
        }
        let token: String
        if let idempotencyKey {
            let trimmed = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= AutomationLimits.maximumEventIDBytes else {
                releaseMutationPermit()
                throw AutomationError.invalidRun("manual idempotency key 為空或過長。")
            }
            token = Self.stableHash(trimmed)
        } else {
            token = UUID().uuidString.lowercased()
        }
        let occurrence = "manual:\(token)"
        if let existing = existingRun(automationID: automationID, occurrenceKey: occurrence) {
            let visible = pendingCompletionRecords[existing.id] ?? existing
            releaseMutationPermit()
            return visible
        }
        let previous = snapshot
        let record: AutomationRunRecord
        do {
            record = try enqueue(
                definition: definition,
                occurrenceKey: occurrence,
                scheduledAt: now(),
                skipped: false,
                recovery: false
            )
        } catch {
            snapshot = previous
            releaseMutationPermit()
            throw error
        }
        pruneBoundedHistory()
        do {
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition, launchQueuedRuns: true)
            if disposition == .committed { return record }
            throw error
        }
        let queued = snapshot.runs.first(where: { $0.id == record.id }) ?? record
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
        return queued
    }

    /// Event ID + Automation ID form the durable idempotency identity. Matching
    /// filters use exact key/value equality and never execute payload text.
    func emitEvent(_ input: AutomationEvent) async throws -> [AutomationRunRecord] {
        try await acquireActiveMutationPermit()
        guard executor != nil else {
            releaseMutationPermit()
            throw AutomationError.unavailable
        }
        let event: AutomationEvent
        do {
            event = try AutomationValidation.validatedEvent(input, now: now())
        } catch {
            releaseMutationPermit()
            throw error
        }
        let definitions = snapshot.automations.filter { definition in
            guard definition.isEnabled,
                  case .event(let trigger) = definition.schedule else { return false }
            return trigger.matches(event)
        }
        guard !definitions.isEmpty else {
            releaseMutationPermit()
            return []
        }

        let previous = snapshot
        var records: [AutomationRunRecord] = []
        do {
            for definition in definitions {
                let occurrence = "event:\(Self.stableHash(event.name)):\(Self.stableHash(event.id))"
                if let existing = existingRun(
                    automationID: definition.id,
                    occurrenceKey: occurrence
                ) {
                    records.append(existing)
                    continue
                }
                records.append(try enqueue(
                    definition: definition,
                    occurrenceKey: occurrence,
                    scheduledAt: event.occurredAt,
                    skipped: false,
                    recovery: false
                ))
            }
            pruneBoundedHistory()
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            let durableRecords = records.map { record in
                snapshot.runs.first(where: { $0.id == record.id }) ?? record
            }
            await finishFailedMutation(disposition, launchQueuedRuns: true)
            if disposition == .committed { return durableRecords }
            throw error
        }
        let durableRecords = records.map { record in
            snapshot.runs.first(where: { $0.id == record.id }) ?? record
        }
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
        return durableRecords
    }

    func appendLog(
        runID: UUID,
        level: AutomationLogLevel,
        message: String
    ) async throws -> AutomationRunRecord {
        try await acquireActiveMutationPermit()
        let validated: String
        do {
            validated = try AutomationValidation.validateLog(level: level, message: message)
        } catch {
            releaseMutationPermit()
            throw error
        }
        if let pending = pendingCompletionRecords[runID] {
            releaseMutationPermit()
            throw AutomationError.invalidTransition(pending.status)
        }
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
            releaseMutationPermit()
            throw AutomationError.runNotFound(runID)
        }
        guard !snapshot.runs[index].status.isTerminal else {
            releaseMutationPermit()
            throw AutomationError.invalidTransition(snapshot.runs[index].status)
        }
        let previous = snapshot
        Self.appendBoundedLog(
            AutomationLogEntry(timestamp: now(), level: level, message: validated),
            to: &snapshot.runs[index]
        )
        let updated = snapshot.runs[index]
        do { try await persist() } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition)
            if disposition == .committed { return updated }
            throw error
        }
        releaseMutationPermit()
        await publish()
        return updated
    }

    func cancelRun(id: UUID) async throws -> AutomationRunRecord {
        try await acquireActiveMutationPermit()
        if let pending = pendingCompletionRecords[id] {
            releaseMutationPermit()
            return pending
        }
        guard let index = snapshot.runs.firstIndex(where: { $0.id == id }) else {
            releaseMutationPermit()
            throw AutomationError.runNotFound(id)
        }
        guard !snapshot.runs[index].status.isTerminal else {
            let terminal = snapshot.runs[index]
            releaseMutationPermit()
            return terminal
        }
        let previous = snapshot
        let current = now()
        snapshot.runs[index].status = .cancelled
        snapshot.runs[index].endedAt = current
        snapshot.runs[index].errorMessage = nil
        Self.appendBoundedLog(
            AutomationLogEntry(timestamp: current, level: .warning, message: "Run cancelled."),
            to: &snapshot.runs[index]
        )
        let cancelled = snapshot.runs[index]
        let executionTask = executionTasks[id]
        do { try await persist() } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            releaseMutationPermit()
            if disposition == .committed {
                executionTask?.cancel()
                await publish()
                await launchQueuedRuns()
                return cancelled
            }
            throw error
        }
        releaseMutationPermit()
        executionTask?.cancel()
        await publish()
        await launchQueuedRuns()
        return cancelled
    }

    /// Records the explicit post-run discard only after the caller has removed
    /// the Task-owned worktree. Run history and artifacts remain durable.
    func markWorktreeDiscarded(runID: UUID) async throws -> AutomationRunRecord {
        try await acquireActiveMutationPermit()
        if pendingCompletionRecords[runID] != nil {
            releaseMutationPermit()
            throw AutomationError.invalidRun("run completion 尚待持久化。")
        }
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
            releaseMutationPermit()
            throw AutomationError.runNotFound(runID)
        }
        guard snapshot.runs[index].status.isTerminal else {
            releaseMutationPermit()
            throw AutomationError.invalidTransition(snapshot.runs[index].status)
        }
        guard snapshot.runs[index].worktree.requestedMode == .dedicated else {
            releaseMutationPermit()
            throw AutomationError.invalidRun("只有 dedicated worktree 可標記為 discarded。")
        }
        guard snapshot.runs[index].worktree.retained else {
            let discarded = snapshot.runs[index]
            releaseMutationPermit()
            return discarded
        }
        let previous = snapshot
        snapshot.runs[index].worktree.retained = false
        Self.appendBoundedLog(
            AutomationLogEntry(
                timestamp: now(),
                level: .info,
                message: "Dedicated worktree discarded by user."
            ),
            to: &snapshot.runs[index]
        )
        let discarded = snapshot.runs[index]
        do { try await persist() } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            await finishFailedMutation(disposition)
            if disposition == .committed { return discarded }
            throw error
        }
        releaseMutationPermit()
        await publish()
        return discarded
    }

    private func ensureStarted() throws {
        guard isStarted,
              !isShuttingDown,
              !persistenceRecoveryRequired else {
            throw AutomationError.unavailable
        }
    }

    /// Swift actors are reentrant at every `await`. Persistence is therefore
    /// protected by an explicit FIFO permit so a later mutation cannot be
    /// overwritten when an earlier save resumes and rolls back.
    private func acquireMutationPermit() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func acquireActiveMutationPermit() async throws {
        try ensureStarted()
        await acquireMutationPermit()
        do {
            try ensureStarted()
        } catch {
            releaseMutationPermit()
            throw error
        }
    }

    private func releaseMutationPermit() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private func makeTimerTask() -> Task<Void, Never> {
        let delay = pollingNanoseconds
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self else { return }
                do {
                    try await self.tick()
                } catch {
                    // tick() restores the last durable snapshot. The timer
                    // remains alive and retries on the next polling interval.
                }
            }
        }
    }

    private func evaluateDueSchedules(at current: Date, recovery: Bool) throws {
        guard current.timeIntervalSince1970.isFinite else {
            throw AutomationError.invalidSchedule("scheduler clock 無效。")
        }
        let priorEvaluation = snapshot.schedulerState.lastEvaluationAt
        let definitions = snapshot.automations.filter(\.isEnabled)
        for definition in definitions {
            guard !Self.isEventSchedule(definition.schedule) else { continue }
            let lastScheduled = snapshot.schedulerState.lastScheduledAtByAutomation[definition.id]
            let baseline = [lastScheduled, priorEvaluation, Optional(definition.createdAt)]
                .compactMap { $0 }
                .max() ?? definition.createdAt
            let due = try dueDates(
                for: definition,
                after: baseline,
                through: current
            )
            guard !due.isEmpty else { continue }

            let selected: [Date]
            switch definition.missedRunPolicy {
            case .skip, .runOnce:
                selected = [due.last!]
            case .catchUp(let maximum):
                selected = Array(due.suffix(maximum))
            }
            for date in selected {
                let occurrence = Self.scheduledOccurrenceKey(for: definition.schedule, date: date)
                let grace = max(60, pollingSeconds * 2)
                let shouldSkip = definition.missedRunPolicy == .skip
                    && current.timeIntervalSince(date) > grace
                _ = try enqueue(
                    definition: definition,
                    occurrenceKey: occurrence,
                    scheduledAt: date,
                    skipped: shouldSkip,
                    recovery: recovery
                )
            }
            if let newest = due.last {
                snapshot.schedulerState.lastScheduledAtByAutomation[definition.id] = newest
            }
        }
        snapshot.schedulerState.lastEvaluationAt = current
    }

    private func dueDates(
        for definition: AutomationDefinition,
        after baseline: Date,
        through current: Date
    ) throws -> [Date] {
        guard current >= baseline else { return [] }
        switch definition.schedule {
        case .oneTime(let date):
            guard snapshot.schedulerState.lastScheduledAtByAutomation[definition.id] == nil,
                  date <= current else { return [] }
            return [date]
        case .interval(let seconds, let anchor):
            let elapsed = current.timeIntervalSince(anchor)
            guard elapsed >= seconds else { return [] }
            let currentIndex = Int(floor(elapsed / seconds))
            let baselineIndex = Int(floor(baseline.timeIntervalSince(anchor) / seconds))
            let firstIndex = max(1, baselineIndex + 1)
            guard currentIndex >= firstIndex else { return [] }
            let wanted: Int
            switch definition.missedRunPolicy {
            case .skip, .runOnce: wanted = 1
            case .catchUp(let maximum): wanted = maximum
            }
            let selectedFirst = max(firstIndex, currentIndex - wanted + 1)
            return (selectedFirst...currentIndex).map {
                anchor.addingTimeInterval(Double($0) * seconds)
            }
        case .cron(let cron):
            let wanted: Int
            switch definition.missedRunPolicy {
            case .skip, .runOnce: wanted = 1
            case .catchUp(let maximum): wanted = maximum
            }
            return try cron.occurrences(
                after: baseline,
                through: current,
                limit: wanted,
                newestFirst: true
            )
        case .event:
            return []
        }
    }

    @discardableResult
    private func enqueue(
        definition: AutomationDefinition,
        occurrenceKey: String,
        scheduledAt: Date,
        skipped: Bool,
        recovery: Bool
    ) throws -> AutomationRunRecord {
        if let existing = existingRun(
            automationID: definition.id,
            occurrenceKey: occurrenceKey
        ) {
            return existing
        }
        guard snapshot.runs.filter({ $0.status == .queued }).count
                < AutomationLimits.maximumQueuedRuns else {
            throw AutomationError.capacityExceeded("queued runs 超過 512。")
        }
        pruneBoundedHistory(reserving: 1)
        guard snapshot.runs.count < AutomationLimits.maximumRuns else {
            throw AutomationError.capacityExceeded("run history 無法安全裁切。")
        }

        let current = now()
        let id = UUID()
        let fullClaimKey = Self.claimKey(
            automationID: definition.id,
            occurrenceKey: occurrenceKey
        )
        let message: String
        let status: AutomationRunStatus
        let startedAt: Date?
        let endedAt: Date?
        let result: AutomationRunResult?
        if skipped {
            message = recovery
                ? "Missed occurrence skipped during restart recovery."
                : "Missed occurrence skipped by policy."
            status = .skipped
            startedAt = current
            endedAt = current
            result = AutomationRunResult(summary: "Skipped missed occurrence.")
        } else {
            message = recovery
                ? "Run queued during restart recovery."
                : "Run queued."
            status = .queued
            startedAt = nil
            endedAt = nil
            result = nil
        }
        let record = AutomationRunRecord(
            id: id,
            automationID: definition.id,
            occurrenceKey: occurrenceKey,
            scheduledAt: scheduledAt,
            startedAt: startedAt,
            endedAt: endedAt,
            status: status,
            log: [AutomationLogEntry(timestamp: current, level: .info, message: message)],
            result: result,
            changes: [],
            worktree: AutomationRunWorktree(requestedMode: definition.task.worktreeMode),
            errorMessage: nil
        )
        snapshot.runs.append(record)
        snapshot.schedulerState.occurrenceClaims.append(AutomationOccurrenceClaim(
            key: fullClaimKey,
            claimedAt: current,
            runID: id
        ))
        trimClaims()
        return record
    }

    private func existingRun(
        automationID: UUID,
        occurrenceKey: String
    ) -> AutomationRunRecord? {
        let full = Self.claimKey(automationID: automationID, occurrenceKey: occurrenceKey)
        if let claim = snapshot.schedulerState.occurrenceClaims.first(where: { $0.key == full }),
           let run = snapshot.runs.first(where: { $0.id == claim.runID }) {
            return run
        }
        return snapshot.runs.first {
            $0.automationID == automationID && $0.occurrenceKey == occurrenceKey
        }
    }

    private func launchQueuedRuns() async {
        while true {
            await acquireMutationPermit()
            guard isStarted,
                  !isShuttingDown,
                  !persistenceRecoveryRequired,
                  let executor,
                  executionTasks.count < maximumConcurrentRuns else {
                releaseMutationPermit()
                return
            }
            let occupiedAutomationIDs = Set(executionAutomationIDs.values)
                .union(snapshot.runs.compactMap {
                    $0.status == .running ? $0.automationID : nil
                })
                .union(pendingCompletionRecords.values.map(\.automationID))
            let candidate = snapshot.runs
                .filter {
                    $0.status == .queued
                        && pendingCompletionRecords[$0.id] == nil
                        && !occupiedAutomationIDs.contains($0.automationID)
                }
                .sorted {
                    if $0.scheduledAt == $1.scheduledAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.scheduledAt < $1.scheduledAt
                }
                .first
            guard let candidate,
                  let runIndex = snapshot.runs.firstIndex(where: { $0.id == candidate.id }),
                  let definition = snapshot.automations.first(where: {
                      $0.id == candidate.automationID
                  }) else {
                releaseMutationPermit()
                return
            }

            let artifactDirectory: URL
            do {
                artifactDirectory = try prepareArtifactDirectory(runID: candidate.id)
            } catch {
                let current = now()
                var failed = snapshot.runs[runIndex]
                failed.status = .failed
                failed.startedAt = current
                failed.endedAt = current
                failed.errorMessage = error.localizedDescription
                failed.result = AutomationRunResult(summary: "Run setup failed.")
                Self.appendBoundedLog(
                    AutomationLogEntry(
                        timestamp: current,
                        level: .error,
                        message: "Run setup failed: \(Self.boundedError(error.localizedDescription))"
                    ),
                    to: &failed
                )
                pendingCompletionRecords[candidate.id] = failed
                let previous = snapshot
                snapshot.runs[runIndex] = failed
                var needsRetry = false
                do {
                    try await persist()
                    pendingCompletionRecords.removeValue(forKey: candidate.id)
                } catch {
                    let disposition = await reconcilePersistenceFailure(
                        error,
                        previous: previous
                    )
                    if disposition == .committed {
                        pendingCompletionRecords.removeValue(forKey: candidate.id)
                    }
                    needsRetry = disposition == .unchanged
                }
                releaseMutationPermit()
                await publish()
                if needsRetry {
                    scheduleCompletionPersistenceRetry(runID: candidate.id)
                }
                continue
            }

            let before = snapshot
            let started = now()
            snapshot.runs[runIndex].status = .running
            snapshot.runs[runIndex].startedAt = started
            Self.appendBoundedLog(
                AutomationLogEntry(timestamp: started, level: .info, message: "Run started."),
                to: &snapshot.runs[runIndex]
            )
            do {
                try await persist()
            } catch {
                let disposition = await reconcilePersistenceFailure(error, previous: before)
                if disposition != .committed {
                    releaseMutationPermit()
                    return
                }
            }
            guard isStarted,
                  !isShuttingDown,
                  !persistenceRecoveryRequired else {
                // A reentrant shutdown request arrived while the start record
                // was being saved. It will durably mark this unlaunched run as
                // interrupted; the executor must never be started here.
                releaseMutationPermit()
                return
            }
            let request = AutomationExecutionRequest(
                definition: definition,
                run: snapshot.runs[runIndex],
                artifactDirectory: artifactDirectory
            )
            let id = candidate.id
            executionAutomationIDs[id] = candidate.automationID
            executionTasks[id] = Task { [weak self] in
                let outcome = await executor(request)
                await self?.executionFinished(runID: id, outcome: outcome)
            }
            releaseMutationPermit()
            await publish()
        }
    }

    private func executionFinished(
        runID: UUID,
        outcome: AutomationExecutionOutcome
    ) async {
        await acquireMutationPermit()
        executionTasks.removeValue(forKey: runID)
        executionAutomationIDs.removeValue(forKey: runID)
        guard isStarted,
              !isShuttingDown,
              !persistenceRecoveryRequired else {
            if !isStarted, executionTasks.isEmpty { isShuttingDown = false }
            releaseMutationPermit()
            return
        }
        guard let index = snapshot.runs.firstIndex(where: {
            $0.id == runID && $0.status == .running
        }) else {
            releaseMutationPermit()
            await launchQueuedRuns()
            return
        }
        var completed = snapshot.runs[index]
        let current = now()
        do {
            try AutomationValidation.validateCompletion(outcome)
            if let worktree = outcome.worktree,
               worktree.requestedMode != completed.worktree.requestedMode {
                throw AutomationError.invalidRun("executor 回傳的 worktree mode 不一致。")
            }
            for entry in outcome.log { Self.appendBoundedLog(entry, to: &completed) }
            completed.status = outcome.status
            completed.endedAt = current
            completed.result = outcome.result ?? AutomationRunResult(
                summary: outcome.status == .succeeded ? "Automation completed." : "Automation ended."
            )
            completed.changes = outcome.changes
            if let worktree = outcome.worktree { completed.worktree = worktree }
            completed.errorMessage = outcome.errorMessage
            Self.appendBoundedLog(
                AutomationLogEntry(
                    timestamp: current,
                    level: outcome.status == .failed ? .error : .info,
                    message: "Run finished with status \(outcome.status.rawValue)."
                ),
                to: &completed
            )
        } catch {
            completed.status = .failed
            completed.endedAt = current
            completed.result = AutomationRunResult(summary: "Executor returned invalid output.")
            completed.changes = []
            completed.errorMessage = Self.boundedError(error.localizedDescription)
            Self.appendBoundedLog(
                AutomationLogEntry(
                    timestamp: current,
                    level: .error,
                    message: "Invalid executor output: \(Self.boundedError(error.localizedDescription))"
                ),
                to: &completed
            )
        }
        pendingCompletionRecords[runID] = completed
        let previous = snapshot
        snapshot.runs[index] = completed
        var needsRetry = false
        do {
            try await persist()
            pendingCompletionRecords.removeValue(forKey: runID)
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            if disposition == .committed {
                pendingCompletionRecords.removeValue(forKey: runID)
            }
            needsRetry = disposition == .unchanged
        }
        releaseMutationPermit()
        await publish()
        if needsRetry { scheduleCompletionPersistenceRetry(runID: runID) }
        await launchQueuedRuns()
    }

    private func persistPendingCompletion(runID: UUID) async {
        await acquireMutationPermit()
        completionPersistenceTasks.removeValue(forKey: runID)
        guard isStarted,
              !isShuttingDown,
              !persistenceRecoveryRequired else {
            releaseMutationPermit()
            return
        }
        guard let completed = pendingCompletionRecords[runID],
              let index = snapshot.runs.firstIndex(where: {
                  $0.id == runID && !$0.status.isTerminal
              }) else {
            pendingCompletionRecords.removeValue(forKey: runID)
            releaseMutationPermit()
            return
        }
        let previous = snapshot
        snapshot.runs[index] = completed
        do {
            try await persist()
        } catch {
            let disposition = await reconcilePersistenceFailure(error, previous: previous)
            if disposition == .committed {
                pendingCompletionRecords.removeValue(forKey: runID)
            } else {
                releaseMutationPermit()
                await publish()
                if disposition == .unchanged {
                    scheduleCompletionPersistenceRetry(runID: runID)
                }
                return
            }
        }
        pendingCompletionRecords.removeValue(forKey: runID)
        releaseMutationPermit()
        await publish()
        await launchQueuedRuns()
    }

    private func scheduleCompletionPersistenceRetry(runID: UUID) {
        guard isStarted,
              !isShuttingDown,
              !persistenceRecoveryRequired else { return }
        guard completionPersistenceTasks[runID] == nil else { return }
        completionPersistenceTasks[runID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistPendingCompletion(runID: runID)
        }
    }

    private func persist() async throws {
        try await store.saveSnapshot(snapshot)
    }

    @discardableResult
    private func reconcilePersistenceFailure(
        _ error: Error,
        previous: AutomationSnapshot
    ) async -> AutomationSnapshotSaveDisposition {
        let disposition: AutomationSnapshotSaveDisposition
        if let saveError = error as? AutomationSnapshotSaveError {
            disposition = saveError.disposition
        } else {
            do {
                let readback = try await store.loadSnapshot()
                if Self.persistenceComparable(readback)
                    == Self.persistenceComparable(snapshot) {
                    disposition = .committed
                } else if Self.persistenceComparable(readback)
                    == Self.persistenceComparable(previous) {
                    disposition = .unchanged
                } else {
                    disposition = .uncertain
                }
            } catch {
                disposition = .uncertain
            }
        }

        switch disposition {
        case .unchanged:
            snapshot = previous
        case .committed:
            break
        case .uncertain:
            persistenceRecoveryRequired = true
        }
        return disposition
    }

    /// The originating API still reports the writer error, but an exact
    /// readback of the proposed snapshot means the transition is durable. Its
    /// observable side effects must therefore run just as they do after a
    /// writer that returned normally.
    private func finishFailedMutation(
        _ disposition: AutomationSnapshotSaveDisposition,
        launchQueuedRuns shouldLaunchQueuedRuns: Bool = false
    ) async {
        releaseMutationPermit()
        guard disposition == .committed else { return }
        await publish()
        if shouldLaunchQueuedRuns { await launchQueuedRuns() }
    }

    private static func persistenceComparable(
        _ input: AutomationSnapshot
    ) -> AutomationSnapshot {
        var comparable = input
        comparable.automations.sort {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
        comparable.runs.sort {
            if $0.scheduledAt == $1.scheduledAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.scheduledAt < $1.scheduledAt
        }
        return comparable
    }

    private func publish() async {
        await updateHandler?(visibleSnapshot())
    }

    private func visibleSnapshot() -> AutomationSnapshot {
        guard !pendingCompletionRecords.isEmpty else { return snapshot }
        var visible = snapshot
        for (id, completed) in pendingCompletionRecords {
            if let index = visible.runs.firstIndex(where: { $0.id == id }) {
                visible.runs[index] = completed
            }
        }
        return visible
    }

    private func pruneBoundedHistory(reserving: Int = 0) {
        let target = max(0, AutomationLimits.maximumRuns - reserving)
        guard snapshot.runs.count > target else { return }
        let removable = snapshot.runs
            .filter {
                $0.status.isTerminal
                    && executionTasks[$0.id] == nil
                    && pendingCompletionRecords[$0.id] == nil
            }
            .sorted {
                let lhs = $0.endedAt ?? $0.scheduledAt
                let rhs = $1.endedAt ?? $1.scheduledAt
                if lhs == rhs { return $0.id.uuidString < $1.id.uuidString }
                return lhs < rhs
            }
        let removalCount = min(snapshot.runs.count - target, removable.count)
        let ids = Set(removable.prefix(removalCount).map(\.id))
        snapshot.runs.removeAll { ids.contains($0.id) }
    }

    private func trimClaims() {
        guard snapshot.schedulerState.occurrenceClaims.count
                > AutomationLimits.maximumOccurrenceClaims else { return }
        snapshot.schedulerState.occurrenceClaims = snapshot.schedulerState.occurrenceClaims
            .sorted {
                if $0.claimedAt == $1.claimedAt { return $0.key < $1.key }
                return $0.claimedAt < $1.claimedAt
            }
            .suffix(AutomationLimits.maximumOccurrenceClaims)
            .map { $0 }
    }

    private func validateArtifactRoot() throws {
        let temporaryRoot = AppPaths.projectTemporaryRoot.standardizedFileURL.path
        guard artifactRoot.isFileURL,
              artifactRoot.path.hasPrefix(temporaryRoot + "/"),
              artifactRoot.lastPathComponent != ".",
              artifactRoot.lastPathComponent != "..",
              !artifactRoot.lastPathComponent.hasPrefix("._") else {
            throw AutomationError.invalidRun("artifact root 必須位於 repository tmp。")
        }
    }

    private func prepareArtifactDirectory(runID: UUID) throws -> URL {
        try validateArtifactRoot()
        try FileManager.default.createDirectory(
            at: artifactRoot,
            withIntermediateDirectories: true
        )
        try Self.requireRealDirectory(artifactRoot)
        let directory = artifactRoot.appendingPathComponent(
            runID.uuidString.lowercased(),
            isDirectory: true
        )
        var existing = Darwin.stat()
        if Darwin.lstat(directory.path, &existing) == 0 {
            try Self.requireRealDirectory(directory)
            return directory
        }
        guard errno == ENOENT else {
            throw AutomationError.invalidRun("無法安全檢查 run artifact directory。")
        }
        if Darwin.mkdir(directory.path, mode_t(0o700)) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Self.requireRealDirectory(directory)
        return directory
    }

    private static func requireRealDirectory(_ url: URL) throws {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw AutomationError.invalidRun("artifact directory 不是安全的 real directory。")
        }
    }

    private static func appendBoundedLog(
        _ entry: AutomationLogEntry,
        to run: inout AutomationRunRecord
    ) {
        if run.log.count >= AutomationLimits.maximumLogEntriesPerRun {
            run.log.removeFirst(run.log.count - AutomationLimits.maximumLogEntriesPerRun + 1)
        }
        var bounded = entry
        if bounded.message.utf8.count > AutomationLimits.maximumLogMessageBytes {
            bounded.message = String(
                bounded.message.utf8.prefix(AutomationLimits.maximumLogMessageBytes - 3)
                    .map { Character(UnicodeScalar($0)) }
            ) + "..."
        }
        run.log.append(bounded)
    }

    private static func boundedError(_ value: String) -> String {
        guard value.utf8.count > AutomationLimits.maximumLogMessageBytes else { return value }
        return String(value.prefix(AutomationLimits.maximumLogMessageBytes / 2)) + "..."
    }

    private static func isEventSchedule(_ schedule: AutomationSchedule) -> Bool {
        if case .event = schedule { return true }
        return false
    }

    private static func scheduledOccurrenceKey(
        for schedule: AutomationSchedule,
        date: Date
    ) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
        switch schedule {
        case .oneTime: return "once:\(milliseconds)"
        case .interval: return "interval:\(milliseconds)"
        case .cron: return "cron:\(milliseconds)"
        case .event: return "event-schedule:\(milliseconds)"
        }
    }

    private static func claimKey(automationID: UUID, occurrenceKey: String) -> String {
        automationID.uuidString.lowercased() + ":" + occurrenceKey
    }

    /// Stable FNV-1a is used only to keep untrusted idempotency keys bounded in
    /// persistence. It is not a security or authentication primitive.
    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
