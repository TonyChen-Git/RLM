import Foundation
import XCTest
@testable import LumaChat

final class ConversationCleanupTests: XCTestCase {
    private func resetStorage() throws {
        setenv("LUMACHAT_APP_SUPPORT_PATH", "/Volumes/SD/Code/RLM/tmp/test-app-support", 1)
        try? FileManager.default.removeItem(at: AppPaths.appSupport)
        try AppPaths.ensureDirectories()
    }

    func testDeleteRemovesConversationJSONAttachmentsAndTempFiles() async throws {
        try resetStorage()
        defer { try? FileManager.default.removeItem(at: AppPaths.appSupport) }

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
        let store = ConversationStore()
        try await store.save(conversation)

        let attachmentDirectory = AppPaths.attachmentsDirectory(conversationID)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachmentDirectory.appendingPathComponent(storedName))
        try Data([4]).write(to: attachmentDirectory.appendingPathComponent(".temporary-interrupted"))

        try await store.delete(id: conversationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppPaths.conversationDirectory(conversationID).path))
    }

    func testDeleteAllAlsoRemovesCorruptAndUnknownEntries() async throws {
        try resetStorage()
        defer { try? FileManager.default.removeItem(at: AppPaths.appSupport) }

        let corrupt = AppPaths.conversations.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unknown = AppPaths.conversations.appendingPathComponent("leftover-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: corrupt.appendingPathComponent("conversation.json"))
        try Data([1]).write(to: unknown.appendingPathComponent("garbage.bin"))

        try await ConversationStore().deleteAll()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: AppPaths.conversations.path)
        XCTAssertTrue(remaining.isEmpty)
    }
}
