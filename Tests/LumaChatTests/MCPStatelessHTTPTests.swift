import Foundation
import XCTest
@testable import LumaChat

private final class MCPStatelessHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data()
        var keepOpen = false
        var failure: URLError?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((URLRequest, JSONValue?) -> Reply)?
        private var recorded: [(URLRequest, JSONValue?)] = []

        func configure(_ handler: @escaping (URLRequest, JSONValue?) -> Reply) {
            lock.withLock { self.handler = handler; recorded = [] }
        }

        func receive(_ request: URLRequest, _ body: JSONValue?) -> Reply {
            let callback = lock.withLock {
                recorded.append((request, body))
                return handler
            }
            return callback?(request, body) ?? Reply(status: 500)
        }

        var requests: [(URLRequest, JSONValue?)] { lock.withLock { recorded } }
        func reset() { lock.withLock { handler = nil; recorded = [] } }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            data = body
        } else {
            data = Data()
        }
        let body = try? MCPWireCodec.decode(JSONValue.self, from: data)
        let reply = Self.state.receive(request, body)
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        if !reply.keepOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class MCPStatelessHTTPTests: XCTestCase {
    private let endpoint = URL(string: "https://stateless.example.test/mcp")!

    override func tearDown() {
        MCPStatelessHTTPStub.state.reset()
        super.tearDown()
    }

    func testModernRequestsOwnRoutingHeadersAndNeverAdoptSessionIdentity() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in
            var reply = Self.completeReply(body)
            reply.headers["Mcp-Session-Id"] = "must-not-be-adopted"
            return reply
        }
        let transport = makeTransport(headers: [
            "Authorization": "Bearer local-test-fixture",
            "mCp-PrOtOcOl-VeRsIoN": "spoofed", "Mcp-Method": "spoofed",
            "Mcp-Name": "spoofed", "Mcp-Session-Id": "spoofed",
            "Mcp-Param-Route": "spoofed", "Mcp-Capabilities": "spoofed",
            "Last-Event-ID": "spoofed"
        ])
        try await transport.start()
        _ = try await transport.send(modernRequest(1, "server/discover"))
        var call = modernRequest(2, "tools/call", ["name": .string("工具"), "arguments": .object([:])])
        call.localHTTPHeaders = ["Mcp-Param-Route": "local-route"]
        _ = try await transport.send(call)
        _ = try await transport.send(modernRequest(3, "resources/read", ["uri": .string("file:///a b")]))
        _ = try await transport.send(modernRequest(4, "prompts/get", ["name": .string("a prompt")]))
        await transport.stop()

        let requests = MCPStatelessHTTPStub.state.requests
        XCTAssertEqual(requests.count, 4)
        for (request, body) in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), MCPClient.statelessProtocolVersion)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Method"), body?["method"]?.stringValue)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Last-Event-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Capabilities"))
            XCTAssertNil(body?["localHTTPHeaders"])
            XCTAssertEqual(body?["params"]?["_meta"]?["io.modelcontextprotocol/clientCapabilities"], .object([:]))
        }
        XCTAssertNil(requests[0].0.value(forHTTPHeaderField: "Mcp-Name"))
        XCTAssertNil(requests[0].0.value(forHTTPHeaderField: "Mcp-Param-Route"))
        XCTAssertEqual(requests[1].0.value(forHTTPHeaderField: "Mcp-Name"), try MCPHTTPHeaderProjection.encodedValue("工具"))
        XCTAssertEqual(requests[1].0.value(forHTTPHeaderField: "Mcp-Param-Route"), "local-route")
        XCTAssertEqual(requests[2].0.value(forHTTPHeaderField: "Mcp-Name"), "file:///a b")
        XCTAssertEqual(requests[3].0.value(forHTTPHeaderField: "Mcp-Name"), "a prompt")
    }

    func testAutomaticHTTPFallbackIsLimitedToReadOnlyDiscovery400() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in
            switch body?["method"]?.stringValue {
            case "server/discover":
                return .init(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Initialize first".utf8))
            case "initialize":
                return Self.resultReply(body, result: .object([
                    "protocolVersion": .string(MCPClient.protocolVersion),
                    "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("Legacy"), "version": .string("1")])
                ]))
            case "notifications/initialized": return .init(status: 202)
            default: return .init(status: 500)
            }
        }
        let client = makeClient(mode: .automatic)
        let result = try await client.connect()
        XCTAssertEqual(result.protocolVersion, MCPClient.protocolVersion)
        await client.disconnect()
        let requests = MCPStatelessHTTPStub.state.requests
        XCTAssertEqual(requests.compactMap { $0.1?["method"]?.stringValue }, ["server/discover", "initialize", "notifications/initialized"])
        XCTAssertEqual(requests[0].0.value(forHTTPHeaderField: "MCP-Protocol-Version"), MCPClient.statelessProtocolVersion)
        XCTAssertNil(requests[1].0.value(forHTTPHeaderField: "MCP-Protocol-Version"))
        XCTAssertNil(requests[1].0.value(forHTTPHeaderField: "Mcp-Method"))
    }

    func testModernHTTPErrorsPreserveStructuredNegotiationData() async throws {
        for code in [-32020, -32021, -32022] {
            MCPStatelessHTTPStub.state.configure { _, body in
                Self.errorReply(body, code: code, data: .object([
                    "supported": .array([.string(MCPClient.protocolVersion)]),
                    "requested": .string(MCPClient.statelessProtocolVersion)
                ]))
            }
            let transport = makeTransport()
            try await transport.start()
            let response = try await transport.send(modernRequest(1, "server/discover"))
            XCTAssertEqual(response?.error?.code, code)
            XCTAssertEqual(response?.error?.data?["requested"], .string(MCPClient.statelessProtocolVersion))
            await transport.stop()
            XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        }
    }

    func testModernHTTP400ErrorsWithoutIDUseTheirOriginatingPOST() async throws {
        for code in [-32020, -32021, -32022] {
            MCPStatelessHTTPStub.state.configure { _, body in
                var reply = Self.errorReply(body, code: code, data: .object([
                    "supported": .array([.string(MCPClient.protocolVersion)]),
                    "requested": .string(MCPClient.statelessProtocolVersion)
                ]))
                var object = try! MCPWireCodec.decode(JSONValue.self, from: reply.body).objectValue!
                object.removeValue(forKey: "id")
                reply.body = try! MCPWireCodec.encode(JSONValue.object(object))
                return reply
            }
            let transport = makeTransport()
            try await transport.start()
            let response = try await transport.send(modernRequest(19, "server/discover"))
            XCTAssertEqual(response?.error?.code, code)
            XCTAssertEqual(response?.id, .integer(19))
            await transport.stop()
            XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        }
    }

    func testAutomaticVersionNegotiationAcceptsModernErrorWithoutID() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in
            switch body?["method"]?.stringValue {
            case "server/discover":
                var reply = Self.errorReply(nil, code: -32022, data: .object([
                    "supported": .array([.string(MCPClient.protocolVersion)]),
                    "requested": .string(MCPClient.statelessProtocolVersion)
                ]))
                var object = try! MCPWireCodec.decode(JSONValue.self, from: reply.body).objectValue!
                object.removeValue(forKey: "id")
                reply.body = try! MCPWireCodec.encode(JSONValue.object(object))
                return reply
            case "initialize":
                return Self.resultReply(body, result: .object([
                    "protocolVersion": .string(MCPClient.protocolVersion),
                    "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("Legacy"), "version": .string("1")])
                ]))
            case "notifications/initialized": return .init(status: 202)
            default: return .init(status: 500)
            }
        }
        let client = makeClient(mode: .automatic)
        let result = try await client.connect()
        XCTAssertEqual(result.protocolVersion, MCPClient.protocolVersion)
        await client.disconnect()
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.compactMap { $0.1?["method"]?.stringValue },
                       ["server/discover", "initialize", "notifications/initialized"])
    }

    func testAuthenticationNetworkAndAvailabilityErrorsNeverDowngrade() async throws {
        for status in [401, 403, 429, 500, 503] {
            MCPStatelessHTTPStub.state.configure { _, body in
                var reply = Self.errorReply(body, code: -32022, data: .object([
                    "supported": .array([.string(MCPClient.protocolVersion)])
                ]))
                reply.status = status
                return reply
            }
            let client = makeClient(mode: .automatic)
            do {
                _ = try await client.connect()
                XCTFail("HTTP \(status) must fail without fallback")
            } catch let error as MCPError {
                guard case .transport = error else { return XCTFail("Unexpected error: \(error)") }
            }
            await client.disconnect()
            XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        }
        MCPStatelessHTTPStub.state.configure { _, _ in .init(failure: URLError(.networkConnectionLost)) }
        let client = makeClient(mode: .automatic)
        do {
            _ = try await client.connect()
            XCTFail("Network failure must not trigger fallback")
        } catch let error as MCPError {
            guard case .transport = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await client.disconnect()
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
    }

    func testModernMethodNotFound404DoesNotSelectLegacy() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in
            var reply = Self.errorReply(body, code: -32601)
            reply.status = 404
            return reply
        }
        let client = makeClient(mode: .automatic)
        do {
            _ = try await client.connect()
            XCTFail("404 must not select another protocol")
        } catch let error as MCPError {
            guard case .remote(let code, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(code, -32601)
        }
        await client.disconnect()
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
    }

    func testAcceptedModernCallIsNotPolledDeletedOrReplayed() async throws {
        MCPStatelessHTTPStub.state.configure { _, _ in
            .init(status: 202, headers: ["Mcp-Session-Id": "ignored"])
        }
        let transport = makeTransport()
        try await transport.start()
        do {
            _ = try await transport.send(modernRequest(1, "tools/call", ["name": .string("write"), "arguments": .object([:])]))
            XCTFail("202 cannot complete a stateless call")
        } catch let error as MCPError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await transport.stop()
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.first?.0.httpMethod, "POST")
    }

    func testModernPOSTSSECompletesWithoutWaitingForStreamClose() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in
            let data = Self.completeReply(body).body
            return .init(headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                         body: Data(": heartbeat\n\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\ndata: ".utf8) + data + Data("\n\n".utf8),
                         keepOpen: true)
        }
        let transport = makeTransport()
        try await transport.start()
        let request = modernRequest(1, "tools/list")
        let response = try await withThrowingTaskGroup(of: MCPJSONRPCResponse?.self) { group in
            group.addTask { try await transport.send(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw MCPError.transport("SSE fixture timed out before returning the completed response")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        XCTAssertEqual(response?.id, .integer(1))
        await transport.stop()
        XCTAssertEqual(MCPStatelessHTTPStub.state.requests.map { $0.0.httpMethod }, ["POST"])
    }

    func testModernMalformedResponsesAndUnexpectedContentTypesFailClosed() async throws {
        let bodies = [
            ("text/plain", #"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}}"#),
            ("application/json", #"[{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}}]"#),
            ("application/json", #"{"id":1,"result":{"resultType":"complete"}}"#),
            ("application/json", #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":-1,"message":"bad"}}"#),
            ("application/json", #"{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}"#)
        ]
        for (type, body) in bodies {
            MCPStatelessHTTPStub.state.configure { _, _ in
                .init(headers: ["Content-Type": type], body: Data(body.utf8))
            }
            let transport = makeTransport()
            try await transport.start()
            do {
                _ = try await transport.send(modernRequest(1, "tools/list"))
                XCTFail("Malformed response must fail")
            } catch let error as MCPError {
                guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
            await transport.stop()
            XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        }
    }

    func testRecognizedButMalformedModernErrorNeverDowngrades() async throws {
        let malformed = [
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022}}"#,
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32022,"message":"unsupported","data":{"supported":["2025-06-18"],"requested":"2026-07-28"}}}"#,
            #"{"jsonrpc":"2.0","id":99,"error":{"code":-32022,"message":"unsupported","data":{"supported":["2025-06-18"]}}}"#,
            #"{"jsonrpc":"1.0","id":1,"error":{"code":-32021,"message":"capability"}}"#
        ]
        for body in malformed {
            MCPStatelessHTTPStub.state.configure { _, _ in .init(status: 400, body: Data(body.utf8)) }
            let client = makeClient(mode: .automatic)
            do {
                _ = try await client.connect()
                XCTFail("Malformed recognized modern errors cannot authorize fallback")
            } catch let error as MCPError {
                guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
            await client.disconnect()
            XCTAssertEqual(MCPStatelessHTTPStub.state.requests.count, 1)
        }
    }

    func testInvalidLocalRoutingHeadersNeverReachNetwork() async throws {
        let invalid: [[String: String]] = [
            ["Authorization": "override"], ["Mcp-Param-A": "a\r\nb"],
            ["Mcp-Param-A": "a", "mcp-param-a": "b"],
            ["Mcp-Param-": "missing-name"], ["Mcp-Param-A": String(repeating: "x", count: 12 * 1_024 + 1)]
        ]
        MCPStatelessHTTPStub.state.configure { _, body in Self.completeReply(body) }
        let transport = makeTransport()
        try await transport.start()
        for headers in invalid {
            var request = modernRequest(1, "tools/call", ["name": .string("write"), "arguments": .object([:])])
            request.localHTTPHeaders = headers
            do {
                _ = try await transport.send(request)
                XCTFail("Invalid local headers must not be transmitted")
            } catch let error as MCPError {
                guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        await transport.stop()
        XCTAssertTrue(MCPStatelessHTTPStub.state.requests.isEmpty)
    }

    func testStatelessInitializeAndUnsupportedMetadataNeverReachNetwork() async throws {
        MCPStatelessHTTPStub.state.configure { _, body in Self.completeReply(body) }
        let transport = makeTransport()
        try await transport.start()
        var unsupported = modernRequest(1, "server/discover")
        unsupported.params = .object(["_meta": .object(["io.modelcontextprotocol/protocolVersion": .string("2099-01-01")])])
        for request in [modernRequest(1, "initialize"), modernRequest(1, "notifications/initialized"), unsupported] {
            do {
                _ = try await transport.send(request)
                XCTFail("Unsupported lifecycle metadata must fail before transmission")
            } catch let error as MCPError {
                guard case .invalidConfiguration = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        await transport.stop()
        XCTAssertTrue(MCPStatelessHTTPStub.state.requests.isEmpty)
    }

    func testLegacySessionRotationIsRejectedAndOriginalIdentityIsUsedForCleanup() async throws {
        MCPStatelessHTTPStub.state.configure { request, body in
            if request.httpMethod == "DELETE" { return .init(status: 202) }
            var reply = Self.completeReply(body)
            reply.headers["Mcp-Session-Id"] = body?["method"] == .string("initialize") ? "initial" : "rotated"
            return reply
        }
        let transport = makeTransport()
        try await transport.start()
        _ = try await transport.send(.init(id: .integer(1), method: "initialize"))
        do {
            _ = try await transport.send(.init(id: .integer(2), method: "tools/list"))
            XCTFail("Session authority may not rotate outside initialization")
        } catch let error as MCPError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await transport.stop()
        let cleanup = MCPStatelessHTTPStub.state.requests.last?.0
        XCTAssertEqual(cleanup?.httpMethod, "DELETE")
        XCTAssertEqual(cleanup?.value(forHTTPHeaderField: "Mcp-Session-Id"), "initial")
    }

    private func makeTransport(headers: [String: String] = [:]) -> MCPStreamableHTTPTransport {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MCPStatelessHTTPStub.self]
        return MCPStreamableHTTPTransport(
            configuration: .init(endpoint: endpoint, headers: headers),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private func makeClient(mode: MCPProtocolMode) -> MCPClient {
        MCPClient(configuration: .init(name: "Stateless HTTP", protocolMode: mode,
                                      transport: .streamableHTTP(.init(endpoint: endpoint))),
                  transport: makeTransport(), requestTimeout: 2)
    }

    private func modernRequest(_ id: Int64, _ method: String, _ params: [String: JSONValue] = [:]) -> MCPJSONRPCRequest {
        var params = params
        params["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(MCPClient.statelessProtocolVersion),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
            "io.modelcontextprotocol/clientInfo": .object(["name": .string("LumaChat"), "version": .string("test")])
        ])
        return .init(id: .integer(id), method: method, params: .object(params))
    }

    private static func completeReply(_ request: JSONValue?) -> MCPStatelessHTTPStub.Reply {
        resultReply(request, result: .object(["resultType": .string("complete")]))
    }

    private static func resultReply(_ request: JSONValue?, result: JSONValue) -> MCPStatelessHTTPStub.Reply {
        let response: JSONValue = .object(["jsonrpc": .string("2.0"), "id": request?["id"] ?? .null, "result": result])
        return .init(body: try! MCPWireCodec.encode(response))
    }

    private static func errorReply(_ request: JSONValue?, code: Int, data: JSONValue? = nil) -> MCPStatelessHTTPStub.Reply {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string("Fixture error")]
        if let data { error["data"] = data }
        let response: JSONValue = .object(["jsonrpc": .string("2.0"), "id": request?["id"] ?? .null, "error": .object(error)])
        return .init(status: 400, body: try! MCPWireCodec.encode(response))
    }
}
