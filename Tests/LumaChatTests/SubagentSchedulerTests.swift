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
        await scheduler.cancelSubagents(parentSessionID: firstParent)
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
