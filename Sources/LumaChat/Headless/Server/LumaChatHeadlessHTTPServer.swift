import Foundation
import LumaChatSDK
import Network

enum LumaChatHeadlessServerError: LocalizedError, Sendable {
    case alreadyRunning
    case stoppedBeforeReady
    case invalidListenerPort
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The LumaChat App Server is already running."
        case .stoppedBeforeReady: "The LumaChat App Server stopped before becoming ready."
        case .invalidListenerPort: "The LumaChat App Server did not publish a valid port."
        case .listenerFailed(let detail): "The LumaChat App Server listener failed: \(detail)"
        }
    }
}

/// Minimal HTTP/1.1 listener for the local headless API. The semantic routing
/// layer remains independently testable, while this class owns framing,
/// connection bounds, and SSE backpressure.
final class LumaChatHeadlessHTTPServer: @unchecked Sendable {
    private let configuration: LumaChatHeadlessServerConfiguration
    private let router: LumaChatHeadlessRequestRouter
    private let queue = DispatchQueue(label: "com.lumachat.headless.http", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LumaChatHeadlessHTTPConnection] = [:]

    init(
        runtime: any LumaChatHeadlessRuntimeFacade,
        configuration: LumaChatHeadlessServerConfiguration
    ) {
        self.configuration = configuration
        router = LumaChatHeadlessRequestRouter(runtime: runtime, configuration: configuration)
    }

    /// Starts the listener and returns its effective port. Port zero requests a
    /// kernel-selected ephemeral port, which is useful for tests and launchers.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let host = configuration.bindHost == "localhost" ? "127.0.0.1" : configuration.bindHost
        let requestedPort = configuration.port == 0
            ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: configuration.port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: requestedPort
        )
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw LumaChatHeadlessServerError.listenerFailed(error.localizedDescription)
        }

        guard installListenerIfStopped(newListener) else {
            newListener.cancel()
            throw LumaChatHeadlessServerError.alreadyRunning
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ListenerStartGate(continuation: continuation)
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                    switch state {
                    case .ready:
                        guard let port = newListener?.port?.rawValue else {
                            gate.complete(.failure(LumaChatHeadlessServerError.invalidListenerPort))
                            return
                        }
                        gate.complete(.success(port))
                    case .failed(let error):
                        self?.clearListenerIfCurrent(newListener)
                        gate.complete(.failure(
                            LumaChatHeadlessServerError.listenerFailed(error.localizedDescription)
                        ))
                    case .cancelled:
                        self?.clearListenerIfCurrent(newListener)
                        gate.complete(.failure(LumaChatHeadlessServerError.stoppedBeforeReady))
                    default:
                        break
                    }
                }
                newListener.start(queue: queue)
            }
        } onCancel: { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        lock.lock()
        let oldListener = listener
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        oldListener?.cancel()
        activeConnections.forEach { $0.cancel() }
    }

    private func installListenerIfStopped(_ candidate: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return false }
        listener = candidate
        return true
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let handler = LumaChatHeadlessHTTPConnection(
            connection: connection,
            router: router,
            configuration: configuration,
            queue: queue
        ) { [weak self] in
            self?.removeConnection(identifier)
        }
        lock.lock()
        let isRunning = listener != nil
        if isRunning { connections[identifier] = handler }
        lock.unlock()
        if isRunning {
            handler.start()
        } else {
            connection.cancel()
        }
    }

    private func removeConnection(_ identifier: ObjectIdentifier) {
        lock.lock()
        connections.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func clearListenerIfCurrent(_ candidate: NWListener?) {
        guard let candidate else { return }
        lock.lock()
        if let current = listener, current === candidate { listener = nil }
        lock.unlock()
    }
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<UInt16, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}

private struct HeadlessHTTPParsingFailure: Error {
    let status: Int
    let code: LumaChatAPIErrorCode
    let message: String
}

private final class LumaChatHeadlessHTTPConnection: @unchecked Sendable {
    private static let headerDelimiter = Data([13, 10, 13, 10])
    private static let maximumReadChunk = 16_384

    private let connection: NWConnection
    private let router: LumaChatHeadlessRequestRouter
    private let configuration: LumaChatHeadlessServerConfiguration
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void
    private let closeLock = NSLock()
    private var input = Data()
    private var expectedRequestBytes: Int?
    private var didDispatch = false
    private var didClose = false
    private var eventTask: Task<Void, Never>?
    private var requestIdleTimer: DispatchSourceTimer?

    init(
        connection: NWConnection,
        router: LumaChatHeadlessRequestRouter,
        configuration: LumaChatHeadlessServerConfiguration,
        queue: DispatchQueue,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.router = router
        self.configuration = configuration
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        armRequestIdleTimer()
        receiveRequestBytes()
    }

    func cancel() {
        queue.async { [weak self] in self?.close() }
    }

    private func receiveRequestBytes() {
        guard canReceiveRequest else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumReadChunk
        ) { [weak self] data, _, isComplete, error in
            guard let self, self.canReceiveRequest else { return }
            if error != nil {
                self.sendParsingError(.init(
                    status: 400,
                    code: .invalidRequest,
                    message: "HTTP request could not be read."
                ))
                return
            }
            if let data, !data.isEmpty {
                self.input.append(data)
                self.armRequestIdleTimer()
            }
            do {
                if try self.requestIsComplete() {
                    try self.dispatchRequest()
                    return
                }
            } catch let failure as HeadlessHTTPParsingFailure {
                self.sendParsingError(failure)
                return
            } catch {
                self.sendParsingError(.init(
                    status: 400,
                    code: .invalidRequest,
                    message: "Malformed HTTP request."
                ))
                return
            }
            if isComplete {
                self.sendParsingError(.init(
                    status: 400,
                    code: .invalidRequest,
                    message: "Incomplete HTTP request."
                ))
            } else {
                self.receiveRequestBytes()
            }
        }
    }

    private func requestIsComplete() throws -> Bool {
        if let expectedRequestBytes {
            guard input.count <= expectedRequestBytes else {
                throw HeadlessHTTPParsingFailure(
                    status: 400,
                    code: .invalidRequest,
                    message: "HTTP pipelining and trailing request bytes are not supported."
                )
            }
            return input.count == expectedRequestBytes
        }

        guard let delimiterRange = input.range(of: Self.headerDelimiter) else {
            guard input.count <= configuration.maximumHeaderBytes else {
                throw HeadlessHTTPParsingFailure(
                    status: 431,
                    code: .payloadTooLarge,
                    message: "HTTP headers are too large."
                )
            }
            return false
        }
        let bodyOffset = delimiterRange.upperBound
        guard bodyOffset <= configuration.maximumHeaderBytes else {
            throw HeadlessHTTPParsingFailure(
                status: 431,
                code: .payloadTooLarge,
                message: "HTTP headers are too large."
            )
        }
        let headerData = input[..<delimiterRange.lowerBound]
        let contentLength = try Self.contentLength(in: Data(headerData))
        guard contentLength <= configuration.maximumJSONBytes else {
            throw HeadlessHTTPParsingFailure(
                status: 413,
                code: .payloadTooLarge,
                message: "JSON body is too large."
            )
        }
        let (expected, overflow) = bodyOffset.addingReportingOverflow(contentLength)
        guard !overflow else {
            throw HeadlessHTTPParsingFailure(
                status: 413,
                code: .payloadTooLarge,
                message: "HTTP request size is invalid."
            )
        }
        expectedRequestBytes = expected
        guard input.count <= expected else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "HTTP pipelining and trailing request bytes are not supported."
            )
        }
        return input.count == expected
    }

    private func dispatchRequest() throws {
        guard canReceiveRequest else { return }
        let request = try Self.parseRequest(input)
        guard beginDispatch() else { return }
        input.removeAll(keepingCapacity: false)
        let task = Task { [weak self, router] in
            guard let self else { return }
            let result = await router.handle(request)
            await self.write(result)
        }
        closeLock.lock()
        let wasClosed = didClose
        if !wasClosed { eventTask = task }
        closeLock.unlock()
        if wasClosed {
            task.cancel()
            return
        }
        monitorPeerClosure()
    }

    private func monitorPeerClosure() {
        guard !isClosed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            if error != nil || complete || data?.isEmpty == false {
                self.close()
            } else {
                self.monitorPeerClosure()
            }
        }
    }

    private func write(_ result: LumaChatHeadlessRouteResult) async {
        let writer = HeadlessConnectionWriter(
            connection: connection,
            timeoutSeconds: configuration.connectionWriteTimeoutSeconds
        )
        do {
            switch result {
            case .response(let response):
                let data = Self.serialized(response: response, close: true)
                try await writer.send(data, isComplete: true)
            case .events(let headers, let stream):
                try await writer.send(Self.serializedEventHeaders(headers), isComplete: false)
                let heartbeatInterval = configuration.sseHeartbeatIntervalSeconds
                let heartbeatTask = Task {
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(heartbeatInterval))
                            try Task.checkCancellation()
                            try await writer.send(
                                Data(": keep-alive\n\n".utf8),
                                isComplete: false
                            )
                        }
                    } catch {
                        // The owning event task closes the connection after
                        // cancellation or the first failed serialized write.
                    }
                }
                do {
                    for try await event in stream {
                        try Task.checkCancellation()
                        let json = try Self.encoder().encode(event)
                        guard json.count <= configuration.maximumEventBytes else {
                            throw HeadlessHTTPParsingFailure(
                                status: 500,
                                code: .internalError,
                                message: "Runtime event exceeded its safety limit."
                            )
                        }
                        var packet = Data(
                            "id: \(event.sequence)\nevent: \(event.kind.rawValue)\ndata: ".utf8
                        )
                        packet.append(json)
                        packet.append(Data("\n\n".utf8))
                        try await writer.send(packet, isComplete: false)
                    }
                    heartbeatTask.cancel()
                    await heartbeatTask.value
                    try await writer.send(Data(), isComplete: true)
                } catch {
                    heartbeatTask.cancel()
                    await heartbeatTask.value
                    throw error
                }
            }
        } catch {
            // Once HTTP/SSE bytes have begun, a second response would corrupt
            // framing. Closing is the only fail-closed behavior.
        }
        close()
    }

    private func sendParsingError(_ failure: HeadlessHTTPParsingFailure) {
        guard beginDispatch() else {
            close()
            return
        }
        let requestID = UUID().uuidString.lowercased()
        let envelope = LumaChatAPIErrorEnvelope(error: .init(
            code: failure.code,
            message: failure.message,
            requestID: requestID
        ))
        let body = (try? Self.encoder().encode(envelope)) ?? Data()
        let response = LumaChatHeadlessHTTPResponse(
            status: failure.status,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "X-LumaChat-API-Version": LumaChatAPIVersion.v1,
                "X-Request-ID": requestID
            ],
            body: body
        )
        connection.send(
            content: Self.serialized(response: response, close: true),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in self?.close() }
        )
    }

    private func close() {
        closeLock.lock()
        guard !didClose else {
            closeLock.unlock()
            return
        }
        didClose = true
        let task = eventTask
        eventTask = nil
        let timer = requestIdleTimer
        requestIdleTimer = nil
        closeLock.unlock()
        task?.cancel()
        timer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose()
    }

    private func armRequestIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.requestIdleTimeoutSeconds)
        timer.setEventHandler { [weak self] in self?.close() }
        timer.activate()

        closeLock.lock()
        guard !didClose, !didDispatch else {
            closeLock.unlock()
            timer.cancel()
            return
        }
        let previous = requestIdleTimer
        requestIdleTimer = timer
        closeLock.unlock()
        previous?.cancel()
    }

    private func beginDispatch() -> Bool {
        closeLock.lock()
        guard !didClose, !didDispatch else {
            closeLock.unlock()
            return false
        }
        didDispatch = true
        let timer = requestIdleTimer
        requestIdleTimer = nil
        closeLock.unlock()
        timer?.cancel()
        return true
    }

    private var canReceiveRequest: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return !didClose && !didDispatch
    }

    private var isClosed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return didClose
    }

    private static func contentLength(in headerData: Data) throws -> Int {
        let parsed = try parseHeaderBlock(headerData)
        guard parsed.headers["transfer-encoding"] == nil else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "Transfer-Encoding is not supported."
            )
        }
        guard let raw = parsed.headers["content-length"] else { return 0 }
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(raw), value >= 0 else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "Content-Length is invalid."
            )
        }
        return value
    }

    private static func parseRequest(_ data: Data) throws -> LumaChatHeadlessHTTPRequest {
        guard let delimiter = data.range(of: headerDelimiter) else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "HTTP headers are incomplete."
            )
        }
        let parsed = try parseHeaderBlock(Data(data[..<delimiter.lowerBound]))
        let body = Data(data[delimiter.upperBound...])
        return LumaChatHeadlessHTTPRequest(
            method: parsed.method,
            target: parsed.target,
            headers: parsed.headers,
            body: body
        )
    }

    private static func parseHeaderBlock(
        _ data: Data
    ) throws -> (method: String, target: String, headers: [String: String]) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "HTTP headers must be UTF-8."
            )
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "HTTP request line is missing."
            )
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0",
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty else {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "HTTP request line is invalid."
            )
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t",
                  let delimiter = line.firstIndex(of: ":") else {
                throw HeadlessHTTPParsingFailure(
                    status: 400,
                    code: .invalidRequest,
                    message: "HTTP header is invalid."
                )
            }
            let name = String(line[..<delimiter]).lowercased()
            let value = line[line.index(after: delimiter)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy(isHTTPTokenByte),
                  headers[name] == nil,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw HeadlessHTTPParsingFailure(
                    status: 400,
                    code: .invalidRequest,
                    message: "Duplicate or unsafe HTTP header."
                )
            }
            headers[name] = value
        }
        if requestParts[2] == "HTTP/1.1", headers["host"] == nil {
            throw HeadlessHTTPParsingFailure(
                status: 400,
                code: .invalidRequest,
                message: "Host header is required."
            )
        }
        return (String(requestParts[0]), String(requestParts[1]), headers)
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            true
        default:
            false
        }
    }

    private static func serialized(
        response: LumaChatHeadlessHTTPResponse,
        close: Bool
    ) -> Data {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = close ? "close" : "keep-alive"
        var data = serializedHeader(status: response.status, headers: headers)
        data.append(response.body)
        return data
    }

    private static func serializedEventHeaders(_ headers: [String: String]) -> Data {
        var output = headers
        output["Connection"] = "close"
        return serializedHeader(status: 200, headers: output)
    }

    private static func serializedHeader(status: Int, headers: [String: String]) -> Data {
        var value = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, headerValue) in headers.sorted(by: { $0.key < $1.key }) {
            value += "\(name): \(headerValue)\r\n"
        }
        value += "\r\n"
        return Data(value.utf8)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// Serializes event and keep-alive frames so a heartbeat can never interleave
/// with a JSON event while Network.framework is applying socket backpressure.
private actor HeadlessConnectionWriter {
    private enum WriteError: Error {
        case timedOut
        case endedWithoutResult
    }

    private let connection: NWConnection
    private let timeoutSeconds: TimeInterval

    init(connection: NWConnection, timeoutSeconds: TimeInterval) {
        self.connection = connection
        self.timeoutSeconds = timeoutSeconds
    }

    func send(_ data: Data, isComplete: Bool) async throws {
        let connection = connection
        let timeoutSeconds = timeoutSeconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Void, Error>) in
                        connection.send(
                            content: data,
                            contentContext: .defaultMessage,
                            isComplete: isComplete,
                            completion: .contentProcessed { error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume()
                                }
                            }
                        )
                    }
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw WriteError.timedOut
            }
            do {
                guard let _ = try await group.next() else {
                    throw WriteError.endedWithoutResult
                }
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
