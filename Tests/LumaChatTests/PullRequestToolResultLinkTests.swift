import Foundation
import XCTest
@testable import LumaChat

final class PullRequestToolResultLinkTests: XCTestCase {
    func testAcceptsSuccessfulStructuredHTTPSURLForEveryPullRequestTool() throws {
        for toolName in [
            "pull_request_get",
            "pull_request_context",
            "pull_request_create"
        ] {
            let destination = PullRequestToolResultLink.destination(
                for: step(
                    toolName: toolName,
                    url: "HTTPS://GitHub.COM/acme/luma/pull/17"
                )
            )

            XCTAssertEqual(
                destination?.absoluteString,
                "https://github.com/acme/luma/pull/17",
                toolName
            )
        }

        XCTAssertEqual(
            PullRequestToolResultLink.destination(
                for: step(
                    toolName: "pull_request_get",
                    url: "https://enterprise.example:8443/acme/luma/pull/17"
                )
            )?.absoluteString,
            "https://enterprise.example:8443/acme/luma/pull/17"
        )
    }

    func testRejectsNonPullRequestAndUnsuccessfulResults() {
        XCTAssertNil(PullRequestToolResultLink.destination(
            for: step(toolName: "fetch_url", url: "https://github.com/acme/luma/pull/17")
        ))
        XCTAssertNil(PullRequestToolResultLink.destination(
            for: step(
                toolName: "pull_request_get",
                url: "https://github.com/acme/luma/pull/17",
                status: .failed
            )
        ))
        XCTAssertNil(PullRequestToolResultLink.destination(
            for: step(
                toolName: "pull_request_get",
                url: "https://github.com/acme/luma/pull/17",
                isError: true
            )
        ))
    }

    func testRejectsMissingAndNonStringStructuredURL() {
        let noData = AgentStep(
            kind: .git,
            title: "Get Pull Request",
            status: .completed,
            toolCall: AgentToolCall(name: "pull_request_get"),
            toolResult: AgentToolResult(content: "done")
        )
        XCTAssertNil(PullRequestToolResultLink.destination(for: noData))

        var wrongType = noData
        wrongType.toolResult?.data = .object(["url": .number(17)])
        XCTAssertNil(PullRequestToolResultLink.destination(for: wrongType))

        var nonObject = noData
        nonObject.toolResult?.data = .string("https://github.com/acme/luma/pull/17")
        XCTAssertNil(PullRequestToolResultLink.destination(for: nonObject))
    }

    func testRejectsUnsafeOrAmbiguousURLs() {
        let unsafeURLs = [
            "http://github.com/acme/luma/pull/17",
            "https://user@github.com/acme/luma/pull/17",
            "https://user:password@github.com/acme/luma/pull/17",
            "https://github.com/acme/luma/pull/17?token=secret",
            "https://github.com/acme/luma/pull/17#discussion",
            "https://github.com/acme/luma/pull/17?",
            "https://github.com/acme/luma/pull/17#",
            "https:///acme/luma/pull/17",
            " https://github.com/acme/luma/pull/17",
            "https://github.com/acme/luma/pull/17\n",
            "https://github.com/acme/luma/pull request/17",
            "https://github.com/acme/luma/%",
            "https://github.com:0/acme/luma/pull/17",
            "https://github.com:65536/acme/luma/pull/17"
        ]

        for url in unsafeURLs {
            XCTAssertNil(
                PullRequestToolResultLink.destination(
                    for: step(toolName: "pull_request_get", url: url)
                ),
                url
            )
        }
    }

    func testToolResultsExposeSafeLinkDataWithoutClaimingWorkspaceMutation() async throws {
        let summary = PullRequestSummary(
            reference: PullRequestReference(
                providerID: "github",
                repositoryID: "acme/luma",
                pullRequestID: "17"
            ),
            title: "Review",
            body: nil,
            webURL: try XCTUnwrap(URL(string: "https://github.com/acme/luma/pull/17")),
            state: .open,
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature/review",
            author: "octocat",
            mergeable: true,
            changedFileCount: 1
        )
        let provider = PullRequestLinkStubProvider(summary: summary)
        let tools = PullRequestToolFactory.makeTools(
            resolver: PullRequestProviderResolver { _ in provider }
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "pull-request-link",
                rootPath: FileManager.default.temporaryDirectory.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            )
        )

        let get = try await execute(
            "pull_request_get",
            arguments: referenceArguments,
            tools: tools,
            context: context
        )
        let pullRequestContext = try await execute(
            "pull_request_context",
            arguments: referenceArguments,
            tools: tools,
            context: context
        )
        let create = try await execute(
            "pull_request_create",
            arguments: .object([
                "repository": .string("acme/luma"),
                "title": .string("Review"),
                "head_branch": .string("feature/review"),
                "base_branch": .string("main")
            ]),
            tools: tools,
            context: context
        )

        for result in [get, pullRequestContext, create] {
            XCTAssertEqual(
                result.data?["url"]?.stringValue,
                "https://github.com/acme/luma/pull/17"
            )
        }
        XCTAssertFalse(create.mayHaveChangedWorkspace)
    }

    private var referenceArguments: JSONValue {
        .object([
            "repository": .string("acme/luma"),
            "pull_request_id": .string("17")
        ])
    }

    private func step(
        toolName: String,
        url: String,
        status: AgentStepStatus = .completed,
        isError: Bool = false
    ) -> AgentStep {
        AgentStep(
            kind: .git,
            title: "Pull Request",
            status: status,
            toolCall: AgentToolCall(name: toolName),
            toolResult: AgentToolResult(
                content: "provider result",
                data: .object(["url": .string(url)]),
                isError: isError
            )
        )
    }

    private func execute(
        _ name: String,
        arguments: JSONValue,
        tools: [any AgentTool],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let tool = try XCTUnwrap(tools.first(where: { $0.name == name }))
        return try await tool.execute(arguments: arguments, context: context)
    }
}

private struct PullRequestLinkStubProvider: PullRequestProvider {
    var id = "github"
    let summary: PullRequestSummary

    func create(_: PullRequestCreateRequest) async throws -> PullRequestSummary {
        summary
    }

    func pullRequest(_: PullRequestReference) async throws -> PullRequestSummary {
        summary
    }

    func context(
        for _: PullRequestReference,
        maximumFiles _: Int
    ) async throws -> PullRequestContext {
        PullRequestContext(
            summary: summary,
            files: [],
            filesTruncated: false,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
