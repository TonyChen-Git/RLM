import Foundation
import XCTest
@testable import LumaChat

final class ConversationCleanupTests: XCTestCase {
    private func makeFixtureDirectory() throws -> URL {
        let directory = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "conversation-cleanup-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testDeleteRemovesConversationJSONAttachmentsAndTempFiles() async throws {
        let directory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let conversationID = UUID()
        let storedName = "attachment.bin"
        let attachment = ChatAttachment(
            name: storedName,
            relativePath: "Attachments/\(storedName)",
            mimeType: "application/octet-stream",
            kind: .file,
            byteCount: 3
        )
        let message = ChatMessage(role: .user, content: "file", attachments: [attachment])
        let conversation = Conversation(id: conversationID, messages: [message])
        let store = ConversationStore(conversationsDirectory: directory)
        try await store.save(conversation)

        let conversationDirectory = directory.appendingPathComponent(conversationID.uuidString)
        let attachmentDirectory = conversationDirectory.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachmentDirectory.appendingPathComponent(storedName))
        try Data([4]).write(to: attachmentDirectory.appendingPathComponent(".temporary-interrupted"))

        try await store.delete(id: conversationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: conversationDirectory.path))
    }

    func testDeleteAllAlsoRemovesCorruptAndUnknownEntries() async throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("conversations", isDirectory: true)
        let otherDirectory = fixture.appendingPathComponent("other-conversations", isDirectory: true)
        let otherStore = ConversationStore(conversationsDirectory: otherDirectory)
        let otherConversation = Conversation(id: UUID(), messages: [])
        try await otherStore.save(otherConversation)

        let corrupt = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unknown = directory.appendingPathComponent("leftover-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corrupt.appendingPathComponent("conversation.json"))
        try Data([1]).write(to: unknown.appendingPathComponent("garbage.bin"))

        try await ConversationStore(conversationsDirectory: directory).deleteAll()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty)
        let retained = try await otherStore.loadConversation(id: otherConversation.id)
        XCTAssertEqual(retained?.id, otherConversation.id)
    }
}
