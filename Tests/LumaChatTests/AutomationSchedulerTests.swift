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

private enum AutomationStoreTestError: Error {
    case injectedFailure
}

private actor FailingAutomationStore: AutomationPersisting {
    private var storedSnapshot: AutomationSnapshot
    private var successfulSavesBeforeFailure: Int?
    private var repeatsFailure = false
    private var commitsBeforeFailure = false
    private var makesReadbackUnreadable = false
    private var readbackIsUnreadable = false

    init(snapshot: AutomationSnapshot = AutomationSnapshot()) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> AutomationSnapshot {
        if readbackIsUnreadable { throw AutomationStoreTestError.injectedFailure }
        return storedSnapshot
    }

    func saveSnapshot(_ snapshot: AutomationSnapshot) throws {
        if let remaining = successfulSavesBeforeFailure {
            if remaining == 0 {
                if commitsBeforeFailure { storedSnapshot = snapshot }
                readbackIsUnreadable = makesReadbackUnreadable
                if !repeatsFailure { successfulSavesBeforeFailure = nil }
                throw AutomationStoreTestError.injectedFailure
            }
            successfulSavesBeforeFailure = remaining - 1
        }
        storedSnapshot = snapshot
        readbackIsUnreadable = false
    }

    func fail(
        afterSuccessfulSaves count: Int = 0,
        repeatedly: Bool = false,
        committingBeforeFailure: Bool = false,
        unreadableAfterFailure: Bool = false
    ) {
        successfulSavesBeforeFailure = count
        repeatsFailure = repeatedly
        commitsBeforeFailure = committingBeforeFailure
        makesReadbackUnreadable = unreadableAfterFailure
    }

    func allowSaves() {
        successfulSavesBeforeFailure = nil
        repeatsFailure = false
        commitsBeforeFailure = false
        makesReadbackUnreadable = false
        readbackIsUnreadable = false
    }

    func capturedSnapshot() -> AutomationSnapshot { storedSnapshot }
}

private actor ControlledAutomationStore: AutomationPersisting {
    private var storedSnapshot = AutomationSnapshot()
    private var shouldBlockNextSave = false
    private var blockedSaveShouldFail = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>?

    func loadSnapshot() -> AutomationSnapshot { storedSnapshot }

    func saveSnapshot(_ snapshot: AutomationSnapshot) async throws {
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            await withCheckedContinuation { continuation in
                blockedSaveContinuation = continuation
            }
            if blockedSaveShouldFail {
                blockedSaveShouldFail = false
                throw AutomationStoreTestError.injectedFailure
            }
        }
        storedSnapshot = snapshot
    }

    func blockNextSave() {
        shouldBlockNextSave = true
    }

    func hasBlockedSave() -> Bool {
        blockedSaveContinuation != nil
    }

    func releaseBlockedSave(failing: Bool) {
        blockedSaveShouldFail = failing
        blockedSaveContinuation?.resume()
        blockedSaveContinuation = nil
    }

    func capturedSnapshot() -> AutomationSnapshot { storedSnapshot }
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

private actor ControlledAutomationExecutor {
    private var requests: [AutomationExecutionRequest] = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func execute(_ request: AutomationExecutionRequest) async -> AutomationExecutionOutcome {
        requests.append(request)
        await withCheckedContinuation { continuation in
            continuations[request.run.id] = continuation
        }
        return AutomationExecutionOutcome(status: .succeeded)
    }

    func capturedRequests() -> [AutomationExecutionRequest] { requests }

    func release(runID: UUID) {
        continuations.removeValue(forKey: runID)?.resume()
    }

    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

final class AutomationSchedulerTests: XCTestCase {
    func testAutomationStoreClassifiesExactPostWriteReadback() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let definition = Self.definition(
            name: "Exact readback",
            schedule: .event(AutomationEventTrigger(name: "readback")),
            createdAt: current
        )
        let baseline = AutomationSnapshot()
        let proposed = AutomationSnapshot(automations: [definition])
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("automation-exact-readback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let committedURL = root.appendingPathComponent("committed.json")
        let committedStore = AutomationStore(fileURL: committedURL) { data, destination in
            try AtomicFileWriter.write(data, to: destination)
            throw AutomationStoreTestError.injectedFailure
        }
        do {
            try await committedStore.saveSnapshot(proposed)
            XCTFail("A post-rename writer failure must be reported.")
        } catch let error as AutomationSnapshotSaveError {
            XCTAssertEqual(error.disposition, .committed)
        }
        let committedReadback = try await committedStore.loadSnapshot()
        XCTAssertEqual(committedReadback, proposed)

        let unchangedURL = root.appendingPathComponent("unchanged.json")
        let baselineStore = AutomationStore(fileURL: unchangedURL)
        try await baselineStore.saveSnapshot(baseline)
        let unchangedStore = AutomationStore(fileURL: unchangedURL) { _, _ in
            throw AutomationStoreTestError.injectedFailure
        }
        do {
            try await unchangedStore.saveSnapshot(proposed)
            XCTFail("A pre-rename writer failure must be reported.")
        } catch let error as AutomationSnapshotSaveError {
            XCTAssertEqual(error.disposition, .unchanged)
        }
        let unchangedReadback = try await unchangedStore.loadSnapshot()
        XCTAssertEqual(unchangedReadback, baseline)

        let uncertainStore = AutomationStore(fileURL: unchangedURL) { _, destination in
            try AtomicFileWriter.write(Data("third-version".utf8), to: destination)
            throw AutomationStoreTestError.injectedFailure
        }
        do {
            try await uncertainStore.saveSnapshot(proposed)
            XCTFail("A third-version writer failure must be reported.")
        } catch let error as AutomationSnapshotSaveError {
            XCTAssertEqual(error.disposition, .uncertain)
        }
    }

    func testAutomationStoreRejectsDanglingSymlinkAsUnsafeForLoadAndSave() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("automation-dangling-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("automations.json")
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: root.appendingPathComponent("missing-target.json")
        )
        let store = AutomationStore(fileURL: fileURL)

        do {
            _ = try await store.loadSnapshot()
            XCTFail("A dangling persistence symlink must not be treated as an absent snapshot.")
        } catch let error as AutomationStoreError {
            XCTAssertEqual(error, .unsafeFile)
        }

        do {
            try await store.saveSnapshot(AutomationSnapshot())
            XCTFail("Saving must not replace an unsafe persistence pre-image.")
        } catch let error as AutomationStoreError {
            XCTAssertEqual(error, .unsafeFile)
        }
    }

    func testCommittedSaveFailurePreservesStateAndRunsCommittedSideEffects() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = FailingAutomationStore()
        let executor = ControlledAutomationExecutor()
        let scheduler = Self.scheduler(
            store: store,
            clock: clock,
            executor: { request in await executor.execute(request) }
        )
        let definition = Self.definition(
            name: "Committed despite error",
            schedule: .event(AutomationEventTrigger(name: "committed")),
            createdAt: current
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        await store.fail(committingBeforeFailure: true)
        let committedRun = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "post-rename"
        )

        let durableAfterError = await store.capturedSnapshot()
        XCTAssertEqual(durableAfterError.automations.map(\.id), [definition.id])
        let runID = committedRun.id
        XCTAssertTrue(durableAfterError.runs.contains(where: { $0.id == runID }))
        try await Self.waitForExecutionCount(1, executor: executor)
        let visible = try await scheduler.currentSnapshot()
        XCTAssertEqual(visible.runs.first(where: { $0.id == runID })?.status, .running)

        await executor.release(runID: runID)
        _ = try await Self.waitForTerminalRun(runID, scheduler: scheduler)
        try await scheduler.shutdown()
        try await scheduler.start()
        let restartedDefinitions = await scheduler.listAutomations()
        XCTAssertEqual(restartedDefinitions.map(\.id), [definition.id])
        try await scheduler.shutdown()
    }

    func testUnreadablePersistenceReadbackLatchesSchedulerFailClosed() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = FailingAutomationStore()
        let scheduler = Self.scheduler(store: store, clock: clock)
        let definition = Self.definition(
            name: "Unreadable readback",
            schedule: .event(AutomationEventTrigger(name: "unreadable")),
            createdAt: current
        )

        try await scheduler.start()
        await store.fail(unreadableAfterFailure: true)
        do {
            _ = try await scheduler.createAutomation(definition)
            XCTFail("The injected persistence failure must escape.")
        } catch is AutomationStoreTestError {
            // Expected.
        }
        do {
            _ = try await scheduler.currentSnapshot()
            XCTFail("Unreadable durability must latch the scheduler unavailable.")
        } catch AutomationError.unavailable {
            // Expected fail-closed latch.
        }

        try await scheduler.shutdown()
    }

    func testConcurrentMutationsSerializeAcrossPersistenceSuspensionAndRollback() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = ControlledAutomationStore()
        let scheduler = Self.scheduler(store: store, clock: clock)
        let firstDefinition = Self.definition(
            name: "Fails after suspension",
            schedule: .event(AutomationEventTrigger(name: "first")),
            createdAt: current
        )
        let secondDefinition = Self.definition(
            name: "Survives first rollback",
            schedule: .event(AutomationEventTrigger(name: "second")),
            createdAt: current
        )

        try await scheduler.start()
        await store.blockNextSave()
        let firstMutation = Task {
            try await scheduler.createAutomation(firstDefinition)
        }
        try await Self.waitForBlockedSave(store)
        let secondMutation = Task {
            try await scheduler.createAutomation(secondDefinition)
        }

        await store.releaseBlockedSave(failing: true)
        do {
            _ = try await firstMutation.value
            XCTFail("The injected first save failure must escape.")
        } catch is AutomationStoreTestError {
            // Expected.
        }
        _ = try await secondMutation.value

        let durable = await store.capturedSnapshot()
        let visible = try await scheduler.currentSnapshot()
        XCTAssertEqual(durable.automations.map(\.id), [secondDefinition.id])
        XCTAssertEqual(visible.automations.map(\.id), [secondDefinition.id])
        try await scheduler.shutdown()
    }

    func testCancellingRunningRunKeepsSameAutomationQueuedUntilExecutorDrains() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let executor = ControlledAutomationExecutor()
        let definition = Self.definition(
            name: "Drain cancellation",
            schedule: .event(AutomationEventTrigger(name: "manual-only")),
            createdAt: current
        )
        let scheduler = Self.scheduler(
            store: MemoryAutomationStore(),
            clock: clock,
            maximumConcurrentRuns: 2,
            executor: { request in await executor.execute(request) }
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        let first = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "first"
        )
        try await Self.waitForExecutionCount(1, executor: executor)
        let second = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "second"
        )

        let cancelled = try await scheduler.cancelRun(id: first.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeDrain = await executor.capturedRequests()
        let queuedBeforeDrain = try await scheduler.run(id: second.id)
        XCTAssertEqual(beforeDrain.map(\.run.id), [first.id])
        XCTAssertEqual(queuedBeforeDrain.status, .queued)

        await executor.release(runID: first.id)
        try await Self.waitForExecutionCount(2, executor: executor)
        let afterDrain = await executor.capturedRequests()
        XCTAssertEqual(afterDrain.map(\.run.id), [first.id, second.id])
        await executor.release(runID: second.id)
        _ = try await Self.waitForTerminalRun(second.id, scheduler: scheduler)
        try await scheduler.shutdown()
    }

    func testFailedShutdownLatchesUnavailableAndNeverLaunchesQueuedWork() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = FailingAutomationStore()
        let executor = ControlledAutomationExecutor()
        let definition = Self.definition(
            name: "Shutdown latch",
            schedule: .event(AutomationEventTrigger(name: "manual-only")),
            createdAt: current
        )
        let scheduler = Self.scheduler(
            store: store,
            clock: clock,
            maximumConcurrentRuns: 2,
            executor: { request in await executor.execute(request) }
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        let first = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "running"
        )
        try await Self.waitForExecutionCount(1, executor: executor)
        let second = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "queued"
        )
        await store.fail()

        do {
            try await scheduler.shutdown()
            XCTFail("The injected shutdown save failure must escape.")
        } catch is AutomationStoreTestError {
            // Expected.
        }
        do {
            _ = try await scheduler.runNow(automationID: definition.id)
            XCTFail("A failed shutdown must keep the scheduler latched unavailable.")
        } catch AutomationError.unavailable {
            // Expected.
        }
        do {
            try await scheduler.start()
            XCTFail("start() must not report success while failed shutdown is latched.")
        } catch AutomationError.unavailable {
            // Expected.
        }

        try await scheduler.shutdown()
        let durable = await store.capturedSnapshot()
        XCTAssertEqual(durable.runs.first(where: { $0.id == first.id })?.status, .interrupted)
        XCTAssertEqual(durable.runs.first(where: { $0.id == second.id })?.status, .queued)
        await executor.release(runID: first.id)
        try await Task.sleep(nanoseconds: 30_000_000)
        let requests = await executor.capturedRequests()
        XCTAssertEqual(requests.map(\.run.id), [first.id])
        await executor.releaseAll()
    }

    func testTickPersistenceFailureRollsBackEvaluationAndRetriesWithoutDuplicateRun() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = FailingAutomationStore()
        let definition = Self.definition(
            name: "Durable tick",
            schedule: .interval(every: 60, anchor: current),
            createdAt: current
        )
        let scheduler = Self.scheduler(store: store, clock: clock)

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        let before = try await scheduler.currentSnapshot()
        clock.advance(by: 120)
        await store.fail()

        do {
            try await scheduler.tick()
            XCTFail("A failed scheduler save must escape to the caller.")
        } catch is AutomationStoreTestError {
            // Expected injected persistence failure.
        }
        let afterFailure = try await scheduler.currentSnapshot()
        let persistedAfterFailure = await store.capturedSnapshot()
        XCTAssertEqual(afterFailure, before)
        XCTAssertEqual(persistedAfterFailure, before)

        try await scheduler.tick()
        let afterRetry = try await scheduler.currentSnapshot()
        XCTAssertEqual(afterRetry.runs.count, 1)
        XCTAssertEqual(afterRetry.runs.first?.status, .queued)
        let persistedAfterRetry = await store.capturedSnapshot()
        XCTAssertEqual(persistedAfterRetry.runs.count, 1)
        try await scheduler.shutdown()
    }

    func testSetupFailurePersistenceRetriesWithoutReexecutingOrRepickingQueuedRun() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let probe = AutomationExecutionProbe()
        let artifactRoot = AppPaths.projectTemporaryRoot
            .appendingPathComponent("automation-setup-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let definition = Self.definition(
            name: "Setup failure",
            schedule: .event(AutomationEventTrigger(name: "manual-only")),
            createdAt: current
        )
        let first = AutomationRunRecord(
            automationID: definition.id,
            occurrenceKey: "manual:first",
            scheduledAt: current,
            worktree: AutomationRunWorktree(requestedMode: definition.task.worktreeMode)
        )
        let second = AutomationRunRecord(
            automationID: definition.id,
            occurrenceKey: "manual:second",
            scheduledAt: current.addingTimeInterval(1),
            worktree: AutomationRunWorktree(requestedMode: definition.task.worktreeMode)
        )
        let store = FailingAutomationStore(snapshot: AutomationSnapshot(
            automations: [definition],
            runs: [first, second]
        ))
        let scheduler = AutomationScheduler(
            store: store,
            executor: { request in
                await probe.record(request)
                return AutomationExecutionOutcome(status: .succeeded)
            },
            artifactRoot: artifactRoot,
            pollingSeconds: 300,
            now: clock.now
        )

        if FileManager.default.fileExists(atPath: artifactRoot.path) {
            try FileManager.default.removeItem(at: artifactRoot)
        }
        try Data("not-a-directory".utf8).write(to: artifactRoot)
        await store.fail(afterSuccessfulSaves: 1, repeatedly: true)

        try await scheduler.start()
        let visible = try await scheduler.run(id: first.id)
        let queuedBehindPendingCompletion = try await scheduler.run(id: second.id)
        XCTAssertEqual(visible.status, .failed)
        XCTAssertEqual(
            queuedBehindPendingCompletion.status,
            .queued,
            "A pending completion must reserve its Automation until persistence succeeds."
        )
        let initialRequests = await probe.capturedRequests()
        XCTAssertEqual(initialRequests.count, 0)

        await store.allowSaves()
        let firstPersisted = try await Self.waitForPersistedTerminalRun(first.id, store: store)
        let secondPersisted = try await Self.waitForPersistedTerminalRun(second.id, store: store)
        XCTAssertEqual(firstPersisted.status, .failed)
        XCTAssertEqual(secondPersisted.status, .failed)
        let finalRequests = await probe.capturedRequests()
        XCTAssertEqual(finalRequests.count, 0)
        try await scheduler.shutdown()
    }

    func testCompletionPersistenceFailureRemainsVisibleRetriesAndDoesNotReexecute() async throws {
        let current = Self.date("2025-01-01T00:00:00Z")
        let clock = AutomationTestClock(current)
        let store = FailingAutomationStore()
        let probe = AutomationExecutionProbe()
        let definition = Self.definition(
            name: "Durable completion",
            schedule: .event(AutomationEventTrigger(name: "manual-only")),
            createdAt: current
        )
        let scheduler = Self.scheduler(
            store: store,
            clock: clock,
            executor: { request in
                await probe.record(request)
                return AutomationExecutionOutcome(
                    status: .succeeded,
                    result: AutomationRunResult(summary: "durable result")
                )
            }
        )

        try await scheduler.start()
        _ = try await scheduler.createAutomation(definition)
        await store.fail(afterSuccessfulSaves: 2)
        let run = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "durable-completion"
        )
        let visible = try await Self.waitForTerminalRun(run.id, scheduler: scheduler)
        XCTAssertEqual(visible.status, .succeeded)
        XCTAssertEqual(visible.result?.summary, "durable result")

        let retry = try await scheduler.runNow(
            automationID: definition.id,
            idempotencyKey: "durable-completion"
        )
        XCTAssertEqual(retry.id, run.id)
        XCTAssertEqual(retry.status, .succeeded)
        let persisted = try await Self.waitForPersistedTerminalRun(run.id, store: store)
        XCTAssertEqual(persisted.status, .succeeded)
        XCTAssertEqual(persisted.result?.summary, "durable result")
        let requests = await probe.capturedRequests()
        XCTAssertEqual(requests.count, 1, "Completion persistence retries must not re-execute work.")
        try await scheduler.shutdown()
    }

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

        let untrustedRepositoryCheck = AutomationDefinition(
            name: "Untrusted repository check",
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
        XCTAssertThrowsError(
            try AutomationValidation.validatedDefinition(untrustedRepositoryCheck)
        )
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
        store: any AutomationPersisting,
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

    private static func waitForBlockedSave(_ store: ControlledAutomationStore) async throws {
        for _ in 0..<200 {
            if await store.hasBlockedSave() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for the controlled Automation save.")
    }

    private static func waitForExecutionCount(
        _ count: Int,
        executor: ControlledAutomationExecutor
    ) async throws {
        for _ in 0..<200 {
            if await executor.capturedRequests().count >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(count) Automation executions.")
    }

    private static func waitForPersistedTerminalRun(
        _ id: UUID,
        store: FailingAutomationStore
    ) async throws -> AutomationRunRecord {
        for _ in 0..<200 {
            let snapshot = await store.capturedSnapshot()
            if let run = snapshot.runs.first(where: { $0.id == id }), run.status.isTerminal {
                return run
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for durable Automation completion \(id.uuidString).")
        let snapshot = await store.capturedSnapshot()
        return try XCTUnwrap(snapshot.runs.first(where: { $0.id == id }))
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }
}
