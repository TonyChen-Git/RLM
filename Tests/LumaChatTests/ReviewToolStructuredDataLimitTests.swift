import Foundation
import XCTest

@testable import LumaChat

final class ReviewToolStructuredDataLimitTests: XCTestCase {
    func testReviewSourceUsesExecutorCeilingAndKeepsPaginationFooterVisible() async throws {
        let source = String(repeating: "é", count: 2_000)
        let readers = ReviewWorkflowSourceReaders(
            local: { _, _ in
                ReviewWorkflowSourceSnapshot(
                    content: source,
                    filePaths: ["Sources/Value.swift"]
                )
            },
            pullRequest: { _, _ in throw ReviewWorkflowToolError.sourceReaderUnavailable }
        )
        let registry = ToolRegistry()
        try await registry.register(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
        )
        let executor = ToolExecutor(
            registry: registry,
            maximumResultCharacters: 1_024
        )
        var context = Self.context()
        // Deliberately stale: ToolExecutor is the final authority for the
        // actual model-visible ceiling and must lower this before execution.
        context.maximumToolResultCharacters = 200_000

        let result = try await executor.execute(
            AgentToolCall(
                name: ReviewWorkflowToolFactory.sourceToolName,
                arguments: .object(["max_bytes": .number(192 * 1_024)])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 1_024)
        XCTAssertNil(result.artifactPath)
        XCTAssertTrue(result.content.contains("Host pagination required"))
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: try XCTUnwrap(context.reviewWorkflow)
        )
        XCTAssertEqual(receipt.offset, 0)
        XCTAssertTrue(receipt.hasMore)
        XCTAssertGreaterThan(receipt.nextOffset, 0)
    }

    func testReviewSubmissionEnvelopeSurvivesOrdinaryPresentationLimit() async throws {
        let payload = String(repeating: "x", count: 32 * 1_024)
        let registry = ToolRegistry()
        try await registry.register(ReviewStructuredDataProbe(payload: payload))
        let executor = ToolExecutor(
            registry: registry,
            maximumResultCharacters: 1_024
        )

        let result = try await executor.execute(
            AgentToolCall(
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: .emptyObject
            ),
            context: Self.context(),
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.data?["payload"]?.stringValue, payload)
    }

    func testReviewSubmissionEnvelopeStillFailsClosedAboveDedicatedLimit() async throws {
        let payload = String(
            repeating: "x",
            count: ReviewWorkflowToolFactory.maximumSubmissionEnvelopeBytes + 4_096
        )
        let registry = ToolRegistry()
        try await registry.register(ReviewStructuredDataProbe(payload: payload))
        let executor = ToolExecutor(
            registry: registry,
            maximumResultCharacters: 1_024
        )

        let result = try await executor.execute(
            AgentToolCall(
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: .emptyObject
            ),
            context: Self.context(),
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )

        XCTAssertEqual(result.data?["truncated"]?.boolValue, true)
        XCTAssertNil(result.data?["payload"])
    }

    private static func context() -> AgentToolContext {
        AgentToolContext(
            sessionID: UUID(),
            mode: .plan,
            workspace: AgentWorkspace(
                name: "Review data limit",
                rootPath: FileManager.default.temporaryDirectory.path,
                allowedPaths: [],
                gitRepository: true
            ),
            reviewWorkflow: ReviewWorkflowRequest(
                workflow: .changes,
                sourceContext: nil
            ),
            reviewSourceSessionID: UUID()
        )
    }
}

private struct ReviewStructuredDataProbe: AgentTool {
    let payload: String
    let id = "builtin.review_submit_findings"
    let name = "review_submit_findings"
    let displayName = "Review structured-data probe"
    let description = "Returns bounded structured Review data for executor-limit tests."
    let inputSchema: JSONValue = .objectSchema(properties: [:])
    let category = AgentToolCategory.git
    let permissionLevel = AgentPermissionLevel.read
    let requiresNetwork = false
    let supportsParallelExecution = false

    func execute(
        arguments _: JSONValue,
        context _: AgentToolContext
    ) async throws -> AgentToolResult {
        AgentToolResult(
            content: "structured Review result",
            data: .object(["payload": .string(payload)])
        )
    }
}
