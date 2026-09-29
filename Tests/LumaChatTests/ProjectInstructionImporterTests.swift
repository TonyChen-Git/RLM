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
        let claudeText = "Use Swift.\n@docs/private.md\ntoken=super-secret-value\n"
        let cursorText = "Keep tests focused.\n"
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
        XCTAssertEqual(first.sourceByteCount, originalClaude.count)
        XCTAssertTrue(first.redactedContent.contains("@docs/private.md"))
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

    private func makeFixture() throws -> (container: URL, workspace: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-instruction-import-\(UUID().uuidString)", isDirectory: true)
        let workspace = container.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (container, workspace)
    }
}
