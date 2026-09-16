import Foundation

enum LumaCLIOutputFormat: String, Codable, Sendable {
    case text
    case json
    case jsonLines
}

enum LumaCLIInteractionMode: String, Codable, Sendable {
    case interactive
    case nonInteractive
}

enum LumaCLIApprovalPolicy: String, Codable, Sendable {
    case prompt
    case deny
}

struct LumaCLIBackendSelection: Equatable, Sendable {
    var backendID: String?
    var modelID: String?

    var isExplicit: Bool { backendID != nil || modelID != nil }
}

struct LumaCLITaskOptions: Equatable, Sendable {
    var taskID: UUID?
    var mode: AppMode
    var title: String?
    var workspacePath: String?
    var backendID: String?
    var modelID: String?
    var timeoutSeconds: Double?
}

struct LumaCLIResumeOptions: Equatable, Sendable {
    var taskID: UUID
    var prompt: String?
    var timeoutSeconds: Double?
}

enum LumaCLIResourceAction: Equatable, Sendable {
    case list(includeArchived: Bool)
    case show(id: String)
}

enum LumaCLICommand: Equatable, Sendable {
    case chat(prompt: String?, timeoutSeconds: Double?)
    case agent(prompt: String?, options: LumaCLITaskOptions)
    case exec(prompt: String, options: LumaCLITaskOptions)
    case resume(LumaCLIResumeOptions)
    case tasks(LumaCLIResourceAction)
    case projects(LumaCLIResourceAction)
    case skills(LumaCLIResourceAction)
    case mcp(LumaCLIResourceAction)
    case plugins(LumaCLIResourceAction)
    case help(topic: String?)
    case version
}

struct LumaCLIInvocation: Equatable, Sendable {
    var command: LumaCLICommand
    var outputFormat: LumaCLIOutputFormat
    var interactionMode: LumaCLIInteractionMode
    var backend: LumaCLIBackendSelection

    var approvalPolicy: LumaCLIApprovalPolicy {
        interactionMode == .interactive ? .prompt : .deny
    }
}

enum LumaCLIEventKind: String, Codable, Sendable {
    case status
    case content
    case reasoning
    case tool
    case approvalRequired
    case warning
}

struct LumaCLIEvent: Codable, Equatable, Sendable {
    var kind: LumaCLIEventKind
    var message: String
    var taskID: UUID?
    var sequence: UInt64?
    var payload: JSONValue?

    init(
        kind: LumaCLIEventKind,
        message: String,
        taskID: UUID? = nil,
        sequence: UInt64? = nil,
        payload: JSONValue? = nil
    ) {
        self.kind = kind
        self.message = message
        self.taskID = taskID
        self.sequence = sequence
        self.payload = payload
    }
}

struct LumaCLIHostResult: Codable, Equatable, Sendable {
    var summary: String
    var taskID: UUID?
    var backendID: String?
    var modelID: String?
    var payload: JSONValue?

    init(
        summary: String,
        taskID: UUID? = nil,
        backendID: String? = nil,
        modelID: String? = nil,
        payload: JSONValue? = nil
    ) {
        self.summary = summary
        self.taskID = taskID
        self.backendID = backendID
        self.modelID = modelID
        self.payload = payload
    }
}

struct LumaCLICreateTaskRequest: Equatable, Sendable {
    var mode: AppMode
    var title: String?
    var workspacePath: String
    var backendID: String
    var modelID: String
}

struct LumaCLITaskMessageRequest: Equatable, Sendable {
    var prompt: String
    var interactionMode: LumaCLIInteractionMode
    var approvalPolicy: LumaCLIApprovalPolicy
    var timeoutSeconds: Double?
}

struct LumaCLIResumeRequest: Equatable, Sendable {
    var prompt: String?
    var interactionMode: LumaCLIInteractionMode
    var approvalPolicy: LumaCLIApprovalPolicy
    var timeoutSeconds: Double?
}

struct LumaCLIChatRequest: Equatable, Sendable {
    var prompt: String
    var backendID: String
    var modelID: String
    var timeoutSeconds: Double?
}

typealias LumaCLIEventHandler = @MainActor @Sendable (LumaCLIEvent) async -> Void

/// Adapter boundary between the command-line frontend and the shared headless
/// runtime. Implementations must delegate to the same task service used by the
/// App Server; they must never drive `AgentViewModel` selection state.
///
/// An explicitly requested backend/model is an authority constraint. If it is
/// unavailable, every method must throw `LumaCLIError.backendUnavailable`
/// instead of selecting a different local backend or any future cloud route.
@MainActor
protocol LumaCLIHost: AnyObject {
    /// Resolves omitted CLI flags to the one configured default route. The
    /// returned selection must contain both IDs; explicit IDs must be preserved
    /// exactly and may not be substituted.
    func resolveBackend(
        selection: LumaCLIBackendSelection
    ) async throws -> LumaCLIBackendSelection

    func chat(
        request: LumaCLIChatRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult

    func createTask(request: LumaCLICreateTaskRequest) async throws -> LumaCLIHostResult
    func task(id: UUID) async throws -> LumaCLIHostResult

    func sendMessage(
        taskID: UUID,
        request: LumaCLITaskMessageRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult

    func resume(
        taskID: UUID,
        request: LumaCLIResumeRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult

    func tasks(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult
    func projects(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult
    func skills(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult
    func mcp(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult
    func plugins(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult
}

enum LumaCLIExitCode: Int32, Equatable, Sendable {
    case success = 0
    case failure = 1
    case usage = 2
    case unavailable = 69
    case permissionDenied = 77
    case configuration = 78
    case cancelled = 130
}

enum LumaCLIError: LocalizedError, Equatable, Sendable {
    case usage(String)
    case configuration(String)
    case notFound(String)
    case backendUnavailable(String)
    case approvalRequired(String)
    case permissionDenied(String)
    case timedOut(String)
    case cancelled
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message),
             .configuration(let message),
             .notFound(let message),
             .backendUnavailable(let message),
             .approvalRequired(let message),
             .permissionDenied(let message),
             .timedOut(let message),
             .executionFailed(let message):
            message
        case .cancelled:
            "Command cancelled."
        }
    }

    var exitCode: LumaCLIExitCode {
        switch self {
        case .usage:
            .usage
        case .configuration:
            .configuration
        case .notFound, .executionFailed, .timedOut:
            .failure
        case .backendUnavailable:
            .unavailable
        case .approvalRequired, .permissionDenied:
            .permissionDenied
        case .cancelled:
            .cancelled
        }
    }
}
