import Foundation

enum SubagentAccessMode: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case writableWorktree = "writable_worktree"
}

enum SubagentPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: SubagentPriority, rhs: SubagentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SubagentStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut:
            true
        case .queued, .running, .paused, .interrupted:
            false
        }
    }
}

struct SubagentBudget: Codable, Equatable, Sendable {
    static let defaultMaximumSteps = 24
    static let defaultContextTokens = 32_768
    static let defaultTotalTokens = 96_000
    static let defaultTimeoutSeconds = 900

    var maximumSteps: Int = defaultMaximumSteps
    var contextTokens: Int = defaultContextTokens
    var totalTokens: Int = defaultTotalTokens
    var timeoutSeconds: Int = defaultTimeoutSeconds
}

struct SubagentScope: Codable, Equatable, Sendable {
    var access: SubagentAccessMode = .readOnly
    /// A workspace-relative directory. Read-only children can be narrowed to
    /// this directory. Writable children always receive a whole dedicated
    /// managed worktree and therefore require `.` here.
    var relativePath: String = "."
    /// Empty input means the host's conservative defaults, never every tool.
    var allowedToolNames: [String] = []
    var allowedMCPServerIDs: [UUID] = []
    var networkAccess: Bool = false
}

struct SubagentSpawnRequest: Codable, Equatable, Sendable {
    var goal: String
    var context: String?
    var scope: SubagentScope = SubagentScope()
    var budget: SubagentBudget = SubagentBudget()
    var priority: SubagentPriority = .normal
}

struct SubagentTestResult: Codable, Equatable, Sendable {
    var command: String
    var passed: Bool
    var detail: String?
}

struct SubagentStructuredResult: Codable, Equatable, Sendable {
    var summary: String
    var findings: [String]
    var files: [String]
    var commands: [String]
    var tests: [SubagentTestResult]
    var artifacts: [String]
    var confidence: Double
    var unresolved: [String]
}

struct SubagentRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var parentSessionID: UUID
    var childSessionID: UUID
    var goal: String
    var status: SubagentStatus
    var scope: SubagentScope
    var context: String?
    var budget: SubagentBudget
    var priority: SubagentPriority
    var providerKey: String
    var depth: Int
    var consumedTokens: Int
    var attempt: Int
    var pendingMessages: [String]
    var startedAt: Date?
    var endedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var result: SubagentStructuredResult?
    var error: String?
    var collectedAt: Date?
}

struct SubagentAuthority: Sendable {
    var parentSessionID: UUID
    var parentDepth: Int
    var providerKey: String
    var workspaceIsGitRepository: Bool
    var networkAccess: Bool
    var allowedMCPServerIDs: Set<UUID>?
    var allowedToolNames: Set<String>?
}

struct SubagentExecutionOutcome: Sendable {
    var status: SubagentStatus
    var result: SubagentStructuredResult?
    var error: String?
}

protocol SubagentControlling: Sendable {
    func spawnSubagent(
        _ request: SubagentSpawnRequest,
        authority: SubagentAuthority
    ) async throws -> SubagentRecord
    func sendSubagentMessage(
        id: UUID,
        parentSessionID: UUID,
        message: String
    ) async throws -> SubagentRecord
    func waitForSubagent(
        id: UUID,
        parentSessionID: UUID,
        timeoutSeconds: Int
    ) async throws -> SubagentRecord
    func listSubagents(parentSessionID: UUID) async -> [SubagentRecord]
    func cancelSubagent(id: UUID, parentSessionID: UUID) async throws -> SubagentRecord
    func resumeSubagent(id: UUID, parentSessionID: UUID) async throws -> SubagentRecord
    func collectSubagentResult(
        id: UUID,
        parentSessionID: UUID
    ) async throws -> SubagentStructuredResult
    func takePendingSubagentMessages(id: UUID) async -> [String]
    func recordSubagentTokenUsage(id: UUID, tokens: Int) async
    func hasOutstandingSubagents(parentSessionID: UUID) async -> Bool
    func cancelSubagents(parentSessionID: UUID) async throws
}

enum SubagentError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unavailable
    case recordNotFound(UUID)
    case parentMismatch
    case concurrencyLimit
    case invalidTransition(SubagentStatus)
    case resultUnavailable
    case waitTimedOut(Int)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail):
            "Subagent 請求無效：\(detail)"
        case .unavailable:
            "Subagent orchestration 尚未可用。"
        case .recordNotFound(let id):
            "找不到 Subagent \(id.uuidString)。"
        case .parentMismatch:
            "Subagent 不屬於目前的 Parent Task。"
        case .concurrencyLimit:
            "Parent Task 的 Subagent 數量已達安全上限。"
        case .invalidTransition(let status):
            "Subagent 目前狀態 \(status.rawValue) 不允許這個操作。"
        case .resultUnavailable:
            "Subagent 尚未產生可收集的結構化結果。"
        case .waitTimedOut(let seconds):
            "等待 Subagent 超過 \(seconds) 秒；它仍會在背景執行。"
        case .executionFailed(let detail):
            "Subagent 執行失敗：\(detail)"
        }
    }
}

enum SubagentValidation {
    static let maximumDepth = 1
    static let maximumChildrenPerParent = 16
    static let maximumActiveChildrenPerParent = 8
    static let maximumGoalBytes = 8 * 1_024
    static let maximumContextBytes = 32 * 1_024
    static let maximumMessageBytes = 8 * 1_024
    static let maximumResultItems = 256
    static let maximumResultTextBytes = 128 * 1_024

    static let defaultReadTools: Set<String> = [
        "list_directory", "read_file", "read_multiple_files", "file_info",
        "search_files", "grep", "find_symbol", "git_status", "git_diff",
        "git_diff_file", "git_log", "git_branch", "git_current_branch",
        "git_show", "git_remotes", "git_tags", "git_stash_list", "todo_list",
        "view_image"
    ]

    static let defaultWritableTools: Set<String> = defaultReadTools.union([
        "create_file", "write_file", "edit_file", "apply_patch",
        "create_directory", "move_file", "copy_file", "delete_file",
        "build", "test", "git_add", "git_restore", "git_checkout",
        "git_commit", "git_create_branch", "todo_create", "todo_update",
        "todo_complete"
    ])

    static func validated(
        _ raw: SubagentSpawnRequest,
        authority: SubagentAuthority
    ) throws -> SubagentSpawnRequest {
        guard authority.parentDepth < maximumDepth else {
            throw SubagentError.invalidRequest("Subagent 不可再建立下一層 child。")
        }
        let goal = try boundedText(
            raw.goal,
            label: "goal",
            maximumBytes: maximumGoalBytes,
            allowEmpty: false
        )
        let context = try raw.context.map {
            try boundedText(
                $0,
                label: "context",
                maximumBytes: maximumContextBytes,
                allowEmpty: true
            )
        }
        let relativePath = try validatedRelativeDirectory(raw.scope.relativePath)
        guard raw.scope.access == .readOnly || relativePath == "." else {
            throw SubagentError.invalidRequest(
                "可寫 Subagent 必須使用整個獨立 worktree；relative_path 必須是 .。"
            )
        }
        guard raw.scope.access == .readOnly || authority.workspaceIsGitRepository else {
            throw SubagentError.invalidRequest("可寫 Subagent 需要 Git workspace。")
        }
        guard !raw.scope.networkAccess || authority.networkAccess else {
            throw SubagentError.invalidRequest("Child 不可擴張 Parent 的 network 權限。")
        }

        let requestedMCP = Set(raw.scope.allowedMCPServerIDs)
        guard requestedMCP.count == raw.scope.allowedMCPServerIDs.count,
              requestedMCP.count <= 32 else {
            throw SubagentError.invalidRequest("MCP scope 重複或超過 32 個。")
        }
        if let parentMCP = authority.allowedMCPServerIDs,
           !requestedMCP.isSubset(of: parentMCP) {
            throw SubagentError.invalidRequest("Child 不可擴張 Parent 的 MCP scope。")
        }

        let defaults = raw.scope.access == .readOnly ? defaultReadTools : defaultWritableTools
        let requestedTools = try validatedTools(raw.scope.allowedToolNames)
        var tools = requestedTools.isEmpty ? defaults : requestedTools
        if let parentTools = authority.allowedToolNames {
            guard tools.isSubset(of: parentTools) else {
                throw SubagentError.invalidRequest("Child 不可擴張 Parent 的 tool scope。")
            }
        }
        tools.remove("spawn_subagent")
        tools.remove("send_subagent_message")
        tools.remove("wait_subagent")
        tools.remove("list_subagents")
        tools.remove("cancel_subagent")
        tools.remove("resume_subagent")
        tools.remove("collect_subagent_result")

        if raw.scope.access == .readOnly {
            tools.formIntersection(defaultReadTools)
        }
        guard !tools.isEmpty else {
            throw SubagentError.invalidRequest("Subagent 至少需要一個允許的工具。")
        }

        let budget = raw.budget
        guard (1...100).contains(budget.maximumSteps),
              (2_048...262_144).contains(budget.contextTokens),
              (1_024...2_000_000).contains(budget.totalTokens),
              (10...3_600).contains(budget.timeoutSeconds) else {
            throw SubagentError.invalidRequest("budget 超出安全範圍。")
        }

        return SubagentSpawnRequest(
            goal: goal,
            context: context,
            scope: SubagentScope(
                access: raw.scope.access,
                relativePath: relativePath,
                allowedToolNames: tools.sorted(),
                allowedMCPServerIDs: requestedMCP.sorted { $0.uuidString < $1.uuidString },
                networkAccess: raw.scope.networkAccess
            ),
            budget: budget,
            priority: raw.priority
        )
    }

    static func validatedMessage(_ raw: String) throws -> String {
        try boundedText(
            raw,
            label: "message",
            maximumBytes: maximumMessageBytes,
            allowEmpty: false
        )
    }

    static func validatedResult(_ raw: SubagentStructuredResult) throws -> SubagentStructuredResult {
        func values(_ input: [String], _ label: String) throws -> [String] {
            guard input.count <= maximumResultItems else {
                throw SubagentError.invalidRequest("\(label) 超過項目上限。")
            }
            var total = 0
            return try input.map { item in
                let value = try boundedText(
                    item,
                    label: label,
                    maximumBytes: 8 * 1_024,
                    allowEmpty: false
                )
                total += value.utf8.count
                guard total <= maximumResultTextBytes else {
                    throw SubagentError.invalidRequest("\(label) 總長度過大。")
                }
                return value
            }
        }

        guard raw.confidence.isFinite, (0...1).contains(raw.confidence),
              raw.tests.count <= maximumResultItems else {
            throw SubagentError.invalidRequest("structured result 欄位無效。")
        }
        return SubagentStructuredResult(
            summary: try boundedText(
                raw.summary,
                label: "summary",
                maximumBytes: maximumResultTextBytes,
                allowEmpty: false
            ),
            findings: try values(raw.findings, "findings"),
            files: try values(raw.files, "files"),
            commands: try values(raw.commands, "commands"),
            tests: try raw.tests.map { test in
                SubagentTestResult(
                    command: try boundedText(
                        test.command,
                        label: "test.command",
                        maximumBytes: 8 * 1_024,
                        allowEmpty: false
                    ),
                    passed: test.passed,
                    detail: try test.detail.map {
                        try boundedText(
                            $0,
                            label: "test.detail",
                            maximumBytes: 8 * 1_024,
                            allowEmpty: true
                        )
                    }
                )
            },
            artifacts: try values(raw.artifacts, "artifacts"),
            confidence: raw.confidence,
            unresolved: try values(raw.unresolved, "unresolved")
        )
    }

    private static func validatedTools(_ values: [String]) throws -> Set<String> {
        guard values.count <= 64 else {
            throw SubagentError.invalidRequest("tool scope 超過 64 個。")
        }
        var result = Set<String>()
        for value in values {
            guard value.utf8.count <= 128,
                  !value.isEmpty,
                  value.utf8.allSatisfy({ byte in
                      byte == 0x5F || byte == 0x2E || byte == 0x2D
                          || (0x30...0x39).contains(byte)
                          || (0x41...0x5A).contains(byte)
                          || (0x61...0x7A).contains(byte)
                  }),
                  result.insert(value).inserted else {
                throw SubagentError.invalidRequest("tool scope 包含無效或重複名稱。")
            }
        }
        return result
    }

    private static func validatedRelativeDirectory(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw SubagentError.invalidRequest("relative_path 必須是安全的 workspace 相對目錄。")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw SubagentError.invalidRequest("relative_path 不可包含空白段或 ..。")
        }
        let normalized = components.filter { $0 != "." }.joined(separator: "/")
        return normalized.isEmpty ? "." : normalized
    }

    private static func boundedText(
        _ raw: String,
        label: String,
        maximumBytes: Int,
        allowEmpty: Bool
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !value.isEmpty),
              value.utf8.count <= maximumBytes,
              !value.contains("\0"),
              !value.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      && scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D
              }) else {
            throw SubagentError.invalidRequest("\(label) 為空白、過大或含控制字元。")
        }
        return value
    }
}
