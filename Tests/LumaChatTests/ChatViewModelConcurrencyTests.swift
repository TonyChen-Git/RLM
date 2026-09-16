import Foundation
import XCTest
@testable import LumaChat

private final class HeldChatStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [HeldChatStreamURLProtocol] = []
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.lock.withLock { Self.held.append(self) }
    }

    override func stopLoading() {
        Self.lock.withLock { stopped = true }
    }

    static var heldCount: Int {
        lock.withLock { held.count }
    }

    static func finishHeldStreams() {
        let streams = lock.withLock {
            let snapshot = held
            held.removeAll()
            return snapshot
        }
        let body = Data("data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\ndata: [DONE]\n\n".utf8)
        for stream in streams {
            let shouldFinish = lock.withLock { !stream.stopped }
            guard shouldFinish else { continue }
            stream.client?.urlProtocol(stream, didLoad: body)
            stream.client?.urlProtocolDidFinishLoading(stream)
        }
    }
}

final class ChatViewModelConcurrencyTests: XCTestCase {
    @MainActor
    func testConversationDraftsSurviveNavigation() {
        let viewModel = ChatViewModel()
        let first = Conversation(model: "test-model", endpoint: "http://unit.test")
        let second = Conversation(model: "test-model", endpoint: "http://unit.test")
        viewModel.conversations = [first, second]

        viewModel.selectedConversationID = first.id
        viewModel.draft = "first draft"
        viewModel.selectedConversationID = second.id
        viewModel.draft = "second draft"

        viewModel.selectedConversationID = first.id
        XCTAssertEqual(viewModel.draft, "first draft")
        viewModel.selectedConversationID = second.id
        XCTAssertEqual(viewModel.draft, "second draft")
    }

    @MainActor
    func testStoppingSelectedConversationDoesNotStopBackgroundConversation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldChatStreamURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            HeldChatStreamURLProtocol.finishHeldStreams()
            session.invalidateAndCancel()
        }

        let viewModel = ChatViewModel(llmClient: LLMClient(session: session))
        viewModel.settings = AppSettings(
            provider: .openAICompatible,
            endpoint: "http://unit.test/v1",
            selectedModel: "test-model"
        )
        let first = Conversation(
            model: "test-model",
            provider: .openAICompatible,
            endpoint: "http://unit.test/v1"
        )
        viewModel.conversations = [first]
        viewModel.selectedConversationID = first.id
        viewModel.draft = "first request"
        await viewModel.send()

        let secondID = try XCTUnwrap(viewModel.createConversation(force: true))
        viewModel.draft = "second request"
        await viewModel.send()

        try await waitUntil { HeldChatStreamURLProtocol.heldCount == 2 }
        XCTAssertEqual(viewModel.runningConversationIDs, Set([first.id, secondID]))
        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertTrue(viewModel.selectedConversationIsGenerating)

        viewModel.stopGenerating()

        XCTAssertTrue(viewModel.isConversationGenerating(first.id))
        XCTAssertFalse(viewModel.isConversationGenerating(secondID))
        XCTAssertTrue(viewModel.isGenerating)
        XCTAssertFalse(viewModel.selectedConversationIsGenerating)
        XCTAssertEqual(viewModel.connectionState, .idle)

        HeldChatStreamURLProtocol.finishHeldStreams()
        try await waitUntil { !viewModel.isGenerating }
        XCTAssertTrue(viewModel.runningConversationIDs.isEmpty)
        XCTAssertEqual(
            viewModel.connectionState,
            .idle,
            "A background conversation must not overwrite the selected conversation's status"
        )

        await viewModel.deleteConversation(id: first.id)
        await viewModel.deleteConversation(id: secondID)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for asynchronous chat state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
