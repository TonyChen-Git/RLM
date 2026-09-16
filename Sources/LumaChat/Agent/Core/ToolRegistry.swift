import Foundation

/// Central fail-closed tool boundary for host-locked Review tasks.
///
/// Review tools are deliberately selected by their exact protocol names. All
/// other tools must be local, read-only workspace inspection tools; category
/// alone is not enough because a filesystem/search tool may still use the
/// network or mutate state.
enum ReviewToolIsolationPolicy {
    private static let dedicatedToolNames: Set<String> = [
        "review_source_read",
        "review_pull_request_source_read",
        "review_submit_findings"
    ]

    static let denialReason =
        "Review 工作流程只允許專用 Review 工具與本機唯讀檔案／搜尋工具。"

    static func allows(
        _ tool: any AgentTool,
        in context: AgentToolContext
    ) -> Bool {
        guard context.reviewWorkflow != nil else { return true }
        if dedicatedToolNames.contains(tool.name) { return true }
        guard tool.permissionLevel == .read, !tool.requiresNetwork else {
            return false
        }
        return tool.category == .filesystem || tool.category == .search
    }
}

/// Defense-in-depth for child Agents. Scope is validated when queued, then
/// enforced both while publishing schemas and again immediately before a tool
/// executes so cached/provider-invented calls cannot escape it.
enum SubagentToolIsolationPolicy {
    static let denialReason = "Subagent 工具超出 Parent 授予的唯讀／worktree scope。"

    static func allows(
        _ tool: any AgentTool,
        in context: AgentToolContext
    ) -> Bool {
        guard let scope = context.subagentScope else { return true }
        guard scope.allowedToolNames.contains(tool.name),
              !SubagentToolFactory.names.contains(tool.name),
              scope.networkAccess || !tool.requiresNetwork else { return false }
        if scope.access == .readOnly {
            return tool.permissionLevel == .read
        }
        return true
    }
}

actor ToolRegistry {
    private var toolsByName: [String: any AgentTool] = [:]

    func register(_ tool: any AgentTool) throws {
        let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AgentRuntimeError.invalidArguments("工具名稱不可為空白。")
        }
        guard toolsByName[name] == nil else {
            throw AgentRuntimeError.invalidArguments("工具名稱重複：\(name)")
        }
        toolsByName[name] = tool
    }

    func register(_ tools: [any AgentTool]) throws {
        for tool in tools { try register(tool) }
    }

    /// Atomically replaces one host-owned group of tools. Validation happens
    /// against a copy so a duplicate or invalid replacement cannot leave the
    /// registry with the previous group removed only partially.
    func replace(
        removingNames: Set<String>,
        with replacements: [any AgentTool]
    ) throws {
        var updated = toolsByName
        for name in removingNames { updated.removeValue(forKey: name) }
        for tool in replacements {
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw AgentRuntimeError.invalidArguments("工具名稱不可為空白。")
            }
            guard updated[name] == nil else {
                throw AgentRuntimeError.invalidArguments("工具名稱重複：\(name)")
            }
            updated[name] = tool
        }
        toolsByName = updated
    }

    @discardableResult
    func unregister(named name: String) -> Bool {
        toolsByName.removeValue(forKey: name) != nil
    }

    func unregister(namespace: String) {
        let prefix = namespace.hasSuffix(".") ? namespace : namespace + "."
        toolsByName = toolsByName.filter { !$0.key.hasPrefix(prefix) }
    }

    func tool(named name: String) -> (any AgentTool)? {
        toolsByName[name]
    }

    func definitions(for mode: AppMode) -> [InternalToolDefinition] {
        guard mode.usesAgentRuntime else { return [] }
        return toolsByName.values
            .filter { tool in
                mode == .agent
                    || tool.permissionLevel == .read
                    || tool.category == .todo
            }
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    func definitions(for mode: AppMode, context: AgentToolContext) -> [InternalToolDefinition] {
        guard mode.usesAgentRuntime else { return [] }
        return toolsByName.values
            .filter { tool in
                tool.isAvailable(in: context)
                    && ReviewToolIsolationPolicy.allows(tool, in: context)
                    && SubagentToolIsolationPolicy.allows(tool, in: context)
                    && (mode == .agent
                        || tool.permissionLevel == .read
                        || tool.category == .todo)
            }
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    func metadata(named name: String) -> ToolMetadata? {
        guard let tool = toolsByName[name] else { return nil }
        return ToolMetadata(tool: tool)
    }

    func allMetadata() -> [ToolMetadata] {
        toolsByName.values.map(ToolMetadata.init).sorted { $0.name < $1.name }
    }
}

struct ToolMetadata: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var displayName: String
    var category: AgentToolCategory
    var permissionLevel: AgentPermissionLevel
    var requiresNetwork: Bool
    var supportsParallelExecution: Bool

    init(
        id: String,
        name: String,
        displayName: String,
        category: AgentToolCategory,
        permissionLevel: AgentPermissionLevel,
        requiresNetwork: Bool = false,
        supportsParallelExecution: Bool
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.category = category
        self.permissionLevel = permissionLevel
        self.requiresNetwork = requiresNetwork
        self.supportsParallelExecution = supportsParallelExecution
    }

    init(tool: any AgentTool) {
        id = tool.id
        name = tool.name
        displayName = tool.displayName
        category = tool.category
        permissionLevel = tool.permissionLevel
        requiresNetwork = tool.requiresNetwork
        supportsParallelExecution = tool.supportsParallelExecution
    }
}
