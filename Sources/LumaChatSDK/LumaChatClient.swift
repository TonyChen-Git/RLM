import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LumaChatClientError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidResponse
    case requestTooLarge(maximumBytes: Int)
    case responseTooLarge(maximumBytes: Int)
    case eventTooLarge(maximumBytes: Int)
    case eventBufferOverflow
    case api(status: Int, error: LumaChatAPIErrorBody)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): detail
        case .invalidResponse: "The LumaChat server returned an invalid HTTP response."
        case .requestTooLarge(let maximum):
            "The LumaChat request exceeded the \(maximum)-byte safety limit."
        case .responseTooLarge(let maximum):
            "The LumaChat response exceeded the \(maximum)-byte safety limit."
        case .eventTooLarge(let maximum):
            "A LumaChat event exceeded the \(maximum)-byte safety limit."
        case .eventBufferOverflow:
            "The event consumer fell behind the bounded client buffer; reconnect with the last sequence."
        case .api(_, let error): error.message
        case .transport(let detail): detail
        }
    }
}

/// A small, dependency-free Swift client for the v1 JSON/SSE API. This target
/// intentionally does not import the LumaChat app executable or its UI models.
public final class LumaChatClient: @unchecked Sendable {
    public static let defaultMaximumJSONBytes = 4_194_304
    public static let defaultMaximumEventBytes = 524_288

    private let baseURL: URL
    private let bearerToken: String
    private let session: URLSession
    private let maximumJSONBytes: Int
    private let maximumEventBytes: Int

    public init(
        baseURL: URL,
        bearerToken: String,
        session: URLSession = .shared,
        maximumJSONBytes: Int = LumaChatClient.defaultMaximumJSONBytes,
        maximumEventBytes: Int = LumaChatClient.defaultMaximumEventBytes
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw LumaChatClientError.invalidConfiguration(
                "The App Server base URL must be an HTTP(S) origin without credentials or query data."
            )
        }
        guard Self.isValidBearerToken(bearerToken) else {
            throw LumaChatClientError.invalidConfiguration(
                "The bearer token must be a 32-512 byte RFC 6750 bearer token."
            )
        }
        guard (1...8_388_608).contains(maximumJSONBytes),
              (1...1_048_576).contains(maximumEventBytes) else {
            throw LumaChatClientError.invalidConfiguration("Client response limits are invalid.")
        }
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
        self.maximumJSONBytes = maximumJSONBytes
        self.maximumEventBytes = maximumEventBytes
    }

    public func health() async throws -> LumaChatHealth {
        let value: LumaChatHealth = try await perform(
            method: "GET",
            components: ["health"],
            body: Optional<Data>.none
        )
        guard value.apiVersion == LumaChatAPIVersion.v1 else {
            throw LumaChatClientError.invalidResponse
        }
        return value
    }

    public func createTask(_ request: LumaChatTaskCreateRequest) async throws -> LumaChatTaskSnapshot {
        let value: LumaChatTaskSnapshot = try await perform(
            method: "POST",
            components: ["tasks"],
            value: request
        )
        guard value.mode == request.mode,
              value.backendID == request.backendID,
              value.modelID == request.modelID else {
            throw LumaChatClientError.invalidResponse
        }
        return value
    }

    public func tasks() async throws -> LumaChatTaskList {
        try await perform(method: "GET", components: ["tasks"], body: Optional<Data>.none)
    }

    public func task(id: UUID) async throws -> LumaChatTaskSnapshot {
        let value: LumaChatTaskSnapshot = try await perform(
            method: "GET",
            components: ["tasks", id.uuidString.lowercased()],
            body: Optional<Data>.none
        )
        guard value.id == id else { throw LumaChatClientError.invalidResponse }
        return value
    }

    public func sendMessage(
        taskID: UUID,
        request: LumaChatMessageRequest
    ) async throws -> LumaChatAcceptedOperation {
        let value: LumaChatAcceptedOperation = try await perform(
            method: "POST",
            components: ["tasks", taskID.uuidString.lowercased(), "messages"],
            value: request
        )
        return try Self.validate(value, taskID: taskID, requestID: request.requestID)
    }

    public func approve(
        taskID: UUID,
        request: LumaChatApprovalDecisionRequest
    ) async throws -> LumaChatAcceptedOperation {
        let value: LumaChatAcceptedOperation = try await perform(
            method: "POST",
            components: ["tasks", taskID.uuidString.lowercased(), "approve"],
            value: request
        )
        return try Self.validate(value, taskID: taskID, requestID: request.requestID)
    }

    public func pause(
        taskID: UUID,
        request: LumaChatControlRequest = .init()
    ) async throws -> LumaChatAcceptedOperation {
        try await control(taskID: taskID, action: "pause", request: request)
    }

    public func resume(
        taskID: UUID,
        request: LumaChatResumeRequest = .init()
    ) async throws -> LumaChatAcceptedOperation {
        let value: LumaChatAcceptedOperation = try await perform(
            method: "POST",
            components: ["tasks", taskID.uuidString.lowercased(), "resume"],
            value: request
        )
        return try Self.validate(value, taskID: taskID, requestID: request.requestID)
    }

    public func stop(
        taskID: UUID,
        request: LumaChatControlRequest = .init()
    ) async throws -> LumaChatAcceptedOperation {
        try await control(taskID: taskID, action: "stop", request: request)
    }

    public func diff(taskID: UUID) async throws -> LumaChatTaskDiff {
        let value: LumaChatTaskDiff = try await perform(
            method: "GET",
            components: ["tasks", taskID.uuidString.lowercased(), "diff"],
            body: Optional<Data>.none
        )
        guard value.taskID == taskID else { throw LumaChatClientError.invalidResponse }
        return value
    }

    /// Opens an authenticated SSE stream. `afterSequence` is an exclusive
    /// cursor, allowing reconnect without replaying an already-consumed event.
    public func events(
        taskID: UUID,
        afterSequence: UInt64? = nil
    ) -> AsyncThrowingStream<LumaChatTaskEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task { [baseURL, bearerToken, session, maximumJSONBytes, maximumEventBytes] in
                do {
                    var url = Self.endpointURL(
                        baseURL: baseURL,
                        components: ["tasks", taskID.uuidString.lowercased(), "events"]
                    )
                    if let afterSequence {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.queryItems = [
                            URLQueryItem(name: "after", value: String(afterSequence))
                        ]
                        guard let cursorURL = components?.url else {
                            throw LumaChatClientError.invalidConfiguration("Invalid event cursor URL.")
                        }
                        url = cursorURL
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    request.setValue(LumaChatAPIVersion.v1, forHTTPHeaderField: "X-LumaChat-API-Version")

                    let (bytes, rawResponse) = try await session.bytes(
                        for: request,
                        delegate: LumaChatSDKRedirectDelegate()
                    )
                    guard let response = rawResponse as? HTTPURLResponse,
                          response.url == request.url,
                          Self.hasExpectedAPIVersion(response) else {
                        throw LumaChatClientError.invalidResponse
                    }
                    guard response.statusCode == 200 else {
                        guard response.value(forHTTPHeaderField: "Content-Type").map({
                            Self.mediaType($0) == "application/json"
                        }) == true else {
                            throw LumaChatClientError.invalidResponse
                        }
                        let body = try await Self.readLimited(bytes, maximumBytes: maximumJSONBytes)
                        throw Self.apiError(status: response.statusCode, data: body)
                    }
                    guard response.value(forHTTPHeaderField: "Content-Type").map({
                        Self.mediaType($0) == "text/event-stream"
                    }) == true else {
                        throw LumaChatClientError.invalidResponse
                    }

                    var line = Data()
                    var eventData = Data()
                    var eventName: String?
                    var eventID: String?
                    var lastSequence = afterSequence ?? 0

                    func flushEvent() throws {
                        guard !eventData.isEmpty else {
                            eventName = nil
                            eventID = nil
                            return
                        }
                        if eventData.last == 0x0A { eventData.removeLast() }
                        let event = try Self.decoder().decode(LumaChatTaskEvent.self, from: eventData)
                        guard event.taskID == taskID, event.sequence > lastSequence else {
                            throw LumaChatClientError.invalidResponse
                        }
                        if let eventName, eventName != event.kind.rawValue {
                            throw LumaChatClientError.invalidResponse
                        }
                        if let eventID, UInt64(eventID) != event.sequence {
                            throw LumaChatClientError.invalidResponse
                        }
                        guard case .enqueued = continuation.yield(event) else {
                            throw LumaChatClientError.eventBufferOverflow
                        }
                        lastSequence = event.sequence
                        eventData.removeAll(keepingCapacity: true)
                        eventName = nil
                        eventID = nil
                    }

                    func consumeLine() throws {
                        if line.last == 0x0D { line.removeLast() }
                        defer { line.removeAll(keepingCapacity: true) }
                        guard !line.isEmpty else {
                            try flushEvent()
                            return
                        }
                        if line.first == 0x3A { return }
                        guard let string = String(data: line, encoding: .utf8) else {
                            throw LumaChatClientError.invalidResponse
                        }
                        let pieces = string.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        let field = String(pieces[0])
                        var value = pieces.count == 2 ? String(pieces[1]) : ""
                        if value.first == " " { value.removeFirst() }
                        switch field {
                        case "data":
                            guard let encoded = value.data(using: .utf8),
                                  eventData.count + encoded.count + 1 <= maximumEventBytes else {
                                throw LumaChatClientError.eventTooLarge(maximumBytes: maximumEventBytes)
                            }
                            eventData.append(encoded)
                            eventData.append(0x0A)
                        case "event": eventName = value
                        case "id": eventID = value
                        default: break
                        }
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 0x0A {
                            try consumeLine()
                        } else {
                            guard line.count < maximumEventBytes else {
                                throw LumaChatClientError.eventTooLarge(maximumBytes: maximumEventBytes)
                            }
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty { try consumeLine() }
                    try flushEvent()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LumaChatClientError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LumaChatClientError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func control(
        taskID: UUID,
        action: String,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation {
        let value: LumaChatAcceptedOperation = try await perform(
            method: "POST",
            components: ["tasks", taskID.uuidString.lowercased(), action],
            value: request
        )
        return try Self.validate(value, taskID: taskID, requestID: request.requestID)
    }

    private func perform<Request: Encodable, Response: Decodable>(
        method: String,
        components: [String],
        value: Request
    ) async throws -> Response {
        let data: Data
        do {
            data = try Self.encoder().encode(value)
        } catch {
            throw LumaChatClientError.invalidConfiguration("The request could not be encoded.")
        }
        return try await perform(method: method, components: components, body: data)
    }

    private func perform<Response: Decodable>(
        method: String,
        components: [String],
        body: Data?
    ) async throws -> Response {
        guard (body?.count ?? 0) <= maximumJSONBytes else {
            throw LumaChatClientError.requestTooLarge(maximumBytes: maximumJSONBytes)
        }
        var request = URLRequest(url: Self.endpointURL(baseURL: baseURL, components: components))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(LumaChatAPIVersion.v1, forHTTPHeaderField: "X-LumaChat-API-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }

        do {
            let (bytes, rawResponse) = try await session.bytes(
                for: request,
                delegate: LumaChatSDKRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse,
                  response.url == request.url,
                  Self.hasExpectedAPIVersion(response),
                  response.value(forHTTPHeaderField: "Content-Type").map({
                    Self.mediaType($0) == "application/json"
                  }) == true else {
                throw LumaChatClientError.invalidResponse
            }
            if let contentLength = response.value(forHTTPHeaderField: "Content-Length") {
                guard let length = Int(contentLength), length >= 0 else {
                    throw LumaChatClientError.invalidResponse
                }
                if length > maximumJSONBytes {
                    throw LumaChatClientError.responseTooLarge(maximumBytes: maximumJSONBytes)
                }
            }
            let data = try await Self.readLimited(bytes, maximumBytes: maximumJSONBytes)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.apiError(status: response.statusCode, data: data)
            }
            do {
                return try Self.decoder().decode(Response.self, from: data)
            } catch {
                throw LumaChatClientError.invalidResponse
            }
        } catch let error as LumaChatClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LumaChatClientError.transport(error.localizedDescription)
        }
    }

    private static func endpointURL(baseURL: URL, components: [String]) -> URL {
        var url = baseURL
        url.appendPathComponent(LumaChatAPIVersion.v1, isDirectory: true)
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component, isDirectory: index < components.count - 1)
        }
        return url
    }

    private static func readLimited<S: AsyncSequence>(
        _ bytes: S,
        maximumBytes: Int
    ) async throws -> Data where S.Element == UInt8 {
        var result = Data()
        result.reserveCapacity(min(maximumBytes, 16_384))
        for try await byte in bytes {
            guard result.count < maximumBytes else {
                throw LumaChatClientError.responseTooLarge(maximumBytes: maximumBytes)
            }
            result.append(byte)
        }
        return result
    }

    private static func apiError(status: Int, data: Data) -> LumaChatClientError {
        if let envelope = try? decoder().decode(LumaChatAPIErrorEnvelope.self, from: data) {
            return .api(status: status, error: envelope.error)
        }
        return .api(
            status: status,
            error: LumaChatAPIErrorBody(
                code: .internalError,
                message: "The LumaChat server returned HTTP \(status)."
            )
        )
    }

    private static func validate(
        _ operation: LumaChatAcceptedOperation,
        taskID: UUID,
        requestID: UUID?
    ) throws -> LumaChatAcceptedOperation {
        guard operation.accepted, operation.taskID == taskID,
              requestID == nil || operation.requestID == requestID else {
            throw LumaChatClientError.invalidResponse
        }
        return operation
    }

    private static func hasExpectedAPIVersion(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "X-LumaChat-API-Version") == LumaChatAPIVersion.v1
    }

    private static func isValidBearerToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard (32...512).contains(bytes.count) else { return false }
        var sawPadding = false
        for byte in bytes {
            if byte == 61 {
                sawPadding = true
                continue
            }
            guard !sawPadding else { return false }
            switch byte {
            case 45, 46, 48...57, 65...90, 95, 97...122, 126, 43, 47:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func mediaType(_ value: String) -> String {
        guard let first = value.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else { return "" }
        return String(first).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Authentication-bearing SDK requests never forward the bearer token through
/// an HTTP redirect. Callers must opt into a different App Server origin by
/// constructing a new client explicitly.
private final class LumaChatSDKRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
