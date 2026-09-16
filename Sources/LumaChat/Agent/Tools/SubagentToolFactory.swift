import Foundation

private struct SubagentAgentTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let inputSchema: JSONValue
    let category: AgentToolCategory = .system
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork = false
    let supportsParallelExecution: Bool
    let operation: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    func isAvailable(in context: AgentToolContext) -> Bool {
        context.subagentController != nil
            && context.subagentAuthority != nil
            && (context.executionLocation.kind == .local
                || context.executionLocation.kind == .worktree)
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        try await operation(arguments, context)
    }
}

enum SubagentToolFactory {
    static let names: Set<String> = [
        "spawn_subagent", "send_subagent_message", "wait_subagent",
        "list_subagents", "cancel_subagent", "resume_subagent",
        "collect_subagent_result"
    ]

    static func makeTools() -> [any AgentTool] {
        [
            tool(
                "spawn_subagent",
                "Spawn Subagent",
                "Queue one bounded child Agent with an explicit read-only or dedicated-worktree scope. Returns immediately with a durable child ID.",
                permission: .dangerous,
                properties: [
                    "goal": .stringSchema(description: "Concrete child objective"),
                    "context": .stringSchema(description: "Optional bounded parent context"),
                    "access": enumSchema(["read_only", "writable_worktree"]),
                    "relative_path": .stringSchema(description: "Workspace-relative directory; writable worktrees require ."),
                    "tool_names": stringArraySchema("Exact child tool allow-list"),
                    "mcp_server_ids": stringArraySchema("Exact MCP UUID allow-list"),
                    "network_access": .booleanSchema(description: "May only narrow the parent capability"),
                    "max_steps": .integerSchema(description: "1...100", minimum: 1),
                    "context_tokens": .integerSchema(description: "2048...262144", minimum: 2_048),
                    "total_tokens": .integerSchema(description: "1024...2000000", minimum: 1_024),
                    "timeout_seconds": .integerSchema(description: "10...3600", minimum: 10),
                    "priority": enumSchema(["low", "normal", "high"])
                ],
                required: ["goal"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys([
                    "goal", "context", "access", "relative_path", "tool_names",
                    "mcp_server_ids", "network_access", "max_steps",
                    "context_tokens", "total_tokens", "timeout_seconds", "priority"
                ])
                let (controller, authority) = try orchestrationContext(context)
                let access = try SubagentAccessMode(
                    validatedRawValue: values.string("access") ?? SubagentAccessMode.readOnly.rawValue,
                    label: "access"
                )
                let priority = try SubagentPriority(
                    validatedName: values.string("priority") ?? "normal"
                )
                let mcpIDs = try values.strings("mcp_server_ids").map { raw -> UUID in
                    guard let id = UUID(uuidString: raw) else {
                        throw AgentRuntimeError.invalidArguments("mcp_server_ids must contain UUID strings")
                    }
                    return id
                }
                let request = SubagentSpawnRequest(
                    goal: try values.requiredString("goal"),
                    context: values.string("context"),
                    scope: SubagentScope(
                        access: access,
                        relativePath: values.string("relative_path") ?? ".",
                        allowedToolNames: try values.strings("tool_names"),
                        allowedMCPServerIDs: mcpIDs,
                        networkAccess: try values.boolean("network_access", default: false)
                    ),
                    budget: SubagentBudget(
                        maximumSteps: try values.integer(
                            "max_steps", default: SubagentBudget.defaultMaximumSteps
                        ),
                        contextTokens: try values.integer(
                            "context_tokens", default: SubagentBudget.defaultContextTokens
                        ),
                        totalTokens: try values.integer(
                            "total_tokens", default: SubagentBudget.defaultTotalTokens
                        ),
                        timeoutSeconds: try values.integer(
                            "timeout_seconds", default: SubagentBudget.defaultTimeoutSeconds
                        )
                    ),
                    priority: priority
                )
                let record = try await controller.spawnSubagent(request, authority: authority)
                return try result(
                    record,
                    "Subagent \(record.id.uuidString.lowercased()) is \(record.status.rawValue)."
                )
            },
            tool(
                "send_subagent_message",
                "Message Subagent",
                "Append bounded context to a queued or running child. The child consumes it at its next model boundary.",
                permission: .write,
                properties: [
                    "subagent_id": .stringSchema(),
                    "message": .stringSchema()
                ],
                required: ["subagent_id", "message"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys(["subagent_id", "message"])
                let (controller, authority) = try orchestrationContext(context)
                let record = try await controller.sendSubagentMessage(
                    id: try values.uuid("subagent_id"),
                    parentSessionID: authority.parentSessionID,
                    message: try values.requiredString("message")
                )
                return try result(record, "Message queued for Subagent \(record.id.uuidString.lowercased()).")
            },
            tool(
                "wait_subagent",
                "Wait for Subagent",
                "Wait for one child to reach a terminal/interrupted state without blocking unrelated children.",
                permission: .read,
                parallel: true,
                properties: [
                    "subagent_id": .stringSchema(),
                    "timeout_seconds": .integerSchema(description: "1...300", minimum: 1)
                ],
                required: ["subagent_id"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys(["subagent_id", "timeout_seconds"])
                let (controller, authority) = try orchestrationContext(context)
                let record = try await controller.waitForSubagent(
                    id: try values.uuid("subagent_id"),
                    parentSessionID: authority.parentSessionID,
                    timeoutSeconds: try values.integer("timeout_seconds", default: 60)
                )
                return try result(record, "Subagent \(record.id.uuidString.lowercased()) is \(record.status.rawValue).")
            },
            tool(
                "list_subagents",
                "List Subagents",
                "List durable child status, budgets, scopes, and result availability for this parent Task.",
                permission: .read,
                parallel: true
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys([])
                let (controller, authority) = try orchestrationContext(context)
                let records = await controller.listSubagents(
                    parentSessionID: authority.parentSessionID
                )
                return try result(
                    records,
                    records.isEmpty
                        ? "No Subagents."
                        : records.map {
                            "\($0.id.uuidString.lowercased()) [\($0.status.rawValue)] \($0.goal)"
                        }.joined(separator: "\n")
                )
            },
            tool(
                "cancel_subagent",
                "Cancel Subagent",
                "Cancel one queued/running child without affecting its siblings.",
                permission: .dangerous,
                properties: ["subagent_id": .stringSchema()],
                required: ["subagent_id"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys(["subagent_id"])
                let (controller, authority) = try orchestrationContext(context)
                let record = try await controller.cancelSubagent(
                    id: try values.uuid("subagent_id"),
                    parentSessionID: authority.parentSessionID
                )
                return try result(record, "Cancelled Subagent \(record.id.uuidString.lowercased()).")
            },
            tool(
                "resume_subagent",
                "Resume Subagent",
                "Requeue an interrupted, paused, failed, cancelled, or timed-out child with the same scope.",
                permission: .write,
                properties: ["subagent_id": .stringSchema()],
                required: ["subagent_id"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys(["subagent_id"])
                let (controller, authority) = try orchestrationContext(context)
                let record = try await controller.resumeSubagent(
                    id: try values.uuid("subagent_id"),
                    parentSessionID: authority.parentSessionID
                )
                return try result(record, "Requeued Subagent \(record.id.uuidString.lowercased()).")
            },
            tool(
                "collect_subagent_result",
                "Collect Subagent Result",
                "Collect the child's validated structured result. Collection clears the parent's outstanding-result obligation.",
                permission: .read,
                properties: ["subagent_id": .stringSchema()],
                required: ["subagent_id"]
            ) { arguments, context in
                let values = try SubagentArguments(arguments)
                try values.requireOnlyKeys(["subagent_id"])
                let (controller, authority) = try orchestrationContext(context)
                let collected = try await controller.collectSubagentResult(
                    id: try values.uuid("subagent_id"),
                    parentSessionID: authority.parentSessionID
                )
                return try result(collected, collected.summary)
            }
        ]
    }

    private static func tool(
        _ name: String,
        _ displayName: String,
        _ description: String,
        permission: AgentPermissionLevel,
        parallel: Bool = false,
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        operation: @escaping @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult
    ) -> any AgentTool {
        SubagentAgentTool(
            id: "builtin.\(name)",
            name: name,
            displayName: displayName,
            description: description,
            inputSchema: .objectSchema(properties: properties, required: required),
            permissionLevel: permission,
            supportsParallelExecution: parallel,
            operation: operation
        )
    }

    private static func orchestrationContext(
        _ context: AgentToolContext
    ) throws -> (any SubagentControlling, SubagentAuthority) {
        guard let controller = context.subagentController,
              let authority = context.subagentAuthority else {
            throw SubagentError.unavailable
        }
        return (controller, authority)
    }

    private static func result<T: Encodable>(
        _ value: T,
        _ summary: String
    ) throws -> AgentToolResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
        return AgentToolResult(content: summary, data: data)
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func stringArraySchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .stringSchema(),
            "description": .string(description)
        ])
    }
}

private struct SubagentArguments: Sendable {
    let values: [String: JSONValue]

    init(_ raw: JSONValue) throws {
        guard let values = raw.objectValue else {
            throw AgentRuntimeError.invalidArguments("expected a JSON object")
        }
        self.values = values
    }

    func requireOnlyKeys(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw AgentRuntimeError.invalidArguments(
                "unsupported argument field(s): \(unknown.joined(separator: ", "))"
            )
        }
    }

    func string(_ key: String) -> String? { values[key]?.stringValue }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a non-empty string")
        }
        return value
    }

    func strings(_ key: String) throws -> [String] {
        guard let raw = values[key] else { return [] }
        guard let array = raw.arrayValue,
              array.count <= 64,
              array.allSatisfy({ $0.stringValue != nil }) else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a string array with at most 64 entries")
        }
        return array.compactMap(\.stringValue)
    }

    func integer(_ key: String, default defaultValue: Int) throws -> Int {
        guard let raw = values[key] else { return defaultValue }
        guard let value = raw.intValue else {
            throw AgentRuntimeError.invalidArguments("\(key) must be an integer")
        }
        return value
    }

    func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw = values[key] else { return defaultValue }
        guard let value = raw.boolValue else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a boolean")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let raw = string(key), let id = UUID(uuidString: raw) else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a UUID")
        }
        return id
    }
}

private extension SubagentAccessMode {
    init(validatedRawValue rawValue: String, label: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw AgentRuntimeError.invalidArguments("\(label) has an unsupported value")
        }
        self = value
    }
}

private extension SubagentPriority {
    init(validatedName name: String) throws {
        switch name {
        case "low": self = .low
        case "normal": self = .normal
        case "high": self = .high
        default: throw AgentRuntimeError.invalidArguments("priority has an unsupported value")
        }
    }
}
