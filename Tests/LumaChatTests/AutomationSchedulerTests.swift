import Foundation
import XCTest

@testable import LumaChat

private actor MemoryAutomationStore: AutomationPersisting {
    private var storedSnapshot: AutomationSnapshot
    private var saveCount = 0

    init(snapshot: AutomationSnapshot = AutomationSnapshot()) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() async throws -> AutomationSnapshot {
        storedSnapshot
    }

    func saveSnapshot(_ snapshot: AutomationSnapshot) async throws {
        storedSnapshot = snapshot
        saveCount += 1
    }

    func capturedSnapshot() -> AutomationSnapshot {
        storedSnapshot
    }

    func capturedSaveCount() -> Int {
        saveCount
    }
}

private final class AutomationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor AutomationExecutionProbe {
    private var requests: [AutomationExecutionRequest] = []

    func record(_ request: AutomationExecutionRequest) {
        requests.append(request)
    }

    func capturedRequests() -> [AutomationExecutionRequest] {
        requests
    }
}

final class AutomationSchedulerTests: XCTestCase {
    func testOneTimeScheduleQueuesExactlyOnceAcrossTicksAndRestart() async throws {
        let current = Self.date("2025-01-02T12:00:00Z")
        let clock = AutomationTestClock(current)
        let store = MemoryAutomationStore()
        let definition = Self.definition(
            name: "One time",
            schedule: .oneTime(at: current.addingTimeInterval(-10)),
            createdAt: current.addingTimeInterval(-60)
        )
        let scheduler = Self.scheduler(store: store, clock: clock)

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        var runs = try await scheduler.listRuns(automationID: definition.id)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .queued)
        XCTAssertTrue(runs.first?.occurrenceKey.hasPrefix("once:") == true)

        clock.advance(by: 600)
        try await scheduler.tick()
        runs = try await scheduler.listRuns(automationID: definition.id)
        XCTAssertEqual(runs.count, 1, "A one-time occurrence must not be claimed twice.")
        try await scheduler.shutdown()

        let restarted = Self.scheduler(store: store, clock: clock)
        try await restarted.start()
        runs = try await restarted.listRuns(automationID: definition.id)
        XCTAssertEqual(runs.count, 1, "A persisted one-time claim must survive restart.")
        try await restarted.shutdown()
    }

    func testIntervalMissedRunPoliciesSkipRunOnceAndBoundCatchUp() async throws {
        let anchor = Self.date("2025-02-01T00:00:00Z")
        let current = anchor.addingTimeInterval(4 * 300 + 120)
        let clock = AutomationTestClock(current)
        let skip = Self.definition(
            name: "Skip",
            schedule: .interval(every: 300, anchor: anchor),
            missedRunPolicy: .skip,
            createdAt: anchor
        )
        let runOnce = Self.definition(
            name: "Run once",
            schedule: .interval(every: 300, anchor: anchor),
            missedRunPolicy: .runOnce,
            createdAt: anchor
        )
        let catchUp = Self.definition(
            name: "Catch up",
            schedule: .interval(every: 300, anchor: anchor),
            missedRunPolicy: .catchUp(maxRuns: 3),
            createdAt: anchor
        )
        let initial = AutomationSnapshot(
            automations: [skip, runOnce, catchUp],
            schedulerState: AutomationSchedulerState(lastEvaluationAt: anchor)
        )
        let scheduler = Self.scheduler(
            store: MemoryAutomationStore(snapshot: initial),
            clock: clock
        )

        try await scheduler.start()
        let skipRuns = try await scheduler.listRuns(automationID: skip.id)
        let runOnceRuns = try await scheduler.listRuns(automationID: runOnce.id)
        let catchUpRuns = try await scheduler.listRuns(automationID: catchUp.id)

        XCTAssertEqual(skipRuns.count, 1)
        XCTAssertEqual(skipRuns.first?.status, .skipped)
        XCTAssertEqual(skipRuns.first?.scheduledAt, anchor.addingTimeInterval(1_200))
        XCTAssertEqual(runOnceRuns.count, 1)
        XCTAssertEqual(runOnceRuns.first?.status, .queued)
        XCTAssertEqual(runOnceRuns.first?.scheduledAt, anchor.addingTimeInterval(1_200))
        XCTAssertEqual(catchUpRuns.count, 3)
        XCTAssertEqual(
            catchUpRuns.map(\.scheduledAt).sorted(),
            [600, 900, 1_200].map { anchor.addingTimeInterval(TimeInterval($0)) }
        )
        XCTAssertTrue(catchUpRuns.allSatisfy { $0.status == .queued })
        try await scheduler.shutdown()
    }

    func testCronScheduleUsesTimeZoneAndQueuesNewestBoundedOccurrences() async throws {
        let baseline = Self.date("2025-03-03T12:02:00Z")
        let current = Self.date("2025-03-03T12:05:20Z")
        let clock = AutomationTestClock(current)
        let cron = AutomationCronSchedule(expression: "* * * * *", timeZoneIdentifier: "UTC")
        let definition = Self.definition(
            name: "Cron",
            schedule: .cron(cron),
            missedRunPolicy: .catchUp(maxRuns: 2),
            createdAt: baseline
        )
        let initial = AutomationSnapshot(
            automations: [definition],
            schedulerState: AutomationSchedulerState(lastEvaluationAt: baseline)
        )
        let scheduler = Self.scheduler(
            store: MemoryAutomationStore(snapshot: initial),
            clock: clock
        )

        try await scheduler.start()
        let runs = try await scheduler.listRuns(automationID: definition.id)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(
            runs.map(\.scheduledAt).sorted(),
            [
                Self.date("2025-03-03T12:04:00Z"),
                Self.date("2025-03-03T12:05:00Z")
            ]
        )
        XCTAssertTrue(runs.allSatisfy { $0.occurrenceKey.hasPrefix("cron:") })
        let matchesExpectedMinute = try cron.matches(Self.date("2025-03-03T12:05:00Z"))
        XCTAssertTrue(matchesExpectedMinute)
        try await scheduler.shutdown()
    }

    func testEventFilterAndProducerIDDeduplicateDurably() async throws {
        let current = Self.date("2025-04-01T08:00:00Z")
        let clock = AutomationTestClock(current)
        let store = MemoryAutomationStore()
        let probe = AutomationExecutionProbe()
        let definition = Self.definition(
            name: "GitHub push",
            schedule: .event(AutomationEventTrigger(
                name: "github.push",
                matchingPayload: ["repository": "acme/luma"]
            )),
            createdAt: current
        )
        let scheduler = Self.scheduler(
            store: store,
            clock: clock,
            executor: { request in
                await probe.record(request)
                return AutomationExecutionOutcome(
                    status: .succeeded,
                    result: AutomationRunResult(summary: "handled")
                )
            }
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        let ignored = try await scheduler.emitEvent(AutomationEvent(
            id: "delivery-1",
            name: "github.push",
            occurredAt: current,
            payload: ["repository": "other/repo"]
        ))
        XCTAssertTrue(ignored.isEmpty)

        let event = AutomationEvent(
            id: "delivery-2",
            name: "github.push",
            occurredAt: current,
            payload: ["repository": "acme/luma", "ref": "refs/heads/main"]
        )
        let firstEmission = try await scheduler.emitEvent(event)
        let duplicateEmission = try await scheduler.emitEvent(event)
        let first = try XCTUnwrap(firstEmission.first)
        let duplicate = try XCTUnwrap(duplicateEmission.first)
        XCTAssertEqual(duplicate.id, first.id)

        let terminal = try await Self.waitForTerminalRun(first.id, scheduler: scheduler)
        XCTAssertEqual(terminal.status, .succeeded)
        let requests = await probe.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.run.id, first.id)

        let persisted = await store.capturedSnapshot()
        XCTAssertEqual(persisted.runs.filter { $0.automationID == definition.id }.count, 1)
        XCTAssertEqual(
            persisted.schedulerState.occurrenceClaims.filter { $0.runID == first.id }.count,
            1
        )
        try await scheduler.shutdown()
    }

    func testManualRunIdempotencyKeyDeduplicatesButKeylessRunsStayDistinct() async throws {
        let current = Self.date("2025-05-01T08:00:00Z")
        let clock = AutomationTestClock(current)
        let probe = AutomationExecutionProbe()
        let definition = Self.definition(
            name: "Manual",
            schedule: .event(AutomationEventTrigger(name: "manual-only")),
            createdAt: current
        )
        let scheduler = Self.scheduler(
            store: MemoryAutomationStore(),
            clock: clock,
            maximumConcurrentRuns: 4,
            executor: { request in
                await probe.record(request)
                return AutomationExecutionOutcome(status: .succeeded)
            }
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        let first = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: " caller-request-42 "
        )
        let retry = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "caller-request-42"
        )
        XCTAssertEqual(first.id, retry.id)

        let keylessA = try await scheduler.runNow(automationID: definition.id)
        let keylessB = try await scheduler.runNow(automationID: definition.id)
        XCTAssertNotEqual(keylessA.id, keylessB.id)
        _ = try await Self.waitForTerminalRun(first.id, scheduler: scheduler)
        _ = try await Self.waitForTerminalRun(keylessA.id, scheduler: scheduler)
        _ = try await Self.waitForTerminalRun(keylessB.id, scheduler: scheduler)
        let requests = await probe.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        try await scheduler.shutdown()
    }

    func testRestartMarksPersistedRunningRunInterruptedWithoutReexecution() async throws {
        let started = Self.date("2025-06-01T09:00:00Z")
        let current = started.addingTimeInterval(90)
        let clock = AutomationTestClock(current)
        let definition = Self.definition(
            name: "Restart recovery",
            schedule: .event(AutomationEventTrigger(name: "fixture")),
            createdAt: started.addingTimeInterval(-60)
        )
        let running = AutomationRunRecord(
            automationID: definition.id,
            occurrenceKey: "event:fixture:delivery",
            scheduledAt: started,
            startedAt: started,
            status: .running,
            log: [AutomationLogEntry(timestamp: started, message: "Run started.")],
            worktree: AutomationRunWorktree(requestedMode: .dedicated)
        )
        let store = MemoryAutomationStore(snapshot: AutomationSnapshot(
            automations: [definition],
            runs: [running],
            schedulerState: AutomationSchedulerState(
                lastEvaluationAt: started,
                occurrenceClaims: [AutomationOccurrenceClaim(
                    key: "\(definition.id.uuidString.lowercased()):\(running.occurrenceKey)",
                    claimedAt: started,
                    runID: running.id
                )]
            )
        ))
        let probe = AutomationExecutionProbe()
        let scheduler = Self.scheduler(
            store: store,
            clock: clock,
            executor: { request in
                await probe.record(request)
                return AutomationExecutionOutcome(status: .succeeded)
            }
        )

        try await scheduler.start()
        let recovered = try await scheduler.run(id: running.id)
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertEqual(recovered.endedAt, current)
        XCTAssertTrue(recovered.errorMessage?.contains("尚在執行") == true)
        XCTAssertTrue(recovered.log.contains { $0.message.contains("restart") })
        let requests = await probe.capturedRequests()
        XCTAssertTrue(requests.isEmpty, "Interrupted work must not be silently re-executed.")
        let persisted = await store.capturedSnapshot()
        XCTAssertEqual(persisted.runs.first?.status, .interrupted)
        try await scheduler.shutdown()
    }

    func testRecurringMutationActionsRequireDedicatedWorktree() throws {
        let now = Self.date("2025-07-01T10:00:00Z")
        let schedules: [AutomationSchedule] = [
            .interval(every: 60, anchor: now),
            .cron(AutomationCronSchedule(expression: "0 * * * *")),
            .event(AutomationEventTrigger(name: "filesystem.changed"))
        ]

        for schedule in schedules {
            let unsafe = Self.definition(
                name: "Unsafe recurring mutation",
                schedule: schedule,
                worktreeMode: .reuseProject,
                createdAt: now
            )
            XCTAssertThrowsError(try AutomationValidation.validatedDefinition(unsafe)) { error in
                guard let automationError = error as? AutomationError,
                      case .invalidDefinition(let detail) = automationError else {
                    return XCTFail("Expected invalidDefinition, got \(error)")
                }
                XCTAssertTrue(detail.contains("dedicated worktree"))
            }
        }

        let safe = Self.definition(
            name: "Safe recurring mutation",
            schedule: .cron(AutomationCronSchedule(expression: "0 * * * *")),
            worktreeMode: .dedicated,
            createdAt: now
        )
        XCTAssertNoThrow(try AutomationValidation.validatedDefinition(safe))

        let oneTimeMainCheckout = Self.definition(
            name: "Explicit one time",
            schedule: .oneTime(at: now.addingTimeInterval(60)),
            worktreeMode: .reuseProject,
            createdAt: now
        )
        XCTAssertNoThrow(try AutomationValidation.validatedDefinition(oneTimeMainCheckout))

        let readOnlyRecurring = AutomationDefinition(
            name: "Read-only repository check",
            schedule: .interval(every: 60, anchor: now),
            task: AutomationTaskSpec(
                actionKind: .repositoryCheck,
                prompt: "Inspect status",
                worktreeMode: .reuseProject,
                command: AutomationCommandInvocation(executable: "git", arguments: ["status"])
            ),
            createdAt: now,
            updatedAt: now
        )
        XCTAssertNoThrow(try AutomationValidation.validatedDefinition(readOnlyRecurring))
    }

    func testHistoryFilteringOrderingAndMarkDedicatedWorktreeDiscarded() async throws {
        let base = Self.date("2025-08-01T11:00:00Z")
        let clock = AutomationTestClock(base.addingTimeInterval(300))
        let definition = Self.definition(
            name: "History",
            schedule: .event(AutomationEventTrigger(name: "history")),
            createdAt: base.addingTimeInterval(-60)
        )
        let other = Self.definition(
            name: "Other history",
            schedule: .event(AutomationEventTrigger(name: "other")),
            createdAt: base.addingTimeInterval(-60)
        )
        let oldest = Self.terminalRun(
            automationID: definition.id,
            occurrenceKey: "history-1",
            scheduledAt: base,
            worktreeMode: .dedicated
        )
        let newest = Self.terminalRun(
            automationID: definition.id,
            occurrenceKey: "history-2",
            scheduledAt: base.addingTimeInterval(120),
            worktreeMode: .dedicated,
            worktreePath: AppPaths.projectTemporaryRoot
                .appendingPathComponent("automation-history-fixture", isDirectory: true)
                .path
        )
        let unrelated = Self.terminalRun(
            automationID: other.id,
            occurrenceKey: "other-1",
            scheduledAt: base.addingTimeInterval(240),
            worktreeMode: .none
        )
        let store = MemoryAutomationStore(snapshot: AutomationSnapshot(
            automations: [definition, other],
            runs: [oldest, newest, unrelated]
        ))
        let scheduler = Self.scheduler(store: store, clock: clock)

        try await scheduler.start()
        let filtered = try await scheduler.listRuns(automationID: definition.id, limit: 1)
        let allRuns = try await scheduler.listRuns(limit: 10)
        XCTAssertEqual(filtered.map(\.id), [newest.id])
        XCTAssertEqual(allRuns.count, 3)

        let discarded = try await scheduler.markWorktreeDiscarded(runID: newest.id)
        XCTAssertFalse(discarded.worktree.retained)
        XCTAssertEqual(discarded.worktree.path, newest.worktree.path)
        XCTAssertTrue(discarded.log.contains { $0.message.contains("discarded by user") })

        let secondDiscard = try await scheduler.markWorktreeDiscarded(runID: newest.id)
        let retainedHistory = try await scheduler.listRuns(automationID: definition.id)
        XCTAssertEqual(secondDiscard.log.count, discarded.log.count, "Discard marking is idempotent.")
        XCTAssertEqual(retainedHistory.count, 2)
        let persisted = await store.capturedSnapshot()
        let saveCount = await store.capturedSaveCount()
        XCTAssertEqual(persisted.runs.first(where: { $0.id == newest.id })?.worktree.retained, false)
        XCTAssertGreaterThan(saveCount, 0)

        do {
            _ = try await scheduler.markWorktreeDiscarded(runID: unrelated.id)
            XCTFail("A non-dedicated run must reject discard marking.")
        } catch AutomationError.invalidRun(let detail) {
            XCTAssertTrue(detail.contains("dedicated"))
        }
        try await scheduler.shutdown()
    }

    private static func scheduler(
        store: MemoryAutomationStore,
        clock: AutomationTestClock,
        maximumConcurrentRuns: Int = 2,
        executor: AutomationExecutionHandler? = nil
    ) -> AutomationScheduler {
        AutomationScheduler(
            store: store,
            executor: executor,
            artifactRoot: AppPaths.projectTemporaryRoot
                .appendingPathComponent("automation-scheduler-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true),
            pollingSeconds: 1,
            maximumConcurrentRuns: maximumConcurrentRuns,
            now: clock.now
        )
    }

    private static func definition(
        name: String,
        schedule: AutomationSchedule,
        missedRunPolicy: AutomationMissedRunPolicy = .runOnce,
        worktreeMode: AutomationWorktreeMode = .dedicated,
        createdAt: Date
    ) -> AutomationDefinition {
        AutomationDefinition(
            name: name,
            schedule: schedule,
            task: AutomationTaskSpec(prompt: "Perform \(name)", worktreeMode: worktreeMode),
            missedRunPolicy: missedRunPolicy,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private static func terminalRun(
        automationID: UUID,
        occurrenceKey: String,
        scheduledAt: Date,
        worktreeMode: AutomationWorktreeMode,
        worktreePath: String? = nil
    ) -> AutomationRunRecord {
        AutomationRunRecord(
            automationID: automationID,
            occurrenceKey: occurrenceKey,
            scheduledAt: scheduledAt,
            startedAt: scheduledAt,
            endedAt: scheduledAt.addingTimeInterval(1),
            status: .succeeded,
            log: [AutomationLogEntry(timestamp: scheduledAt, message: "Completed.")],
            result: AutomationRunResult(summary: "Completed."),
            worktree: AutomationRunWorktree(
                requestedMode: worktreeMode,
                path: worktreePath,
                retained: true
            )
        )
    }

    private static func waitForTerminalRun(
        _ id: UUID,
        scheduler: AutomationScheduler
    ) async throws -> AutomationRunRecord {
        for _ in 0..<200 {
            let run = try await scheduler.run(id: id)
            if run.status.isTerminal { return run }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for Automation run \(id.uuidString).")
        return try await scheduler.run(id: id)
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
