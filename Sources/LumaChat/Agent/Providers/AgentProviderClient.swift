import Foundation

/// Factory entry point used by AgentRuntime. It consumes the same active
/// connection, selected model, endpoint and Keychain value as Chat mode.
enum AgentModelProviderFactory {
    static func make(
        settings: AppSettings,
        apiKey: String?,
        visionCapabilityOverride: Bool? = nil,
        session: URLSession? = nil
    ) -> any AgentModelProvider {
        switch settings.provider {
        case .ollama:
            return OllamaAgentProvider(
                settings: settings,
                apiKey: apiKey,
                visionCapabilityOverride: visionCapabilityOverride,
                session: session
            )
        case .openAICompatible:
            return OpenAICompatibleAgentProvider(
                settings: settings,
                apiKey: apiKey,
                visionCapabilityOverride: visionCapabilityOverride,
                session: session
            )
        case .anthropic:
            return AnthropicAgentProvider(
                settings: settings,
                apiKey: apiKey,
                visionCapabilityOverride: visionCapabilityOverride,
                session: session
            )
        }
    }
}

struct OllamaAgentProvider: AgentModelProvider {
    let id = ProviderKind.ollama.rawValue
    private let client: AgentProviderClient

    init(
        settings: AppSettings,
        apiKey: String?,
        visionCapabilityOverride: Bool? = nil,
        session: URLSession? = nil
    ) {
        client = AgentProviderClient(
            kind: .ollama,
            settings: settings,
            apiKey: apiKey,
            visionCapabilityOverride: visionCapabilityOverride,
            session: session
        )
    }

    func capabilities(for model: String) async -> ModelCapabilities {
        await client.capabilities(for: model)
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        try await client.generate(request: request)
    }

    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        client.stream(request: request)
    }
}

struct OpenAICompatibleAgentProvider: AgentModelProvider {
    let id = ProviderKind.openAICompatible.rawValue
    private let client: AgentProviderClient

    init(
        settings: AppSettings,
        apiKey: String?,
        visionCapabilityOverride: Bool? = nil,
        session: URLSession? = nil
    ) {
        client = AgentProviderClient(
            kind: .openAICompatible,
            settings: settings,
            apiKey: apiKey,
            visionCapabilityOverride: visionCapabilityOverride,
            session: session
        )
    }

    func capabilities(for model: String) async -> ModelCapabilities {
        await client.capabilities(for: model)
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        try await client.generate(request: request)
    }

    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        client.stream(request: request)
    }
}

struct AnthropicAgentProvider: AgentModelProvider {
    let id = ProviderKind.anthropic.rawValue
    private let client: AgentProviderClient

    init(
        settings: AppSettings,
        apiKey: String?,
        visionCapabilityOverride: Bool? = nil,
        session: URLSession? = nil
    ) {
        client = AgentProviderClient(
            kind: .anthropic,
            settings: settings,
            apiKey: apiKey,
            visionCapabilityOverride: visionCapabilityOverride,
            session: session
        )
    }

    func capabilities(for model: String) async -> ModelCapabilities {
        await client.capabilities(for: model)
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        try await client.generate(request: request)
    }

    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        client.stream(request: request)
    }
}

/// Agent-specific native-tool client. Classic Chat's `LLMClient` remains a
/// separate code path, while Agent turns can use bounded NDJSON/SSE streaming.
private struct AgentProviderClient: Sendable {
    private let kind: ProviderKind
    private let settings: AppSettings
    private let apiKey: String?
    private let visionCapabilityOverride: Bool?
    private let transport: ProviderHTTPTransport
    private let capabilityCache: AgentProviderCapabilityCache

    init(
        kind: ProviderKind,
        settings: AppSettings,
        apiKey: String?,
        visionCapabilityOverride: Bool?,
        session: URLSession?
    ) {
        self.kind = kind
        self.settings = settings
        self.apiKey = apiKey
        self.visionCapabilityOverride = visionCapabilityOverride
        transport = ProviderHTTPTransport(session: session)
        capabilityCache = AgentProviderCapabilityCache()
    }

    func capabilities(for requestedModel: String) async -> ModelCapabilities {
        let model = resolvedModel(requestedModel)
        switch kind {
        case .ollama:
            return await ollamaCapabilityResolution(for: model).provider
        case .openAICompatible, .anthropic:
            return applyingVisionOverride(to: providerCapabilities(for: kind, model: model))
        }
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        let (model, wireRequest) = try await preparedRequest(request)

        let wireResponse: ProviderWireResponse
        switch kind {
        case .ollama:
            let urlRequest = try OllamaAgentWireAdapter.makeChatRequest(
                wireRequest,
                settings: settings,
                apiKey: apiKey
            )
            let data = try await transport.data(
                for: urlRequest,
                provider: OllamaAgentWireAdapter.providerName,
                model: model,
                requestedTools: !request.tools.isEmpty
            )
            wireResponse = try OllamaAgentWireAdapter.parseChatResponse(data)
        case .openAICompatible:
            let urlRequest = try OpenAICompatibleAgentWireAdapter.makeChatRequest(
                wireRequest,
                settings: settings,
                apiKey: apiKey
            )
            let data = try await transport.data(
                for: urlRequest,
                provider: OpenAICompatibleAgentWireAdapter.providerName,
                model: model,
                requestedTools: !request.tools.isEmpty
            )
            wireResponse = try OpenAICompatibleAgentWireAdapter.parseChatResponse(data)
        case .anthropic:
            let urlRequest = try AnthropicAgentWireAdapter.makeMessagesRequest(
                wireRequest,
                settings: settings,
                apiKey: apiKey
            )
            let data = try await transport.data(
                for: urlRequest,
                provider: AnthropicAgentWireAdapter.providerName,
                model: model,
                requestedTools: !request.tools.isEmpty
            )
            wireResponse = try AnthropicAgentWireAdapter.parseMessagesResponse(data)
        }

        return modelResponse(wireResponse)
    }

    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let producer = Task {
                do {
                    let (model, wireRequest) = try await preparedRequest(request)
                    let wireResponse: ProviderWireResponse
                    switch kind {
                    case .ollama:
                        let urlRequest = try OllamaAgentWireAdapter.makeChatRequest(
                            wireRequest,
                            settings: settings,
                            apiKey: apiKey,
                            stream: true
                        )
                        var accumulator = OllamaAgentStreamAccumulator()
                        try await transport.streamLines(
                            for: urlRequest,
                            provider: OllamaAgentWireAdapter.providerName,
                            model: model,
                            requestedTools: !request.tools.isEmpty
                        ) { line in
                            for delta in try accumulator.consume(line: line) {
                                try Self.emit(delta, to: continuation)
                            }
                        }
                        wireResponse = try accumulator.finish()
                    case .openAICompatible:
                        let urlRequest = try OpenAICompatibleAgentWireAdapter.makeChatRequest(
                            wireRequest,
                            settings: settings,
                            apiKey: apiKey,
                            stream: true
                        )
                        var accumulator = OpenAICompatibleAgentStreamAccumulator()
                        try await transport.streamLines(
                            for: urlRequest,
                            provider: OpenAICompatibleAgentWireAdapter.providerName,
                            model: model,
                            requestedTools: !request.tools.isEmpty
                        ) { line in
                            for delta in try accumulator.consume(line: line) {
                                try Self.emit(delta, to: continuation)
                            }
                        }
                        wireResponse = try accumulator.finish()
                    case .anthropic:
                        let urlRequest = try AnthropicAgentWireAdapter.makeMessagesRequest(
                            wireRequest,
                            settings: settings,
                            apiKey: apiKey,
                            stream: true
                        )
                        var accumulator = AnthropicAgentStreamAccumulator()
                        try await transport.streamLines(
                            for: urlRequest,
                            provider: AnthropicAgentWireAdapter.providerName,
                            model: model,
                            requestedTools: !request.tools.isEmpty
                        ) { line in
                            for delta in try accumulator.consume(line: line) {
                                try Self.emit(delta, to: continuation)
                            }
                        }
                        wireResponse = try accumulator.finish()
                    }
                    try Task.checkCancellation()
                    try Self.emit(.completed(modelResponse(wireResponse)), to: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private func preparedRequest(
        _ request: AgentModelRequest
    ) async throws -> (String, ProviderWireRequest) {
        let model = resolvedModel(request.model)
        guard !model.isEmpty else { throw ProviderWireError.missingModel }

        // Validate and materialize all request-owned image data before any
        // advisory capability lookup can touch the network. Invalid or
        // unreferenced payloads must fail closed without issuing /api/show.
        try AgentImageAttachmentLimits.validate(request.imagePayloads)
        let preparedMessages = try wireMessages(
            request.messages,
            payloads: request.imagePayloads
        )

        let ollamaResolution: OllamaCapabilityResolution?
        if kind == .ollama {
            ollamaResolution = await ollamaCapabilityResolution(for: model)
        } else {
            ollamaResolution = nil
        }

        if !request.tools.isEmpty, let ollamaResolution {
            guard ollamaResolution.provider.supportsTools else {
                throw ProviderWireError.unsupportedTools(
                    provider: OllamaAgentWireAdapter.providerName,
                    model: model,
                    detail: "Ollama /api/show metadata does not include tools"
                )
            }
        }

        var parameterCapabilities = ModelParameterRecommendationEngine.capabilities(
            for: ModelParameterRoute(
                settings: settings,
                useCase: .agent,
                modelID: model
            )
        )
        if let discovered = ollamaResolution?.modelParameters {
            if let contextWindow = discovered.modelMaximumContextTokens,
               contextWindow > 0 {
                parameterCapabilities.modelMaximumContextTokens = min(
                    parameterCapabilities.modelMaximumContextTokens,
                    contextWindow
                )
            }
            if let maxOutputTokens = discovered.maximumOutputTokens,
               maxOutputTokens > 0 {
                parameterCapabilities.maximumOutputTokens = min(
                    parameterCapabilities.maximumOutputTokens,
                    maxOutputTokens
                )
            }
            // A context-only response from an older Ollama build is not
            // evidence that the model lacks thinking support. Only an actual
            // capabilities array may override the centralized family rule.
            if let supportsThinking = discovered.supportsThinking {
                parameterCapabilities.supportsThinking = supportsThinking
            }
        }
        let safeContext = min(
            parameterCapabilities.maximumContextTokens,
            max(1, request.contextWindowTokens ?? settings.contextLength)
        )
        let safeOutput = min(
            min(parameterCapabilities.maximumOutputTokens, safeContext),
            max(1, request.maxOutputTokens)
        )

        return (
            model,
            ProviderWireRequest(
                model: model,
                messages: preparedMessages,
                tools: request.tools.map {
                    ProviderWireToolDefinition(
                        name: $0.name,
                        description: $0.description,
                        inputSchema: $0.inputSchema
                    )
                },
                contextLength: safeContext,
                maxOutputTokens: safeOutput,
                temperature: parameterCapabilities.supportsTemperature
                    ? validTemperature(request.temperature) : nil,
                topP: parameterCapabilities.supportsTopP
                    ? validUnitInterval(request.topP) : nil,
                topK: parameterCapabilities.supportsTopK
                    ? request.topK.map { min(100_000, max(0, $0)) } : nil,
                minP: parameterCapabilities.supportsMinP
                    ? validUnitInterval(request.minP) : nil,
                repetitionPenalty: parameterCapabilities.supportsRepetitionPenalty
                    ? validRepetitionPenalty(request.repetitionPenalty) : nil,
                presencePenalty: parameterCapabilities.supportsPresencePenalty
                    ? validPresencePenalty(request.presencePenalty) : nil,
                thinkingEnabled: parameterCapabilities.supportsThinking
                    ? request.thinkingEnabled : nil,
                reasoningEffort: request.reasoningEffort.flatMap { effort in
                    parameterCapabilities.supportedReasoningEfforts.contains(effort)
                        ? effort : nil
                }
            )
        )
    }

    private func modelResponse(_ wireResponse: ProviderWireResponse) -> AgentModelResponse {
        AgentModelResponse(
            content: wireResponse.text,
            reasoningSummary: wireResponse.reasoning,
            toolCalls: wireResponse.toolCalls.map {
                AgentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            },
            finishReason: wireResponse.finishReason,
            usage: wireResponse.usage.map {
                AgentTokenUsage(
                    inputTokens: ProviderNumericSafety.tokenCount($0.inputTokens),
                    outputTokens: ProviderNumericSafety.tokenCount($0.outputTokens),
                    totalTokens: ProviderNumericSafety.tokenCount($0.totalTokens)
                )
            }
        )
    }

    private static func emit(
        _ delta: ProviderWireStreamDelta,
        to continuation: AsyncThrowingStream<AgentModelStreamEvent, Error>.Continuation
    ) throws {
        switch delta {
        case .text(let value):
            try emit(.contentDelta(value), to: continuation)
        case .reasoning(let value):
            try emit(.reasoningDelta(value), to: continuation)
        }
    }

    private static func emit(
        _ event: AgentModelStreamEvent,
        to continuation: AsyncThrowingStream<AgentModelStreamEvent, Error>.Continuation
    ) throws {
        switch continuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            throw ProviderWireError.malformedResponse(
                provider: "Agent stream",
                detail: "串流消費速度不足；已拒絕遺失模型輸出"
            )
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw ProviderWireError.malformedResponse(
                provider: "Agent stream",
                detail: "未知的串流緩衝狀態"
            )
        }
    }

    private func resolvedModel(_ requested: String) -> String {
        let value = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
            ? settings.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : value
    }

    private func validTemperature(_ value: Double) -> Double {
        if value.isFinite { return min(2, max(0, value)) }
        if settings.temperature.isFinite { return min(2, max(0, settings.temperature)) }
        return 0.7
    }

    private func validUnitInterval(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    private func validRepetitionPenalty(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(2, max(0, value))
    }

    private func validPresencePenalty(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(2, max(-2, value))
    }

    private func providerCapabilities(
        for provider: ProviderKind,
        model: String
    ) -> ModelCapabilities {
        // `AppSettings.contextLength` is the legacy user preference, not a
        // backend capability. Treating it as a discovered ceiling would clamp
        // every new per-model profile (often to the old 8K default) before the
        // request reached ContextManager. Use the central backend/model ceiling
        // here; an Ollama /api/show result can still replace it with metadata.
        let parameterContext = ModelParameterRecommendationEngine.capabilities(
            for: ModelParameterRoute(
                settings: settings,
                useCase: .agent,
                modelID: model
            )
        ).maximumContextTokens
        switch provider {
        case .ollama:
            return ModelCapabilities(
                supportsTools: true,
                supportsVision: false,
                supportsStreaming: true,
                supportsParallelTools: true,
                supportsReasoning: false,
                supportsSystemPrompt: true,
                contextWindow: parameterContext,
                maxOutputTokens: nil
            )
        case .openAICompatible:
            return ModelCapabilities(
                supportsTools: true,
                // The wire protocol can encode images, but it says nothing
                // about an arbitrary compatible model's input modalities.
                // Automatic mode therefore fails closed; users can explicitly
                // enable vision for a model they know accepts image content.
                supportsVision: false,
                supportsStreaming: true,
                supportsParallelTools: true,
                supportsReasoning: true,
                supportsSystemPrompt: true,
                contextWindow: parameterContext,
                maxOutputTokens: nil
            )
        case .anthropic:
            return ModelCapabilities(
                supportsTools: true,
                // Do not infer model-level vision support from the provider
                // family. Explicit Agent settings can opt a known model in.
                supportsVision: false,
                supportsStreaming: true,
                supportsParallelTools: true,
                supportsReasoning: true,
                supportsSystemPrompt: true,
                contextWindow: parameterContext,
                maxOutputTokens: nil
            )
        }
    }

    private func ollamaCapabilityResolution(
        for model: String
    ) async -> OllamaCapabilityResolution {
        let fallback = applyingVisionOverride(
            to: providerCapabilities(for: .ollama, model: model)
        )
        guard !model.isEmpty else {
            return OllamaCapabilityResolution(provider: fallback, modelParameters: nil)
        }
        if let cached = await capabilityCache.value(for: model) { return cached }

        do {
            let request = try OllamaAgentWireAdapter.makeCapabilitiesRequest(
                model: model,
                settings: settings,
                apiKey: apiKey
            )
            let data = try await transport.data(
                for: request,
                provider: OllamaAgentWireAdapter.providerName,
                model: model,
                requestedTools: false
            )
            let wire = OllamaAgentWireAdapter.parseCapabilities(data)
            let modelParameters = OllamaAgentWireAdapter
                .parseModelParameterCapabilities(data)
            guard wire != nil || modelParameters != nil else {
                // An older/compatible server may not implement metadata. Do
                // not negative-cache that transient absence: a later request
                // must be allowed to discover newly available capabilities.
                return OllamaCapabilityResolution(
                    provider: fallback,
                    modelParameters: nil
                )
            }
            let resolution = OllamaCapabilityResolution(
                provider: applyingVisionOverride(
                    to: wire.map(ModelCapabilities.init) ?? fallback
                ),
                modelParameters: modelParameters
            )
            await capabilityCache.insert(resolution, for: model)
            return resolution
        } catch {
            // Transport and parse failures are advisory for capability
            // discovery. Preserve the static family/backend recommendation and
            // retry discovery on the next request instead of permanently
            // caching a false negative.
            return OllamaCapabilityResolution(provider: fallback, modelParameters: nil)
        }
    }

    private func applyingVisionOverride(
        to capabilities: ModelCapabilities
    ) -> ModelCapabilities {
        guard let visionCapabilityOverride else { return capabilities }
        var effective = capabilities
        effective.supportsVision = visionCapabilityOverride
        return effective
    }

    private func wireMessages(
        _ source: [AgentMessage],
        payloads: [AgentImagePayload]
    ) throws -> [ProviderWireMessage] {
        var toolNamesByCallID: [String: String] = [:]
        var result: [ProviderWireMessage] = []
        var payloadsByID: [UUID: AgentImagePayload] = [:]
        for payload in payloads {
            guard payloadsByID.updateValue(payload, forKey: payload.attachmentID) == nil else {
                throw AgentImageAttachmentError.duplicateAttachment(payload.attachmentID)
            }
        }

        // A persisted reference can legitimately appear again when a user
        // re-attaches the same session image. Request-scoped bytes must be
        // emitted exactly once, beside the newest matching message selected by
        // AgentRuntime, rather than leaking into an older context turn or
        // failing merely because history contains the same safe reference.
        var payloadDestinationByID: [UUID: Int] = [:]
        for (index, message) in source.enumerated() {
            try AgentImageAttachmentLimits.validate(message.imageAttachments)
            for reference in message.imageAttachments {
                guard let payload = payloadsByID[reference.id] else { continue }
                guard message.role == .user || message.role == .tool else {
                    throw ProviderWireError.invalidRequest(
                        "只有 user 或 tool 訊息可提供影像 payload"
                    )
                }
                guard payload.matches(reference) else {
                    throw AgentImageAttachmentError.payloadMismatch(reference.id)
                }
                payloadDestinationByID[reference.id] = index
            }
        }
        guard payloadDestinationByID.count == payloadsByID.count else {
            throw ProviderWireError.invalidRequest(
                "影像 payload 必須對應 request 中唯一的 message attachment reference"
            )
        }

        var emittedPayloadIDs = Set<UUID>()
        var pendingToolImages: [ProviderWireImage] = []
        result.reserveCapacity(source.count + 1)

        for (messageIndex, message) in source.enumerated() {
            if message.role != .tool, !pendingToolImages.isEmpty {
                result.append(ProviderWireMessage(role: .user, images: pendingToolImages))
                pendingToolImages.removeAll(keepingCapacity: true)
            }
            let calls = message.toolCalls.map {
                toolNamesByCallID[$0.id] = $0.name
                return ProviderWireToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
            }
            let role: ProviderWireMessage.Role
            switch message.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: role = .tool
            }

            let toolResult: ProviderWireToolResult?
            if message.role == .tool {
                guard let callID = message.toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !callID.isEmpty else {
                    throw ProviderWireError.invalidRequest("tool message 缺少 toolCallID")
                }
                let explicitName = message.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let toolName = explicitName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? toolNamesByCallID[callID]
                    ?? "tool"
                toolResult = .init(
                    callID: callID,
                    toolName: toolName,
                    content: message.content,
                    isError: message.isError
                )
            } else {
                toolResult = nil
            }
            let images = try message.imageAttachments.compactMap { reference -> ProviderWireImage? in
                guard payloadDestinationByID[reference.id] == messageIndex,
                      let payload = payloadsByID[reference.id] else { return nil }
                guard emittedPayloadIDs.insert(reference.id).inserted else {
                    throw AgentImageAttachmentError.payloadMismatch(reference.id)
                }
                return ProviderWireImage(
                    attachmentID: reference.id,
                    mimeType: reference.mimeType,
                    data: payload.data
                )
            }
            result.append(
                ProviderWireMessage(
                    role: role,
                    text: message.content,
                    reasoning: message.reasoningSummary,
                    toolCalls: calls,
                    toolResult: toolResult,
                    images: message.role == .tool ? [] : images
                )
            )
            // Chat-completions protocols do not consistently accept multimodal
            // content on a `tool` role. Keep the required tool-result message,
            // then provide safely loaded images as one user input after the
            // complete consecutive tool-result group. This ordering matters
            // for parallel OpenAI-style calls, whose tool responses must all
            // immediately follow the assistant before another role appears.
            // Anthropic's adapter groups the user blocks into the same turn.
            if message.role == .tool, !images.isEmpty {
                pendingToolImages.append(contentsOf: images)
            }
        }
        if !pendingToolImages.isEmpty {
            result.append(ProviderWireMessage(role: .user, images: pendingToolImages))
        }
        guard emittedPayloadIDs.count == payloadsByID.count else {
            throw ProviderWireError.invalidRequest(
                "影像 payload 必須對應 request 中唯一的 message attachment reference"
            )
        }
        return result
    }
}

private struct OllamaCapabilityResolution: Sendable {
    var provider: ModelCapabilities
    var modelParameters: DiscoveredModelParameterCapabilities?
}

private actor AgentProviderCapabilityCache {
    private var values: [String: OllamaCapabilityResolution] = [:]

    func value(for model: String) -> OllamaCapabilityResolution? { values[model] }
    func insert(_ value: OllamaCapabilityResolution, for model: String) {
        values[model] = value
    }
}

private extension ModelCapabilities {
    init(_ source: ProviderWireCapabilities) {
        self.init(
            supportsTools: source.supportsTools,
            supportsVision: source.supportsVision,
            supportsStreaming: source.supportsStreaming,
            supportsParallelTools: source.supportsParallelTools,
            supportsReasoning: source.supportsReasoning,
            supportsSystemPrompt: source.supportsSystemPrompt,
            contextWindow: ProviderNumericSafety.capabilityLimit(source.contextWindow),
            maxOutputTokens: ProviderNumericSafety.capabilityLimit(source.maxOutputTokens)
        )
    }
}
