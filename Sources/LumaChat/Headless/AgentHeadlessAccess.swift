import Foundation

/// Safe, non-secret failures exposed by the task-scoped headless adapter.
/// Provider, filesystem, and command errors are mapped to a generic server
/// response at the HTTP boundary so internal paths and credentials never leak.
enum AgentHeadlessAccessError: LocalizedError, Equatable, Sendable {
    case notStarted
    case invalidRequest(String)
    case taskNotFound
    case invalidState(String)
    case approvalNotFound

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "The shared Agent runtime has not finished starting."
        case .invalidRequest(let detail), .invalidState(let detail):
            detail
        case .taskNotFound:
            "Task not found."
        case .approvalNotFound:
            "Pending approval not found."
        }
    }
}

struct AgentHeadlessDiffSnapshot: Equatable, Sendable {
    var text: String
    var baseFingerprint: String?
    var changedPaths: [String]
    var truncated: Bool
    var generatedAt: Date
}

typealias AgentHeadlessEventObserver = @MainActor @Sendable (AgentEvent) -> Void
