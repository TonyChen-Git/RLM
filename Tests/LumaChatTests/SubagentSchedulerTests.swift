import Darwin
import Foundation
import XCTest

@testable import LumaChat

private actor MemorySubagentRecordStore: SubagentRecordPersisting {
    var records: [SubagentRecord]

    init(records: [SubagentRecord] = []) {
        self.records = records
    }

    func loadRecords() -> [SubagentRecord] { records }
    func saveRecords(_ records: [SubagentRecord]) { self.records = records }
}

private enum SubagentStoreTestError: Error {
    case injectedFailure
}

private actor FailingSubagentRecordStore: SubagentRecordPersisting {
    private var records: [SubagentRecord] = []
    private var successfulSavesBeforeFailure: Int?
    private var failureCount = 0

    func loadRecords() -> [SubagentRecord] { records }

    func saveRecords(_ records: [SubagentRecord]) throws {
        if let remaining = successfulSavesBeforeFailure {
            if remaining == 0 {
                successfulSavesBeforeFailure = nil
                failureCount += 1
                throw SubagentStoreTestError.injectedFailure
            }
            successfulSavesBeforeFailure = remaining - 1
        }
        self.records = records
    }

    func fail(afterSuccessfulSaves count: Int = 0) {
        successfulSavesBeforeFailure = count
    }

    func capturedRecords() -> [SubagentRecord] { records }
    func capturedFailureCount() -> Int { failureCount }
}

private actor SubagentDurabilityProbe {
    private var launches = 0
    private var cancellations = 0
    private var publishedSnapshots: [[SubagentRecord]] = []

    func recordLaunch() { launches += 1 }
    func recordCancellation() { cancellations += 1 }
    func recordPublish(_ records: [SubagentRecord]) { publishedSnapshots.append(records) }

    func snapshot() -> (launches: Int, cancellations: Int, published: [[SubagentRecord]]) {
        (launches, cancellations, publishedSnapshots)
    }
}

private actor BlockingSubagentRecordStore: SubagentRecordPersisting {
    private var records: [SubagentRecord] = []
    private var shouldBlockNextSave = false
    private var blockedSaveContinuation: CheckedContinuation<Void, Never>?

    func loadRecords() -> [SubagentRecord] { records }

    func saveRecords(_ records: [SubagentRecord]) async {
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            await withCheckedContinuation { continuation in
                blockedSaveContinuation = continuation
            }
        }
        self.records = records
    }

    func blockNextSave() {
        shouldBlockNextSave = true
    }

    func waitUntilSaveIsBlocked() async {
        while blockedSaveContinuation == nil {
            await Task.yield()
        }
    }

    func releaseBlockedSave() {
        let continuation = blockedSaveContinuation
        blockedSaveContinuation = nil
        continuation?.resume()
    }

    func capturedRecords() -> [SubagentRecord] { records }
}

private actor AmbiguousSubagentRecordStore: SubagentRecordPersisting {
    private enum NextWrite {
        case normal
        case failAfterCommit
        case conflicting([SubagentRecord])
        case unreadable
    }

    private var records: [SubagentRecord]
    private var nextWrite: NextWrite = .normal
    private var readbackIsUnreadable = false

    init(records: [SubagentRecord] = []) {
        self.records = records
    }

    func loadRecords() throws -> [SubagentRecord] {
        if readbackIsUnreadable {
            throw SubagentStoreTestError.injectedFailure
        }
        return records
    }

    func saveRecords(_ records: [SubagentRecord]) throws {
        let behavior = nextWrite
        nextWrite = .normal
        switch behavior {
        case .normal:
            self.records = records
        case .failAfterCommit:
            // Reordering proves scheduler readback compares the decoded
            // semantic snapshot rather than unstable serialized array order.
            self.records = Array(records.reversed())
            throw SubagentStoreTestError.injectedFailure
        case .conflicting(let thirdVersion):
            self.records = thirdVersion
            throw SubagentStoreTestError.injectedFailure
        case .unreadable:
            readbackIsUnreadable = true
            throw SubagentStoreTestError.injectedFailure
        }
    }

    func failNextAfterCommit() {
        nextWrite = .failAfterCommit
    }

    func failNextWithConflictingSnapshot(_ records: [SubagentRecord]) {
        nextWrite = .conflicting(records)
    }

    func failNextWithUnreadableReadback() {
        nextWrite = .unreadable
    }

    func capturedRecordsIgnoringReadbackFailure() -> [SubagentRecord] { records }
}

private actor SubagentExecutionDrainProbe {
    private var launchedIDs: [UUID] = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func execute(_ record: SubagentRecord) async -> SubagentExecutionOutcome {
        launchedIDs.append(record.id)
        await withCheckedContinuation { continuation in
            continuations[record.id] = continuation
        }
        return SubagentExecutionOutcome(
            status: .completed,
            result: SubagentStructuredResult(
                summary: record.goal,
                findings: [],
                files: [],
                commands: [],
                tests: [],
                artifacts: [],
                confidence: 1,
                unresolved: []
            ),
            error: nil
        )
    }

    func waitForLaunchCount(_ count: Int) async {
        while launchedIDs.count < count {
            await Task.yield()
        }
    }

    func release(_ id: UUID) {
        let continuation = continuations.removeValue(forKey: id)
        continuation?.resume()
    }

    func launches() -> [UUID] { launchedIDs }
}

private enum SubagentForcedTerminalCause: Equatable {
    case cancellation
    case timeout
    case tokenBudget
}

private actor SubagentConcurrencyProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var cancelled = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end(wasCancelled: Bool = false) {
        active = max(0, active - 1)
        if wasCancelled { cancelled += 1 }
    }

    func snapshot() -> (active: Int, peak: Int, cancelled: Int) {
        (active, peak, cancelled)
    }
}

private actor SubagentIsolationRecorder {
    private var names: [String] = []
    func append(_ name: String) { names.append(name) }
    func snapshot() -> [String] { names }
}

private struct SubagentIsolationTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let category: AgentToolCategory
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork: Bool
    let supportsParallelExecution = false
    let recorder: SubagentIsolationRecorder
    let inputSchema = JSONValue.objectSchema(properties: [:])
    var description: String { displayName }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await recorder.append(name)
        return AgentToolResult(content: "invoked")
    }
}

final class SubagentSchedulerTests: XCTestCase {
    func testSpawnPrecommitFailureRollsBackWithoutLaunchOrResidualRecord() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in
                await probe.recordLaunch()
                return Self.outcome(summary: record.goal)
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        await store.fail()
        let parentID = UUID()

        do {
            _ = try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "must not launch"),
                authority: Self.authority(parentID: parentID)
            )
            XCTFail("A pre-commit spawn failure must be reported.")
        } catch is SubagentStoreTestError {
            // Expected unchanged-store failure.
        }

        let rolledBackRecords = await scheduler.listSubagents(parentSessionID: parentID)
        let persistedRecords = await store.capturedRecords()
        let rolledBackProbe = await probe.snapshot()
        XCTAssertEqual(rolledBackRecords, [])
        XCTAssertEqual(persistedRecords, [])
        XCTAssertEqual(rolledBackProbe.launches, 0)

        let retry = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "retry after rollback"),
            authority: Self.authority(parentID: parentID)
        )
        let terminal = try await scheduler.waitForSubagent(
            id: retry.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .completed)
        let retriedProbe = await probe.snapshot()
        XCTAssertEqual(retriedProbe.launches, 1)
    }

    func testRecordStoreTreatsOnlyENOENTAsAbsentAndRejectsBrokenSymlink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-record-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("records.json")
        let store = SubagentRecordStore(fileURL: fileURL)

        let absentRecords = try await store.loadRecords()
        XCTAssertEqual(absentRecords, [])
        guard Darwin.symlink("missing-record-target", fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            _ = try await store.loadRecords()
            XCTFail("A dangling records symlink must not be treated as an absent store.")
        } catch let error as SubagentRecordStoreError {
            XCTAssertEqual(error, .invalidFile)
        }
    }

    func testPostRenameFailureKeepsCommittedSemanticSnapshotAndLaunchesOnce() async throws {
        let baselineParent = UUID()
        let baseline = Self.storedTerminalRecord(parentID: baselineParent)
        let store = AmbiguousSubagentRecordStore(records: [baseline])
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in
                await probe.recordLaunch()
                return Self.outcome(summary: record.goal)
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        await store.failNextAfterCommit()

        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "post-rename commit"),
            authority: Self.authority(parentID: parentID)
        )
        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )

        XCTAssertEqual(terminal.status, .completed)
        let durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 1)
        let persisted = await store.capturedRecordsIgnoringReadbackFailure()
        XCTAssertEqual(Set(persisted.map(\.id)), Set([baseline.id, child.id]))
    }

    func testPostRenameFailureRunsCommittedTerminalSideEffectsAndRetainsCapacity() async throws {
        try await assertPostRenameCommittedTerminalSideEffect(.cancellation)
        try await assertPostRenameCommittedTerminalSideEffect(.timeout)
        try await assertPostRenameCommittedTerminalSideEffect(.tokenBudget)
    }

    func testConflictingReadbackAdoptsDiskSnapshotAndBlocksFurtherWrites() async throws {
        let store = AmbiguousSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in
                await probe.recordLaunch()
                return Self.outcome(summary: record.goal)
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let thirdParent = UUID()
        let third = Self.storedTerminalRecord(parentID: thirdParent)
        await store.failNextWithConflictingSnapshot([third])

        do {
            _ = try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "must conflict"),
                authority: Self.authority(parentID: UUID())
            )
            XCTFail("A third-version readback must fail closed.")
        } catch let error as SubagentPersistenceError {
            XCTAssertEqual(error, .conflictingReadback)
        }

        let adopted = await scheduler.listSubagents(parentSessionID: thirdParent)
        XCTAssertEqual(adopted, [third])
        do {
            _ = try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "blocked after conflict"),
                authority: Self.authority(parentID: UUID())
            )
            XCTFail("Writes must remain blocked after conflicting readback.")
        } catch let error as SubagentPersistenceError {
            XCTAssertEqual(error, .recoveryRequired)
        }
        let durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 0)
    }

    func testUnreadableReadbackKeepsLastKnownSnapshotAndBlocksFurtherWrites() async throws {
        let store = AmbiguousSubagentRecordStore()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in Self.outcome(summary: record.goal) },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        await store.failNextWithUnreadableReadback()
        let parentID = UUID()

        do {
            _ = try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "unreadable readback"),
                authority: Self.authority(parentID: parentID)
            )
            XCTFail("Unreadable readback must fail closed.")
        } catch let error as SubagentPersistenceError {
            XCTAssertEqual(error, .unreadableReadback)
        }
        let retained = await scheduler.listSubagents(parentSessionID: parentID)
        XCTAssertEqual(retained, [])
        do {
            _ = try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "blocked after unreadable readback"),
                authority: Self.authority(parentID: parentID)
            )
            XCTFail("Writes must remain blocked after unreadable readback.")
        } catch let error as SubagentPersistenceError {
            XCTAssertEqual(error, .recoveryRequired)
        }
    }

    func testDurableMutationsSerializeAcrossReentrantStoreAwait() async throws {
        let store = BlockingSubagentRecordStore()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Self.outcome(summary: "unexpected")
                } catch {
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "serialized persistence"),
            authority: Self.authority(parentID: parentID)
        )

        await store.blockNextSave()
        let first = Task {
            try await scheduler.sendSubagentMessage(
                id: child.id,
                parentSessionID: parentID,
                message: "first"
            )
        }
        await store.waitUntilSaveIsBlocked()
        let second = Task {
            try await scheduler.sendSubagentMessage(
                id: child.id,
                parentSessionID: parentID,
                message: "second"
            )
        }
        await store.releaseBlockedSave()
        _ = try await first.value
        _ = try await second.value

        let persisted = await store.capturedRecords()
        XCTAssertEqual(
            persisted.first(where: { $0.id == child.id })?.pendingMessages,
            ["first", "second"]
        )
        _ = try await scheduler.cancelSubagent(id: child.id, parentSessionID: parentID)
    }

    func testCancellationRetainsCapacityUntilExecutorDrains() async throws {
        let drain = SubagentExecutionDrainProbe()
        let scheduler = SubagentScheduler(
            store: MemorySubagentRecordStore(),
            globalConcurrency: 1,
            providerConcurrency: 1
        )
        try await scheduler.configure(
            launch: { record in await drain.execute(record) },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let firstParent = UUID()
        let secondParent = UUID()
        let first = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "first"),
            authority: Self.authority(parentID: firstParent)
        )
        await drain.waitForLaunchCount(1)
        let second = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "second"),
            authority: Self.authority(parentID: secondParent)
        )

        _ = try await scheduler.cancelSubagent(id: first.id, parentSessionID: firstParent)
        do {
            _ = try await scheduler.resumeSubagent(id: first.id, parentSessionID: firstParent)
            XCTFail("Resume must wait until the cancelled executor drains.")
        } catch let error as SubagentError {
            guard case .executionFailed = error else {
                return XCTFail("Expected executionFailed, got \(error)")
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        var launches = await drain.launches()
        XCTAssertEqual(launches, [first.id])

        await drain.release(first.id)
        await drain.waitForLaunchCount(2)
        launches = await drain.launches()
        XCTAssertEqual(launches, [first.id, second.id])
        await drain.release(second.id)
        let terminal = try await scheduler.waitForSubagent(
            id: second.id,
            parentSessionID: secondParent,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .completed)
    }

    func testTimeoutAndTokenBudgetRetainCapacityUntilExecutorsDrain() async throws {
        try await assertTerminalCauseRetainsCapacity(.timeout)
        try await assertTerminalCauseRetainsCapacity(.tokenBudget)
    }

    func testPendingCompletionCannotBeOverwrittenByParentCancellation() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in
                await probe.recordLaunch()
                return Self.outcome(summary: record.goal)
            },
            cancel: { _ in await probe.recordCancellation() },
            onUpdate: { _ in }
        )
        await store.fail(afterSuccessfulSaves: 2)
        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "preserve completed result"),
            authority: Self.authority(parentID: parentID)
        )
        for _ in 0..<100 {
            if await store.capturedFailureCount() > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let initialFailureCount = await store.capturedFailureCount()
        XCTAssertEqual(initialFailureCount, 1)

        await store.fail()
        do {
            _ = try await scheduler.cancelSubagent(id: child.id, parentSessionID: parentID)
            XCTFail("A nondurable completion must not be replaced with cancellation.")
        } catch let error as SubagentError {
            guard case .executionFailed(let detail) = error else {
                return XCTFail("Expected executionFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("durable storage"))
        }

        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .completed)
        XCTAssertEqual(terminal.result?.summary, "preserve completed result")
        let durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 1)
        XCTAssertEqual(durability.cancellations, 0)
        let persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .completed)
    }

    func testRunningTransitionMustPersistBeforeLaunchOrPublish() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        let launch: SubagentLaunchHandler = { record in
            await probe.recordLaunch()
            return Self.outcome(summary: record.goal)
        }
        let cancel: SubagentCancellationHandler = { _ in
            await probe.recordCancellation()
        }
        let update: SubagentRecordsUpdateHandler = { records in
            await probe.recordPublish(records)
        }
        try await scheduler.configure(launch: launch, cancel: cancel, onUpdate: update)
        await store.fail(afterSuccessfulSaves: 1)

        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "durable launch"),
            authority: Self.authority(parentID: parentID)
        )

        XCTAssertEqual(child.status, .queued)
        var durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 0)
        XCTAssertFalse(durability.published.flatMap { $0 }.contains {
            $0.id == child.id && $0.status == .running
        })
        var persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .queued)

        try await scheduler.configure(launch: launch, cancel: cancel, onUpdate: update)
        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .completed)
        durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 1)
        persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .completed)
    }

    func testCompletionSaveFailureRetriesWithoutDuplicateLaunchOrNondurablePublish() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { record in
                await probe.recordLaunch()
                return Self.outcome(summary: record.goal)
            },
            cancel: { _ in await probe.recordCancellation() },
            onUpdate: { records in
                if let completed = records.first(where: { $0.status == .completed }) {
                    let persisted = await store.capturedRecords()
                    XCTAssertEqual(
                        persisted.first(where: { $0.id == completed.id })?.status,
                        .completed,
                        "A terminal update must not be published before it is durable."
                    )
                }
                await probe.recordPublish(records)
            }
        )
        await store.fail(afterSuccessfulSaves: 2)
        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "retry completion"),
            authority: Self.authority(parentID: parentID)
        )

        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .completed)
        let durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 1)
        let persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .completed)
    }

    func testMessageAndTokenSideEffectsWaitForDurableMutation() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { _ in
                await probe.recordLaunch()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Self.outcome(summary: "unexpected")
                } catch {
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in await probe.recordCancellation() },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        var request = SubagentSpawnRequest(goal: "durable mutation")
        request.budget = SubagentBudget(
            maximumSteps: 1,
            contextTokens: 2_048,
            totalTokens: 1_024,
            timeoutSeconds: 300
        )
        let child = try await scheduler.spawnSubagent(
            request,
            authority: Self.authority(parentID: parentID)
        )
        _ = try await scheduler.sendSubagentMessage(
            id: child.id,
            parentSessionID: parentID,
            message: "deliver once"
        )

        await store.fail()
        let failedDrain = await scheduler.takePendingSubagentMessages(id: child.id)
        XCTAssertEqual(failedDrain, [])
        var persisted = await store.capturedRecords()
        XCTAssertEqual(
            persisted.first(where: { $0.id == child.id })?.pendingMessages,
            ["deliver once"]
        )
        let durableDrain = await scheduler.takePendingSubagentMessages(id: child.id)
        XCTAssertEqual(durableDrain, ["deliver once"])

        await store.fail()
        await scheduler.recordSubagentTokenUsage(id: child.id, tokens: 1_024)
        let current = await scheduler.listSubagents(parentSessionID: parentID)
        XCTAssertEqual(current.first?.status, .running)
        XCTAssertEqual(current.first?.consumedTokens, 0)
        var durability = await probe.snapshot()
        XCTAssertEqual(durability.cancellations, 0)

        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.consumedTokens, 1_024)
        durability = await probe.snapshot()
        XCTAssertEqual(durability.cancellations, 1)
        persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .failed)
    }

    func testTimeoutRetriesPersistenceBeforeCancellingExecution() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(
            store: store,
            timeoutNanosecondsPerSecond: 1_000_000
        )
        try await scheduler.configure(
            launch: { _ in
                await probe.recordLaunch()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Self.outcome(summary: "unexpected")
                } catch {
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in await probe.recordCancellation() },
            onUpdate: { records in
                if let timedOut = records.first(where: { $0.status == .timedOut }) {
                    let persisted = await store.capturedRecords()
                    XCTAssertEqual(
                        persisted.first(where: { $0.id == timedOut.id })?.status,
                        .timedOut
                    )
                }
            }
        )
        let parentID = UUID()
        var request = SubagentSpawnRequest(goal: "durable timeout")
        request.budget.timeoutSeconds = 20
        let child = try await scheduler.spawnSubagent(
            request,
            authority: Self.authority(parentID: parentID)
        )
        await store.fail()

        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 3
        )
        XCTAssertEqual(terminal.status, .timedOut)
        let durability = await probe.snapshot()
        XCTAssertEqual(durability.launches, 1)
        XCTAssertEqual(durability.cancellations, 1)
        let persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .timedOut)
    }

    func testCancellationSideEffectWaitsForDurableTerminalState() async throws {
        let store = FailingSubagentRecordStore()
        let probe = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(store: store)
        try await scheduler.configure(
            launch: { _ in
                await probe.recordLaunch()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Self.outcome(summary: "unexpected")
                } catch {
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in await probe.recordCancellation() },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "durable cancellation"),
            authority: Self.authority(parentID: parentID)
        )
        await store.fail()

        do {
            _ = try await scheduler.cancelSubagent(
                id: child.id,
                parentSessionID: parentID
            )
            XCTFail("Cancellation must not escape before its state is durable.")
        } catch is SubagentStoreTestError {
            // Expected injected persistence failure.
        }
        var current = await scheduler.listSubagents(parentSessionID: parentID)
        XCTAssertEqual(current.first?.status, .running)
        var durability = await probe.snapshot()
        XCTAssertEqual(durability.cancellations, 0)

        _ = try await scheduler.cancelSubagent(id: child.id, parentSessionID: parentID)
        current = await scheduler.listSubagents(parentSessionID: parentID)
        XCTAssertEqual(current.first?.status, .cancelled)
        durability = await probe.snapshot()
        XCTAssertEqual(durability.cancellations, 1)
        let persisted = await store.capturedRecords()
        XCTAssertEqual(persisted.first(where: { $0.id == child.id })?.status, .cancelled)
    }

    func testSchedulerCapsParallelWorkAndCompletesEveryChild() async throws {
        let store = MemorySubagentRecordStore()
        let probe = SubagentConcurrencyProbe()
        let scheduler = SubagentScheduler(
            store: store,
            globalConcurrency: 2,
            providerConcurrency: 2
        )
        try await scheduler.configure(
            launch: { record in
                await probe.begin()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    await probe.end()
                    return Self.outcome(summary: record.goal)
                } catch {
                    await probe.end(wasCancelled: true)
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        let authority = Self.authority(parentID: parentID)
        var children: [SubagentRecord] = []
        for index in 0..<5 {
            children.append(try await scheduler.spawnSubagent(
                SubagentSpawnRequest(goal: "child-\(index)"),
                authority: authority
            ))
        }
        for child in children {
            let terminal = try await scheduler.waitForSubagent(
                id: child.id,
                parentSessionID: parentID,
                timeoutSeconds: 5
            )
            XCTAssertEqual(terminal.status, .completed)
        }
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.active, 0)
        XCTAssertEqual(snapshot.peak, 2)
    }

    func testChildFailureIsIsolatedAndStructuredResultsCollectIndependently() async throws {
        let scheduler = SubagentScheduler(store: MemorySubagentRecordStore())
        try await scheduler.configure(
            launch: { record in
                record.goal == "fail"
                    ? SubagentExecutionOutcome(
                        status: .failed,
                        result: Self.result(summary: "failed evidence"),
                        error: "expected failure"
                    )
                    : Self.outcome(summary: "successful evidence")
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        let authority = Self.authority(parentID: parentID)
        let failed = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "fail"), authority: authority
        )
        let succeeded = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "pass"), authority: authority
        )
        _ = try await scheduler.waitForSubagent(
            id: failed.id, parentSessionID: parentID, timeoutSeconds: 3
        )
        _ = try await scheduler.waitForSubagent(
            id: succeeded.id, parentSessionID: parentID, timeoutSeconds: 3
        )
        let failedResult = try await scheduler.collectSubagentResult(
            id: failed.id, parentSessionID: parentID
        )
        let successResult = try await scheduler.collectSubagentResult(
            id: succeeded.id, parentSessionID: parentID
        )
        XCTAssertEqual(failedResult.summary, "failed evidence")
        XCTAssertEqual(successResult.summary, "successful evidence")
        let hasOutstanding = await scheduler.hasOutstandingSubagents(parentSessionID: parentID)
        XCTAssertFalse(hasOutstanding)
    }

    func testParentCancellationPropagatesWithoutTouchingOtherParent() async throws {
        let probe = SubagentConcurrencyProbe()
        let scheduler = SubagentScheduler(store: MemorySubagentRecordStore())
        try await scheduler.configure(
            launch: { _ in
                await probe.begin()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    await probe.end()
                    return Self.outcome(summary: "unexpected")
                } catch {
                    await probe.end(wasCancelled: true)
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let firstParent = UUID()
        let secondParent = UUID()
        let first = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "first"),
            authority: Self.authority(parentID: firstParent)
        )
        let second = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "second"),
            authority: Self.authority(parentID: secondParent)
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        try await scheduler.cancelSubagents(parentSessionID: firstParent)
        let firstRecords = await scheduler.listSubagents(parentSessionID: firstParent)
        let secondRecords = await scheduler.listSubagents(parentSessionID: secondParent)
        XCTAssertEqual(firstRecords.first?.id, first.id)
        XCTAssertEqual(firstRecords.first?.status, .cancelled)
        XCTAssertEqual(secondRecords.first?.id, second.id)
        XCTAssertNotEqual(secondRecords.first?.status, .cancelled)
        _ = try await scheduler.cancelSubagent(
            id: second.id, parentSessionID: secondParent
        )
    }

    func testRunningRecordRecoversAsInterruptedAndCanResume() async throws {
        let parentID = UUID()
        let childID = UUID()
        let now = Date()
        let stored = SubagentRecord(
            id: childID,
            parentSessionID: parentID,
            childSessionID: childID,
            goal: "recover",
            status: .running,
            scope: SubagentScope(),
            context: nil,
            budget: SubagentBudget(),
            priority: .normal,
            providerKey: "ollama::model",
            depth: 1,
            consumedTokens: 10,
            attempt: 1,
            pendingMessages: [],
            startedAt: now,
            endedAt: nil,
            createdAt: now,
            updatedAt: now,
            result: nil,
            error: nil,
            collectedAt: nil
        )
        let scheduler = SubagentScheduler(
            store: MemorySubagentRecordStore(records: [stored])
        )
        try await scheduler.configure(
            launch: { _ in Self.outcome(summary: "resumed") },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let recovered = await scheduler.listSubagents(parentSessionID: parentID)
        XCTAssertEqual(recovered.first?.status, .interrupted)
        _ = try await scheduler.resumeSubagent(id: childID, parentSessionID: parentID)
        let completed = try await scheduler.waitForSubagent(
            id: childID, parentSessionID: parentID, timeoutSeconds: 3
        )
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.attempt, 2)
    }

    func testTimeoutCancelsOnlyTimedOutChild() async throws {
        let probe = SubagentConcurrencyProbe()
        let scheduler = SubagentScheduler(
            store: MemorySubagentRecordStore(),
            timeoutNanosecondsPerSecond: 1_000_000
        )
        try await scheduler.configure(
            launch: { _ in
                await probe.begin()
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    await probe.end()
                    return Self.outcome(summary: "unexpected")
                } catch {
                    await probe.end(wasCancelled: true)
                    return SubagentExecutionOutcome(status: .cancelled, result: nil, error: nil)
                }
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        var request = SubagentSpawnRequest(goal: "timeout")
        request.budget.timeoutSeconds = 10
        let child = try await scheduler.spawnSubagent(
            request,
            authority: Self.authority(parentID: parentID)
        )
        let terminal = try await scheduler.waitForSubagent(
            id: child.id,
            parentSessionID: parentID,
            timeoutSeconds: 2
        )
        XCTAssertEqual(terminal.status, .timedOut)
        XCTAssertTrue(terminal.error?.contains("10") == true)
    }

    func testParentMessagesRemainBoundToExactChild() async throws {
        let scheduler = SubagentScheduler(store: MemorySubagentRecordStore())
        try await scheduler.configure(
            launch: { _ in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return Self.outcome(summary: "done")
            },
            cancel: { _ in },
            onUpdate: { _ in }
        )
        let parentID = UUID()
        let child = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "context"),
            authority: Self.authority(parentID: parentID)
        )
        _ = try await scheduler.sendSubagentMessage(
            id: child.id,
            parentSessionID: parentID,
            message: "bounded follow-up"
        )
        let messages = await scheduler.takePendingSubagentMessages(id: child.id)
        XCTAssertEqual(messages, ["bounded follow-up"])
        let consumedAgain = await scheduler.takePendingSubagentMessages(id: child.id)
        XCTAssertEqual(consumedAgain, [])
        do {
            _ = try await scheduler.sendSubagentMessage(
                id: child.id,
                parentSessionID: UUID(),
                message: "wrong parent"
            )
            XCTFail("Expected parent mismatch")
        } catch let error as SubagentError {
            XCTAssertEqual(error, .parentMismatch)
        }
        _ = try await scheduler.cancelSubagent(id: child.id, parentSessionID: parentID)
    }

    func testScopeCannotExpandParentAndExecutorRejectsHiddenTool() async throws {
        var networkRequest = SubagentSpawnRequest(goal: "network")
        networkRequest.scope.networkAccess = true
        XCTAssertThrowsError(try SubagentValidation.validated(
            networkRequest,
            authority: Self.authority(parentID: UUID(), networkAccess: false)
        ))
        var writableSubdirectory = SubagentSpawnRequest(goal: "write")
        writableSubdirectory.scope = SubagentScope(
            access: .writableWorktree,
            relativePath: "Sources",
            allowedToolNames: [],
            allowedMCPServerIDs: [],
            networkAccess: false
        )
        XCTAssertThrowsError(try SubagentValidation.validated(
            writableSubdirectory,
            authority: Self.authority(parentID: UUID())
        ))

        let recorder = SubagentIsolationRecorder()
        let registry = ToolRegistry()
        let read = SubagentIsolationTool(
            id: "test.read", name: "read_file", displayName: "Read",
            category: .filesystem, permissionLevel: .read,
            requiresNetwork: false, recorder: recorder
        )
        let write = SubagentIsolationTool(
            id: "test.write", name: "write_file", displayName: "Write",
            category: .filesystem, permissionLevel: .write,
            requiresNetwork: false, recorder: recorder
        )
        try await registry.register([read, write])
        let scope = SubagentScope(
            access: .readOnly,
            relativePath: ".",
            allowedToolNames: ["read_file"],
            allowedMCPServerIDs: [],
            networkAccess: false
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: Self.workspace(),
            subagentScope: scope
        )
        let definitionNames = await registry.definitions(
            for: .agent,
            context: context
        ).map(\.name)
        XCTAssertEqual(definitionNames, ["read_file"])
        let rejected = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: "write_file"),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: true,
            approvalHandler: { _ in
                XCTFail("Scope rejection must happen before approval")
                return .allowOnce
            }
        )
        XCTAssertTrue(rejected.isError)
        XCTAssertEqual(rejected.content, SubagentToolIsolationPolicy.denialReason)
        let invoked = await recorder.snapshot()
        XCTAssertEqual(invoked, [])
    }

    private static func authority(
        parentID: UUID,
        networkAccess: Bool = false
    ) -> SubagentAuthority {
        SubagentAuthority(
            parentSessionID: parentID,
            parentDepth: 0,
            providerKey: "ollama::test-model",
            workspaceIsGitRepository: true,
            networkAccess: networkAccess,
            allowedMCPServerIDs: nil,
            allowedToolNames: nil
        )
    }

    private static func result(summary: String) -> SubagentStructuredResult {
        SubagentStructuredResult(
            summary: summary,
            findings: [],
            files: [],
            commands: [],
            tests: [],
            artifacts: [],
            confidence: 1,
            unresolved: []
        )
    }

    private static func outcome(summary: String) -> SubagentExecutionOutcome {
        SubagentExecutionOutcome(
            status: .completed,
            result: result(summary: summary),
            error: nil
        )
    }

    private static func storedTerminalRecord(parentID: UUID) -> SubagentRecord {
        let now = Date()
        let id = UUID()
        return SubagentRecord(
            id: id,
            parentSessionID: parentID,
            childSessionID: id,
            goal: "persisted third-version record",
            status: .completed,
            scope: SubagentScope(),
            context: nil,
            budget: SubagentBudget(),
            priority: .normal,
            providerKey: "ollama::test-model",
            depth: 1,
            consumedTokens: 0,
            attempt: 1,
            pendingMessages: [],
            startedAt: now.addingTimeInterval(-1),
            endedAt: now,
            createdAt: now.addingTimeInterval(-2),
            updatedAt: now,
            result: result(summary: "durable result"),
            error: nil,
            collectedAt: now
        )
    }

    private func assertPostRenameCommittedTerminalSideEffect(
        _ cause: SubagentForcedTerminalCause
    ) async throws {
        let store = AmbiguousSubagentRecordStore()
        let drain = SubagentExecutionDrainProbe()
        let durability = SubagentDurabilityProbe()
        let scheduler = SubagentScheduler(
            store: store,
            globalConcurrency: 1,
            providerConcurrency: 1,
            timeoutNanosecondsPerSecond: 1_000_000
        )
        try await scheduler.configure(
            launch: { record in await drain.execute(record) },
            cancel: { _ in await durability.recordCancellation() },
            onUpdate: { _ in }
        )

        let firstParent = UUID()
        let secondParent = UUID()
        var request = SubagentSpawnRequest(goal: "committed-\(cause)")
        request.budget.totalTokens = 1_024
        request.budget.timeoutSeconds = cause == .timeout ? 500 : 3_600
        let first = try await scheduler.spawnSubagent(
            request,
            authority: Self.authority(parentID: firstParent)
        )
        await drain.waitForLaunchCount(1)
        let second = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "queued-after-\(cause)"),
            authority: Self.authority(parentID: secondParent)
        )
        await store.failNextAfterCommit()

        let expectedStatus: SubagentStatus
        switch cause {
        case .cancellation:
            expectedStatus = .cancelled
            _ = try await scheduler.cancelSubagent(
                id: first.id,
                parentSessionID: firstParent
            )
        case .timeout:
            expectedStatus = .timedOut
            let terminal = try await scheduler.waitForSubagent(
                id: first.id,
                parentSessionID: firstParent,
                timeoutSeconds: 3
            )
            XCTAssertEqual(terminal.status, expectedStatus)
        case .tokenBudget:
            expectedStatus = .failed
            await scheduler.recordSubagentTokenUsage(id: first.id, tokens: 1_024)
        }

        for _ in 0..<1_000 {
            let snapshot = await durability.snapshot()
            if snapshot.cancellations == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let terminalRecords = await scheduler.listSubagents(parentSessionID: firstParent)
        XCTAssertEqual(terminalRecords.first?.status, expectedStatus)
        let persisted = await store.capturedRecordsIgnoringReadbackFailure()
        XCTAssertEqual(
            persisted.first(where: { $0.id == first.id })?.status,
            expectedStatus
        )
        var durabilitySnapshot = await durability.snapshot()
        XCTAssertEqual(durabilitySnapshot.cancellations, 1)

        try await Task.sleep(nanoseconds: 30_000_000)
        var launches = await drain.launches()
        XCTAssertEqual(
            launches,
            [first.id],
            "A terminal record must retain its slot until the cancelled executor drains."
        )

        await drain.release(first.id)
        await drain.waitForLaunchCount(2)
        launches = await drain.launches()
        XCTAssertEqual(launches, [first.id, second.id])
        durabilitySnapshot = await durability.snapshot()
        XCTAssertEqual(durabilitySnapshot.cancellations, 1)

        await drain.release(second.id)
        let secondTerminal = try await scheduler.waitForSubagent(
            id: second.id,
            parentSessionID: secondParent,
            timeoutSeconds: 3
        )
        XCTAssertEqual(secondTerminal.status, .completed)
    }

    private func assertTerminalCauseRetainsCapacity(
        _ cause: SubagentForcedTerminalCause
    ) async throws {
        let drain = SubagentExecutionDrainProbe()
        let scheduler = SubagentScheduler(
            store: MemorySubagentRecordStore(),
            globalConcurrency: 1,
            providerConcurrency: 1,
            timeoutNanosecondsPerSecond: 1_000_000
        )
        try await scheduler.configure(
            launch: { record in await drain.execute(record) },
            cancel: { _ in },
            onUpdate: { _ in }
        )

        let firstParent = UUID()
        let secondParent = UUID()
        var request = SubagentSpawnRequest(goal: "first-\(cause)")
        request.budget.totalTokens = 1_024
        if cause == .timeout {
            request.budget.timeoutSeconds = 10
        }
        let first = try await scheduler.spawnSubagent(
            request,
            authority: Self.authority(parentID: firstParent)
        )
        await drain.waitForLaunchCount(1)
        let second = try await scheduler.spawnSubagent(
            SubagentSpawnRequest(goal: "second-\(cause)"),
            authority: Self.authority(parentID: secondParent)
        )

        switch cause {
        case .cancellation:
            _ = try await scheduler.cancelSubagent(
                id: first.id,
                parentSessionID: firstParent
            )
        case .timeout:
            let terminal = try await scheduler.waitForSubagent(
                id: first.id,
                parentSessionID: firstParent,
                timeoutSeconds: 3
            )
            XCTAssertEqual(terminal.status, .timedOut)
        case .tokenBudget:
            await scheduler.recordSubagentTokenUsage(id: first.id, tokens: 1_024)
            let terminal = try await scheduler.waitForSubagent(
                id: first.id,
                parentSessionID: firstParent,
                timeoutSeconds: 3
            )
            XCTAssertEqual(terminal.status, .failed)
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        var launches = await drain.launches()
        XCTAssertEqual(launches, [first.id])

        await drain.release(first.id)
        await drain.waitForLaunchCount(2)
        launches = await drain.launches()
        XCTAssertEqual(launches, [first.id, second.id])
        await drain.release(second.id)
        let secondTerminal = try await scheduler.waitForSubagent(
            id: second.id,
            parentSessionID: secondParent,
            timeoutSeconds: 3
        )
        XCTAssertEqual(secondTerminal.status, .completed)
    }

    private static func workspace() -> AgentWorkspace {
        AgentWorkspace(
            name: "subagent-tests",
            rootPath: AppPaths.projectTemporaryRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
    }
}
