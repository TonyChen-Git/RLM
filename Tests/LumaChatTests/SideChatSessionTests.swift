import XCTest
@testable import LumaChat

private struct SideChatRequest: Sendable {
    let messages: [ChatMessage]
    let settings: AppSettings
    let apiKey: String?
}

private actor SideChatRequestRecorder {
    private var recorded: [SideChatRequest] = []

    func record(_ request: SideChatRequest) { recorded.append(request) }
    func requests() -> [SideChatRequest] { recorded }
}

private struct SideChatTestStreamer: SideChatStreaming {
    let recorder: SideChatRequestRecorder
    var response: [LLMStreamDelta] = [.content("Side answer")]

    func stream(
        messages: [ChatMessage],
        settings: AppSettings,
        apiKey: String?
    ) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(
                    SideChatRequest(messages: messages, settings: settings, apiKey: apiKey)
                )
                for delta in response { continuation.yield(delta) }
                continuation.finish()
            }
        }
    }
}

final class SideChatSessionTests: XCTestCase {
    @MainActor
    func testTranscriptIsSeparateAndUsesFrozenParentRouteWithoutToolContent() async {
        var parent = AgentSession(mode: .agent)
        parent.title = "Parent coding task password=old-title-secret"
        parent.state = .running
        parent.model = "parent-model"
        parent.provider = .openAICompatible
        parent.messages = [
            AgentMessage(
                role: .user,
                content: "Explain the change. Authorization: Bearer old-message-secret"
            ),
            AgentMessage(
                role: .user,
                content: "Use api_key=old-api-key and https://name:url-password@example.test"
            ),
            AgentMessage(
                role: .assistant,
                content: "I will inspect the repository",
                reasoningSummary: "private reasoning"
            ),
            AgentMessage(role: .tool, content: "secret tool output"),
            AgentMessage(
                role: .assistant,
                content: "Calling a tool",
                toolCalls: [AgentToolCall(name: "read_file")]
            )
        ]
        let originalMessages = parent.messages
        let route = AppSettings(
            provider: .openAICompatible,
            endpoint: "https://example.test/v1",
            selectedModel: parent.model
        )
        let recorder = SideChatRequestRecorder()
        let sideChat = SideChatSession(
            parent: parent,
            route: route,
            apiKey: "test-key",
            streamer: SideChatTestStreamer(
                recorder: recorder,
                response: [.reasoning("private side reasoning"), .content("Side answer")]
            )
        )

        sideChat.draft = "What is the status?"
        sideChat.send()
        await sideChat.waitForCompletion()

        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].settings.provider, .openAICompatible)
        XCTAssertEqual(requests[0].settings.selectedModel, "parent-model")
        XCTAssertEqual(requests[0].settings.endpoint, "https://example.test/v1")
        XCTAssertEqual(requests[0].apiKey, "test-key")
        XCTAssertTrue(requests[0].settings.systemPrompt.contains("read-only side chat"))
        XCTAssertEqual(requests[0].messages.last?.content, "What is the status?")
        XCTAssertEqual(requests[0].messages.count, 2)
        let snapshot = requests[0].messages[0].content
        XCTAssertTrue(snapshot.contains("Explain the change"))
        XCTAssertTrue(snapshot.contains("I will inspect the repository"))
        XCTAssertFalse(snapshot.contains("secret tool output"))
        XCTAssertFalse(snapshot.contains("private reasoning"))
        XCTAssertFalse(snapshot.contains("Calling a tool"))
        XCTAssertFalse(snapshot.contains("old-title-secret"))
        XCTAssertFalse(snapshot.contains("old-message-secret"))
        XCTAssertFalse(snapshot.contains("old-api-key"))
        XCTAssertFalse(snapshot.contains("url-password"))
        XCTAssertTrue(snapshot.contains("[REDACTED]"))
        XCTAssertEqual(sideChat.messages.map(\.content), ["What is the status?", "Side answer"])
        XCTAssertFalse(sideChat.messages.map(\.content).joined().contains("private side reasoning"))
        XCTAssertEqual(parent.messages, originalMessages)
    }

    @MainActor
    func testSideConversationLeavesParentRunActive() async {
        var parent = AgentSession(mode: .agent)
        parent.state = .running
        parent.model = "parent-model"
        parent.messages = [AgentMessage(role: .user, content: "Continue implementation")]
        let viewModel = AgentViewModel()
        viewModel.beginRunTracking(runID: UUID(), session: parent, userRequest: nil)
        let recorder = SideChatRequestRecorder()
        let sideChat = SideChatSession(
            parent: parent,
            route: AppSettings(selectedModel: parent.model),
            apiKey: nil,
            streamer: SideChatTestStreamer(recorder: recorder)
        )

        sideChat.draft = "Summarize progress"
        sideChat.send()
        await sideChat.waitForCompletion()

        XCTAssertTrue(viewModel.isRunning(sessionID: parent.id))
        XCTAssertEqual(viewModel.activeRunCount, 1)
        XCTAssertEqual(parent.state, .running)
        XCTAssertEqual(parent.messages.map(\.content), ["Continue implementation"])
        XCTAssertEqual(sideChat.messages.last?.content, "Side answer")
    }

    @MainActor
    func testCloseClearsTransientTranscriptAndPreventsFurtherRequests() async {
        let parent = AgentSession(mode: .agent)
        let recorder = SideChatRequestRecorder()
        let sideChat = SideChatSession(
            parent: parent,
            route: AppSettings(selectedModel: "local-model"),
            apiKey: "test-key",
            streamer: SideChatTestStreamer(recorder: recorder)
        )

        sideChat.draft = "Temporary question"
        sideChat.send()
        await sideChat.waitForCompletion()
        XCTAssertEqual(sideChat.messages.count, 2)

        sideChat.close()
        sideChat.draft = "Second question"
        sideChat.send()

        XCTAssertTrue(sideChat.isClosed)
        XCTAssertTrue(sideChat.messages.isEmpty)
        XCTAssertFalse(sideChat.canSend)
        let requests = await recorder.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(parent.messages.isEmpty)
    }
}
