import Darwin
import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AgentProjectSettingsTests: XCTestCase {
    func testCanonicalIdentityIsStableForEquivalentWorkspacePaths() throws {
        let fixture = try makeFixture("canonical-identity")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let child = fixture.workspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        let direct = try AgentProjectIdentity.resolve(workspaceRootPath: fixture.workspace.path)
        let equivalent = try AgentProjectIdentity.resolve(
            workspaceRootPath: child.appendingPathComponent("..").path
        )

        XCTAssertEqual(direct, equivalent)
        XCTAssertEqual(direct.storageKey.count, 64)
        XCTAssertTrue(direct.storageKey.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testRoundTripPersistsEveryFieldButKeepsEnvironmentValuesInSecretStore() async throws {
        let fixture = try makeFixture("round-trip")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secrets = InMemoryAgentProjectSecretStore()
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        let serverID = UUID()
        let expected = AgentProjectSettings(
            displayName: "自訂研發專案",
            preferredModel: "qwen3-coder:30b",
            agentPermission: .askEveryTime,
            allowedCommands: ["swift test"],
            deniedCommands: ["git push origin main"],
            mcpServerIDs: [serverID],
            environmentVariables: [
                "API_TOKEN": "project-super-secret-token",
                "EMPTY_VALUE": ""
            ],
            systemPrompt: "Follow this project's release checklist."
        )

        try await store.save(expected)
        let loaded = try await store.load()
        let displayName = try await store.loadDisplayName()
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(displayName, "自訂研發專案")

        let raw = try String(decoding: Data(contentsOf: store.settingsFileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("project-super-secret-token"))
        XCTAssertTrue(raw.contains("${LUMACHAT_PROJECT_KEYCHAIN}"))
        XCTAssertTrue(raw.contains(serverID.uuidString))
        XCTAssertEqual(secrets.valuesSnapshot().count, 2)

        let fileMode = try permissions(of: store.settingsFileURL)
        XCTAssertEqual(fileMode & 0o077, 0)
        XCTAssertEqual(fileMode & 0o600, 0o600)
        XCTAssertEqual(
            try permissions(of: store.settingsFileURL.deletingLastPathComponent()),
            0o700
        )
    }

    func testMCPNilInheritsAndEmptyArrayExplicitlyDisablesAllServers() async throws {
        let fixture = try makeFixture("mcp-semantics")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: InMemoryAgentProjectSecretStore()
        )

        try await store.save(AgentProjectSettings(mcpServerIDs: []))
        var loaded = try await store.load()
        XCTAssertEqual(loaded.mcpServerIDs, [])
        var raw = try String(decoding: Data(contentsOf: store.settingsFileURL), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"mcpServerIDs\" : ["))

        try await store.save(AgentProjectSettings(mcpServerIDs: nil))
        loaded = try await store.load()
        XCTAssertNil(loaded.mcpServerIDs)
        raw = try String(decoding: Data(contentsOf: store.settingsFileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains("mcpServerIDs"))
    }

    func testMissingKeychainValueIsOmittedInsteadOfExposingMarkerToRuntime() async throws {
        let fixture = try makeFixture("missing-secret")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secrets = InMemoryAgentProjectSecretStore()
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        try await store.save(AgentProjectSettings(environmentVariables: ["TOKEN": "secret-value"]))
        secrets.deleteAllForTesting()

        let loaded = try await store.load()
        XCTAssertEqual(loaded.environmentVariables, [:])
    }

    func testFailedSecretTransactionRestoresOldSecretsAndOldAtomicDocument() async throws {
        let fixture = try makeFixture("transaction-rollback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secrets = InMemoryAgentProjectSecretStore()
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        let original = AgentProjectSettings(
            preferredModel: "original-model",
            environmentVariables: ["API_TOKEN": "original-secret"]
        )
        try await store.save(original)
        let originalDocument = try Data(contentsOf: store.settingsFileURL)
        secrets.failNextSave(accountSuffix: "|environment|NEW_TOKEN")

        do {
            try await store.save(AgentProjectSettings(
                preferredModel: "replacement-model",
                environmentVariables: [
                    "API_TOKEN": "replacement-secret",
                    "NEW_TOKEN": "new-secret"
                ]
            ))
            XCTFail("Expected injected secret-store failure")
        } catch InMemoryAgentProjectSecretStore.Failure.injected {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), originalDocument)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, original)
        XCTAssertFalse(secrets.valuesSnapshot().values.contains("replacement-secret"))
        XCTAssertFalse(secrets.valuesSnapshot().values.contains("new-secret"))
    }

    func testIdentityMismatchAndNonRegularSettingsFileFailClosed() async throws {
        let fixture = try makeFixture("identity-mismatch")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondWorkspace = fixture.root.appendingPathComponent("workspace-2", isDirectory: true)
        try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: false)
        let secrets = InMemoryAgentProjectSecretStore()
        let first = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        let second = try AgentProjectSettingsStore(
            workspaceRootPath: secondWorkspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        try await first.save(AgentProjectSettings(preferredModel: "first"))
        try await second.save(AgentProjectSettings(preferredModel: "second"))
        let firstDocument = try Data(contentsOf: first.settingsFileURL)
        try firstDocument.write(to: second.settingsFileURL)

        do {
            _ = try await second.load()
            XCTFail("Expected canonical identity mismatch")
        } catch AgentProjectSettingsError.identityMismatch {
            // Expected.
        }

        try FileManager.default.removeItem(at: first.settingsFileURL)
        try FileManager.default.createDirectory(at: first.settingsFileURL, withIntermediateDirectories: false)
        do {
            _ = try await first.load()
            XCTFail("Expected non-regular settings path rejection")
        } catch AgentProjectSettingsError.unsafeStorage {
            // Expected.
        }
    }

    func testStorageRootSymlinkIsRejectedWithoutWritingThroughIt() async throws {
        let fixture = try makeFixture("storage-symlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let linkedStorage = fixture.root.appendingPathComponent("linked-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedStorage, withDestinationURL: outside)
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: linkedStorage,
            secretStore: InMemoryAgentProjectSecretStore()
        )

        do {
            try await store.save(AgentProjectSettings(preferredModel: "model"))
            XCTFail("Expected symlink storage root rejection")
        } catch AgentProjectSettingsError.unsafeStorage {
            // Expected.
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testDeleteRemovesMarkerDocumentAndReferencedSecrets() async throws {
        let fixture = try makeFixture("delete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secrets = InMemoryAgentProjectSecretStore()
        let store = try AgentProjectSettingsStore(
            workspaceRootPath: fixture.workspace.path,
            storageRoot: fixture.storage,
            secretStore: secrets
        )
        try await store.save(AgentProjectSettings(
            environmentVariables: ["TOKEN": "secret", "SECOND_TOKEN": "second"]
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.settingsFileURL.path))
        XCTAssertEqual(secrets.valuesSnapshot().count, 2)

        try await store.delete()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsFileURL.path))
        XCTAssertEqual(secrets.valuesSnapshot(), [:])
        let loaded = try await store.load()
        XCTAssertEqual(loaded, AgentProjectSettings())
    }

    func testValidationRejectsAmbiguousCommandsUnsafeEnvironmentAndOversizedPrompt() {
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(displayName: "invalid\nname")
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(
                displayName: String(
                    repeating: "x",
                    count: AgentProjectSettingsLimits.maximumDisplayNameBytes + 1
                )
            )
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(allowedCommands: [" swift test"])
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(deniedCommands: ["git push", "git push"])
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(environmentVariables: ["PATH": "/untrusted"])
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(environmentVariables: ["DYLD_INSERT_LIBRARIES": "payload"])
        ))
        XCTAssertThrowsError(try AgentProjectSettingsValidation.validate(
            AgentProjectSettings(
                systemPrompt: String(
                    repeating: "x",
                    count: AgentProjectSettingsLimits.maximumSystemPromptBytes + 1
                )
            )
        ))
    }

    func testCommandPolicyIsExactDeterministicAndNeverAutoApprovesRiskyCommands() {
        let evaluator = AgentProjectCommandPolicyEvaluator()
        let settings = AgentProjectSettings(
            allowedCommands: ["swift test", "curl https://example.invalid", "rm file.txt"],
            deniedCommands: ["git push", "swift test --filter SecretTests"]
        )

        XCTAssertEqual(
            evaluator.evaluate(command: "swift test", settings: settings),
            .automaticApprovalCandidate
        )
        XCTAssertEqual(
            evaluator.evaluate(command: "curl https://example.invalid", settings: settings),
            .requiresStandardAuthorization
        )
        XCTAssertEqual(
            evaluator.evaluate(command: "rm file.txt", settings: settings),
            .requiresStandardAuthorization
        )
        XCTAssertEqual(
            evaluator.evaluate(command: "swift  test", settings: settings),
            .requiresStandardAuthorization
        )
        XCTAssertEqual(
            evaluator.evaluate(command: "git push", settings: settings),
            .denied(.matchedDeniedCommand)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                command: "same",
                settings: AgentProjectSettings(
                    allowedCommands: ["same"],
                    deniedCommands: ["same"]
                )
            ),
            .denied(.matchedDeniedCommand)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                command: "safe",
                settings: AgentProjectSettings(allowedCommands: ["safe", "safe"])
            ),
            .denied(.invalidAllowedPolicy)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                command: "safe",
                settings: AgentProjectSettings(deniedCommands: ["bad", "bad"])
            ),
            .denied(.invalidDeniedPolicy)
        )
        XCTAssertEqual(
            evaluator.evaluate(command: "swift test\nrm file", settings: settings),
            .denied(.invalidCommand)
        )
    }

    private func makeFixture(_ name: String) throws -> (
        root: URL,
        workspace: URL,
        storage: URL
    ) {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-project-settings-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let storage = root.appendingPathComponent("settings-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (root, workspace, storage)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class InMemoryAgentProjectSecretStore: AgentProjectSecretStore, @unchecked Sendable {
    enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var failingAccountSuffix: String?

    func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failingAccountSuffix, account.hasSuffix(failingAccountSuffix) {
            self.failingAccountSuffix = nil
            throw Failure.injected
        }
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

    func failNextSave(accountSuffix: String) {
        lock.lock()
        defer { lock.unlock() }
        failingAccountSuffix = accountSuffix
    }

    func valuesSnapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func deleteAllForTesting() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}
