import Foundation
import XCTest

@testable import LumaChat

final class ReviewToolIsolationTests: XCTestCase {
    func testReviewDefinitionsExposeOnlyDedicatedAndLocalReadOnlyInspectionTools() async throws {
        let registry = ToolRegistry()
        let recorder = ReviewIsolationInvocationRecorder()
        try await registry.register(Self.tools(recorder: recorder))

        let definitions = await registry.definitions(
            for: .agent,
            context: Self.context(reviewWorkflow: Self.reviewRequest)
        )

        XCTAssertEqual(
            definitions.map(\.name),
            [
                "grep",
                "read_file",
                "review_pull_request_source_read",
                "review_source_read",
                "review_submit_findings",
                "search_files"
            ]
        )
    }

    func testReviewExecutorRejectsEveryHiddenToolBeforeExecution() async throws {
        let registry = ToolRegistry()
        let recorder = ReviewIsolationInvocationRecorder()
        let tools = Self.tools(recorder: recorder)
        try await registry.register(tools)
        let executor = ToolExecutor(registry: registry)
        let context = Self.context(reviewWorkflow: Self.reviewRequest)
        let exposed = Set(
            await registry.definitions(for: .agent, context: context).map(\.name)
        )
        let hiddenNames = tools.map(\.name).filter { !exposed.contains($0) }

        XCTAssertFalse(hiddenNames.isEmpty)
        for name in hiddenNames {
            let result = try await executor.execute(
                AgentToolCall(name: name),
                context: context,
                permissionMode: .fullAccess,
                networkAccess: true,
                approvalHandler: { _ in
                    XCTFail("Review isolation must reject before approval")
                    return .allowOnce
                }
            )
            XCTAssertTrue(result.isError, "Expected Review rejection for \(name)")
            XCTAssertEqual(
                result.content,
                ReviewToolIsolationPolicy.denialReason,
                "Unexpected rejection for \(name)"
            )
        }

        let invokedNames = await recorder.names()
        XCTAssertEqual(invokedNames, [])
    }

    func testReviewExecutorRunsOnlyExposedTools() async throws {
        let registry = ToolRegistry()
        let recorder = ReviewIsolationInvocationRecorder()
        try await registry.register(Self.tools(recorder: recorder))
        let executor = ToolExecutor(registry: registry)
        let context = Self.context(reviewWorkflow: Self.reviewRequest)
        let exposedNames = await registry.definitions(for: .agent, context: context).map(\.name)

        for name in exposedNames {
            let result = try await executor.execute(
                AgentToolCall(name: name),
                context: context,
                permissionMode: .fullAccess,
                networkAccess: true,
                approvalHandler: nil
            )
            XCTAssertFalse(result.isError, "Expected Review allow for \(name)")
        }

        let invokedNames = await recorder.names()
        XCTAssertEqual(Set(invokedNames), Set(exposedNames))
    }

    func testNormalAgentAndPlanBehaviorIsUnchangedWithoutReviewWorkflow() async throws {
        let registry = ToolRegistry()
        let recorder = ReviewIsolationInvocationRecorder()
        try await registry.register(Self.tools(recorder: recorder))
        let context = Self.context(reviewWorkflow: nil)

        let agentNames = Set(
            await registry.definitions(for: .agent, context: context).map(\.name)
        )
        XCTAssertEqual(agentNames, Set(Self.tools(recorder: recorder).map(\.name)))

        let planNames = Set(
            await registry.definitions(for: .plan, context: context).map(\.name)
        )
        XCTAssertTrue(planNames.contains("run_command_read_metadata"))
        XCTAssertTrue(planNames.contains("git_status"))
        XCTAssertTrue(planNames.contains("todo_read"))
        XCTAssertFalse(planNames.contains("write_file"))

        let result = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: "write_file"),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: true,
            approvalHandler: nil
        )
        XCTAssertFalse(result.isError)
        let invokedNames = await recorder.names()
        XCTAssertEqual(invokedNames, ["write_file"])
    }

    private static let reviewRequest = ReviewWorkflowRequest(
        workflow: .changes,
        sourceContext: nil
    )

    private static func context(
        reviewWorkflow: ReviewWorkflowRequest?
    ) -> AgentToolContext {
        AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "Review isolation",
                rootPath: FileManager.default.temporaryDirectory.path,
                allowedPaths: [],
                gitRepository: true
            ),
            reviewWorkflow: reviewWorkflow
        )
    }

    private static func tools(
        recorder: ReviewIsolationInvocationRecorder
    ) -> [any AgentTool] {
        [
            tool("review_source_read", category: .git, recorder: recorder),
            tool(
                "review_pull_request_source_read",
                category: .git,
                requiresNetwork: true,
                recorder: recorder
            ),
            tool("review_submit_findings", category: .git, recorder: recorder),
            tool("read_file", category: .filesystem, recorder: recorder),
            tool("search_files", category: .search, recorder: recorder),
            tool("grep", category: .search, recorder: recorder),
            tool(
                "networked_file_read",
                category: .filesystem,
                requiresNetwork: true,
                recorder: recorder
            ),
            tool(
                "write_file",
                category: .filesystem,
                permission: .write,
                recorder: recorder
            ),
            tool(
                "mutating_search",
                category: .search,
                permission: .write,
                recorder: recorder
            ),
            tool("run_command_read_metadata", category: .terminal, recorder: recorder),
            tool("git_status", category: .git, recorder: recorder),
            tool(
                "pull_request_get",
                category: .git,
                requiresNetwork: true,
                recorder: recorder
            ),
            tool(
                "fetch_url",
                category: .web,
                requiresNetwork: true,
                recorder: recorder
            ),
            tool("mcp_read_only", category: .mcp, recorder: recorder),
            tool("computer_screenshot", category: .system, recorder: recorder),
            tool("todo_read", category: .todo, recorder: recorder),
            tool("image_inspect", category: .image, recorder: recorder)
        ]
    }

    private static func tool(
        _ name: String,
        category: AgentToolCategory,
        permission: AgentPermissionLevel = .read,
        requiresNetwork: Bool = false,
        recorder: ReviewIsolationInvocationRecorder
    ) -> ReviewIsolationProbeTool {
        ReviewIsolationProbeTool(
            id: "test.\(name)",
            name: name,
            category: category,
            permissionLevel: permission,
            requiresNetwork: requiresNetwork,
            recorder: recorder
        )
    }
}

private actor ReviewIsolationInvocationRecorder {
    private var invokedNames: [String] = []

    func record(_ name: String) {
        invokedNames.append(name)
    }

    func names() -> [String] {
        invokedNames
    }
}

private struct ReviewIsolationProbeTool: AgentTool {
    let id: String
    let name: String
    var displayName: String { name }
    var description: String { "Review isolation probe \(name)" }
    let inputSchema: JSONValue = .objectSchema(properties: [:])
    let category: AgentToolCategory
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork: Bool
    let supportsParallelExecution = true
    let recorder: ReviewIsolationInvocationRecorder

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        await recorder.record(name)
        return AgentToolResult(content: "executed \(name)")
    }
}
