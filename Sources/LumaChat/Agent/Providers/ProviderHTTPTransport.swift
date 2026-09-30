import Foundation

struct ProviderHTTPTransport: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: RejectingRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(
        for request: URLRequest,
        provider: String,
        model: String,
        requestedTools: Bool
    ) async throws -> Data {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ProviderWireError.network(provider: provider, detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderWireError.malformedResponse(provider: provider, detail: "缺少 HTTP 回應資訊")
        }
        guard AgentHTTPOrigin.isSameOrigin(request.url, httpResponse.url) else {
            throw ProviderWireError.network(
                provider: provider,
                detail: "回應來源與設定的 endpoint 不同；已拒絕重新導向"
            )
        }
        let maximumBytes = (200..<300).contains(httpResponse.statusCode)
            ? 32 * 1_024 * 1_024
            : 256 * 1_024
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            throw ProviderWireError.malformedResponse(
                provider: provider,
                detail: "HTTP 回應超過 \(maximumBytes) bytes 安全上限"
            )
        }
        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(httpResponse.expectedContentLength)))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw ProviderWireError.malformedResponse(
                        provider: provider,
                        detail: "HTTP 回應超過 \(maximumBytes) bytes 安全上限"
                    )
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderWireError {
            throw error
        } catch {
            throw ProviderWireError.network(provider: provider, detail: error.localizedDescription)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data).map(Self.redactedErrorDiagnostic)
            if requestedTools,
               Self.looksLikeUnsupportedTools(statusCode: httpResponse.statusCode, message: message) {
                throw ProviderWireError.unsupportedTools(
                    provider: provider,
                    model: model,
                    detail: message.map { String($0.prefix(2_000)) }
                )
            }
            throw ProviderWireError.http(
                provider: provider,
                statusCode: httpResponse.statusCode,
                message: message.map { String($0.prefix(2_000)) }
            )
        }
        return data
    }

    /// Reads a successful streaming response as bounded CR/LF-delimited wire
    /// lines. The closure is deliberately synchronous and nonescaping so each
    /// provider parser observes frames in exact network order without an
    /// unbounded intermediary task or queue.
    func streamLines(
        for request: URLRequest,
        provider: String,
        model: String,
        requestedTools: Bool,
        handleLine: (Data) throws -> Void
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ProviderWireError.network(provider: provider, detail: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderWireError.malformedResponse(provider: provider, detail: "缺少 HTTP 回應資訊")
        }
        guard AgentHTTPOrigin.isSameOrigin(request.url, httpResponse.url) else {
            throw ProviderWireError.network(
                provider: provider,
                detail: "回應來源與設定的 endpoint 不同；已拒絕重新導向"
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let data = try await readErrorBody(bytes, provider: provider)
            let message = Self.errorMessage(from: data).map(Self.redactedErrorDiagnostic)
            if requestedTools,
               Self.looksLikeUnsupportedTools(
                   statusCode: httpResponse.statusCode,
                   message: message
               ) {
                throw ProviderWireError.unsupportedTools(
                    provider: provider,
                    model: model,
                    detail: message.map { String($0.prefix(2_000)) }
                )
            }
            throw ProviderWireError.http(
                provider: provider,
                statusCode: httpResponse.statusCode,
                message: message.map { String($0.prefix(2_000)) }
            )
        }

        let maximumBytes = ProviderWireStreamLimits.maximumResponseBytes
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            throw ProviderWireError.malformedResponse(
                provider: provider,
                detail: "HTTP 串流回應超過 \(maximumBytes) bytes 安全上限"
            )
        }

        var totalBytes = 0
        var line = Data()
        line.reserveCapacity(4_096)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                totalBytes += 1
                guard totalBytes <= maximumBytes else {
                    throw ProviderWireError.malformedResponse(
                        provider: provider,
                        detail: "HTTP 串流回應超過 \(maximumBytes) bytes 安全上限"
                    )
                }
                if byte == 0x0A {
                    if line.last == 0x0D { line.removeLast() }
                    try handleLine(line)
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < ProviderWireStreamLimits.maximumLineBytes else {
                        throw ProviderWireError.malformedResponse(
                            provider: provider,
                            detail: "HTTP 串流單行超過安全上限"
                        )
                    }
                    line.append(byte)
                }
            }
            try Task.checkCancellation()
            if !line.isEmpty {
                if line.last == 0x0D { line.removeLast() }
                try handleLine(line)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderWireError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ProviderWireError.network(provider: provider, detail: error.localizedDescription)
        }
    }

    private func readErrorBody(
        _ bytes: URLSession.AsyncBytes,
        provider: String
    ) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < ProviderWireStreamLimits.maximumErrorBytes else {
                    throw ProviderWireError.malformedResponse(
                        provider: provider,
                        detail: "HTTP 錯誤回應超過安全上限"
                    )
                }
                data.append(byte)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderWireError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw ProviderWireError.network(provider: provider, detail: error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let envelope = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data) {
            return envelope.message
        }
        return String(data: data.prefix(64 * 1_024), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func redactedErrorDiagnostic(_ message: String) -> String {
        let redacted = SecretRedactor().redact(message)
        let firstLine = String(redacted.prefix(2_000).split(whereSeparator: \.isNewline).first ?? "")
        let contentMarkers = [
            "prompt:", "prompt=", "\"prompt\":", "messages:", "messages=", "\"messages\":",
            "content:", "content=", "\"content\":", "system:", "user:", "assistant:"
        ]
        let firstContentOffset = contentMarkers.compactMap {
            firstLine.range(of: $0, options: .caseInsensitive)?.lowerBound
        }
            .min()
        let diagnostic = firstContentOffset.map { String(firstLine[..<$0]) + "[request content omitted]" }
            ?? firstLine
        return String(diagnostic.prefix(500))
    }

    private static func looksLikeUnsupportedTools(statusCode: Int, message: String?) -> Bool {
        guard [400, 404, 405, 422, 501].contains(statusCode) else { return false }
        guard let message = message?.lowercased() else { return false }
        let toolTerms = ["tool", "tools", "tool_choice", "function call", "function_call"]
        let supportTerms = ["unsupported", "not support", "does not support", "unknown", "unrecognized", "invalid"]
        return toolTerms.contains(where: message.contains)
            && supportTerms.contains(where: message.contains)
    }
}

enum ProviderRequestBuilder {
    static func routeURL(endpoint: String, provider: ProviderKind, route: [String]) throws -> URL {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw ProviderWireError.invalidEndpoint }
        if !base.contains("://") { base = "http://" + base }

        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
            throw ProviderWireError.invalidEndpoint
        }
        guard components.user == nil, components.password == nil else {
            throw ProviderWireError.invalidEndpoint
        }
        guard components.query == nil, components.fragment == nil else {
            throw ProviderWireError.invalidEndpoint
        }
        // User-selected Ollama and OpenAI-compatible servers may be hosted on
        // LAN machines that expose HTTP only. Anthropic requires TLS remotely.
        if scheme == "http",
           provider == .anthropic,
           !AgentHTTPOrigin.isLoopback(components.host) {
            throw ProviderWireError.invalidEndpoint
        }
        components.scheme = scheme

        var path = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if path.isEmpty {
            let host = components.host?.lowercased()
            if provider == .anthropic, host == "api.anthropic.com" {
                path = ["v1"]
            } else if provider == .openAICompatible, host == "api.openai.com" {
                path = ["v1"]
            } else if provider == .openAICompatible, host == "openrouter.ai" {
                path = ["api", "v1"]
            }
        }

        let lowerPath = path.map { $0.lowercased() }
        let lowerRoute = route.map { $0.lowercased() }
        var overlap = min(path.count, route.count)
        while overlap > 0,
              Array(lowerPath.suffix(overlap)) != Array(lowerRoute.prefix(overlap)) {
            overlap -= 1
        }
        path.append(contentsOf: route.dropFirst(overlap))
        components.path = "/" + path.joined(separator: "/")
        guard let url = components.url else { throw ProviderWireError.invalidEndpoint }
        return url
    }

    static func jsonRequest(
        url: URL,
        provider: ProviderKind,
        apiKey: String?,
        timeout: TimeInterval,
        body: Data
    ) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: validTimeout(timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider != .openAICompatible,
           url.scheme?.lowercased() == "http",
           !AgentHTTPOrigin.isLoopback(url.host),
           key?.isEmpty == false {
            throw ProviderWireError.invalidEndpoint
        }
        switch provider {
        case .ollama, .openAICompatible:
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if let key, !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func validTimeout(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 300
    }
}

private struct ProviderErrorEnvelope: Decodable {
    struct ErrorObject: Decodable {
        let message: String?
        let detail: String?
        let type: String?
    }

    let error: ProviderJSONValue?
    let messageValue: String?
    let detail: String?

    private enum CodingKeys: String, CodingKey {
        case error, messageValue = "message", detail
    }

    var message: String? {
        if let messageValue = messageValue?.nilIfEmpty { return messageValue }
        if let detail = detail?.nilIfEmpty { return detail }
        guard let error else { return nil }
        switch error {
        case .string(let value):
            return value.nilIfEmpty
        case .object(let object):
            for key in ["message", "detail", "type"] {
                if case .string(let value)? = object[key], let value = value.nilIfEmpty {
                    return value
                }
            }
            return nil
        default:
            return nil
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
