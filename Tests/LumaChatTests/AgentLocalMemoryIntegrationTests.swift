import Foundation
import XCTest
@testable import LumaChat

private actor LocalMemoryCaptureProvider: AgentModelProvider {
    nonisolated let id = "local-memory-capture"
    private var captured: [AgentModelRequest] = []

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 8_192,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        captured.append(request)
        return AgentModelResponse(
            content: "done", reasoningSummary: nil, toolCalls: [],
            finishReason: "stop", usage: nil
        )
    }

    func requests() -> [AgentModelRequest] { captured }
}

private actor LocalMemorySettingsStore: AgentSettingsPersisting {
    private var value = AgentSettings()
    func load() -> AgentSettings { value }
    func save(_ settings: AgentSettings) { value = settings }
}

final class AgentLocalMemoryIntegrationTests: XCTestCase {
    @MainActor
    func testBackgroundScanOnlySuggestsCompletedOptedInTasksAndRecoversIdempotently() async throws {
        let base = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "memory-scan-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = AgentWorkspace(
            name: "workspace", rootPath: workspaceRoot.path,
            allowedPaths: [], bookmarkData: nil, gitRepository: false
        )
        let project = AgentProject(name: "Memory Project", primaryWorkspace: workspace)
        let sessionStore = AgentSessionStore(sessionsRoot: base.appendingPathComponent("sessions"))
        let catalogStore = AgentProjectCatalogStore(
            catalogFile: base.appendingPathComponent("catalog.json")
        )
        let memoryStore = AgentLocalMemoryStore(
            storageRoot: base.appendingPathComponent("memories")
        )
        let settingsStore = LocalMemorySettingsStore()
        try await catalogStore.saveProjects([project])
        _ = try await memoryStore.setEnabled(true, projectID: project.id)
        for state in [AgentRunState.completed, .paused] {
            var session = AgentSession(mode: .agent)
            session.state = state
            session.projectID = project.id
            session.projectFolderID = project.primaryFolderID
            session.workspace = workspace
            session.memoryContributionEnabled = true
            session.messages = [AgentMessage(
                role: .user, content: "Remember: prefer focused changes"
            )]
            try await sessionStore.save(session)
        }
        var settings = AgentSettings()
        settings.memoriesEnabled = true
        settings.automaticMemorySuggestionsEnabled = true
        let model = AgentViewModel(
            sessionStore: sessionStore, projectCatalogStore: catalogStore,
            settingsStore: settingsStore, localMemoryStore: memoryStore
        )
        try await model.restoreProjectCatalogState()
        let didUpdate = await model.updateSettings(settings)
        XCTAssertTrue(didUpdate)
        var snapshot = try await memoryStore.load(projectID: project.id)
        for _ in 0..<50 where snapshot.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            snapshot = try await memoryStore.load(projectID: project.id)
        }
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries[0].status, .proposed)
        let unapprovedContext = try await memoryStore.approvedForContext(projectID: project.id)
        XCTAssertTrue(unapprovedContext.isEmpty)
        model.selectedSessionID = model.sessions.first(where: { $0.state == .completed })?.id
        await model.searchLocalMemories(query: "focused")
        XCTAssertEqual(model.localMemorySearchResults.first?.entry.status, .proposed)
        await model.approveSelectedLocalMemory(id: snapshot.entries[0].id)
        XCTAssertEqual(model.localMemorySearchResults.first?.entry.status, .approved)

        let reopened = AgentViewModel(
            sessionStore: sessionStore, projectCatalogStore: catalogStore,
            settingsStore: settingsStore, localMemoryStore: memoryStore
        )
        try await reopened.restoreProjectCatalogState()
        let didUpdateAgain = await reopened.updateSettings(settings)
        XCTAssertTrue(didUpdateAgain)
        try await Task.sleep(for: .milliseconds(100))
        let recovered = try await memoryStore.load(projectID: project.id)
        XCTAssertEqual(recovered.entries.count, 1)
        settings.memoriesEnabled = false
        let disabled = await model.updateSettings(settings)
        XCTAssertTrue(disabled)
        XCTAssertTrue(model.localMemorySearchResults.isEmpty)
        await model.searchLocalMemories(query: "focused")
        XCTAssertTrue(model.localMemorySearchResults.isEmpty)
    }

    func testBackgroundPlannerRequiresFinishedOptedInTaskAndSourceEvidence() throws {
        var session = AgentSession(mode: .agent)
        session.projectID = UUID()
        session.memoryContributionEnabled = true
        session.state = .completed
        let useful = AgentMessage(role: .user, content: "I prefer concise responses")
        let secret = AgentMessage(role: .user, content: "Remember: token=super-secret-value")
        let unlabeledSecret = AgentMessage(
            role: .user, content: "Remember: password is super-secret-value"
        )
        let opaqueSecret = AgentMessage(
            role: .user,
            content: "Remember: AB12CD34EF56GH78IJ90KL12MN34OP56"
        )
        let ordinary = AgentMessage(role: .user, content: "Please fix the build")
        session.messages = [useful, secret, unlabeledSecret, opaqueSecret, ordinary]
        let candidates = AgentLocalMemorySuggestionPlanner.candidates(in: session)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.category, .preference)
        XCTAssertEqual(candidates.first?.source.messageID, useful.id)
        XCTAssertEqual(candidates.first?.source.taskID, session.id)
        XCTAssertFalse(candidates[0].source.excerpt.contains("super-secret-value"))

        session.state = .running
        XCTAssertTrue(AgentLocalMemorySuggestionPlanner.candidates(in: session).isEmpty)
        session.state = .completed
        session.memoryContributionEnabled = false
        XCTAssertTrue(AgentLocalMemorySuggestionPlanner.candidates(in: session).isEmpty)
        session.memoryContributionEnabled = true
        session.projectID = nil
        XCTAssertTrue(AgentLocalMemorySuggestionPlanner.candidates(in: session).isEmpty)
    }

    func testAutomaticSuggestionSettingDefaultsOffForOldSettings() throws {
        let restored = try JSONDecoder().decode(
            AgentSettings.self, from: Data("{}".utf8)
        )
        XCTAssertFalse(restored.memoriesEnabled)
        XCTAssertFalse(restored.automaticMemorySuggestionsEnabled)
    }

    func testProjectionOnlyIncludesApprovedRedactedEntriesWithinBudget() throws {
        let now = Date()
        let entries = [
            AgentLocalMemoryEntry(
                id: UUID(), text: "token=super-secret-value", status: .approved,
                createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: "draft is private", status: .proposed,
                createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: String(repeating: "x", count: 3_900),
                status: .approved, createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: "Prefer concise output", status: .approved,
                createdAt: now, updatedAt: now
            )
        ]
        let projection = try XCTUnwrap(AgentLocalMemoryPrompt.render(entries))
        XCTAssertLessThanOrEqual(projection.utf8.count, AgentLocalMemoryPrompt.maximumBytes)
        XCTAssertFalse(projection.contains("super-secret-value"))
        XCTAssertFalse(projection.contains("draft is private"))
        XCTAssertTrue(projection.contains("Prefer concise output"))
        XCTAssertNil(AgentLocalMemoryPrompt.render([entries[1]]))
    }

    func testRuntimeSendsMemoryOnlyAsTransientProviderContext() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "memory-runtime-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = AgentSession(mode: .agent)
        session.model = "capture-model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent, rootPath: root.path,
            allowedPaths: [], bookmarkData: nil, gitRepository: false
        )
        let registry = ToolRegistry()
        let provider = LocalMemoryCaptureProvider()
        let runtime = AgentRuntime(
            registry: registry, executor: ToolExecutor(registry: registry)
        )
        let completed = await runtime.run(
            session: session,
            userRequest: "summarize",
            provider: provider,
            approvedMemoryContext: "[\"Prefer short answers\"]",
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(completed.state, .completed, completed.lastError ?? "")
        let requests = await provider.requests()
        let memory = try XCTUnwrap(requests.first?.messages.first(where: {
            $0.name == "luma-approved-local-memory"
        }))
        XCTAssertTrue(memory.content.contains("Prefer short answers"))
        XCTAssertFalse(completed.messages.contains(where: {
            $0.name == "luma-approved-local-memory"
        }))

        let nextProvider = LocalMemoryCaptureProvider()
        let nextRuntime = AgentRuntime(
            registry: registry, executor: ToolExecutor(registry: registry)
        )
        let next = await nextRuntime.run(
            session: completed,
            userRequest: "again",
            provider: nextProvider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(next.state, .completed, next.lastError ?? "")
        let nextRequests = await nextProvider.requests()
        XCTAssertFalse(nextRequests.first?.messages.contains(where: {
            $0.name == "luma-approved-local-memory"
        }) ?? true)
    }
}
