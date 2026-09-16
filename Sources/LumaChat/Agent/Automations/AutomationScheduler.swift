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
    private var isStarted = false

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
        guard !isStarted else { return }
        try validateArtifactRoot()
        var loaded = try await store.loadSnapshot()
        let current = now()
        var recovered = false
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
            recovered = true
        }
        snapshot = loaded
        do {
            try evaluateDueSchedules(at: current, recovery: true)
            pruneBoundedHistory()
            try await persist()
        } catch {
            snapshot = AutomationSnapshot()
            throw error
        }
        _ = recovered
        isStarted = true
        timerTask = makeTimerTask()
        await publish()
        await launchQueuedRuns()
    }

    /// Graceful shutdown preserves queued work and records currently executing
    /// callbacks as interrupted. It never removes run artifacts or worktrees.
    func shutdown() async throws {
        guard isStarted else { return }
        timerTask?.cancel()
        timerTask = nil
        let current = now()
        for (id, task) in executionTasks {
            task.cancel()
            if let index = snapshot.runs.firstIndex(where: { $0.id == id && $0.status == .running }) {
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
        }
        executionTasks.removeAll()
        try await persist()
        isStarted = false
        await publish()
    }

    func tick() async throws {
        try ensureStarted()
        try evaluateDueSchedules(at: now(), recovery: false)
        pruneBoundedHistory()
        try await persist()
        await publish()
        await launchQueuedRuns()
    }

    func createAutomation(_ input: AutomationDefinition) async throws -> AutomationDefinition {
        try ensureStarted()
        guard snapshot.automations.count < AutomationLimits.maximumAutomations else {
            throw AutomationError.capacityExceeded("最多 256 個 Automation。")
        }
        let definition = try AutomationValidation.validatedDefinition(input)
        guard !snapshot.automations.contains(where: { $0.id == definition.id }) else {
            throw AutomationError.duplicateAutomation(definition.id)
        }
        let previous = snapshot
        snapshot.automations.append(definition)
        do {
            try evaluateDueSchedules(at: now(), recovery: false)
            pruneBoundedHistory()
            try await persist()
        } catch {
            snapshot = previous
            throw error
        }
        await publish()
        await launchQueuedRuns()
        return definition
    }

    func updateAutomation(_ input: AutomationDefinition) async throws -> AutomationDefinition {
        try ensureStarted()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == input.id }) else {
            throw AutomationError.automationNotFound(input.id)
        }
        let old = snapshot.automations[index]
        var candidate = input
        candidate.createdAt = old.createdAt
        candidate.updatedAt = max(now(), old.createdAt)
        candidate = try AutomationValidation.validatedDefinition(candidate)
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
            snapshot = previous
            throw error
        }
        await publish()
        await launchQueuedRuns()
        return candidate
    }

    @discardableResult
    func setAutomationEnabled(id: UUID, enabled: Bool) async throws -> AutomationDefinition {
        try ensureStarted()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == id }) else {
            throw AutomationError.automationNotFound(id)
        }
        let previous = snapshot
        snapshot.automations[index].isEnabled = enabled
        snapshot.automations[index].updatedAt = max(now(), snapshot.automations[index].createdAt)
        do { try await persist() } catch {
            snapshot = previous
            throw error
        }
        await publish()
        return snapshot.automations[index]
    }

    /// Removes only the definition. History, worktrees and artifacts are
    /// deliberately retained. Active or queued runs must be resolved first.
    func removeAutomation(id: UUID) async throws {
        try ensureStarted()
        guard let index = snapshot.automations.firstIndex(where: { $0.id == id }) else {
            throw AutomationError.automationNotFound(id)
        }
        guard !snapshot.runs.contains(where: { $0.automationID == id && !$0.status.isTerminal }) else {
            throw AutomationError.activeRuns(id)
        }
        let previous = snapshot
        snapshot.automations.remove(at: index)
        snapshot.schedulerState.lastScheduledAtByAutomation.removeValue(forKey: id)
        do { try await persist() } catch {
            snapshot = previous
            throw error
        }
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
        return snapshot.runs
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
        guard let run = snapshot.runs.first(where: { $0.id == id }) else {
            throw AutomationError.runNotFound(id)
        }
        return run
    }

    func currentSnapshot() throws -> AutomationSnapshot {
        try ensureStarted()
        return snapshot
    }

    /// A supplied idempotency key is stable across caller retries. Without one,
    /// every manual request is intentionally a new occurrence.
    func runNow(
        automationID: UUID,
        idempotencyKey: String? = nil
    ) async throws -> AutomationRunRecord {
        try ensureStarted()
        guard executor != nil else { throw AutomationError.unavailable }
        guard let definition = snapshot.automations.first(where: { $0.id == automationID }) else {
            throw AutomationError.automationNotFound(automationID)
        }
        let token: String
        if let idempotencyKey {
            let trimmed = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= AutomationLimits.maximumEventIDBytes else {
                throw AutomationError.invalidRun("manual idempotency key 為空或過長。")
            }
            token = Self.stableHash(trimmed)
        } else {
            token = UUID().uuidString.lowercased()
        }
        let occurrence = "manual:\(token)"
        if let existing = existingRun(automationID: automationID, occurrenceKey: occurrence) {
            return existing
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
            pruneBoundedHistory()
            try await persist()
        } catch {
            snapshot = previous
            throw error
        }
        await publish()
        await launchQueuedRuns()
        return snapshot.runs.first(where: { $0.id == record.id }) ?? record
    }

    /// Event ID + Automation ID form the durable idempotency identity. Matching
    /// filters use exact key/value equality and never execute payload text.
    func emitEvent(_ input: AutomationEvent) async throws -> [AutomationRunRecord] {
        try ensureStarted()
        guard executor != nil else { throw AutomationError.unavailable }
        let event = try AutomationValidation.validatedEvent(input, now: now())
        let definitions = snapshot.automations.filter { definition in
            guard definition.isEnabled,
                  case .event(let trigger) = definition.schedule else { return false }
            return trigger.matches(event)
        }
        guard !definitions.isEmpty else { return [] }

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
            snapshot = previous
            throw error
        }
        await publish()
        await launchQueuedRuns()
        return records.map { record in
            snapshot.runs.first(where: { $0.id == record.id }) ?? record
        }
    }

    func appendLog(
        runID: UUID,
        level: AutomationLogLevel,
        message: String
    ) async throws -> AutomationRunRecord {
        try ensureStarted()
        let validated = try AutomationValidation.validateLog(level: level, message: message)
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
            throw AutomationError.runNotFound(runID)
        }
        guard !snapshot.runs[index].status.isTerminal else {
            throw AutomationError.invalidTransition(snapshot.runs[index].status)
        }
        let previous = snapshot.runs[index]
        Self.appendBoundedLog(
            AutomationLogEntry(timestamp: now(), level: level, message: validated),
            to: &snapshot.runs[index]
        )
        do { try await persist() } catch {
            snapshot.runs[index] = previous
            throw error
        }
        await publish()
        return snapshot.runs[index]
    }

    func cancelRun(id: UUID) async throws -> AutomationRunRecord {
        try ensureStarted()
        guard let index = snapshot.runs.firstIndex(where: { $0.id == id }) else {
            throw AutomationError.runNotFound(id)
        }
        guard !snapshot.runs[index].status.isTerminal else { return snapshot.runs[index] }
        let previous = snapshot.runs[index]
        let current = now()
        snapshot.runs[index].status = .cancelled
        snapshot.runs[index].endedAt = current
        snapshot.runs[index].errorMessage = nil
        Self.appendBoundedLog(
            AutomationLogEntry(timestamp: current, level: .warning, message: "Run cancelled."),
            to: &snapshot.runs[index]
        )
        do { try await persist() } catch {
            snapshot.runs[index] = previous
            throw error
        }
        executionTasks.removeValue(forKey: id)?.cancel()
        await publish()
        await launchQueuedRuns()
        return snapshot.runs[index]
    }

    /// Records the explicit post-run discard only after the caller has removed
    /// the Task-owned worktree. Run history and artifacts remain durable.
    func markWorktreeDiscarded(runID: UUID) async throws -> AutomationRunRecord {
        try ensureStarted()
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
            throw AutomationError.runNotFound(runID)
        }
        guard snapshot.runs[index].status.isTerminal else {
            throw AutomationError.invalidTransition(snapshot.runs[index].status)
        }
        guard snapshot.runs[index].worktree.requestedMode == .dedicated else {
            throw AutomationError.invalidRun("只有 dedicated worktree 可標記為 discarded。")
        }
        guard snapshot.runs[index].worktree.retained else { return snapshot.runs[index] }
        let previous = snapshot.runs[index]
        snapshot.runs[index].worktree.retained = false
        Self.appendBoundedLog(
            AutomationLogEntry(
                timestamp: now(),
                level: .info,
                message: "Dedicated worktree discarded by user."
            ),
            to: &snapshot.runs[index]
        )
        do { try await persist() } catch {
            snapshot.runs[index] = previous
            throw error
        }
        await publish()
        return snapshot.runs[index]
    }

    private func ensureStarted() throws {
        guard isStarted else { throw AutomationError.unavailable }
    }

    private func makeTimerTask() -> Task<Void, Never> {
        let delay = pollingNanoseconds
        return Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self else { return }
                try? await self.tick()
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
            guard !isEventSchedule(definition.schedule) else { continue }
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
        guard let executor else { return }
        while executionTasks.count < maximumConcurrentRuns {
            let runningAutomationIDs = Set(snapshot.runs.compactMap {
                $0.status == .running ? $0.automationID : nil
            })
            let candidate = snapshot.runs
                .filter { $0.status == .queued && !runningAutomationIDs.contains($0.automationID) }
                .sorted {
                    if $0.scheduledAt == $1.scheduledAt { return $0.id.uuidString < $1.id.uuidString }
                    return $0.scheduledAt < $1.scheduledAt
                }
                .first
            guard let candidate,
                  let runIndex = snapshot.runs.firstIndex(where: { $0.id == candidate.id }),
                  let definition = snapshot.automations.first(where: {
                      $0.id == candidate.automationID
                  }) else { return }

            let artifactDirectory: URL
            do {
                artifactDirectory = try prepareArtifactDirectory(runID: candidate.id)
            } catch {
                await failQueuedRun(id: candidate.id, error: error)
                continue
            }

            let before = snapshot.runs[runIndex]
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
                snapshot.runs[runIndex] = before
                return
            }
            await publish()
            let request = AutomationExecutionRequest(
                definition: definition,
                run: snapshot.runs[runIndex],
                artifactDirectory: artifactDirectory
            )
            let id = candidate.id
            executionTasks[id] = Task { [weak self] in
                let outcome = await executor(request)
                await self?.executionFinished(runID: id, outcome: outcome)
            }
        }
    }

    private func failQueuedRun(id: UUID, error: Error) async {
        guard let index = snapshot.runs.firstIndex(where: { $0.id == id && $0.status == .queued }) else {
            return
        }
        let current = now()
        snapshot.runs[index].status = .failed
        snapshot.runs[index].startedAt = current
        snapshot.runs[index].endedAt = current
        snapshot.runs[index].errorMessage = error.localizedDescription
        snapshot.runs[index].result = AutomationRunResult(summary: "Run setup failed.")
        Self.appendBoundedLog(
            AutomationLogEntry(
                timestamp: current,
                level: .error,
                message: "Run setup failed: \(Self.boundedError(error.localizedDescription))"
            ),
            to: &snapshot.runs[index]
        )
        try? await persist()
        await publish()
    }

    private func executionFinished(
        runID: UUID,
        outcome: AutomationExecutionOutcome
    ) async {
        executionTasks.removeValue(forKey: runID)
        guard let index = snapshot.runs.firstIndex(where: {
            $0.id == runID && $0.status == .running
        }) else {
            await launchQueuedRuns()
            return
        }
        let previous = snapshot.runs[index]
        let current = now()
        do {
            try AutomationValidation.validateCompletion(outcome)
            if let worktree = outcome.worktree,
               worktree.requestedMode != snapshot.runs[index].worktree.requestedMode {
                throw AutomationError.invalidRun("executor 回傳的 worktree mode 不一致。")
            }
            for entry in outcome.log { Self.appendBoundedLog(entry, to: &snapshot.runs[index]) }
            snapshot.runs[index].status = outcome.status
            snapshot.runs[index].endedAt = current
            snapshot.runs[index].result = outcome.result ?? AutomationRunResult(
                summary: outcome.status == .succeeded ? "Automation completed." : "Automation ended."
            )
            snapshot.runs[index].changes = outcome.changes
            if let worktree = outcome.worktree { snapshot.runs[index].worktree = worktree }
            snapshot.runs[index].errorMessage = outcome.errorMessage
            Self.appendBoundedLog(
                AutomationLogEntry(
                    timestamp: current,
                    level: outcome.status == .failed ? .error : .info,
                    message: "Run finished with status \(outcome.status.rawValue)."
                ),
                to: &snapshot.runs[index]
            )
        } catch {
            snapshot.runs[index].status = .failed
            snapshot.runs[index].endedAt = current
            snapshot.runs[index].result = AutomationRunResult(summary: "Executor returned invalid output.")
            snapshot.runs[index].changes = []
            snapshot.runs[index].errorMessage = Self.boundedError(error.localizedDescription)
            Self.appendBoundedLog(
                AutomationLogEntry(
                    timestamp: current,
                    level: .error,
                    message: "Invalid executor output: \(Self.boundedError(error.localizedDescription))"
                ),
                to: &snapshot.runs[index]
            )
        }
        do {
            pruneBoundedHistory()
            try await persist()
        } catch {
            snapshot.runs[index] = previous
        }
        await publish()
        await launchQueuedRuns()
    }

    private func persist() async throws {
        try await store.saveSnapshot(snapshot)
    }

    private func publish() async {
        await updateHandler?(snapshot)
    }

    private func pruneBoundedHistory(reserving: Int = 0) {
        let target = max(0, AutomationLimits.maximumRuns - reserving)
        guard snapshot.runs.count > target else { return }
        let removable = snapshot.runs
            .filter(\.status.isTerminal)
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
