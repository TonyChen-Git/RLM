import Foundation
import XCTest

@testable import LumaChat

private final class PhaseHOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.notConnectedToInternet)
        )
    }

    override func stopLoading() {}
}

private struct PhaseHNoRemoteCredentialProvider: RemoteRunnerCredentialProviding {
    func credential(for runnerID: UUID) throws -> RemoteRunnerCredential? { nil }
}

private struct PhaseHDisconnectingSSHTransport: SSHCommandTransporting {
    func run(
        configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData: Data?,
        request: SSHCommandRequest
    ) async throws -> SSHCommandResult {
        throw RemoteExecutionError.connectionFailed("injected transport disconnect")
    }
}

final class PhaseHFailureInjectionTests: XCTestCase {
    func testNetworkDownLeavesUpdateStateUnchanged() async throws {
        let root = try fixtureRoot("network-down")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json")
        )
        let original = LumaUpdatePersistentState(
            lastKnownGood: LumaLastKnownGoodApplication(
                version: "1.4.0",
                build: 7,
                bundleIdentifier: "com.lumachat.desktop",
                teamIdentifier: "ABCDE12345",
                applicationPath: root.appendingPathComponent("known-good.app").path,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        try store.saveState(original)
        let service = LumaUpdateService(
            configuration: LumaUpdateTrustConfiguration(
                feedURL: URL(string: "https://updates.example.test/feed.json")!,
                publicKeyBase64: Data(repeating: 7, count: 32).base64EncodedString(),
                teamIdentifier: "ABCDE12345",
                bundleIdentifier: "com.lumachat.desktop"
            ),
            stateStore: store,
            session: offlineSession(),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            backupRoot: root.appendingPathComponent("backups", isDirectory: true)
        )

        do {
            _ = try await service.check()
            XCTFail("A disconnected update check must fail.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Expected URLError.notConnectedToInternet, got \(error)")
        }
        XCTAssertEqual(try store.loadState(), original)
    }

    func testOllamaDownSurfacesConnectionFailureWithoutModels() async throws {
        let settings = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://127.0.0.1:11434",
            selectedModel: "qwen3.8"
        )

        do {
            _ = try await LLMClient(session: offlineSession()).fetchModels(
                settings: settings,
                apiKey: nil
            )
            XCTFail("An unavailable Ollama backend must fail.")
        } catch ChatError.server(let message) {
            XCTAssertTrue(message.contains("無法連線到 LLM 伺服器"), message)
        } catch {
            XCTFail("Expected a bounded ChatError.server, got \(error)")
        }
    }

    func testMCPProcessCrashFailsPendingRequestAndDisconnects() async throws {
        let transport = MCPStdioTransport(
            serverID: UUID(),
            configuration: MCPStdioConfiguration(
                command: "/bin/zsh",
                arguments: ["-c", "IFS= read -r request; exit 73"]
            ),
            allowsNetwork: false
        )
        try await transport.start()
        do {
            _ = try await transport.send(
                MCPJSONRPCRequest(id: .integer(1), method: "failure-injection")
            )
            XCTFail("A crashed MCP process must fail its pending request.")
        } catch MCPError.transport(let detail) {
            XCTAssertTrue(detail.contains("exited with status 73"), detail)
        } catch {
            XCTFail("Expected an MCP transport failure, got \(error)")
        }

        do {
            _ = try await transport.send(
                MCPJSONRPCRequest(id: .integer(2), method: "after-crash")
            )
            XCTFail("A crashed MCP process must remain disconnected.")
        } catch MCPError.notConnected {
            // Expected.
        } catch {
            XCTFail("Expected MCPError.notConnected, got \(error)")
        }
        await transport.stop()
    }

    func testBrowserCrashCleansEphemeralProfileAndSession() async throws {
        let root = try fixtureRoot("browser-crash")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BrowserService()

        do {
            _ = try await service.start(configuration: BrowserLaunchConfiguration(
                repositoryRoot: root,
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                startupTimeout: 1,
                commandTimeout: 1
            ))
            XCTFail("A browser that exits during startup must fail.")
        } catch BrowserError.browserExited(let status) {
            XCTAssertEqual(status, 1)
        } catch {
            XCTFail("Expected BrowserError.browserExited, got \(error)")
        }

        let sessions = await service.listSessions()
        XCTAssertTrue(sessions.isEmpty)
        let ephemeralRoot = root
            .appendingPathComponent("tmp/browser/ephemeral", isDirectory: true)
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: ephemeralRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(remaining.isEmpty, "A failed launch left an ephemeral profile behind.")
    }

    func testGitIndexLockFailsWithoutMutatingIndexOrWorktree() async throws {
        let root = try fixtureRoot("git-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        try run("/usr/bin/git", ["init", "--initial-branch=main"], at: root)
        try run("/usr/bin/git", ["config", "user.name", "Luma Failure Tests"], at: root)
        try run("/usr/bin/git", ["config", "user.email", "failure-tests@invalid.local"], at: root)
        let fileURL = root.appendingPathComponent("sample.txt")
        try Data("before\n".utf8).write(to: fileURL)
        try run("/usr/bin/git", ["add", "sample.txt"], at: root)
        try run("/usr/bin/git", ["commit", "--no-gpg-sign", "-m", "initial"], at: root)
        try Data("after\n".utf8).write(to: fileURL)
        let indexURL = root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: indexURL)
        let lockURL = root.appendingPathComponent(".git/index.lock")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data("owned by another process".utf8)
        ))

        let workspace = AgentWorkspace(
            name: "Git lock failure",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let service = try GitService(
            validator: validator,
            terminal: TerminalSession(validator: validator),
            changes: ChangeManager(validator: validator),
            timeout: 10
        )

        do {
            _ = try await service.add(paths: ["sample.txt"], taskID: UUID())
            XCTFail("Git staging must fail while index.lock exists.")
        } catch GitServiceError.commandFailed(_, let exitCode, let output) {
            XCTAssertNotEqual(exitCode, 0)
            XCTAssertTrue(output.contains("index.lock"), output)
        } catch {
            XCTFail("Expected GitServiceError.commandFailed, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: indexURL), indexBefore)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testRemoteDisconnectPropagatesStableConnectionFailure() async throws {
        let configuration = RemoteRunnerConfiguration(
            name: "Disconnected runner",
            host: "runner.example.test",
            username: "runner",
            workspaceRoot: "/srv/luma",
            knownHostsFile: AppPaths.projectTemporaryRoot
                .appendingPathComponent("phase-h-known-hosts").path,
            authentication: .systemAgent
        )
        let backend = try SSHRemoteExecutionBackend(
            configuration: configuration,
            credentialProvider: PhaseHNoRemoteCredentialProvider(),
            transport: PhaseHDisconnectingSSHTransport()
        )

        do {
            _ = try await backend.verifyConnection()
            XCTFail("A disconnected SSH transport must fail verification.")
        } catch let error as RemoteExecutionError {
            XCTAssertEqual(error.code, .connection)
        } catch {
            XCTFail("Expected RemoteExecutionError.connectionFailed, got \(error)")
        }
    }

    private func fixtureRoot(_ name: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-h-failure-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func offlineSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhaseHOfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func run(_ executable: String, _ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PhaseHFailureInjectionTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: diagnostic]
            )
        }
    }
}
