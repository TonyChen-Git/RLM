import Foundation
import XCTest
@testable import LumaChat

final class PullRequestProviderTests: XCTestCase {
    func testGitHubCreateUsesVersionedCredentialedJSONRequest() async throws {
        let transport = PullRequestMockTransport(responses: [
            Self.response(body: Self.pullJSON(number: 17, changedFiles: 2))
        ])
        let provider = try GitHubPullRequestProvider(
            token: "test-token",
            transport: transport,
            now: { Date(timeIntervalSince1970: 123) }
        )

        let summary = try await provider.create(PullRequestCreateRequest(
            repositoryID: "acme/luma",
            title: "Ship review workspace",
            body: "Ready for review",
            headBranch: "feature/review",
            baseBranch: "main",
            isDraft: true
        ))

        XCTAssertEqual(summary.reference, PullRequestReference(
            providerID: "github",
            repositoryID: "acme/luma",
            pullRequestID: "17"
        ))
        XCTAssertEqual(summary.changedFileCount, 2)
        XCTAssertEqual(summary.webURL.absoluteString, "https://github.com/acme/luma/pull/17")

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/acme/luma/pulls")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
            GitHubPullRequestProvider.apiVersion
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Ship review workspace")
        XCTAssertEqual(object["head"] as? String, "feature/review")
        XCTAssertEqual(object["base"] as? String, "main")
        XCTAssertEqual(object["draft"] as? Bool, true)
    }

    func testGitHubContextIsBoundedAndMarksUnavailablePatches() async throws {
        let files = """
        [
          {
            "filename":"Sources/New.swift","status":"added",
            "additions":2,"deletions":0,"changes":2,
            "patch":"@@ -0,0 +1,2 @@\\n+one\\n+two"
          },
          {
            "filename":"Assets/logo.bin","previous_filename":"Assets/old.bin",
            "status":"renamed","additions":0,"deletions":0,"changes":1
          }
        ]
        """
        let transport = PullRequestMockTransport(responses: [
            Self.response(body: Self.pullJSON(number: 9, changedFiles: 3)),
            Self.response(body: files)
        ])
        let provider = try GitHubPullRequestProvider(
            transport: transport,
            now: { Date(timeIntervalSince1970: 456) }
        )
        let reference = PullRequestReference(
            providerID: "github",
            repositoryID: "acme/luma",
            pullRequestID: "9"
        )

        let context = try await provider.context(for: reference, maximumFiles: 2)

        XCTAssertEqual(context.files.count, 2)
        XCTAssertTrue(context.filesTruncated)
        XCTAssertEqual(context.fetchedAt, Date(timeIntervalSince1970: 456))
        XCTAssertEqual(context.files[0].status, .added)
        XCTAssertFalse(context.files[0].isPatchUnavailable)
        XCTAssertEqual(context.files[1].previousPath, "Assets/old.bin")
        XCTAssertEqual(context.files[1].status, .renamed)
        XCTAssertTrue(context.files[1].isPatchUnavailable)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(
            url: try XCTUnwrap(requests.last?.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "per_page" })?.value, "2")
        XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "1")
    }

    func testGitHubProviderFailsClosedBeforeNetworkAndMapsRemoteErrors() async throws {
        let noAuthTransport = PullRequestMockTransport(responses: [])
        let noAuth = try GitHubPullRequestProvider(transport: noAuthTransport)
        do {
            _ = try await noAuth.create(PullRequestCreateRequest(
                repositoryID: "acme/luma",
                title: "Title",
                body: nil,
                headBranch: "feature",
                baseBranch: "main",
                isDraft: false
            ))
            XCTFail("Expected authentication to be required")
        } catch let error as PullRequestProviderError {
            XCTAssertEqual(error, .authenticationRequired)
        }
        let unauthenticatedRequests = await noAuthTransport.capturedRequests()
        XCTAssertTrue(unauthenticatedRequests.isEmpty)

        let invalid = try GitHubPullRequestProvider(
            token: "token",
            transport: noAuthTransport
        )
        do {
            _ = try await invalid.pullRequest(PullRequestReference(
                providerID: "github",
                repositoryID: "../escape",
                pullRequestID: "1"
            ))
            XCTFail("Expected invalid repository rejection")
        } catch let error as PullRequestProviderError {
            XCTAssertEqual(error, .invalidRepositoryID("../escape"))
        }

        let deniedTransport = PullRequestMockTransport(responses: [
            Self.response(
                statusCode: 403,
                body: #"{"message":"API rate limit exceeded"}"#,
                headers: ["x-ratelimit-remaining": "0"]
            )
        ])
        let denied = try GitHubPullRequestProvider(transport: deniedTransport)
        do {
            _ = try await denied.pullRequest(PullRequestReference(
                providerID: "github",
                repositoryID: "acme/luma",
                pullRequestID: "4"
            ))
            XCTFail("Expected rate limit mapping")
        } catch let error as PullRequestProviderError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testProviderRegistryUsesOpaqueReferenceAndBoundsContext() async throws {
        let provider = PullRequestStubProvider(id: "example")
        let service = try PullRequestService(providers: [provider])
        let providerIDs = await service.availableProviderIDs()
        XCTAssertEqual(providerIDs, ["example"])

        let reference = PullRequestReference(
            providerID: "missing",
            repositoryID: "opaque-repository",
            pullRequestID: "opaque-pr"
        )
        do {
            _ = try await service.pullRequest(reference)
            XCTFail("Expected missing provider rejection")
        } catch let error as PullRequestProviderError {
            XCTAssertEqual(error, .providerUnavailable("missing"))
        }

        let validReference = PullRequestReference(
            providerID: "example",
            repositoryID: "opaque-repository",
            pullRequestID: "opaque-pr"
        )
        do {
            _ = try await service.context(for: validReference, maximumFiles: 3_001)
            XCTFail("Expected maximumFiles rejection")
        } catch let error as PullRequestProviderError {
            XCTAssertEqual(
                error,
                .invalidRequest("maximumFiles must be between 1 and 3000")
            )
        }

        XCTAssertThrowsError(try PullRequestService(providers: [provider, provider])) { error in
            XCTAssertEqual(error as? PullRequestProviderError, .duplicateProvider("example"))
        }
    }

    func testCredentialAccountCanonicalizesEndpointAndRejectsCleartextRemote() throws {
        let account = try PullRequestCredentialStore.account(configuration: .init(
            providerID: "GitHub",
            apiEndpoint: "https://API.GitHub.com/"
        ))
        XCTAssertEqual(account, "pull-request|github|https://api.github.com")

        XCTAssertThrowsError(try PullRequestCredentialStore.account(configuration: .init(
            providerID: "github",
            apiEndpoint: "http://github.example.test/api/v3"
        ))) { error in
            XCTAssertEqual(error as? PullRequestProviderError, .invalidEndpoint)
        }

        XCTAssertEqual(
            try PullRequestCredentialStore.apiBaseURL(configuration: .init(
                providerID: "github",
                apiEndpoint: "http://127.0.0.1:8080/api/v3/"
            )).absoluteString,
            "http://127.0.0.1:8080/api/v3"
        )

        for malformedEndpoint in [
            "https://api.github.com:65536",
            "https://api.github.com/%zz",
            "https://api.github.com/\u{0000}control"
        ] {
            let configuration = PullRequestProviderConfiguration(
                providerID: "github",
                apiEndpoint: malformedEndpoint
            )
            XCTAssertThrowsError(
                try PullRequestCredentialStore.account(configuration: configuration)
            ) { error in
                XCTAssertEqual(error as? PullRequestProviderError, .invalidEndpoint)
            }
            XCTAssertThrowsError(
                try PullRequestCredentialStore.apiBaseURL(configuration: configuration)
            ) { error in
                XCTAssertEqual(error as? PullRequestProviderError, .invalidEndpoint)
            }
        }
    }

    func testCredentialStoreUsesInjectedStorageForNormalizedSaveLoadAndDelete() throws {
        let secrets = PullRequestFakeSecretStore()
        let concreteStore = PullRequestCredentialStore(secretStore: secrets)
        let store: any PullRequestCredentialStorage = concreteStore
        let configuration = PullRequestProviderConfiguration(
            providerID: "GitHub",
            apiEndpoint: "https://API.GitHub.com/"
        )
        let account = "pull-request|github|https://api.github.com"

        try store.saveToken(" \n github_pat_test-token \t", configuration: configuration)

        XCTAssertEqual(secrets.valuesSnapshot(), [account: "github_pat_test-token"])
        XCTAssertEqual(try store.loadToken(configuration: configuration), "github_pat_test-token")

        try store.deleteToken(configuration: configuration)

        XCTAssertNil(try store.loadToken(configuration: configuration))
        XCTAssertTrue(secrets.valuesSnapshot().isEmpty)
    }

    func testCredentialStoreRejectsBlankWhitespaceControlAndOversizedTokens() throws {
        let secrets = PullRequestFakeSecretStore()
        let store = PullRequestCredentialStore(secretStore: secrets)
        let configuration = PullRequestProviderConfiguration.github
        let invalidTokens = [
            "",
            " \n\t ",
            "token with-space",
            "token\twith-tab",
            "token\u{0000}with-nul",
            "token\u{007F}with-control",
            String(repeating: "é", count: 2_049)
        ]

        for token in invalidTokens {
            XCTAssertThrowsError(try store.saveToken(token, configuration: configuration)) { error in
                guard case .invalidRequest = error as? PullRequestProviderError else {
                    return XCTFail("Expected invalidRequest, got \(error)")
                }
            }
        }

        XCTAssertTrue(secrets.valuesSnapshot().isEmpty)

        let maximumToken = String(repeating: "x", count: PullRequestCredentialStore.maximumTokenBytes)
        try store.saveToken(maximumToken, configuration: configuration)
        XCTAssertEqual(try store.loadToken(configuration: configuration), maximumToken)
    }

    func testCredentialStoreValidatesPreviouslyStoredTokenOnLoad() throws {
        let secrets = PullRequestFakeSecretStore()
        let store = PullRequestCredentialStore(secretStore: secrets)
        let configuration = PullRequestProviderConfiguration.github
        let account = try PullRequestCredentialStore.account(configuration: configuration)
        secrets.setRawValue("token\u{0000}from-keychain", account: account)

        XCTAssertThrowsError(try store.loadToken(configuration: configuration)) { error in
            guard case .invalidRequest = error as? PullRequestProviderError else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    private static func response(
        statusCode: Int = 200,
        body: String,
        headers: [String: String] = [:]
    ) -> PullRequestHTTPResponse {
        PullRequestHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data(body.utf8),
            finalURL: URL(string: "https://api.github.com")
        )
    }

    private static func pullJSON(number: Int, changedFiles: Int) -> String {
        """
        {
          "number":\(number),
          "title":"Review workspace",
          "body":"Ready",
          "html_url":"https://github.com/acme/luma/pull/\(number)",
          "state":"open",
          "draft":true,
          "merged":false,
          "mergeable":true,
          "changed_files":\(changedFiles),
          "user":{"login":"octocat"},
          "head":{"ref":"feature/review"},
          "base":{"ref":"main"}
        }
        """
    }
}

private actor PullRequestMockTransport: PullRequestHTTPTransport {
    private var responses: [PullRequestHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [PullRequestHTTPResponse]) {
        self.responses = responses
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes _: Int
    ) async throws -> PullRequestHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw PullRequestProviderError.network("unexpected request")
        }
        return responses.removeFirst()
    }

    func capturedRequests() -> [URLRequest] { requests }
}

private struct PullRequestStubProvider: PullRequestProvider {
    var id: String

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary {
        throw PullRequestProviderError.invalidRequest(request.title)
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        throw PullRequestProviderError.invalidPullRequestID(reference.pullRequestID)
    }

    func context(
        for reference: PullRequestReference,
        maximumFiles _: Int
    ) async throws -> PullRequestContext {
        throw PullRequestProviderError.invalidPullRequestID(reference.pullRequestID)
    }
}

private final class PullRequestFakeSecretStore:
    PullRequestCredentialSecretStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }

    func setRawValue(_ value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        values[account] = value
    }

    func valuesSnapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
