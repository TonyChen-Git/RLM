import Foundation
import XCTest
@testable import LumaChat

private final class MCPHTTPStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Result = (status: Int, headers: [String: String], body: Data)
    struct StreamResult: @unchecked Sendable {
        var status: Int
        var headers: [String: String]
        var responseURL: URL? = nil
        /// Delays are relative to the response headers, not cumulative.
        /// The array defines byte order even when delayed work becomes runnable together.
        var chunks: [(delay: TimeInterval, body: Data)]
        /// `nil` deliberately leaves the response stream open.
        var finishDelay: TimeInterval?
    }

    nonisolated(unsafe) static var handler: ((URLRequest, JSONValue?) -> Result)?
    nonisolated(unsafe) static var streamHandler: ((URLRequest, JSONValue?) -> StreamResult)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var methodRequests: [(String, URLRequest)] = []
    nonisolated(unsafe) static var stoppedRequests: [URLRequest] = []
    private let deliveryQueue = DispatchQueue(label: "LumaChatTests.MCPHTTPStub.delivery")
    private let lifecycleLock = NSRecursiveLock()
    private var scheduledWork: DispatchWorkItem?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let body = Self.bodyData(from: request)
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        if let method = json?["method"]?.stringValue {
            Self.methodRequests.append((method, request))
        }
        if let result = Self.streamHandler?(request, json) {
            let response = HTTPURLResponse(
                url: result.responseURL ?? request.url!,
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: result.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            deliver(result, chunkIndex: 0, started: .now())
            return
        }
        let result = Self.handler?(request, json) ?? (
            status: 500,
            headers: [:],
            body: Data()
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !result.body.isEmpty { client?.urlProtocol(self, didLoad: result.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        lifecycleLock.withLock {
            stopped = true
            scheduledWork?.cancel()
            scheduledWork = nil
        }
        Self.stoppedRequests.append(request)
    }

    private func deliver(_ result: StreamResult, chunkIndex: Int, started: DispatchTime) {
        if chunkIndex < result.chunks.count {
            let chunk = result.chunks[chunkIndex]
            schedule(at: started + max(0, chunk.delay)) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: chunk.body)
                // Queue the next chunk only after this callback completed. Independent
                // global asyncAfter jobs can reorder or race stream termination when
                // the hosted runner is busy, unlike an ordered HTTP byte stream.
                self.deliver(result, chunkIndex: chunkIndex + 1, started: started)
            }
        } else if let finishDelay = result.finishDelay {
            schedule(at: started + max(0, finishDelay)) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func schedule(at deadline: DispatchTime, action: @escaping @Sendable () -> Void) {
        lifecycleLock.withLock {
            guard !stopped else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lifecycleLock.withLock {
                    guard !self.stopped else { return }
                    self.scheduledWork = nil
                    action()
                }
            }
            scheduledWork = work
            deliveryQueue.asyncAfter(deadline: deadline, execute: work)
        }
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

final class MCPStreamableHTTPTests: XCTestCase {
    override func tearDown() {
        MCPHTTPStubURLProtocol.handler = nil
        MCPHTTPStubURLProtocol.streamHandler = nil
        MCPHTTPStubURLProtocol.requests = []
        MCPHTTPStubURLProtocol.methodRequests = []
        MCPHTTPStubURLProtocol.stoppedRequests = []
        super.tearDown()
    }

    func testSubsequentRequestsCarryNegotiatedSessionAndProtocolHeaders() async throws {
        MCPHTTPStubURLProtocol.handler = { _, json in
            let id = json?["id"] ?? .null
            let rpcID = try? id.rpcID
            let method = json?["method"]?.stringValue
            let result: JSONValue = method == "initialize"
                ? .object([
                    "protocolVersion": .string(MCPClient.protocolVersion),
                    "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("HTTP"), "version": .string("1")]),
                ])
                : .object(["tools": .array([])])
            return (
                200,
                method == "initialize"
                    ? ["Content-Type": "application/json", "Mcp-Session-Id": "session-123"]
                    : ["Content-Type": "application/json"],
                try! JSONEncoder().encode(
                    MCPJSONRPCResponse(jsonrpc: "2.0", id: rpcID, result: result, error: nil)
                )
            )
        }
        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()
        _ = try await transport.send(.init(id: .integer(1), method: "initialize"))
        _ = try await transport.send(.init(id: .integer(2), method: "tools/list"))
        await transport.stop()

        let requests = MCPHTTPStubURLProtocol.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "MCP-Protocol-Version"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Mcp-Session-Id"), "session-123")
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "MCP-Protocol-Version"),
            MCPClient.protocolVersion
        )
    }

    func testExpiredSessionIsReinitializedAndOriginalRequestIsRetriedOnce() async throws {
        var initializeCount = 0
        MCPHTTPStubURLProtocol.handler = { request, json in
            let method = json?["method"]?.stringValue ?? ""
            let id: MCPJSONRPCID?
            if let value = json?["id"] { id = try? value.rpcID }
            else { id = nil }
            if method == "initialize" {
                initializeCount += 1
                let sessionID = initializeCount == 1 ? "expired-session" : "fresh-session"
                let body = try! JSONEncoder().encode(MCPJSONRPCResponse(
                    jsonrpc: "2.0",
                    id: id,
                    result: .object([
                        "protocolVersion": .string(MCPClient.protocolVersion),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object(["name": .string("HTTP"), "version": .string("1")]),
                    ]),
                    error: nil
                ))
                return (200, ["Content-Type": "application/json", "Mcp-Session-Id": sessionID], body)
            }
            if method == "notifications/initialized" { return (202, [:], Data()) }
            if method == "tools/list",
               request.value(forHTTPHeaderField: "Mcp-Session-Id") == "expired-session" {
                return (404, ["Content-Type": "application/json"], Data(#"{"error":"expired"}"#.utf8))
            }
            let body = try! JSONEncoder().encode(MCPJSONRPCResponse(
                jsonrpc: "2.0",
                id: id,
                result: .object(["tools": .array([])]),
                error: nil
            ))
            return (200, ["Content-Type": "application/json"], body)
        }

        let configuration = MCPServerConfiguration(
            name: "HTTP",
            transport: .streamableHTTP(.init(endpoint: URL(string: "https://mcp.example.test/rpc")!))
        )
        let client = MCPClient(
            configuration: configuration,
            transport: MCPStreamableHTTPTransport(
                configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
                session: stubSession()
            )
        )
        _ = try await client.connect()
        let tools = try await client.listTools()
        XCTAssertTrue(tools.isEmpty)
        XCTAssertEqual(initializeCount, 2)
        let toolRequests = MCPHTTPStubURLProtocol.methodRequests
            .filter { $0.0 == "tools/list" }
            .map(\.1)
        XCTAssertEqual(toolRequests.count, 2)
        XCTAssertEqual(toolRequests.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "fresh-session")
        await client.disconnect()
    }

    func testAcceptedRequestUsesBoundedGETStreamAndReturnsBeforeItCloses() async throws {
        MCPHTTPStubURLProtocol.streamHandler = { request, json in
            let method = json?["method"]?.stringValue
            if method == "initialize" {
                let response = MCPJSONRPCResponse(
                    jsonrpc: "2.0",
                    id: .integer(1),
                    result: .object([
                        "protocolVersion": .string(MCPClient.protocolVersion),
                        "capabilities": .object([:]),
                        "serverInfo": .object(["name": .string("HTTP"), "version": .string("1")]),
                    ]),
                    error: nil
                )
                return .init(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Mcp-Session-Id": "async-session",
                    ],
                    chunks: [(0, try! MCPWireCodec.encode(response))],
                    finishDelay: 0
                )
            }
            if request.httpMethod == "POST" {
                return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
            }
            if request.httpMethod == "GET" {
                let prefix = Data(#"""
                : heartbeat
                
                data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}
                
                data: {"jsonrpc":"2.0","id":99,"result":{"wrong":true}}
                
                data: {"jsonrpc":"2.0","id":
                """#.utf8)
                let matching = Data("2,\"result\":{\"async\":true}}\r\n\r\n".utf8)
                return .init(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                    // The suffix deadline is already due when the prefix arrives.
                    // A busy scheduler must still preserve the array's byte order.
                    chunks: [(0.05, prefix), (0.01, matching)],
                    // A buffering implementation cannot complete: the server keeps
                    // this response open until the test cancels/stops the transport.
                    finishDelay: nil
                )
            }
            return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
        }

        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()
        _ = try await transport.send(.init(id: .integer(1), method: "initialize"))

        let response = try await sendBeforeStreamCloses(
            .init(id: .integer(2), method: "tools/list"),
            using: transport
        )

        XCTAssertEqual(response?.id, .integer(2))
        XCTAssertEqual(response?.result?["async"]?.boolValue, true)

        let get = try XCTUnwrap(MCPHTTPStubURLProtocol.requests.first { $0.httpMethod == "GET" })
        XCTAssertEqual(get.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(get.value(forHTTPHeaderField: "Mcp-Session-Id"), "async-session")
        XCTAssertEqual(get.value(forHTTPHeaderField: "MCP-Protocol-Version"), MCPClient.protocolVersion)
        await transport.stop()
    }

    func testPOSTSSEAlsoReturnsAtMatchingEventBeforeStreamCloses() async throws {
        MCPHTTPStubURLProtocol.streamHandler = { _, _ in
            .init(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [
                    (0.01, Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n".utf8)),
                    (0.05, Data("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ready\":true}}\n\n".utf8)),
                ],
                finishDelay: nil
            )
        }
        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()

        let response = try await sendBeforeStreamCloses(
            .init(id: .integer(1), method: "initialize"),
            using: transport
        )
        XCTAssertEqual(response?.result?["ready"]?.boolValue, true)
        await transport.stop()
    }

    func testSameOriginRedirectIsRejectedEvenWithAnInjectedSession() async throws {
        let response = MCPJSONRPCResponse(
            jsonrpc: "2.0",
            id: .integer(1),
            result: .object(["ready": .bool(true)]),
            error: nil
        )
        MCPHTTPStubURLProtocol.streamHandler = { _, _ in
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                responseURL: URL(string: "https://mcp.example.test/redirected")!,
                chunks: [(0, try! MCPWireCodec.encode(response))],
                finishDelay: 0
            )
        }
        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()
        do {
            _ = try await transport.send(.init(id: .integer(1), method: "initialize"))
            XCTFail("A redirected MCP response must be rejected.")
        } catch let error as MCPError {
            guard case .invalidResponse(let detail) = error else {
                return XCTFail("Expected a redirect validation error, got \(error).")
            }
            XCTAssertTrue(detail.contains("redirect"))
        }
        await transport.stop()
    }

    func testStopCancelsAnOpenAsynchronousReceiveStream() async throws {
        MCPHTTPStubURLProtocol.streamHandler = { request, json in
            if json?["method"]?.stringValue == "initialize" {
                let response = MCPJSONRPCResponse(
                    jsonrpc: "2.0",
                    id: .integer(1),
                    result: .object(["ready": .bool(true)]),
                    error: nil
                )
                return .init(
                    status: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "cancel-session",
                    ],
                    chunks: [(0, try! MCPWireCodec.encode(response))],
                    finishDelay: 0
                )
            }
            if request.httpMethod == "POST" {
                return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
            }
            if request.httpMethod == "GET" {
                return .init(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    chunks: [(0.01, Data(": heartbeat\n\n".utf8))],
                    finishDelay: nil
                )
            }
            return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
        }

        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()
        _ = try await transport.send(.init(id: .integer(1), method: "initialize"))
        let sendTask = Task {
            try await transport.send(.init(id: .integer(2), method: "tools/list"))
        }
        try await waitUntil(timeout: 1) {
            MCPHTTPStubURLProtocol.requests.contains { $0.httpMethod == "GET" }
        }

        await transport.stop()
        do {
            _ = try await sendTask.value
            XCTFail("Stopping the transport must cancel its open receive stream.")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(MCPHTTPStubURLProtocol.stoppedRequests.contains { $0.httpMethod == "GET" })
    }

    func testGET404ClearsNegotiatedSession() async throws {
        MCPHTTPStubURLProtocol.streamHandler = { request, json in
            if json?["method"]?.stringValue == "initialize" {
                let response = MCPJSONRPCResponse(
                    jsonrpc: "2.0",
                    id: .integer(1),
                    result: .object(["ready": .bool(true)]),
                    error: nil
                )
                return .init(
                    status: 200,
                    headers: ["Content-Type": "application/json", "Mcp-Session-Id": "expired"],
                    chunks: [(0, try! MCPWireCodec.encode(response))],
                    finishDelay: 0
                )
            }
            if request.httpMethod == "POST" {
                return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
            }
            if request.httpMethod == "GET" {
                return .init(
                    status: 404,
                    headers: ["Content-Type": "application/json"],
                    chunks: [(0, Data(#"{"error":"expired"}"#.utf8))],
                    finishDelay: 0
                )
            }
            return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
        }

        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        try await transport.start()
        _ = try await transport.send(.init(id: .integer(1), method: "initialize"))
        do {
            _ = try await transport.send(.init(id: .integer(2), method: "tools/list"))
            XCTFail("Expected the GET receive stream to report session expiry.")
        } catch let error as MCPError {
            XCTAssertEqual(error, .sessionExpired)
        }
        await transport.stop()

        XCTAssertFalse(MCPHTTPStubURLProtocol.requests.contains { request in
            request.httpMethod == "DELETE"
                && request.value(forHTTPHeaderField: "Mcp-Session-Id") == "expired"
        })
    }

    func testClientTimeoutCancelsOpenGETReceiveStream() async throws {
        MCPHTTPStubURLProtocol.streamHandler = { request, json in
            let method = json?["method"]?.stringValue
            if method == "initialize" {
                let response = MCPJSONRPCResponse(
                    jsonrpc: "2.0",
                    id: .integer(1),
                    result: .object([
                        "protocolVersion": .string(MCPClient.protocolVersion),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object(["name": .string("HTTP"), "version": .string("1")]),
                    ]),
                    error: nil
                )
                return .init(
                    status: 200,
                    headers: ["Content-Type": "application/json", "Mcp-Session-Id": "timeout"],
                    chunks: [(0, try! MCPWireCodec.encode(response))],
                    finishDelay: 0
                )
            }
            if request.httpMethod == "POST" {
                return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
            }
            if request.httpMethod == "GET" {
                return .init(
                    status: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    chunks: [(0.01, Data(": heartbeat\n\n".utf8))],
                    finishDelay: nil
                )
            }
            return .init(status: 202, headers: [:], chunks: [], finishDelay: 0)
        }

        let server = MCPServerConfiguration(
            name: "Timeout",
            transport: .streamableHTTP(.init(endpoint: URL(string: "https://mcp.example.test/rpc")!))
        )
        let transport = MCPStreamableHTTPTransport(
            configuration: .init(endpoint: URL(string: "https://mcp.example.test/rpc")!),
            session: stubSession()
        )
        let client = MCPClient(configuration: server, transport: transport, requestTimeout: 1)
        _ = try await client.connect()

        let started = Date()
        do {
            _ = try await client.listTools()
            XCTFail("Expected the MCP client request timeout.")
        } catch let error as MCPError {
            guard case .transport(let detail) = error else {
                return XCTFail("Expected a transport timeout, got \(error).")
            }
            XCTAssertTrue(detail.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        try await waitUntil(timeout: 1) {
            MCPHTTPStubURLProtocol.stoppedRequests.contains { $0.httpMethod == "GET" }
        }
        await client.disconnect()
    }

    private func sendBeforeStreamCloses(
        _ request: MCPJSONRPCRequest,
        using transport: MCPStreamableHTTPTransport
    ) async throws -> MCPJSONRPCResponse? {
        let completed = expectation(description: "Matching SSE response arrives while the stream remains open")
        let sendTask = Task {
            defer { completed.fulfill() }
            return try await transport.send(request)
        }
        // The fixture never closes the stream. The timeout only bounds a broken
        // implementation; successful streaming is established by the response,
        // independent of runner scheduling latency. Always cancel and await the
        // operation so a failing test cannot leave a receive stream behind.
        await fulfillment(of: [completed], timeout: 5)
        sendTask.cancel()
        do {
            return try await sendTask.value
        } catch {
            await transport.stop()
            throw error
        }
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPHTTPStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the HTTP transport state.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private extension JSONValue {
    var rpcID: MCPJSONRPCID {
        get throws {
            switch self {
            case .number(let value):
                guard value.isFinite,
                      value.rounded() == value,
                      value >= -9_223_372_036_854_775_808.0,
                      value < 9_223_372_036_854_775_808.0 else {
                    throw MCPError.invalidResponse("invalid id")
                }
                return .integer(Int64(value))
            case .string(let value): return .string(value)
            case .null: return .null
            default: throw MCPError.invalidResponse("invalid id")
            }
        }
    }
}
