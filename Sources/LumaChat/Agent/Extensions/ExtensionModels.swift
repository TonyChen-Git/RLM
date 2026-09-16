import Foundation

// MARK: - Skills

enum SkillSourceKind: String, Codable, CaseIterable, Sendable {
    case global
    case project
    case repository
    case nested
    case plugin

    var title: String {
        switch self {
        case .global: "Global"
        case .project: "Project"
        case .repository: "Repository"
        case .nested: "Nested"
        case .plugin: "Plugin"
        }
    }
}

enum ExtensionPermission: String, Codable, CaseIterable, Identifiable, Sendable {
    case filesystemRead = "filesystem_read"
    case filesystemWrite = "filesystem_write"
    case process
    case network
    case mcp
    case browser
    case computerUse = "computer_use"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filesystemRead: "Read files"
        case .filesystemWrite: "Write files"
        case .process: "Run processes"
        case .network: "Network"
        case .mcp: "MCP"
        case .browser: "Browser"
        case .computerUse: "Computer Use"
        }
    }
}

struct SkillDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var usage: String?
    var permissions: [ExtensionPermission]
    var source: SkillSourceKind
    var sourcePath: String
    var pluginID: String?
    var hasReferences: Bool
    var hasScripts: Bool
    var hasTemplates: Bool
    var hasAssets: Bool

    var invocation: String { "$\(name)" }
}

struct ResolvedSkill: Equatable, Sendable {
    var descriptor: SkillDescriptor
    var instructions: String
}

struct LoadedSkillReference: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var source: SkillSourceKind
    var sourcePath: String
    var permissions: [ExtensionPermission]
    var loadedAt: Date

    init(_ skill: ResolvedSkill, loadedAt: Date = Date()) {
        id = skill.descriptor.id
        name = skill.descriptor.name
        source = skill.descriptor.source
        sourcePath = skill.descriptor.sourcePath
        permissions = skill.descriptor.permissions
        self.loadedAt = loadedAt
    }
}

// MARK: - Plugins

enum PluginSource: Codable, Equatable, Sendable {
    case localDirectory(path: String)
    case git(repository: URL, revision: String?)
    case manifest(url: URL)
    case registry(index: URL, pluginID: String)

    var label: String {
        switch self {
        case .localDirectory(let path): "Local · \(path)"
        case .git(let repository, let revision):
            "Git · \(repository.absoluteString)\(revision.map { " @ \($0)" } ?? "")"
        case .manifest(let url): "Manifest · \(url.absoluteString)"
        case .registry(let index, let pluginID): "Registry · \(index.absoluteString) · \(pluginID)"
        }
    }
}

struct PluginSkillDeclaration: Codable, Equatable, Sendable {
    var path: String
}

struct PluginToolDeclaration: Codable, Equatable, Sendable {
    var name: String
    var displayName: String?
    var description: String
    var executable: String
    var fixedArguments: [String]
    var inputSchema: JSONValue
    var permission: AgentPermissionLevel
    var requiresNetwork: Bool
    var timeoutSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case name, displayName, description, executable, fixedArguments
        case inputSchema, permission, requiresNetwork, timeoutSeconds
    }

    init(
        name: String,
        displayName: String? = nil,
        description: String,
        executable: String,
        fixedArguments: [String] = [],
        inputSchema: JSONValue = .objectSchema(properties: [:]),
        permission: AgentPermissionLevel = .execute,
        requiresNetwork: Bool = false,
        timeoutSeconds: Double? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.executable = executable
        self.fixedArguments = fixedArguments
        self.inputSchema = inputSchema
        self.permission = permission
        self.requiresNetwork = requiresNetwork
        self.timeoutSeconds = timeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? "Plugin tool"
        executable = try values.decode(String.self, forKey: .executable)
        fixedArguments = try values.decodeIfPresent([String].self, forKey: .fixedArguments) ?? []
        inputSchema = try values.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
            ?? .objectSchema(properties: [:])
        permission = try values.decodeIfPresent(AgentPermissionLevel.self, forKey: .permission)
            ?? .execute
        requiresNetwork = try values.decodeIfPresent(Bool.self, forKey: .requiresNetwork) ?? false
        timeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
    }
}

enum LifecycleHookEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case preModel = "PreModel"
    case postModel = "PostModel"
    case preTool = "PreTool"
    case postTool = "PostTool"
    case permissionRequest = "PermissionRequest"
    case permissionDecision = "PermissionDecision"
    case preCommit = "PreCommit"
    case postCommit = "PostCommit"
    case subagentStart = "SubagentStart"
    case subagentEnd = "SubagentEnd"
    case taskStart = "TaskStart"
    case taskPause = "TaskPause"
    case taskResume = "TaskResume"
    case taskComplete = "TaskComplete"
    case handoffStart = "HandoffStart"
    case handoffComplete = "HandoffComplete"

    var id: String { rawValue }
}

enum HookFailurePolicy: String, Codable, CaseIterable, Sendable {
    case continueTask = "continue"
    case failTask = "fail_task"
    case disablePlugin = "disable_plugin"
}

struct PluginHookDeclaration: Codable, Equatable, Sendable {
    var event: LifecycleHookEvent
    var executable: String
    var arguments: [String]
    var permission: AgentPermissionLevel
    var requiresNetwork: Bool
    var timeoutSeconds: Double
    var failurePolicy: HookFailurePolicy

    init(
        event: LifecycleHookEvent,
        executable: String,
        arguments: [String] = [],
        permission: AgentPermissionLevel = .execute,
        requiresNetwork: Bool = false,
        timeoutSeconds: Double = 10,
        failurePolicy: HookFailurePolicy = .continueTask
    ) {
        self.event = event
        self.executable = executable
        self.arguments = arguments
        self.permission = permission
        self.requiresNetwork = requiresNetwork
        self.timeoutSeconds = timeoutSeconds
        self.failurePolicy = failurePolicy
    }
}

struct PluginMCPServerDeclaration: Codable, Equatable, Sendable {
    var name: String
    var transport: MCPTransportConfiguration
    var permissionLevel: AgentPermissionLevel?
}

struct PluginCommandDeclaration: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var tool: String?
}

struct PluginManifest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var version: String
    var author: String
    var description: String
    var minimumLumaChatVersion: String?
    var permissions: [ExtensionPermission]
    var skills: [PluginSkillDeclaration]
    var mcpServers: [PluginMCPServerDeclaration]
    var tools: [PluginToolDeclaration]
    var commands: [PluginCommandDeclaration]
    var hooks: [PluginHookDeclaration]
    var assets: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, version, author, description, minimumLumaChatVersion
        case permissions, skills, mcpServers, tools, commands, hooks, assets
    }

    init(
        id: String,
        name: String,
        version: String,
        author: String,
        description: String,
        minimumLumaChatVersion: String? = nil,
        permissions: [ExtensionPermission] = [],
        skills: [PluginSkillDeclaration] = [],
        mcpServers: [PluginMCPServerDeclaration] = [],
        tools: [PluginToolDeclaration] = [],
        commands: [PluginCommandDeclaration] = [],
        hooks: [PluginHookDeclaration] = [],
        assets: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.minimumLumaChatVersion = minimumLumaChatVersion
        self.permissions = permissions
        self.skills = skills
        self.mcpServers = mcpServers
        self.tools = tools
        self.commands = commands
        self.hooks = hooks
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        author = try values.decodeIfPresent(String.self, forKey: .author) ?? "Unknown"
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        minimumLumaChatVersion = try values.decodeIfPresent(
            String.self,
            forKey: .minimumLumaChatVersion
        )
        permissions = try values.decodeIfPresent(
            [ExtensionPermission].self,
            forKey: .permissions
        ) ?? []
        skills = try values.decodeIfPresent([PluginSkillDeclaration].self, forKey: .skills) ?? []
        mcpServers = try values.decodeIfPresent(
            [PluginMCPServerDeclaration].self,
            forKey: .mcpServers
        ) ?? []
        tools = try values.decodeIfPresent([PluginToolDeclaration].self, forKey: .tools) ?? []
        commands = try values.decodeIfPresent(
            [PluginCommandDeclaration].self,
            forKey: .commands
        ) ?? []
        hooks = try values.decodeIfPresent([PluginHookDeclaration].self, forKey: .hooks) ?? []
        assets = try values.decodeIfPresent([String].self, forKey: .assets) ?? []
    }
}

struct InstalledPlugin: Codable, Equatable, Identifiable, Sendable {
    var id: String { manifest.id }
    var manifest: PluginManifest
    var source: PluginSource
    var installPath: String
    var enabled: Bool
    var grantedPermissions: [ExtensionPermission]
    var installedAt: Date
    var updatedAt: Date
    var lastError: String?
}

struct PluginCandidate: Equatable, Sendable {
    var manifest: PluginManifest
    var source: PluginSource
    var stagedPath: String
}

// MARK: - OAuth connectors

enum OAuthConnectorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case slack
    case gmail
    case googleDrive = "google_drive"
    case jira
    case linear
    case notion
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .github: "GitHub"
        case .slack: "Slack"
        case .gmail: "Gmail"
        case .googleDrive: "Google Drive"
        case .jira: "Jira"
        case .linear: "Linear"
        case .notion: "Notion"
        case .custom: "Custom OAuth"
        }
    }
}

struct OAuthConnectorConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: OAuthConnectorKind
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var clientID: String
    var scopes: [String]
    var redirectURI: URL
    var enabled: Bool
    var connectedAt: Date?
    var accountLabel: String?

    init(
        id: UUID = UUID(),
        name: String,
        kind: OAuthConnectorKind,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        clientID: String,
        scopes: [String],
        redirectURI: URL,
        enabled: Bool = true,
        connectedAt: Date? = nil,
        accountLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.enabled = enabled
        self.connectedAt = connectedAt
        self.accountLabel = accountLabel
    }
}

struct OAuthCredential: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenType: String
}

// MARK: - Hook execution

struct LifecycleHookInvocation: Equatable, Sendable {
    var pluginID: String
    var hookIndex: Int
    var event: LifecycleHookEvent
    var sessionID: UUID
    var workspaceRoot: String
    var detail: String?
}

struct LifecycleHookResult: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var pluginID: String
    var event: LifecycleHookEvent
    var startedAt: Date
    var endedAt: Date
    var succeeded: Bool
    var output: String
    var failurePolicy: HookFailurePolicy

    init(
        id: UUID = UUID(),
        pluginID: String,
        event: LifecycleHookEvent,
        startedAt: Date,
        endedAt: Date,
        succeeded: Bool,
        output: String,
        failurePolicy: HookFailurePolicy
    ) {
        self.id = id
        self.pluginID = pluginID
        self.event = event
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.succeeded = succeeded
        self.output = output
        self.failurePolicy = failurePolicy
    }
}

typealias LifecycleHookResultHandler = @Sendable (LifecycleHookResult) async -> Void
typealias PluginHookFailureHandler = @Sendable (
    _ pluginID: String,
    _ policy: HookFailurePolicy,
    _ message: String
) async -> Void

enum ExtensionSubsystemError: LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case unsafePath(String)
    case sizeLimit(String)
    case unsupportedSource(String)
    case pluginNotFound(String)
    case permissionNotGranted(String)
    case hookFailed(String)
    case invalidConnector(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): "Plugin manifest 無效：\(detail)"
        case .unsafePath(let path): "Extension 路徑不安全：\(path)"
        case .sizeLimit(let detail): "Extension 超過安全上限：\(detail)"
        case .unsupportedSource(let detail): "Extension source 尚不支援：\(detail)"
        case .pluginNotFound(let id): "找不到 Plugin：\(id)"
        case .permissionNotGranted(let detail): "Plugin 權限未核准：\(detail)"
        case .hookFailed(let detail): "Lifecycle hook 失敗：\(detail)"
        case .invalidConnector(let detail): "OAuth connector 無效：\(detail)"
        }
    }
}
