import Foundation

enum OllamaAgentWireAdapter {
    static let providerName = "Ollama"

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
            provider: .ollama,
            route: ["api", "chat"]
        )
        let payload = OllamaWireChatRequest(
            model: input.model,
            messages: input.messages.map(OllamaWireChatRequest.Message.init),
            tools: input.tools.isEmpty ? nil : input.tools.map(OllamaWireChatRequest.Tool.init),
            stream: stream,
            think: input.thinkingEnabled,
            options: .init(
                numContext: max(1, input.contextLength),
                numPredict: max(1, input.maxOutputTokens),
                temperature: input.temperature,
                topP: input.topP,
                topK: input.topK,
                minP: input.minP,
                repeatPenalty: input.repetitionPenalty
            )
        )
        let body = try ProviderRequestBuilder.encoder().encode(payload)
        var request = try ProviderRequestBuilder.jsonRequest(
            url: url,
            provider: .ollama,
            apiKey: apiKey,
            timeout: settings.requestTimeout,
            body: body
        )
        if stream {
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        }
        return request
    }

    static func parseChatResponse(_ data: Data) throws -> ProviderWireResponse {
        let response: OllamaWireChatResponse
        do {
            response = try JSONDecoder().decode(OllamaWireChatResponse.self, from: data)
        } catch {
            throw ProviderWireError.malformedResponse(
                provider: providerName,
                detail: error.localizedDescription
            )
        }
        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            throw ProviderWireError.http(provider: providerName, statusCode: 200, message: error)
        }
        guard let message = response.message else {
            throw ProviderWireError.malformedResponse(provider: providerName, detail: "缺少 message")
        }

        let calls = (message.toolCalls ?? []).enumerated().map { index, call in
            ProviderWireToolCall(
                id: call.id?.nilIfBlank ?? "ollama_call_\(index)_\(UUID().uuidString.lowercased())",
                name: call.function.name,
                arguments: call.function.arguments.value
            )
        }
        let inputTokens = ProviderNumericSafety.tokenCount(response.promptEvalCount)
        let outputTokens = ProviderNumericSafety.tokenCount(response.evalCount)
        let usage: ProviderWireUsage?
        if inputTokens != nil || outputTokens != nil {
            usage = .init(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: ProviderNumericSafety.tokenSum(inputTokens, outputTokens)
            )
        } else {
            usage = nil
        }
        return ProviderWireResponse(
            text: message.content ?? "",
            reasoning: message.thinking?.nilIfBlank,
            toolCalls: calls,
            usage: usage,
            finishReason: response.doneReason
        )
    }

    static func makeCapabilitiesRequest(
        model: String,
        settings: AppSettings,
        apiKey: String?
    ) throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderWireError.missingModel
        }
        let url = try ProviderRequestBuilder.routeURL(
            endpoint: settings.endpoint,
            provider: .ollama,
            route: ["api", "show"]
        )
        let body = try ProviderRequestBuilder.encoder().encode(
            OllamaWireShowRequest(model: model, verbose: false)
        )
        return try ProviderRequestBuilder.jsonRequest(
            url: url,
            provider: .ollama,
            apiKey: apiKey,
            timeout: settings.requestTimeout,
            body: body
        )
    }

    /// Returns nil when an older Ollama server omitted capability metadata.
    /// The concrete provider then uses provider-level defaults; model names are
    /// deliberately never inspected.
    static func parseCapabilities(_ data: Data) -> ProviderWireCapabilities? {
        guard let response = try? JSONDecoder().decode(OllamaWireShowResponse.self, from: data),
              let rawCapabilities = response.capabilities else { return nil }
        let capabilities = Set(rawCapabilities.map { $0.lowercased() })
        let supportsTools = capabilities.contains("tools") || capabilities.contains("tool")
        let contextWindow = response.modelInfo?
            .filter { key, _ in
                let key = key.lowercased()
                return key == "context_length" || key.hasSuffix(".context_length")
            }
            .compactMap { ProviderNumericSafety.capabilityLimit($0.value.intValue) }
            .max()
        return ProviderWireCapabilities(
            supportsTools: supportsTools,
            supportsVision: capabilities.contains("vision"),
            supportsStreaming: true,
            supportsParallelTools: supportsTools,
            supportsReasoning: capabilities.contains("thinking") || capabilities.contains("reasoning"),
            supportsSystemPrompt: true,
            contextWindow: contextWindow,
            maxOutputTokens: nil
        )
    }

}

struct OllamaAgentStreamAccumulator: Sendable {
    private var text = ""
    private var textBytes = 0
    private var reasoning = ""
    private var reasoningBytes = 0
    private var calls: [Int: ProviderWireToolCallAccumulator] = [:]
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var finishReason: String?
    private var sawDone = false

    mutating func consume(line: Data) throws -> [ProviderWireStreamDelta] {
        guard !line.isEmpty else { return [] }
        let chunk: OllamaWireChatStreamChunk
        do {
            chunk = try JSONDecoder().decode(OllamaWireChatStreamChunk.self, from: line)
        } catch {
            throw ProviderWireError.malformedResponse(
                provider: OllamaAgentWireAdapter.providerName,
                detail: error.localizedDescription
            )
        }
        if let error = chunk.error?.nilIfBlank {
            throw ProviderWireError.http(
                provider: OllamaAgentWireAdapter.providerName,
                statusCode: 200,
                message: error
            )
        }

        var deltas: [ProviderWireStreamDelta] = []
        if let value = chunk.message?.content, !value.isEmpty {
            try Self.appendBounded(
                value,
                to: &text,
                byteCount: &textBytes,
                provider: OllamaAgentWireAdapter.providerName,
                field: "content"
            )
            deltas.append(.text(value))
        }
        if let value = chunk.message?.thinking, !value.isEmpty {
            try Self.appendBounded(
                value,
                to: &reasoning,
                byteCount: &reasoningBytes,
                provider: OllamaAgentWireAdapter.providerName,
                field: "thinking"
            )
            deltas.append(.reasoning(value))
        }
        if let toolCalls = chunk.message?.toolCalls {
            guard toolCalls.count <= ProviderWireStreamLimits.maximumToolCalls else {
                throw malformed("單一 Ollama chunk 的 tool calls 過多")
            }
            for (position, call) in toolCalls.enumerated() {
                let index = call.function.index ?? position
                guard (0..<ProviderWireStreamLimits.maximumToolCalls).contains(index) else {
                    throw malformed("Ollama tool call index 超出安全範圍")
                }
                var builder = calls[index] ?? ProviderWireToolCallAccumulator()
                builder.acceptID(call.id)
                builder.appendName(call.function.name)
                if let arguments = call.function.arguments {
                    if case .string(let fragment) = arguments {
                        try builder.appendArguments(
                            fragment,
                            provider: OllamaAgentWireAdapter.providerName
                        )
                    } else {
                        builder.setArguments(arguments)
                    }
                }
                calls[index] = builder
            }
        }
        if let value = chunk.promptEvalCount { inputTokens = ProviderNumericSafety.tokenCount(value) }
        if let value = chunk.evalCount { outputTokens = ProviderNumericSafety.tokenCount(value) }
        if let value = chunk.doneReason?.nilIfBlank { finishReason = value }
        if chunk.done == true { sawDone = true }
        return deltas
    }

    func finish() throws -> ProviderWireResponse {
        guard sawDone else { throw malformed("Ollama NDJSON 在 done=true 前中斷") }
        let finalizedCalls = try calls.keys.sorted().map { index in
            try calls[index]!.finalized(
                provider: OllamaAgentWireAdapter.providerName,
                index: index,
                idPrefix: "ollama_call"
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
            toolCalls: finalizedCalls,
            usage: usage,
            finishReason: finishReason
        )
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
                detail: "Ollama 串流 \(field) 超過安全上限"
            )
        }
        destination += value
        byteCount += bytes
    }

    private func malformed(_ detail: String) -> ProviderWireError {
        .malformedResponse(provider: OllamaAgentWireAdapter.providerName, detail: detail)
    }
}

private struct OllamaWireChatRequest: Encodable {
    struct Options: Encodable {
        let numContext: Int
        let numPredict: Int
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let minP: Double?
        let repeatPenalty: Double?

        private enum CodingKeys: String, CodingKey {
            case numContext = "num_ctx"
            case numPredict = "num_predict"
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case minP = "min_p"
            case repeatPenalty = "repeat_penalty"
        }
    }

    struct Message: Encodable {
        let role: String
        let content: String
        let toolName: String?
        let toolCalls: [ToolCall]?
        let images: [String]?

        init(_ source: ProviderWireMessage) {
            role = source.role.rawValue
            content = source.toolResult?.content ?? source.text
            toolName = source.toolResult?.toolName
            toolCalls = source.toolCalls.isEmpty
                ? nil
                : source.toolCalls.enumerated().map { index, call in
                    ToolCall(
                        type: "function",
                        function: .init(index: index, name: call.name, arguments: call.arguments)
                    )
                }
            images = source.images.isEmpty
                ? nil
                : source.images.map { $0.data.base64EncodedString() }
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, images
            case toolName = "tool_name"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Encodable {
        struct Function: Encodable {
            let index: Int
            let name: String
            let arguments: ProviderJSONValue
        }

        let type: String
        let function: Function
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
    let stream: Bool
    let think: Bool?
    let options: Options
}

private struct OllamaWireChatResponse: Decodable {
    struct Message: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String
                let arguments: FlexibleProviderArguments
            }

            let id: String?
            let function: Function
        }

        let content: String?
        let thinking: String?
        let toolCalls: [ToolCall]?

        private enum CodingKeys: String, CodingKey {
            case content, thinking
            case toolCalls = "tool_calls"
        }
    }

    let message: Message?
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case message, error
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

private struct OllamaWireChatStreamChunk: Decodable {
    struct Message: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let index: Int?
                let name: String?
                let arguments: ProviderJSONValue?
            }

            let id: String?
            let function: Function
        }

        let content: String?
        let thinking: String?
        let toolCalls: [ToolCall]?

        private enum CodingKeys: String, CodingKey {
            case content, thinking
            case toolCalls = "tool_calls"
        }
    }

    let message: Message?
    let done: Bool?
    let doneReason: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case message, done, error
        case doneReason = "done_reason"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
    }
}

private struct OllamaWireShowRequest: Encodable {
    let model: String
    let verbose: Bool
}

private struct OllamaWireShowResponse: Decodable {
    let capabilities: [String]?
    let modelInfo: [String: ProviderJSONValue]?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case modelInfo = "model_info"
    }
}

struct FlexibleProviderArguments: Decodable {
    let value: ProviderJSONValue

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            value = ProviderJSONValue.parseJSONString(raw) ?? .string(raw)
        } else {
            value = try container.decode(ProviderJSONValue.self)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
