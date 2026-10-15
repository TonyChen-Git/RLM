import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class ProjectInstructionImporterTests: XCTestCase {
    private let importer = ProjectInstructionImporter()

    func testPreviewsBothRootInstructionFormatsWithoutChangingSources() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let claude = fixture.workspace.appendingPathComponent("CLAUDE.md")
        let cursor = fixture.workspace.appendingPathComponent(".cursorrules")
        let claudeText = "Use Swift.\n@docs/private.md\n`@docs/missing.md`\ntoken=super-secret-value\n"
        let cursorText = "Keep tests focused.\n"
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("docs"),
            withIntermediateDirectories: false
        )
        try Data("Use focused fixtures.\n".utf8).write(
            to: fixture.workspace.appendingPathComponent("docs/private.md")
        )
        try Data(claudeText.utf8).write(to: claude)
        try Data(cursorText.utf8).write(to: cursor)
        let originalClaude = try Data(contentsOf: claude)
        let originalCursor = try Data(contentsOf: cursor)

        let first = try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )
        let second = try importer.preview(
            source: .cursorLegacy,
            workspaceRootPath: fixture.workspace.path
        )

        XCTAssertEqual(first.source, .claudeCode)
        XCTAssertEqual(first.sourcePath, claude.path)
        XCTAssertEqual(first.sourceByteCount, originalClaude.count + "Use focused fixtures.\n".utf8.count)
        XCTAssertTrue(first.redactedContent.contains("@docs/private.md"))
        XCTAssertTrue(first.redactedContent.contains("Use focused fixtures."))
        XCTAssertEqual(first.components.map(\.relativePath), ["CLAUDE.md", "docs/private.md"])
        XCTAssertFalse(first.redactedContent.contains("super-secret-value"))
        XCTAssertEqual(second.source, .cursorLegacy)
        XCTAssertEqual(second.sourcePath, cursor.path)
        XCTAssertEqual(second.redactedContent, cursorText)
        XCTAssertEqual(try Data(contentsOf: claude), originalClaude)
        XCTAssertEqual(try Data(contentsOf: cursor), originalCursor)
    }

    func testMissingSymlinkDirectoryAndHardLinkFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let source = fixture.workspace.appendingPathComponent("CLAUDE.md")
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .missingSource) }

        let outside = fixture.container.appendingPathComponent("outside.md")
        try Data("Outside instructions".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .unsafeSource) }
        try FileManager.default.removeItem(at: source)

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .unsafeSource) }
        try FileManager.default.removeItem(at: source)

        try FileManager.default.linkItem(at: outside, to: source)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .unsafeSource) }
    }

    func testRejectsInvalidTextEmptyFileAndOversizedFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let source = fixture.workspace.appendingPathComponent("CLAUDE.md")

        try Data([0xFF, 0xFE]).write(to: source)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .invalidText) }

        try Data("Use Swift\0Never run tests".utf8).write(to: source)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .invalidText) }

        try Data(" \n\t".utf8).write(to: source)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .emptySource) }

        try Data(repeating: 0x41, count: ProjectInstructionImporter.maximumSourceBytes + 1)
            .write(to: source)
        XCTAssertThrowsError(try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )) { XCTAssertEqual($0 as? ProjectInstructionImportError, .sourceTooLarge) }
    }

    func testPreviewIsBoundToCanonicalWorkspaceAndDirectoryInstance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let other = fixture.container.appendingPathComponent("other", isDirectory: true)
        let child = fixture.workspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data("Use Swift".utf8).write(
            to: fixture.workspace.appendingPathComponent("CLAUDE.md")
        )
        let preview = try importer.preview(
            source: .claudeCode,
            workspaceRootPath: fixture.workspace.path
        )

        XCTAssertTrue(preview.belongs(toWorkspaceRootPath: child.appendingPathComponent("..").path))
        XCTAssertFalse(preview.belongs(toWorkspaceRootPath: other.path))
        XCTAssertFalse(preview.belongs(toWorkspaceRootPath: "relative/path"))

        let moved = fixture.container.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.workspace, to: moved)
        try FileManager.default.createDirectory(at: fixture.workspace, withIntermediateDirectories: false)
        XCTAssertFalse(preview.belongs(toWorkspaceRootPath: fixture.workspace.path))
    }

    func testClaudeReferencesRejectCyclesTraversalAndSymlinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let root = fixture.workspace.appendingPathComponent("CLAUDE.md")
        let nested = fixture.workspace.appendingPathComponent("nested.md")
        try Data("@nested.md\n".utf8).write(to: root)
        try Data("@CLAUDE.md\n".utf8).write(to: nested)
        XCTAssertThrowsError(try importer.preview(source: .claudeCode,
                                                  workspaceRootPath: fixture.workspace.path)) {
            XCTAssertEqual($0 as? ProjectInstructionImportError, .referenceCycle)
        }

        try Data("@../outside.md\n".utf8).write(to: root)
        XCTAssertThrowsError(try importer.preview(source: .claudeCode,
                                                  workspaceRootPath: fixture.workspace.path)) {
            XCTAssertEqual($0 as? ProjectInstructionImportError, .unsafeReference)
        }

        try Data("@nested.md\n".utf8).write(to: root)
        try FileManager.default.removeItem(at: nested)
        let outside = fixture.container.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        XCTAssertThrowsError(try importer.preview(source: .claudeCode,
                                                  workspaceRootPath: fixture.workspace.path)) {
            XCTAssertEqual($0 as? ProjectInstructionImportError, .unsafeSource)
        }
    }

    func testCursorMDCParsesScopeWithoutPromotingScopedRules() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let rules = fixture.workspace.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try Data("---\nalwaysApply: true\n---\nAlways test.\n".utf8)
            .write(to: rules.appendingPathComponent("always.mdc"))
        try Data("---\ndescription: Swift style\nglobs: [Sources/**/*.swift, Tests/*.swift]\nalwaysApply: false\n---\nUse Swift style.\n".utf8)
            .write(to: rules.appendingPathComponent("swift.mdc"))

        let preview = try importer.preview(source: .cursorRules,
                                           workspaceRootPath: fixture.workspace.path)
        XCTAssertEqual(preview.components.count, 2)
        XCTAssertEqual(preview.components[0].scope, .always)
        XCTAssertEqual(preview.components[1].scope,
                       .files(["Sources/**/*.swift", "Tests/*.swift"]))
        XCTAssertTrue(preview.redactedContent.contains("Always test."))
        XCTAssertFalse(preview.redactedContent.contains("Use Swift style."))
        XCTAssertEqual(preview.components[1].redactedContent, "Use Swift style.")
    }

    func testProjectConfigurationPreviewsOnlySafeFields() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let claude = fixture.workspace.appendingPathComponent(".claude")
        let cursor = fixture.workspace.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
        try Data(#"{"model":"selected-model","env":{"API_TOKEN":"secret-value"},"hooks":{"PostToolUse":[]}}"#.utf8)
            .write(to: claude.appendingPathComponent("settings.json"))
        try Data(#"{"mcpServers":{"local-files":{"command":"dangerous-hook","env":{"TOKEN":"secret-value"}}}}"#.utf8)
            .write(to: cursor.appendingPathComponent("mcp.json"))

        let settings = try importer.preview(source: .claudeSettings,
                                            workspaceRootPath: fixture.workspace.path)
        XCTAssertEqual(settings.configuration?.modelSuggestion, "selected-model")
        XCTAssertEqual(settings.configuration?.topLevelKeys, ["env", "hooks", "model"])
        XCTAssertFalse(settings.redactedContent.contains("secret-value"))
        XCTAssertFalse(settings.redactedContent.contains("PostToolUse"))
        let mcp = try importer.preview(source: .cursorMCP,
                                       workspaceRootPath: fixture.workspace.path)
        XCTAssertEqual(mcp.configuration?.mcpServerNames, ["local-files"])
        XCTAssertNil(mcp.configuration?.modelSuggestion)
        XCTAssertFalse(mcp.redactedContent.contains("dangerous-hook"))
    }

    func testSourceDigestDetectsChangeHiddenByRedaction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let source = fixture.workspace.appendingPathComponent("CLAUDE.md")
        try Data("Use tests. token=secret-one\n".utf8).write(to: source)
        let first = try importer.preview(source: .claudeCode,
                                         workspaceRootPath: fixture.workspace.path)
        try Data("Use tests. token=secret-two\n".utf8).write(to: source)
        let second = try importer.preview(source: .claudeCode,
                                          workspaceRootPath: fixture.workspace.path)
        XCTAssertEqual(first.redactedContent, second.redactedContent)
        XCTAssertEqual(first.sourceByteCount, second.sourceByteCount)
        XCTAssertNotEqual(first.components, second.components)
    }

    private func makeFixture() throws -> (container: URL, workspace: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-instruction-import-\(UUID().uuidString)", isDirectory: true)
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (container, workspace)
    }
}
