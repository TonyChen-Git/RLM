import Foundation

/// A dependency-free client for the streaming APIs exposed by the providers that
/// LumaChat supports. The client is immutable and safe to share between tasks.
struct LLMClient: Sendable {
    typealias AttachmentLoader = @Sendable (ChatAttachment) async throws -> Data?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func fetchModels(settings: AppSettings, apiKey: String?) async throws -> [String] {
        let route: [String]
        switch settings.provider {
        case .ollama:
            route = ["api", "tags"]
        case .openAICompatible, .anthropic:
            route = ["models"]
        }

        let url = try Self.routeURL(for: settings, route: route)
        var request = URLRequest(url: url, timeoutInterval: Self.timeout(from: settings))
        request.httpMethod = "GET"
        try applyHeaders(
            to: &request,
            provider: settings.provider,
            apiKey: apiKey,
            hasJSONBody: false
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(
                for: request,
                maximumBytes: Self.maximumMetadataResponseSize
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChatError {
            throw Self.sanitized(error, apiKey: apiKey)
        } catch {
            throw ChatError.server(
                "無法連線到 LLM 伺服器："
                    + Self.sanitizedText(error.localizedDescription, apiKey: apiKey)
            )
        }

        guard let httpResponse = response as? HTTPURLResponse,
              AgentHTTPOrigin.isSameOrigin(request.url, httpResponse.url) else {
            throw ChatError.malformedResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.httpError(
                statusCode: httpResponse.statusCode,
                body: data,
                apiKey: apiKey
            )
        }

        do {
            let models: [String]
            switch settings.provider {
            case .ollama:
                let response = try decoder.decode(OllamaModelsResponse.self, from: data)
                models = response.models.compactMap { model in
                    let candidate = model.name ?? model.model
                    return candidate?.nilIfBlank
                }
            case .openAICompatible:
                let response = try decoder.decode(APIModelsResponse.self, from: data)
                models = response.data.compactMap(\.id.nilIfBlank)
            case .anthropic:
                let response = try decoder.decode(APIModelsResponse.self, from: data)
                models = response.data.compactMap(\.id.nilIfBlank)
            }

            return Array(Set(models)).sorted()
        } catch {
            throw ChatError.server("模型清單格式無法解析：\(error.localizedDescription)")
        }
    }

    /// Discovers concrete model limits advertised by the selected backend.
    /// Unsupported providers deliberately return nil so their centralized
    /// provider/family recommendation remains authoritative.
    func fetchModelParameterCapabilities(
        settings: AppSettings,
        apiKey: String?
    ) async throws -> DiscoveredModelParameterCapabilities? {
        guard settings.provider == .ollama else { return nil }

        let request = try OllamaAgentWireAdapter.makeCapabilitiesRequest(
            model: settings.selectedModel,
            settings: settings,
            apiKey: apiKey
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await boundedData(
                for: request,
                maximumBytes: Self.maximumMetadataResponseSize
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ChatError {
            throw Self.sanitized(error, apiKey: apiKey)
        } catch {
            throw ChatError.server(
                "無法讀取模型能力："
                    + Self.sanitizedText(error.localizedDescription, apiKey: apiKey)
            )
        }

        guard let httpResponse = response as? HTTPURLResponse,
              AgentHTTPOrigin.isSameOrigin(request.url, httpResponse.url) else {
            throw ChatError.malformedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.httpError(
                statusCode: httpResponse.statusCode,
                body: data,
                apiKey: apiKey
            )
        }
        return OllamaAgentWireAdapter.parseModelParameterCapabilities(data)
    }

    /// Starts a streaming chat request. Stopping iteration cancels the underlying
    /// URLSession task. Each yielded value is a content or reasoning delta, not the
    /// full response.
    func stream(
        messages: [ChatMessage],
        settings: AppSettings,
        parameters: EffectiveModelParameterProfile? = nil,
        apiKey: String?,
        attachmentLoader: @escaping AttachmentLoader
    ) -> AsyncThrowingStream<LLMStreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !settings.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ChatError.noModel
                    }

                    let preparedMessages = try await prepare(
                        messages: messages,
                        settings: settings,
                        attachmentLoader: attachmentLoader
                    )
                    let discoveredCapabilities: DiscoveredModelParameterCapabilities?
                    do {
                        discoveredCapabilities = try await fetchModelParameterCapabilities(
                            settings: settings,
                            apiKey: apiKey
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Capability discovery is advisory. Older Ollama and
                        // compatible servers can omit /api/show; the static
                        // backend/family recommendation remains safe fallback.
                        discoveredCapabilities = nil
                    }
                    let request = try makeStreamingRequest(
                        messages: preparedMessages,
                        settings: settings,
                        parameters: parameters,
                        discoveredCapabilities: discoveredCapabilities,
                        apiKey: apiKey
                    )

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw ChatError.server("無法連線到 LLM 伺服器：\(error.localizedDescription)")
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          AgentHTTPOrigin.isSameOrigin(request.url, httpResponse.url) else {
                        throw ChatError.malformedResponse
                    }

                    if httpResponse.expectedContentLength
                        > Int64(Self.maximumStreamingResponseSize) {
                        throw ChatError.server("伺服器串流回應超過安全上限。")
                    }

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var body = Data()
                        body.reserveCapacity(4_096)
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if body.count >= Self.maximumErrorBodySize { break }
                            body.append(byte)
                        }
                        throw Self.httpError(
                            statusCode: httpResponse.statusCode,
                            body: body,
                            apiKey: apiKey
                        )
                    }

                    switch settings.provider {
                    case .ollama:
                        try await Self.consumeOllama(bytes: bytes, continuation: continuation)
                    case .openAICompatible:
                        try await Self.consumeOpenAI(bytes: bytes, continuation: continuation)
                    case .anthropic:
                        try await Self.consumeAnthropic(bytes: bytes, continuation: continuation)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.sanitized(error, apiKey: apiKey))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request construction

    private func prepare(
        messages: [ChatMessage],
        settings: AppSettings,
        attachmentLoader: AttachmentLoader
    ) async throws -> [PreparedMessage] {
        var source = messages
        let hasSystemMessage = source.contains { $0.role == .system }
        let systemPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasSystemMessage, !systemPrompt.isEmpty {
            source.insert(ChatMessage(role: .system, content: systemPrompt), at: 0)
        }

        var result: [PreparedMessage] = []
        result.reserveCapacity(source.count)

        for message in source {
            try Task.checkCancellation()
            var text = message.content
            var images: [PreparedImage] = []

            for attachment in message.attachments {
                try Task.checkCancellation()
                if attachment.kind == .image {
                    guard let data = try await attachmentLoader(attachment), !data.isEmpty else { continue }
                    images.append(
                        PreparedImage(
                            mimeType: Self.imageMIMEType(from: attachment.mimeType),
                            base64: data.base64EncodedString()
                        )
                    )
                } else if let extractedText = attachment.extractedText?.nilIfBlank {
                    text += "\n\n--- 附件：\(attachment.name) ---\n\(extractedText)"
                } else {
                    text += "\n\n--- 附件：\(attachment.name) ---\n"
                    text += "格式：\(attachment.mimeType)，大小：\(attachment.byteCount) bytes。"
                    text += "此格式無法抽取文字內容，請依附件資訊回覆或請使用者轉成 PDF／文字格式。"
                }
            }

            result.append(PreparedMessage(role: message.role, text: text, images: images))
        }

        return result
    }

    private func makeStreamingRequest(
        messages: [PreparedMessage],
        settings: AppSettings,
        parameters suppliedParameters: EffectiveModelParameterProfile?,
        discoveredCapabilities: DiscoveredModelParameterCapabilities?,
        apiKey: String?
    ) throws -> URLRequest {
        let route = ModelParameterRoute(settings: settings, useCase: .chat)
        let recommended = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: settings.modelParameterProfiles,
            discoveredCapabilities: discoveredCapabilities
        )
        let candidate: EffectiveModelParameterProfile
        if let suppliedParameters, suppliedParameters.key == route.key {
            candidate = suppliedParameters
        } else {
            candidate = recommended
        }
        // Recompute support at the request boundary. A stale or malformed
        // persisted capability snapshot can therefore never enable fields for
        // a backend that does not support them.
        let capabilities = recommended.capabilities
        let values = ModelParameterValidation.normalized(
            candidate.values,
            capabilities: capabilities
        )
        let endpointRoute: [String]
        switch settings.provider {
        case .ollama:
            endpointRoute = ["api", "chat"]
        case .openAICompatible:
            endpointRoute = ["chat", "completions"]
        case .anthropic:
            endpointRoute = ["messages"]
        }

        let url = try Self.routeURL(for: settings, route: endpointRoute)
        var request = URLRequest(url: url, timeoutInterval: Self.timeout(from: settings))
        request.httpMethod = "POST"
        try applyHeaders(
            to: &request,
            provider: settings.provider,
            apiKey: apiKey,
            hasJSONBody: true
        )

        switch settings.provider {
        case .ollama:
            let payload = OllamaChatRequest(
                model: settings.selectedModel,
                messages: messages.map {
                    OllamaChatRequest.Message(
                        role: $0.role.rawValue,
                        content: $0.text,
                        images: $0.images.isEmpty ? nil : $0.images.map(\.base64)
                    )
                },
                stream: true,
                think: capabilities.supportsThinking ? values.thinkingEnabled : nil,
                options: .init(
                    numContext: values.contextWindowTokens,
                    numPredict: values.maxOutputTokens,
                    temperature: capabilities.supportsTemperature ? values.temperature : nil,
                    topP: capabilities.supportsTopP ? values.topP : nil,
                    topK: capabilities.supportsTopK ? values.topK : nil,
                    minP: capabilities.supportsMinP ? values.minP : nil,
                    repeatPenalty: capabilities.supportsRepetitionPenalty
                        ? values.repetitionPenalty : nil
                )
            )
            request.httpBody = try encoder.encode(payload)

        case .openAICompatible:
            let payload = OpenAIChatRequest(
                model: settings.selectedModel,
                messages: messages.map { message in
                    let content: OpenAIContent
                    if message.images.isEmpty {
                        content = .text(message.text)
                    } else {
                        var blocks: [OpenAIContentBlock] = []
                        if !message.text.isEmpty {
                            blocks.append(.text(message.text))
                        }
                        blocks.append(contentsOf: message.images.map(OpenAIContentBlock.image))
                        content = .blocks(blocks)
                    }
                    return OpenAIChatRequest.Message(role: message.role.rawValue, content: content)
                },
                stream: true,
                maxTokens: settings.resolvedBackend == .openAI
                    && capabilities.supportsReasoningEffort ? nil : values.maxOutputTokens,
                maxCompletionTokens: settings.resolvedBackend == .openAI
                    && capabilities.supportsReasoningEffort ? values.maxOutputTokens : nil,
                temperature: capabilities.supportsTemperature ? values.temperature : nil,
                topP: capabilities.supportsTopP ? values.topP : nil,
                topK: capabilities.supportsTopK ? values.topK : nil,
                minP: capabilities.supportsMinP ? values.minP : nil,
                repetitionPenalty: capabilities.supportsRepetitionPenalty
                    ? values.repetitionPenalty : nil,
                presencePenalty: capabilities.supportsPresencePenalty
                    ? values.presencePenalty : nil,
                reasoningEffort: capabilities.supportsReasoningEffort
                    ? values.reasoningEffort.rawValue : nil,
                chatTemplateKwargs: (settings.resolvedBackend == .mlx
                    || settings.resolvedBackend == .lmStudio)
                    && capabilities.supportsThinking
                    ? .init(enableThinking: values.thinkingEnabled) : nil
            )
            request.httpBody = try encoder.encode(payload)

        case .anthropic:
            let system = messages
                .filter { $0.role == .system }
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            let anthropicMessages = messages.compactMap { message -> AnthropicChatRequest.Message? in
                guard message.role != .system else { return nil }
                var blocks: [AnthropicContentBlock] = []
                if !message.text.isEmpty {
                    blocks.append(.text(message.text))
                }
                blocks.append(contentsOf: message.images.map(AnthropicContentBlock.image))
                if blocks.isEmpty {
                    blocks.append(.text(" "))
                }
                return .init(role: message.role.rawValue, content: blocks)
            }

            let payload = AnthropicChatRequest(
                model: settings.selectedModel,
                system: system.isEmpty ? nil : system,
                messages: anthropicMessages,
                stream: true,
                maxTokens: values.maxOutputTokens,
                temperature: capabilities.supportsTemperature
                    ? min(1, values.temperature) : nil,
                topP: capabilities.supportsTopP ? values.topP : nil,
                topK: capabilities.supportsTopK ? values.topK : nil
            )
            request.httpBody = try encoder.encode(payload)
        }

        return request
    }

    private func applyHeaders(
        to request: inout URLRequest,
        provider: ProviderKind,
        apiKey: String?,
        hasJSONBody: Bool
    ) throws {
        request.setValue(hasJSONBody ? "application/json" : "application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if hasJSONBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.url?.scheme?.lowercased() == "http",
           !AgentHTTPOrigin.isLoopback(request.url?.host),
           key?.isEmpty == false {
            throw ChatError.invalidEndpoint
        }
        switch provider {
        case .ollama:
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .openAICompatible:
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if let key, !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    // MARK: - Stream parsing

    private static func consumeOllama(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) async throws {
        var lines = LineAccumulator()
        var totalBytes = 0

        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= maximumStreamingResponseSize else {
                throw ChatError.server("伺服器串流回應超過安全上限。")
            }
            if let line = try lines.append(byte) {
                try parseOllamaLine(line, continuation: continuation)
            }
        }

        if let line = try lines.finish() {
            try parseOllamaLine(line, continuation: continuation)
        }
    }

    private static func parseOllamaLine(
        _ line: String,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) throws {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = line.data(using: .utf8) else { throw ChatError.malformedResponse }

        let chunk: OllamaStreamChunk
        do {
            chunk = try JSONDecoder().decode(OllamaStreamChunk.self, from: data)
        } catch {
            throw ChatError.server("Ollama 串流格式無法解析：\(error.localizedDescription)")
        }

        if let message = chunk.error?.nilIfBlank {
            throw ChatError.server("Ollama：\(message)")
        }
        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
            continuation.yield(.reasoning(thinking))
        }
        if let text = chunk.message?.content, !text.isEmpty {
            continuation.yield(.content(text))
        } else if let text = chunk.response, !text.isEmpty {
            // Some Ollama-compatible servers use the /api/generate response shape.
            continuation.yield(.content(text))
        }
    }

    private static func consumeOpenAI(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) async throws {
        var lines = LineAccumulator()
        var event = SSEEventAccumulator()
        var plainResponseLines: [String] = []
        var totalBytes = 0

        func process(_ line: String) throws {
            if line.isEmpty {
                if let payload = event.finishEvent() {
                    try parseOpenAIEvent(payload, continuation: continuation)
                }
            } else if try !event.consume(line: line) {
                plainResponseLines.append(line)
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= maximumStreamingResponseSize else {
                throw ChatError.server("伺服器串流回應超過安全上限。")
            }
            if let line = try lines.append(byte) {
                try process(line)
            }
        }

        if let line = try lines.finish() {
            try process(line)
        }
        if let payload = event.finishEvent() {
            try parseOpenAIEvent(payload, continuation: continuation)
        }

        if !event.sawData, !plainResponseLines.isEmpty {
            try parseOpenAINonStreaming(
                plainResponseLines.joined(separator: "\n"),
                continuation: continuation
            )
        }
    }

    private static func parseOpenAIEvent(
        _ payload: String,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "[DONE]", !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8) else { throw ChatError.malformedResponse }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.description.nilIfBlank ?? envelope.message?.nilIfBlank {
            throw ChatError.server("LLM 伺服器：\(message)")
        }

        do {
            let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
            for choice in chunk.choices {
                if let reasoning = choice.delta?.reasoningText, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = choice.delta?.content?.text, !content.isEmpty {
                    continuation.yield(.content(content))
                } else if let text = choice.text, !text.isEmpty {
                    continuation.yield(.content(text))
                }
            }
        } catch {
            throw ChatError.server("OpenAI 相容串流格式無法解析：\(error.localizedDescription)")
        }
    }

    private static func parseOpenAINonStreaming(
        _ payload: String,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) throws {
        guard let data = payload.data(using: .utf8) else { throw ChatError.malformedResponse }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.description.nilIfBlank ?? envelope.message?.nilIfBlank {
            throw ChatError.server("LLM 伺服器：\(message)")
        }

        do {
            let response = try JSONDecoder().decode(OpenAICompletionResponse.self, from: data)
            for choice in response.choices {
                if let reasoning = choice.message?.reasoningText, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let text = choice.message?.content?.text ?? choice.text, !text.isEmpty {
                    continuation.yield(.content(text))
                }
            }
        } catch {
            throw ChatError.server("OpenAI 相容回應格式無法解析：\(error.localizedDescription)")
        }
    }

    private static func consumeAnthropic(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) async throws {
        var lines = LineAccumulator()
        var event = SSEEventAccumulator()
        var plainResponseLines: [String] = []
        var totalBytes = 0

        func process(_ line: String) throws {
            if line.isEmpty {
                if let payload = event.finishEvent() {
                    try parseAnthropicEvent(payload, continuation: continuation)
                }
            } else if try !event.consume(line: line) {
                plainResponseLines.append(line)
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= maximumStreamingResponseSize else {
                throw ChatError.server("伺服器串流回應超過安全上限。")
            }
            if let line = try lines.append(byte) {
                try process(line)
            }
        }

        if let line = try lines.finish() {
            try process(line)
        }
        if let payload = event.finishEvent() {
            try parseAnthropicEvent(payload, continuation: continuation)
        }

        if !event.sawData, !plainResponseLines.isEmpty {
            try parseAnthropicNonStreaming(
                plainResponseLines.joined(separator: "\n"),
                continuation: continuation
            )
        }
    }

    private static func parseAnthropicEvent(
        _ payload: String,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) throws {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "[DONE]", !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8) else { throw ChatError.malformedResponse }

        do {
            let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            if event.type == "error", let message = event.error?.message?.nilIfBlank {
                throw ChatError.server("Anthropic：\(message)")
            }
            if event.type == "content_block_delta", let delta = event.delta {
                switch delta.type {
                case "text_delta":
                    if let text = delta.text, !text.isEmpty {
                        continuation.yield(.content(text))
                    }
                case "thinking_delta":
                    if let thinking = delta.thinking ?? delta.text, !thinking.isEmpty {
                        continuation.yield(.reasoning(thinking))
                    }
                default:
                    break
                }
            }
        } catch let error as ChatError {
            throw error
        } catch {
            throw ChatError.server("Anthropic 串流格式無法解析：\(error.localizedDescription)")
        }
    }

    private static func parseAnthropicNonStreaming(
        _ payload: String,
        continuation: AsyncThrowingStream<LLMStreamDelta, Error>.Continuation
    ) throws {
        guard let data = payload.data(using: .utf8) else { throw ChatError.malformedResponse }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.description.nilIfBlank ?? envelope.message?.nilIfBlank {
            throw ChatError.server("Anthropic：\(message)")
        }

        do {
            let response = try JSONDecoder().decode(AnthropicCompletionResponse.self, from: data)
            for block in response.content {
                switch block.type {
                case "text":
                    if let text = block.text, !text.isEmpty {
                        continuation.yield(.content(text))
                    }
                case "thinking":
                    if let thinking = block.thinking ?? block.text, !thinking.isEmpty {
                        continuation.yield(.reasoning(thinking))
                    }
                default:
                    break
                }
            }
        } catch {
            throw ChatError.server("Anthropic 回應格式無法解析：\(error.localizedDescription)")
        }
    }

    // MARK: - URL and error handling

    private static func routeURL(for settings: AppSettings, route: [String]) throws -> URL {
        var base = settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw ChatError.invalidEndpoint }
        if !base.contains("://") {
            base = "http://" + base
        }

        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.nilIfBlank != nil else {
            throw ChatError.invalidEndpoint
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ChatError.invalidEndpoint
        }
        if scheme == "http",
           settings.provider != .ollama,
           !AgentHTTPOrigin.isLoopback(components.host) {
            throw ChatError.invalidEndpoint
        }

        components.scheme = scheme

        var existing = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        if existing.isEmpty {
            let host = components.host?.lowercased()
            if settings.provider == .anthropic, host == "api.anthropic.com" {
                existing = ["v1"]
            } else if settings.provider == .openAICompatible, host == "api.openai.com" {
                existing = ["v1"]
            } else if settings.provider == .openAICompatible, host == "openrouter.ai" {
                existing = ["api", "v1"]
            }
        }

        let lowerExisting = existing.map { $0.lowercased() }
        let lowerRoute = route.map { $0.lowercased() }
        var overlap = min(existing.count, route.count)
        while overlap > 0 {
            if Array(lowerExisting.suffix(overlap)) == Array(lowerRoute.prefix(overlap)) {
                break
            }
            overlap -= 1
        }
        existing.append(contentsOf: route.dropFirst(overlap))

        components.path = "/" + existing.joined(separator: "/")
        guard let url = components.url else { throw ChatError.invalidEndpoint }
        return url
    }

    private static func timeout(from settings: AppSettings) -> TimeInterval {
        settings.requestTimeout.isFinite && settings.requestTimeout > 0
            ? settings.requestTimeout
            : 300
    }

    private func boundedData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ChatError.server("伺服器回應超過安全上限。")
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw ChatError.server("伺服器回應超過安全上限。")
            }
            data.append(byte)
        }
        return (data, response)
    }

    private static func httpError(
        statusCode: Int,
        body: Data,
        apiKey: String?
    ) -> ChatError {
        let message: String?
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            message = envelope.error?.description.nilIfBlank ?? envelope.message?.nilIfBlank
        } else {
            message = String(data: body, encoding: .utf8)?.nilIfBlank
        }

        let status = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if let message {
            let safeMessage = sanitizedText(String(message.prefix(2_000)), apiKey: apiKey)
            return .server("HTTP \(statusCode)（\(status)）：\(safeMessage)")
        }
        return .server("HTTP \(statusCode)（\(status)）")
    }

    private static func imageMIMEType(from value: String) -> String {
        let mime = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mime.hasPrefix("image/") ? mime : "image/png"
    }

    private static func sanitized(_ error: Error, apiKey: String?) -> ChatError {
        if let chatError = error as? ChatError {
            switch chatError {
            case .server(let message):
                return .server(sanitizedText(message, apiKey: apiKey))
            case .permissionDenied(let message):
                return .permissionDenied(sanitizedText(message, apiKey: apiKey))
            case .invalidEndpoint, .noModel, .malformedResponse, .fileTooLarge,
                 .unsupportedFile:
                return chatError
            }
        }
        return .server(sanitizedText(error.localizedDescription, apiKey: apiKey))
    }

    private static func sanitizedText(_ value: String, apiKey: String?) -> String {
        var result = value
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            result = result.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        }
        return SecretRedactor().redact(result)
    }

    private static let maximumErrorBodySize = 64 * 1_024
    private static let maximumMetadataResponseSize = 4 * 1_024 * 1_024
    private static let maximumStreamingResponseSize = 64 * 1_024 * 1_024
}

// MARK: - Provider payloads

private struct PreparedMessage: Sendable {
    let role: MessageRole
    let text: String
    let images: [PreparedImage]
}

private struct PreparedImage: Sendable {
    let mimeType: String
    let base64: String
}

private struct OllamaModelsResponse: Decodable {
    struct Model: Decodable {
        let name: String?
        let model: String?
    }

    let models: [Model]
}

private struct APIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct OllamaChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
        let images: [String]?
    }

    struct Options: Encodable {
        let numContext: Int
        let numPredict: Int
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let minP: Double?
        let repeatPenalty: Double?

        enum CodingKeys: String, CodingKey {
            case numContext = "num_ctx"
            case numPredict = "num_predict"
            case temperature
            case topP = "top_p"
            case topK = "top_k"
            case minP = "min_p"
            case repeatPenalty = "repeat_penalty"
        }
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool?
    let options: Options
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: OpenAIContent
    }

    let model: String
    let messages: [Message]
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

        enum CodingKeys: String, CodingKey {
            case enableThinking = "enable_thinking"
        }
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
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

private enum OpenAIContent: Encodable {
    case text(String)
    case blocks([OpenAIContentBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

private struct OpenAIContentBlock: Encodable {
    struct ImageURL: Encodable {
        let url: String
    }

    let type: String
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func text(_ value: String) -> Self {
        .init(type: "text", text: value, imageURL: nil)
    }

    static func image(_ value: PreparedImage) -> Self {
        .init(
            type: "image_url",
            text: nil,
            imageURL: .init(url: "data:\(value.mimeType);base64,\(value.base64)")
        )
    }
}

private struct AnthropicChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [AnthropicContentBlock]
    }

    let model: String
    let system: String?
    let messages: [Message]
    let stream: Bool
    let maxTokens: Int
    let temperature: Double?
    let topP: Double?
    let topK: Int?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
    }
}

private struct AnthropicContentBlock: Encodable {
    struct Source: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    let type: String
    let text: String?
    let source: Source?

    static func text(_ value: String) -> Self {
        .init(type: "text", text: value, source: nil)
    }

    static func image(_ value: PreparedImage) -> Self {
        .init(
            type: "image",
            text: nil,
            source: .init(type: "base64", mediaType: value.mimeType, data: value.base64)
        )
    }
}

// MARK: - Provider responses

private struct OllamaStreamChunk: Decodable {
    struct Message: Decodable {
        let content: String?
        let thinking: String?
    }

    let message: Message?
    let response: String?
    let error: String?
}

private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: FlexibleText?
            let reasoningContent: FlexibleText?
            let reasoning: FlexibleText?

            var reasoningText: String? {
                if let text = reasoningContent?.text, !text.isEmpty { return text }
                if let text = reasoning?.text, !text.isEmpty { return text }
                return nil
            }

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
            }
        }

        let delta: Delta?
        let text: String?
    }

    let choices: [Choice]
}

private struct OpenAICompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: FlexibleText?
            let reasoningContent: FlexibleText?
            let reasoning: FlexibleText?

            var reasoningText: String? {
                if let text = reasoningContent?.text, !text.isEmpty { return text }
                if let text = reasoning?.text, !text.isEmpty { return text }
                return nil
            }

            private enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case reasoning
            }
        }

        let message: Message?
        let text: String?
    }

    let choices: [Choice]
}

private struct FlexibleText: Decodable {
    struct Block: Decodable {
        let text: String?
    }

    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            text = value
        } else if let blocks = try? container.decode([Block].self) {
            text = blocks.compactMap(\.text).joined()
        } else if container.decodeNil() {
            text = ""
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected text or text content blocks")
            )
        }
    }
}

private struct AnthropicStreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
    }

    struct APIError: Decodable {
        let message: String?
    }

    let type: String
    let delta: Delta?
    let error: APIError?
}

private struct AnthropicCompletionResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
        let thinking: String?
    }

    let content: [Block]
}

private struct ErrorEnvelope: Decodable {
    let error: FlexibleAPIError?
    let message: String?
}

private struct FlexibleAPIError: Decodable {
    let description: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            description = string
            return
        }

        struct Object: Decodable {
            let message: String?
            let detail: String?
            let type: String?
        }

        let object = try container.decode(Object.self)
        description = object.message ?? object.detail ?? object.type ?? "未知的伺服器錯誤"
    }
}

// MARK: - Incremental wire-format helpers

private struct LineAccumulator {
    private var buffer = Data()
    private static let maximumLineSize = 16 * 1_024 * 1_024

    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 0x0A {
            return try takeLine()
        }
        guard buffer.count < Self.maximumLineSize else {
            throw ChatError.server("伺服器串流單行資料過大。")
        }
        buffer.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        guard !buffer.isEmpty else { return nil }
        return try takeLine()
    }

    private mutating func takeLine() throws -> String {
        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard let line = String(data: buffer, encoding: .utf8) else {
            throw ChatError.server("伺服器串流包含無效的 UTF-8 文字。")
        }
        return line
    }
}

private struct SSEEventAccumulator {
    private var dataLines: [String] = []
    private var dataBytes = 0
    private(set) var sawData = false
    private static let maximumEventBytes = 4 * 1_024 * 1_024

    /// Returns true when the line is a valid SSE field or comment.
    mutating func consume(line: String) throws -> Bool {
        if line.hasPrefix(":") {
            return true
        }

        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var start = line.index(after: colon)
            if start < line.endIndex, line[start] == " " {
                start = line.index(after: start)
            }
            value = line[start...]
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "data":
            sawData = true
            let line = String(value)
            let separatorBytes = dataLines.isEmpty ? 0 : 1
            guard dataBytes + separatorBytes + line.utf8.count <= Self.maximumEventBytes else {
                throw ChatError.server("伺服器 SSE event 超過安全上限。")
            }
            dataBytes += separatorBytes + line.utf8.count
            dataLines.append(line)
            return true
        case "event", "id", "retry":
            return true
        default:
            return false
        }
    }

    mutating func finishEvent() -> String? {
        guard !dataLines.isEmpty else { return nil }
        defer {
            dataLines.removeAll(keepingCapacity: true)
            dataBytes = 0
        }
        return dataLines.joined(separator: "\n")
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
