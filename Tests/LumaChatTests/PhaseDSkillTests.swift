import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class PhaseDSkillTests: XCTestCase {
    func testDiscoveryHonorsScopePrecedenceAndLoadsExplicitSkillOnDemand() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        try writeSkill(
            at: global.appendingPathComponent("release", isDirectory: true),
            name: "release",
            description: "Global release notes helper",
            body: "GLOBAL INSTRUCTIONS"
        )
        try writeSkill(
            at: workspaceRoot.appendingPathComponent(
                ".lumachat/skills/release",
                isDirectory: true
            ),
            name: "release",
            description: "Project release notes helper",
            permissions: [.filesystemRead],
            body: "PROJECT INSTRUCTIONS"
        )
        try writeSkill(
            at: workspaceRoot.appendingPathComponent(
                "packages/editor/review-helper",
                isDirectory: true
            ),
            name: "review-helper",
            description: "Review source changes and security findings",
            body: "NESTED REVIEW INSTRUCTIONS"
        )

        let service = SkillService(globalRoot: global)
        let workspace = AgentWorkspace(
            name: "Skill Workspace",
            rootPath: workspaceRoot.path,
            allowedPaths: [workspaceRoot.path],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let discovered = try await service.discover(workspace: workspace, plugins: [])

        XCTAssertEqual(discovered.filter { $0.name == "release" }.count, 2)
        XCTAssertTrue(discovered.contains { $0.name == "release" && $0.source == .global })
        XCTAssertTrue(discovered.contains { $0.name == "release" && $0.source == .project })
        XCTAssertTrue(discovered.contains { $0.name == "review-helper" && $0.source == .nested })

        let explicitlyLoaded = try await service.resolve(
            request: "Please use $release for this build.",
            available: discovered
        )
        XCTAssertEqual(explicitlyLoaded.count, 1)
        XCTAssertEqual(explicitlyLoaded[0].descriptor.source, .project)
        XCTAssertEqual(explicitlyLoaded[0].descriptor.permissions, [.filesystemRead])
        XCTAssertTrue(explicitlyLoaded[0].instructions.contains("PROJECT INSTRUCTIONS"))
        XCTAssertFalse(explicitlyLoaded[0].instructions.contains("GLOBAL INSTRUCTIONS"))

        let automaticallyLoaded = try await service.resolve(
            request: "Review source changes and security findings before shipping.",
            available: discovered
        )
        XCTAssertEqual(automaticallyLoaded.map(\.descriptor.name), ["review-helper"])
    }

    func testPluginSkillAndResourceDirectoriesAreDescribedWithoutExecutingScripts() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("plugin", isDirectory: true)
        let skillRoot = package.appendingPathComponent("skills/release", isDirectory: true)
        try writeSkill(
            at: skillRoot,
            name: "plugin-release",
            description: "Build signed release artifacts",
            permissions: [.filesystemRead, .process],
            body: "Follow the release checklist."
        )
        for directory in ["references", "scripts", "templates", "assets"] {
            try FileManager.default.createDirectory(
                at: skillRoot.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let manifest = PluginManifest(
            id: "com.example.release",
            name: "Release Tools",
            version: "1.0.0",
            author: "Example",
            description: "Release helpers",
            permissions: [.filesystemRead, .process],
            skills: [PluginSkillDeclaration(path: "skills/release")]
        )
        let plugin = InstalledPlugin(
            manifest: manifest,
            source: .localDirectory(path: package.path),
            installPath: package.path,
            enabled: true,
            grantedPermissions: [.filesystemRead, .process],
            installedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastError: nil
        )
        let service = SkillService(globalRoot: root.appendingPathComponent("empty-global"))
        let discovered = try await service.discover(workspace: nil, plugins: [plugin])
        let descriptor = try XCTUnwrap(discovered.first)
        XCTAssertEqual(descriptor.pluginID, plugin.id)
        XCTAssertEqual(descriptor.source, .plugin)
        XCTAssertTrue(descriptor.hasReferences)
        XCTAssertTrue(descriptor.hasScripts)
        XCTAssertTrue(descriptor.hasTemplates)
        XCTAssertTrue(descriptor.hasAssets)

        let pluginResolution = try await service.resolve(
            request: "$plugin-release",
            available: discovered
        )
        let loaded = try XCTUnwrap(pluginResolution.first)
        XCTAssertTrue(loaded.instructions.contains("references/"))
        XCTAssertTrue(loaded.instructions.contains("Scripts never execute automatically"))
    }

    func testResourceReadRequiresLoadedSkillAndRejectsTraversalAndSymlinkEscape() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)
        let skillRoot = global.appendingPathComponent("docs", isDirectory: true)
        try writeSkill(
            at: skillRoot,
            name: "docs",
            description: "Read project documentation references",
            body: "Read only the referenced material."
        )
        let references = skillRoot.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try Data("trusted reference".utf8).write(
            to: references.appendingPathComponent("guide.md")
        )
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: references.appendingPathComponent("escape.md"),
            withDestinationURL: outside
        )

        let service = SkillService(globalRoot: global)
        let discovered = try await service.discover(workspace: nil, plugins: [])
        let descriptor = try XCTUnwrap(discovered.first)
        let allowed: Set<String> = [descriptor.id]
        let trustedResource = try await service.readResource(
            skillID: descriptor.id,
            relativePath: "references/guide.md",
            allowedSkillIDs: allowed
        )
        XCTAssertEqual(trustedResource, "trusted reference")

        await assertAsyncThrows {
            _ = try await service.readResource(
                skillID: descriptor.id,
                relativePath: "../outside.txt",
                allowedSkillIDs: allowed
            )
        }
        await assertAsyncThrows {
            _ = try await service.readResource(
                skillID: descriptor.id,
                relativePath: "references/escape.md",
                allowedSkillIDs: allowed
            )
        }
        await assertAsyncThrows {
            _ = try await service.readResource(
                skillID: descriptor.id,
                relativePath: "references/guide.md",
                allowedSkillIDs: []
            )
        }
    }

    func testSkillResourceToolIsHiddenUntilHostSuppliesExactLoadedID() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)
        let skillRoot = global.appendingPathComponent("docs", isDirectory: true)
        try writeSkill(
            at: skillRoot,
            name: "docs",
            description: "Read project documentation references",
            body: "Use bounded references."
        )
        try FileManager.default.createDirectory(
            at: skillRoot.appendingPathComponent("references", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("resource body".utf8).write(
            to: skillRoot.appendingPathComponent("references/readme.md")
        )
        let service = SkillService(globalRoot: global)
        let discovered = try await service.discover(workspace: nil, plugins: [])
        let descriptor = try XCTUnwrap(discovered.first)
        let registry = ToolRegistry()
        try await registry.register(SkillToolFactory.makeTools(service: service))
        let workspace = AgentWorkspace(
            name: "Skill Tool",
            rootPath: root.path,
            allowedPaths: [root.path],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let hiddenContext = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: workspace,
            temporaryRoot: root
        )
        let hiddenDefinitions = await registry.definitions(for: .agent, context: hiddenContext)
        XCTAssertFalse(hiddenDefinitions.contains { $0.name == "skill_read_resource" })

        var loadedContext = hiddenContext
        loadedContext.loadedSkillIDs = [descriptor.id]
        let loadedDefinitions = await registry.definitions(for: .agent, context: loadedContext)
        XCTAssertTrue(loadedDefinitions.contains { $0.name == "skill_read_resource" })
        let result = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(
                name: "skill_read_resource",
                arguments: .object([
                    "skill_id": .string(descriptor.id),
                    "path": .string("references/readme.md")
                ])
            ),
            context: loadedContext,
            permissionMode: .autoApproveSafe,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "resource body")

        var wrongContext = hiddenContext
        wrongContext.loadedSkillIDs = ["different-skill"]
        let rejected = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(
                name: "skill_read_resource",
                arguments: .object([
                    "skill_id": .string(descriptor.id),
                    "path": .string("references/readme.md")
                ])
            ),
            context: wrongContext,
            permissionMode: .autoApproveSafe,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(rejected.isError)
        XCTAssertFalse(rejected.content.contains("resource body"))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-d-skill-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(
        at root: URL,
        name: String,
        description: String,
        permissions: [ExtensionPermission] = [],
        body: String
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rawPermissions = permissions.map(\.rawValue).joined(separator: ", ")
        let text = """
        ---
        name: \(name)
        description: \(description)
        usage: Use when the request matches \(name)
        permissions: [\(rawPermissions)]
        ---
        \(body)
        """
        try Data(text.utf8).write(to: root.appendingPathComponent("SKILL.md"))
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
