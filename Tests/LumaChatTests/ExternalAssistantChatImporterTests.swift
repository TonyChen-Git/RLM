import Foundation
import XCTest
@testable import LumaChat

final class ExternalAssistantChatImporterTests: XCTestCase {
    private let importer = ExternalAssistantChatImporter()

    func testClaudeJSONLImportsOnlyRedactedUserAndAssistantText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("claude-session.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Please review src/main.swift token=super-secret-value and ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"Looks good."}]}}"#,
            #"{"type":"tool","message":{"role":"tool","content":"tool output"}}"#
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: source)

        let preview = try importer.preview(source: .claudeCodeJSONL, url: source)
        XCTAssertEqual(preview.messages.map(\.role), [.user, .assistant])
        XCTAssertFalse(preview.messages[0].content.contains("super-secret-value"))
        XCTAssertFalse(preview.messages[0].content.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"))
        XCTAssertFalse(preview.messages.map(\.content).joined().contains("private reasoning"))
        XCTAssertEqual(preview.messages[1].content, "Looks good.")
        XCTAssertTrue(preview.sourceDigest.hasPrefix("claudeCodeJSONL:"))
        try importer.verifyUnchanged(preview)

        try Data((lines + "\n" + lines).utf8).write(to: source)
        XCTAssertThrowsError(try importer.verifyUnchanged(preview)) {
            XCTAssertEqual($0 as? ExternalAssistantChatImportError, .sourceChanged)
        }
    }

    func testCursorMarkdownPreservesCodeFenceHeadings() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("cursor-chat.md")
        let markdown = """
        # Chat export
        ## User
        How should I test this?
        ```md
        ## Assistant
        This is quoted code.
        ```
        ## Assistant
        Run the focused test.
        """
        try Data(markdown.utf8).write(to: source)
        let preview = try importer.preview(source: .cursorMarkdown, url: source)
        XCTAssertEqual(preview.messages.count, 2)
        XCTAssertTrue(preview.messages[0].content.contains("This is quoted code."))
        XCTAssertEqual(preview.messages[1].content, "Run the focused test.")
    }

    func testUnsafeAndUnsupportedChatsFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("chat.jsonl")
        try Data("not json".utf8).write(to: source)
        XCTAssertThrowsError(try importer.preview(source: .claudeCodeJSONL, url: source)) {
            XCTAssertEqual($0 as? ExternalAssistantChatImportError, .unsupportedFormat)
        }
        let link = fixture.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try importer.preview(source: .claudeCodeJSONL, url: link)) {
            XCTAssertEqual($0 as? ExternalAssistantChatImportError, .unsafeFile)
        }
        try Data(repeating: 0x41, count: ExternalAssistantChatImporter.maximumSourceBytes + 1)
            .write(to: source)
        XCTAssertThrowsError(try importer.preview(source: .claudeCodeJSONL, url: source)) {
            XCTAssertEqual($0 as? ExternalAssistantChatImportError, .oversized)
        }
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-chat-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
