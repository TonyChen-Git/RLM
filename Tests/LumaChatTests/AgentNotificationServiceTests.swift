import Foundation
import XCTest

@testable import LumaChat

private enum AgentNotificationFakeError: Error, Equatable {
    case deliveryFailed
}

private actor RecordingAgentNotificationBackend: AgentNotificationBackend {
    private var currentStatus: AgentNotificationAuthorizationStatus
    private var authorizationResult: AgentNotificationAuthorizationStatus
    private var authorizationRequests = 0
    private var statusReads = 0
    private var requests: [AgentNotificationRequest] = []
    private var interactionHandler:
        (@Sendable (AgentNotificationInteraction) async -> Void)?
    private var shouldFailNextDelivery = false

    init(
        status: AgentNotificationAuthorizationStatus,
        authorizationResult: AgentNotificationAuthorizationStatus = .authorized
    ) {
        currentStatus = status
        self.authorizationResult = authorizationResult
    }

    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        statusReads += 1
        return currentStatus
    }

    func requestAuthorization() async -> AgentNotificationAuthorizationStatus {
        authorizationRequests += 1
        currentStatus = authorizationResult
        return currentStatus
    }

    func deliver(_ request: AgentNotificationRequest) async throws {
        if shouldFailNextDelivery {
            shouldFailNextDelivery = false
            throw AgentNotificationFakeError.deliveryFailed
        }
        requests.append(request)
    }

    func setInteractionHandler(
        _ handler: (@Sendable (AgentNotificationInteraction) async -> Void)?
    ) async {
        interactionHandler = handler
    }

    func capturedRequests() -> [AgentNotificationRequest] {
        requests
    }

    func authorizationRequestCount() -> Int {
        authorizationRequests
    }

    func authorizationStatusReadCount() -> Int {
        statusReads
    }

    func failNextDelivery() {
        shouldFailNextDelivery = true
    }

    func simulateInteraction(
        request: AgentNotificationRequest,
        actionIdentifier: String = "fixture.default-action"
    ) async {
        await simulateInteraction(AgentNotificationInteraction(
            requestIdentifier: request.identifier,
            actionIdentifier: actionIdentifier,
            userInfo: request.userInfo
        ))
    }

    func simulateInteraction(_ interaction: AgentNotificationInteraction) async {
        if let interactionHandler {
            await interactionHandler(interaction)
        }
    }
}

private actor RecordingAgentNotificationRouter: AgentNotificationRouting {
    private var routes: [AgentNotificationRoute] = []

    func route(_ notification: AgentNotificationRoute) async {
        routes.append(notification)
    }

    func capturedRoutes() -> [AgentNotificationRoute] {
        routes
    }
}

private final class AgentNotificationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

final class AgentNotificationServiceTests: XCTestCase {
    private let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testEverySupportedEventProducesTypedBoundedRequestMetadata() async throws {
        let backend = RecordingAgentNotificationBackend(status: .authorized)
        let service = AgentNotificationService(backend: backend)
        let events: [AgentNotificationEvent] = [
            .taskCompleted(
                taskID: taskID,
                taskTitle: "Compile docs",
                body: "The Task completed.",
                metadata: ["fixture": "task"]
            ),
            .approvalRequired(
                taskID: taskID,
                taskTitle: "Deploy preview",
                body: "Review the pending command.",
                metadata: ["fixture": "approval"]
            ),
            .automationCompleted(
                taskID: taskID,
                automationTitle: "Nightly checks",
                body: "The automation completed.",
                metadata: ["fixture": "automation-completed"]
            ),
            .automationFailed(
                taskID: taskID,
                automationTitle: "Nightly checks",
                body: "The automation failed.",
                metadata: ["fixture": "automation-failed"]
            ),
            .subagentBlocked(
                taskID: taskID,
                subagentName: "researcher",
                body: "The subagent needs input.",
                metadata: ["fixture": "subagent"]
            ),
            .remoteAgentWaiting(
                taskID: taskID,
                remoteName: "build-host",
                body: "The Remote Agent is waiting.",
                metadata: ["fixture": "remote"]
            )
        ]

        for event in events {
            let result = try await service.post(event)
            guard case .scheduled = result else {
                return XCTFail("Expected every distinct event to be scheduled, got \(result)")
            }
        }

        let requests = await backend.capturedRequests()
        XCTAssertEqual(requests.map(\.kind), AgentNotificationKind.allCases)
        XCTAssertEqual(requests.count, events.count)
        let expectedDeepLink = AgentNotificationRoute.taskDeepLink(for: taskID)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.taskID, taskID)
            XCTAssertEqual(request.deepLink, expectedDeepLink)
            XCTAssertEqual(request.threadIdentifier, taskID.uuidString.lowercased())
            XCTAssertEqual(request.categoryIdentifier, request.kind.categoryIdentifier)
            XCTAssertEqual(request.metadata, events[index].metadata)
            XCTAssertTrue(request.userInfo.values.contains(request.kind.rawValue))
            XCTAssertTrue(request.userInfo.values.contains(taskID.uuidString.lowercased()))
            XCTAssertTrue(request.userInfo.values.contains(expectedDeepLink.absoluteString))
        }
    }

    func testPostingNeverPromptsAndAuthorizationRequestIsExplicit() async throws {
        let backend = RecordingAgentNotificationBackend(
            status: .notDetermined,
            authorizationResult: .authorized
        )
        let service = AgentNotificationService(backend: backend)

        let result = try await service.post(.taskCompleted(
            taskID: taskID,
            body: "Finished."
        ))
        XCTAssertEqual(result, .notAuthorized(.notDetermined))
        let promptCountBeforeRequest = await backend.authorizationRequestCount()
        let requestsBeforeAuthorization = await backend.capturedRequests()
        XCTAssertEqual(promptCountBeforeRequest, 0)
        XCTAssertTrue(requestsBeforeAuthorization.isEmpty)

        let authorized = try await service.requestAuthorization()
        XCTAssertEqual(authorized, .authorized)
        let promptCountAfterRequest = await backend.authorizationRequestCount()
        XCTAssertEqual(promptCountAfterRequest, 1)

        let scheduled = try await service.post(.taskCompleted(
            taskID: taskID,
            body: "Finished."
        ))
        guard case .scheduled = scheduled else {
            return XCTFail("Expected delivery after explicit authorization")
        }
        let requestsAfterAuthorization = await backend.capturedRequests()
        XCTAssertEqual(requestsAfterAuthorization.count, 1)
    }

    func testNotificationClickRoutesTypedTaskAndDeepLinkMetadata() async throws {
        let backend = RecordingAgentNotificationBackend(status: .authorized)
        let router = RecordingAgentNotificationRouter()
        let service = AgentNotificationService(backend: backend, router: router)
        let deepLink = URL(string: "lumachat://task/\(taskID.uuidString.lowercased())?pane=approval")!
        let event = AgentNotificationEvent.approvalRequired(
            taskID: taskID,
            body: "Approve the command.",
            deepLink: deepLink,
            metadata: ["approval_id": "approval-7"]
        )

        _ = try await service.post(event)
        let requests = await backend.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        await backend.simulateInteraction(
            request: request,
            actionIdentifier: "fixture.open"
        )

        var routes = await router.capturedRoutes()
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].requestIdentifier, request.identifier)
        XCTAssertEqual(routes[0].actionIdentifier, "fixture.open")
        XCTAssertEqual(routes[0].kind, .approvalRequired)
        XCTAssertEqual(routes[0].taskID, taskID)
        XCTAssertEqual(routes[0].deepLink, deepLink)
        XCTAssertEqual(routes[0].metadata, ["approval_id": "approval-7"])

        await backend.simulateInteraction(AgentNotificationInteraction(
            requestIdentifier: "forged",
            actionIdentifier: "fixture.open",
            userInfo: ["untrusted": "payload"]
        ))
        routes = await router.capturedRoutes()
        XCTAssertEqual(routes.count, 1)

        await service.stopClickRouting()
        await backend.simulateInteraction(request: request)
        routes = await router.capturedRoutes()
        XCTAssertEqual(routes.count, 1)
    }

    func testDeduplicationWindowExpiresAndRecentStateIsBounded() async throws {
        let backend = RecordingAgentNotificationBackend(status: .authorized)
        let clock = AgentNotificationTestClock(Date(timeIntervalSince1970: 10_000))
        let policy = AgentNotificationPolicy(
            deduplicationWindow: 10,
            maximumRecentDeliveries: 2
        )
        let service = AgentNotificationService(
            backend: backend,
            policy: policy,
            clock: { clock.now() }
        )
        let event = AgentNotificationEvent.taskCompleted(
            taskID: taskID,
            body: "Finished.",
            deduplicationKey: "task-1-run-1"
        )

        let first = try await service.post(event)
        let duplicate = try await service.post(event)
        guard case .scheduled(let firstIdentifier) = first else {
            return XCTFail("Expected first delivery")
        }
        XCTAssertEqual(duplicate, .duplicate(originalIdentifier: firstIdentifier))
        var captured = await backend.capturedRequests()
        XCTAssertEqual(captured.count, 1)

        clock.advance(by: 10)
        let afterExpiry = try await service.post(event)
        guard case .scheduled = afterExpiry else {
            return XCTFail("Expected delivery at the end of the deduplication window")
        }
        captured = await backend.capturedRequests()
        XCTAssertEqual(captured.count, 2)

        _ = try await service.post(.automationCompleted(
            body: "B",
            deduplicationKey: "B"
        ))
        _ = try await service.post(.automationCompleted(
            body: "C",
            deduplicationKey: "C"
        ))
        let diagnostics = await service.diagnostics()
        XCTAssertEqual(diagnostics.recentDeliveryCount, 2)
        XCTAssertEqual(diagnostics.maximumRecentDeliveries, 2)

        let evicted = try await service.post(.automationCompleted(
            body: "Finished.",
            deduplicationKey: "task-1-run-1"
        ))
        guard case .scheduled = evicted else {
            return XCTFail("Expected the evicted key to be deliverable")
        }
    }

    func testFailedBackendDeliveryIsRetryableAndDoesNotPoisonDedupe() async throws {
        let backend = RecordingAgentNotificationBackend(status: .authorized)
        let service = AgentNotificationService(backend: backend)
        let event = AgentNotificationEvent.automationFailed(
            body: "The run failed.",
            deduplicationKey: "automation-run-4"
        )
        await backend.failNextDelivery()

        do {
            _ = try await service.post(event)
            XCTFail("Expected the fake backend failure")
        } catch {
            XCTAssertEqual(error as? AgentNotificationFakeError, .deliveryFailed)
        }

        let retry = try await service.post(event)
        guard case .scheduled = retry else {
            return XCTFail("Expected retry after backend failure")
        }
        let requests = await backend.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testPayloadBoundsFailBeforeTheBackendIsInvoked() async throws {
        let backend = RecordingAgentNotificationBackend(status: .authorized)
        let policy = AgentNotificationPolicy(
            maximumTitleBytes: 8,
            maximumMetadataEntries: 1,
            maximumMetadataValueBytes: 4
        )
        let service = AgentNotificationService(backend: backend, policy: policy)

        do {
            _ = try await service.post(AgentNotificationEvent(
                kind: .taskCompleted,
                title: "123456789",
                body: "Done"
            ))
            XCTFail("Expected title bound")
        } catch {
            XCTAssertEqual(
                error as? AgentNotificationServiceError,
                .titleTooLarge(8)
            )
        }

        do {
            _ = try await service.post(AgentNotificationEvent(
                kind: .automationCompleted,
                title: "Auto",
                body: "Done",
                metadata: ["a": "1", "b": "2"]
            ))
            XCTFail("Expected metadata entry bound")
        } catch {
            XCTAssertEqual(
                error as? AgentNotificationServiceError,
                .tooManyMetadataEntries(1)
            )
        }

        do {
            _ = try await service.post(AgentNotificationEvent(
                kind: .remoteAgentWaiting,
                title: "Remote",
                body: "Done",
                taskID: taskID,
                deepLink: URL(string: "https://example.invalid/task")!
            ))
            XCTFail("Expected external deep-link scheme refusal")
        } catch {
            XCTAssertEqual(
                error as? AgentNotificationServiceError,
                .unsupportedDeepLinkScheme("https")
            )
        }

        let requests = await backend.capturedRequests()
        let statusReads = await backend.authorizationStatusReadCount()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(statusReads, 0)
    }
}
