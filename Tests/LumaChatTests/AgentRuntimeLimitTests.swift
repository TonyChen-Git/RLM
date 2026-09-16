import Foundation
import XCTest
@testable import LumaChat

private actor StepLimitProvider: AgentModelProvider {
    nonisolated let id = "step-limit"

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        .init(
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
        .init(
            content: "",
            reasoningSummary: nil,
            toolCalls: [.init(id: "one", name: "step_probe")],
            finishReason: "tool_calls",
            usage: nil
        )
    }
}

private actor StepLimitProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct StepLimitTool: AgentTool {
    let probe: StepLimitProbe
    let id = "step-limit-probe"
    let name = "step_probe"
    let displayName = "Step Probe"
    let description = "Records an execution."
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = false
    let inputSchema = JSONValue.objectSchema(properties: [:])

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await probe.record()
        return .init(content: "executed")
    }
}

final class AgentRuntimeLimitTests: XCTestCase {
    func testMaximumStepCountDoesNotExecuteAnOutOfBudgetTool() async throws {
        let workspaceURL = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "agent-step-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let probe = StepLimitProbe()
        let registry = ToolRegistry()
        try await registry.register(StepLimitTool(probe: probe))
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        var session = AgentSession(mode: .agent)
        session.model = "model"
        session.workspace = AgentWorkspace(
            name: "step-limit",
            rootPath: workspaceURL.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        var settings = AgentSettings()
        settings.maxSteps = 1

        let result = await runtime.run(
            session: session,
            userRequest: "Use the tool",
            provider: StepLimitProvider(),
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        let executionCount = await probe.count
        XCTAssertEqual(executionCount, 0)
        XCTAssertFalse(result.messages.contains { $0.role == .tool })
    }
}
