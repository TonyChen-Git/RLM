import Foundation

typealias ProviderJSONValue = JSONValue

extension JSONValue {
    static func parseJSONString(_ value: String) -> ProviderJSONValue? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProviderJSONValue.self, from: data)
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct ProviderWireToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: ProviderJSONValue
}

struct ProviderWireToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: ProviderJSONValue
}

struct ProviderWireToolResult: Equatable, Sendable {
    let callID: String
    let toolName: String
    let content: String
    let isError: Bool
}

struct ProviderWireImage: Equatable, Sendable {
    let attachmentID: UUID
    let mimeType: String
    let data: Data
}

struct ProviderWireMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    let role: Role
    let text: String
    let reasoning: String?
    let toolCalls: [ProviderWireToolCall]
    let toolResult: ProviderWireToolResult?
    let images: [ProviderWireImage]

    init(
        role: Role,
        text: String = "",
        reasoning: String? = nil,
        toolCalls: [ProviderWireToolCall] = [],
        toolResult: ProviderWireToolResult? = nil,
        images: [ProviderWireImage] = []
    ) {
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.images = images
    }
}

struct ProviderWireRequest: Equatable, Sendable {
    let model: String
    let messages: [ProviderWireMessage]
    let tools: [ProviderWireToolDefinition]
    let contextLength: Int
    let maxOutputTokens: Int
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let minP: Double?
    let repetitionPenalty: Double?
    let presencePenalty: Double?
    let thinkingEnabled: Bool?
    let reasoningEffort: ModelReasoningEffort?

    init(
        model: String,
        messages: [ProviderWireMessage],
        tools: [ProviderWireToolDefinition],
        contextLength: Int,
        maxOutputTokens: Int,
        temperature: Double?,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        thinkingEnabled: Bool? = nil,
        reasoningEffort: ModelReasoningEffort? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
    }
}

struct ProviderWireUsage: Equatable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
}

struct ProviderWireResponse: Equatable, Sendable {
    let text: String
    let reasoning: String?
    let toolCalls: [ProviderWireToolCall]
    let usage: ProviderWireUsage?
    let finishReason: String?
}

enum ProviderWireStreamDelta: Equatable, Sendable {
    case text(String)
    case reasoning(String)
}

enum ProviderWireStreamLimits {
    static let maximumResponseBytes = 32 * 1_024 * 1_024
    static let maximumErrorBytes = 256 * 1_024
    static let maximumLineBytes = 512 * 1_024
    static let maximumSSEFrameBytes = 4 * 1_024 * 1_024
    static let maximumTextBytes = 16 * 1_024 * 1_024
    static let maximumToolCalls = 128
    static let maximumArgumentsPerCall = 4 * 1_024 * 1_024
}

struct ProviderSSEFrame: Equatable, Sendable {
    let event: String?
    let data: Data
}

/// Incremental SSE framing shared by the OpenAI-compatible and Anthropic
/// adapters. The HTTP transport already removes CR/LF delimiters; this decoder
/// preserves multi-line `data:` fields and enforces a bounded event payload.
struct ProviderSSEDecoder: Sendable {
    private var event: String?
    private var dataLines: [Data] = []
    private var dataBytes = 0

    mutating func consume(line: Data, provider: String) throws -> ProviderSSEFrame? {
        guard line.count <= ProviderWireStreamLimits.maximumLineBytes else {
            throw malformed(provider, "SSE 單行超過安全上限")
        }
        if line.isEmpty { return dispatchFrame() }
        if line.first == 0x3A { return nil }

        let separator = line.firstIndex(of: 0x3A)
        let fieldData = separator.map { line[..<$0] } ?? line[...]
        var valueData: Data.SubSequence
        if let separator {
            valueData = line[line.index(after: separator)...]
            if valueData.first == 0x20 { valueData = valueData.dropFirst() }
        } else {
            valueData = line[line.endIndex..<line.endIndex]
        }
        guard let field = String(data: Data(fieldData), encoding: .utf8) else {
            throw malformed(provider, "SSE 欄位不是有效 UTF-8")
        }
        switch field {
        case "event":
            guard let value = String(data: Data(valueData), encoding: .utf8) else {
                throw malformed(provider, "SSE event 不是有效 UTF-8")
            }
            event = value
        case "data":
            let separatorBytes = dataLines.isEmpty ? 0 : 1
            guard dataBytes + separatorBytes + valueData.count
                    <= ProviderWireStreamLimits.maximumSSEFrameBytes else {
                throw malformed(provider, "SSE event 超過安全上限")
            }
            dataLines.append(Data(valueData))
            dataBytes += separatorBytes + valueData.count
        default:
            break
        }
        return nil
    }

    mutating func finish() -> ProviderSSEFrame? { dispatchFrame() }

    private mutating func dispatchFrame() -> ProviderSSEFrame? {
        defer {
            event = nil
            dataLines.removeAll(keepingCapacity: true)
            dataBytes = 0
        }
        guard !dataLines.isEmpty else { return nil }
        var payload = Data()
        payload.reserveCapacity(dataBytes)
        for (index, line) in dataLines.enumerated() {
            if index > 0 { payload.append(0x0A) }
            payload.append(line)
        }
        return ProviderSSEFrame(event: event, data: payload)
    }

    private func malformed(_ provider: String, _ detail: String) -> ProviderWireError {
        .malformedResponse(provider: provider, detail: detail)
    }
}

struct ProviderWireToolCallAccumulator: Sendable {
    private(set) var id = ""
    private(set) var name = ""
    private var argumentFragments = ""
    private var argumentFragmentBytes = 0
    private var completeArguments: ProviderJSONValue?

    mutating func acceptID(_ value: String?) {
        guard id.isEmpty,
              let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        id = value
    }

    mutating func appendName(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        if name.isEmpty {
            name = value
        } else if value.hasPrefix(name) {
            // Some compatible servers resend a cumulative function name,
            // while OpenAI-style streams normally send suffix fragments.
            name = value
        } else if value != name, !name.hasSuffix(value) {
            name += value
        }
    }

    mutating func appendArguments(_ value: String, provider: String) throws {
        let bytes = value.utf8.count
        guard argumentFragmentBytes + bytes
                <= ProviderWireStreamLimits.maximumArgumentsPerCall else {
            throw ProviderWireError.malformedResponse(
                provider: provider,
                detail: "串流 tool arguments 超過安全上限"
            )
        }
        argumentFragments += value
        argumentFragmentBytes += bytes
    }

    mutating func setArguments(_ value: ProviderJSONValue) {
        completeArguments = value
    }

    func finalized(provider: String, index: Int, idPrefix: String) throws -> ProviderWireToolCall {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw ProviderWireError.malformedResponse(
                provider: provider,
                detail: "串流 tool call \(index) 缺少名稱"
            )
        }
        let arguments: ProviderJSONValue
        if !argumentFragments.isEmpty {
            guard let parsed = ProviderJSONValue.parseJSONString(argumentFragments) else {
                throw ProviderWireError.malformedResponse(
                    provider: provider,
                    detail: "串流 tool call \(normalizedName) 的 arguments 不是完整 JSON"
                )
            }
            arguments = parsed
        } else {
            arguments = completeArguments ?? .emptyObject
        }
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderWireToolCall(
            id: normalizedID.isEmpty
                ? "\(idPrefix)_\(index)_\(UUID().uuidString.lowercased())"
                : normalizedID,
            name: normalizedName,
            arguments: arguments
        )
    }
}

struct ProviderWireCapabilities: Equatable, Sendable {
    let supportsTools: Bool
    let supportsVision: Bool
    let supportsStreaming: Bool
    let supportsParallelTools: Bool
    let supportsReasoning: Bool
    let supportsSystemPrompt: Bool
    let contextWindow: Int?
    let maxOutputTokens: Int?
}

enum ProviderNumericSafety {
    static func tokenCount(_ value: Int?) -> Int? {
        guard let value, (0...1_000_000_000).contains(value) else { return nil }
        return value
    }

    static func tokenSum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        let lhs = tokenCount(lhs)
        let rhs = tokenCount(rhs)
        guard lhs != nil || rhs != nil else { return nil }
        let (sum, overflow) = (lhs ?? 0).addingReportingOverflow(rhs ?? 0)
        guard !overflow, sum <= 1_000_000_000 else { return nil }
        return sum
    }

    static func capabilityLimit(_ value: Int?) -> Int? {
        guard let value, (1...10_000_000).contains(value) else { return nil }
        return value
    }
}

enum ProviderWireError: LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case missingModel
    case invalidRequest(String)
    case malformedResponse(provider: String, detail: String)
    case network(provider: String, detail: String)
    case http(provider: String, statusCode: Int, message: String?)
    case unsupportedTools(provider: String, model: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "模型伺服器網址格式不正確。"
        case .missingModel:
            return "請先選擇 Agent 要使用的模型。"
        case .invalidRequest(let detail):
            return "Agent 模型請求不完整：\(detail)"
        case .malformedResponse(let provider, let detail):
            return "\(provider) 回傳了無法解析的 Agent 回應：\(detail)"
        case .network(let provider, let detail):
            return "無法連線到 \(provider) Agent API：\(detail)"
        case .http(let provider, let statusCode, let message):
            if let message, !message.isEmpty {
                return "\(provider) Agent API 回傳 HTTP \(statusCode)：\(message)"
            }
            return "\(provider) Agent API 回傳 HTTP \(statusCode)。"
        case .unsupportedTools(let provider, let model, let detail):
            let suffix = detail.flatMap { $0.isEmpty ? nil : $0 }.map { "（\($0)）" } ?? ""
            return "\(provider) 的模型「\(model)」不支援原生 Agent tools。\(suffix)"
        }
    }
}
