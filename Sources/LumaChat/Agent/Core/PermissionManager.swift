import CryptoKit
import Foundation

enum ToolAuthorization: Sendable, Equatable {
    case allow
    case requireApproval(level: AgentPermissionLevel, reasons: [String])
    case deny(reason: String)
}

actor PermissionManager {
    private static let maximumPersistedAllowances = 128
    private static let maximumAllowanceFieldBytes = 512

    private struct AllowanceKey: Hashable, Sendable {
        var toolID: String
        var toolName: String
        var category: String
        var effectiveLevel: String
        var workspaceRoot: String
        var argumentScope: Data?
    }

    private var sessionAllowances: [UUID: Set<AllowanceKey>] = [:]
    private let riskAnalyzer: CommandRiskAnalyzer
    private let projectCommandPolicy: AgentProjectCommandPolicyEvaluator

    init(riskAnalyzer: CommandRiskAnalyzer = CommandRiskAnalyzer()) {
        self.riskAnalyzer = riskAnalyzer
        projectCommandPolicy = AgentProjectCommandPolicyEvaluator(riskAnalyzer: riskAnalyzer)
    }

    func authorize(
        metadata: ToolMetadata,
        call: AgentToolCall,
        context: AgentToolContext,
        permissionMode: AgentPermissionMode,
        networkAccess: Bool
    ) -> ToolAuthorization {
        guard context.mode.usesAgentRuntime else {
            return .deny(reason: "Chat 模式不允許使用專案工具。")
        }

        // Lifecycle hooks are selected by the host from an installed manifest,
        // and the exact plugin/hook/event binding is rechecked by the tool.
        // Their install-time permission grant therefore acts as the approval;
        // they still traverse this manager and fail closed when global network
        // access is unavailable. Model calls never receive this capability.
        if context.lifecycleHookInvocation != nil, metadata.category == .plugin {
            guard !metadata.requiresNetwork || networkAccess else {
                return .deny(reason: "Lifecycle hook 需要網路，但此 Task 未開放網路存取。")
            }
            return .allow
        }

        if context.mode == .plan {
            guard metadata.permissionLevel == .read || metadata.category == .todo else {
                return .deny(reason: "Plan 模式只允許讀取、搜尋、Git 檢視與 Todo 工具。")
            }
            if metadata.requiresNetwork && !networkAccess {
                let allowance = Self.allowanceKey(
                    metadata: metadata,
                    context: context,
                    effectiveLevel: .network,
                    call: call
                )
                if sessionAllowances[context.sessionID]?.contains(allowance) == true {
                    return .allow
                }
                return .requireApproval(
                    level: .network,
                    reasons: ["此唯讀工具仍會將資料傳送到網路，而 Agent 網路存取目前未自動開放"]
                )
            }
            return .allow
        }

        var level = metadata.permissionLevel
        var reasons: [String] = []
        var isConservativeAutomaticTerminalCommand = false
        var isProjectAllowedCommand = false
        if metadata.category == .terminal,
           let command = call.arguments["command"]?.stringValue {
            let projectPolicy = projectCommandPolicy.evaluate(
                command: command,
                settings: AgentProjectSettings(
                    allowedCommands: context.allowedCommands,
                    deniedCommands: context.deniedCommands
                )
            )
            switch projectPolicy {
            case .denied(.matchedDeniedCommand):
                return .deny(reason: "此命令已被目前 Project Settings 明確拒絕。")
            case .denied:
                return .deny(reason: "Project Settings 的命令規則無效；已安全拒絕執行。")
            case .automaticApprovalCandidate:
                isProjectAllowedCommand = true
            case .requiresStandardAuthorization:
                break
            }
            let assessment = riskAnalyzer.assess(command)
            isConservativeAutomaticTerminalCommand = riskAnalyzer
                .isConservativeAutomaticCommand(command)
            reasons = assessment.reasons
            if !isConservativeAutomaticTerminalCommand {
                reasons.append(
                    "任意 shell 可能修改 Workspace；請優先使用可產生 Diff/Undo 的檔案工具，shell 變更僅能由 validation 與 Git diff 交叉檢查"
                )
            }
            switch assessment.level {
            case .dangerous: level = .dangerous
            case .network where level != .dangerous: level = .network
            case .safe: break
            case .network: break
            }
        }

        let networkIsDisabled = metadata.requiresNetwork && !networkAccess
        if networkIsDisabled {
            reasons.append("此工具會把參數傳送到網路服務，而 Agent 網路存取目前未自動開放")
        }
        if metadata.category == .mcp, level != .read {
            reasons.append(
                "MCP 工具在外部程序／服務執行；若它修改 Workspace 或遠端資料，Luma Chat 無法保證原生 Diff/Undo snapshot"
            )
        }
        if level == .dangerous {
            return .requireApproval(
                level: .dangerous,
                reasons: reasons.isEmpty ? ["此工具可能造成難以復原的變更"] : reasons
            )
        }
        let effectiveLevel: AgentPermissionLevel = networkIsDisabled
            || (level == .network && !networkAccess)
            ? .network
            : level
        // An explicit session allowance may cover the same network action even
        // while global auto-network access remains disabled. Terminal grants
        // are hashed to the exact argument object; dangerous actions are never
        // stored and therefore can never reach this branch.
        let allowance = Self.allowanceKey(
            metadata: metadata,
            context: context,
            effectiveLevel: effectiveLevel,
            call: call
        )
        if sessionAllowances[context.sessionID]?.contains(allowance) == true {
            return .allow
        }
        if effectiveLevel == .network && !networkAccess {
            return .requireApproval(
                level: .network,
                reasons: reasons.isEmpty ? ["Agent 的網路存取目前未自動開放"] : reasons
            )
        }
        if level == .read { return .allow }
        if isProjectAllowedCommand { return .allow }

        switch permissionMode {
        case .askEveryTime:
            return .requireApproval(level: level, reasons: reasons)
        case .autoApproveSafe:
            // `build` and `test` do not accept model-provided shell text. Their
            // commands are selected from a fixed, workspace-manifest-based
            // detector, so they are the safe validation actions promised by
            // Auto Approve Safe Tools. Keep arbitrary terminal/MCP execute
            // tools on the approval path.
            if metadata.category == .terminal,
               level == .execute,
               metadata.id == "builtin.\(metadata.name)",
               (metadata.name == "build" || metadata.name == "test") {
                return .allow
            }
            if metadata.category == .terminal,
               level == .execute,
               !isConservativeAutomaticTerminalCommand {
                return .requireApproval(
                    level: .execute,
                    reasons: ["任意 shell 與專案程式需明確確認；只有保守的唯讀命令可自動執行"]
                )
            }
            return level == .network || level == .execute
                ? .requireApproval(level: level, reasons: reasons)
                : .allow
        case .fullAccess:
            return .allow
        }
    }

    func allowForSession(
        metadata: ToolMetadata,
        context: AgentToolContext,
        effectiveLevel: AgentPermissionLevel,
        call: AgentToolCall? = nil
    ) {
        // Dangerous operations are deliberately re-approved every time and
        // therefore must never enter either the in-memory or durable allowance
        // set.
        guard effectiveLevel != .dangerous else { return }
        if Self.isBuiltInComputerUse(metadata) {
            guard let call,
                  let scope = ComputerUseScopedApprovalPolicy.scope(
                      toolName: metadata.name,
                      arguments: call.arguments
                  ),
                  scope.isAlwaysAllowEligible else {
                return
            }
        }
        sessionAllowances[context.sessionID, default: []].insert(
            Self.allowanceKey(
                metadata: metadata,
                context: context,
                effectiveLevel: effectiveLevel,
                call: call
            )
        )
    }

    func persistedAllowances(for sessionID: UUID) -> [AgentPermissionAllowance] {
        (sessionAllowances[sessionID] ?? [])
            // Third-party MCP and Plugin code can change independently between
            // launches (or after a Plugin update). Their approvals are
            // fail-closed and remain process-local.
            .filter {
                $0.category != AgentToolCategory.mcp.rawValue
                    && $0.category != AgentToolCategory.plugin.rawValue
                    && $0.category != AgentToolCategory.browser.rawValue
                    && !Self.isBuiltInComputerUseAllowance(
                        toolID: $0.toolID,
                        toolName: $0.toolName
                    )
            }
            .map {
                AgentPermissionAllowance(
                    toolID: $0.toolID,
                    toolName: $0.toolName,
                    category: $0.category,
                    effectiveLevel: $0.effectiveLevel,
                    workspaceRoot: $0.workspaceRoot,
                    argumentScope: $0.argumentScope
                )
            }
            .sorted {
                let lhs = [$0.toolID, $0.toolName, $0.category, $0.effectiveLevel]
                    .joined(separator: "\u{0}")
                let rhs = [$1.toolID, $1.toolName, $1.category, $1.effectiveLevel]
                    .joined(separator: "\u{0}")
                if lhs == rhs {
                    return ($0.argumentScope ?? Data()).lexicographicallyPrecedes(
                        $1.argumentScope ?? Data()
                    )
                }
                return lhs < rhs
            }
    }

    func restorePersistedAllowances(
        _ allowances: [AgentPermissionAllowance],
        for sessionID: UUID,
        workspace: AgentWorkspace
    ) {
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let restored = allowances
            .prefix(Self.maximumPersistedAllowances)
            .compactMap { allowance -> AllowanceKey? in
                guard allowance.workspaceRoot == root,
                      allowance.category != AgentToolCategory.mcp.rawValue,
                      allowance.category != AgentToolCategory.plugin.rawValue,
                      allowance.category != AgentToolCategory.browser.rawValue,
                      !Self.isBuiltInComputerUseAllowance(
                          toolID: allowance.toolID,
                          toolName: allowance.toolName
                      ),
                      allowance.effectiveLevel != AgentPermissionLevel.dangerous.rawValue,
                      Self.validAllowanceField(allowance.toolID),
                      Self.validAllowanceField(allowance.toolName),
                      Self.validAllowanceField(allowance.category),
                      Self.validAllowanceField(allowance.effectiveLevel),
                      allowance.argumentScope == nil || allowance.argumentScope?.count == 32 else {
                    return nil
                }
                return AllowanceKey(
                    toolID: allowance.toolID,
                    toolName: allowance.toolName,
                    category: allowance.category,
                    effectiveLevel: allowance.effectiveLevel,
                    workspaceRoot: allowance.workspaceRoot,
                    argumentScope: allowance.argumentScope
                )
            }
        if restored.isEmpty {
            sessionAllowances.removeValue(forKey: sessionID)
        } else {
            sessionAllowances[sessionID] = Set(restored)
        }
    }

    func clearSession(_ sessionID: UUID) {
        sessionAllowances.removeValue(forKey: sessionID)
    }

    func clearAll() {
        sessionAllowances.removeAll()
    }

    private static func allowanceKey(
        metadata: ToolMetadata,
        context: AgentToolContext,
        effectiveLevel: AgentPermissionLevel,
        call: AgentToolCall?
    ) -> AllowanceKey {
        let root = URL(fileURLWithPath: context.workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return AllowanceKey(
            toolID: metadata.id,
            toolName: metadata.name,
            category: metadata.category.rawValue,
            effectiveLevel: effectiveLevel.rawValue,
            workspaceRoot: root,
            argumentScope: argumentScope(metadata: metadata, call: call)
        )
    }

    private static func argumentScope(
        metadata: ToolMetadata,
        call: AgentToolCall?
    ) -> Data? {
        guard metadata.category == .terminal || isBuiltInComputerUse(metadata),
              let call else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(call.arguments) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    private static func isBuiltInComputerUse(_ metadata: ToolMetadata) -> Bool {
        isBuiltInComputerUseAllowance(
            toolID: metadata.id,
            toolName: metadata.name
        )
    }

    private static func isBuiltInComputerUseAllowance(
        toolID: String,
        toolName: String
    ) -> Bool {
        toolID == "builtin.\(toolName)"
            && ComputerUseScopedApprovalPolicy.recognizes(toolName: toolName)
    }

    private static func validAllowanceField(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumAllowanceFieldBytes
            && !value.contains("\0")
    }
}

struct SecretRedactor: Sendable {
    func redact(_ input: String) -> String {
        var output = input
        let patterns: [(pattern: String, replacement: String)] = [
            (#"(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----"#, "[REDACTED]"),
            (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{4,}"#, "$1 [REDACTED]"),
            (
                #"(?i)([\"']?\b[A-Za-z0-9_.-]{0,128}(?:api[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|password|passwd|secret|authorization|credential|private[_-]?key|client[_-]?secret|cookie)[A-Za-z0-9_.-]{0,128}[\"']?\s*[:=]\s*)[\"']?[^\s\"',;]{4,65536}[\"']?"#,
                "$1[REDACTED]"
            ),
            (
                #"(?i)(--?[A-Za-z0-9_.-]{0,128}(?:api[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|password|passwd|secret|authorization|credential|private[_-]?key|client[_-]?secret|cookie)[A-Za-z0-9_.-]{0,128}\s+)(?:\"[^\"]{4,65536}\"|'[^']{4,65536}'|[^\s\"'`;]{4,65536})"#,
                "$1[REDACTED]"
            ),
            (#"(?i)\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,}|glpat-[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{12,})\b"#, "[REDACTED]"),
            // Credential-bearing URLs are secrets regardless of scheme. The
            // username may be empty (for example `redis://:password@host`).
            (#"(?i)(\b[a-z][a-z0-9+.-]{0,31}://(?:[^\s/:@]{1,1024})?):[^\s/@]{1,65536}@"#, "$1:[REDACTED]@")
        ]
        for item in patterns {
            guard let expression = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = expression.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: item.replacement
            )
        }
        return output
    }

    func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(redact(text))
        case .array(let values): .array(values.map(redact))
        case .object(let object):
            .object(object.reduce(into: [String: JSONValue]()) { values, entry in
                values[entry.key] = Self.isSensitiveKey(entry.key)
                    ? .string("[REDACTED]")
                    : redact(entry.value)
            })
        case .number, .bool, .null: value
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "token", "password", "passwd", "secret", "api_key", "access_key",
            "authorization", "credential", "private_key", "client_secret", "cookie"
        ].contains(where: normalized.contains)
    }
}
