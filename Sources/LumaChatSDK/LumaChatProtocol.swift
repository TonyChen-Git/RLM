import Foundation

/// Wire-level version for the language-neutral LumaChat headless API.
///
/// The protocol uses ordinary JSON over HTTP for commands and Server-Sent
/// Events (SSE) for task events. No Swift type names are required by clients.
public enum LumaChatAPIVersion {
    public static let v1 = "v1"
    public static let basePath = "/v1"
}

public enum LumaChatTaskMode: String, Codable, CaseIterable, Sendable {
    case chat
    case plan
    case agent
}

public enum LumaChatTaskState: String, Codable, CaseIterable, Sendable {
    case idle
    case running
    case awaitingApproval = "awaiting_approval"
    case paused
    case completed
    case cancelled
    case failed
    case stepLimit = "step_limit"
}

public enum LumaChatExecutionKind: String, Codable, CaseIterable, Sendable {
    case local
    case worktree
    case ssh
    /// Durable representation only. v1 has no cloud executor and must return
    /// `backend_unavailable` rather than silently running this task elsewhere.
    case futureCloud = "future_cloud"
}

/// Exact inference route selected by the caller. The v1 server must either use
/// this route or return `backend_unavailable`; implicit provider/cloud fallback
/// is prohibited.
public struct LumaChatTaskCreateRequest: Codable, Equatable, Sendable {
    /// Caller-generated idempotency identity. A conforming runtime must return
    /// the original result when this request is retried with the same payload.
    public var requestID: UUID?
    public var title: String?
    public var mode: LumaChatTaskMode
    public var workspacePath: String
    /// Stable provider/backend identifier (for example `ollama` or
    /// `openai-compatible/profile-id`). It must be resolved exactly.
    public var backendID: String
    public var modelID: String

    public init(
        requestID: UUID? = UUID(),
        title: String? = nil,
        mode: LumaChatTaskMode = .agent,
        workspacePath: String,
        backendID: String,
        modelID: String
    ) {
        self.requestID = requestID
        self.title = title
        self.mode = mode
        self.workspacePath = workspacePath
        self.backendID = backendID
        self.modelID = modelID
    }
}

public struct LumaChatMessageRequest: Codable, Equatable, Sendable {
    public var requestID: UUID?
    public var content: String
    public var metadata: [String: LumaChatJSONValue]?

    public init(
        requestID: UUID? = UUID(),
        content: String,
        metadata: [String: LumaChatJSONValue]? = nil
    ) {
        self.requestID = requestID
        self.content = content
        self.metadata = metadata
    }
}

public struct LumaChatControlRequest: Codable, Equatable, Sendable {
    public var requestID: UUID?

    public init(requestID: UUID? = UUID()) {
        self.requestID = requestID
    }
}

public struct LumaChatResumeRequest: Codable, Equatable, Sendable {
    public var requestID: UUID?
    /// Optional continuation text. Nil resumes the task's durable pending goal
    /// or turn without inventing a new prompt.
    public var content: String?
    public var metadata: [String: LumaChatJSONValue]?

    public init(
        requestID: UUID? = UUID(),
        content: String? = nil,
        metadata: [String: LumaChatJSONValue]? = nil
    ) {
        self.requestID = requestID
        self.content = content
        self.metadata = metadata
    }
}

public enum LumaChatApprovalDecision: String, Codable, CaseIterable, Sendable {
    case allowOnce
    case allowForTask
    case deny
}

public struct LumaChatApprovalDecisionRequest: Codable, Equatable, Sendable {
    public var requestID: UUID?
    public var approvalID: UUID
    public var decision: LumaChatApprovalDecision

    public init(
        requestID: UUID? = UUID(),
        approvalID: UUID,
        decision: LumaChatApprovalDecision
    ) {
        self.requestID = requestID
        self.approvalID = approvalID
        self.decision = decision
    }
}

public struct LumaChatApproval: Codable, Equatable, Sendable {
    public var id: UUID
    public var toolName: String
    public var displayName: String
    public var permissionLevel: String
    public var reason: String?
    public var command: String?
    public var workingDirectory: String?
    public var riskReasons: [String]
    public var diffPreview: String?

    public init(
        id: UUID,
        toolName: String,
        displayName: String,
        permissionLevel: String,
        reason: String? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        riskReasons: [String] = [],
        diffPreview: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.displayName = displayName
        self.permissionLevel = permissionLevel
        self.reason = reason
        self.command = command
        self.workingDirectory = workingDirectory
        self.riskReasons = riskReasons
        self.diffPreview = diffPreview
    }
}

public struct LumaChatTaskResult: Codable, Equatable, Sendable {
    public var content: String
    public var reasoningSummary: String?

    public init(content: String, reasoningSummary: String? = nil) {
        self.content = content
        self.reasoningSummary = reasoningSummary
    }
}

public struct LumaChatTaskSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var mode: LumaChatTaskMode
    public var status: LumaChatTaskState
    public var backendID: String
    public var modelID: String
    public var workspacePath: String
    public var executionKind: LumaChatExecutionKind
    public var pendingApproval: LumaChatApproval?
    /// Latest terminal assistant output when available. Optional preserves wire
    /// compatibility with v1 servers written before result projection existed.
    public var result: LumaChatTaskResult?
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        mode: LumaChatTaskMode,
        status: LumaChatTaskState,
        backendID: String,
        modelID: String,
        workspacePath: String,
        executionKind: LumaChatExecutionKind = .local,
        pendingApproval: LumaChatApproval? = nil,
        result: LumaChatTaskResult? = nil,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.status = status
        self.backendID = backendID
        self.modelID = modelID
        self.workspacePath = workspacePath
        self.executionKind = executionKind
        self.pendingApproval = pendingApproval
        self.result = result
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LumaChatAcceptedOperation: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var taskID: UUID
    public var status: LumaChatTaskState
    public var accepted: Bool

    public init(
        requestID: UUID,
        taskID: UUID,
        status: LumaChatTaskState,
        accepted: Bool = true
    ) {
        self.requestID = requestID
        self.taskID = taskID
        self.status = status
        self.accepted = accepted
    }
}

public struct LumaChatTaskList: Codable, Equatable, Sendable {
    public var tasks: [LumaChatTaskSnapshot]

    public init(tasks: [LumaChatTaskSnapshot]) {
        self.tasks = tasks
    }
}

public struct LumaChatTaskDiff: Codable, Equatable, Sendable {
    public var taskID: UUID
    public var diff: String
    public var baseFingerprint: String?
    public var receipt: LumaChatJSONValue?
    public var changedPaths: [String]
    public var truncated: Bool
    public var generatedAt: Date

    public init(
        taskID: UUID,
        diff: String,
        baseFingerprint: String? = nil,
        receipt: LumaChatJSONValue? = nil,
        changedPaths: [String] = [],
        truncated: Bool = false,
        generatedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.diff = diff
        self.baseFingerprint = baseFingerprint
        self.receipt = receipt
        self.changedPaths = changedPaths
        self.truncated = truncated
        self.generatedAt = generatedAt
    }
}

public enum LumaChatJSONValue: Codable, Equatable, Sendable {
    case object([String: LumaChatJSONValue])
    case array([LumaChatJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LumaChatJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LumaChatJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum LumaChatTaskEventKind: String, Codable, CaseIterable, Sendable {
    case snapshot
    case messageDelta = "message_delta"
    case reasoningDelta = "reasoning_delta"
    case step
    case approvalRequired = "approval_required"
    case diffChanged = "diff_changed"
    case stateChanged = "state_changed"
    case warning
    case error
    case heartbeat
}

public struct LumaChatTaskEvent: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var taskID: UUID
    public var kind: LumaChatTaskEventKind
    public var timestamp: Date
    public var payload: LumaChatJSONValue

    public init(
        sequence: UInt64,
        taskID: UUID,
        kind: LumaChatTaskEventKind,
        timestamp: Date = Date(),
        payload: LumaChatJSONValue = .null
    ) {
        self.sequence = sequence
        self.taskID = taskID
        self.kind = kind
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct LumaChatHealth: Codable, Equatable, Sendable {
    public var status: String
    public var apiVersion: String
    public var serverID: UUID
    public var startedAt: Date

    public init(status: String, apiVersion: String, serverID: UUID, startedAt: Date) {
        self.status = status
        self.apiVersion = apiVersion
        self.serverID = serverID
        self.startedAt = startedAt
    }
}

public enum LumaChatAPIErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case forbidden
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case unsupportedMediaType = "unsupported_media_type"
    case payloadTooLarge = "payload_too_large"
    case conflict
    case invalidState = "invalid_state"
    case backendUnavailable = "backend_unavailable"
    case approvalNotFound = "approval_not_found"
    case eventCursorExpired = "event_cursor_expired"
    case internalError = "internal_error"
}

public struct LumaChatAPIErrorBody: Codable, Equatable, Sendable {
    public var code: LumaChatAPIErrorCode
    public var message: String
    public var requestID: String?

    public init(code: LumaChatAPIErrorCode, message: String, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }
}

public struct LumaChatAPIErrorEnvelope: Codable, Equatable, Sendable {
    public var error: LumaChatAPIErrorBody

    public init(error: LumaChatAPIErrorBody) {
        self.error = error
    }
}
