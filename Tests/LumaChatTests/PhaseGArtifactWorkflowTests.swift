import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class PhaseGArtifactWorkflowTests: XCTestCase {
    func testBundledCatalogIsAllowListedAndContainsSevenValidatedSkills() async throws {
        let bundledRoot = Self.repositoryRoot
            .appendingPathComponent("Extensions/Builtin", isDirectory: true)
        let catalog = BundledPluginCatalog(root: bundledRoot)
        XCTAssertThrowsError(try catalog.packageURL(for: "com.example.not-bundled"))

        let package = try catalog.packageURL(
            for: BundledPluginCatalog.artifactWorkflowsID
        )
        XCTAssertEqual(package.lastPathComponent, BundledPluginCatalog.artifactWorkflowsID)
        XCTAssertEqual(
            package.resolvingSymlinksInPath(),
            bundledRoot
                .appendingPathComponent(
                    BundledPluginCatalog.artifactWorkflowsID,
                    isDirectory: true
                )
                .resolvingSymlinksInPath()
        )

        // Non-app development and test binaries use the same source checkout
        // fallback that powers `swift run`.
        XCTAssertEqual(
            try BundledPluginCatalog()
                .packageURL(for: BundledPluginCatalog.artifactWorkflowsID)
                .resolvingSymlinksInPath(),
            package.resolvingSymlinksInPath()
        )

        let testRoot = try Self.makePersistentProjectTemporaryRoot()
        let manager = PluginManager(
            recordsFile: testRoot.appendingPathComponent("plugins.json"),
            installRoot: testRoot.appendingPathComponent("installed", isDirectory: true),
            scratchRoot: testRoot.appendingPathComponent("scratch", isDirectory: true),
            currentLumaChatVersion: "1.4.0",
            bundledPluginRoot: bundledRoot
        )
        _ = try await manager.load()
        let candidate = try await manager.inspectBundledArtifactWorkflows()
        XCTAssertEqual(candidate.manifest.id, BundledPluginCatalog.artifactWorkflowsID)
        XCTAssertEqual(candidate.manifest.skills.count, 7)
        XCTAssertEqual(candidate.source, .localDirectory(path: package.path))
        XCTAssertEqual(
            Set(candidate.manifest.permissions),
            Set([.filesystemRead, .filesystemWrite, .process, .browser])
        )

        do {
            _ = try await manager.install(candidate, grantedPermissions: [.filesystemRead])
            XCTFail("Installing a bundled workflow without its declared permissions must fail")
        } catch let error as ExtensionSubsystemError {
            guard case .permissionNotGranted = error else {
                return XCTFail("Unexpected permission failure: \(error)")
            }
        }

        let installed = try await manager.install(
            candidate,
            grantedPermissions: Set(candidate.manifest.permissions)
        )
        let plugin = try XCTUnwrap(installed.first)
        XCTAssertTrue(plugin.enabled)
        XCTAssertEqual(plugin.grantedPermissions, candidate.manifest.permissions)
        XCTAssertNotEqual(plugin.installPath, package.path)
        for declaration in candidate.manifest.skills {
            let installedSkill = URL(fileURLWithPath: plugin.installPath, isDirectory: true)
                .appendingPathComponent(declaration.path, isDirectory: true)
                .appendingPathComponent("SKILL.md")
            XCTAssertTrue(FileManager.default.fileExists(atPath: installedSkill.path))
        }

        let service = SkillService(
            globalRoot: testRoot.appendingPathComponent("empty-global", isDirectory: true)
        )
        let discovered = try await service.discover(workspace: nil, plugins: installed)
        XCTAssertEqual(
            Set(discovered.map(\.name)),
            Set([
                "artifact-pdf",
                "artifact-document",
                "artifact-spreadsheet",
                "artifact-presentation",
                "artifact-image",
                "artifact-visualization",
                "artifact-site"
            ])
        )
        XCTAssertTrue(discovered.allSatisfy {
            $0.source == .plugin && $0.pluginID == BundledPluginCatalog.artifactWorkflowsID
        })
        let pluginPermissions = Set(candidate.manifest.permissions)
        XCTAssertTrue(discovered.allSatisfy {
            Set($0.permissions).isSubset(of: pluginPermissions)
        })

        let resolved = try await service.resolve(
            request: "Use $artifact-pdf for this deliverable.",
            available: discovered
        )
        XCTAssertEqual(resolved.map(\.descriptor.name), ["artifact-pdf"])
        XCTAssertTrue(resolved[0].instructions.contains("Render every page"))

        let automaticRequests = [
            ("Create a searchable PDF", "artifact-pdf"),
            ("Create a Word DOCX document", "artifact-document"),
            ("Create an Excel XLSX workbook", "artifact-spreadsheet"),
            ("Create a PowerPoint PPTX presentation", "artifact-presentation"),
            ("Make a PNG image", "artifact-image"),
            ("Make a chart visualization", "artifact-visualization"),
            ("Build a responsive website", "artifact-site")
        ]
        for (request, expectedName) in automaticRequests {
            let matches = try await service.resolve(request: request, available: discovered)
            let match = try XCTUnwrap(matches.first, request)
            XCTAssertEqual(match.descriptor.name, expectedName, request)
        }

        let disabled = try await manager.setEnabled(
            false,
            pluginID: BundledPluginCatalog.artifactWorkflowsID
        )
        XCTAssertFalse(try XCTUnwrap(disabled.first).enabled)

        let reloadedManager = PluginManager(
            recordsFile: testRoot.appendingPathComponent("plugins.json"),
            installRoot: testRoot.appendingPathComponent("installed", isDirectory: true),
            scratchRoot: testRoot.appendingPathComponent("scratch", isDirectory: true),
            currentLumaChatVersion: "1.4.0",
            bundledPluginRoot: bundledRoot
        )
        let reloaded = try await reloadedManager.load()
        XCTAssertEqual(reloaded.first?.manifest, candidate.manifest)
        XCTAssertEqual(reloaded.first?.grantedPermissions, candidate.manifest.permissions)
        XCTAssertFalse(reloaded.first?.enabled ?? true)
        let disabledDiscovery = try await service.discover(workspace: nil, plugins: reloaded)
        XCTAssertTrue(disabledDiscovery.isEmpty)

        let permissionRevoked = InstalledPlugin(
            manifest: plugin.manifest,
            source: plugin.source,
            installPath: plugin.installPath,
            enabled: true,
            grantedPermissions: [.filesystemRead],
            installedAt: plugin.installedAt,
            updatedAt: plugin.updatedAt,
            lastError: nil
        )
        let revokedDiscovery = try await service.discover(
            workspace: nil,
            plugins: [permissionRevoked]
        )
        XCTAssertTrue(revokedDiscovery.isEmpty)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    /// Test artifacts intentionally remain under the repository-owned tmp tree.
    /// The project forbids deleting AppleDouble sidecars, so this test uses a
    /// collision-free directory and does not recursively tear it down.
    private static func makePersistentProjectTemporaryRoot() throws -> URL {
        let root = repositoryRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("phase-g-artifact-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
