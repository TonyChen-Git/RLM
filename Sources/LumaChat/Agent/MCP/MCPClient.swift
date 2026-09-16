import Foundation

actor MCPClient {
    static let protocolVersion = "2025-06-18"

    let configuration: MCPServerConfiguration
    private let transport: any MCPTransport
    private let requestTimeout: TimeInterval
    private var nextRequestID: Int64 = 1
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
        try await transport.start()
        do {
            let resultValue = try await call(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("Luma Chat"),
                        "version": .string("1.0")
                    ])
                ])
            )
            let result = try decodePayload(
                MCPInitializeResult.self,
                from: resultValue,
                context: "initialize result"
            )
            guard !result.protocolVersion.isEmpty else {
                throw MCPError.invalidResponse("Initialize result omitted protocolVersion.")
            }
            try await notify(method: "notifications/initialized", params: .object([:]))
            initializeResult = result
            isConnected = true
            return result
        } catch {
            await transport.stop()
            initializeResult = nil
            isConnected = false
            throw error
        }
    }

    func disconnect() async {
        await transport.stop()
        initializeResult = nil
        isConnected = false
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
        return tools
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

    func callTool(name: String, arguments: JSONValue) async throws -> MCPToolCallResult {
        try requireConnection()
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
        let result = try await call(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
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
        mayRecoverExpiredSession: Bool = true
    ) async throws -> JSONValue {
        let id = MCPJSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let request = MCPJSONRPCRequest(id: id, method: method, params: params)
        let response: MCPJSONRPCResponse
        do {
            response = try await responseWithTimeout(for: request)
        } catch MCPError.sessionExpired where mayRecoverExpiredSession && method != "initialize" {
            await transport.stop()
            initializeResult = nil
            isConnected = false
            _ = try await connect()
            return try await call(
                method: method,
                params: params,
                mayRecoverExpiredSession: false
            )
        }
        if let error = response.error {
            let redacted = SecretRedactor().redact(error.message)
            throw MCPError.remote(code: error.code, message: String(redacted.prefix(4_000)))
        }
        guard response.id == id else {
            throw MCPError.invalidResponse("JSON-RPC response id does not match its request.")
        }
        guard let result = response.result else {
            throw MCPError.invalidResponse("JSON-RPC response contains neither result nor error.")
        }
        try MCPPayloadValidator.validateJSON(result, context: "MCP response")
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
                throw MCPError.transport("Request timed out after \(Int(timeout)) seconds.")
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private func requireConnection() throws {
        guard isConnected else { throw MCPError.notConnected }
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
