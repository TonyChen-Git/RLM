import Foundation

// MARK: - Configuration

enum MCPTransportKind: String, Codable, CaseIterable, Sendable {
    case stdio
    case streamableHTTP = "streamable_http"
}

enum MCPServerScope: String, Codable, CaseIterable, Sendable {
    case global
    case projectOnly = "project_only"

    var title: String {
        switch self {
        case .global: "Global"
        case .projectOnly: "Project Only"
        }
    }
}

struct MCPStdioConfiguration: Codable, Equatable, Sendable {
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?

    init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

struct MCPStreamableHTTPConfiguration: Codable, Equatable, Sendable {
    var endpoint: URL
    var headers: [String: String]

    init(endpoint: URL, headers: [String: String] = [:]) {
        self.endpoint = endpoint
        self.headers = headers
    }
}

enum MCPTransportConfiguration: Equatable, Sendable {
    case stdio(MCPStdioConfiguration)
    case streamableHTTP(MCPStreamableHTTPConfiguration)

    var kind: MCPTransportKind {
        switch self {
        case .stdio: .stdio
        case .streamableHTTP: .streamableHTTP
        }
    }
}

extension MCPTransportConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case args
        case arguments
        case env
        case environment
        case cwd
        case workingDirectory
        case url
        case endpoint
        case headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type)?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let command = try container.decodeIfPresent(String.self, forKey: .command)
        let endpoint = try container.decodeIfPresent(URL.self, forKey: .url)
            ?? container.decodeIfPresent(URL.self, forKey: .endpoint)

        if rawType == "stdio" || (rawType == nil && command != nil) {
            guard let command, !command.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .command,
                    in: container,
                    debugDescription: "An MCP stdio server requires a command."
                )
            }
            self = .stdio(
                MCPStdioConfiguration(
                    command: command,
                    arguments: try container.decodeIfPresent([String].self, forKey: .args)
                        ?? container.decodeIfPresent([String].self, forKey: .arguments)
                        ?? [],
                    environment: try container.decodeIfPresent([String: String].self, forKey: .env)
                        ?? container.decodeIfPresent([String: String].self, forKey: .environment)
                        ?? [:],
                    workingDirectory: try container.decodeIfPresent(String.self, forKey: .cwd)
                        ?? container.decodeIfPresent(String.self, forKey: .workingDirectory)
                )
            )
            return
        }

        let isHTTP = rawType == "streamable_http"
            || rawType == "streamablehttp"
            || rawType == "http"
            || (rawType == nil && endpoint != nil)
        if isHTTP, let endpoint {
            self = .streamableHTTP(
                MCPStreamableHTTPConfiguration(
                    endpoint: endpoint,
                    headers: try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
                )
            )
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .type,
            in: container,
            debugDescription: "MCP transport must be stdio or streamable HTTP."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let configuration):
            try container.encode(MCPTransportKind.stdio.rawValue, forKey: .type)
            try container.encode(configuration.command, forKey: .command)
            if !configuration.arguments.isEmpty {
                try container.encode(configuration.arguments, forKey: .args)
            }
            if !configuration.environment.isEmpty {
                try container.encode(configuration.environment, forKey: .env)
            }
            try container.encodeIfPresent(configuration.workingDirectory, forKey: .cwd)
        case .streamableHTTP(let configuration):
            try container.encode(MCPTransportKind.streamableHTTP.rawValue, forKey: .type)
            try container.encode(configuration.endpoint, forKey: .url)
            if !configuration.headers.isEmpty {
                try container.encode(configuration.headers, forKey: .headers)
            }
        }
    }
}

struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var permissionLevel: AgentPermissionLevel?
    var scope: MCPServerScope
    /// Canonical workspace root selected for Project Only servers. This is
    /// routing metadata, never a credential or an additional file authority.
    var projectPath: String?
    /// Set only for declarative MCP servers managed by an installed plugin.
    /// Manual servers remain nil and are never removed with a plugin.
    var ownerPluginID: String?
    var transport: MCPTransportConfiguration

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        permissionLevel: AgentPermissionLevel? = nil,
        scope: MCPServerScope = .global,
        projectPath: String? = nil,
        ownerPluginID: String? = nil,
        transport: MCPTransportConfiguration
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.permissionLevel = permissionLevel
        self.scope = scope
        self.projectPath = projectPath
        self.ownerPluginID = ownerPluginID
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case permissionLevel
        case scope
        case projectPath, ownerPluginID
        case transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        permissionLevel = try container.decodeIfPresent(AgentPermissionLevel.self, forKey: .permissionLevel)
        scope = try container.decodeIfPresent(MCPServerScope.self, forKey: .scope) ?? .global
        projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        ownerPluginID = try container.decodeIfPresent(String.self, forKey: .ownerPluginID)
        if container.contains(.transport) {
            transport = try container.decode(MCPTransportConfiguration.self, forKey: .transport)
        } else {
            // The common Claude/Codex import shape keeps command/url fields at
            // the server object level. Decode that object as a transport too.
            transport = try MCPTransportConfiguration(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !name.isEmpty { try container.encode(name, forKey: .name) }
        if !enabled { try container.encode(enabled, forKey: .enabled) }
        try container.encodeIfPresent(permissionLevel, forKey: .permissionLevel)
        if scope != .global { try container.encode(scope, forKey: .scope) }
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
        try container.encodeIfPresent(ownerPluginID, forKey: .ownerPluginID)
        try container.encode(transport, forKey: .transport)
    }
}

/// Supports the conventional `{ "mcpServers": { "name": { ... } } }` import
/// document while retaining stable UUIDs once configurations are persisted.
struct MCPConfigurationDocument: Codable, Equatable, Sendable {
    var mcpServers: [String: MCPServerConfiguration]

    init(mcpServers: [String: MCPServerConfiguration] = [:]) {
        self.mcpServers = mcpServers
    }

    var servers: [MCPServerConfiguration] {
        mcpServers.map { key, value in
            var server = value
            if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                server.name = key
            }
            return server
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - JSON-RPC wire types

enum MCPJSONRPCID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MCPJSONRPCRequest: Codable, Equatable, Sendable {
    var jsonrpc = "2.0"
    var id: MCPJSONRPCID?
    var method: String
    var params: JSONValue?

    init(id: MCPJSONRPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct MCPJSONRPCError: Codable, Equatable, Error, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?
}

struct MCPJSONRPCResponse: Codable, Equatable, Sendable {
    var jsonrpc: String?
    var id: MCPJSONRPCID?
    var result: JSONValue?
    var error: MCPJSONRPCError?
}

enum MCPError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case notConnected
    case alreadyRunning
    case transport(String)
    case invalidResponse(String)
    case remote(code: Int, message: String)
    case serverNotFound(UUID)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "MCP 設定無效：\(detail)"
        case .notConnected: "MCP server 尚未連線。"
        case .alreadyRunning: "MCP transport 已經啟動。"
        case .transport(let detail): "MCP transport 錯誤：\(detail)"
        case .invalidResponse(let detail): "MCP server 回傳無效內容：\(detail)"
        case .remote(let code, let message): "MCP server 錯誤 \(code)：\(message)"
        case .serverNotFound(let id): "找不到 MCP server：\(id.uuidString)"
        case .sessionExpired: "MCP HTTP session 已過期，正在重新初始化。"
        }
    }
}

// MARK: - MCP protocol payloads

struct MCPImplementationInfo: Codable, Equatable, Sendable {
    var name: String
    var version: String
}

struct MCPInitializeResult: Codable, Equatable, Sendable {
    var protocolVersion: String
    var capabilities: JSONValue
    var serverInfo: MCPImplementationInfo
    var instructions: String?
}

struct MCPToolAnnotations: Codable, Equatable, Sendable {
    var title: String?
    var readOnlyHint: Bool?
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?
}

struct MCPToolDescriptor: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var description: String?
    var inputSchema: JSONValue
    var outputSchema: JSONValue?
    var annotations: MCPToolAnnotations?
}

struct MCPToolsListResult: Codable, Equatable, Sendable {
    var tools: [MCPToolDescriptor]
    var nextCursor: String?
}

struct MCPResourceDescriptor: Codable, Equatable, Sendable {
    var uri: String
    var name: String
    var title: String?
    var description: String?
    var mimeType: String?
    var size: Int64?
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case uri
        case name
        case title
        case description
        case mimeType
        case size
        case annotations
        case metadata = "_meta"
    }
}

struct MCPResourcesListResult: Codable, Equatable, Sendable {
    var resources: [MCPResourceDescriptor]
    var nextCursor: String?
}

struct MCPContentAnnotations: Codable, Equatable, Sendable {
    var audience: [MCPRole]?
    var priority: Double?
    var lastModified: String?
}

enum MCPRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

struct MCPResourceTemplateDescriptor: Codable, Equatable, Sendable {
    var uriTemplate: String
    var name: String
    var title: String?
    var description: String?
    var mimeType: String?
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case uriTemplate
        case name
        case title
        case description
        case mimeType
        case annotations
        case metadata = "_meta"
    }
}

struct MCPResourceTemplatesListResult: Codable, Equatable, Sendable {
    var resourceTemplates: [MCPResourceTemplateDescriptor]
    var nextCursor: String?
}

struct MCPPromptArgument: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var description: String?
    var required: Bool?
}

struct MCPPromptDescriptor: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var description: String?
    var arguments: [MCPPromptArgument]?
}

struct MCPPromptsListResult: Codable, Equatable, Sendable {
    var prompts: [MCPPromptDescriptor]
    var nextCursor: String?
}

struct MCPToolCallResult: Codable, Equatable, Sendable {
    var content: [JSONValue]
    var structuredContent: JSONValue?
    var isError: Bool?
}

struct MCPTextResourceContents: Equatable, Sendable {
    var uri: String
    var mimeType: String?
    var text: String
    var metadata: JSONValue?
}

struct MCPBlobResourceContents: Equatable, Sendable {
    var uri: String
    var mimeType: String?
    /// Strictly decoded bytes from the wire-level base64 `blob` field.
    var data: Data
    var metadata: JSONValue?
}

enum MCPResourceContent: Equatable, Sendable {
    case text(MCPTextResourceContents)
    case blob(MCPBlobResourceContents)

    var uri: String {
        switch self {
        case .text(let content): content.uri
        case .blob(let content): content.uri
        }
    }

    var mimeType: String? {
        switch self {
        case .text(let content): content.mimeType
        case .blob(let content): content.mimeType
        }
    }

    var text: String? {
        guard case .text(let content) = self else { return nil }
        return content.text
    }

    var data: Data? {
        guard case .blob(let content) = self else { return nil }
        return content.data
    }

    /// Compatibility for existing callers while the result is now strongly typed.
    subscript(key: String) -> JSONValue? {
        switch key {
        case "uri": .string(uri)
        case "mimeType": mimeType.map(JSONValue.string)
        case "text": text.map(JSONValue.string)
        default: nil
        }
    }
}

struct MCPResourceReadResult: Equatable, Sendable {
    var contents: [MCPResourceContent]
    var metadata: JSONValue?
}

struct MCPTextContent: Equatable, Sendable {
    var text: String
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?
}

struct MCPBinaryContent: Equatable, Sendable {
    /// Strictly decoded bytes from the wire-level base64 `data` field.
    var data: Data
    var mimeType: String
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?
}

struct MCPResourceLinkContent: Equatable, Sendable {
    var uri: String
    var name: String
    var title: String?
    var description: String?
    var mimeType: String?
    var size: Int64?
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?
}

struct MCPEmbeddedResourceContent: Equatable, Sendable {
    var resource: MCPResourceContent
    var annotations: MCPContentAnnotations?
    var metadata: JSONValue?
}

enum MCPPromptContentBlock: Equatable, Sendable {
    case text(MCPTextContent)
    case image(MCPBinaryContent)
    case audio(MCPBinaryContent)
    case resourceLink(MCPResourceLinkContent)
    case resource(MCPEmbeddedResourceContent)
    /// Forward-compatible content remains available only after bounded validation.
    case unknown(type: String, value: JSONValue)
}

struct MCPPromptMessage: Equatable, Sendable {
    var role: MCPRole
    var content: MCPPromptContentBlock
}

struct MCPPromptGetResult: Equatable, Sendable {
    var description: String?
    var messages: [MCPPromptMessage]
    var metadata: JSONValue?
}

enum MCPConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

struct MCPLogEntry: Codable, Equatable, Identifiable, Sendable {
    enum Level: String, Codable, Sendable { case info, warning, error }

    var id: UUID = UUID()
    var timestamp: Date = Date()
    var level: Level
    var message: String
}

struct MCPServerSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { configuration.id }
    var configuration: MCPServerConfiguration
    var state: MCPConnectionState
    var negotiatedProtocolVersion: String?
    var serverInfo: MCPImplementationInfo?
    var tools: [MCPToolDescriptor]
    var resources: [MCPResourceDescriptor]
    var resourceTemplates: [MCPResourceTemplateDescriptor] = []
    var prompts: [MCPPromptDescriptor]
    var lastError: String?
    var logs: [MCPLogEntry]? = nil
}
