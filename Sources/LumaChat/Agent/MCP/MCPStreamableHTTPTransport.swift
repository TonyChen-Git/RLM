import Foundation

actor MCPStreamableHTTPTransport: MCPTransport {
    private static let maximumBodyBytes = 16 * 1_024 * 1_024
    private static let maximumSSEEvents = 4_096

    private let configuration: MCPStreamableHTTPConfiguration
    private let session: URLSession
    private var sessionID: String?
    private var running = false
    private var generation: UInt64 = 0
    private var activeOperations: [UUID: Task<MCPJSONRPCResponse?, Error>] = [:]

    init(configuration: MCPStreamableHTTPConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let ephemeral = URLSessionConfiguration.ephemeral
            ephemeral.urlCache = nil
            ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: ephemeral,
                delegate: RejectingRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
    }

    func start() async throws {
        guard !running else { throw MCPError.alreadyRunning }
        generation &+= 1
        running = true
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        try Task.checkCancellation()
        guard running else { throw MCPError.notConnected }

        let operationID = UUID()
        let operationGeneration = generation
        let operation = Task { [self] in
            do {
                return try await performSend(request, generation: operationGeneration)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            }
        }
        activeOperations[operationID] = operation

        return try await withTaskCancellationHandler {
            do {
                let response = try await operation.value
                activeOperations[operationID] = nil
                return response
            } catch {
                activeOperations[operationID] = nil
                throw error
            }
        } onCancel: {
            operation.cancel()
        }
    }

    func stop() async {
        guard running || sessionID != nil || !activeOperations.isEmpty else { return }

        running = false
        generation &+= 1
        let operations = Array(activeOperations.values)
        activeOperations.removeAll()
        operations.forEach { $0.cancel() }

        guard let negotiatedSessionID = sessionID else { return }
        sessionID = nil

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        applyConfiguredHeaders(to: &request)
        request.setValue(negotiatedSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        _ = try? await boundedData(for: request, maximumBytes: 1 * 1_024 * 1_024)
    }

    private func performSend(
        _ request: MCPJSONRPCRequest,
        generation operationGeneration: UInt64
    ) async throws -> MCPJSONRPCResponse? {
        try ensureActive(operationGeneration)

        let negotiatedSessionID = sessionID
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try MCPWireCodec.encode(request)
        urlRequest.timeoutInterval = 30
        applyConfiguredHeaders(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if request.method != "initialize" {
            urlRequest.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let negotiatedSessionID {
            urlRequest.setValue(negotiatedSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (bytes, response) = try await responseBytes(for: urlRequest)
        try ensureActive(operationGeneration)
        let http = try validatedHTTPResponse(response, for: urlRequest)

        if http.statusCode == 404, negotiatedSessionID != nil {
            sessionID = nil
            throw MCPError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.transport("Streamable HTTP returned status \(http.statusCode).")
        }
        try negotiateSession(from: http)

        if http.statusCode == 202 {
            guard let requestID = request.id else { return nil }
            return try await receiveAsynchronousResponse(
                matching: requestID,
                includeProtocolHeader: request.method != "initialize",
                generation: operationGeneration
            )
        }

        // A JSON-RPC notification has no response. Do not keep an unexpected
        // server stream alive after its HTTP status has been validated.
        guard let requestID = request.id else { return nil }

        let contentType = normalizedContentType(http)
        if contentType == "text/event-stream" {
            return try await matchingSSEResponse(
                in: bytes,
                expectedID: requestID,
                generation: operationGeneration
            )
        }

        let data = try await collect(
            bytes,
            response: http,
            maximumBytes: Self.maximumBodyBytes,
            generation: operationGeneration
        )
        guard !data.isEmpty else {
            throw MCPError.invalidResponse("No JSON-RPC response was present in the HTTP body.")
        }
        let responses = try decodeResponses(from: data)
        guard let matched = responses.first(where: { $0.id == requestID }) else {
            throw MCPError.invalidResponse("No JSON-RPC response matched the request id.")
        }
        try validateMatchedResponse(matched)
        return matched
    }

    private func receiveAsynchronousResponse(
        matching requestID: MCPJSONRPCID,
        includeProtocolHeader: Bool,
        generation operationGeneration: UInt64
    ) async throws -> MCPJSONRPCResponse {
        try ensureActive(operationGeneration)

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        applyConfiguredHeaders(to: &request)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if includeProtocolHeader {
            request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        let negotiatedSessionID = sessionID
        if let negotiatedSessionID {
            request.setValue(negotiatedSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (bytes, response) = try await responseBytes(for: request)
        try ensureActive(operationGeneration)
        let http = try validatedHTTPResponse(response, for: request)
        if http.statusCode == 404, negotiatedSessionID != nil {
            sessionID = nil
            throw MCPError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.transport("Streamable HTTP receive stream returned status \(http.statusCode).")
        }
        guard normalizedContentType(http) == "text/event-stream" else {
            throw MCPError.invalidResponse("Streamable HTTP GET did not return text/event-stream.")
        }
        try negotiateSession(from: http)
        return try await matchingSSEResponse(
            in: bytes,
            expectedID: requestID,
            generation: operationGeneration
        )
    }

    private func matchingSSEResponse(
        in bytes: URLSession.AsyncBytes,
        expectedID: MCPJSONRPCID,
        generation operationGeneration: UInt64
    ) async throws -> MCPJSONRPCResponse {
        var decoder = BoundedMCPSSEDecoder(
            maximumBytes: Self.maximumBodyBytes,
            maximumEvents: Self.maximumSSEEvents
        )

        for try await byte in bytes {
            try Task.checkCancellation()
            try ensureActive(operationGeneration)
            for payload in try decoder.append(byte) {
                if let response = try matchingResponse(in: payload, expectedID: expectedID) {
                    return response
                }
            }
        }
        for payload in try decoder.finish() {
            if let response = try matchingResponse(in: payload, expectedID: expectedID) {
                return response
            }
        }
        throw MCPError.invalidResponse("SSE stream ended without a response matching the request id.")
    }

    private func matchingResponse(
        in payload: Data,
        expectedID: MCPJSONRPCID
    ) throws -> MCPJSONRPCResponse? {
        guard payload != Data("[DONE]".utf8) else { return nil }
        let responses = try decodeResponses(from: payload)
        guard let matched = responses.first(where: { $0.id == expectedID }) else {
            // Server notifications, requests, and responses for other in-flight
            // calls may share a receive stream. They are deliberately ignored here.
            return nil
        }
        try validateMatchedResponse(matched)
        return matched
    }

    private func decodeResponses(from data: Data) throws -> [MCPJSONRPCResponse] {
        do {
            if let batch = try? MCPWireCodec.decode([MCPJSONRPCResponse].self, from: data) {
                return batch
            }
            return [try MCPWireCodec.decode(MCPJSONRPCResponse.self, from: data)]
        } catch {
            throw MCPError.invalidResponse("Streamable HTTP contained malformed JSON-RPC data.")
        }
    }

    private func validateMatchedResponse(_ response: MCPJSONRPCResponse) throws {
        guard response.jsonrpc == nil || response.jsonrpc == "2.0" else {
            throw MCPError.invalidResponse("JSON-RPC response has an unsupported version.")
        }
        guard response.result != nil || response.error != nil else {
            throw MCPError.invalidResponse("JSON-RPC response contains neither result nor error.")
        }
    }

    private func responseBytes(
        for request: URLRequest
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.transport("HTTP request failed: \(error.localizedDescription)")
        }
    }

    private func validatedHTTPResponse(
        _ response: URLResponse,
        for request: URLRequest
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse("Streamable HTTP returned a non-HTTP response.")
        }
        guard AgentHTTPOrigin.isSameOrigin(configuration.endpoint, http.url) else {
            throw MCPError.invalidResponse("MCP response origin differs from the configured endpoint.")
        }
        // The production URLSession rejects redirects. This exact endpoint check
        // also protects injected/test sessions whose delegate policy is unknown.
        guard http.url?.absoluteURL == request.url?.absoluteURL else {
            throw MCPError.invalidResponse("MCP HTTP redirects are not allowed.")
        }
        return http
    }

    private func negotiateSession(from response: HTTPURLResponse) throws {
        guard let value = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty else {
            return
        }
        guard value.utf8.count <= 1_024,
              value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw MCPError.invalidResponse("Mcp-Session-Id contains invalid characters.")
        }
        sessionID = value
    }

    private func normalizedContentType(_ response: HTTPURLResponse) -> String {
        response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func applyConfiguredHeaders(to request: inout URLRequest) {
        for (field, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    private func ensureActive(_ operationGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard running, generation == operationGeneration else { throw CancellationError() }
    }

    private func collect(
        _ bytes: URLSession.AsyncBytes,
        response: URLResponse,
        maximumBytes: Int,
        generation operationGeneration: UInt64
    ) async throws -> Data {
        let expected = response.expectedContentLength
        if expected > Int64(maximumBytes) {
            throw MCPError.invalidResponse("HTTP body exceeds the \(maximumBytes)-byte limit.")
        }
        var data = Data()
        if expected > 0 {
            data.reserveCapacity(min(maximumBytes, Int(expected)))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            try ensureActive(operationGeneration)
            guard data.count < maximumBytes else {
                throw MCPError.invalidResponse("HTTP body exceeds the \(maximumBytes)-byte limit.")
            }
            data.append(byte)
        }
        return data
    }

    private func boundedData(
        for request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let expected = response.expectedContentLength
        if expected > Int64(maximumBytes) {
            throw MCPError.invalidResponse("HTTP body exceeds the \(maximumBytes)-byte limit.")
        }
        var data = Data()
        if expected > 0 {
            data.reserveCapacity(min(maximumBytes, Int(expected)))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
                throw MCPError.invalidResponse("HTTP body exceeds the \(maximumBytes)-byte limit.")
            }
            data.append(byte)
        }
        return (data, response)
    }
}

/// Incremental SSE framing with explicit byte and event budgets. Events are
/// emitted at the terminating blank line, so callers need not wait for the HTTP
/// response body to close after the matching JSON-RPC response has arrived.
private struct BoundedMCPSSEDecoder: Sendable {
    let maximumBytes: Int
    let maximumEvents: Int

    private var consumedBytes = 0
    private var emittedEvents = 0
    private var line = Data()
    private var dataLines: [Data] = []
    private var previousWasCarriageReturn = false

    init(maximumBytes: Int, maximumEvents: Int) {
        self.maximumBytes = maximumBytes
        self.maximumEvents = maximumEvents
    }

    mutating func append(_ byte: UInt8) throws -> [Data] {
        consumedBytes += 1
        guard consumedBytes <= maximumBytes else {
            throw MCPError.invalidResponse("SSE stream exceeds the \(maximumBytes)-byte limit.")
        }

        if byte == 0x0A { // LF, including the second byte of CRLF.
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                return []
            }
            return try finishLine()
        }
        if byte == 0x0D { // CR is also a valid SSE line ending.
            previousWasCarriageReturn = true
            return try finishLine()
        }

        previousWasCarriageReturn = false
        line.append(byte)
        return []
    }

    mutating func finish() throws -> [Data] {
        var payloads: [Data] = []
        if !line.isEmpty {
            payloads.append(contentsOf: try finishLine())
        }
        if let payload = try finishEvent() {
            payloads.append(payload)
        }
        return payloads
    }

    private mutating func finishLine() throws -> [Data] {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            return try finishEvent().map { [$0] } ?? []
        }
        guard line.first != 0x3A else { return [] } // SSE comment / heartbeat.

        let colon = line.firstIndex(of: 0x3A)
        let fieldEnd = colon ?? line.endIndex
        guard Data(line[..<fieldEnd]) == Data("data".utf8) else { return [] }

        var valueStart = colon.map { line.index(after: $0) } ?? line.endIndex
        if valueStart < line.endIndex, line[valueStart] == 0x20 {
            valueStart = line.index(after: valueStart)
        }
        dataLines.append(Data(line[valueStart..<line.endIndex]))
        return []
    }

    private mutating func finishEvent() throws -> Data? {
        guard !dataLines.isEmpty else { return nil }
        emittedEvents += 1
        guard emittedEvents <= maximumEvents else {
            throw MCPError.invalidResponse("SSE stream exceeds the \(maximumEvents)-event limit.")
        }

        var payload = Data()
        for (index, value) in dataLines.enumerated() {
            if index > 0 { payload.append(0x0A) }
            payload.append(value)
        }
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }
}
