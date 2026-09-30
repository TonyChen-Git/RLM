import Foundation

enum OpenAICompatibleAgentWireAdapter {
    static let providerName = "OpenAI 相容"

    static func makeChatRequest(
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
            provider: .openAICompatible,
            route: ["chat", "completions"]
        )
        let payload = try OpenAIWireChatRequest(
            model: input.model,
            messages: leadingSystemMessages(input.messages).map(OpenAIWireChatRequest.Message.init),
            tools: input.tools.isEmpty ? nil : input.tools.map(OpenAIWireChatRequest.Tool.init),
            toolChoice: input.tools.isEmpty ? nil : "auto",
            stream: stream,
            maxTokens: settings.resolvedBackend == .openAI
                && input.reasoningEffort != nil ? nil : max(1, input.maxOutputTokens),
            maxCompletionTokens: settings.resolvedBackend == .openAI
                && input.reasoningEffort != nil ? max(1, input.maxOutputTokens) : nil,
            temperature: input.temperature,
            topP: input.topP,
            topK: input.topK,
            minP: input.minP,
            repetitionPenalty: input.repetitionPenalty,
            presencePenalty: input.presencePenalty,
            reasoningEffort: input.reasoningEffort?.rawValue,
            chatTemplateKwargs: (settings.resolvedBackend == .mlx
                || settings.resolvedBackend == .lmStudio)
                && input.thinkingEnabled != nil
                ? .init(enableThinking: input.thinkingEnabled == true) : nil
        )
        let body = try ProviderRequestBuilder.encoder().encode(payload)
        var request = try ProviderRequestBuilder.jsonRequest(
            url: url,
            provider: .openAICompatible,
            apiKey: apiKey,
            timeout: settings.requestTimeout,
            body: body
        )
        if stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return request
    }

    /// Chat templates such as Qwen require one system turn before all ordinary
    /// turns. ContextManager keeps runtime context in separate system messages;
    /// combine them only at this provider's wire boundary, without reordering
    /// user, assistant, or tool turns.
    private static func leadingSystemMessages(
        _ messages: [ProviderWireMessage]
    ) -> [ProviderWireMessage] {
        let systemContents = messages.filter { $0.role == .system }.map(\.text)
        guard !systemContents.isEmpty else { return messages }
        return [ProviderWireMessage(role: .system, text: systemContents.joined(separator: "\n\n"))]
            + messages.filter { $0.role != .system }
    }

    static func parseChatResponse(_ data: Data) throws -> ProviderWireResponse {
        let response: OpenAIWireChatResponse
        do {
            response = try JSONDecoder().decode(OpenAIWireChatResponse.self, from: data)
        } catch {
            throw ProviderWireError.malformedResponse(
                provider: providerName,
                detail: error.localizedDescription
            )
        }
        guard let choice = response.choices.first else {
            throw ProviderWireError.malformedResponse(provider: providerName, detail: "choices 是空的")
        }
        let calls = (choice.message.toolCalls ?? []).enumerated().map { index, call in
            ProviderWireToolCall(
                id: call.id?.nilIfBlank ?? "openai_call_\(index)_\(UUID().uuidString.lowercased())",
                name: call.function.name,
                arguments: call.function.arguments.value
            )
        }
        let usage = response.usage.map {
            ProviderWireUsage(
                inputTokens: ProviderNumericSafety.tokenCount($0.promptTokens),
                outputTokens: ProviderNumericSafety.tokenCount($0.completionTokens),
                totalTokens: ProviderNumericSafety.tokenCount($0.totalTokens)
            )
        }
        return ProviderWireResponse(
            text: choice.message.content?.text ?? "",
            reasoning: choice.message.reasoningText?.nilIfBlank,
            toolCalls: calls,
            usage: usage,
            finishReason: choice.finishReason
        )
    }
}

struct OpenAICompatibleAgentStreamAccumulator: Sendable {
    private var sse = ProviderSSEDecoder()
    private var text = ""
    private var textBytes = 0
    private var reasoning = ""
    private var reasoningBytes = 0
    private var calls: [Int: ProviderWireToolCallAccumulator] = [:]
    private var usage: ProviderWireUsage?
    private var finishReason: String?
    private var sawDone = false

    mutating func consume(line: Data) throws -> [ProviderWireStreamDelta] {
        guard let frame = try sse.consume(
            line: line,
            provider: OpenAICompatibleAgentWireAdapter.providerName
        ) else { return [] }
        return try process(frame)
    }

    mutating func finish() throws -> ProviderWireResponse {
        if let frame = sse.finish() { _ = try process(frame) }
        guard sawDone || finishReason != nil else {
            throw malformed("OpenAI-compatible SSE 在完成事件前中斷")
        }
        let finalizedCalls = try calls.keys.sorted().map { index in
            try calls[index]!.finalized(
                provider: OpenAICompatibleAgentWireAdapter.providerName,
                index: index,
                idPrefix: "openai_call"
            )
        }
        return ProviderWireResponse(
            text: text,
            reasoning: reasoning.nilIfBlank,
            toolCalls: finalizedCalls,
            usage: usage,
            finishReason: finishReason
        )
    }

    private mutating func process(_ frame: ProviderSSEFrame) throws -> [ProviderWireStreamDelta] {
        guard let payload = String(data: frame.data, encoding: .utf8) else {
            throw malformed("SSE data 不是有效 UTF-8")
        }
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            sawDone = true
            return []
        }

        let chunk: OpenAIWireChatStreamChunk
        do {
            chunk = try JSONDecoder().decode(OpenAIWireChatStreamChunk.self, from: frame.data)
        } catch {
            throw malformed(error.localizedDescription)
        }
        if frame.event == "error" || chunk.error != nil {
            throw ProviderWireError.http(
                provider: OpenAICompatibleAgentWireAdapter.providerName,
                statusCode: 200,
                message: chunk.error?.message ?? "stream error"
            )
        }
        if let wireUsage = chunk.usage {
            usage = ProviderWireUsage(
                inputTokens: ProviderNumericSafety.tokenCount(wireUsage.promptTokens),
                outputTokens: ProviderNumericSafety.tokenCount(wireUsage.completionTokens),
                totalTokens: ProviderNumericSafety.tokenCount(wireUsage.totalTokens)
            )
        }

        var deltas: [ProviderWireStreamDelta] = []
        for choice in chunk.choices ?? [] where choice.index == nil || choice.index == 0 {
            if let value = choice.delta?.content?.text, !value.isEmpty {
                try Self.appendBounded(
                    value,
                    to: &text,
                    byteCount: &textBytes,
                    provider: OpenAICompatibleAgentWireAdapter.providerName,
                    field: "content"
                )
                deltas.append(.text(value))
            }
            if let value = choice.delta?.reasoningText, !value.isEmpty {
                try Self.appendBounded(
                    value,
                    to: &reasoning,
                    byteCount: &reasoningBytes,
                    provider: OpenAICompatibleAgentWireAdapter.providerName,
                    field: "reasoning"
                )
                deltas.append(.reasoning(value))
            }
            if let toolCalls = choice.delta?.toolCalls {
                guard toolCalls.count <= ProviderWireStreamLimits.maximumToolCalls else {
                    throw malformed("單一 OpenAI chunk 的 tool calls 過多")
                }
                for (position, call) in toolCalls.enumerated() {
                    let index = call.index ?? position
                    guard (0..<ProviderWireStreamLimits.maximumToolCalls).contains(index) else {
                        throw malformed("OpenAI tool call index 超出安全範圍")
                    }
                    var builder = calls[index] ?? ProviderWireToolCallAccumulator()
                    builder.acceptID(call.id)
                    builder.appendName(call.function?.name)
                    if let arguments = call.function?.arguments {
                        try builder.appendArguments(
                            arguments,
                            provider: OpenAICompatibleAgentWireAdapter.providerName
                        )
                    }
                    calls[index] = builder
                }
            }
            if let value = choice.finishReason?.nilIfBlank { finishReason = value }
        }
        return deltas
    }

    private static func appendBounded(
        _ value: String,
        to destination: inout String,
        byteCount: inout Int,
        provider: String,
        field: String
    ) throws {
        let bytes = value.utf8.count
        guard byteCount + bytes <= ProviderWireStreamLimits.maximumTextBytes else {
            throw ProviderWireError.malformedResponse(
                provider: provider,
                detail: "串流 \(field) 超過安全上限"
            )
        }
        destination += value
        byteCount += bytes
    }

    private func malformed(_ detail: String) -> ProviderWireError {
        .malformedResponse(
            provider: OpenAICompatibleAgentWireAdapter.providerName,
            detail: detail
        )
    }
}

private struct OpenAIWireChatRequest: Encodable {
    struct Message: Encodable {
        enum Content: Encodable {
            case text(String)
            case blocks([ContentBlock])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value): try container.encode(value)
                case .blocks(let value): try container.encode(value)
                }
            }
        }

        struct ContentBlock: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            private enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }

            static func text(_ value: String) -> Self {
                .init(type: "text", text: value, imageURL: nil)
            }

            static func image(_ value: ProviderWireImage) -> Self {
                .init(
                    type: "image_url",
                    text: nil,
                    imageURL: .init(
                        url: "data:\(value.mimeType);base64,\(value.data.base64EncodedString())"
                    )
                )
            }
        }

        let role: String
        let content: Content
        let toolCalls: [ToolCall]?
        let toolCallID: String?
        let name: String?

        init(_ source: ProviderWireMessage) throws {
            role = source.role.rawValue
            let text = source.toolResult?.content ?? source.text
            if source.images.isEmpty {
                content = .text(text)
            } else {
                var blocks: [ContentBlock] = []
                if !text.isEmpty { blocks.append(.text(text)) }
                blocks.append(contentsOf: source.images.map(ContentBlock.image))
                content = .blocks(blocks)
            }
            toolCalls = try source.toolCalls.isEmpty ? nil : source.toolCalls.map(ToolCall.init)
            toolCallID = source.toolResult?.callID
            name = source.toolResult?.toolName
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, name
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
    }

    struct ToolCall: Encodable {
        struct Function: Encodable {
            let name: String
            let arguments: String
        }

        let id: String
        let type: String
        let function: Function

        init(_ source: ProviderWireToolCall) throws {
            id = source.id
            type = "function"
            function = .init(name: source.name, arguments: try source.arguments.jsonString())
        }
    }

    struct Tool: Encodable {
        struct Function: Encodable {
            let name: String
            let description: String
            let parameters: ProviderJSONValue
        }

        let type: String
        let function: Function

        init(_ source: ProviderWireToolDefinition) {
            type = "function"
            function = .init(
                name: source.name,
                description: source.description,
                parameters: source.inputSchema
            )
        }
    }

    let model: String
    let messages: [Message]
    let tools: [Tool]?
    let toolChoice: String?
    let stream: Bool
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let minP: Double?
    let repetitionPenalty: Double?
    let presencePenalty: Double?
    let reasoningEffort: String?
    let chatTemplateKwargs: ChatTemplateKwargs?

    struct ChatTemplateKwargs: Encodable {
        let enableThinking: Bool

        private enum CodingKeys: String, CodingKey {
            case enableThinking = "enable_thinking"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case toolChoice = "tool_choice"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case presencePenalty = "presence_penalty"
        case reasoningEffort = "reasoning_effort"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct OpenAIWireChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String
                    let arguments: FlexibleProviderArguments
                }

                let id: String?
                let function: Function
            }

            let content: OpenAIWireFlexibleText?
            let reasoningContent: OpenAIWireFlexibleText?
            let reasoning: OpenAIWireFlexibleText?
            let toolCalls: [ToolCall]?

            var reasoningText: String? {
                if let value = reasoningContent?.text, !value.isEmpty { return value }
                if let value = reasoning?.text, !value.isEmpty { return value }
                return nil
            }

            private enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let choices: [Choice]
    let usage: Usage?
}

private struct OpenAIWireChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: OpenAIWireFlexibleText?
            let reasoningContent: OpenAIWireFlexibleText?
            let reasoning: OpenAIWireFlexibleText?
            let toolCalls: [ToolCall]?

            var reasoningText: String? {
                if let value = reasoningContent?.text, !value.isEmpty { return value }
                if let value = reasoning?.text, !value.isEmpty { return value }
                return nil
            }

            private enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        let index: Int?
        let delta: Delta?
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct ErrorObject: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let usage: Usage?
    let error: ErrorObject?
}

private struct OpenAIWireFlexibleText: Decodable {
    struct Block: Decodable {
        let text: String?
        let content: String?
    }

    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            text = ""
        } else if let value = try? container.decode(String.self) {
            text = value
        } else if let blocks = try? container.decode([Block].self) {
            text = blocks.compactMap { $0.text ?? $0.content }.joined()
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected text or text blocks")
            )
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
