import Foundation
import LumaChatSDK

struct LumaChatHeadlessServerConfiguration: Equatable, Sendable {
    static let defaultMaximumHeaderBytes = 65_536
    static let defaultMaximumJSONBytes = 4_194_304
    static let defaultMaximumEventBytes = 524_288
    static let defaultRequestIdleTimeoutSeconds: TimeInterval = 30
    static let defaultSSEHeartbeatIntervalSeconds: TimeInterval = 15
    static let defaultConnectionWriteTimeoutSeconds: TimeInterval = 15

    let bindHost: String
    let port: UInt16
    let bearerToken: String
    let allowNonLoopback: Bool
    let maximumHeaderBytes: Int
    let maximumJSONBytes: Int
    let maximumEventBytes: Int
    let requestIdleTimeoutSeconds: TimeInterval
    let sseHeartbeatIntervalSeconds: TimeInterval
    let connectionWriteTimeoutSeconds: TimeInterval

    init(
        bindHost: String = "127.0.0.1",
        port: UInt16 = 0,
        bearerToken: String,
        allowNonLoopback: Bool = false,
        maximumHeaderBytes: Int = Self.defaultMaximumHeaderBytes,
        maximumJSONBytes: Int = Self.defaultMaximumJSONBytes,
        maximumEventBytes: Int = Self.defaultMaximumEventBytes,
        requestIdleTimeoutSeconds: TimeInterval = Self.defaultRequestIdleTimeoutSeconds,
        sseHeartbeatIntervalSeconds: TimeInterval = Self.defaultSSEHeartbeatIntervalSeconds,
        connectionWriteTimeoutSeconds: TimeInterval = Self.defaultConnectionWriteTimeoutSeconds
    ) throws {
        let normalizedHost = bindHost.lowercased()
        let loopbackHosts = ["127.0.0.1", "::1", "localhost"]
        guard allowNonLoopback || loopbackHosts.contains(normalizedHost) else {
            throw ConfigurationError.nonLoopbackRequiresExplicitOptIn
        }
        guard Self.isValidBearerToken(bearerToken)
        else { throw ConfigurationError.invalidBearerToken }
        guard (1_024...262_144).contains(maximumHeaderBytes),
              (1_024...8_388_608).contains(maximumJSONBytes),
              (1_024...1_048_576).contains(maximumEventBytes),
              (1...300).contains(requestIdleTimeoutSeconds),
              (1...60).contains(sseHeartbeatIntervalSeconds),
              (1...60).contains(connectionWriteTimeoutSeconds) else {
            throw ConfigurationError.invalidLimits
        }
        self.bindHost = normalizedHost
        self.port = port
        self.bearerToken = bearerToken
        self.allowNonLoopback = allowNonLoopback
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumJSONBytes = maximumJSONBytes
        self.maximumEventBytes = maximumEventBytes
        self.requestIdleTimeoutSeconds = requestIdleTimeoutSeconds
        self.sseHeartbeatIntervalSeconds = sseHeartbeatIntervalSeconds
        self.connectionWriteTimeoutSeconds = connectionWriteTimeoutSeconds
    }

    static func generateBearerToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
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

    enum ConfigurationError: LocalizedError, Equatable {
        case nonLoopbackRequiresExplicitOptIn
        case invalidBearerToken
        case invalidLimits

        var errorDescription: String? {
            switch self {
            case .nonLoopbackRequiresExplicitOptIn:
                "A non-loopback App Server bind requires explicit opt-in."
            case .invalidBearerToken:
                "The App Server bearer token must be a 32-512 byte RFC 6750 bearer token."
            case .invalidLimits:
                "The App Server HTTP safety limits are invalid."
            }
        }
    }
}

struct LumaChatHeadlessHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        var normalizedHeaders: [String: String] = [:]
        for (name, value) in headers {
            normalizedHeaders[name.lowercased()] = value
        }
        self.headers = normalizedHeaders
        self.body = body
    }
}

struct LumaChatHeadlessHTTPResponse: Sendable {
    let status: Int
    var headers: [String: String]
    let body: Data
}

enum LumaChatHeadlessRouteResult: Sendable {
    case response(LumaChatHeadlessHTTPResponse)
    case events(headers: [String: String], stream: AsyncThrowingStream<LumaChatTaskEvent, Error>)
}

actor LumaChatHeadlessRequestRouter {
    private struct RoutingFailure: Error, Sendable {
        let status: Int
        let code: LumaChatAPIErrorCode
        let message: String
        let allow: String?

        init(
            status: Int,
            code: LumaChatAPIErrorCode,
            message: String,
            allow: String? = nil
        ) {
            self.status = status
            self.code = code
            self.message = message
            self.allow = allow
        }
    }

    private let runtime: any LumaChatHeadlessRuntimeFacade
    private let configuration: LumaChatHeadlessServerConfiguration
    private let expectedToken: [UInt8]
    private let serverID: UUID
    private let startedAt: Date

    init(
        runtime: any LumaChatHeadlessRuntimeFacade,
        configuration: LumaChatHeadlessServerConfiguration,
        serverID: UUID = UUID(),
        startedAt: Date = Date()
    ) {
        self.runtime = runtime
        self.configuration = configuration
        expectedToken = Array(configuration.bearerToken.utf8)
        self.serverID = serverID
        self.startedAt = startedAt
    }

    func handle(_ request: LumaChatHeadlessHTTPRequest) async -> LumaChatHeadlessRouteResult {
        let responseRequestID = requestIDHeader(request) ?? UUID().uuidString.lowercased()
        do {
            try validateHeaderEnvelope(request)
            try authenticate(request)
            let parsed = try parseTarget(request.target)
            try validateTransportEnvelope(request)
            return try await route(
                request,
                path: parsed.path,
                queryItems: parsed.queryItems,
                responseRequestID: responseRequestID
            )
        } catch let failure as RoutingFailure {
            return .response(errorResponse(
                status: failure.status,
                code: failure.code,
                message: failure.message,
                requestID: responseRequestID,
                allow: failure.allow
            ))
        } catch let failure as LumaChatHeadlessRuntimeFailure {
            return .response(errorResponse(
                status: failure.status,
                code: failure.code,
                message: failure.message,
                requestID: responseRequestID
            ))
        } catch {
            return .response(errorResponse(
                status: 500,
                code: .internalError,
                message: "Internal App Server error.",
                requestID: responseRequestID
            ))
        }
    }

    private func route(
        _ request: LumaChatHeadlessHTTPRequest,
        path: [String],
        queryItems: [URLQueryItem],
        responseRequestID: String
    ) async throws -> LumaChatHeadlessRouteResult {
        guard path.first == LumaChatAPIVersion.v1 else {
            throw RoutingFailure(status: 404, code: .notFound, message: "Route not found.")
        }

        if path == ["v1", "health"] {
            try requireMethod(request.method, allowed: ["GET"])
            try requireNoQuery(queryItems)
            return .response(try jsonResponse(
                status: 200,
                value: LumaChatHealth(
                    status: "ok",
                    apiVersion: LumaChatAPIVersion.v1,
                    serverID: serverID,
                    startedAt: startedAt
                ),
                requestID: responseRequestID
            ))
        }

        guard path.count >= 2, path[1] == "tasks" else {
            throw RoutingFailure(status: 404, code: .notFound, message: "Route not found.")
        }

        if path.count == 2 {
            try requireNoQuery(queryItems)
            switch request.method {
            case "GET":
                let tasks = try await runtime.listTasks()
                return .response(try jsonResponse(
                    status: 200,
                    value: LumaChatTaskList(tasks: tasks),
                    requestID: responseRequestID
                ))
            case "POST":
                var payload: LumaChatTaskCreateRequest = try decodeRequiredJSON(request)
                payload.requestID = try normalizedMutationID(
                    embedded: payload.requestID,
                    request: request
                )
                try validate(payload)
                let result = try await runtime.createTask(payload)
                return .response(try jsonResponse(
                    status: 201,
                    value: result,
                    requestID: responseRequestID
                ))
            default:
                throw methodNotAllowed(["GET", "POST"])
            }
        }

        guard path.count >= 3, let taskID = UUID(uuidString: path[2]) else {
            throw RoutingFailure(status: 404, code: .notFound, message: "Task route not found.")
        }

        if path.count == 3 {
            try requireMethod(request.method, allowed: ["GET"])
            try requireNoQuery(queryItems)
            return .response(try jsonResponse(
                status: 200,
                value: try await runtime.task(id: taskID),
                requestID: responseRequestID
            ))
        }

        guard path.count == 4 else {
            throw RoutingFailure(status: 404, code: .notFound, message: "Task route not found.")
        }

        switch path[3] {
        case "messages":
            try requireMethod(request.method, allowed: ["POST"])
            try requireNoQuery(queryItems)
            var payload: LumaChatMessageRequest = try decodeRequiredJSON(request)
            payload.requestID = try normalizedMutationID(embedded: payload.requestID, request: request)
            try validate(payload)
            return .response(try jsonResponse(
                status: 202,
                value: try await runtime.sendMessage(taskID: taskID, request: payload),
                requestID: responseRequestID
            ))

        case "events":
            try requireMethod(request.method, allowed: ["GET"])
            let cursor = try parseEventCursor(queryItems)
            let stream = try await runtime.events(taskID: taskID, afterSequence: cursor)
            return .events(
                headers: standardHeaders(requestID: responseRequestID).merging([
                    "Content-Type": "text/event-stream; charset=utf-8",
                    "Cache-Control": "no-cache, no-store",
                    "X-Accel-Buffering": "no"
                ]) { _, new in new },
                stream: stream
            )

        case "approve":
            try requireMethod(request.method, allowed: ["POST"])
            try requireNoQuery(queryItems)
            var payload: LumaChatApprovalDecisionRequest = try decodeRequiredJSON(request)
            payload.requestID = try normalizedMutationID(embedded: payload.requestID, request: request)
            return .response(try jsonResponse(
                status: 202,
                value: try await runtime.approve(taskID: taskID, request: payload),
                requestID: responseRequestID
            ))

        case "pause", "stop":
            try requireMethod(request.method, allowed: ["POST"])
            try requireNoQuery(queryItems)
            var payload = try decodeControlJSON(request)
            payload.requestID = try normalizedMutationID(embedded: payload.requestID, request: request)
            let result = path[3] == "pause"
                ? try await runtime.pause(taskID: taskID, request: payload)
                : try await runtime.stop(taskID: taskID, request: payload)
            return .response(try jsonResponse(
                status: 202,
                value: result,
                requestID: responseRequestID
            ))

        case "resume":
            try requireMethod(request.method, allowed: ["POST"])
            try requireNoQuery(queryItems)
            var payload = try decodeResumeJSON(request)
            payload.requestID = try normalizedMutationID(embedded: payload.requestID, request: request)
            try validateResume(payload)
            return .response(try jsonResponse(
                status: 202,
                value: try await runtime.resume(taskID: taskID, request: payload),
                requestID: responseRequestID
            ))

        case "diff":
            try requireMethod(request.method, allowed: ["GET"])
            try requireNoQuery(queryItems)
            return .response(try jsonResponse(
                status: 200,
                value: try await runtime.diff(taskID: taskID),
                requestID: responseRequestID
            ))

        default:
            throw RoutingFailure(status: 404, code: .notFound, message: "Task route not found.")
        }
    }

    private func authenticate(_ request: LumaChatHeadlessHTTPRequest) throws {
        guard let authorization = request.headers["authorization"], authorization.count >= 7,
              authorization.prefix(7).lowercased() == "bearer " else {
            throw RoutingFailure(status: 401, code: .unauthorized, message: "Bearer token required.")
        }
        let supplied = Array(authorization.dropFirst("Bearer ".count).utf8)
        guard constantTimeEqual(supplied, expectedToken) else {
            throw RoutingFailure(status: 401, code: .unauthorized, message: "Bearer token is invalid.")
        }
    }

    private func validateHeaderEnvelope(_ request: LumaChatHeadlessHTTPRequest) throws {
        var byteCount = request.method.utf8.count + request.target.utf8.count + 12
        guard !request.method.isEmpty,
              request.method.utf8.allSatisfy(Self.isHTTPTokenByte) else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Invalid HTTP method.")
        }
        for (name, value) in request.headers {
            let (lineBytes, overflow) = name.utf8.count
                .addingReportingOverflow(value.utf8.count + 4)
            guard !overflow,
                  !name.isEmpty,
                  name.utf8.allSatisfy(Self.isHTTPTokenByte),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw RoutingFailure(status: 400, code: .invalidRequest, message: "Unsafe HTTP header.")
            }
            let (total, totalOverflow) = byteCount.addingReportingOverflow(lineBytes)
            guard !totalOverflow else {
                throw RoutingFailure(status: 431, code: .payloadTooLarge, message: "HTTP headers are too large.")
            }
            byteCount = total
        }
        guard byteCount <= configuration.maximumHeaderBytes else {
            throw RoutingFailure(status: 431, code: .payloadTooLarge, message: "HTTP headers are too large.")
        }
    }

    private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = lhs.count ^ rhs.count
        let width = max(lhs.count, rhs.count)
        for index in 0..<width {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }

    private func parseTarget(_ target: String) throws -> (path: [String], queryItems: [URLQueryItem]) {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), target.utf8.count <= 4_096,
              let components = URLComponents(string: "http://localhost\(target)"),
              components.fragment == nil else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Invalid request target.")
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.contains("."), !path.contains("..") else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Invalid request path.")
        }
        return (path, components.queryItems ?? [])
    }

    private func validateTransportEnvelope(_ request: LumaChatHeadlessHTTPRequest) throws {
        guard request.body.count <= configuration.maximumJSONBytes else {
            throw RoutingFailure(status: 413, code: .payloadTooLarge, message: "JSON body is too large.")
        }
        guard request.headers["transfer-encoding"] == nil else {
            throw RoutingFailure(
                status: 400,
                code: .invalidRequest,
                message: "Transfer-Encoding is not supported."
            )
        }
        if request.method == "GET", !request.body.isEmpty {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "GET body is not allowed.")
        }
        if !request.body.isEmpty {
            guard request.headers["content-type"].map({
                Self.mediaType($0) == "application/json"
            }) == true else {
                throw RoutingFailure(
                    status: 415,
                    code: .unsupportedMediaType,
                    message: "Content-Type must be application/json."
                )
            }
        }
    }

    private func decodeRequiredJSON<Value: Decodable>(
        _ request: LumaChatHeadlessHTTPRequest
    ) throws -> Value {
        guard !request.body.isEmpty else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "JSON body is required.")
        }
        return try decodeJSON(request.body)
    }

    private func decodeControlJSON(_ request: LumaChatHeadlessHTTPRequest) throws -> LumaChatControlRequest {
        request.body.isEmpty ? .init(requestID: nil) : try decodeJSON(request.body)
    }

    private func decodeResumeJSON(_ request: LumaChatHeadlessHTTPRequest) throws -> LumaChatResumeRequest {
        request.body.isEmpty ? .init(requestID: nil) : try decodeJSON(request.body)
    }

    private func decodeJSON<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            var nodeCount = 0
            try validateJSONShape(object, depth: 0, nodeCount: &nodeCount)
            return try Self.decoder().decode(Value.self, from: data)
        } catch let failure as RoutingFailure {
            throw failure
        } catch {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Malformed JSON body.")
        }
    }

    private func validateJSONShape(_ value: Any, depth: Int, nodeCount: inout Int) throws {
        nodeCount += 1
        guard depth <= 32, nodeCount <= 20_000 else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "JSON structure is too complex.")
        }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                guard key.utf8.count <= 512 else {
                    throw RoutingFailure(status: 400, code: .invalidRequest, message: "JSON key is too long.")
                }
                try validateJSONShape(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        } else if let array = value as? [Any] {
            for child in array {
                try validateJSONShape(child, depth: depth + 1, nodeCount: &nodeCount)
            }
        }
    }

    private func normalizedMutationID(
        embedded: UUID?,
        request: LumaChatHeadlessHTTPRequest
    ) throws -> UUID {
        let headerID: UUID?
        if let raw = request.headers["x-request-id"] {
            guard let parsed = UUID(uuidString: raw) else {
                throw RoutingFailure(status: 400, code: .invalidRequest, message: "X-Request-ID must be a UUID.")
            }
            headerID = parsed
        } else {
            headerID = nil
        }
        if let embedded, let headerID, embedded != headerID {
            throw RoutingFailure(
                status: 400,
                code: .invalidRequest,
                message: "Body requestID and X-Request-ID do not match."
            )
        }
        return embedded ?? headerID ?? UUID()
    }

    private func validate(_ request: LumaChatTaskCreateRequest) throws {
        guard request.mode != .chat else {
            throw RoutingFailure(
                status: 400,
                code: .invalidRequest,
                message: "The task API accepts plan or agent mode; use the chat API for classic chat."
            )
        }
        try validateText(request.workspacePath, name: "workspacePath", maximumBytes: 4_096, allowNewlines: false)
        guard request.workspacePath.hasPrefix("/"), !request.workspacePath.hasPrefix("//") else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "workspacePath must be absolute.")
        }
        try validateText(request.backendID, name: "backendID", maximumBytes: 256, allowNewlines: false)
        try validateText(request.modelID, name: "modelID", maximumBytes: 512, allowNewlines: false)
        if let title = request.title {
            try validateText(title, name: "title", maximumBytes: 512, allowNewlines: false)
        }
    }

    private func validate(_ request: LumaChatMessageRequest) throws {
        try validateText(request.content, name: "content", maximumBytes: 1_048_576, allowNewlines: true)
    }

    private func validateResume(_ request: LumaChatResumeRequest) throws {
        if let content = request.content {
            try validateText(content, name: "content", maximumBytes: 1_048_576, allowNewlines: true)
        }
    }

    private func validateText(
        _ value: String,
        name: String,
        maximumBytes: Int,
        allowNewlines: Bool
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumBytes else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "\(name) is empty or too large.")
        }
        let invalidControl = value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            return allowNewlines
                ? scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D
                : true
        }
        guard !invalidControl else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "\(name) contains control data.")
        }
    }

    private func parseEventCursor(_ items: [URLQueryItem]) throws -> UInt64? {
        guard items.count <= 1 else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Invalid event cursor.")
        }
        guard let item = items.first else { return nil }
        guard item.name == "after", let value = item.value, let cursor = UInt64(value) else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Invalid event cursor.")
        }
        return cursor
    }

    private func requireNoQuery(_ items: [URLQueryItem]) throws {
        guard items.isEmpty else {
            throw RoutingFailure(status: 400, code: .invalidRequest, message: "Query parameters are not supported.")
        }
    }

    private func requireMethod(_ method: String, allowed: [String]) throws {
        guard allowed.contains(method) else { throw methodNotAllowed(allowed) }
    }

    private func methodNotAllowed(_ allowed: [String]) -> RoutingFailure {
        RoutingFailure(
            status: 405,
            code: .methodNotAllowed,
            message: "Method not allowed.",
            allow: allowed.joined(separator: ", ")
        )
    }

    private func jsonResponse<Value: Encodable>(
        status: Int,
        value: Value,
        requestID: String
    ) throws -> LumaChatHeadlessHTTPResponse {
        let body = try Self.encoder().encode(value)
        guard body.count <= configuration.maximumJSONBytes else {
            throw RoutingFailure(status: 500, code: .internalError, message: "Response exceeded its safety limit.")
        }
        var headers = standardHeaders(requestID: requestID)
        headers["Content-Type"] = "application/json; charset=utf-8"
        return LumaChatHeadlessHTTPResponse(status: status, headers: headers, body: body)
    }

    private func errorResponse(
        status: Int,
        code: LumaChatAPIErrorCode,
        message: String,
        requestID: String,
        allow: String? = nil
    ) -> LumaChatHeadlessHTTPResponse {
        let value = LumaChatAPIErrorEnvelope(error: .init(
            code: code,
            message: message,
            requestID: requestID
        ))
        let body = (try? Self.encoder().encode(value)) ?? Data()
        var headers = standardHeaders(requestID: requestID)
        headers["Content-Type"] = "application/json; charset=utf-8"
        if status == 401 { headers["WWW-Authenticate"] = "Bearer" }
        if let allow { headers["Allow"] = allow }
        return LumaChatHeadlessHTTPResponse(status: status, headers: headers, body: body)
    }

    private func standardHeaders(requestID: String) -> [String: String] {
        [
            "X-LumaChat-API-Version": LumaChatAPIVersion.v1,
            "X-Request-ID": requestID,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ]
    }

    private func requestIDHeader(_ request: LumaChatHeadlessHTTPRequest) -> String? {
        guard let raw = request.headers["x-request-id"], UUID(uuidString: raw) != nil else { return nil }
        return raw.lowercased()
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

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }

    private static func mediaType(_ value: String) -> String {
        guard let first = value.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else { return "" }
        return String(first).trimmingCharacters(in: .whitespaces).lowercased()
    }
}
