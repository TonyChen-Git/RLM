import Foundation
import LumaChatSDK

/// The only bridge from the HTTP surface into LumaChat's durable Agent host.
///
/// A production adapter must delegate to the same persistence, runtime,
/// approval continuations, and diff services used by the app. In particular it
/// must not select a UI task first, instantiate a second Agent loop, or replace
/// an unavailable `backendID` with another provider (including a cloud one).
@MainActor
protocol LumaChatHeadlessRuntimeFacade: AnyObject, Sendable {
    func listTasks() async throws -> [LumaChatTaskSnapshot]
    func createTask(_ request: LumaChatTaskCreateRequest) async throws -> LumaChatTaskSnapshot
    func task(id: UUID) async throws -> LumaChatTaskSnapshot
    func sendMessage(
        taskID: UUID,
        request: LumaChatMessageRequest
    ) async throws -> LumaChatAcceptedOperation
    func events(
        taskID: UUID,
        afterSequence: UInt64?
    ) async throws -> AsyncThrowingStream<LumaChatTaskEvent, Error>
    func approve(
        taskID: UUID,
        request: LumaChatApprovalDecisionRequest
    ) async throws -> LumaChatAcceptedOperation
    func pause(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation
    func resume(
        taskID: UUID,
        request: LumaChatResumeRequest
    ) async throws -> LumaChatAcceptedOperation
    func stop(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation
    func diff(taskID: UUID) async throws -> LumaChatTaskDiff
}

/// Expected, user-safe failures crossing the runtime/HTTP boundary. Unknown
/// errors are deliberately collapsed to a generic 500 response by the router
/// so filesystem paths, command output, and provider secrets cannot leak.
struct LumaChatHeadlessRuntimeFailure: LocalizedError, Equatable, Sendable {
    let status: Int
    let code: LumaChatAPIErrorCode
    let message: String

    var errorDescription: String? { message }

    static func notFound(_ message: String = "Task not found.") -> Self {
        .init(status: 404, code: .notFound, message: message)
    }

    static func conflict(_ message: String) -> Self {
        .init(status: 409, code: .conflict, message: message)
    }

    static func invalidState(_ message: String) -> Self {
        .init(status: 409, code: .invalidState, message: message)
    }

    static func backendUnavailable(_ message: String = "Selected backend is unavailable.") -> Self {
        .init(status: 503, code: .backendUnavailable, message: message)
    }

    static func approvalNotFound(_ message: String = "Pending approval not found.") -> Self {
        .init(status: 404, code: .approvalNotFound, message: message)
    }

    static func eventCursorExpired(_ message: String = "Event cursor is no longer available.") -> Self {
        .init(status: 409, code: .eventCursorExpired, message: message)
    }
}
