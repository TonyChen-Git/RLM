import XCTest
@testable import LumaChat

final class ModelMigrationTests: XCTestCase {
    func testOldSettingsDecodeWithNewProfileDefaults() throws {
        let data = Data(#"""
        {
          "provider": "ollama",
          "endpoint": "http://localhost:11434",
          "selectedModel": "qwen2.5",
          "contextLength": 8192,
          "temperature": 0.7,
          "systemPrompt": "test",
          "requestTimeout": 300
        }
        """#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.selectedModel, "qwen2.5")
        XCTAssertTrue(settings.connectionProfiles.isEmpty)
        XCTAssertNil(settings.activeProfileID)
    }

    func testOldConversationAndMessageDecodeWithoutReasoningOrProject() throws {
        let id = UUID()
        let messageID = UUID()
        let json = #"""
        {
          "id":"\#(id.uuidString)",
          "title":"old",
          "messages":[{
            "id":"\#(messageID.uuidString)",
            "role":"assistant",
            "content":"hello",
            "attachments":[],
            "createdAt":0,
            "isError":false
          }],
          "createdAt":0,
          "updatedAt":0,
          "model":"old-model",
          "provider":"ollama",
          "endpoint":"http://localhost:11434"
        }
        """#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))

        XCTAssertEqual(conversation.messages.first?.content, "hello")
        XCTAssertNil(conversation.messages.first?.reasoning)
        XCTAssertNil(conversation.project)
        XCTAssertNil(conversation.profileID)
    }
}
