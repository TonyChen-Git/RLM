import Foundation

enum ToolExecutionError: LocalizedError, Sendable, Equatable {
    case timeout(tool: String, seconds: TimeInterval)
    case invalidArguments(tool: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .timeout(let tool, let seconds):
            "工具「\(tool)」執行超過 \(Int(seconds)) 秒，已取消。"
        case .invalidArguments(let tool, let reason):
            "工具「\(tool)」的輸入被安全限制拒絕：\(reason)"
        }
    }
}

actor ToolExecutor {
    private let registry: ToolRegistry
    private let permissionManager: PermissionManager
    private let redactor: SecretRedactor
    private let logger: AgentLogger
    private let maximumResultCharacters: Int

    init(
        registry: ToolRegistry,
        permissionManager: PermissionManager = PermissionManager(),
        redactor: SecretRedactor = SecretRedactor(),
        logger: AgentLogger = .shared,
        maximumResultCharacters: Int = 24_000
    ) {
        self.registry = registry
        self.permissionManager = permissionManager
        self.redactor = redactor
        self.logger = logger
        self.maximumResultCharacters = max(1_024, maximumResultCharacters)
    }

    func execute(
        _ call: AgentToolCall,
        context baseContext: AgentToolContext,
        permissionMode: AgentPermissionMode,
        networkAccess: Bool,
        approvalHandler: AgentApprovalHandler?
    ) async throws -> AgentToolResult {
        guard let tool = await registry.tool(named: call.name) else {
            try? await logger.record(
                sessionID: baseContext.sessionID,
                kind: .error,
                name: call.name,
                succeeded: false,
                detail: "unknown tool"
            )
            throw AgentRuntimeError.unknownTool(call.name)
        }
        guard ReviewToolIsolationPolicy.allows(tool, in: baseContext) else {
            try? await logger.record(
                sessionID: baseContext.sessionID,
                kind: .tool,
                name: call.name,
                succeeded: false,
                detail: ReviewToolIsolationPolicy.denialReason
            )
            return AgentToolResult(
                content: ReviewToolIsolationPolicy.denialReason,
                isError: true
            )
        }
        guard SubagentToolIsolationPolicy.allows(tool, in: baseContext) else {
            try? await logger.record(
                sessionID: baseContext.sessionID,
                kind: .tool,
                name: call.name,
                succeeded: false,
                detail: SubagentToolIsolationPolicy.denialReason
            )
            return AgentToolResult(
                content: SubagentToolIsolationPolicy.denialReason,
                isError: true
            )
        }
        guard tool.isAvailable(in: baseContext) else {
            return AgentToolResult(
                content: "工具不屬於這個 Project，或已被 Project Settings 停用。",
                isError: true
            )
        }
        try Self.validateArguments(call.arguments, tool: tool.displayName)
        let metadata = ToolMetadata(tool: tool)
        var context = baseContext
        context.toolCallID = call.id
        context.reason = call.arguments["reason"]?.stringValue
        // A tool must size model-visible output against the executor's actual
        // presentation ceiling. Callers normally keep these values aligned,
        // but clamping here prevents a stale or third-party context from
        // causing the executor to remove a pagination footer after execution.
        context.maximumToolResultCharacters = min(
            context.maximumToolResultCharacters,
            maximumResultCharacters
        )
        // Authorization remains centralized here. The tool only receives the
        // already-approved global network capability after this executor has
        // evaluated the call and, when needed, obtained user approval.
        context.networkAccess = networkAccess
        if let downstream = baseContext.progressHandler {
            let redactor = redactor
            let workspace = baseContext.workspace
            context.progressHandler = { update in
                // Third-party AgentTool implementations share this optional
                // callback. Bound hostile input before regex redaction, then
                // re-bound the sanitized text to the public per-event limit.
                let rawBounded = Self.boundedProgressDelta(
                    update.delta,
                    maximumBytes: TerminalSession.maximumLiveOutputDeltaBytes * 2
                )
                let scrubbed = redactor.redact(
                    Self.scrubHostWorkspacePaths(rawBounded.value, workspace: workspace)
                )
                let bounded = Self.boundedProgressDelta(scrubbed)
                await downstream(
                    AgentToolProgress(
                        stream: update.stream,
                        delta: bounded.value,
                        totalBytes: max(0, min(update.totalBytes, 32 * 1_024 * 1_024)),
                        truncated: update.truncated || rawBounded.truncated || bounded.truncated
                    )
                )
            }
        }

        let authorization = await permissionManager.authorize(
            metadata: metadata,
            call: call,
            context: context,
            permissionMode: permissionMode,
            networkAccess: networkAccess
        )
        switch authorization {
        case .allow:
            break
        case .deny(let reason):
            try? await logger.record(
                sessionID: context.sessionID,
                kind: .tool,
                name: metadata.name,
                succeeded: false,
                detail: reason
            )
            return AgentToolResult(content: reason, isError: true)
        case .requireApproval(let level, let reasons):
            guard let approvalHandler else {
                try? await logger.record(
                    sessionID: context.sessionID,
                    kind: .tool,
                    name: metadata.name,
                    succeeded: false,
                    detail: "approval handler unavailable"
                )
                return AgentToolResult(content: "工具未獲得使用者核准。", isError: true)
            }
            let request = AgentApprovalRequest(
                sessionID: context.sessionID,
                toolName: metadata.name,
                displayName: metadata.displayName,
                permissionLevel: level,
                arguments: redactor.redact(call.arguments),
                reason: context.reason.map(redactor.redact),
                command: call.arguments["command"]?.stringValue.map(redactor.redact),
                workingDirectory: call.arguments["cwd"]?.stringValue ?? ".",
                riskReasons: reasons,
                diffPreview: Self.approvalDiffPreview(call: call, context: context)
                    .map(redactor.redact),
                executionBackend: context.remoteExecutionIdentity?.backendLabel,
                remoteHost: context.remoteExecutionIdentity?.host,
                remotePort: context.remoteExecutionIdentity?.port,
                remoteUser: context.remoteExecutionIdentity?.user,
                remoteWorkspaceRoot: context.remoteExecutionIdentity?.workspaceRoot
            )
            let decision = await approvalHandler(request)
            switch decision {
            case .deny:
                try? await logger.record(
                    sessionID: context.sessionID,
                    kind: .tool,
                    name: metadata.name,
                    succeeded: false,
                    detail: "user denied approval"
                )
                return AgentToolResult(content: "使用者拒絕了「\(metadata.displayName)」。", isError: true)
            case .allowForSession:
                await permissionManager.allowForSession(
                    metadata: metadata,
                    context: context,
                    effectiveLevel: level,
                    call: call
                )
            case .allowOnce:
                break
            }
        }

        // `networkAccess` controls automatic authority. Reaching this point
        // also means an otherwise-disabled network action was explicitly
        // approved (or covered by its exact session allowance), so the tool's
        // sandbox may enable network for this invocation only.
        if metadata.requiresNetwork {
            context.networkAccess = true
        }

        let startedAt = ContinuousClock.now
        do {
            var result = try await executeWithTimeout(
                tool,
                arguments: call.arguments,
                context: context,
                timeout: context.commandTimeout
            )
            result.duration = startedAt.duration(to: .now).timeInterval
            // Tool stdout and third-party errors can contain an absolute local
            // checkout path even though every model-facing tool argument uses
            // workspace-relative paths. Never disclose that host path to a
            // remote Ollama/OpenAI/Anthropic server.
            result.content = redactor.redact(
                Self.scrubHostWorkspacePaths(result.content, workspace: context.workspace)
            )
            if let data = result.data { result.data = redactor.redact(data) }
            if var change = result.change {
                change.relativePath = redactor.redact(change.relativePath)
                if let destination = change.destinationRelativePath {
                    change.destinationRelativePath = redactor.redact(destination)
                }
                change.unifiedDiff = redactor.redact(change.unifiedDiff)
                result.change = change
            }
            try? await logger.record(
                sessionID: context.sessionID,
                kind: .tool,
                name: metadata.name,
                succeeded: !result.isError,
                duration: result.duration
            )
            return try limit(result, toolName: metadata.name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let duration = startedAt.duration(to: .now).timeInterval
            try? await logger.record(
                sessionID: context.sessionID,
                kind: .tool,
                name: metadata.name,
                succeeded: false,
                duration: duration,
                detail: error.localizedDescription
            )
            return AgentToolResult(
                content: redactor.redact(
                    Self.scrubHostWorkspacePaths(
                        error.localizedDescription,
                        workspace: context.workspace
                    )
                ),
                isError: true,
                duration: duration
            )
        }
    }

    func metadata(named name: String) async -> ToolMetadata? {
        await registry.metadata(named: name)
    }

    func clearPermissions(for sessionID: UUID) async {
        await permissionManager.clearSession(sessionID)
    }

    func clearAllPermissions() async {
        await permissionManager.clearAll()
    }

    func restorePermissionAllowances(
        _ allowances: [AgentPermissionAllowance],
        for sessionID: UUID,
        workspace: AgentWorkspace
    ) async {
        await permissionManager.restorePersistedAllowances(
            allowances,
            for: sessionID,
            workspace: workspace
        )
    }

    func permissionAllowances(for sessionID: UUID) async -> [AgentPermissionAllowance] {
        await permissionManager.persistedAllowances(for: sessionID)
    }

    private func executeWithTimeout(
        _ tool: any AgentTool,
        arguments: JSONValue,
        context: AgentToolContext,
        timeout: TimeInterval
    ) async throws -> AgentToolResult {
        let seconds = max(1, timeout)
        return try await withThrowingTaskGroup(of: AgentToolResult.self) { group in
            group.addTask {
                try await tool.execute(arguments: arguments, context: context)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ToolExecutionError.timeout(tool: tool.displayName, seconds: seconds)
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    /// Provider and MCP payload limits bound the wire response, but a tool
    /// argument is subsequently copied by redaction, approval, parsing and
    /// persistence. Reject oversized or pathological JSON before any of those
    /// stages, permission prompts, or tool-side allocations occur.
    private static func validateArguments(_ value: JSONValue, tool: String) throws {
        let maximumBytes = 4 * 1_024 * 1_024
        let maximumDepth = 64
        let maximumNodes = 50_000
        var bytes = 0
        var nodes = 0

        func add(_ count: Int) throws {
            guard count >= 0, count <= maximumBytes - bytes else {
                throw ToolExecutionError.invalidArguments(
                    tool: tool,
                    reason: "JSON 參數超過 4 MiB。"
                )
            }
            bytes += count
        }

        func walk(_ item: JSONValue, depth: Int) throws {
            guard depth <= maximumDepth else {
                throw ToolExecutionError.invalidArguments(
                    tool: tool,
                    reason: "JSON 巢狀深度超過 \(maximumDepth) 層。"
                )
            }
            nodes += 1
            guard nodes <= maximumNodes else {
                throw ToolExecutionError.invalidArguments(
                    tool: tool,
                    reason: "JSON 節點超過 \(maximumNodes) 個。"
                )
            }
            switch item {
            case .object(let object):
                try add(2)
                for (key, nested) in object {
                    try add(key.utf8.count + 4)
                    try walk(nested, depth: depth + 1)
                }
            case .array(let array):
                try add(2)
                for nested in array {
                    try add(1)
                    try walk(nested, depth: depth + 1)
                }
            case .string(let string):
                try add(string.utf8.count + 2)
            case .number:
                try add(32)
            case .bool:
                try add(5)
            case .null:
                try add(4)
            }
        }

        try walk(value, depth: 0)
    }

    private static func approvalDiffPreview(
        call: AgentToolCall,
        context: AgentToolContext
    ) -> String? {
        if call.name == "apply_patch" { return call.arguments["patch"]?.stringValue }
        if call.name == "move_file" || call.name == "copy_file" {
            guard let source = call.arguments["source"]?.stringValue,
                  let destination = call.arguments["destination"]?.stringValue else { return nil }
            return "\(call.name == "move_file" ? "Move" : "Copy") \(source) → \(destination)"
        }
        if call.name == "create_directory", let path = call.arguments["path"]?.stringValue {
            return "Create directory: \(path)"
        }
        guard ["create_file", "write_file", "edit_file", "delete_file"].contains(call.name),
              let path = call.arguments["path"]?.stringValue,
              let validator = try? WorkspaceSecurityValidator(workspace: context.workspace),
              let secureIO = try? SecureWorkspaceIO(validator: validator),
              let snapshot = try? secureIO.snapshot(path: path, maximumBytes: 2 * 1_024 * 1_024)
        else { return nil }

        let oldFiles = snapshot.entries.reduce(into: [String: Data]()) { files, entry in
            if case .file(let data) = entry.kind { files[entry.relativePath] = data }
        }
        let builder = UnifiedDiffBuilder()
        if call.name == "delete_file" {
            let previews = oldFiles.keys.sorted().prefix(24).map { relativePath in
                let displayPath = relativePath.isEmpty ? path : "\(path)/\(relativePath)"
                return builder.make(path: displayPath, old: oldFiles[relativePath], new: nil)
            }
            return boundedPreview(previews.joined(separator: "\n"))
        }

        guard let content = proposedContent(call: call, oldFiles: oldFiles),
              let old = oldFiles[""] else {
            if call.name == "create_file", let content = call.arguments["content"]?.stringValue {
                return boundedPreview(builder.make(path: path, old: nil, new: Data(content.utf8)))
            }
            return nil
        }
        return boundedPreview(builder.make(path: path, old: old, new: Data(content.utf8)))
    }

    private static func proposedContent(
        call: AgentToolCall,
        oldFiles: [String: Data]
    ) -> String? {
        if call.name == "write_file" || call.name == "create_file" {
            return call.arguments["content"]?.stringValue
        }
        guard call.name == "edit_file",
              let oldData = oldFiles[""],
              let source = String(data: oldData, encoding: .utf8),
              let replacement = call.arguments["replacement"]?.stringValue else { return nil }
        if let oldText = call.arguments["old_text"]?.stringValue, !oldText.isEmpty {
            if call.arguments["replace_all"]?.boolValue == true {
                return source.replacingOccurrences(of: oldText, with: replacement)
            }
            guard let range = source.range(of: oldText) else { return nil }
            var result = source
            result.replaceSubrange(range, with: replacement)
            return result
        }
        guard let start = call.arguments["start_line"]?.intValue,
              let end = call.arguments["end_line"]?.intValue,
              start >= 1, end >= start else { return nil }
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard end <= lines.count else { return nil }
        lines.replaceSubrange((start - 1)..<end, with: replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return lines.joined(separator: "\n")
    }

    private static func boundedPreview(_ value: String, limit: Int = 64 * 1_024) -> String {
        guard value.utf8.count > limit else { return value }
        return String(decoding: value.utf8.prefix(limit), as: UTF8.self) + "\n… [preview truncated]"
    }

    private static func scrubHostWorkspacePaths(
        _ value: String,
        workspace: AgentWorkspace
    ) -> String {
        let raw = workspace.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "/" else { return value }
        let lexical = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: raw, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let candidates = Set([raw, lexical, resolved])
            .filter { !$0.isEmpty && $0 != "/" }
            .sorted { $0.utf8.count > $1.utf8.count }
        return candidates.reduce(value) { partial, path in
            partial.replacingOccurrences(of: path, with: ".")
        }
    }

    private static func boundedProgressDelta(
        _ value: String,
        maximumBytes: Int = TerminalSession.maximumLiveOutputDeltaBytes
    ) -> (value: String, truncated: Bool) {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return (value, false) }
        var prefix = Data(data.prefix(maximumBytes))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return (String(data: prefix, encoding: .utf8) ?? "", true)
    }

    private func limit(
        _ original: AgentToolResult,
        toolName: String
    ) throws -> AgentToolResult {
        var result = original
        let maximumArtifactBytes = 16 * 1_024 * 1_024

        if original.content.utf8.count > maximumResultCharacters {
            let artifact = try writeBoundedArtifact(
                Data(original.content.utf8),
                extension: "txt",
                maximumBytes: maximumArtifactBytes
            )
            let half = maximumResultCharacters / 2
            let artifactLabel = original.content.utf8.count <= maximumArtifactBytes
                ? "完整輸出已保存於本機 artifact"
                : "輸出 artifact 已達 16 MiB 安全上限"
            result.content = String(original.content.prefix(half))
                + "\n…［\(artifactLabel)；以下為尾端］…\n"
                + String(original.content.suffix(maximumResultCharacters - half))
            result.truncated = true
            result.artifactPath = artifact.path
        }

        if let data = result.data {
            let encoded = try JSONEncoder().encode(data)
            let maximumStructuredBytes: Int
            switch toolName {
            case ReviewWorkflowToolFactory.sourceToolName,
                 ReviewWorkflowToolFactory.pullRequestSourceToolName:
                maximumStructuredBytes = ReviewWorkflowToolFactory.maximumSourceReceiptBytes
            case ReviewWorkflowToolFactory.submissionToolName:
                maximumStructuredBytes = ReviewWorkflowToolFactory.maximumSubmissionEnvelopeBytes
            default:
                maximumStructuredBytes = maximumResultCharacters
            }
            if encoded.count > maximumStructuredBytes {
                result.data = .object([
                    "truncated": .bool(true),
                    "byteCount": .number(Double(encoded.count)),
                    "message": .string("Structured tool data exceeded the session limit and was omitted.")
                ])
                result.truncated = true
            }
        }

        if var change = result.change,
           change.unifiedDiff.utf8.count > maximumResultCharacters {
            let artifact = try writeBoundedArtifact(
                Data(change.unifiedDiff.utf8),
                extension: "diff",
                maximumBytes: maximumArtifactBytes
            )
            let half = maximumResultCharacters / 2
            change.unifiedDiff = String(change.unifiedDiff.prefix(half))
                + "\n… diff truncated …\n"
                + String(change.unifiedDiff.suffix(maximumResultCharacters - half))
            change.snapshotPath = artifact.path
            result.change = change
            result.artifactPath = result.artifactPath ?? artifact.path
            result.truncated = true
        }
        return result
    }

    private func writeBoundedArtifact(
        _ data: Data,
        extension fileExtension: String,
        maximumBytes: Int
    ) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let artifact = AppPaths.agentArtifacts.appendingPathComponent(
            "tool-result-\(UUID().uuidString.lowercased()).\(fileExtension)"
        )
        let bounded = data.count <= maximumBytes ? data : Data(data.prefix(maximumBytes))
        try AtomicFileWriter.write(bounded, to: artifact)
        return artifact
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
