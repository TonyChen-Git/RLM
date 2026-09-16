import Foundation
import XCTest

@testable import LumaChat

final class PullRequestToolConfigurationTests: XCTestCase {
    func testOneRegisteredToolResolvesProviderFromEachRunContextSnapshot() async throws {
        let resolver = PullRequestProviderResolver { configuration in
            PullRequestConfigurationStubProvider(
                configuration: try configuration.normalized()
            )
        }
        let tool = try XCTUnwrap(
            PullRequestToolFactory.makeTools(resolver: resolver)
                .first(where: { $0.name == "pull_request_get" })
        )
        let workspace = AgentWorkspace(
            name: "pr-config",
            rootPath: AppPaths.projectTemporaryRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let arguments = JSONValue.object([
            "repository": .string("acme/luma"),
            "pull_request_id": .string("7")
        ])
        let first = try await tool.execute(
            arguments: arguments,
            context: AgentToolContext(
                sessionID: UUID(),
                mode: .plan,
                workspace: workspace,
                pullRequestProvider: .init(
                    providerID: "GitHub",
                    apiEndpoint: "https://github-one.example/api/v3/"
                )
            )
        )
        let second = try await tool.execute(
            arguments: arguments,
            context: AgentToolContext(
                sessionID: UUID(),
                mode: .plan,
                workspace: workspace,
                pullRequestProvider: .init(
                    providerID: "github",
                    apiEndpoint: "https://github-two.example/api/v3"
                )
            )
        )

        XCTAssertTrue(first.content.contains("github-one.example"), first.content)
        XCTAssertTrue(second.content.contains("github-two.example"), second.content)
    }

    func testAgentSettingsLegacyDecodeDefaultsAndInvalidEndpointFailsClosed() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(AgentSettings.self, from: Data("{}".utf8))
                .pullRequestProvider,
            .github
        )
        let malformed = Data(#"{"pullRequestProvider":{"providerID":"github","apiEndpoint":"http://remote.example/api"}}"#.utf8)
        XCTAssertEqual(
            try decoder.decode(AgentSettings.self, from: malformed)
                .pullRequestProvider,
            .github
        )

        var configured = AgentSettings()
        configured.pullRequestProvider = .init(
            providerID: "github",
            apiEndpoint: "https://enterprise.example/api/v3"
        )
        let encoded = String(decoding: try JSONEncoder().encode(configured), as: UTF8.self)
        XCTAssertTrue(encoded.contains("enterprise.example"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
    }

    func testProviderConfigurationRejectsURLsFoundationCouldRepair() throws {
        for endpoint in [
            "https://example.com/bad path",
            "https://example.com/bad%path",
            "https://user:@example.com/api",
            "https://example.com:65536/api",
            "https://example.com/api?",
            "https://example.com/api#"
        ] {
            XCTAssertThrowsError(try PullRequestProviderConfiguration(
                providerID: "github",
                apiEndpoint: endpoint
            ).normalized(), endpoint)
        }
        XCTAssertEqual(
            try PullRequestProviderConfiguration(
                providerID: "GitHub",
                apiEndpoint: "https://Enterprise.Example:8443/api/v3/"
            ).normalized(),
            .init(
                providerID: "github",
                apiEndpoint: "https://enterprise.example:8443/api/v3"
            )
        )
    }
}

private struct PullRequestConfigurationStubProvider: PullRequestProvider {
    let configuration: PullRequestProviderConfiguration
    var id: String { configuration.providerID }

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary {
        summary(repository: request.repositoryID, pullRequestID: "created")
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        summary(
            repository: reference.repositoryID,
            pullRequestID: reference.pullRequestID
        )
    }

    func context(
        for reference: PullRequestReference,
        maximumFiles _: Int
    ) async throws -> PullRequestContext {
        PullRequestContext(
            summary: summary(
                repository: reference.repositoryID,
                pullRequestID: reference.pullRequestID
            ),
            files: [],
            filesTruncated: false,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func summary(
        repository: String,
        pullRequestID: String
    ) -> PullRequestSummary {
        let base = URL(string: configuration.apiEndpoint)!
        return PullRequestSummary(
            reference: .init(
                providerID: configuration.providerID,
                repositoryID: repository,
                pullRequestID: pullRequestID
            ),
            title: base.host ?? configuration.apiEndpoint,
            body: nil,
            webURL: base.appendingPathComponent("pull/").appendingPathComponent(pullRequestID),
            state: .open,
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature",
            author: nil,
            mergeable: nil,
            changedFileCount: nil
        )
    }
}
