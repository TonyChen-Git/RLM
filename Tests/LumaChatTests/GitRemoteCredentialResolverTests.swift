import Foundation
import XCTest

@testable import LumaChat

final class GitRemoteCredentialResolverTests: XCTestCase {
    func testAuthenticationMaterialIsRedactedFromTerminalResultProgressAndArtifacts() async throws {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "git-auth-redaction-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = "github_pat_terminal_secret_123456"
        let authentication = GitRemoteCommandAuthentication(
            token: token,
            remoteURL: "https://github.com/acme/luma.git"
        )
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: AgentWorkspace(
                name: root.lastPathComponent,
                rootPath: root.path,
                allowedPaths: [],
                gitRepository: false
            ))
        )
        let progress = GitCredentialProgressProbe()
        var environment = authentication.environment
        environment["LUMA_RAW_TOKEN_TEST"] = token
        let result = try await terminal.run(
            command: "printf '%s\\n' \"$LUMACHAT_GIT_HTTP_AUTHORIZATION\"; "
                + "printf '%s\\n' \"$LUMA_RAW_TOKEN_TEST\" >&2",
            timeout: 5,
            environment: environment,
            redactionSecrets: authentication.redactionSecrets,
            progressHandler: { update in await progress.record(update) }
        )

        let header = "Authorization: Bearer \(token)"
        let encodedResult = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        let progressText = await progress.text()
        for rendered in [encodedResult, progressText] {
            XCTAssertFalse(rendered.contains(token), rendered)
            XCTAssertFalse(rendered.contains(header), rendered)
            XCTAssertTrue(rendered.contains("[REDACTED]"), rendered)
        }
        for path in [result.stdoutArtifactPath, result.stderrArtifactPath].compactMap({ $0 }) {
            let artifact = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
            XCTAssertFalse(artifact.contains(token), artifact)
            XCTAssertFalse(artifact.contains(header), artifact)
            XCTAssertTrue(artifact.contains("[REDACTED]"), artifact)
        }
        await terminal.dispose()
    }

    func testOfficialGitHubCredentialIsURLScopedAndNeverAppearsInArguments() throws {
        let token = "github_pat_phase_b_secret_123456"
        let store = RecordingPullRequestCredentialStore(token: token)
        let resolver = GitRemoteCredentialResolver.configured(credentialStore: store)

        let authentication = try XCTUnwrap(resolver.resolve(
            "https://github.com/acme/luma.git",
            .github
        ))
        let arguments = authentication.gitGlobalArguments.joined(separator: " ")

        XCTAssertFalse(arguments.contains(token))
        XCTAssertTrue(arguments.contains("http.https://github.com/acme/luma.git.extraHeader"))
        XCTAssertTrue(arguments.contains("http.sslVerify=true"))
        XCTAssertTrue(arguments.contains("http.followRedirects=false"))
        XCTAssertTrue(arguments.contains("http.proxy="))
        XCTAssertEqual(
            authentication.environment[GitRemoteCommandAuthentication.authorizationEnvironmentKey],
            "Authorization: Bearer \(token)"
        )
        XCTAssertEqual(Set(authentication.redactionSecrets), [token, "Authorization: Bearer \(token)"])
        XCTAssertEqual(store.loadCount, 1)
    }

    func testCredentialAuthorizationRequiresExactSupportedHTTPSOrigin() throws {
        let enterprise = PullRequestProviderConfiguration(
            providerID: "github",
            apiEndpoint: "https://git.example.test:8443/api/v3"
        )
        XCTAssertTrue(try GitRemoteCredentialResolver.authorizes(
            remoteURL: "https://git.example.test:8443/acme/luma.git",
            providerConfiguration: enterprise
        ))
        for remote in [
            "https://git.example.test/acme/luma.git",
            "https://other.example.test:8443/acme/luma.git",
            "http://git.example.test:8443/acme/luma.git",
            "ssh://git@git.example.test:8443/acme/luma.git",
            "https://user@git.example.test:8443/acme/luma.git",
            "https://git.example.test:8443/acme/luma.git?token=bad",
            "https://git.example.test:8443/acme/luma.git#fragment"
        ] {
            XCTAssertFalse(try GitRemoteCredentialResolver.authorizes(
                remoteURL: remote,
                providerConfiguration: enterprise
            ), remote)
        }

        XCTAssertTrue(try GitRemoteCredentialResolver.authorizes(
            remoteURL: "https://github.com/acme/luma.git",
            providerConfiguration: .github
        ))
        XCTAssertFalse(try GitRemoteCredentialResolver.authorizes(
            remoteURL: "https://api.github.com/acme/luma.git",
            providerConfiguration: .github
        ))
    }

    func testUnauthorizedRemoteDoesNotReadCredentialStore() throws {
        let store = RecordingPullRequestCredentialStore(token: "github_pat_never_loaded")
        let resolver = GitRemoteCredentialResolver.configured(credentialStore: store)

        XCTAssertNil(try resolver.resolve("https://example.invalid/acme/luma.git", .github))
        XCTAssertNil(try resolver.resolve("git@github.com:acme/luma.git", .github))
        XCTAssertEqual(store.loadCount, 0)
    }

    func testLoopbackVariantsAndShortCredentialsFailClosed() throws {
        for host in [
            "localhost", "localhost.", "127.0.0.1", "127.255.255.254",
            "::1", "0:0:0:0:0:0:0:1", "::ffff:127.0.0.1", "2130706433"
        ] {
            XCTAssertTrue(AgentHTTPOrigin.isLoopback(host), host)
        }
        XCTAssertFalse(AgentHTTPOrigin.isLoopback("128.0.0.1"))
        XCTAssertThrowsError(try PullRequestCredentialStore.normalizedToken("abc"))
        XCTAssertEqual(
            try PullRequestCredentialStore.normalizedToken("  token-value  "),
            "token-value"
        )
    }
}

private actor GitCredentialProgressProbe {
    private var updates: [AgentToolProgress] = []

    func record(_ update: AgentToolProgress) {
        updates.append(update)
    }

    func text() -> String {
        updates.map(\.delta).joined()
    }
}

private final class RecordingPullRequestCredentialStore: PullRequestCredentialStorage,
    @unchecked Sendable {
    private let lock = NSLock()
    private let token: String?
    private var loads = 0

    init(token: String?) { self.token = token }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func saveToken(
        _ token: String,
        configuration: PullRequestProviderConfiguration
    ) throws {}

    func loadToken(
        configuration: PullRequestProviderConfiguration
    ) throws -> String? {
        lock.lock()
        loads += 1
        lock.unlock()
        return token
    }

    func deleteToken(configuration: PullRequestProviderConfiguration) throws {}
}
