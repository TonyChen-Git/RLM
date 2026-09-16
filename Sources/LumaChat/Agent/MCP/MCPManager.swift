import Foundation

actor MCPManager {
    private let registry: ToolRegistry
    private let transportFactory: any MCPTransportFactory
    private var clients: [UUID: MCPClient] = [:]
    private var snapshots: [UUID: MCPServerSnapshot] = [:]
    private var namespaces: [UUID: String] = [:]
    private var toolMappings: [UUID: [String: String]] = [:]
    private var connectionTokens: [UUID: UUID] = [:]
    private var logs: [UUID: [MCPLogEntry]] = [:]

    init(
        registry: ToolRegistry,
        transportFactory: any MCPTransportFactory = MCPDefaultTransportFactory()
    ) {
        self.registry = registry
        self.transportFactory = transportFactory
    }

    @discardableResult
    func connect(_ configuration: MCPServerConfiguration) async throws -> MCPServerSnapshot {
        guard configuration.enabled else {
            throw MCPError.invalidConfiguration("Server is disabled.")
        }
        if clients[configuration.id] != nil || connectionTokens[configuration.id] != nil {
            await disconnect(serverID: configuration.id)
        }

        let connectionToken = UUID()
        connectionTokens[configuration.id] = connectionToken
        let namespace = uniqueNamespace(for: configuration)
        // Reserve before the first await so two same-named servers cannot select
        // the same registry namespace while the actor is re-entrant.
        namespaces[configuration.id] = namespace

        snapshots[configuration.id] = MCPServerSnapshot(
            configuration: configuration,
            state: .connecting,
            negotiatedProtocolVersion: nil,
            serverInfo: nil,
            tools: [],
            resources: [],
            resourceTemplates: [],
            prompts: [],
            lastError: nil
        )
        appendLog(serverID: configuration.id, level: .info, message: "Connecting \(configuration.transport.kind.rawValue) transport")

        var candidateClient: MCPClient?
        do {
            let transport = try transportFactory.makeTransport(for: configuration)
            let client = MCPClient(configuration: configuration, transport: transport)
            candidateClient = client
            let initialized = try await client.connect()
            appendLog(
                serverID: configuration.id,
                level: .info,
                message: "Initialized \(initialized.serverInfo.name) \(initialized.serverInfo.version) using protocol \(initialized.protocolVersion)"
            )
            try requireCurrentConnection(configuration.id, token: connectionToken)
            // MCP server features are independently optional capabilities.
            // Capability absence and method-not-found both produce an empty
            // discovery result instead of preventing other features from use.
            let toolDiscovery = await optionalTools(from: client)
            let resourceDiscovery = await optionalResources(from: client)
            let templateDiscovery = await optionalResourceTemplates(from: client)
            let promptDiscovery = await optionalPrompts(from: client)
            let tools = toolDiscovery.values
            let resources = resourceDiscovery.values
            let resourceTemplates = templateDiscovery.values
            let prompts = promptDiscovery.values
            try requireCurrentConnection(configuration.id, token: connectionToken)
            let registration = try await register(
                tools: tools,
                for: configuration,
                client: client,
                namespace: namespace
            )
            guard connectionTokens[configuration.id] == connectionToken else {
                await registry.unregister(namespace: namespace)
                throw CancellationError()
            }

            clients[configuration.id] = client
            toolMappings[configuration.id] = registration.mapping
            let snapshot = MCPServerSnapshot(
                configuration: configuration,
                state: .connected,
                negotiatedProtocolVersion: initialized.protocolVersion,
                serverInfo: initialized.serverInfo,
                tools: tools,
                resources: resources,
                resourceTemplates: resourceTemplates,
                prompts: prompts,
                lastError: [
                    toolDiscovery.warning,
                    resourceDiscovery.warning,
                    templateDiscovery.warning,
                    promptDiscovery.warning
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                    .nilIfEmpty
            )
            snapshots[configuration.id] = snapshot
            appendLog(
                serverID: configuration.id,
                level: snapshot.lastError == nil ? .info : .warning,
                message: "Discovery: \(tools.count) tools, \(resources.count) resources, \(resourceTemplates.count) resource templates, \(prompts.count) prompts"
            )
            return snapshot
        } catch {
            await candidateClient?.disconnect()
            if connectionTokens[configuration.id] == connectionToken {
                connectionTokens.removeValue(forKey: configuration.id)
                if namespaces[configuration.id] == namespace {
                    namespaces.removeValue(forKey: configuration.id)
                    await registry.unregister(namespace: namespace)
                }
                toolMappings.removeValue(forKey: configuration.id)
                clients.removeValue(forKey: configuration.id)
            }
            var snapshot = snapshots[configuration.id] ?? MCPServerSnapshot(
                configuration: configuration,
                state: .failed,
                negotiatedProtocolVersion: nil,
                serverInfo: nil,
                tools: [],
                resources: [],
                resourceTemplates: [],
                prompts: [],
                lastError: nil
            )
            if connectionTokens[configuration.id] == nil {
                snapshot.state = .failed
                snapshot.lastError = SecretRedactor().redact(error.localizedDescription)
                snapshots[configuration.id] = snapshot
                appendLog(
                    serverID: configuration.id,
                    level: .error,
                    message: snapshot.lastError ?? "Connection failed"
                )
            }
            throw error
        }
    }

    func disconnect(serverID: UUID) async {
        connectionTokens.removeValue(forKey: serverID)
        if let namespace = namespaces.removeValue(forKey: serverID) {
            await registry.unregister(namespace: namespace)
        }
        toolMappings.removeValue(forKey: serverID)
        if let client = clients.removeValue(forKey: serverID) {
            await client.disconnect()
        }
        if var snapshot = snapshots[serverID] {
            snapshot.state = .disconnected
            snapshots[serverID] = snapshot
        }
        appendLog(serverID: serverID, level: .info, message: "Disconnected")
    }

    func disconnectAll() async {
        let serverIDs = Set(clients.keys)
            .union(namespaces.keys)
            .union(snapshots.keys)
        for serverID in serverIDs {
            await disconnect(serverID: serverID)
        }
    }

    @discardableResult
    func reconnect(serverID: UUID) async throws -> MCPServerSnapshot {
        guard let configuration = snapshots[serverID]?.configuration else {
            throw MCPError.serverNotFound(serverID)
        }
        await disconnect(serverID: serverID)
        return try await connect(configuration)
    }

    @discardableResult
    func refreshDiscovery(serverID: UUID) async throws -> MCPServerSnapshot {
        guard let client = clients[serverID],
              var snapshot = snapshots[serverID],
              let namespace = namespaces[serverID] else {
            throw MCPError.serverNotFound(serverID)
        }

        let toolDiscovery = await optionalTools(from: client)
        let resourceDiscovery = await optionalResources(from: client)
        let templateDiscovery = await optionalResourceTemplates(from: client)
        let promptDiscovery = await optionalPrompts(from: client)
        let tools = toolDiscovery.values
        let resources = resourceDiscovery.values
        let resourceTemplates = templateDiscovery.values
        let prompts = promptDiscovery.values
        await registry.unregister(namespace: namespace)
        do {
            let registration = try await register(
                tools: tools,
                for: snapshot.configuration,
                client: client,
                namespace: namespace
            )
            toolMappings[serverID] = registration.mapping
        } catch {
            toolMappings[serverID] = [:]
            throw error
        }

        snapshot.tools = tools
        snapshot.resources = resources
        snapshot.resourceTemplates = resourceTemplates
        snapshot.prompts = prompts
        snapshot.lastError = [
            toolDiscovery.warning,
            resourceDiscovery.warning,
            templateDiscovery.warning,
            promptDiscovery.warning
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
            .nilIfEmpty
        snapshots[serverID] = snapshot
        return snapshot
    }

    func listTools(serverID: UUID) async throws -> [MCPToolDescriptor] {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        return try await client.listTools()
    }

    func listResources(serverID: UUID) async throws -> [MCPResourceDescriptor] {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        return try await client.listResources()
    }

    func listPrompts(serverID: UUID) async throws -> [MCPPromptDescriptor] {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        return try await client.listPrompts()
    }

    func listResourceTemplates(serverID: UUID) async throws -> [MCPResourceTemplateDescriptor] {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        do {
            let templates = try await client.listResourceTemplates()
            appendLog(
                serverID: serverID,
                level: .info,
                message: "Listed \(templates.count) resource templates"
            )
            return templates
        } catch MCPError.remote(let code, _) where code == -32601 {
            appendLog(
                serverID: serverID,
                level: .info,
                message: "Resource templates are not supported by this server"
            )
            return []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let safeError = redactedError(error)
            appendLog(serverID: serverID, level: .error, message: safeError.localizedDescription)
            throw safeError
        }
    }

    func getPrompt(
        serverID: UUID,
        name: String,
        arguments: [String: String]? = nil
    ) async throws -> MCPPromptGetResult {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        do {
            let prompt = try await client.getPrompt(name: name, arguments: arguments)
            appendLog(
                serverID: serverID,
                level: .info,
                message: "Fetched prompt with \(prompt.messages.count) messages and \(arguments?.count ?? 0) arguments"
            )
            return prompt
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let safeError = redactedError(error)
            appendLog(serverID: serverID, level: .error, message: safeError.localizedDescription)
            throw safeError
        }
    }

    func readResource(serverID: UUID, uri: String) async throws -> MCPResourceReadResult {
        guard let client = clients[serverID] else { throw MCPError.serverNotFound(serverID) }
        do {
            let resource = try await client.readResource(uri: uri)
            appendLog(
                serverID: serverID,
                level: .info,
                message: "Read resource with \(resource.contents.count) content items"
            )
            return resource
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let safeError = redactedError(error)
            appendLog(serverID: serverID, level: .error, message: safeError.localizedDescription)
            throw safeError
        }
    }

    func snapshot(serverID: UUID) -> MCPServerSnapshot? {
        snapshots[serverID]
    }

    func allSnapshots() -> [MCPServerSnapshot] {
        snapshots.values.map { snapshot in
            var value = snapshot
            value.logs = logs[snapshot.id] ?? []
            return value
        }.sorted {
            $0.configuration.name.localizedStandardCompare($1.configuration.name) == .orderedAscending
        }
    }

    /// Namespaced model-facing name -> original server tool name.
    func registeredToolMapping(serverID: UUID) -> [String: String] {
        toolMappings[serverID] ?? [:]
    }

    private func register(
        tools: [MCPToolDescriptor],
        for configuration: MCPServerConfiguration,
        client: MCPClient,
        namespace: String
    ) async throws -> (mapping: [String: String], names: [String]) {
        var mapping: [String: String] = [:]
        var names: [String] = []
        var occurrences: [String: Int] = [:]
        var adapters: [any AgentTool] = []

        for descriptor in tools {
            let sanitized = MCPToolNamespace.sanitize(descriptor.name, fallback: "tool")
            let occurrence = occurrences[sanitized, default: 0] + 1
            occurrences[sanitized] = occurrence
            let suffix = occurrence == 1 ? "" : "_\(occurrence)"
            let registeredName = "\(namespace).\(sanitized)\(suffix)"
            mapping[registeredName] = descriptor.name
            names.append(registeredName)
            adapters.append(
                MCPAgentTool(
                    registeredName: registeredName,
                    serverName: configuration.name,
                    descriptor: descriptor,
                    configuration: configuration,
                    client: client
                )
            )
        }

        do {
            try await registry.register(adapters)
        } catch {
            await registry.unregister(namespace: namespace)
            throw error
        }
        return (mapping, names)
    }

    private func uniqueNamespace(for configuration: MCPServerConfiguration) -> String {
        let component = MCPToolNamespace.sanitize(configuration.name, fallback: "server")
        let base = "mcp.\(component)"
        guard namespaces.values.contains(base) else { return base }
        return "\(base)_\(configuration.id.uuidString.lowercased().prefix(8))"
    }

    private func requireCurrentConnection(_ serverID: UUID, token: UUID) throws {
        guard connectionTokens[serverID] == token else { throw CancellationError() }
    }

    private func appendLog(serverID: UUID, level: MCPLogEntry.Level, message: String) {
        let sanitized = SecretRedactor().redact(message)
        var entries = logs[serverID] ?? []
        entries.append(MCPLogEntry(level: level, message: String(sanitized.prefix(4_000))))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        logs[serverID] = entries
        if var snapshot = snapshots[serverID] {
            snapshot.logs = entries
            snapshots[serverID] = snapshot
        }
    }

    private func redactedError(_ error: Error) -> MCPError {
        let redact: (String) -> String = { value in
            String(SecretRedactor().redact(value).prefix(4_000))
        }
        guard let error = error as? MCPError else {
            return .transport(redact(error.localizedDescription))
        }
        switch error {
        case .invalidConfiguration(let detail): return .invalidConfiguration(redact(detail))
        case .transport(let detail): return .transport(redact(detail))
        case .invalidResponse(let detail): return .invalidResponse(redact(detail))
        case .remote(let code, let message): return .remote(code: code, message: redact(message))
        case .notConnected: return .notConnected
        case .alreadyRunning: return .alreadyRunning
        case .serverNotFound(let id): return .serverNotFound(id)
        case .sessionExpired: return .sessionExpired
        }
    }

    private func optionalResources(from client: MCPClient) async -> OptionalDiscovery<MCPResourceDescriptor> {
        do { return OptionalDiscovery(values: try await client.listResources()) }
        catch MCPError.remote(let code, _) where code == -32601 { return OptionalDiscovery(values: []) }
        catch {
            return OptionalDiscovery(
                values: [],
                warning: "Resources discovery failed: \(redactedError(error).localizedDescription)"
            )
        }
    }

    private func optionalTools(from client: MCPClient) async -> OptionalDiscovery<MCPToolDescriptor> {
        do { return OptionalDiscovery(values: try await client.listTools()) }
        catch MCPError.remote(let code, _) where code == -32601 { return OptionalDiscovery(values: []) }
        catch {
            return OptionalDiscovery(
                values: [],
                warning: "Tools discovery failed: \(redactedError(error).localizedDescription)"
            )
        }
    }

    private func optionalResourceTemplates(
        from client: MCPClient
    ) async -> OptionalDiscovery<MCPResourceTemplateDescriptor> {
        do { return OptionalDiscovery(values: try await client.listResourceTemplates()) }
        catch MCPError.remote(let code, _) where code == -32601 { return OptionalDiscovery(values: []) }
        catch {
            return OptionalDiscovery(
                values: [],
                warning: "Resource template discovery failed: \(redactedError(error).localizedDescription)"
            )
        }
    }

    private func optionalPrompts(from client: MCPClient) async -> OptionalDiscovery<MCPPromptDescriptor> {
        do { return OptionalDiscovery(values: try await client.listPrompts()) }
        catch MCPError.remote(let code, _) where code == -32601 { return OptionalDiscovery(values: []) }
        catch {
            return OptionalDiscovery(
                values: [],
                warning: "Prompts discovery failed: \(redactedError(error).localizedDescription)"
            )
        }
    }
}

private struct OptionalDiscovery<Value: Sendable>: Sendable {
    var values: [Value]
    var warning: String?

    init(values: [Value], warning: String? = nil) {
        self.values = values
        self.warning = warning
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum MCPToolNamespace {
    static func sanitize(_ value: String, fallback: String) -> String {
        var result = ""
        var previousWasSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            let isASCIIAlpha = (97...122).contains(scalar.value)
            let isDigit = (48...57).contains(scalar.value)
            if isASCIIAlpha || isDigit || scalar.value == 95 {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator, !result.isEmpty {
                result.append("_")
                previousWasSeparator = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if result.isEmpty { return fallback }
        if result.first?.isNumber == true { return "_\(result)" }
        return result
    }
}

private struct MCPAgentTool: AgentTool {
    let registeredName: String
    let serverName: String
    let descriptor: MCPToolDescriptor
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork: Bool
    let supportsParallelExecution: Bool
    let configuration: MCPServerConfiguration
    let client: MCPClient

    init(
        registeredName: String,
        serverName: String,
        descriptor: MCPToolDescriptor,
        configuration: MCPServerConfiguration,
        client: MCPClient
    ) {
        self.registeredName = registeredName
        self.serverName = serverName
        self.descriptor = descriptor
        self.configuration = configuration
        self.client = client

        let transportMinimum: AgentPermissionLevel = switch configuration.transport {
        case .streamableHTTP: .network
        case .stdio: .execute
        }
        var effective = Self.higherRisk(configuration.permissionLevel ?? transportMinimum, transportMinimum)
        if descriptor.annotations?.openWorldHint == true {
            effective = Self.higherRisk(effective, .network)
        }
        if descriptor.annotations?.destructiveHint == true { effective = .dangerous }
        permissionLevel = effective
        requiresNetwork = switch configuration.transport {
        case .streamableHTTP: true
        case .stdio:
            configuration.permissionLevel == .network
                || configuration.permissionLevel == .dangerous
                || descriptor.annotations?.openWorldHint == true
        }
        supportsParallelExecution = permissionLevel == .read
            && descriptor.annotations?.readOnlyHint == true
    }

    var id: String { registeredName }
    var name: String { registeredName }
    var displayName: String {
        let title = descriptor.title ?? descriptor.annotations?.title ?? descriptor.name
        return "\(serverName): \(title)"
    }
    var description: String {
        descriptor.description ?? "MCP tool \(descriptor.name) from \(serverName)."
    }
    var inputSchema: JSONValue { descriptor.inputSchema }
    var category: AgentToolCategory { .mcp }

    func isAvailable(in context: AgentToolContext) -> Bool {
        if context.executionLocation.kind == .ssh
            || context.executionLocation.kind == .futureCloud,
           case .stdio = configuration.transport {
            // STDIO MCP servers are child processes on the Mac. A Remote Task
            // must not present such a process as though it ran on its SSH/cloud
            // execution host. Streamable HTTP MCP remains an explicit external
            // service and is still governed by MCP/network approvals.
            return false
        }
        if let allowed = context.allowedMCPServerIDs,
           !allowed.contains(configuration.id) {
            return false
        }
        guard configuration.scope == .projectOnly else { return true }
        guard let projectPath = configuration.projectPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !projectPath.isEmpty else { return false }
        let workspaceURL = URL(fileURLWithPath: context.workspace.rootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let projectURL = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return workspaceURL.path == projectURL.path
    }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        let result = try await client.callTool(name: descriptor.name, arguments: arguments)
        let rendered = MCPContentRenderer.render(result.content)
        let data = result.structuredContent ?? .array(result.content)
        let isError = result.isError ?? false
        let mayMutateWorkspace = descriptor.annotations?.readOnlyHint != true
        let safetyNotice = mayMutateWorkspace
            ? "MCP 工具可能在 Luma Chat 原生檔案交易之外產生副作用；無法保證 Diff/Undo snapshot。\n"
            : ""
        return AgentToolResult(
            content: safetyNotice + rendered,
            data: data,
            isError: isError,
            mayHaveChangedWorkspace: mayMutateWorkspace && !isError
        )
    }

    private static func higherRisk(
        _ lhs: AgentPermissionLevel,
        _ rhs: AgentPermissionLevel
    ) -> AgentPermissionLevel {
        func rank(_ level: AgentPermissionLevel) -> Int {
            switch level {
            case .read: 0
            case .write: 1
            case .execute: 2
            case .network: 3
            case .dangerous: 4
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }
}

private enum MCPContentRenderer {
    static func render(_ content: [JSONValue]) -> String {
        let pieces = content.compactMap { item -> String? in
            guard let object = item.objectValue else { return compactJSON(item) }
            switch object["type"]?.stringValue {
            case "text":
                return object["text"]?.stringValue
            case "resource":
                if let resource = object["resource"]?.objectValue,
                   let text = resource["text"]?.stringValue {
                    return text
                }
                return "[MCP resource content]"
            case "image":
                return "[MCP image: \(object["mimeType"]?.stringValue ?? "unknown type")]"
            case "audio":
                return "[MCP audio: \(object["mimeType"]?.stringValue ?? "unknown type")]"
            default:
                return compactJSON(item)
            }
        }
        return pieces.isEmpty ? "MCP tool completed without textual content." : pieces.joined(separator: "\n")
    }

    private static func compactJSON(_ value: JSONValue) -> String? {
        guard let data = try? MCPWireCodec.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
