import Darwin
import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AgentProjectImportRollbackTests: XCTestCase {
    func testImportUndoSurvivesRestartAndPreservesLaterAuthorityAndCredentials() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings(
            preferredModel: "old-model", systemPrompt: "Original instructions",
            importedRules: [rule("old.mdc", "Original scoped rule")]
        )
        try await store.save(original)
        var imported = original
        imported.preferredModel = "imported-model"
        imported.systemPrompt = "Imported instructions"
        imported.importedRules = [rule("new.mdc", "New scoped rule")]
        try await store.save(imported, importRequest: request(store, baseline: original))
        let preview = try await rollback(store)
        XCTAssertTrue(preview.canRestore)

        var later = imported
        later.displayName = "Later alias"
        later.agentPermission = .askEveryTime
        later.allowedCommands = ["swift test"]
        later.deniedCommands = ["git push"]
        later.mcpServerIDs = [UUID()]
        later.environmentVariables = ["API_TOKEN": "later-secret"]
        try await store.save(later)
        let secretsBeforeRestore = fixture.secrets.snapshot()
        let secretMutations = fixture.secrets.mutations
        let restarted = try fixture.store()
        let restored = try await restarted.restoreImport(id: preview.id)
        var expected = later
        expected.preferredModel = original.preferredModel
        expected.systemPrompt = original.systemPrompt
        expected.importedRules = original.importedRules
        XCTAssertEqual(restored, expected)
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(fixture.secrets.snapshot(), secretsBeforeRestore)
        XCTAssertEqual(fixture.secrets.mutations, secretMutations)
        let remaining = try await restarted.loadImportRollback()
        XCTAssertNil(remaining)
        do {
            _ = try await restarted.restoreImport(id: preview.id)
            XCTFail("An already consumed undo must not apply twice")
        } catch AgentProjectSettingsError.importRollbackUnavailable {}
    }

    func testIdenticalReimportKeepsUndoAndNewImportReplacesItsIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings()
        let imported = AgentProjectSettings(systemPrompt: "First import")
        try await store.save(imported, importRequest: request(store, baseline: original, fields: [.systemPrompt]))
        let first = try await rollback(store)
        try await store.save(imported, importRequest: request(store, baseline: imported, fields: [.systemPrompt]))
        let repeated = try await rollback(store)
        XCTAssertEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.previous, first.previous)
        var second = imported
        second.systemPrompt = "Second import"
        try await store.save(second, importRequest: request(store, baseline: imported, fields: [.systemPrompt]))
        let latest = try await rollback(store)
        XCTAssertNotEqual(latest.id, first.id)
        do {
            _ = try await store.restoreImport(id: first.id)
            XCTFail("A stale preview must not undo a newer import")
        } catch AgentProjectSettingsError.importRollbackUnavailable {}
        let restored = try await store.restoreImport(id: latest.id)
        XCTAssertEqual(restored, imported)
    }

    func testLaterImportedFieldEditRejectsPreviewAndRestoreWithoutChangingDocument() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let imported = AgentProjectSettings(systemPrompt: "Imported")
        try await store.save(imported, importRequest: request(store, baseline: AgentProjectSettings(), fields: [.systemPrompt]))
        let preview = try await rollback(store)
        try await store.save(AgentProjectSettings(systemPrompt: "Later manual edit"))
        let before = try Data(contentsOf: store.settingsFileURL)
        let stale = try await rollback(store)
        XCTAssertFalse(stale.canRestore)
        do {
            _ = try await store.restoreImport(id: preview.id)
            XCTFail("Restore must recheck the current field fingerprint")
        } catch AgentProjectSettingsError.importConflict {}
        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), before)
    }

    func testOnlyActuallyChangedImportFieldsAreRestoredIncludingNilAndEmpty() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings(preferredModel: "unchanged", systemPrompt: nil)
        try await store.save(original)
        var imported = original
        imported.systemPrompt = "Imported"
        try await store.save(imported, importRequest: request(store, baseline: original))
        let preview = try await rollback(store)
        imported.preferredModel = "Later model"
        imported.importedRules = [rule("later.mdc", "Later rule")]
        try await store.save(imported)
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertNil(restored.systemPrompt)
        XCTAssertEqual(restored.preferredModel, "Later model")
        XCTAssertEqual(restored.importedRules, imported.importedRules)
    }

    func testStaleBaselineAndWrongWorkspaceFailBeforeSecretsOrSettingsChange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings(systemPrompt: "Original")
        let staleRequest = try request(store, baseline: original, fields: [.systemPrompt])
        try await store.save(AgentProjectSettings(systemPrompt: "Concurrent edit"))
        let before = try Data(contentsOf: store.settingsFileURL)
        let mutations = fixture.secrets.mutations
        do {
            try await store.save(AgentProjectSettings(environmentVariables: ["TOKEN": "new-secret"], systemPrompt: "Import"), importRequest: staleRequest)
            XCTFail("A stale draft must not overwrite another writer")
        } catch AgentProjectSettingsError.importConflict {}
        let another = try AgentProjectImportSaveRequest(
            identity: AgentProjectIdentity(canonicalRootPath: "/another-project"),
            fields: [.systemPrompt], baseline: AgentProjectSettings(systemPrompt: "Concurrent edit")
        )
        do {
            try await store.save(original, importRequest: another)
            XCTFail("An import request must remain bound to its Project")
        } catch AgentProjectSettingsError.importConflict {}
        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), before)
        XCTAssertEqual(fixture.secrets.mutations, mutations)
    }

    func testUndoRedactsPriorTextAndNeverCopiesEnvironmentSecrets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let secret = "abcdefghijklmnopqrstuvwxyz0123456789"
        let original = AgentProjectSettings(
            environmentVariables: ["API_TOKEN": "environment-secret"],
            systemPrompt: "Previously entered \(secret)",
            importedRules: [rule("prior.mdc", "Previously entered \(secret)")]
        )
        try await store.save(original)
        var imported = original
        imported.systemPrompt = "Safe import"
        imported.importedRules = []
        try await store.save(imported, importRequest: request(store, baseline: original))
        let raw = String(decoding: try Data(contentsOf: store.settingsFileURL), as: UTF8.self)
        XCTAssertFalse(raw.contains(secret))
        XCTAssertFalse(raw.contains("environment-secret"))
        let preview = try await rollback(store)
        XCTAssertFalse(preview.previous.contains(secret))
        XCTAssertFalse(preview.previous.contains("API_TOKEN"))
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertEqual(restored.systemPrompt, ExternalImportSanitizer.redact(original.systemPrompt!))
        XCTAssertEqual(restored.importedRules.first?.redactedContent, "Previously entered [REDACTED]")
        XCTAssertEqual(restored.environmentVariables, original.environmentVariables)
    }

    func testUnredactedImportIsRejectedBeforePersistence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        do {
            try await store.save(
                AgentProjectSettings(systemPrompt: "token=abcdefghijklmnopqrstuvwxyz0123456789"),
                importRequest: request(store, baseline: AgentProjectSettings(), fields: [.systemPrompt])
            )
            XCTFail("Imported sensitive content must not bypass the sanitizer")
        } catch AgentProjectSettingsError.invalidConfiguration {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsFileURL.path))
        XCTAssertEqual(fixture.secrets.mutations, 0)
    }

    func testMissingKeychainValueKeepsItsMarkerDuringUndoWithoutCredentialWrites() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings(environmentVariables: ["TOKEN": "secret"], systemPrompt: "Original")
        try await store.save(original)
        var imported = original
        imported.systemPrompt = "Imported"
        try await store.save(imported, importRequest: request(store, baseline: original, fields: [.systemPrompt]))
        let preview = try await rollback(store)
        fixture.secrets.removeAll()
        let mutations = fixture.secrets.mutations
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertTrue(restored.environmentVariables.isEmpty)
        XCTAssertEqual(fixture.secrets.mutations, mutations)
        let document = try json(store.settingsFileURL)
        let settings = try XCTUnwrap(document["settings"] as? [String: Any])
        XCTAssertEqual(settings["environmentVariables"] as? [String: String], ["TOKEN": "${LUMACHAT_PROJECT_KEYCHAIN}"])
    }

    func testFailedSecretWriteLeavesPriorSettingsAndUndoUsable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let imported = AgentProjectSettings(environmentVariables: ["TOKEN": "old-secret"], systemPrompt: "First")
        try await store.save(imported, importRequest: request(store, baseline: AgentProjectSettings(), fields: [.systemPrompt]))
        let preview = try await rollback(store)
        let before = try Data(contentsOf: store.settingsFileURL)
        fixture.secrets.failNextSave()
        var second = imported
        second.systemPrompt = "Second"
        second.environmentVariables["TOKEN"] = "new-secret"
        do {
            try await store.save(second, importRequest: request(store, baseline: imported, fields: [.systemPrompt]))
            XCTFail("Expected injected credential write failure")
        } catch ImportRollbackSecrets.Failure.injected {}
        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), before)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, imported)
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertNil(restored.systemPrompt)
    }

    func testOversizedCombinedDocumentDoesNotCommitImportOrConsumePriorUndo() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let imported = AgentProjectSettings(
            systemPrompt: String(repeating: ".", count: 250_000),
            importedRules: [rule("prior.mdc", String(repeating: ".", count: 160_000))]
        )
        try await store.save(imported, importRequest: request(store, baseline: AgentProjectSettings()))
        let preview = try await rollback(store)
        let before = try Data(contentsOf: store.settingsFileURL)
        var tooLarge = imported
        tooLarge.systemPrompt = String(repeating: "!", count: 250_000)
        tooLarge.importedRules = [rule("one.mdc", String(repeating: ".", count: 200_000)), rule("two.mdc", String(repeating: ".", count: 200_000))]
        do {
            try await store.save(tooLarge, importRequest: request(store, baseline: imported))
            XCTFail("Settings plus undo must respect the document cap")
        } catch AgentProjectSettingsError.settingsTooLarge {}
        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), before)
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertEqual(restored, AgentProjectSettings())
    }

    func testTamperedUndoWithHiddenOrSensitiveFieldsFailsClosed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        try await store.save(AgentProjectSettings(systemPrompt: "Imported"), importRequest: request(store, baseline: AgentProjectSettings(), fields: [.systemPrompt]))
        let original = try json(store.settingsFileURL)
        for (field, value) in [("preferredModel", "hidden-model"), ("systemPrompt", "token=abcdefghijklmnopqrstuvwxyz0123456789")] {
            var document = original
            var undo = try XCTUnwrap(document["importRollback"] as? [String: Any])
            var previous = try XCTUnwrap(undo["previous"] as? [String: Any])
            previous[field] = value
            undo["previous"] = previous
            document["importRollback"] = undo
            try JSONSerialization.data(withJSONObject: document).write(to: store.settingsFileURL)
            do {
                _ = try await store.loadImportRollback()
                XCTFail("Invalid undo must never reach its preview")
            } catch AgentProjectSettingsError.invalidDocument {}
        }
    }

    func testLegacyDocumentMigratesWhenSavingImport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        let original = AgentProjectSettings(systemPrompt: "Legacy")
        try await store.save(original)
        var legacy = try json(store.settingsFileURL)
        legacy["version"] = 1
        legacy.removeValue(forKey: "importRollback")
        try JSONSerialization.data(withJSONObject: legacy).write(to: store.settingsFileURL)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, original)
        try await store.save(AgentProjectSettings(systemPrompt: "Imported"), importRequest: request(store, baseline: original, fields: [.systemPrompt]))
        XCTAssertEqual(try json(store.settingsFileURL)["version"] as? Int, 2)
        let preview = try await rollback(store)
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertEqual(restored, original)
    }

    func testIndependentStoresSerializeCompetingImportsAgainstSameBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try fixture.store()
        let second = try fixture.store()
        let baseline = AgentProjectSettings(systemPrompt: "Original")
        try await first.save(baseline)
        let sharedRequest = try request(first, baseline: baseline, fields: [.systemPrompt])
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for (store, prompt) in [(first, "First"), (second, "Second")] {
                group.addTask {
                    do {
                        try await store.save(AgentProjectSettings(systemPrompt: prompt), importRequest: sharedRequest)
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let preview = try await rollback(first)
        let restored = try await second.restoreImport(id: preview.id)
        XCTAssertEqual(restored, baseline)
    }

    func testHeldMutationLockRejectsImmediatelyAndPreservesUndoForRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try fixture.store()
        try await store.save(AgentProjectSettings(systemPrompt: "Imported"), importRequest: request(store, baseline: AgentProjectSettings(), fields: [.systemPrompt]))
        let preview = try await rollback(store)
        let before = try Data(contentsOf: store.settingsFileURL)
        let lockPath = store.settingsFileURL.deletingLastPathComponent().appendingPathComponent(".settings.lock").path
        let descriptor = lockPath.withCString { Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        do {
            _ = try await store.restoreImport(id: preview.id)
            XCTFail("A busy writer must fail closed without waiting on its actor executor")
        } catch AgentProjectSettingsError.storageBusy {}
        XCTAssertEqual(try Data(contentsOf: store.settingsFileURL), before)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let restored = try await store.restoreImport(id: preview.id)
        XCTAssertEqual(restored, AgentProjectSettings())
    }

    private func rollback(_ store: AgentProjectSettingsStore) async throws -> AgentProjectImportRollbackPreview {
        let preview = try await store.loadImportRollback()
        return try XCTUnwrap(preview)
    }

    private func request(_ store: AgentProjectSettingsStore, baseline: AgentProjectSettings, fields: Set<AgentProjectImportField> = Set(AgentProjectImportField.allCases)) throws -> AgentProjectImportSaveRequest {
        try AgentProjectImportSaveRequest(identity: store.identity, fields: fields, baseline: baseline)
    }

    private func rule(_ path: String, _ content: String) -> ProjectInstructionImportComponent {
        ProjectInstructionImportComponent(relativePath: path, redactedContent: content, sourceByteCount: content.utf8.count, scope: .files(["Sources/**/*.swift"]))
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func makeFixture() throws -> ImportRollbackFixture {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent("import-rollback-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return ImportRollbackFixture(root: root, workspace: workspace, secrets: ImportRollbackSecrets())
    }
}

private struct ImportRollbackFixture {
    let root: URL
    let workspace: URL
    let secrets: ImportRollbackSecrets
    func store() throws -> AgentProjectSettingsStore {
        try AgentProjectSettingsStore(workspaceRootPath: workspace.path, storageRoot: root.appendingPathComponent("settings"), secretStore: secrets)
    }
}

private final class ImportRollbackSecrets: AgentProjectSecretStore, @unchecked Sendable {
    enum Failure: Error { case injected }
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var shouldFail = false
    private var mutationCount = 0
    var mutations: Int { lock.withLock { mutationCount } }
    func save(_ value: String, account: String) throws {
        try lock.withLock {
            if shouldFail { shouldFail = false; throw Failure.injected }
            values[account] = value
            mutationCount += 1
        }
    }
    func load(account: String) -> String? { lock.withLock { values[account] } }
    func delete(account: String) { lock.withLock { values.removeValue(forKey: account); mutationCount += 1 } }
    func removeAll() { lock.withLock { values.removeAll() } }
    func snapshot() -> [String: String] { lock.withLock { values } }
    func failNextSave() { lock.withLock { shouldFail = true } }
}
