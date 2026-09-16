import Foundation

struct RemoteExecutionBackendResolver: Sendable {
    private let operation: @Sendable (
        UUID,
        AgentRemoteExecutionIdentity?
    ) async throws -> any RemoteExecutionBackend

    init(
        _ operation: @escaping @Sendable (UUID) async throws -> any RemoteExecutionBackend
    ) {
        self.operation = { runnerID, _ in
            try await operation(runnerID)
        }
    }

    private init(
        pinned operation: @escaping @Sendable (
            UUID,
            AgentRemoteExecutionIdentity?
        ) async throws -> any RemoteExecutionBackend
    ) {
        self.operation = operation
    }

    func resolve(
        _ runnerID: UUID,
        matching identity: AgentRemoteExecutionIdentity?
    ) async throws -> any RemoteExecutionBackend {
        try await operation(runnerID, identity)
    }

    static func service(_ service: any RemoteRunnerServicing) -> Self {
        Self(pinned: { runnerID, identity in
            guard let identity else {
                throw RemoteExecutionError.invalidRequest(
                    "Remote tools require the execution identity pinned when the run started."
                )
            }
            return try await service.backend(for: runnerID, matching: identity)
        })
    }
}

private struct RemoteAgentTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let inputSchema: JSONValue
    let category: AgentToolCategory
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork = true
    let supportsParallelExecution: Bool
    let operation: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    func isAvailable(in context: AgentToolContext) -> Bool {
        guard context.executionLocation.kind == .ssh,
              let runnerID = context.remoteRunnerID,
              let identity = context.remoteExecutionIdentity else { return false }
        return identity.runnerID == runnerID
            && identity.workspaceRoot == context.workspace.rootPath
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        try await operation(arguments, context)
    }
}

enum RemoteToolFactory {
    static let names: Set<String> = [
        "remote_file_info", "remote_list_directory", "remote_read_file",
        "remote_write_file", "remote_create_directory", "remote_remove",
        "remote_move", "remote_git_status", "remote_git_diff", "remote_git_log",
        "remote_git_add", "remote_git_commit", "remote_build", "remote_test",
        "remote_run_shell", "remote_pty_run"
    ]

    static func register(
        in registry: ToolRegistry,
        service: any RemoteRunnerServicing
    ) async throws {
        try await registry.register(makeTools(service: service))
    }

    static func makeTools(
        service: any RemoteRunnerServicing
    ) -> [any AgentTool] {
        makeTools(resolver: .service(service))
    }

    static func makeTools(
        resolver: RemoteExecutionBackendResolver
    ) -> [any AgentTool] {
        filesystemTools(resolver: resolver)
            + gitTools(resolver: resolver)
            + validationTools(resolver: resolver)
            + shellTools(resolver: resolver)
    }

    private static func filesystemTools(
        resolver: RemoteExecutionBackendResolver
    ) -> [any AgentTool] {
        [
            tool(
                "remote_file_info", "Remote File Info",
                "Inspect one workspace-relative path on the Task-bound SSH runner without following symbolic links.",
                category: .filesystem, permission: .read, parallel: true,
                properties: ["path": .stringSchema(description: "Workspace-relative path")],
                required: ["path"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["path"])
                let path = try values.requiredString("path")
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(.metadata(path: path))
                guard case .metadata(let metadata) = result.payload else {
                    throw RemoteExecutionError.protocolViolation("Unexpected metadata payload.")
                }
                return AgentToolResult(
                    content: "\(metadata.path): \(metadata.kind.rawValue), \(metadata.byteCount) bytes",
                    data: try payload(metadata: metadata, receipt: result.receipt),
                    truncated: result.receipt.outputTruncated
                )
            },
            tool(
                "remote_list_directory", "Remote List Directory",
                "List one bounded directory on the Task-bound SSH workspace. Symbolic links are identified but never traversed.",
                category: .filesystem, permission: .read, parallel: true,
                properties: [
                    "path": .stringSchema(description: "Workspace-relative path; defaults to ."),
                    "max_entries": .integerSchema(description: "Maximum entries, 1-2000", minimum: 1)
                ]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["path", "max_entries"])
                let path = try values.optionalString("path") ?? "."
                let maximum = try values.integer(
                    "max_entries", default: 500,
                    range: 1...RemoteRunnerLimits.maximumDirectoryEntries
                )
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(
                    .list(path: path, maximumEntries: maximum)
                )
                guard case .listing(let entries) = result.payload else {
                    throw RemoteExecutionError.protocolViolation("Unexpected directory payload.")
                }
                let summary = entries.isEmpty ? "Directory is empty." : entries.map {
                    "\($0.kind == .directory ? "d" : "-") \($0.byteCount) \($0.name)"
                }.joined(separator: "\n")
                return AgentToolResult(
                    content: summary,
                    data: .object([
                        "entries": try encodeJSON(entries),
                        "receipt": try encodeJSON(result.receipt)
                    ]),
                    truncated: result.receipt.outputTruncated
                )
            },
            tool(
                "remote_read_file", "Remote Read File",
                "Read one bounded regular file from the Task-bound SSH workspace. Binary data is not rendered as model text.",
                category: .filesystem, permission: .read, parallel: true,
                properties: [
                    "path": .stringSchema(description: "Workspace-relative file"),
                    "max_bytes": .integerSchema(description: "Maximum bytes, 1-4194304", minimum: 1)
                ],
                required: ["path"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["path", "max_bytes"])
                let path = try values.requiredString("path")
                let maximum = try values.integer(
                    "max_bytes", default: 256 * 1_024,
                    range: 1...RemoteRunnerLimits.maximumFileTransferBytes
                )
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(
                    .read(path: path, maximumBytes: maximum)
                )
                guard case .file(let data, let metadata, let truncated) = result.payload else {
                    throw RemoteExecutionError.protocolViolation("Unexpected file payload.")
                }
                let text: String
                if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") {
                    text = decoded
                } else {
                    text = "[binary content omitted: \(data.count) bytes]"
                }
                return AgentToolResult(
                    content: text,
                    data: try payload(metadata: metadata, receipt: result.receipt),
                    truncated: truncated || result.receipt.outputTruncated
                )
            },
            tool(
                "remote_write_file", "Remote Write File",
                "Atomically create or replace one UTF-8 file on the Task-bound SSH workspace. AppleDouble paths and symbolic-link traversal are refused.",
                category: .filesystem, permission: .write, parallel: false,
                properties: [
                    "path": .stringSchema(description: "Workspace-relative file"),
                    "content": .stringSchema(description: "UTF-8 content, at most 4 MiB"),
                    "create_parents": .booleanSchema(description: "Create missing parent directories")
                ],
                required: ["path", "content"]
            ) { arguments, context in
                let values = try RemoteToolArguments(
                    arguments,
                    keys: ["path", "content", "create_parents"]
                )
                let path = try values.requiredString("path")
                let content = try values.requiredString("content", allowEmpty: true)
                let data = Data(content.utf8)
                guard data.count <= RemoteRunnerLimits.maximumFileTransferBytes else {
                    throw AgentRuntimeError.invalidArguments("content exceeds 4 MiB")
                }
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(.write(
                    path: path,
                    data: data,
                    createParents: try values.boolean("create_parents", default: false)
                ))
                return try mutationResult(result, summary: "Wrote remote file \(path).")
            },
            tool(
                "remote_create_directory", "Remote Create Directory",
                "Create a directory on the Task-bound SSH workspace without following symbolic links.",
                category: .filesystem, permission: .write, parallel: false,
                properties: [
                    "path": .stringSchema(description: "Workspace-relative directory"),
                    "recursive": .booleanSchema(description: "Create missing parents")
                ],
                required: ["path"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["path", "recursive"])
                let path = try values.requiredString("path")
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(.createDirectory(
                    path: path,
                    recursive: try values.boolean("recursive", default: false)
                ))
                return try mutationResult(result, summary: "Created remote directory \(path).")
            },
            tool(
                "remote_remove", "Remote Remove",
                "Remove exactly one regular file or one empty directory on the Task-bound SSH workspace. Recursive deletion and ._* paths are unavailable.",
                category: .filesystem, permission: .dangerous, parallel: false,
                properties: ["path": .stringSchema(description: "Workspace-relative path")],
                required: ["path"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["path"])
                let path = try values.requiredString("path")
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(.remove(path: path))
                return try mutationResult(result, summary: "Removed remote path \(path).")
            },
            tool(
                "remote_move", "Remote Move",
                "Move one file or directory inside the Task-bound SSH workspace without overwriting the destination.",
                category: .filesystem, permission: .write, parallel: false,
                properties: [
                    "source": .stringSchema(description: "Workspace-relative source"),
                    "destination": .stringSchema(description: "Workspace-relative destination")
                ],
                required: ["source", "destination"]
            ) { arguments, context in
                let values = try RemoteToolArguments(
                    arguments,
                    keys: ["source", "destination"]
                )
                let source = try values.requiredString("source")
                let destination = try values.requiredString("destination")
                let backend = try await backend(resolver, context)
                let result = try await backend.executeFilesystem(
                    .move(source: source, destination: destination)
                )
                return try mutationResult(
                    result,
                    summary: "Moved remote path \(source) to \(destination)."
                )
            }
        ]
    }

    private static func gitTools(
        resolver: RemoteExecutionBackendResolver
    ) -> [any AgentTool] {
        [
            tool(
                "remote_git_status", "Remote Git Status",
                "Show bounded Git status for the Task-bound SSH workspace.",
                category: .git, permission: .read, parallel: true
            ) { arguments, context in
                _ = try RemoteToolArguments(arguments, keys: [])
                let resolved = try await backend(resolver, context)
                let result = try await resolved.executeGit(.status)
                return try gitResult(result, mutates: false)
            },
            tool(
                "remote_git_diff", "Remote Git Diff",
                "Show a bounded working-tree or staged diff on the Task-bound SSH workspace.",
                category: .git, permission: .read, parallel: true,
                properties: [
                    "staged": .booleanSchema(description: "Read the staged diff"),
                    "paths": stringArraySchema("Optional workspace-relative paths")
                ]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["staged", "paths"])
                let resolved = try await backend(resolver, context)
                let result = try await resolved.executeGit(.diff(
                    staged: try values.boolean("staged", default: false),
                    paths: try values.stringArray("paths", default: [])
                ))
                return try gitResult(result, mutates: false)
            },
            tool(
                "remote_git_log", "Remote Git Log",
                "Show bounded commit history on the Task-bound SSH workspace.",
                category: .git, permission: .read, parallel: true,
                properties: [
                    "max_count": .integerSchema(description: "Commit count, 1-1000", minimum: 1)
                ]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["max_count"])
                let resolved = try await backend(resolver, context)
                let result = try await resolved.executeGit(.log(maximumCount: try values.integer(
                    "max_count", default: 20, range: 1...1_000
                )))
                return try gitResult(result, mutates: false)
            },
            tool(
                "remote_git_add", "Remote Git Add",
                "Stage exact workspace-relative paths on the Task-bound SSH workspace.",
                category: .git, permission: .write, parallel: false,
                properties: ["paths": stringArraySchema("Paths to stage")],
                required: ["paths"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["paths"])
                let resolved = try await backend(resolver, context)
                let result = try await resolved.executeGit(.add(
                    paths: try values.requiredStringArray("paths")
                ))
                return try gitResult(result, mutates: true)
            },
            tool(
                "remote_git_commit", "Remote Git Commit",
                "Create a commit in the Task-bound SSH workspace. This never pushes.",
                category: .git, permission: .write, parallel: false,
                properties: ["message": .stringSchema(description: "Commit message")],
                required: ["message"]
            ) { arguments, context in
                let values = try RemoteToolArguments(arguments, keys: ["message"])
                let resolved = try await backend(resolver, context)
                let result = try await resolved.executeGit(.commit(
                    message: try values.requiredString("message")
                ))
                return try gitResult(result, mutates: true)
            }
        ]
    }

    private static func validationTools(
        resolver: RemoteExecutionBackendResolver
    ) -> [any AgentTool] {
        [
            validationTool(
                "remote_build", "Remote Build", kind: .build, resolver: resolver
            ),
            validationTool(
                "remote_test", "Remote Test", kind: .test, resolver: resolver
            )
        ]
    }

    private static func shellTools(
        resolver: RemoteExecutionBackendResolver
    ) -> [any AgentTool] {
        [
            shellTool(
                "remote_run_shell", "Remote Run Shell",
                "Run a bounded script through a fixed shell on the Task-bound SSH runner. Host/user/path are shown by the local approval UI.",
                allocatePTY: false,
                resolver: resolver
            ),
            shellTool(
                "remote_pty_run", "Remote PTY Run",
                "Run one bounded command with an SSH-allocated PTY. SSH v1 does not claim persistent reconnect or later stdin support.",
                allocatePTY: true,
                resolver: resolver
            )
        ]
    }

    private static func tool(
        _ name: String,
        _ displayName: String,
        _ description: String,
        category: AgentToolCategory,
        permission: AgentPermissionLevel,
        parallel: Bool,
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        operation: @escaping @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult
    ) -> any AgentTool {
        RemoteAgentTool(
            id: "remote.\(name)",
            name: name,
            displayName: displayName,
            description: description,
            inputSchema: .objectSchema(properties: properties, required: required),
            category: category,
            permissionLevel: permission,
            supportsParallelExecution: parallel,
            operation: operation
        )
    }

    private static func backend(
        _ resolver: RemoteExecutionBackendResolver,
        _ context: AgentToolContext
    ) async throws -> any RemoteExecutionBackend {
        guard context.executionLocation.kind == .ssh,
              let runnerID = context.remoteRunnerID else {
            throw RemoteExecutionError.invalidRequest(
                "Remote tools require a host-bound SSH Task."
            )
        }
        guard let identity = context.remoteExecutionIdentity,
              identity.runnerID == runnerID,
              identity.workspaceRoot == context.workspace.rootPath else {
            throw RemoteExecutionError.invalidRequest(
                "Remote Task identity no longer matches its workspace binding."
            )
        }
        let result = try await resolver.resolve(runnerID, matching: identity)
        guard result.runnerID == runnerID else {
            throw RemoteExecutionError.protocolViolation(
                "Remote resolver returned a different runner."
            )
        }
        return result
    }

    private static func mutationResult(
        _ result: RemoteFilesystemResult,
        summary: String
    ) throws -> AgentToolResult {
        var object: [String: JSONValue] = [
            "receipt": try encodeJSON(result.receipt)
        ]
        if case .mutation(let metadata) = result.payload, let metadata {
            object["metadata"] = try encodeJSON(metadata)
        }
        return AgentToolResult(
            content: summary,
            data: .object(object),
            truncated: result.receipt.outputTruncated,
            mayHaveChangedWorkspace: true
        )
    }

    private static func payload(
        metadata: RemoteFileMetadata,
        receipt: RemoteOperationReceipt
    ) throws -> JSONValue {
        .object([
            "metadata": try encodeJSON(metadata),
            "receipt": try encodeJSON(receipt)
        ])
    }

    private static func validationTool(
        _ name: String,
        _ displayName: String,
        kind: RemoteValidationKind,
        resolver: RemoteExecutionBackendResolver
    ) -> any AgentTool {
        tool(
            name, displayName,
            "Run a bounded \(kind.rawValue) on the Task-bound SSH workspace.",
            category: .terminal, permission: .execute, parallel: false,
            properties: [
                "toolchain": enumSchema(["swift_package", "xcode"]),
                "scheme": .stringSchema(description: "Required for the xcode toolchain"),
                "configuration": enumSchema(RemoteBuildConfiguration.allCases.map(\.rawValue)),
                "timeout_seconds": .integerSchema(description: "Timeout, 1-3600", minimum: 1)
            ]
        ) { arguments, context in
            let values = try RemoteToolArguments(
                arguments,
                keys: ["toolchain", "scheme", "configuration", "timeout_seconds"]
            )
            let toolchain: RemoteProjectToolchain
            switch try values.optionalString("toolchain") ?? "swift_package" {
            case "swift_package": toolchain = .swiftPackage
            case "xcode": toolchain = .xcode(scheme: try values.requiredString("scheme"))
            default: throw AgentRuntimeError.invalidArguments("unsupported toolchain")
            }
            let configuration = RemoteBuildConfiguration(
                rawValue: try values.optionalString("configuration") ?? "debug"
            )
            guard let configuration else {
                throw AgentRuntimeError.invalidArguments("unsupported configuration")
            }
            let timeout = try values.optionalInteger("timeout_seconds", range: 1...3_600)
                .map { TimeInterval($0) }
            let request = RemoteValidationRequest(
                kind: kind,
                toolchain: toolchain,
                configuration: configuration,
                timeout: timeout
            )
            let resolved = try await backend(resolver, context)
            let result: RemoteValidationResult
            switch kind {
            case .build:
                result = try await resolved.executeBuild(request)
            case .test:
                result = try await resolved.executeTest(request)
            }
            return AgentToolResult(
                content: commandOutput(result.stdout, result.stderr, result.receipt.exitCode),
                data: try encodeJSON(result),
                isError: result.receipt.exitCode != 0,
                truncated: result.receipt.outputTruncated,
                mayHaveChangedWorkspace: true
            )
        }
    }

    private static func shellTool(
        _ name: String,
        _ displayName: String,
        _ description: String,
        allocatePTY: Bool,
        resolver: RemoteExecutionBackendResolver
    ) -> any AgentTool {
        tool(
            name, displayName, description,
            category: .terminal, permission: .dangerous, parallel: false,
            properties: [
                "script": .stringSchema(description: "Shell script, at most 512 KiB"),
                "shell": enumSchema(RemoteShell.allCases.map(\.rawValue)),
                "environment": stringMapSchema("Bounded environment additions"),
                "timeout_seconds": .integerSchema(description: "Timeout, 1-3600", minimum: 1)
            ],
            required: ["script"]
        ) { arguments, context in
            let values = try RemoteToolArguments(
                arguments,
                keys: ["script", "shell", "environment", "timeout_seconds"]
            )
            let script = try values.requiredString("script")
            guard script.utf8.count <= RemoteRunnerLimits.maximumShellScriptBytes else {
                throw AgentRuntimeError.invalidArguments("script exceeds 512 KiB")
            }
            let shell = RemoteShell(rawValue: try values.optionalString("shell") ?? "/bin/sh")
            guard let shell else { throw AgentRuntimeError.invalidArguments("unsupported shell") }
            let timeout = try values.optionalInteger("timeout_seconds", range: 1...3_600)
                .map { TimeInterval($0) }
            let resolved = try await backend(resolver, context)
            let result = try await resolved.executeShell(RemoteShellRequest(
                script: script,
                shell: shell,
                environment: try values.stringMap("environment"),
                timeout: timeout,
                allocatePTY: allocatePTY
            ))
            return AgentToolResult(
                content: commandOutput(result.stdout, result.stderr, result.receipt.exitCode),
                data: try encodeJSON(result),
                isError: result.receipt.exitCode != 0,
                truncated: result.receipt.outputTruncated,
                mayHaveChangedWorkspace: true
            )
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    private static func commandOutput(
        _ stdout: String,
        _ stderr: String,
        _ exitCode: Int32
    ) -> String {
        let output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        return output.isEmpty ? "Remote command exited with code \(exitCode)." : output
    }

    private static func gitResult(
        _ result: RemoteGitResult,
        mutates: Bool
    ) throws -> AgentToolResult {
        AgentToolResult(
            content: commandOutput(result.stdout, result.stderr, result.receipt.exitCode),
            data: try encodeJSON(result),
            isError: result.receipt.exitCode != 0,
            truncated: result.receipt.outputTruncated,
            mayHaveChangedWorkspace: mutates
        )
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
            "description": .string(description),
            "items": .stringSchema()
        ])
    }

    private static func stringMapSchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .object(["type": .string("string")])
        ])
    }
}

private struct RemoteToolArguments: Sendable {
    private let object: [String: JSONValue]

    init(_ value: JSONValue, keys: Set<String>) throws {
        guard let object = value.objectValue else {
            throw AgentRuntimeError.invalidArguments("expected a JSON object")
        }
        let unknown = Set(object.keys).subtracting(keys)
        guard unknown.isEmpty else {
            throw AgentRuntimeError.invalidArguments(
                "unsupported argument field(s): \(unknown.sorted().joined(separator: ", "))"
            )
        }
        self.object = object
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard case .string(let result) = value, !result.contains("\0") else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a string without NUL")
        }
        return result
    }

    func requiredString(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = try optionalString(key), allowEmpty || !value.isEmpty else {
            throw AgentRuntimeError.invalidArguments("\(key) is required")
        }
        return value
    }

    func integer(
        _ key: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value = object[key] else { return defaultValue }
        guard let integer = value.intValue, range.contains(integer) else {
            throw AgentRuntimeError.invalidArguments(
                "\(key) must be in \(range.lowerBound)...\(range.upperBound)"
            )
        }
        return integer
    }

    func optionalInteger(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard object[key] != nil else { return nil }
        return try integer(key, default: range.lowerBound, range: range)
    }

    func boolean(_ key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = object[key] else { return defaultValue }
        guard case .bool(let result) = value else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a boolean")
        }
        return result
    }

    func stringArray(_ key: String, default defaultValue: [String]) throws -> [String] {
        guard let value = object[key] else { return defaultValue }
        guard case .array(let items) = value,
              items.count <= RemoteRunnerLimits.maximumArguments else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a bounded string array")
        }
        return try items.map { item in
            guard case .string(let string) = item, !string.contains("\0"),
                  string.utf8.count <= RemoteRunnerLimits.maximumArgumentBytes else {
                throw AgentRuntimeError.invalidArguments("\(key) contains an invalid string")
            }
            return string
        }
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        let result = try stringArray(key, default: [])
        guard !result.isEmpty else {
            throw AgentRuntimeError.invalidArguments("\(key) requires at least one path")
        }
        return result
    }

    func stringMap(_ key: String) throws -> [String: String] {
        guard let value = object[key] else { return [:] }
        guard case .object(let entries) = value,
              entries.count <= RemoteRunnerLimits.maximumEnvironmentEntries else {
            throw AgentRuntimeError.invalidArguments("\(key) must be a bounded string map")
        }
        var result: [String: String] = [:]
        for (name, rawValue) in entries {
            guard case .string(let string) = rawValue else {
                throw AgentRuntimeError.invalidArguments("\(key) values must be strings")
            }
            result[name] = string
        }
        return result
    }
}
