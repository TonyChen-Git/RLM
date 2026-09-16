import Foundation

enum AnthropicAgentWireAdapter {
    static let providerName = "Anthropic"

    static func makeMessagesRequest(
        _ input: ProviderWireRequest,
        settings: AppSettings,
        apiKey: String?,
        stream: Bool = false
    ) throws -> URLRequest {
        guard !input.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderWireError.missingModel
        }
        let url = try ProviderRequestBuilder.routeURL(
            endpoint: settings.endpoint,
            provider: .anthropic,
            route: ["messages"]
        )
        let system = input.messages
            .filter { $0.role == .system }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let payload = AnthropicWireMessagesRequest(
            model: input.model,
            system: system.isEmpty ? nil : system,
            messages: AnthropicWireMessagesRequest.messages(from: input.messages),
            tools: input.tools.isEmpty ? nil : input.tools.map(AnthropicWireMessagesRequest.Tool.init),
            stream: stream,
            maxTokens: max(1, input.maxOutputTokens),
            temperature: input.temperature.map { min(1, max(0, $0)) },
            topP: input.topP,
            topK: input.topK
        )
        let body = try ProviderRequestBuilder.encoder().encode(payload)
        var request = try ProviderRequestBuilder.jsonRequest(
            url: url,
            provider: .anthropic,
            apiKey: apiKey,
            timeout: settings.requestTimeout,
            body: body
        )
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return request
    }

    static func parseMessagesResponse(_ data: Data) throws -> ProviderWireResponse {
        let response: AnthropicWireMessagesResponse
        do {
            response = try JSONDecoder().decode(AnthropicWireMessagesResponse.self, from: data)
        } catch {
            throw ProviderWireError.malformedResponse(
                provider: providerName,
                detail: error.localizedDescription
            )
        }

        var text: [String] = []
        var reasoning: [String] = []
        var calls: [ProviderWireToolCall] = []
        for block in response.content {
            switch block.type {
            case "text":
                if let value = block.text, !value.isEmpty { text.append(value) }
            case "thinking":
                if let value = block.thinking ?? block.text, !value.isEmpty { reasoning.append(value) }
            case "tool_use":
                guard let id = block.id?.nilIfBlank,
                      let name = block.name?.nilIfBlank,
                      let input = block.input else {
                    throw ProviderWireError.malformedResponse(
                        provider: providerName,
                        detail: "tool_use 缺少 id、name 或 input"
                    )
                }
                calls.append(.init(id: id, name: name, arguments: input))
            default:
                continue
            }
        }
        let usage = response.usage.map {
            let input = ProviderNumericSafety.tokenCount($0.inputTokens)
            let output = ProviderNumericSafety.tokenCount($0.outputTokens)
            return ProviderWireUsage(
                inputTokens: input,
                outputTokens: output,
                totalTokens: ProviderNumericSafety.tokenSum(input, output)
            )
        }
        return ProviderWireResponse(
            text: text.joined(),
            reasoning: reasoning.joined().nilIfBlank,
            toolCalls: calls,
            usage: usage,
            finishReason: response.stopReason
        )
    }

}

struct AnthropicAgentStreamAccumulator: Sendable {
    private enum Block: Sendable {
        case text
        case reasoning
        case tool(ProviderWireToolCallAccumulator)
        case ignored
    }

    private var sse = ProviderSSEDecoder()
    private var blocks: [Int: Block] = [:]
    private var text = ""
    private var textBytes = 0
    private var reasoning = ""
    private var reasoningBytes = 0
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var finishReason: String?
    private var sawMessageStop = false

    mutating func consume(line: Data) throws -> [ProviderWireStreamDelta] {
        guard let frame = try sse.consume(
            line: line,
            provider: AnthropicAgentWireAdapter.providerName
        ) else { return [] }
        return try process(frame)
    }

    mutating func finish() throws -> ProviderWireResponse {
        if let frame = sse.finish() { _ = try process(frame) }
        guard sawMessageStop else {
            throw malformed("Anthropic SSE 在 message_stop 前中斷")
        }
        let calls = try blocks.keys.sorted().compactMap { index -> ProviderWireToolCall? in
            guard case .tool(let builder) = blocks[index] else { return nil }
            return try builder.finalized(
                provider: AnthropicAgentWireAdapter.providerName,
                index: index,
                idPrefix: "anthropic_call"
            )
        }
        let usage: ProviderWireUsage?
        if inputTokens != nil || outputTokens != nil {
            usage = ProviderWireUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: ProviderNumericSafety.tokenSum(inputTokens, outputTokens)
            )
        } else {
            usage = nil
        }
        return ProviderWireResponse(
            text: text,
            reasoning: reasoning.nilIfBlank,
            toolCalls: calls,
            usage: usage,
            finishReason: finishReason
        )
    }

    private mutating func process(_ frame: ProviderSSEFrame) throws -> [ProviderWireStreamDelta] {
        let event: AnthropicWireStreamEvent
        do {
            event = try JSONDecoder().decode(AnthropicWireStreamEvent.self, from: frame.data)
        } catch {
            throw malformed(error.localizedDescription)
        }
        if frame.event == "error" || event.type == "error" {
            throw ProviderWireError.http(
                provider: AnthropicAgentWireAdapter.providerName,
                statusCode: 200,
                message: event.error?.message ?? "stream error"
            )
        }

        var deltas: [ProviderWireStreamDelta] = []
        switch event.type {
        case "message_start":
            if let value = event.message?.usage?.inputTokens {
                inputTokens = ProviderNumericSafety.tokenCount(value)
            }
            if let value = event.message?.usage?.outputTokens {
                outputTokens = ProviderNumericSafety.tokenCount(value)
            }
        case "content_block_start":
            guard let index = try validatedIndex(event.index),
                  let content = event.contentBlock else {
                throw malformed("content_block_start 缺少 index 或 content_block")
            }
            switch content.type {
            case "text":
                blocks[index] = .text
                if let value = content.text, !value.isEmpty {
                    try appendText(value, reasoningField: false)
                    deltas.append(.text(value))
                }
            case "thinking":
                blocks[index] = .reasoning
                if let value = content.thinking ?? content.text, !value.isEmpty {
                    try appendText(value, reasoningField: true)
                    deltas.append(.reasoning(value))
                }
            case "tool_use":
                var builder = ProviderWireToolCallAccumulator()
                builder.acceptID(content.id)
                builder.appendName(content.name)
                if let input = content.input { builder.setArguments(input) }
                blocks[index] = .tool(builder)
            default:
                blocks[index] = .ignored
            }
        case "content_block_delta":
            guard let index = try validatedIndex(event.index), let delta = event.delta else {
                throw malformed("content_block_delta 缺少 index 或 delta")
            }
            switch delta.type {
            case "text_delta":
                if let value = delta.text, !value.isEmpty {
                    try appendText(value, reasoningField: false)
                    deltas.append(.text(value))
                }
            case "thinking_delta":
                if let value = delta.thinking ?? delta.text, !value.isEmpty {
                    try appendText(value, reasoningField: true)
                    deltas.append(.reasoning(value))
                }
            case "input_json_delta":
                guard case .tool(var builder) = blocks[index] else {
                    throw malformed("input_json_delta 沒有對應的 tool_use block")
                }
                try builder.appendArguments(
                    delta.partialJSON ?? "",
                    provider: AnthropicAgentWireAdapter.providerName
                )
                blocks[index] = .tool(builder)
            default:
                break
            }
        case "message_delta":
            if let value = event.delta?.stopReason?.nilIfBlank { finishReason = value }
            if let value = event.usage?.outputTokens {
                outputTokens = ProviderNumericSafety.tokenCount(value)
            }
        case "message_stop":
            sawMessageStop = true
        case "content_block_stop", "ping":
            break
        default:
            break
        }
        return deltas
    }

    private func validatedIndex(_ value: Int?) throws -> Int? {
        guard let value else { return nil }
        guard (0..<ProviderWireStreamLimits.maximumToolCalls).contains(value) else {
            throw malformed("Anthropic content block index 超出安全範圍")
        }
        return value
    }

    private mutating func appendText(_ value: String, reasoningField: Bool) throws {
        let bytes = value.utf8.count
        if reasoningField {
            guard reasoningBytes + bytes <= ProviderWireStreamLimits.maximumTextBytes else {
                throw malformed("Anthropic thinking 串流超過安全上限")
            }
            reasoning += value
            reasoningBytes += bytes
        } else {
            guard textBytes + bytes <= ProviderWireStreamLimits.maximumTextBytes else {
                throw malformed("Anthropic text 串流超過安全上限")
            }
            text += value
            textBytes += bytes
        }
    }

    private func malformed(_ detail: String) -> ProviderWireError {
        .malformedResponse(provider: AnthropicAgentWireAdapter.providerName, detail: detail)
    }
}

private struct AnthropicWireMessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        var content: [ContentBlock]
    }

    struct ContentBlock: Encodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: ProviderJSONValue?
        let toolUseID: String?
        let content: ProviderJSONValue?
        let isError: Bool?
        let source: ProviderJSONValue?

        private enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, content, source
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }

        static func text(_ value: String) -> Self {
            .init(
                type: "text", text: value, id: nil, name: nil, input: nil,
                toolUseID: nil, content: nil, isError: nil, source: nil
            )
        }

        static func image(_ value: ProviderWireImage) -> Self {
            .init(
                type: "image", text: nil, id: nil, name: nil, input: nil,
                toolUseID: nil, content: nil, isError: nil,
                source: .object([
                    "type": .string("base64"),
                    "media_type": .string(value.mimeType),
                    "data": .string(value.data.base64EncodedString())
                ])
            )
        }

        static func toolUse(_ call: ProviderWireToolCall) -> Self {
            .init(
                type: "tool_use", text: nil, id: call.id, name: call.name,
                input: call.arguments, toolUseID: nil, content: nil, isError: nil,
                source: nil
            )
        }

        static func toolResult(
            _ result: ProviderWireToolResult,
            images: [ProviderWireImage]
        ) -> Self {
            let content: ProviderJSONValue
            if images.isEmpty {
                content = .string(result.content)
            } else {
                var blocks: [ProviderJSONValue] = []
                if !result.content.isEmpty {
                    blocks.append(.object([
                        "type": .string("text"),
                        "text": .string(result.content)
                    ]))
                }
                blocks.append(contentsOf: images.map { image in
                    .object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(image.mimeType),
                            "data": .string(image.data.base64EncodedString())
                        ])
                    ])
                })
                content = .array(blocks)
            }
            return .init(
                type: "tool_result", text: nil, id: nil, name: nil, input: nil,
                toolUseID: result.callID, content: content,
                isError: result.isError ? true : nil, source: nil
            )
        }
    }

    struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: ProviderJSONValue

        init(_ source: ProviderWireToolDefinition) {
            name = source.name
            description = source.description
            inputSchema = source.inputSchema
        }

        private enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    let model: String
    let system: String?
    let messages: [Message]
    let tools: [Tool]?
    let stream: Bool
    let maxTokens: Int
    let temperature: Double?
    let topP: Double?
    let topK: Int?

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
    }

    static func messages(from source: [ProviderWireMessage]) -> [Message] {
        var result: [Message] = []
        for message in source where message.role != .system {
            let role: String
            var blocks: [ContentBlock] = []
            switch message.role {
            case .system:
                continue
            case .user:
                role = "user"
                if !message.text.isEmpty { blocks.append(.text(message.text)) }
                blocks.append(contentsOf: message.images.map(ContentBlock.image))
            case .assistant:
                role = "assistant"
                if !message.text.isEmpty { blocks.append(.text(message.text)) }
                blocks.append(contentsOf: message.toolCalls.map(ContentBlock.toolUse))
            case .tool:
                role = "user"
                if let toolResult = message.toolResult {
                    blocks.append(.toolResult(toolResult, images: message.images))
                } else if !message.text.isEmpty {
                    blocks.append(.text(message.text))
                    blocks.append(contentsOf: message.images.map(ContentBlock.image))
                }
            }
            if blocks.isEmpty { blocks.append(.text(" ")) }

            // Anthropic represents tool results as user content blocks. Grouping
            // adjacent results also preserves parallel tool calls in one turn.
            if result.last?.role == role {
                result[result.count - 1].content.append(contentsOf: blocks)
            } else {
                result.append(.init(role: role, content: blocks))
            }
        }
        return result
    }
}

private struct AnthropicWireMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: ProviderJSONValue?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage?

    private enum CodingKeys: String, CodingKey {
        case content, usage
        case stopReason = "stop_reason"
    }
}

private struct AnthropicWireStreamEvent: Decodable {
    struct Message: Decodable {
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: ProviderJSONValue?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let partialJSON: String?
        let stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case type, text, thinking
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct ErrorObject: Decodable {
        let message: String?
    }

    let type: String
    let index: Int?
    let message: Message?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let usage: Usage?
    let error: ErrorObject?

    private enum CodingKeys: String, CodingKey {
        case type, index, message, delta, usage, error
        case contentBlock = "content_block"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
