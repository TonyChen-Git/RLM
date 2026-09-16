import Darwin
import Foundation

struct AgentWebSearchResult: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
}

/// Optional search backend seam. Luma Chat intentionally ships without a
/// default search vendor; `web_search` is registered only when the host injects
/// a configured provider, while fetch_url/http_request remain independent.
protocol AgentWebSearchProvider: Sendable {
    func search(query: String, maximumResults: Int) async throws -> [AgentWebSearchResult]
}

private struct WebAgentTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let inputSchema: JSONValue
    let category: AgentToolCategory = .web
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork = true
    let supportsParallelExecution: Bool
    let operation: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        try await operation(arguments, context)
    }
}

enum WebToolFactory {
    static func makeTools(
        configuration: URLSessionConfiguration? = nil,
        searchProvider: (any AgentWebSearchProvider)? = nil
    ) -> [any AgentTool] {
        let client = WebToolHTTPClient(configuration: configuration)
        var tools: [any AgentTool] = [
            WebAgentTool(
                id: "builtin.fetch_url",
                name: "fetch_url",
                displayName: "Fetch URL",
                description: "Fetch one HTTP(S) URL with GET and return bounded readable text. Redirects and cloud metadata endpoints are refused.",
                inputSchema: .objectSchema(
                    properties: [
                        "url": .stringSchema(description: "Absolute HTTP(S) URL"),
                        "max_bytes": .integerSchema(description: "Maximum response bytes, 1024-2097152", minimum: 1_024)
                    ],
                    required: ["url"]
                ),
                permissionLevel: .read,
                supportsParallelExecution: true
            ) { arguments, context in
                let values = try WebToolArguments(arguments)
                let response = try await client.request(
                    method: .get,
                    rawURL: try values.requiredString("url"),
                    headers: [:],
                    body: nil,
                    maximumBytes: try values.maximumBytes(),
                    timeout: context.commandTimeout
                )
                return response.toolResult(readableHTML: true)
            },
            WebAgentTool(
                id: "builtin.http_request",
                name: "http_request",
                displayName: "HTTP Request",
                description: "Send a bounded HTTP(S) GET, POST, PUT, PATCH, or DELETE request. This remote mutation-capable tool always requires explicit approval.",
                inputSchema: .objectSchema(
                    properties: [
                        "url": .stringSchema(description: "Absolute HTTP(S) URL"),
                        "method": enumSchema(["GET", "POST", "PUT", "PATCH", "DELETE"]),
                        "headers": stringMapSchema("Optional request headers; header injection is rejected"),
                        "body": .stringSchema(description: "Optional UTF-8 request body, at most 1 MiB"),
                        "max_bytes": .integerSchema(description: "Maximum response bytes, 1024-2097152", minimum: 1_024)
                    ],
                    required: ["url", "method"]
                ),
                permissionLevel: .dangerous,
                supportsParallelExecution: false
            ) { arguments, context in
                let values = try WebToolArguments(arguments)
                let method = try WebToolHTTPMethod.parse(values.requiredString("method"))
                let body = values.string("body").map { Data($0.utf8) }
                guard (body?.count ?? 0) <= 1_048_576 else {
                    throw WebToolError.invalidRequest("request body exceeds 1 MiB")
                }
                let response = try await client.request(
                    method: method,
                    rawURL: try values.requiredString("url"),
                    headers: try values.stringMap("headers"),
                    body: body,
                    maximumBytes: try values.maximumBytes(),
                    timeout: context.commandTimeout
                )
                return response.toolResult(readableHTML: false)
            }
        ]
        if let searchProvider {
            tools.append(webSearchTool(provider: searchProvider))
        }
        return tools
    }

    private static func webSearchTool(
        provider: any AgentWebSearchProvider
    ) -> any AgentTool {
        WebAgentTool(
            id: "builtin.web_search",
            name: "web_search",
            displayName: "Web Search",
            description: "Search the web through the user-configured search provider and return bounded titles, URLs, and snippets.",
            inputSchema: .objectSchema(
                properties: [
                    "query": .stringSchema(description: "Search query, at most 4096 UTF-8 bytes"),
                    "max_results": .integerSchema(description: "Maximum results, 1-20", minimum: 1)
                ],
                required: ["query"]
            ),
            permissionLevel: .read,
            supportsParallelExecution: true
        ) { arguments, _ in
            let values = try WebToolArguments(arguments)
            let query = try values.requiredString("query")
            guard query.utf8.count <= 4_096 else {
                throw WebToolError.invalidRequest("query exceeds 4096 UTF-8 bytes")
            }
            let maximumResults = try values.integer(
                "max_results",
                default: 5,
                range: 1 ... 20
            )
            let rawResults = try await provider.search(
                query: query,
                maximumResults: maximumResults
            )
            guard rawResults.count <= 100 else { throw WebToolError.invalidResponse }

            var totalBytes = 0
            var results: [AgentWebSearchResult] = []
            for raw in rawResults.prefix(maximumResults) {
                let result = AgentWebSearchResult(
                    title: String(raw.title.prefix(1_024)),
                    url: try validatedSearchResultURL(raw.url),
                    snippet: String(raw.snippet.prefix(8_192))
                )
                totalBytes += result.title.utf8.count
                    + result.url.utf8.count
                    + result.snippet.utf8.count
                guard totalBytes <= 128 * 1_024 else {
                    throw WebToolError.invalidResponse
                }
                results.append(result)
            }

            let rendered = results.isEmpty
                ? "No web search results for: \(query)"
                : results.enumerated().map { index, result in
                    "\(index + 1). \(result.title)\n\(result.url)\n\(result.snippet)"
                }.joined(separator: "\n\n")
            let data: JSONValue = .object([
                "query": .string(query),
                "results": .array(results.map { result in
                    .object([
                        "title": .string(result.title),
                        "url": .string(result.url),
                        "snippet": .string(result.snippet)
                    ])
                })
            ])
            return AgentToolResult(content: rendered, data: data)
        }
    }

    private static func validatedSearchResultURL(_ rawValue: String) throws -> String {
        guard rawValue.utf8.count <= 4_096,
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw WebToolError.invalidResponse
        }
        return url.absoluteString
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func stringMapSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .object(["type": .string("string")])
        ])
    }
}

private enum WebToolHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    static func parse(_ rawValue: String) throws -> Self {
        switch rawValue.uppercased() {
        case "GET": return .get
        case "POST": return .post
        case "PUT": return .put
        case "PATCH": return .patch
        case "DELETE": return .delete
        default: throw WebToolError.invalidRequest("unsupported HTTP method")
        }
    }
}

private struct WebToolArguments: Sendable {
    let values: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard let values = value.objectValue else {
            throw WebToolError.invalidRequest("arguments must be a JSON object")
        }
        self.values = values
    }

    func string(_ name: String) -> String? { values[name]?.stringValue }

    func requiredString(_ name: String) throws -> String {
        guard let value = string(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw WebToolError.invalidRequest("\(name) must be a non-empty string")
        }
        return value
    }

    func stringMap(_ name: String) throws -> [String: String] {
        guard let raw = values[name] else { return [:] }
        guard let object = raw.objectValue else {
            throw WebToolError.invalidRequest("\(name) must be an object of strings")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let string = value.stringValue else {
                throw WebToolError.invalidRequest("\(name).\(key) must be a string")
            }
            result[key] = string
        }
        return result
    }

    func maximumBytes() throws -> Int {
        guard let raw = values["max_bytes"] else { return 512 * 1_024 }
        guard let value = raw.intValue, (1_024 ... 2 * 1_024 * 1_024).contains(value) else {
            throw WebToolError.invalidRequest("max_bytes must be between 1024 and 2097152")
        }
        return value
    }

    func integer(
        _ name: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = values[name] else { return defaultValue }
        guard let value = raw.intValue, range.contains(value) else {
            throw WebToolError.invalidRequest(
                "\(name) must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return value
    }
}

private enum WebToolError: LocalizedError, Equatable {
    case invalidRequest(String)
    case responseTooLarge(Int)
    case redirectRefused
    case invalidResponse
    case httpFailure(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail): "Invalid web request: \(detail)."
        case .responseTooLarge(let limit): "Web response exceeded the \(limit)-byte limit."
        case .redirectRefused: "HTTP redirects are refused; approve and request the destination URL directly."
        case .invalidResponse: "The server did not return a valid HTTP response."
        case .httpFailure(let status, let body): "HTTP \(status): \(body)"
        }
    }
}

private struct WebToolHTTPResponse: Sendable {
    var url: URL
    var status: Int
    var contentType: String
    var body: Data

    func toolResult(readableHTML: Bool) -> AgentToolResult {
        let decoded = Self.decode(body)
        let isHTML = contentType.lowercased().contains("text/html")
        let content = readableHTML && isHTML ? HTMLReadableText.extract(decoded) : decoded
        let safeContent = content.isEmpty && !body.isEmpty
            ? "[\(body.count) bytes of non-text content omitted]"
            : content
        return AgentToolResult(
            content: "HTTP \(status) \(url.absoluteString)\n\(safeContent)",
            data: .object([
                "url": .string(url.absoluteString),
                "status": .number(Double(status)),
                "content_type": .string(contentType),
                "byte_count": .number(Double(body.count))
            ])
        )
    }

    static func decode(_ data: Data) -> String {
        if let value = String(data: data, encoding: .utf8) { return value }
        if let value = String(data: data, encoding: .isoLatin1) { return value }
        return ""
    }
}

private final class WebToolHTTPClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration? = nil) {
        let selected = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        selected.urlCache = nil
        selected.requestCachePolicy = .reloadIgnoringLocalCacheData
        selected.httpCookieStorage = nil
        selected.httpShouldSetCookies = false
        selected.urlCredentialStorage = nil
        selected.waitsForConnectivity = false
        self.configuration = selected
    }

    func request(
        method: WebToolHTTPMethod,
        rawURL: String,
        headers: [String: String],
        body: Data?,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async throws -> WebToolHTTPResponse {
        let url = try Self.validatedURL(rawURL)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = min(max(timeout, 1), 300)
        request.setValue("LumaChat-Agent/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        for (name, value) in try Self.validatedHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let copied = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        let loader = BoundedWebResponseLoader(maximumBytes: maximumBytes)
        let response = try await loader.load(request, configuration: copied)
        if !(200 ... 299).contains(response.status) {
            let errorBody = String(WebToolHTTPResponse.decode(response.body).prefix(4_096))
            throw WebToolError.httpFailure(response.status, errorBody)
        }
        return response
    }

    private static func validatedURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8_192,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw WebToolError.invalidRequest("URL must be an absolute HTTP(S) URL without embedded credentials")
        }
        var host = components.host!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !isForbiddenMetadataHost(host) else {
            throw WebToolError.invalidRequest("cloud metadata endpoints are forbidden")
        }
        return url
    }

    private static func validatedHeaders(_ headers: [String: String]) throws -> [String: String] {
        let forbidden = Set(["host", "content-length", "connection", "transfer-encoding", "upgrade"])
        guard headers.count <= 64 else {
            throw WebToolError.invalidRequest("too many HTTP headers")
        }
        var result: [String: String] = [:]
        var normalizedNames: Set<String> = []
        var totalBytes = 0
        for (name, value) in headers {
            let scalars = name.unicodeScalars
            let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            let normalizedName = name.lowercased()
            totalBytes += name.utf8.count + value.utf8.count
            guard !name.isEmpty, name.utf8.count <= 128,
                  scalars.allSatisfy({ tokenCharacters.contains($0) }),
                  normalizedNames.insert(normalizedName).inserted,
                  !forbidden.contains(normalizedName),
                  value.utf8.count <= 8_192,
                  totalBytes <= 64 * 1_024,
                  value.unicodeScalars.allSatisfy({ scalar in
                      scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7f)
                  }) else {
                throw WebToolError.invalidRequest("invalid or unsafe HTTP header")
            }
            result[name] = value
        }
        return result
    }

    private static func isForbiddenMetadataHost(_ host: String) -> Bool {
        let forbiddenNames: Set<String> = [
            "metadata.google.internal", "metadata.goog"
        ]
        if forbiddenNames.contains(host) { return true }

        let addressHost = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var ipv4 = in_addr()
        if inet_aton(addressHost, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            // All IPv4 link-local destinations are unsuitable for a general web
            // tool; the well-known Alibaba metadata address is outside that range.
            return address & 0xffff_0000 == 0xa9fe_0000 || address == 0x6464_64c8
        }

        guard let bytes = ipv6Bytes(addressHost) else { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let mapped = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if mapped & 0xffff_0000 == 0xa9fe_0000 || mapped == 0x6464_64c8 { return true }
        }
        return bytes == ipv6Bytes("fd00:ec2::254") || bytes == ipv6Bytes("fd20:ce::254")
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

private final class BoundedWebResponseLoader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebToolHTTPResponse, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var completed = false
    private var task: URLSessionDataTask?
    private var session: URLSession?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func load(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> WebToolHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !completed else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(WebToolError.invalidResponse))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(WebToolError.responseTooLarge(maximumBytes)))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        lock.lock()
        let exceedsLimit = data.count > maximumBytes || incoming.count > maximumBytes - min(data.count, maximumBytes)
        if !exceedsLimit { data.append(incoming) }
        lock.unlock()
        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(WebToolError.responseTooLarge(maximumBytes)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(WebToolError.redirectRefused))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let body = data
        lock.unlock()
        guard let response, let url = response.url else {
            finish(.failure(WebToolError.invalidResponse))
            return
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        finish(.success(.init(url: url, status: response.statusCode, contentType: contentType, body: body)))
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<WebToolHTTPResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}

private enum HTMLReadableText {
    static func extract(_ html: String) -> String {
        var output = ""
        output.reserveCapacity(min(html.count, 256 * 1_024))
        var tag = ""
        var entity = ""
        var insideTag = false
        var insideEntity = false
        var skippedElement: String?

        for character in html {
            if insideTag {
                if character == ">" {
                    let parsed = tagName(tag)
                    if let skippedElement {
                        if parsed.closing && parsed.name == skippedElement { self.appendSpace(to: &output) }
                    } else if !parsed.closing && ["script", "style", "noscript", "head"].contains(parsed.name) {
                        skippedElement = parsed.name
                    } else if ["br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"].contains(parsed.name) {
                        appendSpace(to: &output)
                    }
                    if parsed.closing, parsed.name == skippedElement { skippedElement = nil }
                    tag.removeAll(keepingCapacity: true)
                    insideTag = false
                } else if tag.count < 4_096 {
                    tag.append(character)
                }
                continue
            }
            if character == "<" {
                insideEntity = false
                entity.removeAll(keepingCapacity: true)
                insideTag = true
                continue
            }
            guard skippedElement == nil else { continue }
            if insideEntity {
                if character == ";" {
                    output.append(decodedEntity(entity))
                    entity.removeAll(keepingCapacity: true)
                    insideEntity = false
                } else if entity.count < 16 {
                    entity.append(character)
                } else {
                    output.append("&")
                    output.append(contentsOf: entity)
                    entity.removeAll(keepingCapacity: true)
                    insideEntity = false
                }
            } else if character == "&" {
                insideEntity = true
            } else if character.isWhitespace {
                appendSpace(to: &output)
            } else {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tagName(_ raw: String) -> (name: String, closing: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let closing = trimmed.hasPrefix("/")
        let body = closing ? trimmed.dropFirst() : trimmed[...]
        let name = body.prefix { $0.isLetter || $0.isNumber }.description
        return (name, closing)
    }

    private static func appendSpace(to output: inout String) {
        guard output.last?.isWhitespace != true else { return }
        output.append(" ")
    }

    private static func decodedEntity(_ value: String) -> Character {
        switch value.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        default:
            if value.hasPrefix("#x"), let scalar = UInt32(value.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init) {
                return Character(scalar)
            }
            if value.hasPrefix("#"), let scalar = UInt32(value.dropFirst()).flatMap(UnicodeScalar.init) {
                return Character(scalar)
            }
            return "�"
        }
    }
}
