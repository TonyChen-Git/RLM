import Foundation
import XCTest

@testable import LumaChat

private struct AgentStreamingStubResponse: Sendable {
  var statusCode = 200
  var headers: [String: String] = ["Content-Type": "application/json"]
  var chunks: [Data]
  var holdOpen = false
}

private final class AgentStreamingStubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> AgentStreamingStubResponse)?
  nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
  nonisolated(unsafe) private static var capturedBodies: [Data] = []
  nonisolated(unsafe) private static var stops = 0
  private static let stateLock = NSLock()

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = Self.bodyData(from: request)
    Self.stateLock.lock()
    Self.capturedRequests.append(request)
    Self.capturedBodies.append(body)
    let response =
      Self.handler?(request)
      ?? AgentStreamingStubResponse(
        statusCode: 500,
        chunks: []
      )
    Self.stateLock.unlock()

    let http = HTTPURLResponse(
      url: request.url!,
      statusCode: response.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: response.headers
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
    if !response.holdOpen { client?.urlProtocolDidFinishLoading(self) }
  }

  override func stopLoading() {
    Self.stateLock.lock()
    Self.stops += 1
    Self.stateLock.unlock()
  }

  static func reset(
    handler: @escaping (URLRequest) -> AgentStreamingStubResponse
  ) {
    stateLock.lock()
    self.handler = handler
    capturedRequests = []
    capturedBodies = []
    stops = 0
    stateLock.unlock()
  }

  static func snapshot() -> (requests: [URLRequest], bodies: [Data], stops: Int) {
    stateLock.lock()
    defer { stateLock.unlock() }
    return (capturedRequests, capturedBodies, stops)
  }

  private static func bodyData(from request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      result.append(buffer, count: count)
    }
    return result
  }
}

final class AgentProviderStreamingTests: XCTestCase {
  private let schema = JSONValue.objectSchema(
    properties: ["path": .stringSchema()],
    required: ["path"]
  )

  func testOllamaNDJSONStreamingAssemblesToolDeltasAndUsage() async throws {
    AgentStreamingStubURLProtocol.reset { request in
      if request.url?.path == "/api/show" {
        return AgentStreamingStubResponse(
          chunks: [Data(#"{"capabilities":["completion","tools"]}"#.utf8)]
        )
      }
      return AgentStreamingStubResponse(
        headers: ["Content-Type": "application/x-ndjson"],
        chunks: [
          Data(#"{"message":{"content":"Hel","thinking":"private"},"done":false}"#.utf8)
            + Data([0x0A]),
          Data(
            #"{"message":{"content":"lo","tool_calls":[{"function":{"index":0,"name":"read_","arguments":"{\"pa"}}]},"done":false}"#
              .utf8)
            + Data([0x0A]),
          Data(
            #"{"message":{"tool_calls":[{"function":{"index":0,"name":"file","arguments":"th\":\"A.swift\"}"}}]},"done":true,"done_reason":"tool_calls","prompt_eval_count":9,"eval_count":4}"#
              .utf8)
            + Data([0x0A]),
        ]
      )
    }
    let session = stubSession()
    defer { session.invalidateAndCancel() }
    let provider = AgentModelProviderFactory.make(
      settings: AppSettings(
        provider: .ollama,
        endpoint: "http://127.0.0.1",
        selectedModel: "tool-model"
      ),
      apiKey: nil,
      session: session
    )

    let events = try await collect(
      provider.stream(request: modelRequest(model: "tool-model"))
    )
    XCTAssertEqual(events.textDeltas, ["Hel", "lo"])
    XCTAssertEqual(events.reasoningDeltas, ["private"])
    let response = try XCTUnwrap(events.response)
    XCTAssertEqual(response.content, "Hello")
    XCTAssertEqual(response.reasoningSummary, "private")
    XCTAssertEqual(response.toolCalls.map(\.name), ["read_file"])
    XCTAssertEqual(
      response.toolCalls.first?.arguments,
      .object(["path": .string("A.swift")])
    )
    XCTAssertEqual(
      response.usage,
      AgentTokenUsage(inputTokens: 9, outputTokens: 4, totalTokens: 13)
    )

    let snapshot = AgentStreamingStubURLProtocol.snapshot()
    XCTAssertEqual(snapshot.requests.map { $0.url?.path }, ["/api/show", "/api/chat"])
    let chatBody = try XCTUnwrap(snapshot.bodies.last)
    XCTAssertEqual(try jsonObject(chatBody)["stream"] as? Bool, true)
    XCTAssertEqual(
      snapshot.requests.last?.value(forHTTPHeaderField: "Accept"),
      "application/x-ndjson"
    )
  }

  func testOpenAICompatibleSSEAssemblesParallelToolCallDeltas() async throws {
    AgentStreamingStubURLProtocol.reset { _ in
      AgentStreamingStubResponse(
        headers: ["Content-Type": "text/event-stream"],
        chunks: [
          Data(
            #"""
            data: {"choices":[{"index":0,"delta":{"content":"Hel","reasoning_content":"why ","tool_calls":[{"index":0,"id":"call-a","function":{"name":"read_","arguments":"{\"pa"}},{"index":1,"id":"call-b","function":{"name":"read_","arguments":"{\"pa"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"content":"lo","reasoning_content":"now","tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"th\":\"A.swift\"}"}},{"index":1,"function":{"name":"file","arguments":"th\":\"B.swift\"}"}}]},"finish_reason":"tool_calls"}]}

            data: {"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16}}

            data: [DONE]

            """#.utf8)
        ]
      )
    }
    let session = stubSession()
    defer { session.invalidateAndCancel() }
    let provider = AgentModelProviderFactory.make(
      settings: AppSettings(
        provider: .openAICompatible,
        endpoint: "http://127.0.0.1/v1",
        selectedModel: "tool-model"
      ),
      apiKey: "secret",
      session: session
    )

    let events = try await collect(provider.stream(request: modelRequest()))
    XCTAssertEqual(events.textDeltas, ["Hel", "lo"])
    XCTAssertEqual(events.reasoningDeltas, ["why ", "now"])
    let response = try XCTUnwrap(events.response)
    XCTAssertEqual(response.content, "Hello")
    XCTAssertEqual(response.reasoningSummary, "why now")
    XCTAssertEqual(response.toolCalls.map(\.id), ["call-a", "call-b"])
    XCTAssertEqual(response.toolCalls.map(\.name), ["read_file", "read_file"])
    XCTAssertEqual(
      response.toolCalls[1].arguments,
      .object(["path": .string("B.swift")])
    )
    XCTAssertEqual(
      response.usage,
      AgentTokenUsage(inputTokens: 11, outputTokens: 5, totalTokens: 16)
    )
    XCTAssertEqual(response.finishReason, "tool_calls")

    let snapshot = AgentStreamingStubURLProtocol.snapshot()
    XCTAssertEqual(try jsonObject(try XCTUnwrap(snapshot.bodies.last))["stream"] as? Bool, true)
    XCTAssertEqual(
      snapshot.requests.last?.value(forHTTPHeaderField: "Accept"),
      "text/event-stream"
    )
  }

  func testAnthropicSSEAssemblesInputJSONAndMessageUsage() async throws {
    AgentStreamingStubURLProtocol.reset { _ in
      AgentStreamingStubResponse(
        headers: ["Content-Type": "text/event-stream"],
        chunks: [
          Data(
            #"""
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":13,"output_tokens":0}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"A.swift\"}"}}

            event: content_block_start
            data: {"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":2,"delta":{"type":"thinking_delta","thinking":"private"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}

            event: message_stop
            data: {"type":"message_stop"}

            """#.utf8)
        ]
      )
    }
    let session = stubSession()
    defer { session.invalidateAndCancel() }
    let provider = AgentModelProviderFactory.make(
      settings: AppSettings(
        provider: .anthropic,
        endpoint: "http://127.0.0.1/v1",
        selectedModel: "claude-test"
      ),
      apiKey: "secret",
      session: session
    )

    let events = try await collect(provider.stream(request: modelRequest(model: "claude-test")))
    XCTAssertEqual(events.textDeltas, ["Hel", "lo"])
    XCTAssertEqual(events.reasoningDeltas, ["private"])
    let response = try XCTUnwrap(events.response)
    XCTAssertEqual(response.content, "Hello")
    XCTAssertEqual(response.reasoningSummary, "private")
    XCTAssertEqual(response.toolCalls.map(\.id), ["toolu_1"])
    XCTAssertEqual(
      response.toolCalls[0].arguments,
      .object(["path": .string("A.swift")])
    )
    XCTAssertEqual(
      response.usage,
      AgentTokenUsage(inputTokens: 13, outputTokens: 7, totalTokens: 20)
    )
    XCTAssertEqual(response.finishReason, "tool_use")

    let snapshot = AgentStreamingStubURLProtocol.snapshot()
    XCTAssertEqual(try jsonObject(try XCTUnwrap(snapshot.bodies.last))["stream"] as? Bool, true)
    XCTAssertEqual(
      snapshot.requests.last?.value(forHTTPHeaderField: "Accept"),
      "text/event-stream"
    )
  }

  func testStreamingParserRejectsIncompleteToolArgumentsAndTransportBoundsLines() async throws {
    var accumulator = OpenAICompatibleAgentStreamAccumulator()
    _ = try accumulator.consume(
      line: Data(
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call","function":{"name":"read_file","arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#
          .utf8))
    _ = try accumulator.consume(line: Data())
    _ = try accumulator.consume(line: Data("data: [DONE]".utf8))
    _ = try accumulator.consume(line: Data())
    XCTAssertThrowsError(try accumulator.finish())

    AgentStreamingStubURLProtocol.reset { _ in
      AgentStreamingStubResponse(
        chunks: [
          Data(
            repeating: 0x41,
            count: ProviderWireStreamLimits.maximumLineBytes + 1
          ) + Data([0x0A])
        ]
      )
    }
    let session = stubSession()
    defer { session.invalidateAndCancel() }
    let transport = ProviderHTTPTransport(session: session)
    var request = URLRequest(url: URL(string: "http://127.0.0.1/stream")!)
    request.httpMethod = "POST"
    do {
      try await transport.streamLines(
        for: request,
        provider: "test",
        model: "model",
        requestedTools: false,
        handleLine: { _ in }
      )
      XCTFail("Expected the bounded line guard to reject the response")
    } catch let error as ProviderWireError {
      guard case .malformedResponse = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testCancellingStreamingTransportCancelsURLSessionTask() async throws {
    AgentStreamingStubURLProtocol.reset { _ in
      AgentStreamingStubResponse(chunks: [], holdOpen: true)
    }
    let session = stubSession()
    defer { session.invalidateAndCancel() }
    let transport = ProviderHTTPTransport(session: session)
    let request = URLRequest(url: URL(string: "http://127.0.0.1/held-open")!)
    let task = Task {
      try await transport.streamLines(
        for: request,
        provider: "test",
        model: "model",
        requestedTools: false,
        handleLine: { _ in }
      )
    }
    for _ in 0..<1_000 {
      if !AgentStreamingStubURLProtocol.snapshot().requests.isEmpty { break }
      await Task.yield()
    }
    XCTAssertFalse(AgentStreamingStubURLProtocol.snapshot().requests.isEmpty)
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
    for _ in 0..<1_000 {
      if AgentStreamingStubURLProtocol.snapshot().stops > 0 { break }
      await Task.yield()
    }
    XCTAssertGreaterThan(AgentStreamingStubURLProtocol.snapshot().stops, 0)
  }

  private func modelRequest(model: String = "tool-model") -> AgentModelRequest {
    AgentModelRequest(
      model: model,
      messages: [.init(role: .user, content: "Inspect A.swift")],
      tools: [.init(name: "read_file", description: "Read", inputSchema: schema)],
      stream: true,
      temperature: 0.2,
      maxOutputTokens: 512
    )
  }

  private func collect(
    _ stream: AsyncThrowingStream<AgentModelStreamEvent, Error>
  ) async throws -> (
    textDeltas: [String],
    reasoningDeltas: [String],
    response: AgentModelResponse?
  ) {
    var text: [String] = []
    var reasoning: [String] = []
    var response: AgentModelResponse?
    for try await event in stream {
      switch event {
      case .contentDelta(let value): text.append(value)
      case .reasoningDelta(let value): reasoning.append(value)
      case .completed(let value): response = value
      }
    }
    return (text, reasoning, response)
  }

  private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AgentStreamingStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}
