import Foundation

struct BrowserCDPEvent: Equatable, Sendable {
    let sequence: UInt64
    let method: String
    let params: JSONValue
}

private struct BrowserCDPCommand: Encodable, Sendable {
    let id: Int64
    let method: String
    let params: JSONValue
}

private struct BrowserCDPErrorPayload: Decodable, Sendable {
    let code: Int
    let message: String
}

private struct BrowserCDPEnvelope: Decodable, Sendable {
    let id: Int64?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: BrowserCDPErrorPayload?
}

private struct BrowserCDPPendingRequest {
    let method: String
    let continuation: CheckedContinuation<JSONValue, Error>
}

private struct BrowserCDPStoredEvent: Sendable {
    let event: BrowserCDPEvent
    let encodedBytes: Int
}

/// A single bounded Chrome DevTools Protocol connection. Only loopback
/// WebSockets are accepted; Chromium is launched with a loopback-only endpoint.
actor CDPWebSocketConnection {
    let endpoint: URL

    private let urlSession: URLSession
    private let webSocket: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private var timeoutTasks: [Int64: Task<Void, Never>] = [:]
    private var pending: [Int64: BrowserCDPPendingRequest] = [:]
    private var events: [BrowserCDPStoredEvent] = []
    private var storedEventBytes = 0
    private var nextCommandID: Int64 = 0
    private var nextEventSequence: UInt64 = 0
    private var running = false

    init(endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "ws",
              AgentHTTPOrigin.isLoopback(endpoint.host),
              let port = endpoint.port,
              (1...65_535).contains(port),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path.utf8.count <= 1_024 else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        self.endpoint = endpoint

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = BrowserBounds.maximumCommandTimeout
        configuration.timeoutIntervalForResource = BrowserBounds.maximumCommandTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: configuration,
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = BrowserBounds.maximumCommandTimeout
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = BrowserBounds.maximumCDPMessageBytes
        urlSession = session
        webSocket = socket
    }

    func start() throws {
        guard !running else { return }
        running = true
        webSocket.resume()
        receiveTask = Task { [weak self, webSocket] in
            while !Task.isCancelled {
                do {
                    let message = try await webSocket.receive()
                    guard let self else {
                        webSocket.cancel(with: .goingAway, reason: nil)
                        return
                    }
                    do {
                        try await self.receive(message)
                    } catch let error as BrowserError {
                        await self.connectionFailed(with: error)
                        return
                    } catch {
                        await self.connectionFailed(with: BrowserError.websocketClosed)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await self?.connectionFailed(with: BrowserError.websocketClosed)
                    return
                }
            }
        }
    }

    func command(
        _ method: String,
        params: JSONValue = .emptyObject,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard running else { throw BrowserError.websocketClosed }
        guard !method.isEmpty,
              method.utf8.count <= 128,
              method.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 46, 95:
                      true
                  default:
                      false
                  }
              }) else {
            throw BrowserError.protocolViolation("Command method is invalid.")
        }
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumCommandTimeout,
            maximum: BrowserBounds.maximumCommandTimeout
        )
        guard pending.count < BrowserBounds.maximumPendingCommands else {
            throw BrowserError.tooManyPendingCommands(BrowserBounds.maximumPendingCommands)
        }
        try BrowserBounds.validateJSON(
            params,
            maximumDepth: 32,
            maximumValues: 20_000,
            maximumStringBytes: BrowserBounds.maximumJavaScriptResultBytes
        )

        nextCommandID &+= 1
        guard nextCommandID > 0 else {
            nextCommandID = 1
            guard pending.isEmpty else {
                throw BrowserError.protocolViolation("Command identifier exhausted.")
            }
        }
        let commandID = nextCommandID
        let payload = try JSONEncoder().encode(
            BrowserCDPCommand(id: commandID, method: method, params: params)
        )
        guard payload.count <= BrowserBounds.maximumCDPMessageBytes,
              let payloadText = String(data: payload, encoding: .utf8) else {
            throw BrowserError.responseTooLarge(BrowserBounds.maximumCDPMessageBytes)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[commandID] = BrowserCDPPendingRequest(
                    method: method,
                    continuation: continuation
                )
                timeoutTasks[commandID] = Task { [weak self] in
                    let milliseconds = Int64((boundedTimeout * 1_000).rounded(.up))
                    do {
                        try await Task.sleep(for: .milliseconds(milliseconds))
                    } catch {
                        return
                    }
                    await self?.expireCommand(commandID)
                }
                Task { [weak self] in
                    await self?.transmit(payloadText, commandID: commandID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelCommand(commandID)
            }
        }
    }

    func recentEvents(
        methods: Set<String>,
        afterSequence: UInt64? = nil,
        limit: Int
    ) throws -> [BrowserCDPEvent] {
        let boundedLimit = try BrowserBounds.validatedResultLimit(limit)
        let filtered = events.lazy.filter { stored in
            methods.contains(stored.event.method)
                && afterSequence.map { stored.event.sequence > $0 } != false
        }
        return Array(filtered.suffix(boundedLimit).map(\.event))
    }

    func isOpen() -> Bool { running }

    func latestEventSequence() -> UInt64 { nextEventSequence }

    func clearEvents(methods: Set<String>) {
        guard !methods.isEmpty else {
            events.removeAll(keepingCapacity: false)
            storedEventBytes = 0
            return
        }
        events.removeAll { stored in
            guard methods.contains(stored.event.method) else { return false }
            storedEventBytes -= stored.encodedBytes
            return true
        }
    }

    func close() {
        guard running || !pending.isEmpty || receiveTask != nil else { return }
        running = false
        receiveTask?.cancel()
        receiveTask = nil
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        webSocket.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        failPending(with: BrowserError.websocketClosed)
        events.removeAll(keepingCapacity: false)
        storedEventBytes = 0
    }

    private func transmit(_ payload: String, commandID: Int64) async {
        guard running, pending[commandID] != nil else { return }
        do {
            try await webSocket.send(.string(payload))
        } catch is CancellationError {
            cancelCommand(commandID)
        } catch {
            failCommand(commandID, with: BrowserError.websocketClosed)
            connectionFailed(with: BrowserError.websocketClosed)
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            guard let value = value.data(using: .utf8) else {
                throw BrowserError.protocolViolation("WebSocket text was not UTF-8.")
            }
            data = value
        @unknown default:
            throw BrowserError.protocolViolation("Unknown WebSocket message type.")
        }
        guard data.count <= BrowserBounds.maximumCDPMessageBytes else {
            throw BrowserError.responseTooLarge(BrowserBounds.maximumCDPMessageBytes)
        }

        let envelope: BrowserCDPEnvelope
        do {
            envelope = try JSONDecoder().decode(BrowserCDPEnvelope.self, from: data)
        } catch {
            throw BrowserError.protocolViolation("Malformed JSON envelope.")
        }

        if let id = envelope.id {
            guard let request = pending.removeValue(forKey: id) else {
                // A response may arrive after its bounded timeout or cancellation.
                return
            }
            timeoutTasks.removeValue(forKey: id)?.cancel()
            if let payload = envelope.error {
                let message = BrowserBounds.boundedUTF8(
                    SecretRedactor().redact(payload.message),
                    maximumBytes: 4_096
                ).0
                request.continuation.resume(
                    throwing: BrowserError.protocolError(code: payload.code, message: message)
                )
                return
            }
            guard let result = envelope.result else {
                request.continuation.resume(
                    throwing: BrowserError.protocolViolation(
                        "Response to \(request.method) contained neither a result nor an error."
                    )
                )
                return
            }
            do {
                try BrowserBounds.validateJSON(result)
                request.continuation.resume(returning: result)
            } catch {
                request.continuation.resume(throwing: error)
            }
            return
        }

        guard let method = envelope.method,
              !method.isEmpty,
              method.utf8.count <= 128 else {
            throw BrowserError.protocolViolation("Event method is missing or invalid.")
        }
        let rawParams = envelope.params ?? .emptyObject
        try BrowserBounds.validateJSON(rawParams)
        guard let params = BrowserSecuritySanitizer.retainedEvent(
            method: method,
            params: rawParams
        ) else {
            return
        }
        let encodedBytes = try JSONEncoder().encode(params).count + method.utf8.count
        guard encodedBytes <= BrowserBounds.maximumStoredEventBytes else {
            // Page-controlled console payloads can be arbitrarily large. They
            // are intentionally omitted rather than retained without a bound.
            return
        }
        nextEventSequence &+= 1
        events.append(
            BrowserCDPStoredEvent(
                event: BrowserCDPEvent(
                    sequence: nextEventSequence,
                    method: method,
                    params: params
                ),
                encodedBytes: encodedBytes
            )
        )
        storedEventBytes += encodedBytes
        trimEvents()
    }

    private func trimEvents() {
        while events.count > BrowserBounds.maximumStoredEvents
            || storedEventBytes > BrowserBounds.maximumStoredEventsBytes {
            let removed = events.removeFirst()
            storedEventBytes -= removed.encodedBytes
        }
    }

    private func expireCommand(_ commandID: Int64) {
        guard let request = pending.removeValue(forKey: commandID) else { return }
        timeoutTasks.removeValue(forKey: commandID)?.cancel()
        request.continuation.resume(throwing: BrowserError.commandTimedOut(request.method))
    }

    private func cancelCommand(_ commandID: Int64) {
        guard let request = pending.removeValue(forKey: commandID) else { return }
        timeoutTasks.removeValue(forKey: commandID)?.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func failCommand(_ commandID: Int64, with error: Error) {
        guard let request = pending.removeValue(forKey: commandID) else { return }
        timeoutTasks.removeValue(forKey: commandID)?.cancel()
        request.continuation.resume(throwing: error)
    }

    private func connectionFailed(with error: Error) {
        running = false
        receiveTask?.cancel()
        receiveTask = nil
        webSocket.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        failPending(with: error)
    }

    private func failPending(with error: Error) {
        let requests = Array(pending.values)
        pending.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }

    deinit {
        receiveTask?.cancel()
        webSocket.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
    }
}
