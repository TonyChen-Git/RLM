import Foundation
import XCTest
@testable import LumaChat

private actor GoalSessionStore: AgentSessionPersisting {
    private var snapshots: [AgentSession] = []
    private var shouldBlockNextSave = false
    private var blockedSaveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func loadSessions() async throws -> [AgentSession] { [] }

    func save(_ session: AgentSession) async throws {
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            blockedSaveStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        snapshots.append(session)
    }

    func delete(id: UUID) async throws { _ = id }

    func savedSnapshots() -> [AgentSession] { snapshots }

    func blockNextSave() {
        shouldBlockNextSave = true
        blockedSaveStarted = false
    }

    func waitUntilBlockedSaveStarts() async {
        if blockedSaveStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseBlockedSave() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

final class AgentGoalTests: XCTestCase {
    func testGoalNormalizesInputAndBuildsBoundedRuntimeRequest() throws {
        let goal = try AgentGoal(
            objective: "  完成 release  \n",
            completionCriteria: "  測試全部通過  "
        )

        XCTAssertEqual(goal.objective, "完成 release")
        XCTAssertEqual(goal.completionCriteria, "測試全部通過")
        XCTAssertTrue(goal.runtimeRequest.contains("完成 release"))
        XCTAssertTrue(goal.runtimeRequest.contains("測試全部通過"))
        XCTAssertLessThan(goal.runtimeRequest.utf8.count, 40 * 1_024)
    }

    func testGoalRejectsEmptyOversizedAndControlCharacterInput() throws {
        XCTAssertThrowsError(try AgentGoal(objective: "  \n ")) { error in
            XCTAssertEqual(error as? AgentGoalValidationError, .emptyObjective)
        }
        XCTAssertThrowsError(
            try AgentGoal(objective: String(repeating: "x", count: AgentGoal.maximumObjectiveBytes + 1))
        )
        XCTAssertThrowsError(try AgentGoal(objective: "valid\u{0000}invalid")) { error in
            XCTAssertEqual(error as? AgentGoalValidationError, .containsControlCharacters)
        }
    }

    func testGoalDecoderAppliesTheSameBoundsAsInteractiveInput() throws {
        let now = Date().timeIntervalSinceReferenceDate
        let oversized = String(repeating: "x", count: AgentGoal.maximumObjectiveBytes + 1)
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "objective": "\(oversized)",
          "createdAt": \(now),
          "updatedAt": \(now)
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(AgentGoal.self, from: Data(json.utf8)))
    }

    func testLegacySessionWithoutGoalStillDecodes() throws {
        let legacy = AgentSession(mode: .agent)
        let encoded = try JSONEncoder().encode(legacy)
        let restored = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertNil(restored.goal)
        XCTAssertNil(restored.goalStatus)
    }

    func testGoalCommandParsingRequiresExactCommandAndObjective() {
        XCTAssertTrue(AgentViewModel.isGoalCommand("/goal ship 1.2.0"))
        XCTAssertEqual(
            AgentViewModel.goalCommandObjective(from: " /goal\n ship 1.2.0  "),
            "ship 1.2.0"
        )
        XCTAssertTrue(AgentViewModel.isGoalCommand("/goal"))
        XCTAssertNil(AgentViewModel.goalCommandObjective(from: "/goal"))
        XCTAssertFalse(AgentViewModel.isGoalCommand("/goalkeeper"))
        XCTAssertEqual(
            AgentViewModel.taskTitle(forGoalObjective: "第一行目標\n不應進入標題"),
            "第一行目標"
        )
        XCTAssertEqual(
            AgentViewModel.taskTitle(forGoalObjective: String(repeating: "a", count: 60)),
            String(repeating: "a", count: 42) + "…"
        )
    }

    func testInterruptedGoalRecoversAsPausedWithoutLosingOutcome() throws {
        var session = AgentSession(mode: .agent)
        session.goal = try AgentGoal(objective: "完成完整 release")
        session.state = .running

        let recovered = AgentViewModel.recoverInterruptedSessions([session]).first

        XCTAssertEqual(recovered?.goal, session.goal)
        XCTAssertEqual(recovered?.state, .paused)
        XCTAssertEqual(recovered?.goalStatus, .paused)
    }

    @MainActor
    func testTerminalGoalSnapshotIsCompletedAndPersistedIdempotently() async throws {
        let store = GoalSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var completed = AgentSession(mode: .agent)
        completed.goal = try AgentGoal(objective: "完成完整 release")
        completed.state = .completed
        completed.updatedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        let runID = UUID()

        viewModel.beginRunTracking(runID: runID, session: completed, userRequest: nil)
        await viewModel.handle(.sessionUpdated(completed), runID: runID)
        await viewModel.handle(.finished(completed), runID: runID)
        await viewModel.finish(completed, runID: runID)

        let snapshots = await store.savedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.goal?.completedAt, completed.updatedAt)
        XCTAssertEqual(viewModel.selectedSession?.goalStatus, nil)
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == completed.id })?.goalStatus,
            .completed
        )
        XCTAssertFalse(viewModel.isRunning)
    }

    @MainActor
    func testGoalCanBeEditedAndClearedWithoutDeletingTaskHistory() async throws {
        let store = GoalSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var session = AgentSession(mode: .agent)
        session.goal = try AgentGoal(objective: "原始目標")
        session.messages = [AgentMessage(role: .user, content: "保留的歷史")]
        let seedRunID = UUID()
        viewModel.beginRunTracking(runID: seedRunID, session: session, userRequest: nil)
        await viewModel.finish(session, runID: seedRunID)
        viewModel.selectedSessionID = session.id
        viewModel.activeMode = .agent

        let edited = await viewModel.updateGoal(
            objective: "更新後目標",
            completionCriteria: "驗證完成"
        )
        XCTAssertTrue(edited)
        XCTAssertEqual(viewModel.selectedSession?.goal?.objective, "更新後目標")
        XCTAssertEqual(viewModel.selectedSession?.messages, session.messages)

        let cleared = await viewModel.clearGoal()
        XCTAssertTrue(cleared)
        XCTAssertNil(viewModel.selectedSession?.goal)
        XCTAssertEqual(viewModel.selectedSession?.messages, session.messages)

        let snapshots = await store.savedSnapshots()
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.last?.messages, session.messages)
    }

    @MainActor
    func testActiveGoalCannotBeSilentlyReplaced() async throws {
        let store = GoalSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var session = AgentSession(mode: .agent)
        session.model = "test-model"
        session.workspace = AgentWorkspace(
            name: "fixture",
            rootPath: AppPaths.projectTemporaryRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        session.goal = try AgentGoal(objective: "不要被覆蓋")
        let seedRunID = UUID()
        viewModel.beginRunTracking(runID: seedRunID, session: session, userRequest: nil)
        await viewModel.finish(session, runID: seedRunID)
        viewModel.selectedSessionID = session.id
        viewModel.activeMode = .agent

        XCTAssertFalse(viewModel.canStartGoal)
        viewModel.sidebarSearch = "不要被覆蓋"
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), [session.id])
        viewModel.sidebarSearch = "找不到"
        XCTAssertTrue(viewModel.filteredSessions.isEmpty)
        viewModel.sidebarSearch = ""
        let replaced = await viewModel.startGoal(
            objective: "新目標",
            completionCriteria: nil,
            route: AppSettings(selectedModel: "test-model"),
            apiKey: ""
        )

        XCTAssertFalse(replaced)
        XCTAssertEqual(viewModel.selectedSession?.goal?.objective, "不要被覆蓋")
        XCTAssertTrue(viewModel.errorMessage?.contains("已有未完成") == true)
        let snapshots = await store.savedSnapshots()
        XCTAssertEqual(snapshots.count, 1)
    }

    @MainActor
    func testGoalPersistenceGateBlocksConflictingComposerSend() async throws {
        let store = GoalSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var session = AgentSession(mode: .agent)
        session.model = "test-model"
        session.workspace = AgentWorkspace(
            name: "fixture",
            rootPath: AppPaths.projectTemporaryRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let seedRunID = UUID()
        viewModel.beginRunTracking(runID: seedRunID, session: session, userRequest: nil)
        await viewModel.finish(session, runID: seedRunID)
        viewModel.selectedSessionID = session.id
        viewModel.activeMode = .agent
        viewModel.draft = "不可在 Goal 落盤中送出"
        await store.blockNextSave()

        let starting = Task { @MainActor in
            await viewModel.startGoal(
                objective: "持久化競態測試",
                completionCriteria: nil,
                route: AppSettings(selectedModel: "test-model"),
                apiKey: ""
            )
        }
        await store.waitUntilBlockedSaveStarts()

        XCTAssertTrue(viewModel.selectedGoalIsMutating)
        XCTAssertFalse(viewModel.canSend)
        XCTAssertFalse(viewModel.canStartGoal)

        await store.releaseBlockedSave()
        let started = await starting.value
        XCTAssertTrue(started)
        XCTAssertEqual(viewModel.selectedSession?.goal?.objective, "持久化競態測試")
        XCTAssertEqual(viewModel.selectedSession?.title, "持久化競態測試")
    }
}
