import Foundation
import XCTest
@testable import LumaChat

private actor GitLifecycleProbe {
    private(set) var statusCalls = 0
    private(set) var unstagedCalls = 0
    private(set) var stagedCalls = 0

    func status() -> AgentToolResult {
        statusCalls += 1
        return AgentToolResult(content: "## main\n M Sources/App.swift")
    }

    func diff(staged: Bool) -> AgentToolResult {
        if staged { stagedCalls += 1 } else { unstagedCalls += 1 }
        return AgentToolResult(content: staged ? "staged diff" : "unstaged diff")
    }

    func counts() -> (Int, Int, Int) { (statusCalls, unstagedCalls, stagedCalls) }
}

private struct GitLifecycleTool: AgentTool {
    let probe: GitLifecycleProbe
    let isStatus: Bool
    var id: String { "test.\(name)" }
    var name: String { isStatus ? "git_status" : "git_diff" }
    var displayName: String { isStatus ? "Git Status" : "Git Diff" }
    let description = "Git lifecycle test tool"
    var inputSchema: JSONValue {
        .objectSchema(properties: isStatus ? [:] : ["staged": .booleanSchema()])
    }
    let category = AgentToolCategory.git
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = true

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        if isStatus { return await probe.status() }
        return await probe.diff(staged: arguments["staged"]?.boolValue ?? false)
    }
}

private actor GitLifecycleProvider: AgentModelProvider {
    nonisolated let id = "git-lifecycle"
    private var requests: [AgentModelRequest] = []

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
        return AgentModelResponse(
            content: "final without asking for Git tools",
            reasoningSummary: nil,
            toolCalls: [],
            finishReason: "stop",
            usage: nil
        )
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

final class AgentRuntimeGitLifecycleTests: XCTestCase {
    func testHostGuaranteesInitialStatusAndFinalStagedUnstagedDiff() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-git-lifecycle", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = GitLifecycleProbe()
        let registry = ToolRegistry()
        try await registry.register([
            GitLifecycleTool(probe: probe, isStatus: true),
            GitLifecycleTool(probe: probe, isStatus: false)
        ])
        let provider = GitLifecycleProvider()
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        var session = AgentSession(mode: .agent)
        session.model = "git-model"
        session.workspace = AgentWorkspace(
            name: "Git Fixture",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )

        let result = await runtime.run(
            session: session,
            userRequest: "finish directly",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let counts = await probe.counts()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
        let requests = await provider.capturedRequests()
        XCTAssertTrue(requests.first?.messages.contains(where: {
            $0.name == "luma-agent-git-status" && $0.content.contains("## main")
        }) == true)
        XCTAssertEqual(result.steps.filter { $0.toolCall?.name == "git_status" }.count, 1)
        XCTAssertEqual(result.steps.filter { $0.toolCall?.name == "git_diff" }.count, 2)
        XCTAssertTrue(result.messages.contains { $0.name == "luma-agent-git-final-unstaged" })
        XCTAssertTrue(result.messages.contains { $0.name == "luma-agent-git-final-staged" })
        XCTAssertEqual(result.messages.last?.content, "final without asking for Git tools")
    }
}
