import Foundation
import XCTest
@testable import LumaChat

private actor ProjectSettingsIntegrationProbe {
    private(set) var environments: [[String: String]] = []

    func record(_ environment: [String: String]) {
        environments.append(environment)
    }

    func snapshot() -> [[String: String]] { environments }
}

private actor ProjectSettingsApprovalProbe {
    private(set) var count = 0

    func record() { count += 1 }
    func snapshot() -> Int { count }
}

private struct ProjectSettingsWriteProbeTool: AgentTool {
    let probe: ProjectSettingsIntegrationProbe
    let id = "test.project-settings-write"
    let name = "project_settings_write_probe"
    let displayName = "Project Settings Write Probe"
    let description = "Records effective project environment for integration testing."
    let inputSchema = JSONValue.objectSchema(properties: [:])
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.write
    let supportsParallelExecution = false

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await probe.record(context.environment)
        return AgentToolResult(content: "project settings applied")
    }
}

private actor ProjectSettingsScriptProvider: AgentModelProvider {
    nonisolated let id = "project-settings-script"
    private var responses: [AgentModelResponse]
    private var requests: [AgentModelRequest] = []

    init(responses: [AgentModelResponse]) { self.responses = responses }

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
        requests.append(request)
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

final class AgentProjectSettingsIntegrationTests: XCTestCase {
    func testAllowForSessionPersistsAcrossRuntimeRecreation() async throws {
        let root = try workspaceRoot("permission-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let executionProbe = ProjectSettingsIntegrationProbe()
        let approvalProbe = ProjectSettingsApprovalProbe()
        let registry = ToolRegistry()
        try await registry.register(ProjectSettingsWriteProbeTool(probe: executionProbe))
        var session = AgentSession(mode: .agent)
        session.model = "tool-model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false
        )
        var settings = AgentSettings()
        settings.permissionMode = .askEveryTime
        let firstProvider = ProjectSettingsScriptProvider(responses: [
            AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [AgentToolCall(id: "persist-write-1", name: "project_settings_write_probe")],
                finishReason: "tool_calls",
                usage: nil
            ),
            AgentModelResponse(
                content: "first done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        let firstRuntime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        let first = await firstRuntime.run(
            session: session,
            userRequest: "persist approval",
            provider: firstProvider,
            settings: settings,
            approvalHandler: { _ in
                await approvalProbe.record()
                return .allowForSession
            },
            eventHandler: { _ in }
        )
        XCTAssertEqual(first.state, .completed, first.lastError ?? "")
        XCTAssertEqual(first.permissionAllowances?.count, 1)
        let firstApprovalCount = await approvalProbe.snapshot()
        XCTAssertEqual(firstApprovalCount, 1)

        let secondProvider = ProjectSettingsScriptProvider(responses: [
            AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [AgentToolCall(id: "persist-write-2", name: "project_settings_write_probe")],
                finishReason: "tool_calls",
                usage: nil
            ),
            AgentModelResponse(
                content: "second done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        let recreatedRuntime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        let second = await recreatedRuntime.run(
            session: first,
            userRequest: nil,
            provider: secondProvider,
            settings: settings,
            approvalHandler: { _ in
                await approvalProbe.record()
                return .deny
            },
            eventHandler: { _ in }
        )
        XCTAssertEqual(second.state, .completed, second.lastError ?? "")
        let finalApprovalCount = await approvalProbe.snapshot()
        XCTAssertEqual(finalApprovalCount, 1, "Restored session grant should skip a duplicate prompt")
        let executions = await executionProbe.snapshot()
        XCTAssertEqual(executions.count, 2)
    }

    func testRuntimeAppliesPermissionEnvironmentAndProjectPrompt() async throws {
        let root = try workspaceRoot("runtime")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ProjectSettingsIntegrationProbe()
        let registry = ToolRegistry()
        try await registry.register(ProjectSettingsWriteProbeTool(probe: probe))
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        let provider = ProjectSettingsScriptProvider(responses: [
            AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [AgentToolCall(id: "write-1", name: "project_settings_write_probe")],
                finishReason: "tool_calls",
                usage: nil
            ),
            AgentModelResponse(
                content: "done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        var session = AgentSession(mode: .agent)
        session.model = "tool-model"
        session.todos = [
            AgentTodo(title: "Persist across resume", status: .inProgress)
        ]
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false
        )
        var global = AgentSettings()
        global.permissionMode = .askEveryTime

        let result = await runtime.run(
            session: session,
            userRequest: "apply project settings",
            projectSettings: AgentProjectSettings(
                agentPermission: .fullAccess,
                environmentVariables: ["PROJECT_TOKEN": "not-a-real-secret"],
                systemPrompt: "Use the workspace release checklist."
            ),
            provider: provider,
            settings: global,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let environments = await probe.snapshot()
        XCTAssertEqual(environments, [["PROJECT_TOKEN": "not-a-real-secret"]])
        let requests = await provider.capturedRequests()
        XCTAssertTrue(requests.first?.messages.contains(where: {
            $0.role == .system
                && $0.name == "luma-project-settings-system"
                && $0.content.contains("workspace release checklist")
        }) == true)
        XCTAssertTrue(requests.allSatisfy { request in
            request.messages.contains(where: {
                $0.role == .system
                    && $0.name == "luma-agent-todos"
                    && $0.content.contains("Persist across resume")
            })
        })
    }

    func testProjectCommandRulesDenyFirstAndExactAllow() async throws {
        let root = try workspaceRoot("command-policy")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false
        )
        let metadata = ToolMetadata(
            id: "builtin.run_command",
            name: "run_command",
            displayName: "Run Command",
            category: .terminal,
            permissionLevel: .execute,
            requiresNetwork: false,
            supportsParallelExecution: false
        )
        let manager = PermissionManager()
        let allowedContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            allowedCommands: ["swift test"]
        )
        let allowed = await manager.authorize(
            metadata: metadata,
            call: AgentToolCall(
                name: "run_command",
                arguments: .object(["command": .string("swift test")])
            ),
            context: allowedContext,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        XCTAssertEqual(allowed, .allow)

        let deniedContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            allowedCommands: ["swift test"],
            deniedCommands: ["swift test"]
        )
        guard case .deny(let reason) = await manager.authorize(
            metadata: metadata,
            call: AgentToolCall(
                name: "run_command",
                arguments: .object(["command": .string("swift test")])
            ),
            context: deniedContext,
            permissionMode: .fullAccess,
            networkAccess: true
        ) else {
            return XCTFail("Denied Project command was authorized")
        }
        XCTAssertTrue(reason.contains("Project Settings"))
    }

    func testMCPSelectionDistinguishesInheritNoneAndExplicitList() {
        let first = UUID()
        let second = UUID()
        XCTAssertTrue(AgentViewModel.mcpServerIsSelected(
            first,
            projectSettings: AgentProjectSettings(mcpServerIDs: nil)
        ))
        XCTAssertFalse(AgentViewModel.mcpServerIsSelected(
            first,
            projectSettings: AgentProjectSettings(mcpServerIDs: [])
        ))
        XCTAssertTrue(AgentViewModel.mcpServerIsSelected(
            first,
            projectSettings: AgentProjectSettings(mcpServerIDs: [first])
        ))
        XCTAssertFalse(AgentViewModel.mcpServerIsSelected(
            second,
            projectSettings: AgentProjectSettings(mcpServerIDs: [first])
        ))
    }

    private func workspaceRoot(_ label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("project-settings-integration", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
