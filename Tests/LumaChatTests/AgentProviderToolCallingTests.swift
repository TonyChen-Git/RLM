import Foundation
import XCTest
@testable import LumaChat

private final class AgentProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.requestBodies.append(Self.bodyData(from: request))
        let result = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class AgentProviderToolCallingTests: XCTestCase {
    private let schema: ProviderJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object(["type": .string("string")])
        ]),
        "required": .array([.string("path")])
    ])

    func testRemoteOllamaHTTPIsSupportedWithoutLeakingCredentials() throws {
        let remote = try ProviderRequestBuilder.routeURL(
            endpoint: "http://192.168.50.20:11434",
            provider: .ollama,
            route: ["api", "chat"]
        )
        XCTAssertEqual(remote.absoluteString, "http://192.168.50.20:11434/api/chat")
        XCTAssertNoThrow(
            try ProviderRequestBuilder.jsonRequest(
                url: remote,
                provider: .ollama,
                apiKey: nil,
                timeout: 30,
                body: Data("{}".utf8)
            )
        )
        XCTAssertThrowsError(
            try ProviderRequestBuilder.jsonRequest(
                url: remote,
                provider: .ollama,
                apiKey: "must-not-travel-in-cleartext",
                timeout: 30,
                body: Data("{}".utf8)
            )
        )
    }

    func testRemoteOpenAICompatibleHTTPAndHTTPSAllowBearerCredential() throws {
        let body = Data(#"{"model":"qwen3.8-27b","messages":[]}"#.utf8)
        for scheme in ["http", "https"] {
            let url = try ProviderRequestBuilder.routeURL(
                endpoint: "\(scheme)://10.5.88.100:8003/v1",
                provider: .openAICompatible,
                route: ["chat", "completions"]
            )
            XCTAssertEqual(url.absoluteString, "\(scheme)://10.5.88.100:8003/v1/chat/completions")

            let request = try ProviderRequestBuilder.jsonRequest(
                url: url,
                provider: .openAICompatible,
                apiKey: "sk-local-vllm",
                timeout: 30,
                body: body
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local-vllm")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.httpBody, body)
        }
    }

    func testRemoteAnthropicHTTPStillRequiresTLS() {
        XCTAssertThrowsError(
            try ProviderRequestBuilder.routeURL(
                endpoint: "http://192.168.50.20:8080/v1",
                provider: .anthropic,
                route: ["messages"]
            )
        ) { error in
            guard case ProviderWireError.invalidEndpoint = error else {
                return XCTFail("Expected invalidEndpoint, got \(error)")
            }
        }
    }

    func testRemoteNumericBoundariesDoNotTrapOrPoisonCapabilities() throws {
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
        XCTAssertNil(JSONValue.number(0x1p63).intValue)

        let ollama = try OllamaAgentWireAdapter.parseChatResponse(Data(#"""
        {
          "message":{"role":"assistant","content":"ok"},
          "prompt_eval_count":9223372036854775807,
          "eval_count":1
        }
        """#.utf8))
        XCTAssertNil(ollama.usage?.inputTokens)
        XCTAssertEqual(ollama.usage?.outputTokens, 1)
        XCTAssertEqual(ollama.usage?.totalTokens, 1)

        let anthropic = try AnthropicAgentWireAdapter.parseMessagesResponse(Data(#"""
        {
          "content":[{"type":"text","text":"ok"}],
          "usage":{"input_tokens":9223372036854775807,"output_tokens":1}
        }
        """#.utf8))
        XCTAssertNil(anthropic.usage?.inputTokens)
        XCTAssertEqual(anthropic.usage?.totalTokens, 1)

        let capabilities = OllamaAgentWireAdapter.parseCapabilities(Data(#"""
        {
          "capabilities":["tools"],
          "model_info":{"context_length":9223372036854775807}
        }
        """#.utf8))
        XCTAssertNil(capabilities?.contextWindow)
    }

    func testOllamaToolRoundTripPayloadResponseAndMetadataCapabilities() throws {
        let settings = AppSettings(
            provider: .ollama,
            endpoint: "http://127.0.0.1",
            selectedModel: "tool-model",
            contextLength: 16_384,
            temperature: 0.25
        )
        let request = ProviderWireRequest(
            model: "tool-model",
            messages: roundTripMessages,
            tools: [.init(name: "read_file", description: "Read a file", inputSchema: schema)],
            contextLength: 16_384,
            maxOutputTokens: 2_048,
            temperature: 0.25
        )

        let urlRequest = try OllamaAgentWireAdapter.makeChatRequest(
            request,
            settings: settings,
            apiKey: "ollama-secret"
        )
        XCTAssertEqual(urlRequest.url?.path, "/api/chat")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer ollama-secret")
        let json = try jsonObject(urlRequest)
        XCTAssertEqual(json["model"] as? String, "tool-model")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual((json["options"] as? [String: Any])?["num_ctx"] as? Int, 16_384)
        XCTAssertEqual((json["options"] as? [String: Any])?["num_predict"] as? Int, 2_048)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "read_file")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.count, 2)
        let toolMessages = messages.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(toolMessages.map { $0["tool_name"] as? String }, ["read_file", "search"])

        let response = try OllamaAgentWireAdapter.parseChatResponse(Data(#"""
        {
          "message": {
            "role": "assistant",
            "thinking": "inspect both files",
            "content": "I will inspect them.",
            "tool_calls": [
              {"function":{"name":"read_file","arguments":{"path":"A.swift"}}},
              {"function":{"name":"search","arguments":"{\"query\":\"TODO\"}"}}
            ]
          },
          "done": true,
          "done_reason": "stop",
          "prompt_eval_count": 9,
          "eval_count": 4
        }
        """#.utf8))
        XCTAssertEqual(response.text, "I will inspect them.")
        XCTAssertEqual(response.reasoning, "inspect both files")
        XCTAssertEqual(response.toolCalls.map(\.name), ["read_file", "search"])
        XCTAssertEqual(response.toolCalls[0].arguments, .object(["path": .string("A.swift")]))
        XCTAssertEqual(response.toolCalls[1].arguments, .object(["query": .string("TODO")]))
        XCTAssertNotEqual(response.toolCalls[0].id, response.toolCalls[1].id)
        XCTAssertEqual(response.usage, .init(inputTokens: 9, outputTokens: 4, totalTokens: 13))

        let capabilities = try XCTUnwrap(OllamaAgentWireAdapter.parseCapabilities(Data(#"""
        {
          "capabilities": ["completion", "tools", "vision", "thinking"],
          "model_info": {"example.context_length": 32768}
        }
        """#.utf8)))
        XCTAssertTrue(capabilities.supportsTools)
        XCTAssertTrue(capabilities.supportsVision)
        XCTAssertTrue(capabilities.supportsReasoning)
        XCTAssertEqual(capabilities.contextWindow, 32_768)
    }

    func testOpenAICompatibleToolRoundTripPayloadAndResponse() throws {
        let settings = AppSettings(
            provider: .openAICompatible,
            endpoint: "https://api.openai.com",
            selectedModel: "tool-model"
        )
        let input = ProviderWireRequest(
            model: "tool-model",
            messages: roundTripMessages,
            tools: [.init(name: "read_file", description: "Read a file", inputSchema: schema)],
            contextLength: 8_192,
            maxOutputTokens: 1_024,
            temperature: 0.5
        )
        let urlRequest = try OpenAICompatibleAgentWireAdapter.makeChatRequest(
            input,
            settings: settings,
            apiKey: "openai-secret"
        )
        XCTAssertEqual(urlRequest.url?.path, "/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer openai-secret")
        let json = try jsonObject(urlRequest)
        XCTAssertEqual(json["tool_choice"] as? String, "auto")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        let assistantCalls = try XCTUnwrap(assistant["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(assistantCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["arguments"] as? String, #"{"path":"A.swift"}"#)
        let tool = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
        XCTAssertEqual(tool["tool_call_id"] as? String, "call-a")

        let response = try OpenAICompatibleAgentWireAdapter.parseChatResponse(Data(#"""
        {
          "choices": [{
            "finish_reason": "tool_calls",
            "message": {
              "role": "assistant",
              "content": "Checking both.",
              "reasoning_content": "Need two independent reads",
              "tool_calls": [
                {"id":"call-1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"A.swift\"}"}},
                {"id":"call-2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"B.swift\"}"}}
              ]
            }
          }],
          "usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16}
        }
        """#.utf8))
        XCTAssertEqual(response.text, "Checking both.")
        XCTAssertEqual(response.reasoning, "Need two independent reads")
        XCTAssertEqual(response.toolCalls.map(\.id), ["call-1", "call-2"])
        XCTAssertEqual(response.toolCalls[1].arguments, .object(["path": .string("B.swift")]))
        XCTAssertEqual(response.usage, .init(inputTokens: 11, outputTokens: 5, totalTokens: 16))
        XCTAssertEqual(response.finishReason, "tool_calls")
    }

    func testOpenAICompatibleMergesEverySystemMessageAtRequestStart() throws {
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://127.0.0.1:8003/v1",
            selectedModel: "fixture-model"
        )
        let systemContents = [
            "Main system prompt",
            "Project Settings: exact instructions",
            "Git status: modified file",
            "Skills: loaded skill",
            "Memory: approved note",
            "Todo: outstanding item"
        ]
        let request = ProviderWireRequest(
            model: "fixture-model",
            messages: [
                .init(role: .system, text: systemContents[0]),
                .init(role: .user, text: "first user turn"),
                .init(role: .system, text: systemContents[1]),
                .init(role: .assistant, text: "calling tool", toolCalls: [
                    .init(id: "call-a", name: "read_file", arguments: .object(["path": .string("A.swift")]))
                ]),
                .init(role: .tool, toolResult: .init(
                    callID: "call-a", toolName: "read_file", content: "tool result", isError: false
                )),
                .init(role: .system, text: systemContents[2]),
                .init(role: .system, text: systemContents[3]),
                .init(role: .system, text: systemContents[4]),
                .init(role: .system, text: systemContents[5]),
                .init(role: .user, text: "second user turn")
            ],
            tools: [.init(name: "read_file", description: "Read", inputSchema: schema)],
            contextLength: 8_192,
            maxOutputTokens: 1_024,
            temperature: 0.2
        )
        let urlRequest = try OpenAICompatibleAgentWireAdapter.makeChatRequest(
            request,
            settings: settings,
            apiKey: nil
        )
        XCTAssertEqual(urlRequest.url?.path, "/v1/chat/completions")
        let json = try jsonObject(urlRequest)
        XCTAssertEqual(json["model"] as? String, "fixture-model")
        XCTAssertEqual(json["tool_choice"] as? String, "auto")
        XCTAssertNil(json["reasoning_effort"])
        XCTAssertNil(json["chat_template_kwargs"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, [
            "system", "user", "assistant", "tool", "user"
        ])
        XCTAssertEqual(messages[0]["content"] as? String, systemContents.joined(separator: "\n\n"))
        XCTAssertFalse(messages.dropFirst().contains { $0["role"] as? String == "system" })
        XCTAssertEqual(messages[1]["content"] as? String, "first user turn")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call-a")
        XCTAssertEqual(messages[4]["content"] as? String, "second user turn")
    }

    func testHTTP400KeepsRedactedDiagnosticWithoutEchoingPrompt() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1/v1/chat/completions")!)
        for serverMessage in [
            "Qwen template requires leading system; api_key=sk-secret-example-12345; prompt: private project instructions",
            "Qwen template requires leading system; api_key=sk-secret-example-12345; \"messages\": [{\"content\":\"private project instructions\"}]"
        ] {
            AgentProviderStubURLProtocol.handler = { _ in
                let error = ["error": ["message": serverMessage]]
                return (400, (try? JSONSerialization.data(withJSONObject: error)) ?? Data())
            }
            do {
                _ = try await ProviderHTTPTransport(session: session).data(
                    for: request,
                    provider: "OpenAI 相容",
                    model: "fixture-model",
                    requestedTools: false
                )
                XCTFail("Expected the HTTP 400 diagnostic")
            } catch let error as ProviderWireError {
                guard case .http(_, let statusCode, let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(statusCode, 400)
                XCTAssertTrue(message?.contains("requires leading system") == true)
                XCTAssertFalse(message?.contains("sk-secret-example-12345") == true)
                XCTAssertFalse(message?.contains("private project instructions") == true)
            }
        }
    }

    func testAnthropicToolRoundTripPayloadAndResponse() throws {
        let settings = AppSettings(
            provider: .anthropic,
            endpoint: "https://api.anthropic.com",
            selectedModel: "claude-test"
        )
        let input = ProviderWireRequest(
            model: "claude-test",
            messages: roundTripMessages,
            tools: [.init(name: "read_file", description: "Read a file", inputSchema: schema)],
            contextLength: 8_192,
            maxOutputTokens: 1_024,
            temperature: 0.5
        )
        let urlRequest = try AnthropicAgentWireAdapter.makeMessagesRequest(
            input,
            settings: settings,
            apiKey: "anthropic-secret"
        )
        XCTAssertEqual(urlRequest.url?.path, "/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let json = try jsonObject(urlRequest)
        XCTAssertEqual(json["system"] as? String, "You are a coding agent.")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools[0]["input_schema"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual(
            (assistant["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "tool_use" }.count,
            2
        )
        let resultMessage = try XCTUnwrap(messages.last)
        XCTAssertEqual(resultMessage["role"] as? String, "user")
        XCTAssertEqual(
            (resultMessage["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "tool_result" }.count,
            2
        )

        let response = try AnthropicAgentWireAdapter.parseMessagesResponse(Data(#"""
        {
          "content": [
            {"type":"thinking","thinking":"inspect both files"},
            {"type":"text","text":"I'll inspect both."},
            {"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"A.swift"}},
            {"type":"tool_use","id":"toolu_2","name":"read_file","input":{"path":"B.swift"}}
          ],
          "stop_reason":"tool_use",
          "usage":{"input_tokens":13,"output_tokens":7}
        }
        """#.utf8))
        XCTAssertEqual(response.text, "I'll inspect both.")
        XCTAssertEqual(response.reasoning, "inspect both files")
        XCTAssertEqual(response.toolCalls.map(\.id), ["toolu_1", "toolu_2"])
        XCTAssertEqual(response.toolCalls[0].arguments, .object(["path": .string("A.swift")]))
        XCTAssertEqual(response.usage, .init(inputTokens: 13, outputTokens: 7, totalTokens: 20))
        XCTAssertEqual(response.finishReason, "tool_use")
    }

    func testFactoryUsesInjectedSessionForOpenAICompatibleProvider() async throws {
        AgentProviderStubURLProtocol.requests = []
        AgentProviderStubURLProtocol.requestBodies = []
        AgentProviderStubURLProtocol.handler = { _ in
            (200, Data(#"""
            {
              "choices":[{"finish_reason":"tool_calls","message":{
                "content":"",
                "tool_calls":[
                  {"id":"call-1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"A.swift\"}"}},
                  {"id":"call-2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"B.swift\"}"}}
                ]
              }}],
              "usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}
            }
            """#.utf8))
        }
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .openAICompatible,
            endpoint: "http://127.0.0.1/v1",
            selectedModel: "selected-model"
        )
        let provider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: "injected-secret",
            session: session
        )
        XCTAssertTrue(provider is OpenAICompatibleAgentProvider)
        let response = try await provider.generate(
            request: AgentModelRequest(
                model: "",
                messages: [.init(role: .user, content: "Inspect both")],
                tools: [.init(name: "read_file", description: "Read", inputSchema: schema)],
                stream: false,
                temperature: 0.2,
                maxOutputTokens: 512
            )
        )
        XCTAssertEqual(response.toolCalls.map(\.id), ["call-1", "call-2"])
        XCTAssertEqual(response.usage, .init(inputTokens: 3, outputTokens: 2, totalTokens: 5))
        let sent = try XCTUnwrap(AgentProviderStubURLProtocol.requests.last)
        XCTAssertEqual(sent.url?.path, "/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer injected-secret")
        let sentBody = try XCTUnwrap(AgentProviderStubURLProtocol.requestBodies.last)
        XCTAssertEqual(try jsonObject(sentBody)["model"] as? String, "selected-model")
    }

    func testOllamaMetadataRejectsUnsupportedToolsAndMissingMetadataUsesProviderFallback() async throws {
        AgentProviderStubURLProtocol.requests = []
        AgentProviderStubURLProtocol.requestBodies = []
        AgentProviderStubURLProtocol.handler = { request in
            if request.url?.path == "/api/show" {
                return (200, Data(#"{"capabilities":["completion"],"model_info":{}}"#.utf8))
            }
            return (500, Data(#"{"error":"chat should not be called"}"#.utf8))
        }
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .ollama,
            endpoint: "http://127.0.0.1",
            selectedModel: "metadata-model"
        )
        let provider = AgentModelProviderFactory.make(settings: settings, apiKey: nil, session: session)
        let capabilities = await provider.capabilities(for: "metadata-model")
        XCTAssertFalse(capabilities.supportsTools)
        do {
            _ = try await provider.generate(
                request: AgentModelRequest(
                    model: "metadata-model",
                    messages: [.init(role: .user, content: "Use a tool")],
                    tools: [.init(name: "read_file", description: "Read", inputSchema: schema)],
                    stream: false,
                    temperature: 0.2,
                    maxOutputTokens: 512
                )
            )
            XCTFail("Expected a useful unsupported-tools error")
        } catch let error as ProviderWireError {
            guard case .unsupportedTools(let providerName, let model, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerName, "Ollama")
            XCTAssertEqual(model, "metadata-model")
            XCTAssertTrue(error.localizedDescription.contains("不支援原生 Agent tools"))
        }
        XCTAssertEqual(AgentProviderStubURLProtocol.requests.map { $0.url?.path }, ["/api/show"])

        AgentProviderStubURLProtocol.requests = []
        AgentProviderStubURLProtocol.requestBodies = []
        AgentProviderStubURLProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        let fallbackProvider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: nil,
            session: session
        )
        let fallback = await fallbackProvider.capabilities(for: "arbitrary-model-name")
        XCTAssertTrue(fallback.supportsTools)
        XCTAssertEqual(AgentProviderStubURLProtocol.requests.map { $0.url?.path }, ["/api/show"])
    }

    private var roundTripMessages: [ProviderWireMessage] {
        [
            .init(role: .system, text: "You are a coding agent."),
            .init(role: .user, text: "Inspect both files."),
            .init(
                role: .assistant,
                text: "I will inspect them.",
                toolCalls: [
                    .init(id: "call-a", name: "read_file", arguments: .object(["path": .string("A.swift")])),
                    .init(id: "call-b", name: "search", arguments: .object(["query": .string("TODO")]))
                ]
            ),
            .init(
                role: .tool,
                toolResult: .init(
                    callID: "call-a", toolName: "read_file", content: "file A", isError: false
                )
            ),
            .init(
                role: .tool,
                toolResult: .init(
                    callID: "call-b", toolName: "search", content: "one match", isError: false
                )
            )
        ]
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try jsonObject(body)
    }

    private func jsonObject(_ body: Data) throws -> [String: Any] {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentProviderStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
