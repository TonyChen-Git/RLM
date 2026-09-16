import Foundation
import XCTest
@testable import LumaChat

private actor ConcurrentAgentSessionStore: AgentSessionPersisting {
    private var snapshots: [AgentSession] = []

    func loadSessions() async throws -> [AgentSession] { [] }

    func save(_ session: AgentSession) async throws {
        snapshots.append(session)
    }

    func delete(id: UUID) async throws {
        snapshots.removeAll { $0.id == id }
    }

    func savedSnapshots() -> [AgentSession] { snapshots }
}

final class AgentViewModelConcurrencyTests: XCTestCase {
    @MainActor
    func testTwoSessionsTrackAndFinishRunsIndependently() async {
        let store = ConcurrentAgentSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var first = AgentSession(mode: .agent)
        var second = AgentSession(mode: .agent)
        first.state = .running
        second.state = .running
        let firstRunID = UUID()
        let secondRunID = UUID()

        viewModel.beginRunTracking(runID: firstRunID, session: first, userRequest: nil)
        viewModel.beginRunTracking(runID: secondRunID, session: second, userRequest: nil)

        XCTAssertTrue(viewModel.isRunning)
        XCTAssertEqual(viewModel.activeRunCount, 2)
        XCTAssertEqual(viewModel.runningSessionIDs, Set([first.id, second.id]))
        XCTAssertTrue(viewModel.isRunning(sessionID: first.id))
        XCTAssertTrue(viewModel.isRunning(sessionID: second.id))

        first.state = .completed
        await viewModel.finish(first, runID: firstRunID)

        XCTAssertTrue(viewModel.isRunning, "Finishing one task must not stop another task")
        XCTAssertEqual(viewModel.activeRunCount, 1)
        XCTAssertFalse(viewModel.isRunning(sessionID: first.id))
        XCTAssertTrue(viewModel.isRunning(sessionID: second.id))

        second.state = .completed
        await viewModel.finish(second, runID: secondRunID)

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.activeRunCount, 0)
        XCTAssertTrue(viewModel.runningSessionIDs.isEmpty)
    }

    @MainActor
    func testDraftsRemainScopedToSessionWhileBothRunsContinue() async {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        var first = AgentSession(mode: .agent)
        var second = AgentSession(mode: .agent)
        first.state = .running
        second.state = .running
        let firstRunID = UUID()
        let secondRunID = UUID()

        viewModel.selectedSessionID = first.id
        viewModel.draft = "first project follow-up"
        viewModel.beginRunTracking(runID: firstRunID, session: first, userRequest: nil)

        viewModel.selectedSessionID = second.id
        XCTAssertEqual(viewModel.draft, "")
        viewModel.draft = "second project follow-up"
        viewModel.beginRunTracking(runID: secondRunID, session: second, userRequest: nil)

        viewModel.selectedSessionID = first.id
        XCTAssertEqual(viewModel.draft, "first project follow-up")
        XCTAssertEqual(viewModel.activeRunCount, 2)

        viewModel.selectedSessionID = second.id
        XCTAssertEqual(viewModel.draft, "second project follow-up")
        XCTAssertEqual(viewModel.activeRunCount, 2)

        first.state = .completed
        second.state = .completed
        await viewModel.finish(first, runID: firstRunID)
        await viewModel.finish(second, runID: secondRunID)
    }

    @MainActor
    func testSwitchingPlanAgentModeDoesNotMutateRunningTask() async {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        var running = AgentSession(mode: .agent)
        running.model = "test-model"
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runID)
        viewModel.selectedSessionID = running.id
        viewModel.activeMode = .agent

        viewModel.switchMode(.plan, route: AppSettings(selectedModel: "test-model"))

        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == running.id })?.mode, .agent)
        XCTAssertTrue(viewModel.isRunning(sessionID: running.id))
        XCTAssertEqual(viewModel.sessions.count, 1, "Navigation must never create a task")
        XCTAssertEqual(viewModel.activeMode, .plan)
        XCTAssertNil(viewModel.selectedSessionID)

        running.state = .completed
        await viewModel.finish(running, runID: runID)
    }

    @MainActor
    func testSwitchingToAgentWithoutExistingTaskDoesNotCreateConversation() {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())

        viewModel.switchMode(.agent, route: AppSettings(selectedModel: "test-model"))

        XCTAssertEqual(viewModel.activeMode, .agent)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertNil(viewModel.selectedSessionID)
    }

    @MainActor
    func testSwitchingIdleOppositeModeNeverConvertsTaskAndSelectsExistingTarget() {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        let route = AppSettings(selectedModel: "test-model")
        let planID = viewModel.createSession(mode: .plan, route: route)

        viewModel.switchMode(.agent, route: route)

        XCTAssertEqual(viewModel.activeMode, .agent)
        XCTAssertNil(viewModel.selectedSessionID)
        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == planID })?.mode, .plan)

        let agentID = viewModel.createSession(mode: .agent, route: route)
        viewModel.selectedSessionID = planID
        viewModel.activeMode = .plan

        viewModel.switchMode(.agent, route: route)

        XCTAssertEqual(viewModel.selectedSessionID, agentID)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == planID })?.mode, .plan)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == agentID })?.mode, .agent)

        viewModel.switchMode(.plan, route: route)

        XCTAssertEqual(viewModel.selectedSessionID, planID)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == planID })?.mode, .plan)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == agentID })?.mode, .agent)
    }

    @MainActor
    func testSwitchingModeSelectsExistingMatchingTaskWithoutCreatingOne() async {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        var plan = AgentSession(mode: .plan)
        plan.model = "test-model"
        let planRunID = UUID()
        viewModel.beginRunTracking(runID: planRunID, session: plan, userRequest: nil)
        await viewModel.finish(plan, runID: planRunID)

        var running = AgentSession(mode: .agent)
        running.model = "test-model"
        running.state = .running
        let agentRunID = UUID()
        viewModel.beginRunTracking(runID: agentRunID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: agentRunID)
        viewModel.selectedSessionID = running.id
        viewModel.activeMode = .agent
        let originalCount = viewModel.sessions.count

        viewModel.switchMode(.plan, route: AppSettings(selectedModel: "test-model"))

        XCTAssertEqual(viewModel.sessions.count, originalCount)
        XCTAssertEqual(viewModel.selectedSessionID, plan.id)
        XCTAssertEqual(viewModel.activeMode, .plan)
        XCTAssertTrue(viewModel.isRunning(sessionID: running.id))

        running.state = .completed
        await viewModel.finish(running, runID: agentRunID)
    }

    @MainActor
    func testProjectRenamePersistsWithoutChangingOrStoppingRunningTask() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-project-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        var running = makeSession(workspaceRoot: root)
        running.title = "保留這個任務標題"
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runID)
        viewModel.selectedSessionID = running.id
        viewModel.activeMode = .agent

        let renamed = await viewModel.renameSelectedProject(to: "自訂專案名稱")
        XCTAssertTrue(renamed)
        XCTAssertEqual(viewModel.projectDisplayName(for: running.workspace), "自訂專案名稱")
        XCTAssertEqual(viewModel.selectedSession?.title, "保留這個任務標題")
        XCTAssertTrue(viewModel.isRunning(sessionID: running.id))

        let settingsStore = try AgentProjectSettingsStore(workspaceRootPath: root.path)
        let persistedName = try await settingsStore.loadDisplayName()
        XCTAssertEqual(persistedName, "自訂專案名稱")

        let reset = await viewModel.renameSelectedProject(to: "   ")
        let resetPersistedName = try await settingsStore.loadDisplayName()
        XCTAssertTrue(reset)
        XCTAssertEqual(viewModel.projectDisplayName(for: running.workspace), root.lastPathComponent)
        XCTAssertNil(resetPersistedName)
        XCTAssertTrue(viewModel.isRunning(sessionID: running.id))

        running.state = .completed
        await viewModel.finish(running, runID: runID)
        try await settingsStore.delete()
    }

    @MainActor
    func testFinishingBackgroundRunDoesNotClearSelectedSessionsDraft() async {
        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        var first = AgentSession(mode: .agent)
        let second = AgentSession(mode: .agent)
        first.state = .running
        let firstRunID = UUID()

        viewModel.selectedSessionID = first.id
        viewModel.draft = "submitted first request"
        viewModel.beginRunTracking(
            runID: firstRunID,
            session: first,
            userRequest: "submitted first request"
        )

        viewModel.selectedSessionID = second.id
        viewModel.draft = "keep this second draft"

        first.messages.append(AgentMessage(role: .user, content: "submitted first request"))
        first.state = .completed
        await viewModel.finish(first, runID: firstRunID)

        XCTAssertEqual(viewModel.selectedSessionID, second.id)
        XCTAssertEqual(viewModel.draft, "keep this second draft")

        viewModel.selectedSessionID = first.id
        XCTAssertEqual(viewModel.draft, "", "Only the durably persisted submitted draft is consumed")
        viewModel.selectedSessionID = second.id
        XCTAssertEqual(viewModel.draft, "keep this second draft")
    }

    @MainActor
    func testShutdownCancelsAndPersistsEveryActiveSession() async {
        let store = ConcurrentAgentSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var first = AgentSession(mode: .agent)
        var second = AgentSession(mode: .agent)
        first.state = .running
        second.state = .running
        let firstRunID = UUID()
        let secondRunID = UUID()

        viewModel.beginRunTracking(runID: firstRunID, session: first, userRequest: nil)
        viewModel.beginRunTracking(runID: secondRunID, session: second, userRequest: nil)
        await viewModel.handle(.sessionUpdated(first), runID: firstRunID)
        await viewModel.handle(.sessionUpdated(second), runID: secondRunID)

        await viewModel.shutdown()

        XCTAssertFalse(viewModel.isRunning)
        XCTAssertTrue(viewModel.runningSessionIDs.isEmpty)
        XCTAssertTrue(viewModel.stoppingSessionIDs.isEmpty)

        let saved = await store.savedSnapshots()
        let cancelledIDs = Set(saved.filter { $0.state == .cancelled }.map(\.id))
        XCTAssertEqual(cancelledIDs, Set([first.id, second.id]))
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == first.id })?.state, .cancelled)
        XCTAssertEqual(viewModel.sessions.first(where: { $0.id == second.id })?.state, .cancelled)
    }

    @MainActor
    func testWritableRunBlocksOnlyAnotherAgentInSameCanonicalWorkspace() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-vm-concurrency-\(UUID().uuidString)", isDirectory: true)
        let firstProject = root.appendingPathComponent("first", isDirectory: true)
        let secondProject = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = AgentViewModel(sessionStore: ConcurrentAgentSessionStore())
        let sameWorkspace = makeSession(workspaceRoot: firstProject)
        let otherWorkspace = makeSession(workspaceRoot: secondProject)
        let sameRunID = UUID()
        let otherRunID = UUID()

        // Seed the two selectable idle tasks through the same persistence/event
        // surface production runs use.
        viewModel.beginRunTracking(runID: sameRunID, session: sameWorkspace, userRequest: nil)
        await viewModel.finish(sameWorkspace, runID: sameRunID)
        viewModel.beginRunTracking(runID: otherRunID, session: otherWorkspace, userRequest: nil)
        await viewModel.finish(otherWorkspace, runID: otherRunID)

        var running = makeSession(workspaceRoot: firstProject)
        running.state = .running
        let runningRunID = UUID()
        viewModel.beginRunTracking(runID: runningRunID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runningRunID)

        viewModel.activeMode = .agent
        viewModel.selectedSessionID = sameWorkspace.id
        viewModel.draft = "edit the same checkout"
        XCTAssertFalse(viewModel.canSend)

        viewModel.selectedSessionID = otherWorkspace.id
        viewModel.draft = "edit an independent checkout"
        XCTAssertTrue(viewModel.canSend)

        running.state = .completed
        await viewModel.finish(running, runID: runningRunID)
    }

    private func makeSession(workspaceRoot: URL) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.model = "test-model"
        session.workspace = AgentWorkspace(
            name: workspaceRoot.lastPathComponent,
            rootPath: workspaceRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        return session
    }
}
