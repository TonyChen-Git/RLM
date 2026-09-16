import Foundation
import XCTest
@testable import LumaChat

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var contentType = "application/json"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LLMReasoningStreamTests: XCTestCase {
    private func client() -> (LLMClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (LLMClient(session: session), session)
    }

    private func collect(provider: ProviderKind, body: String) async throws -> [LLMStreamDelta] {
        StubURLProtocol.responseBody = Data(body.utf8)
        StubURLProtocol.contentType = provider == .ollama ? "application/x-ndjson" : "text/event-stream"
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: provider,
            endpoint: "http://unit.test",
            selectedModel: "test-model"
        )
        let messages = [ChatMessage(role: .user, content: "hello")]
        var deltas: [LLMStreamDelta] = []
        for try await delta in client.stream(
            messages: messages,
            settings: settings,
            apiKey: nil,
            attachmentLoader: { _ in nil }
        ) {
            deltas.append(delta)
        }
        return deltas
    }

    func testOllamaSeparatesThinkingFromAnswer() async throws {
        let body = """
        {"message":{"thinking":"plan","content":""}}
        {"message":{"thinking":"","content":"answer"}}

        """
        let deltas = try await collect(provider: .ollama, body: body)
        XCTAssertEqual(deltas, [.reasoning("plan"), .content("answer")])
    }

    func testOpenAICompatibleSeparatesReasoningContent() async throws {
        let body = """
        data: {"choices":[{"delta":{"reasoning_content":"plan"}}]}

        data: {"choices":[{"delta":{"content":"answer"}}]}

        data: [DONE]

        """
        let deltas = try await collect(provider: .openAICompatible, body: body)
        XCTAssertEqual(deltas, [.reasoning("plan"), .content("answer")])
    }

    func testAnthropicSeparatesThinkingDelta() async throws {
        let body = """
        data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"plan"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}

        """
        let deltas = try await collect(provider: .anthropic, body: body)
        XCTAssertEqual(deltas, [.reasoning("plan"), .content("answer")])
    }
}
