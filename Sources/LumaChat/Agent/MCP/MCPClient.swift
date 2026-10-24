import Foundation

actor MCPClient {
    static let protocolVersion = "2025-06-18"
    static let statelessProtocolVersion = "2026-07-28"
    private var activeProtocolVersion = protocolVersion
    private var discoveredTools: [String: MCPToolDescriptor] = [:]
    private(set) var discoveryWarnings: [String] = []

    let configuration: MCPServerConfiguration
    private let transport: any MCPTransport
    private let requestTimeout: TimeInterval
    private var nextRequestID: Int64 = 1
    private var connectionGeneration = UUID()
    private var isConnecting = false
    private var isDisconnecting = false
    private(set) var initializeResult: MCPInitializeResult?
    private(set) var isConnected = false

    init(
        configuration: MCPServerConfiguration,
        transport: any MCPTransport,
        requestTimeout: TimeInterval = 30
    ) {
        self.configuration = configuration
        self.transport = transport
        self.requestTimeout = max(1, requestTimeout)
    }

    func connect() async throws -> MCPInitializeResult {
        if let initializeResult, isConnected { return initializeResult }
        guard !isConnecting, !isDisconnecting else { throw MCPError.alreadyRunning }
        let generation = UUID()
        connectionGeneration = generation
        isConnecting = true
        do {
            try await transport.start()
            try requireGeneration(generation)
            let result: MCPInitializeResult
            if configuration.protocolMode == .legacy {
                result = try await initializeLegacy()
            } else {
                activeProtocolVersion = Self.statelessProtocolVersion
                do {
                    let value = try await call(method: "server/discover", params: .object([:]))
                    let discovery = try decodePayload(MCPDiscoverResult.self, from: value, context: "server/discover result")
                    guard discovery.supportedVersions.contains(Self.statelessProtocolVersion),
                          discovery.supportedVersions.count <= 32,
                          discovery.capabilities.objectValue != nil else {
                        throw MCPError.invalidResponse("server/discover does not support the selected protocol or contains malformed capabilities.")
                    }
                    let info: MCPImplementationInfo
                    if let value = discovery.metadata?["io.modelcontextprotocol/serverInfo"] {
                        info = try decodePayload(MCPImplementationInfo.self, from: value, context: "serverInfo")
                    } else {
                        info = MCPImplementationInfo(name: configuration.name, version: "unknown")
                    }
                    result = MCPInitializeResult(protocolVersion: Self.statelessProtocolVersion,
                        capabilities: discovery.capabilities, serverInfo: info, instructions: discovery.instructions)
                } catch {
                    try requireGeneration(generation)
                    guard configuration.protocolMode == .automatic, mayUseLegacy(after: error) else { throw error }
                    // Only the read-only discovery probe can negotiate a fallback.
                    // Restart the transport so late probe replies cannot join the legacy lifecycle.
                    await transport.stop()
                    try requireGeneration(generation)
                    try await transport.start()
                    try requireGeneration(generation)
                    result = try await initializeLegacy()
                }
            }
            try requireGeneration(generation)
            initializeResult = result
            isConnected = true
            isConnecting = false
            return result
        } catch {
            if connectionGeneration == generation {
                await stopConnection(generation: UUID())
            }
            throw publicError(error)
        }
    }

    private func initializeLegacy() async throws -> MCPInitializeResult {
        activeProtocolVersion = Self.protocolVersion
        let value = try await call(method: "initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]), "clientInfo": clientInfo
        ]))
        let result = try decodePayload(MCPInitializeResult.self, from: value, context: "initialize result")
        guard result.protocolVersion == Self.protocolVersion else {
            throw MCPError.invalidResponse("Unsupported MCP protocol \(result.protocolVersion); select a supported protocol in Settings.")
        }
        try await notify(method: "notifications/initialized", params: .object([:]))
        return result
    }

    private var clientInfo: JSONValue {
        .object(["name": .string("LumaChat"), "version": .string(
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        )])
    }

    private func mayUseLegacy(after error: Error) -> Bool {
        switch error {
        case MCPCompatibilityError.legacyHTTPServer:
            return configuration.transport.kind == .streamableHTTP
        case MCPCompatibilityError.unsupportedVersion(let versions):
            return versions.contains(Self.protocolVersion)
        case MCPCompatibilityError.requestTimedOut:
            return configuration.transport.kind == .stdio
        case MCPError.remote(let code, _):
            return configuration.transport.kind == .stdio && ![-32020, -32021, -32022].contains(code)
        default: return false
        }
    }

    private func publicError(_ error: Error) -> Error {
        switch error {
        case MCPCompatibilityError.legacyHTTPServer:
            return MCPError.invalidResponse("The endpoint requires legacy MCP; choose Automatic or 2025-06-18 compatibility.")
        case MCPCompatibilityError.unsupportedVersion:
            return MCPError.invalidResponse("The server does not support the selected MCP protocol.")
        case MCPCompatibilityError.requestTimedOut:
            return MCPError.transport("Request timed out after \(Int(requestTimeout)) seconds. The operation was not resent; verify its result before retrying.")
        case let error as URLError:
            return MCPError.transport("Network request failed (\(error.code.rawValue)). No operation was resent; verify its result before retrying.")
        default: return error
        }
    }

    func disconnect() async {
        await stopConnection(generation: UUID())
    }

    private func stopConnection(generation: UUID) async {
        // Invalidate pending replies before suspending on transport teardown.
        connectionGeneration = generation
        initializeResult = nil
        discoveredTools = [:]
        discoveryWarnings = []
        isConnected = false
        isConnecting = false
        isDisconnecting = true
        await transport.stop()
        if connectionGeneration == generation { isDisconnecting = false }
    }

    func reconnect() async throws -> MCPInitializeResult {
        await disconnect()
        return try await connect()
    }

    func listTools() async throws -> [MCPToolDescriptor] {
        try requireConnection()
        try requireCapability("tools")
        var tools: [MCPToolDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var remainingBytes = 32 * 1_024 * 1_024
        repeat {
            pageCount += 1
            guard pageCount <= 50 else {
                throw MCPError.invalidResponse("tools/list exceeded 50 pages.")
            }
            let result = try await call(
                method: "tools/list",
                params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            )
            try consumeDiscoveryBudget(result, remainingBytes: &remainingBytes)
            let page = try decodePayload(
                MCPToolsListResult.self,
                from: result,
                context: "tools/list result"
            )
            guard tools.count + page.tools.count <= 2_000 else {
                throw MCPError.invalidResponse("tools/list exceeded 2,000 tools.")
            }
            try MCPPayloadValidator.validateTools(page.tools)
            try MCPPayloadValidator.validateCursor(page.nextCursor)
            tools.append(contentsOf: page.tools)
            cursor = uniqueNextCursor(page.nextCursor, seen: &seenCursors)
        } while cursor != nil
        var accepted: [MCPToolDescriptor] = []
        var byName: [String: MCPToolDescriptor] = [:]
        var seenNames = Set<String>()
        var warnings: [String] = []
        for tool in tools {
            guard seenNames.insert(tool.name).inserted else {
                throw MCPError.invalidResponse("tools/list contains duplicate tool names.")
            }
            if activeProtocolVersion == Self.statelessProtocolVersion,
               configuration.transport.kind == .streamableHTTP {
                do { try MCPHTTPHeaderProjection.validate(tool: tool) }
                catch {
                    let name = String(SecretRedactor().redact(tool.name).prefix(128))
                    if warnings.count < 50 { warnings.append("Excluded tool \(name): invalid HTTP header schema.") }
                    continue
                }
            }
            byName[tool.name] = tool
            accepted.append(tool)
        }
        discoveredTools = byName
        discoveryWarnings = warnings
        return accepted
    }

    func listResources() async throws -> [MCPResourceDescriptor] {
        try requireConnection()
        try requireCapability("resources")
        var resources: [MCPResourceDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var remainingBytes = 32 * 1_024 * 1_024
        repeat {
            pageCount += 1
            guard pageCount <= 50 else {
                throw MCPError.invalidResponse("resources/list exceeded 50 pages.")
            }
            let result = try await call(
                method: "resources/list",
                params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            )
            try consumeDiscoveryBudget(result, remainingBytes: &remainingBytes)
            let page = try decodePayload(
                MCPResourcesListResult.self,
                from: result,
                context: "resources/list result"
            )
            guard resources.count + page.resources.count <= 2_000 else {
                throw MCPError.invalidResponse("resources/list exceeded 2,000 resources.")
            }
            try MCPPayloadValidator.validateResources(page.resources)
            try MCPPayloadValidator.validateCursor(page.nextCursor)
            resources.append(contentsOf: page.resources)
            cursor = uniqueNextCursor(page.nextCursor, seen: &seenCursors)
        } while cursor != nil
        return resources
    }

    func listResourceTemplates() async throws -> [MCPResourceTemplateDescriptor] {
        try requireConnection()
        try requireCapability("resources")
        var templates: [MCPResourceTemplateDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var remainingBytes = 32 * 1_024 * 1_024
        repeat {
            pageCount += 1
            guard pageCount <= 50 else {
                throw MCPError.invalidResponse("resources/templates/list exceeded 50 pages.")
            }
            let result = try await call(
                method: "resources/templates/list",
                params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            )
            try consumeDiscoveryBudget(result, remainingBytes: &remainingBytes)
            let page = try decodePayload(
                MCPResourceTemplatesListResult.self,
                from: result,
                context: "resources/templates/list result"
            )
            guard templates.count + page.resourceTemplates.count <= 2_000 else {
                throw MCPError.invalidResponse(
                    "resources/templates/list exceeded 2,000 resource templates."
                )
            }
            try MCPPayloadValidator.validateResourceTemplates(page.resourceTemplates)
            try MCPPayloadValidator.validateCursor(page.nextCursor)
            templates.append(contentsOf: page.resourceTemplates)
            cursor = uniqueNextCursor(page.nextCursor, seen: &seenCursors)
        } while cursor != nil
        return templates
    }

    func listPrompts() async throws -> [MCPPromptDescriptor] {
        try requireConnection()
        try requireCapability("prompts")
        var prompts: [MCPPromptDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var remainingBytes = 32 * 1_024 * 1_024
        repeat {
            pageCount += 1
            guard pageCount <= 50 else {
                throw MCPError.invalidResponse("prompts/list exceeded 50 pages.")
            }
            let result = try await call(
                method: "prompts/list",
                params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
            )
            try consumeDiscoveryBudget(result, remainingBytes: &remainingBytes)
            let page = try decodePayload(
                MCPPromptsListResult.self,
                from: result,
                context: "prompts/list result"
            )
            guard prompts.count + page.prompts.count <= 2_000 else {
                throw MCPError.invalidResponse("prompts/list exceeded 2,000 prompts.")
            }
            try MCPPayloadValidator.validatePrompts(page.prompts)
            try MCPPayloadValidator.validateCursor(page.nextCursor)
            prompts.append(contentsOf: page.prompts)
            cursor = uniqueNextCursor(page.nextCursor, seen: &seenCursors)
        } while cursor != nil
        return prompts
    }

    func callTool(
        name: String,
        arguments: JSONValue,
        expectedDescriptor: MCPToolDescriptor? = nil
    ) async throws -> MCPToolCallResult {
        try requireConnection()
        if let expectedDescriptor, discoveredTools[name] != expectedDescriptor {
            throw MCPError.invalidConfiguration("Tool discovery changed; approve the current tool before retrying.")
        }
        guard case .object = arguments else {
            throw MCPError.invalidConfiguration("MCP tool arguments must be a JSON object.")
        }
        try MCPPayloadValidator.validateJSON(
            arguments,
            context: "MCP tool arguments",
            maximumEncodedBytes: 8 * 1_024 * 1_024,
            maximumStringBytes: 4 * 1_024 * 1_024,
            input: true
        )
        var headers: [String: String] = [:]
        if activeProtocolVersion == Self.statelessProtocolVersion {
            try requireCapability("tools")
            guard let tool = discoveredTools[name] else {
                throw MCPError.invalidConfiguration("Discover and approve this MCP tool before calling it.")
            }
            if configuration.transport.kind == .streamableHTTP {
                headers = try MCPHTTPHeaderProjection.headers(for: tool, arguments: arguments.objectValue ?? [:])
            }
        }
        let result = try await call(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]),
            localHTTPHeaders: headers
        )
        return try decodePayload(
            MCPToolCallResult.self,
            from: result,
            context: "tools/call result"
        )
    }

    func getPrompt(
        name: String,
        arguments: [String: String]? = nil
    ) async throws -> MCPPromptGetResult {
        try requireConnection()
        try requireCapability("prompts")
        try MCPPayloadValidator.validatePromptRequest(name: name, arguments: arguments)
        var parameters: [String: JSONValue] = ["name": .string(name)]
        if let arguments {
            parameters["arguments"] = .object(arguments.mapValues(JSONValue.string))
        }
        let result = try await call(
            method: "prompts/get",
            params: .object(parameters)
        )
        return try MCPPayloadValidator.parsePromptGetResult(result)
    }

    func readResource(uri: String) async throws -> MCPResourceReadResult {
        try requireConnection()
        try requireCapability("resources")
        try MCPPayloadValidator.validateResourceURI(uri, input: true)
        let result = try await call(
            method: "resources/read",
            params: .object(["uri": .string(uri)])
        )
        return try MCPPayloadValidator.parseResourceReadResult(result)
    }

    private func call(
        method: String,
        params: JSONValue?,
        localHTTPHeaders: [String: String] = [:]
    ) async throws -> JSONValue {
        let generation = connectionGeneration
        let modern = activeProtocolVersion == Self.statelessProtocolVersion
        let id = MCPJSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        var parameters = params
        if modern {
            var object = params?.objectValue ?? [:]
            object["_meta"] = .object([
                "io.modelcontextprotocol/protocolVersion": .string(Self.statelessProtocolVersion),
                "io.modelcontextprotocol/clientCapabilities": .object([:]),
                "io.modelcontextprotocol/clientInfo": clientInfo
            ])
            parameters = .object(object)
        }
        var request = MCPJSONRPCRequest(id: id, method: method, params: parameters)
        request.localHTTPHeaders = localHTTPHeaders
        let response: MCPJSONRPCResponse
        do {
            response = try await responseWithTimeout(for: request)
        } catch {
            try requireGeneration(generation)
            if isConnected {
                // A timeout/disconnect can follow server-side execution. Never
                // reinitialize or replay with stale tool/permission discovery.
                if case MCPError.invalidConfiguration = error { /* Local preflight did not send. */ }
                else { await stopConnection(generation: UUID()) }
            }
            if method == "server/discover" { throw error }
            throw publicError(error)
        }
        try requireGeneration(generation)
        guard response.id == id, response.jsonrpc == "2.0",
              (response.result == nil) != (response.error == nil) else {
            throw MCPError.invalidResponse("Invalid JSON-RPC envelope or response id.")
        }
        if let error = response.error {
            if modern, method == "server/discover", error.code == -32022,
               error.data?["requested"]?.stringValue == Self.statelessProtocolVersion,
               case .array(let values)? = error.data?["supported"], values.count <= 32,
               values.allSatisfy({ $0.stringValue != nil }) {
                throw MCPCompatibilityError.unsupportedVersion(values.compactMap(\.stringValue))
            }
            let redacted = SecretRedactor().redact(error.message)
            throw MCPError.remote(code: error.code, message: String(redacted.prefix(4_000)))
        }
        guard let result = response.result else {
            throw MCPError.invalidResponse("JSON-RPC response contains neither result nor error.")
        }
        try MCPPayloadValidator.validateJSON(result, context: "MCP response")
        if modern {
            guard result["resultType"]?.stringValue == "complete" else {
                if result["resultType"]?.stringValue == "input_required" {
                    throw MCPError.invalidResponse("Server requested an unsupported client capability. No input was supplied or operation replayed.")
                }
                throw MCPError.invalidResponse("Stateless MCP requires resultType complete.")
            }
        }
        return result
    }

    private func notify(method: String, params: JSONValue?) async throws {
        _ = try await transport.send(MCPJSONRPCRequest(id: nil, method: method, params: params))
    }

    private func responseWithTimeout(for request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        let timeout = requestTimeout
        return try await withThrowingTaskGroup(of: MCPJSONRPCResponse.self) { group in
            group.addTask { [transport] in
                guard let response = try await transport.send(request) else {
                    throw MCPError.invalidResponse("Transport accepted a request without returning a response.")
                }
                return response
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPCompatibilityError.requestTimedOut
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private func requireConnection() throws {
        guard isConnected else { throw MCPError.notConnected }
    }

    private func requireGeneration(_ generation: UUID) throws {
        guard generation == connectionGeneration else { throw CancellationError() }
    }

    private func requireCapability(_ name: String) throws {
        guard let capabilities = initializeResult?.capabilities.objectValue,
              capabilities[name]?.objectValue != nil else {
            throw MCPError.remote(
                code: -32601,
                message: "The server does not advertise the \(name) capability."
            )
        }
    }

    private func decodePayload<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue,
        context: String
    ) throws -> Value {
        do {
            return try MCPWireCodec.decode(type, from: value)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.invalidResponse("\(context) contains malformed fields.")
        }
    }

    private func uniqueNextCursor(_ candidate: String?, seen: inout Set<String>) -> String? {
        guard let candidate, !candidate.isEmpty, seen.insert(candidate).inserted else { return nil }
        return candidate
    }

    private func consumeDiscoveryBudget(
        _ value: JSONValue,
        remainingBytes: inout Int
    ) throws {
        remainingBytes -= try MCPWireCodec.encode(value).count
        guard remainingBytes >= 0 else {
            throw MCPError.invalidResponse("MCP discovery exceeded the 32 MiB cumulative limit.")
        }

        var stack: [(JSONValue, Int)] = [(value, 0)]
        var entries = 0
        while let (current, depth) = stack.popLast() {
            guard depth <= 32 else {
                throw MCPError.invalidResponse("MCP discovery JSON exceeds 32 levels of nesting.")
            }
            entries += 1
            guard entries <= 200_000 else {
                throw MCPError.invalidResponse("MCP discovery JSON contains too many values.")
            }
            switch current {
            case .string(let text):
                guard text.utf8.count <= 256 * 1_024 else {
                    throw MCPError.invalidResponse("MCP discovery contains an oversized string.")
                }
            case .array(let values):
                stack.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let object):
                guard object.keys.allSatisfy({ $0.utf8.count <= 4_096 }) else {
                    throw MCPError.invalidResponse("MCP discovery contains an oversized JSON key.")
                }
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            case .number, .bool, .null:
                break
            }
        }
    }
}
