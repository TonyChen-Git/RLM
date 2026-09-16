import Foundation
import LumaChatSDK
import XCTest
@testable import LumaChat

@MainActor
final class HeadlessAppServerTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef"

    func testConfigurationDefaultsToLoopbackAndRequiresExplicitRemoteOptIn() throws {
        let configuration = try LumaChatHeadlessServerConfiguration(bearerToken: token)
        XCTAssertEqual(configuration.bindHost, "127.0.0.1")
        XCTAssertEqual(configuration.port, 0)
        XCTAssertFalse(configuration.allowNonLoopback)
        XCTAssertEqual(configuration.requestIdleTimeoutSeconds, 30)
        XCTAssertEqual(configuration.sseHeartbeatIntervalSeconds, 15)
        XCTAssertEqual(configuration.connectionWriteTimeoutSeconds, 15)

        XCTAssertThrowsError(try LumaChatHeadlessServerConfiguration(
            bindHost: "0.0.0.0",
            bearerToken: token
        ))
        XCTAssertNoThrow(try LumaChatHeadlessServerConfiguration(
            bindHost: "0.0.0.0",
            bearerToken: token,
            allowNonLoopback: true
        ))
        XCTAssertThrowsError(try LumaChatHeadlessServerConfiguration(bearerToken: "short"))
        XCTAssertThrowsError(try LumaChatHeadlessServerConfiguration(
            bearerToken: String(repeating: "a", count: 31) + " "
        ))
        XCTAssertThrowsError(try LumaChatHeadlessServerConfiguration(
            bearerToken: token,
            requestIdleTimeoutSeconds: 0
        ))
    }

    func testAuthenticationHappensBeforeRuntimeAndErrorsAreVersionedJSON() async throws {
        let runtime = FakeHeadlessRuntime()
        let router = try makeRouter(runtime: runtime)
        let result = await router.handle(.init(
            method: "GET",
            target: "/v1/tasks",
            headers: [:]
        ))
        let response = try response(result)
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.headers["WWW-Authenticate"], "Bearer")
        XCTAssertEqual(response.headers["X-LumaChat-API-Version"], LumaChatAPIVersion.v1)
        let envelope = try decoder().decode(LumaChatAPIErrorEnvelope.self, from: response.body)
        XCTAssertEqual(envelope.error.code, .unauthorized)
        XCTAssertEqual(runtime.listCount, 0)
    }

    func testSwiftClientRejectsNonOriginURLsAndUnsafeBearerTokens() throws {
        XCTAssertThrowsError(try LumaChatClient(
            baseURL: URL(string: "http://127.0.0.1:32189/proxy")!,
            bearerToken: token
        ))
        XCTAssertThrowsError(try LumaChatClient(
            baseURL: URL(string: "http://127.0.0.1:32189")!,
            bearerToken: String(repeating: "a", count: 31) + " "
        ))
    }

    func testSwiftClientBoundsEncodedRequestsBeforeTransport() async throws {
        let client = try LumaChatClient(
            baseURL: URL(string: "http://127.0.0.1:32189")!,
            bearerToken: token,
            maximumJSONBytes: 1
        )
        do {
            _ = try await client.createTask(.init(
                workspacePath: "/Volumes/Work/Repository",
                backendID: "ollama",
                modelID: "model"
            ))
            XCTFail("Expected request bound failure")
        } catch let error as LumaChatClientError {
            XCTAssertEqual(error, .requestTooLarge(maximumBytes: 1))
        }
    }

    func testBearerSchemeIsCaseInsensitiveButCredentialIsExact() async throws {
        let runtime = FakeHeadlessRuntime()
        let router = try makeRouter(runtime: runtime)
        let accepted = await router.handle(.init(
            method: "GET",
            target: "/v1/tasks",
            headers: ["Authorization": "bearer \(token)"]
        ))
        XCTAssertEqual(try response(accepted).status, 200)

        let rejected = await router.handle(.init(
            method: "GET",
            target: "/v1/tasks",
            headers: ["Authorization": "Bearer \(token)x"]
        ))
        XCTAssertEqual(try response(rejected).status, 401)
        XCTAssertEqual(runtime.listCount, 1)
    }

    func testCreateUsesFlatExactBackendContractAndNeverFallsBack() async throws {
        let runtime = FakeHeadlessRuntime()
        let router = try makeRouter(runtime: runtime)
        let request = LumaChatTaskCreateRequest(
            requestID: UUID(),
            title: "Headless task",
            mode: .agent,
            workspacePath: "/Volumes/Work/Repository",
            backendID: "ollama/local",
            modelID: "qwen3.8:latest"
        )
        let result = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks",
            value: request
        ))
        let createdResponse = try response(result)
        XCTAssertEqual(createdResponse.status, 201)
        let created = try decoder().decode(LumaChatTaskSnapshot.self, from: createdResponse.body)
        XCTAssertEqual(created.backendID, "ollama/local")
        XCTAssertEqual(created.modelID, "qwen3.8:latest")
        XCTAssertEqual(runtime.lastCreate?.backendID, "ollama/local")
        XCTAssertEqual(runtime.lastCreate?.modelID, "qwen3.8:latest")

        let unavailable = LumaChatTaskCreateRequest(
            mode: .agent,
            workspacePath: "/Volumes/Work/Repository",
            backendID: "unavailable",
            modelID: "model"
        )
        let unavailableResult = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks",
            value: unavailable
        ))
        let unavailableResponse = try response(unavailableResult)
        XCTAssertEqual(unavailableResponse.status, 503)
        let error = try decoder().decode(
            LumaChatAPIErrorEnvelope.self,
            from: unavailableResponse.body
        )
        XCTAssertEqual(error.error.code, .backendUnavailable)
        XCTAssertEqual(runtime.fallbackAttempts, 0)
    }

    func testTaskMutationsAreExplicitlyTaskScoped() async throws {
        let runtime = FakeHeadlessRuntime()
        let router = try makeRouter(runtime: runtime)
        let taskID = runtime.snapshot.id

        let message = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks/\(taskID.uuidString)/messages",
            value: LumaChatMessageRequest(content: "Inspect the repository")
        ))
        XCTAssertEqual(try response(message).status, 202)

        let approvalID = UUID()
        let approval = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks/\(taskID.uuidString)/approve",
            value: LumaChatApprovalDecisionRequest(
                approvalID: approvalID,
                decision: .allowOnce
            )
        ))
        XCTAssertEqual(try response(approval).status, 202)

        let pause = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks/\(taskID.uuidString)/pause",
            value: LumaChatControlRequest()
        ))
        XCTAssertEqual(try response(pause).status, 202)

        let resume = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks/\(taskID.uuidString)/resume",
            value: LumaChatResumeRequest(content: "Continue from the durable state")
        ))
        XCTAssertEqual(try response(resume).status, 202)

        let stop = await router.handle(try jsonRequest(
            method: "POST",
            target: "/v1/tasks/\(taskID.uuidString)/stop",
            value: LumaChatControlRequest()
        ))
        XCTAssertEqual(try response(stop).status, 202)

        XCTAssertEqual(runtime.messageTaskID, taskID)
        XCTAssertEqual(runtime.approvalTaskID, taskID)
        XCTAssertEqual(runtime.approvalID, approvalID)
        XCTAssertEqual(runtime.pauseTaskID, taskID)
        XCTAssertEqual(runtime.resumeTaskID, taskID)
        XCTAssertEqual(runtime.stopTaskID, taskID)
    }

    func testStatusDiffAndTerminalResultRemainMachineReadable() async throws {
        let runtime = FakeHeadlessRuntime()
        let router = try makeRouter(runtime: runtime)
        let taskID = runtime.snapshot.id

        let statusResult = await router.handle(authorizedRequest(
            method: "GET",
            target: "/v1/tasks/\(taskID.uuidString)"
        ))
        let status = try decoder().decode(
            LumaChatTaskSnapshot.self,
            from: response(statusResult).body
        )
        XCTAssertEqual(status.result?.content, "Finished analysis")

        let diffResult = await router.handle(authorizedRequest(
            method: "GET",
            target: "/v1/tasks/\(taskID.uuidString)/diff"
        ))
        let diff = try decoder().decode(LumaChatTaskDiff.self, from: response(diffResult).body)
        XCTAssertEqual(diff.diff, "diff --git a/a b/a\n")
        XCTAssertEqual(diff.baseFingerprint, "abc123")
    }

    func testBoundedJSONAndUnsupportedMethodsFailBeforeRuntime() async throws {
        let runtime = FakeHeadlessRuntime()
        let configuration = try LumaChatHeadlessServerConfiguration(
            bearerToken: token,
            maximumJSONBytes: 1_024
        )
        let router = LumaChatHeadlessRequestRouter(runtime: runtime, configuration: configuration)
        let oversized = authorizedRequest(
            method: "POST",
            target: "/v1/tasks/\(runtime.snapshot.id.uuidString)/messages",
            body: Data(repeating: 0x61, count: 1_025),
            contentType: "application/json"
        )
        let oversizedResponse = try response(await router.handle(oversized))
        XCTAssertEqual(oversizedResponse.status, 413)

        let invalidMethod = try response(await router.handle(authorizedRequest(
            method: "DELETE",
            target: "/v1/tasks"
        )))
        XCTAssertEqual(invalidMethod.status, 405)
        XCTAssertEqual(invalidMethod.headers["Allow"], "GET, POST")
        XCTAssertNil(runtime.messageTaskID)
    }

    func testSyntheticHeaderEnvelopeIsBoundedBeforeRuntime() async throws {
        let runtime = FakeHeadlessRuntime()
        let configuration = try LumaChatHeadlessServerConfiguration(
            bearerToken: token,
            maximumHeaderBytes: 1_024
        )
        let router = LumaChatHeadlessRequestRouter(runtime: runtime, configuration: configuration)
        let result = await router.handle(.init(
            method: "GET",
            target: "/v1/tasks",
            headers: [
                "Authorization": "Bearer \(token)",
                "X-Padding": String(repeating: "a", count: 1_024)
            ]
        ))
        XCTAssertEqual(try response(result).status, 431)
        XCTAssertEqual(runtime.listCount, 0)
    }

    func testUnexpectedRuntimeErrorsAreRedacted() async throws {
        let runtime = FakeHeadlessRuntime()
        runtime.listError = NSError(
            domain: "secret /Users/example/private token=abc",
            code: 7
        )
        let router = try makeRouter(runtime: runtime)
        let result = await router.handle(authorizedRequest(method: "GET", target: "/v1/tasks"))
        let response = try response(result)
        XCTAssertEqual(response.status, 500)
        let envelope = try decoder().decode(LumaChatAPIErrorEnvelope.self, from: response.body)
        XCTAssertEqual(envelope.error.code, .internalError)
        XCTAssertEqual(envelope.error.message, "Internal App Server error.")
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("secret"))
    }

    func testSSEBrokerReplaysExclusiveCursorAndRejectsExpiredCursor() async throws {
        let runtime = FakeHeadlessRuntime()
        let taskID = runtime.snapshot.id
        _ = try await runtime.broker.publish(
            taskID: taskID,
            kind: .stateChanged,
            payload: .string("running")
        )
        _ = try await runtime.broker.publish(
            taskID: taskID,
            kind: .messageDelta,
            payload: .string("hello")
        )
        let router = try makeRouter(runtime: runtime)
        let route = await router.handle(authorizedRequest(
            method: "GET",
            target: "/v1/tasks/\(taskID.uuidString)/events?after=1"
        ))
        guard case .events(let headers, let stream) = route else {
            return XCTFail("Expected SSE route")
        }
        XCTAssertEqual(headers["Content-Type"], "text/event-stream; charset=utf-8")
        var iterator = stream.makeAsyncIterator()
        let replayed = try await iterator.next()
        XCTAssertEqual(replayed?.sequence, 2)
        XCTAssertEqual(replayed?.payload, .string("hello"))

        let smallBroker = LumaChatHeadlessEventBroker(maximumRetainedEvents: 1)
        _ = try await smallBroker.publish(taskID: taskID, kind: .snapshot, payload: .null)
        _ = try await smallBroker.publish(taskID: taskID, kind: .step, payload: .null)
        do {
            _ = try await smallBroker.stream(taskID: taskID, afterSequence: 0)
            XCTFail("Expected expired cursor")
        } catch let error as LumaChatHeadlessRuntimeFailure {
            XCTAssertEqual(error.code, .eventCursorExpired)
        }
    }

    func testSSEBrokerPreservesSequenceWhenReplayIsCleared() async throws {
        let broker = LumaChatHeadlessEventBroker()
        let taskID = UUID()
        _ = try await broker.publish(taskID: taskID, kind: .snapshot, payload: .null)
        await broker.removeRetainedEvents(taskID: taskID)
        let next = try await broker.publish(taskID: taskID, kind: .step, payload: .null)
        XCTAssertEqual(next.sequence, 2)
    }

    func testLateSSEEventDoesNotReopenTerminalStream() async throws {
        let broker = LumaChatHeadlessEventBroker()
        let taskID = UUID()
        _ = try await broker.publish(taskID: taskID, kind: .snapshot, payload: .null)
        await broker.finish(taskID: taskID)
        _ = try await broker.publish(taskID: taskID, kind: .warning, payload: .null)

        let stream = try await broker.stream(taskID: taskID, afterSequence: 0)
        var iterator = stream.makeAsyncIterator()
        XCTAssertEqual(try await iterator.next()?.sequence, 1)
        XCTAssertEqual(try await iterator.next()?.sequence, 2)
        XCTAssertNil(try await iterator.next())
    }

    private func makeRouter(
        runtime: FakeHeadlessRuntime
    ) throws -> LumaChatHeadlessRequestRouter {
        LumaChatHeadlessRequestRouter(
            runtime: runtime,
            configuration: try LumaChatHeadlessServerConfiguration(bearerToken: token)
        )
    }

    private func authorizedRequest(
        method: String,
        target: String,
        body: Data = Data(),
        contentType: String? = nil
    ) -> LumaChatHeadlessHTTPRequest {
        var headers = ["Authorization": "Bearer \(token)"]
        if let contentType { headers["Content-Type"] = contentType }
        return .init(method: method, target: target, headers: headers, body: body)
    }

    private func jsonRequest<Value: Encodable>(
        method: String,
        target: String,
        value: Value
    ) throws -> LumaChatHeadlessHTTPRequest {
        authorizedRequest(
            method: method,
            target: target,
            body: try encoder().encode(value),
            contentType: "application/json"
        )
    }

    private func response(
        _ result: LumaChatHeadlessRouteResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LumaChatHeadlessHTTPResponse {
        guard case .response(let response) = result else {
            XCTFail("Expected JSON response", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return response
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
private final class FakeHeadlessRuntime: LumaChatHeadlessRuntimeFacade {
    let broker = LumaChatHeadlessEventBroker()
    private(set) var listCount = 0
    private(set) var lastCreate: LumaChatTaskCreateRequest?
    private(set) var fallbackAttempts = 0
    private(set) var messageTaskID: UUID?
    private(set) var approvalTaskID: UUID?
    private(set) var approvalID: UUID?
    private(set) var pauseTaskID: UUID?
    private(set) var resumeTaskID: UUID?
    private(set) var stopTaskID: UUID?
    var listError: Error?

    var snapshot = LumaChatTaskSnapshot(
        id: UUID(),
        title: "Task",
        mode: .agent,
        status: .completed,
        backendID: "ollama/local",
        modelID: "qwen3.8:latest",
        workspacePath: "/Volumes/Work/Repository",
        result: .init(content: "Finished analysis"),
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    func listTasks() async throws -> [LumaChatTaskSnapshot] {
        listCount += 1
        if let listError { throw listError }
        return [snapshot]
    }

    func createTask(_ request: LumaChatTaskCreateRequest) async throws -> LumaChatTaskSnapshot {
        lastCreate = request
        if request.backendID == "unavailable" {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable()
        }
        snapshot.backendID = request.backendID
        snapshot.modelID = request.modelID
        snapshot.workspacePath = request.workspacePath
        snapshot.mode = request.mode
        return snapshot
    }

    func task(id: UUID) async throws -> LumaChatTaskSnapshot {
        guard id == snapshot.id else { throw LumaChatHeadlessRuntimeFailure.notFound() }
        return snapshot
    }

    func sendMessage(
        taskID: UUID,
        request: LumaChatMessageRequest
    ) async throws -> LumaChatAcceptedOperation {
        messageTaskID = taskID
        return accepted(taskID: taskID, requestID: request.requestID)
    }

    func events(
        taskID: UUID,
        afterSequence: UInt64?
    ) async throws -> AsyncThrowingStream<LumaChatTaskEvent, Error> {
        guard taskID == snapshot.id else { throw LumaChatHeadlessRuntimeFailure.notFound() }
        return try await broker.stream(taskID: taskID, afterSequence: afterSequence)
    }

    func approve(
        taskID: UUID,
        request: LumaChatApprovalDecisionRequest
    ) async throws -> LumaChatAcceptedOperation {
        approvalTaskID = taskID
        approvalID = request.approvalID
        return accepted(taskID: taskID, requestID: request.requestID)
    }

    func pause(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation {
        pauseTaskID = taskID
        return accepted(taskID: taskID, requestID: request.requestID)
    }

    func resume(
        taskID: UUID,
        request: LumaChatResumeRequest
    ) async throws -> LumaChatAcceptedOperation {
        resumeTaskID = taskID
        return accepted(taskID: taskID, requestID: request.requestID)
    }

    func stop(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation {
        stopTaskID = taskID
        return accepted(taskID: taskID, requestID: request.requestID)
    }

    func diff(taskID: UUID) async throws -> LumaChatTaskDiff {
        guard taskID == snapshot.id else { throw LumaChatHeadlessRuntimeFailure.notFound() }
        return .init(
            taskID: taskID,
            diff: "diff --git a/a b/a\n",
            baseFingerprint: "abc123",
            changedPaths: ["a"]
        )
    }

    private func accepted(taskID: UUID, requestID: UUID?) -> LumaChatAcceptedOperation {
        LumaChatAcceptedOperation(
            requestID: requestID ?? UUID(),
            taskID: taskID,
            status: .running
        )
    }
}
