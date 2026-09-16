import CryptoKit
import Darwin
import Foundation

struct PluginHookBinding: Equatable, Sendable {
    var pluginID: String
    var hookIndex: Int
    var event: LifecycleHookEvent
    var toolName: String
    var failurePolicy: HookFailurePolicy
}

enum PluginRuntimeFactory {
    static func makeTools(plugins: [InstalledPlugin]) -> [any AgentTool] {
        validEnabledPlugins(plugins).flatMap { plugin in
            let regular: [any AgentTool] = plugin.manifest.tools.enumerated().map { index, tool in
                PluginExecutableTool(
                    plugin: plugin,
                    declarationIndex: index,
                    declaration: tool,
                    hook: nil
                )
            }
            let hooks: [any AgentTool] = plugin.manifest.hooks.enumerated().map { index, hook in
                let declaration = PluginToolDeclaration(
                    name: "hook_\(index)",
                    displayName: "\(plugin.manifest.name) · \(hook.event.rawValue)",
                    description: "Host-only lifecycle hook.",
                    executable: hook.executable,
                    fixedArguments: hook.arguments,
                    inputSchema: .objectSchema(properties: [:]),
                    permission: hook.permission,
                    requiresNetwork: hook.requiresNetwork,
                    timeoutSeconds: hook.timeoutSeconds
                )
                return PluginExecutableTool(
                    plugin: plugin,
                    declarationIndex: index,
                    declaration: declaration,
                    hook: hook
                )
            }
            return regular + hooks
        }
    }

    static func hookBindings(plugins: [InstalledPlugin]) -> [PluginHookBinding] {
        validEnabledPlugins(plugins).flatMap { plugin in
            plugin.manifest.hooks.enumerated().map { index, hook in
                PluginHookBinding(
                    pluginID: plugin.id,
                    hookIndex: index,
                    event: hook.event,
                    toolName: PluginExecutableTool.toolName(
                        pluginID: plugin.id,
                        declarationName: "hook_\(index)",
                        isHook: true
                    ),
                    failurePolicy: hook.failurePolicy
                )
            }
        }
    }

    private static func validEnabledPlugins(_ plugins: [InstalledPlugin]) -> [InstalledPlugin] {
        plugins.filter { plugin in
            plugin.enabled
                && Set(plugin.manifest.permissions).isSubset(of: Set(plugin.grantedPermissions))
        }
    }
}

private struct PluginExecutableTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let inputSchema: JSONValue
    let category = AgentToolCategory.plugin
    let permissionLevel: AgentPermissionLevel
    let requiresNetwork: Bool
    let supportsParallelExecution = false

    private let plugin: InstalledPlugin
    private let declarationIndex: Int
    private let declaration: PluginToolDeclaration
    private let hook: PluginHookDeclaration?

    init(
        plugin: InstalledPlugin,
        declarationIndex: Int,
        declaration: PluginToolDeclaration,
        hook: PluginHookDeclaration?
    ) {
        self.plugin = plugin
        self.declarationIndex = declarationIndex
        self.declaration = declaration
        self.hook = hook
        name = Self.toolName(
            pluginID: plugin.id,
            declarationName: declaration.name,
            isHook: hook != nil
        )
        id = "plugin.\(plugin.id).\(hook == nil ? "tool" : "hook").\(declarationIndex)"
        displayName = declaration.displayName ?? "\(plugin.manifest.name) · \(declaration.name)"
        description = declaration.description
        inputSchema = declaration.inputSchema
        permissionLevel = declaration.permission == .read ? .execute : declaration.permission
        requiresNetwork = declaration.requiresNetwork
    }

    func isAvailable(in context: AgentToolContext) -> Bool {
        guard context.executionLocation.kind == .local
                || context.executionLocation.kind == .worktree else {
            // Executable plugins run as local child processes. Remote Tasks
            // must not silently execute them on the Mac while presenting the
            // result as SSH work; a future remote plugin backend can opt in
            // with an explicit execution receipt.
            return false
        }
        guard let hook else { return true }
        guard let invocation = context.lifecycleHookInvocation else { return false }
        return invocation.pluginID == plugin.id
            && invocation.hookIndex == declarationIndex
            && invocation.event == hook.event
            && invocation.sessionID == context.sessionID
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard plugin.enabled,
              Set(plugin.manifest.permissions).isSubset(of: Set(plugin.grantedPermissions)),
              plugin.grantedPermissions.contains(.process),
              !requiresNetwork || plugin.grantedPermissions.contains(.network) else {
            throw ExtensionSubsystemError.permissionNotGranted(plugin.manifest.name)
        }
        let root = URL(fileURLWithPath: plugin.installPath, isDirectory: true)
        let executable = try PluginManager.contained(
            relativePath: declaration.executable,
            root: root
        )
        var metadata = stat()
        guard lstat(executable.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ExtensionSubsystemError.unsafePath(declaration.executable)
        }
        let maximumTimeout = min(
            max(1, context.commandTimeout),
            min(300, max(1, declaration.timeoutSeconds ?? context.commandTimeout))
        )
        let payload: JSONValue
        if let invocation = context.lifecycleHookInvocation {
            payload = .object([
                "event": .string(invocation.event.rawValue),
                "task_id": .string(invocation.sessionID.uuidString.lowercased()),
                "detail": invocation.detail.map(JSONValue.string) ?? .null
            ])
        } else {
            payload = arguments
        }
        let result = try await PluginProcessRunner.run(
            executable: executable,
            arguments: declaration.fixedArguments,
            standardInput: try payload.jsonString(),
            workspace: context.workspace,
            pluginRoot: root,
            temporaryRoot: context.temporaryRoot.appendingPathComponent(
                "plugin-processes",
                isDirectory: true
            ),
            timeout: maximumTimeout,
            allowsWorkspaceRead: plugin.grantedPermissions.contains(.filesystemRead)
                || plugin.grantedPermissions.contains(.filesystemWrite),
            allowsWorkspaceWrite: plugin.grantedPermissions.contains(.filesystemWrite),
            allowsNetwork: requiresNetwork && context.networkAccess,
            environment: [
                "LUMACHAT_PLUGIN_ID": plugin.id,
                "LUMACHAT_TASK_ID": context.sessionID.uuidString.lowercased(),
                "LUMACHAT_HOOK_EVENT": context.lifecycleHookInvocation?.event.rawValue ?? ""
            ]
        )
        return AgentToolResult(
            content: result.output.isEmpty
                ? (result.succeeded ? "Plugin command completed." : "Plugin command failed.")
                : result.output,
            data: .object([
                "exit_code": .number(Double(result.exitCode)),
                "external_side_effect": .bool(true),
                "undoable": .bool(false)
            ]),
            isError: !result.succeeded,
            truncated: result.truncated,
            mayHaveChangedWorkspace: permissionLevel != .read
        )
    }

    static func toolName(
        pluginID: String,
        declarationName: String,
        isHook: Bool
    ) -> String {
        let digest = SHA256.hash(data: Data(pluginID.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        let normalized = declarationName.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return "plugin_\(isHook ? "hook_" : "")\(digest)_\(String(normalized).prefix(48))"
    }
}

private enum PluginProcessRunner {
    struct Result: Sendable {
        var exitCode: Int32
        var output: String
        var truncated: Bool
        var succeeded: Bool { exitCode == 0 }
    }

    static func run(
        executable: URL,
        arguments: [String],
        standardInput: String,
        workspace: AgentWorkspace,
        pluginRoot: URL,
        temporaryRoot: URL,
        timeout: TimeInterval,
        allowsWorkspaceRead: Bool,
        allowsWorkspaceWrite: Bool,
        allowsNetwork: Bool,
        environment: [String: String]
    ) async throws -> Result {
        guard arguments.count <= 64,
              arguments.allSatisfy({ $0.utf8.count <= 8_192 && !$0.contains("\0") }),
              standardInput.utf8.count <= 4 * 1_024 * 1_024 else {
            throw ExtensionSubsystemError.sizeLimit("Plugin process arguments/input 超出限制")
        }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let sandboxBackend: any SandboxBackend = MacOSSandboxBackend()
        let sandbox: any AgentSandboxPolicy
        let workingDirectory: URL
        var isolatedRuntimeRoot: URL?
        if allowsWorkspaceRead {
            sandbox = try sandboxBackend.makeWorkspacePolicy(
                validator: WorkspaceSecurityValidator(workspace: workspace),
                additionalReadOnlyRoots: [pluginRoot]
            )
            workingDirectory = URL(
                fileURLWithPath: workspace.rootPath,
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let parent = AppPaths.extensionScratch.appendingPathComponent(
                "plugin-sandboxes",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let isolated = parent.appendingPathComponent(
                UUID().uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: false)
            isolatedRuntimeRoot = isolated
            sandbox = try sandboxBackend.makeExtensionPolicy(
                trustedExtensionRuntimeRoot: isolated,
                pluginReadOnlyRoot: pluginRoot
            )
            workingDirectory = isolated
        }
        defer {
            try? FileManager.default.removeItem(at: sandbox.runtimeEnvironment.root)
            if let isolatedRuntimeRoot {
                try? FileManager.default.removeItem(at: isolatedRuntimeRoot)
            }
        }
        let outputURL = sandbox.runtimeEnvironment.root.appendingPathComponent(
            "plugin-output.log"
        )
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ExtensionSubsystemError.hookFailed("無法建立 bounded output")
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let input = Pipe()
        let process = Process()
        process.executableURL = sandbox.launcherExecutable
        process.arguments = sandbox.launcherArguments(
            executable: executable,
            arguments: arguments,
            allowsNetwork: allowsNetwork,
            allowsWorkspaceWrite: allowsWorkspaceWrite && allowsWorkspaceRead
        )
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.environment = sandbox.environment(
            session: [:],
            command: [
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8"
            ].merging(environment) { _, pluginValue in pluginValue }
        )
        try process.run()
        // Close the parent's duplicate read end, otherwise a plugin that exits
        // without consuming stdin can leave a large writer blocked forever.
        try? input.fileHandleForReading.close()
        let inputData = Data(standardInput.utf8)
        let inputWriter = Task.detached(priority: .utility) {
            defer { try? input.fileHandleForWriting.close() }
            do {
                try input.fileHandleForWriting.write(contentsOf: inputData)
            } catch {
                // The process may terminate before consuming its bounded input.
                // That closed-pipe condition is reflected by its exit status.
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            var outputMetadata = stat()
            if lstat(outputURL.path, &outputMetadata) == 0,
               outputMetadata.st_size > 1 * 1_024 * 1_024 {
                await terminate(process)
                try? input.fileHandleForWriting.close()
                _ = await inputWriter.result
                throw ExtensionSubsystemError.sizeLimit(
                    "Plugin process output 超過 1 MiB，已終止"
                )
            }
            if Task.isCancelled {
                await terminate(process)
                try? input.fileHandleForWriting.close()
                _ = await inputWriter.result
                throw CancellationError()
            }
            if clock.now >= deadline {
                await terminate(process)
                try? input.fileHandleForWriting.close()
                _ = await inputWriter.result
                throw ToolExecutionError.timeout(tool: executable.lastPathComponent, seconds: timeout)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try? input.fileHandleForWriting.close()
        _ = await inputWriter.result
        try outputHandle.synchronize()
        let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        let maximum = 64 * 1_024
        let truncated = data.count > maximum
        let bounded = data.prefix(maximum)
        return Result(
            exitCode: process.terminationStatus,
            output: String(decoding: bounded, as: UTF8.self),
            truncated: truncated
        )
    }

    private static func terminate(_ process: Process) async {
        let processGroup = -process.processIdentifier
        _ = kill(processGroup, SIGTERM)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            _ = kill(processGroup, SIGKILL)
        }
    }
}
