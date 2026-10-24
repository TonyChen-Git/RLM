import Foundation
import XCTest
@testable import LumaChat

final class MCPStatelessClientTests: XCTestCase {
    func testStatelessDiscoveryAndOperationsCarryIndependentRequestMetadata() async throws {
        let transport = StatelessContractTransport()
        let client = MCPClient(configuration: configuration(), transport: transport)

        let discovery = try await client.connect()
        XCTAssertEqual(discovery.protocolVersion, MCPClient.statelessProtocolVersion)
        XCTAssertEqual(discovery.serverInfo.name, "Stateless fixture")
        XCTAssertEqual(discovery.serverInfo.version, "1.0")
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let tool = try await client.callTool(name: "echo", arguments: .object(["text": .string("hello")]))
        XCTAssertEqual(tool.content.first?["text"]?.stringValue, "hello")
        let resource = try await client.readResource(uri: "fixture:///README.md")
        XCTAssertEqual(resource.contents.first?["text"]?.stringValue, "fixture contents")
        let prompt = try await client.getPrompt(name: "review", arguments: ["language": "zh-TW"])
        XCTAssertEqual(prompt.messages.count, 1)

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "server/discover", "tools/list", "tools/call", "resources/read", "prompts/get"
        ])
        XCTAssertEqual(Set(requests.compactMap(\.id)).count, requests.count)
        for request in requests {
            let metadata = try XCTUnwrap(request.params?["_meta"], "Missing metadata on \(request.method)")
            XCTAssertEqual(metadata["io.modelcontextprotocol/protocolVersion"]?.stringValue, "2026-07-28")
            XCTAssertEqual(metadata["io.modelcontextprotocol/clientCapabilities"], .object([:]))
            let clientInfo = try XCTUnwrap(metadata["io.modelcontextprotocol/clientInfo"]?.objectValue)
            XCTAssertFalse(clientInfo["name"]?.stringValue?.isEmpty ?? true)
            XCTAssertFalse(clientInfo["version"]?.stringValue?.isEmpty ?? true)
        }
        let call = try XCTUnwrap(requests.first { $0.method == "tools/call" })
        XCTAssertEqual(call.params?["name"]?.stringValue, "echo")
        XCTAssertEqual(call.params?["arguments"], .object(["text": .string("hello")]))
        XCTAssertNil(call.params?["arguments"]?["_meta"], "Protocol metadata must not enter tool arguments")
        XCTAssertEqual(requests.first { $0.method == "resources/read" }?.params?["uri"]?.stringValue,
                       "fixture:///README.md")
        XCTAssertEqual(requests.first { $0.method == "prompts/get" }?.params?["arguments"],
                       .object(["language": .string("zh-TW")]))
        await client.disconnect()
    }

    func testStatelessServerInfoMayBeAbsent() async throws {
        let transport = StatelessContractTransport(includesServerInfo: false)
        let config = configuration()
        let client = MCPClient(configuration: config, transport: transport)
        let discovery = try await client.connect()
        XCTAssertEqual(discovery.serverInfo.name, config.name)
        XCTAssertEqual(discovery.serverInfo.version, "unknown")
        await client.disconnect()
    }

    func testStatelessDiscoveryRejectsUnsupportedVersionsWithoutLegacyFallback() async throws {
        let transport = StatelessContractTransport(supportedVersions: ["2099-01-01"])
        let client = MCPClient(configuration: configuration(), transport: transport)
        do {
            _ = try await client.connect()
            XCTFail("An unknown revision must not silently change protocol semantics")
        } catch {
            XCTAssertTrue(error is MCPError)
        }
        let requests = await transport.requests
        let connected = await client.isConnected
        XCTAssertEqual(requests.map(\.method), ["server/discover"])
        XCTAssertFalse(connected)
    }

    func testAutomaticStdioFallsBackAfterExplicitLegacyMethodError() async throws {
        let transport = StatelessContractTransport(discoverError: MCPJSONRPCError(
            code: -32601, message: "Method not found", data: nil
        ))
        let client = MCPClient(configuration: configuration(mode: .automatic), transport: transport)
        let discovery = try await client.connect()
        XCTAssertEqual(discovery.protocolVersion, MCPClient.protocolVersion)
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "server/discover", "initialize", "notifications/initialized", "tools/list"
        ])
        XCTAssertNil(requests.last?.params?["_meta"], "Legacy calls must keep the legacy envelope")
        await client.disconnect()
    }

    func testAutomaticStdioDoesNotDowngradeRecognizedModernErrors() async throws {
        let errors = [
            MCPJSONRPCError(code: -32020, message: "Header mismatch", data: nil),
            MCPJSONRPCError(code: -32021, message: "Missing capability", data: .object([
                "requiredCapabilities": .object(["elicitation": .object([:])])
            ])),
            MCPJSONRPCError(code: -32022, message: "Unsupported protocol", data: .object([
                "requested": .string(MCPClient.statelessProtocolVersion),
                "supported": .array([.string("2099-01-01")])
            ]))
        ]
        for error in errors {
            let transport = StatelessContractTransport(discoverError: error)
            let client = MCPClient(configuration: configuration(mode: .automatic), transport: transport)
            do {
                _ = try await client.connect()
                XCTFail("Modern error \(error.code) must not downgrade to initialize")
            } catch {
                XCTAssertTrue(error is MCPError)
            }
            let methods = await transport.requests.map(\.method)
            let connected = await client.isConnected
            XCTAssertFalse(methods.contains("initialize"))
            XCTAssertFalse(methods.contains("notifications/initialized"))
            XCTAssertFalse(connected)
            await client.disconnect()
        }
    }

    func testPinnedLegacyUsesOnlyInitializeFlow() async throws {
        let transport = StatelessContractTransport()
        let client = MCPClient(configuration: configuration(mode: .legacy), transport: transport)
        let result = try await client.connect()
        XCTAssertEqual(result.protocolVersion, MCPClient.protocolVersion)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["initialize", "notifications/initialized"])
        XCTAssertNil(requests.first?.params?["_meta"])
        await client.disconnect()
    }

    func testVersionNegotiationRequiresMatchingRequestedVersion() async throws {
        for requested: String? in [nil, "2099-01-01", MCPClient.statelessProtocolVersion] {
            var data: [String: JSONValue] = ["supported": .array([.string(MCPClient.protocolVersion)])]
            if let requested { data["requested"] = .string(requested) }
            let transport = StatelessContractTransport(discoverError: MCPJSONRPCError(
                code: -32022, message: "Unsupported version", data: .object(data)
            ))
            let client = MCPClient(configuration: configuration(mode: .automatic), transport: transport)
            do {
                let result = try await client.connect()
                XCTAssertEqual(requested, MCPClient.statelessProtocolVersion)
                XCTAssertEqual(result.protocolVersion, MCPClient.protocolVersion)
            } catch {
                XCTAssertNotEqual(requested, MCPClient.statelessProtocolVersion)
            }
            let methods = await transport.requests.map(\.method)
            XCTAssertEqual(methods.contains("initialize"), requested == MCPClient.statelessProtocolVersion)
            await client.disconnect()
        }
    }

    func testExcludedToolCannotHideDuplicateSchemaAuthority() async throws {
        let bad = StatelessContractTransport.tool(name: "echo", inputSchema: .object([
            "type": .string("object"), "properties": .object([
                "tenant": .object(["type": .string("number"), "x-mcp-header": .string("Tenant")])
            ])
        ]))
        let transport = StatelessContractTransport(tools: [bad, StatelessContractTransport.tool()])
        var config = configuration()
        config.transport = .streamableHTTP(.init(endpoint: URL(string: "https://mcp.example.test/mcp")!))
        let client = MCPClient(configuration: config, transport: transport)
        _ = try await client.connect()
        do {
            _ = try await client.listTools()
            XCTFail("A filtered descriptor must not allow duplicate names to acquire authority")
        } catch is MCPError {}
        await client.disconnect()
    }

    func testIncompleteOrUnrecognizedToolResultsFailWithoutResending() async throws {
        let results: [JSONValue] = [
            .object(["content": .array([])]),
            .object(["resultType": .string("future_result"), "content": .array([])]),
            .object([
                "resultType": .string("input_required"),
                "inputRequests": .object([
                    "private_roots": .object(["method": .string("roots/list"), "params": .object([:])])
                ]),
                "requestState": .string("opaque-state-not-for-automatic-replay")
            ]),
            .object([
                "resultType": .string("input_required"),
                "requestState": .string("state-only-still-incomplete")
            ])
        ]
        for result in results {
            let transport = StatelessContractTransport(resultOverrides: ["tools/call": result])
            let client = MCPClient(configuration: configuration(), transport: transport)
            _ = try await client.connect()
            _ = try await client.listTools()
            do {
                _ = try await client.callTool(name: "echo", arguments: .object(["text": .string("hello")]))
                XCTFail("Incomplete or unrecognized results must never be treated as tool success")
            } catch {
                XCTAssertTrue(error is MCPError)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["server/discover", "tools/list", "tools/call"])
            XCTAssertNil(requests.last?.params?["inputResponses"])
            XCTAssertNil(requests.last?.params?["requestState"])
            await client.disconnect()
        }
    }

    func testInvalidHTTPHeaderAnnotationExcludesOnlyAffectedTool() async throws {
        let invalid = StatelessContractTransport.tool(name: "invalid_header", inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tenant": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Tenant\r\nAuthorization")
                ])
            ])
        ]))
        let transport = StatelessContractTransport(tools: [StatelessContractTransport.tool(), invalid])
        var config = configuration()
        config.transport = .streamableHTTP(MCPStreamableHTTPConfiguration(
            endpoint: try XCTUnwrap(URL(string: "https://mcp.example.test/mcp"))
        ))
        let client = MCPClient(configuration: config, transport: transport)
        _ = try await client.connect()
        let tools = try await client.listTools()
        let warnings = await client.discoveryWarnings
        XCTAssertEqual(tools.map(\.name), ["echo"])
        XCTAssertFalse(warnings.isEmpty, "Excluded tools need an actionable discovery diagnostic")
        do {
            _ = try await client.callTool(name: "invalid_header", arguments: .object(["tenant": .string("x")]))
            XCTFail("An excluded tool must not be callable by bypassing discovery")
        } catch {
            XCTAssertTrue(error is MCPError)
        }
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.method == "tools/call" })
        await client.disconnect()
    }

    func testDisconnectRejectsLateDiscoverWithoutRestoringConnection() async throws {
        let transport = StatelessContractTransport(holdsDiscovery: true)
        let client = MCPClient(configuration: configuration(), transport: transport)
        let pending = Task { try await client.connect() }
        do {
            try await transport.waitUntilDiscoveryHeld()
        } catch {
            await client.disconnect()
            await transport.releaseDiscovery()
            _ = try? await pending.value
            throw error
        }
        await client.disconnect()
        await transport.releaseDiscovery()
        do {
            _ = try await pending.value
            XCTFail("A stale discovery callback cannot restore disconnected authority")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected late-discovery error: \(error)")
        }
        let connected = await client.isConnected
        let discovery = await client.initializeResult
        let requests = await transport.requests
        XCTAssertFalse(connected)
        XCTAssertNil(discovery)
        XCTAssertEqual(requests.map(\.method), ["server/discover"])
    }

    private func configuration(mode: MCPProtocolMode = .stateless) -> MCPServerConfiguration {
        MCPServerConfiguration(
            name: "Stateless contract",
            protocolMode: mode,
            transport: .stdio(MCPStdioConfiguration(command: "/usr/bin/mock"))
        )
    }
}

/// Deliberately independent of network framing: these tests exercise the client's
/// era, request metadata, result handling, and stale-response authority checks.
private actor StatelessContractTransport: MCPTransport {
    private let supportedVersions: [String]
    private let includesServerInfo: Bool
    private let discoverError: MCPJSONRPCError?
    private let resultOverrides: [String: JSONValue]
    private let tools: [JSONValue]
    private let holdsDiscovery: Bool
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private var discoveryReleased = false
    private var legacy = false
    private(set) var requests: [MCPJSONRPCRequest] = []

    init(
        supportedVersions: [String] = [MCPClient.statelessProtocolVersion],
        includesServerInfo: Bool = true,
        discoverError: MCPJSONRPCError? = nil,
        resultOverrides: [String: JSONValue] = [:],
        tools: [JSONValue] = [StatelessContractTransport.tool()],
        holdsDiscovery: Bool = false
    ) {
        self.supportedVersions = supportedVersions
        self.includesServerInfo = includesServerInfo
        self.discoverError = discoverError
        self.resultOverrides = resultOverrides
        self.tools = tools
        self.holdsDiscovery = holdsDiscovery
    }

    func start() {}
    func stop() {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        requests.append(request)
        if request.method == "server/discover", holdsDiscovery, !discoveryReleased {
            await withCheckedContinuation { discoveryContinuation = $0 }
        }
        guard let id = request.id else { return nil }
        if request.method == "server/discover", let discoverError {
            return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: discoverError)
        }
        if let override = resultOverrides[request.method] {
            return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: override, error: nil)
        }
        var result: [String: JSONValue]
        switch request.method {
        case "server/discover":
            result = [
                "supportedVersions": .array(supportedVersions.map(JSONValue.string)),
                "capabilities": Self.capabilities,
                "ttlMs": .number(0),
                "cacheScope": .string("private")
            ]
            if includesServerInfo {
                result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": Self.serverInfo])
            }
        case "initialize":
            legacy = true
            result = [
                "protocolVersion": .string(MCPClient.protocolVersion),
                "capabilities": Self.capabilities,
                "serverInfo": Self.serverInfo
            ]
        case "tools/list":
            result = ["tools": .array(tools)]
        case "tools/call":
            result = ["content": .array([
                .object(["type": .string("text"), "text": request.params?["arguments"]?["text"] ?? .string("")])
            ]), "isError": .bool(false)]
        case "resources/read":
            result = ["contents": .array([.object([
                "uri": request.params?["uri"] ?? .string(""),
                "mimeType": .string("text/plain"),
                "text": .string("fixture contents")
            ])])]
        case "prompts/get":
            result = ["messages": .array([.object([
                "role": .string("user"),
                "content": .object(["type": .string("text"), "text": .string("Review this fixture")])
            ])])]
        default:
            return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: MCPJSONRPCError(
                code: -32601, message: "Method not found", data: nil
            ))
        }
        if !legacy { result["resultType"] = .string("complete") }
        return MCPJSONRPCResponse(jsonrpc: "2.0", id: id, result: .object(result), error: nil)
    }

    func waitUntilDiscoveryHeld() async throws {
        for _ in 0..<500 {
            if discoveryContinuation != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MCPError.transport("Test discovery did not reach its suspension point")
    }

    func releaseDiscovery() {
        discoveryReleased = true
        discoveryContinuation?.resume()
        discoveryContinuation = nil
    }

    static func tool(name: String = "echo", inputSchema: JSONValue? = nil) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string("Stateless contract fixture"),
            "inputSchema": inputSchema ?? .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string")])])
            ])
        ])
    }

    private static let capabilities = JSONValue.object([
        "tools": .object([:]), "resources": .object([:]), "prompts": .object([:])
    ])
    private static let serverInfo = JSONValue.object([
        "name": .string("Stateless fixture"), "version": .string("1.0")
    ])
}
