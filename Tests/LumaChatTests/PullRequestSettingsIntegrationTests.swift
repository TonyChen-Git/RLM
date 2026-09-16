import Foundation
import XCTest

@testable import LumaChat

final class PullRequestSettingsIntegrationTests: XCTestCase {
    @MainActor
    func testStartWiresInjectedCredentialStoreIntoGitRemoteCommands() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "view-model-git-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--initial-branch=main"], at: repository)
        let provider = PullRequestProviderConfiguration(
            providerID: "github",
            apiEndpoint: "https://git-auth-test.invalid/api/v3"
        )
        try runGit([
            "remote", "add", "origin", "https://git-auth-test.invalid/acme/luma.git"
        ], at: repository)

        var settings = AgentSettings()
        settings.pullRequestProvider = provider
        settings.commandTimeout = 1
        let settingsStore = PullRequestSettingsStoreFake(settings: settings)
        let credentials = PullRequestCredentialStoreFake()
        let token = "view-model-injected-token"
        try credentials.saveToken(token, configuration: provider)
        let environment = BuiltinToolEnvironment()
        let viewModel = AgentViewModel(
            sessionStore: AgentSessionStore(
                sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true)
            ),
            projectCatalogStore: AgentProjectCatalogStore(
                catalogFile: root.appendingPathComponent("projects.json")
            ),
            settingsStore: settingsStore,
            toolEnvironment: environment,
            mcpSettingsStore: MCPSettingsStore(
                fileURL: root.appendingPathComponent("mcp.json")
            ),
            pullRequestCredentialStore: credentials
        )
        await viewModel.start()
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(credentials.loadCount, 0)

        let workspace = AgentWorkspace(
            name: repository.lastPathComponent,
            rootPath: repository.path,
            allowedPaths: [],
            gitRepository: true
        )
        let git = try await environment.gitService(for: AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            commandTimeout: 1
        ))
        do {
            _ = try await git.fetch(
                remote: "origin",
                taskID: UUID(),
                providerConfiguration: provider
            )
            XCTFail("The reserved .invalid remote must not fetch successfully")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
        XCTAssertEqual(credentials.loadCount, 1)
        await viewModel.shutdown()
    }

    @MainActor
    func testConfigurationAndTokenCommitTogetherAndOldScopeIsRemoved() async throws {
        let old = PullRequestProviderConfiguration.github
        let new = PullRequestProviderConfiguration(
            providerID: "GitHub",
            apiEndpoint: "https://enterprise.example/api/v3/"
        )
        var initial = AgentSettings()
        initial.pullRequestProvider = old
        let settingsStore = PullRequestSettingsStoreFake(settings: initial)
        let credentials = PullRequestCredentialStoreFake()
        try credentials.saveToken("old-token", configuration: old)
        let viewModel = AgentViewModel(
            settingsStore: settingsStore,
            pullRequestCredentialStore: credentials
        )

        let saved = await viewModel.updatePullRequestConfiguration(
            new,
            token: "  new-token  "
        )
        XCTAssertTrue(saved)
        let normalized = try new.normalized()
        XCTAssertEqual(viewModel.settings.pullRequestProvider, normalized)
        XCTAssertEqual(
            try credentials.loadToken(configuration: normalized),
            "new-token"
        )
        XCTAssertNil(try credentials.loadToken(configuration: old))
        let persisted = await settingsStore.current()
        XCTAssertEqual(persisted.pullRequestProvider, normalized)
    }

    @MainActor
    func testSettingsFailureRollsBackExactCredentialValue() async throws {
        let configuration = PullRequestProviderConfiguration.github
        let settingsStore = PullRequestSettingsStoreFake(
            settings: AgentSettings(),
            failSaves: true
        )
        let credentials = PullRequestCredentialStoreFake()
        try credentials.saveToken("existing-token", configuration: configuration)
        let viewModel = AgentViewModel(
            settingsStore: settingsStore,
            pullRequestCredentialStore: credentials
        )

        let saved = await viewModel.updatePullRequestConfiguration(
            configuration,
            token: "replacement-token"
        )
        XCTAssertFalse(saved)
        XCTAssertEqual(
            try credentials.loadToken(configuration: configuration),
            "existing-token"
        )
        XCTAssertEqual(viewModel.settings.pullRequestProvider, .github)
    }

    @MainActor
    func testBlankTokenDeletesCurrentScopeWithoutEnteringSettingsJSON() async throws {
        let settingsStore = PullRequestSettingsStoreFake(settings: AgentSettings())
        let credentials = PullRequestCredentialStoreFake()
        try credentials.saveToken("remove-me", configuration: .github)
        let viewModel = AgentViewModel(
            settingsStore: settingsStore,
            pullRequestCredentialStore: credentials
        )

        let saved = await viewModel.updatePullRequestConfiguration(
            .github,
            token: " \n "
        )
        XCTAssertTrue(saved)
        XCTAssertNil(try credentials.loadToken(configuration: .github))
        let persisted = await settingsStore.current()
        let encoded = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
        XCTAssertFalse(encoded.contains("remove-me"))
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PullRequestSettingsIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(
                    decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )]
            )
        }
    }
}

private actor PullRequestSettingsStoreFake: AgentSettingsPersisting {
    private var settings: AgentSettings
    private let failSaves: Bool

    init(settings: AgentSettings, failSaves: Bool = false) {
        self.settings = settings
        self.failSaves = failSaves
    }

    func load() -> AgentSettings { settings }

    func save(_ settings: AgentSettings) throws {
        if failSaves {
            throw PullRequestProviderError.invalidRequest("injected settings failure")
        }
        self.settings = settings
    }

    func current() -> AgentSettings { settings }
}

private final class PullRequestCredentialStoreFake:
    PullRequestCredentialStorage,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var loads = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func saveToken(
        _ token: String,
        configuration: PullRequestProviderConfiguration
    ) throws {
        let account = try PullRequestCredentialStore.account(configuration: configuration)
        let normalized = try PullRequestCredentialStore.normalizedToken(token)
        lock.lock()
        values[account] = normalized
        lock.unlock()
    }

    func loadToken(
        configuration: PullRequestProviderConfiguration
    ) throws -> String? {
        let account = try PullRequestCredentialStore.account(configuration: configuration)
        lock.lock()
        loads += 1
        let value = values[account]
        lock.unlock()
        return value
    }

    func deleteToken(
        configuration: PullRequestProviderConfiguration
    ) throws {
        let account = try PullRequestCredentialStore.account(configuration: configuration)
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}
