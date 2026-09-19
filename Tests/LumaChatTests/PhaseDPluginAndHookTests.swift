import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class PhaseDPluginAndHookTests: XCTestCase {
    func testLifecycleEventVocabularyAndLegacyManifestDefaultsAreClosed() throws {
        XCTAssertEqual(
            Set(LifecycleHookEvent.allCases.map(\.rawValue)),
            Set([
                "SessionStart", "SessionEnd", "PreModel", "PostModel",
                "PreTool", "PostTool", "PermissionRequest", "PermissionDecision",
                "PreCommit", "PostCommit", "SubagentStart", "SubagentEnd",
                "TaskStart", "TaskPause", "TaskResume", "TaskComplete",
                "HandoffStart", "HandoffComplete"
            ])
        )
        let minimal = Data(
            #"{"id":"com.example.minimal","name":"Minimal","version":"1","description":"Legacy manifest"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: minimal)
        XCTAssertEqual(decoded.author, "Unknown")
        XCTAssertTrue(decoded.permissions.isEmpty)
        XCTAssertTrue(decoded.skills.isEmpty)
        XCTAssertTrue(decoded.mcpServers.isEmpty)
        XCTAssertTrue(decoded.tools.isEmpty)
        XCTAssertTrue(decoded.commands.isEmpty)
        XCTAssertTrue(decoded.hooks.isEmpty)
        XCTAssertTrue(decoded.assets.isEmpty)
    }

    func testInspectInstallUpdateDisableReloadAndUninstallUseAtomicRecords() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let installRoot = root.appendingPathComponent("installed", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let records = root.appendingPathComponent("state/plugins.json")
        try writePackage(
            at: source,
            manifest: basicManifest(version: "1.0.0")
        )
        let manager = PluginManager(
            recordsFile: records,
            installRoot: installRoot,
            scratchRoot: scratch
        )

        let candidate = try await manager.inspect(
            source: .localDirectory(path: source.path)
        )
        XCTAssertEqual(candidate.manifest.id, "com.example.phase-d")
        await assertAsyncThrows {
            _ = try await manager.install(candidate, grantedPermissions: [])
        }

        let installed = try await manager.install(
            candidate,
            grantedPermissions: [.filesystemRead]
        )
        let original = try XCTUnwrap(installed.first)
        XCTAssertTrue(original.enabled)
        XCTAssertEqual(original.grantedPermissions, [.filesystemRead])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.installPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: records.path))

        let disabled = try await manager.setEnabled(false, pluginID: original.id)
        XCTAssertEqual(disabled.first?.enabled, false)

        try writePackage(
            at: source,
            manifest: basicManifest(version: "1.1.0")
        )
        let update = try await manager.inspect(source: .localDirectory(path: source.path))
        let updated = try await manager.install(
            update,
            grantedPermissions: [.filesystemRead]
        )
        XCTAssertEqual(updated.first?.manifest.version, "1.1.0")
        XCTAssertEqual(updated.first?.enabled, false)
        XCTAssertEqual(updated.first?.installedAt, original.installedAt)

        let reloadedManager = PluginManager(
            recordsFile: records,
            installRoot: installRoot,
            scratchRoot: scratch
        )
        let reloaded = try await reloadedManager.load()
        XCTAssertEqual(reloaded.first?.manifest.version, "1.1.0")
        XCTAssertEqual(reloaded.first?.enabled, false)

        let remaining = try await reloadedManager.uninstall(pluginID: original.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.installPath))
        let afterUninstall = try await reloadedManager.load()
        XCTAssertTrue(afterUninstall.isEmpty)
    }

    func testManifestValidationRejectsTraversalSymlinkAndMissingProcessPermission() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(
            recordsFile: root.appendingPathComponent("state/plugins.json"),
            installRoot: root.appendingPathComponent("installed", isDirectory: true),
            scratchRoot: root.appendingPathComponent("scratch", isDirectory: true)
        )

        let traversal = root.appendingPathComponent("traversal", isDirectory: true)
        var traversalManifest = basicManifest()
        traversalManifest.assets = ["../outside.txt"]
        try writePackage(at: traversal, manifest: traversalManifest)
        await assertAsyncThrows {
            _ = try await manager.inspect(source: .localDirectory(path: traversal.path))
        }

        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try writePackage(at: linked, manifest: basicManifest())
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        await assertAsyncThrows {
            _ = try await manager.inspect(source: .localDirectory(path: linked.path))
        }

        let missingPermission = root.appendingPathComponent(
            "missing-process",
            isDirectory: true
        )
        let invalidManifest = PluginManifest(
            id: "com.example.no-process",
            name: "Unsafe Tool",
            version: "1.0.0",
            author: "Example",
            description: "Declares a process without process permission",
            tools: [
                PluginToolDeclaration(
                    name: "run",
                    description: "Run helper",
                    executable: "helper.sh"
                )
            ]
        )
        try writePackage(
            at: missingPermission,
            manifest: invalidManifest,
            files: ["helper.sh": "#!/bin/sh\nexit 0\n"]
        )
        await assertAsyncThrows {
            _ = try await manager.inspect(
                source: .localDirectory(path: missingPermission.path)
            )
        }
        await assertAsyncThrows {
            _ = try await manager.inspect(
                source: .manifest(url: URL(string: "http://plugins.example.test/plugin.json")!)
            )
        }
    }

    func testMinimumLumaChatVersionIsEnforcedDuringInspection() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("future", isDirectory: true)
        var manifest = basicManifest()
        manifest.minimumLumaChatVersion = "2.0.0"
        try writePackage(at: source, manifest: manifest)
        let manager = PluginManager(
            recordsFile: root.appendingPathComponent("state/plugins.json"),
            installRoot: root.appendingPathComponent("installed", isDirectory: true),
            scratchRoot: root.appendingPathComponent("scratch", isDirectory: true),
            currentLumaChatVersion: "1.4.0"
        )

        await assertAsyncThrows {
            _ = try await manager.inspect(source: .localDirectory(path: source.path))
        }
    }

    func testHookSchemaIsHostOnlyAndExecutionUsesPermissionRedactionAndFailurePolicy() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        #!/bin/sh
        printf 'access_token=phase-d-super-secret-123456\\n'
        exit 7
        """
        let scriptURL = root.appendingPathComponent("hook.sh")
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )
        let manifest = PluginManifest(
            id: "com.example.hooks",
            name: "Lifecycle Audit",
            version: "1.0.0",
            author: "Example",
            description: "Lifecycle hook fixture",
            permissions: [.process],
            tools: [
                PluginToolDeclaration(
                    name: "visible_tool",
                    description: "A normal model-visible plugin tool",
                    executable: "hook.sh"
                )
            ],
            hooks: [
                PluginHookDeclaration(
                    event: .preModel,
                    executable: "hook.sh",
                    timeoutSeconds: 2,
                    failurePolicy: .disablePlugin
                )
            ]
        )
        let plugin = InstalledPlugin(
            manifest: manifest,
            source: .localDirectory(path: root.path),
            installPath: root.path,
            enabled: true,
            grantedPermissions: [.process],
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastError: nil
        )
        let registry = ToolRegistry()
        try await registry.register(PluginRuntimeFactory.makeTools(plugins: [plugin]))
        let binding = try XCTUnwrap(
            PluginRuntimeFactory.hookBindings(plugins: [plugin]).first
        )
        XCTAssertEqual(binding.event, .preModel)
        XCTAssertEqual(binding.failurePolicy, .disablePlugin)

        let sessionID = UUID()
        let workspace = AgentWorkspace(
            name: "Hook Workspace",
            rootPath: root.path,
            allowedPaths: [root.path],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let normalContext = AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: workspace,
            temporaryRoot: root,
            commandTimeout: 3
        )
        let normalDefinitions = await registry.definitions(for: .agent, context: normalContext)
        XCTAssertTrue(normalDefinitions.contains { $0.name.contains("visible_tool") })
        XCTAssertFalse(normalDefinitions.contains { $0.name == binding.toolName })

        let fabricated = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: binding.toolName, arguments: .emptyObject),
            context: normalContext,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(fabricated.isError)

        var hookContext = normalContext
        hookContext.lifecycleHookInvocation = LifecycleHookInvocation(
            pluginID: plugin.id,
            hookIndex: binding.hookIndex,
            event: binding.event,
            sessionID: sessionID,
            workspaceRoot: root.path,
            detail: "model boundary"
        )
        let hookDefinitions = await registry.definitions(for: .agent, context: hookContext)
        XCTAssertTrue(hookDefinitions.contains { $0.name == binding.toolName })

        let automaticallyAuthorized = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: binding.toolName, arguments: .emptyObject),
            context: hookContext,
            permissionMode: .askEveryTime,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(automaticallyAuthorized.isError)
        XCTAssertFalse(automaticallyAuthorized.content.contains("phase-d-super-secret-123456"))
        XCTAssertTrue(automaticallyAuthorized.content.contains("[REDACTED]"))

        let executed = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: binding.toolName, arguments: .emptyObject),
            context: hookContext,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(executed.isError)
        XCTAssertFalse(executed.content.contains("phase-d-super-secret-123456"))
        XCTAssertTrue(executed.content.contains("[REDACTED]"))
        XCTAssertEqual(executed.data?["exit_code"]?.intValue, 7)

        let historyURL = root.appendingPathComponent("hook-history/history.json")
        let history = LifecycleHookLogStore(fileURL: historyURL)
        _ = try await history.append(
            LifecycleHookResult(
                pluginID: plugin.id,
                event: binding.event,
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 11),
                succeeded: false,
                output: executed.content,
                failurePolicy: binding.failurePolicy
            )
        )
        let restored = try await LifecycleHookLogStore(fileURL: historyURL).load()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].failurePolicy, .disablePlugin)
        let persisted = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("phase-d-super-secret-123456"))
        XCTAssertTrue(persisted.contains("[REDACTED]"))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-d-plugin-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func basicManifest(version: String = "1.0.0") -> PluginManifest {
        PluginManifest(
            id: "com.example.phase-d",
            name: "Phase D Fixture",
            version: version,
            author: "LumaChat Tests",
            description: "A local plugin fixture",
            permissions: [.filesystemRead],
            assets: ["README.md"]
        )
    }

    private func writePackage(
        at root: URL,
        manifest: PluginManifest,
        files: [String: String] = [:]
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: root.appendingPathComponent("plugin.json"))
        try Data("fixture".utf8).write(to: root.appendingPathComponent("README.md"))
        for (relativePath, contents) in files {
            let file = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
