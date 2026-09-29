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

/// Builds durable fork state without sharing any live Runtime object. A fork
/// receives bounded, redacted user/assistant history, copied Goal/Todo values
/// with fresh IDs, and an independently supplied execution location/workspace.
struct AgentTaskForkBuilder: Sendable {
    static let maximumHistoryBytes = 64 * 1_024
    static let maximumSourceMessages = 80
    private static let truncationMarker = "\n… [fork message truncated]"

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
        fork.messages = inheritedMessages(from: source, createdAt: now)
        fork.steps = []
        fork.todos = source.todos.map {
            AgentTodo(
                id: UUID(),
                title: redactor.redact($0.title),
                detail: $0.detail.map(redactor.redact),
                status: $0.status,
                createdAt: now,
                updatedAt: now
            )
        }
        if let goal = source.goal {
            do {
                fork.goal = try AgentGoal(
                    id: UUID(),
                    objective: redactor.redact(goal.objective),
                    completionCriteria: goal.completionCriteria.map(redactor.redact),
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

    private func inheritedMessages(from session: AgentSession, createdAt: Date) -> [AgentMessage] {
        let header = AgentMessage(
            role: .system,
            content: """
            This Task was forked from \(session.id.uuidString). Earlier user and assistant messages
            are inherited context only. Re-inspect files and Git state before making claims. Tool
            calls, tool results, reasoning, review payloads, and image attachments were not carried;
            no terminal, approval, active process, or Runtime state was shared. Older messages may
            be omitted to fit the bounded fork history.
            """,
            name: "luma-task-fork-context",
            createdAt: createdAt
        )
        var remainingBytes = Self.maximumHistoryBytes - header.content.utf8.count
        var newestFirst: [AgentMessage] = []
        let candidates = session.messages
            .filter {
                ($0.role == .user || $0.role == .assistant)
                    && (!$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !$0.imageAttachments.isEmpty)
            }
            .suffix(Self.maximumSourceMessages)

        for original in candidates.reversed() {
            var content = redactor.redact(original.content)
            if !original.imageAttachments.isEmpty {
                content += (content.isEmpty ? "" : "\n")
                    + "[Parent image attachment omitted; reattach it if needed.]"
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard remainingBytes > 0 else { break }
            let inheritedContent: String
            if content.utf8.count <= remainingBytes {
                inheritedContent = content
            } else if newestFirst.isEmpty {
                inheritedContent = Self.utf8Prefix(
                    content,
                    maximumBytes: remainingBytes,
                    marker: Self.truncationMarker
                )
            } else {
                break
            }
            guard !inheritedContent.isEmpty else { break }
            // Create fresh message identities and carry text only. In particular,
            // provider tool-call/result pairs and parent attachment paths must
            // never be replayed in the child session.
            newestFirst.append(AgentMessage(
                role: original.role,
                content: inheritedContent,
                createdAt: original.createdAt
            ))
            remainingBytes -= inheritedContent.utf8.count
            if inheritedContent != content { break }
        }
        return [header] + Array(newestFirst.reversed())
    }

    private func boundedTitle(_ source: String) -> String {
        let prefix = "Fork · "
        let maximumCharacters = 80
        let remainder = max(1, maximumCharacters - prefix.count)
        let normalized = redactor.redact(source).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix + String((normalized.isEmpty ? "Coding Task" : normalized).prefix(remainder))
    }

    private static func utf8Prefix(
        _ value: String,
        maximumBytes: Int,
        marker: String
    ) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        guard maximumBytes > marker.utf8.count else { return "" }
        var result = ""
        result.reserveCapacity(maximumBytes - marker.utf8.count)
        var used = 0
        for character in value {
            let count = String(character).utf8.count
            guard used <= maximumBytes - marker.utf8.count - count else { break }
            result.append(character)
            used += count
        }
        return result + marker
    }
}
