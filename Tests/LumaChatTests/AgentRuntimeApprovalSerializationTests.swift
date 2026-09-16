import Foundation
import XCTest

@testable import LumaChat

private actor ApprovalSerializationProvider: AgentModelProvider {
    nonisolated let id = "approval-serialization-provider"
    private var responses: [AgentModelResponse]

    init(responses: [AgentModelResponse]) {
        self.responses = responses
    }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: true,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 8_192,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }
}

private actor NetworkExecutionProbe {
    private var executions = 0

    func record() { executions += 1 }
    func count() -> Int { executions }
}

private struct ApprovalNetworkReadTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let probe: NetworkExecutionProbe
    let description = "A parallel-safe network read used to verify approval serialization."
    let inputSchema = JSONValue.objectSchema(properties: [:])
    let category = AgentToolCategory.web
    let permissionLevel = AgentPermissionLevel.read
    let requiresNetwork = true
    let supportsParallelExecution = true

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await probe.record()
        return AgentToolResult(content: "network read completed")
    }
}

private actor ApprovalConcurrencyProbe {
    private var active = 0
    private var maximumConcurrent = 0
    private var requests = 0

    func approve(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        requests += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        try? await Task.sleep(for: .milliseconds(60))
        active -= 1
        return .allowOnce
    }

    func snapshot() -> (requests: Int, maximumConcurrent: Int) {
        (requests, maximumConcurrent)
    }
}

final class AgentRuntimeApprovalSerializationTests: XCTestCase {
    func testDisabledNetworkReadApprovalsAreSerializedBeforeParallelExecution() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "approval-serialization-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executionProbe = NetworkExecutionProbe()
        let approvalProbe = ApprovalConcurrencyProbe()
        let registry = ToolRegistry()
        try await registry.register([
            ApprovalNetworkReadTool(
                id: "network-read-a",
                name: "network_read_a",
                displayName: "Network Read A",
                probe: executionProbe
            ),
            ApprovalNetworkReadTool(
                id: "network-read-b",
                name: "network_read_b",
                displayName: "Network Read B",
                probe: executionProbe
            ),
        ])
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        let provider = ApprovalSerializationProvider(responses: [
            AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [
                    AgentToolCall(id: "network-a", name: "network_read_a"),
                    AgentToolCall(id: "network-b", name: "network_read_b"),
                ],
                finishReason: "tool_calls",
                usage: nil
            ),
            AgentModelResponse(
                content: "both reads completed",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            ),
        ])
        var session = AgentSession(mode: .agent)
        session.model = "model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        var settings = AgentSettings()
        settings.permissionMode = .fullAccess
        settings.networkAccess = false
        settings.maxSteps = 4

        let result = await runtime.run(
            session: session,
            userRequest: "perform two network reads",
            provider: provider,
            settings: settings,
            approvalHandler: { request in await approvalProbe.approve(request) },
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let approvals = await approvalProbe.snapshot()
        let executions = await executionProbe.count()
        XCTAssertEqual(approvals.requests, 2)
        XCTAssertEqual(approvals.maximumConcurrent, 1)
        XCTAssertEqual(executions, 2)
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.count, 2)
    }
}
