import Foundation

enum AgentTaskForkError: LocalizedError, Equatable {
    case workspaceRequired
    case invalidGoal(String)

    var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            "A Task must have a workspace before it can be forked."
        case .invalidGoal(let detail):
            "The parent Goal could not be copied safely: \(detail)"
        }
    }
}

/// Builds durable fork state without sharing any live Runtime object.  A fork
/// receives a bounded context message, copied Goal/Todo values with fresh IDs,
/// and an independently supplied execution location/workspace.
struct AgentTaskForkBuilder: Sendable {
    static let maximumSummaryBytes = 64 * 1_024
    static let maximumSourceMessages = 80

    private let redactor = SecretRedactor()

    func makeFork(
        from source: AgentSession,
        workspace: AgentWorkspace,
        executionLocation: AgentExecutionLocation,
        localWorkspace: AgentWorkspace?,
        localProjectFolderID: UUID?,
        localCheckoutBaselineFingerprint: String? = nil,
        localCheckoutBaselineSupplementalPaths: [String]? = nil,
        localCheckoutBaselineReference: String? = nil,
        forkSessionID: UUID = UUID(),
        now: Date = Date()
    ) throws -> AgentSession {
        guard source.workspace != nil else { throw AgentTaskForkError.workspaceRequired }

        var fork = AgentSession(mode: source.mode)
        fork.id = forkSessionID
        fork.title = boundedTitle(source.title)
        fork.state = .idle
        fork.workspace = workspace
        fork.executionLocation = executionLocation
        fork.localWorkspace = localWorkspace
        fork.localProjectFolderID = localProjectFolderID
        fork.localCheckoutBaselineFingerprint = localCheckoutBaselineFingerprint
        fork.localCheckoutBaselineSupplementalPaths = localCheckoutBaselineSupplementalPaths
        fork.localCheckoutBaselineReference = localCheckoutBaselineReference
        fork.projectID = source.projectID
        // A managed worktree is a Task execution checkout, not another catalog
        // folder. Preserve the original folder separately for a handoff back.
        fork.projectFolderID = executionLocation.kind == .local
            ? source.projectFolderID
            : nil
        fork.messages = summaryMessage(from: source, createdAt: now).map { [$0] } ?? []
        fork.steps = []
        fork.todos = source.todos.map {
            AgentTodo(
                id: UUID(),
                title: $0.title,
                detail: $0.detail,
                status: $0.status,
                createdAt: now,
                updatedAt: now
            )
        }
        if let goal = source.goal {
            do {
                fork.goal = try AgentGoal(
                    id: UUID(),
                    objective: goal.objective,
                    completionCriteria: goal.completionCriteria,
                    createdAt: now,
                    updatedAt: now,
                    completedAt: goal.completedAt == nil ? nil : now
                )
            } catch {
                throw AgentTaskForkError.invalidGoal(error.localizedDescription)
            }
        }
        fork.changes = []
        fork.model = source.model
        fork.provider = source.provider
        fork.profileID = source.profileID
        fork.connection = source.connection
        fork.permissionAllowances = []
        fork.pinnedAt = nil
        fork.archivedAt = nil
        fork.createdAt = now
        fork.updatedAt = now
        fork.lastError = nil
        fork.forkOrigin = AgentTaskForkOrigin(
            sourceSessionID: source.id,
            sourceUpdatedAt: source.updatedAt,
            forkedAt: now
        )
        fork.lastHandoff = nil
        // Checkpoints are immutable provenance references, not live runtime
        // state. Retain the bounded lineage so the fork can explain and audit
        // where it came from without sharing processes or mutable snapshots.
        fork.checkpointReferences = source.checkpointReferences.map {
            Array($0.suffix(256))
        }
        return fork
    }

    private func summaryMessage(from session: AgentSession, createdAt: Date) -> AgentMessage? {
        let candidates = session.messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(Self.maximumSourceMessages)
        var sections: [String] = []
        if let goal = session.goal {
            sections.append("Goal: \(goal.objective)")
            if let criteria = goal.completionCriteria {
                sections.append("Completion criteria: \(criteria)")
            }
        }
        if !session.todos.isEmpty {
            let todo = session.todos.map {
                "[\($0.status.rawValue)] \($0.title)" + ($0.detail.map { ": \($0)" } ?? "")
            }.joined(separator: "\n")
            sections.append("Todo state:\n\(todo)")
        }
        let conversation = candidates.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return "\(message.role.rawValue.uppercased()): \(content)"
        }.joined(separator: "\n\n")
        if !conversation.isEmpty { sections.append("Recent parent conversation:\n\(conversation)") }
        guard !sections.isEmpty else { return nil }

        let header = """
        This Task was forked from \(session.id.uuidString). The following is bounded,
        inherited context only. Re-inspect files and Git state before making claims;
        no terminal, approval, active process, or Runtime state was shared.
        """
        let value = redactor.redact(([header] + sections).joined(separator: "\n\n"))
        let bounded = Self.utf8Prefix(value, maximumBytes: Self.maximumSummaryBytes)
        return AgentMessage(
            role: .system,
            content: bounded,
            name: "luma-task-fork-context",
            createdAt: createdAt
        )
    }

    private func boundedTitle(_ source: String) -> String {
        let prefix = "Fork · "
        let maximumCharacters = 80
        let remainder = max(1, maximumCharacters - prefix.count)
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + String((normalized.isEmpty ? "Coding Task" : normalized).prefix(remainder))
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for character in value {
            let count = String(character).utf8.count
            guard used <= maximumBytes - count else { break }
            result.append(character)
            used += count
        }
        return result + "\n… [fork context truncated]"
    }
}
