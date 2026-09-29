import Foundation
import XCTest
@testable import LumaChat

private actor SteerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor SteerProvider: AgentModelProvider {
    nonisolated let id = "steer-test"
    private let firstEntered: SteerGate
    private let firstRelease: SteerGate?
    private var responses: [AgentModelResponse]
    private var requests: [[AgentMessage]] = []

    init(
        responses: [AgentModelResponse],
        firstEntered: SteerGate,
        firstRelease: SteerGate? = nil
    ) {
        self.responses = responses
        self.firstEntered = firstEntered
        self.firstRelease = firstRelease
    }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        .init(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: true,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 16_384,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        requests.append(request.messages)
        if requests.count == 1 {
            await firstEntered.open()
            if let firstRelease { await firstRelease.wait() }
        }
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }

    func capturedRequests() -> [[AgentMessage]] { requests }
}

private struct SteerBlockingTool: AgentTool {
    let entered: SteerGate
    let release: SteerGate
    let id = "steer-test.blocking"
    let name = "steer_blocking_tool"
    let displayName = "Blocking test tool"
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = false
    var description: String { "A test tool that waits until released." }
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await entered.open()
        await release.wait()
        return AgentToolResult(content: "tool completed")
    }
}

@MainActor
final class AgentSteerTests: XCTestCase {
    func testSteerAcceptedDuringRunPreflightReachesFirstModelTurn() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = SteerGate()
        let provider = SteerProvider(
            responses: [finalResponse("Done")],
            firstEntered: entered
        )
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

        let acceptedBeforeRun = await runtime.steer("Check the edge case before answering")
        XCTAssertTrue(acceptedBeforeRun)
        let result = await runtime.run(
            session: session,
            userRequest: "Original request",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        let requests = await provider.capturedRequests()
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].contains {
            $0.role == .user && $0.content == "Check the edge case before answering"
        })
        let acceptedAfterRun = await runtime.steer("After completion")
        XCTAssertFalse(acceptedAfterRun)
    }

    func testPreRunSteerDoesNotLeakIntoLaterRunAfterStopOrPause() async throws {
        for stopRun in [false, true] {
            let (root, session) = try makeSession()
            defer { try? FileManager.default.removeItem(at: root) }
            let entered = SteerGate()
            let provider = SteerProvider(
                responses: [finalResponse("Done")],
                firstEntered: entered
            )
            let registry = ToolRegistry()
            let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

            let acceptedBeforeCancellation = await runtime.steer("Instruction for cancelled preflight")
            XCTAssertTrue(acceptedBeforeCancellation)
            if stopRun {
                let result = await runtime.stop()
                XCTAssertNil(result)
            } else {
                let result = await runtime.pause()
                XCTAssertNil(result)
            }
            let acceptedAfterCancellation = await runtime.steer("No preflight owner")
            XCTAssertFalse(acceptedAfterCancellation)

            let result = await runtime.run(
                session: session,
                userRequest: "New run",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )
            let requests = await provider.capturedRequests()
            XCTAssertEqual(result.state, .completed)
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(requests[0].contains {
                $0.content == "Instruction for cancelled preflight"
            })
        }
    }

    func testCancelledPreflightCannotStartRuntimeOrCarrySteerIntoRetry() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = SteerGate()
        let provider = SteerProvider(
            responses: [finalResponse("Done")],
            firstEntered: entered
        )
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let acceptedBeforeCancellation = await runtime.steer("Cancelled preflight instruction")
        XCTAssertTrue(acceptedBeforeCancellation)

        let gate = SteerGate()
        let cancelledPreflight = Task {
            await gate.wait()
            return await runtime.run(
                session: session,
                userRequest: "Cancelled request",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )
        }
        cancelledPreflight.cancel()
        await gate.open()
        let cancelledResult = await cancelledPreflight.value
        XCTAssertEqual(cancelledResult.messages, session.messages)
        let cancelledRequests = await provider.capturedRequests()
        XCTAssertTrue(cancelledRequests.isEmpty)

        let retry = await runtime.run(
            session: session,
            userRequest: "New request",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        let requests = await provider.capturedRequests()
        XCTAssertEqual(retry.state, .completed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests[0].contains {
            $0.content == "Cancelled preflight instruction"
        })
    }

    func testFollowUpPreferenceDefaultsAndPersists() throws {
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.followUpBehavior, .steer)
        var changed = legacy
        changed.followUpBehavior = .queue
        let restored = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(changed)
        )
        XCTAssertEqual(restored.followUpBehavior, .queue)
    }

    func testSteerDuringModelResponseRunsInSameInvocation() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = SteerGate()
        let release = SteerGate()
        let provider = SteerProvider(
            responses: [finalResponse("First answer"), finalResponse("Adjusted answer")],
            firstEntered: entered,
            firstRelease: release
        )
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

        let run = Task {
            await runtime.run(
                session: session,
                userRequest: "Original request",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )
        }
        await entered.wait()
        let accepted = await runtime.steer("Change direction now")
        XCTAssertTrue(accepted)
        await release.open()

        let result = await run.value
        let requests = await provider.capturedRequests()
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[0].contains { $0.content == "Change direction now" })
        XCTAssertTrue(requests[1].contains {
            $0.role == .user && $0.content == "Change direction now"
        })
        XCTAssertEqual(result.messages.last(where: { $0.role == .assistant })?.content,
                       "Adjusted answer")
        let lateAccepted = await runtime.steer("Too late")
        XCTAssertFalse(lateAccepted)
    }

    func testSteerWaitsForInFlightToolAndPreservesResult() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerEntered = SteerGate()
        let toolEntered = SteerGate()
        let toolRelease = SteerGate()
        let registry = ToolRegistry()
        try await registry.register(SteerBlockingTool(entered: toolEntered, release: toolRelease))
        let provider = SteerProvider(
            responses: [
                .init(
                    content: "",
                    reasoningSummary: nil,
                    toolCalls: [.init(id: "steer-call", name: "steer_blocking_tool")],
                    finishReason: "tool_calls",
                    usage: nil
                ),
                finalResponse("Done after steer")
            ],
            firstEntered: providerEntered
        )
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

        let run = Task {
            await runtime.run(
                session: session,
                userRequest: "Use the tool",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )
        }
        await toolEntered.wait()
        let accepted = await runtime.steer("Include this change")
        XCTAssertTrue(accepted)
        await toolRelease.open()

        let result = await run.value
        let requests = await provider.capturedRequests()
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains { $0.role == .tool && $0.content == "tool completed" })
        XCTAssertTrue(requests[1].contains { $0.role == .user && $0.content == "Include this change" })
    }

    func testAcceptedSteerAtStepLimitRemainsResumable() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = SteerGate()
        let release = SteerGate()
        let provider = SteerProvider(
            responses: [finalResponse("Initial answer")],
            firstEntered: entered,
            firstRelease: release
        )
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        var settings = AgentSettings()
        settings.maxSteps = 1

        let run = Task {
            await runtime.run(
                session: session,
                userRequest: "Original request",
                provider: provider,
                settings: settings,
                approvalHandler: nil,
                eventHandler: { _ in }
            )
        }
        await entered.wait()
        let accepted = await runtime.steer("Keep going with this")
        XCTAssertTrue(accepted)
        await release.open()

        let result = await run.value
        XCTAssertEqual(result.state, .stepLimit)
        XCTAssertTrue(result.messages.contains {
            $0.role == .user && $0.content == "Keep going with this"
        })
    }

    func testSteerIsRejectedDuringCompletedEventBoundary() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let providerEntered = SteerGate()
        let finishedEntered = SteerGate()
        let finishedRelease = SteerGate()
        let provider = SteerProvider(
            responses: [finalResponse("Complete")],
            firstEntered: providerEntered
        )
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

        let run = Task {
            await runtime.run(
                session: session,
                userRequest: "Original request",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { event in
                    if case .finished = event {
                        await finishedEntered.open()
                        await finishedRelease.wait()
                    }
                }
            )
        }
        await finishedEntered.wait()
        let accepted = await runtime.steer("Too late")
        XCTAssertFalse(accepted)
        await finishedRelease.open()
        let result = await run.value
        XCTAssertEqual(result.state, .completed)
        XCTAssertFalse(result.messages.contains { $0.content == "Too late" })
    }

    func testMailboxCloseRejectsLateSteerWithoutLosingAcceptedMessage() async {
        let mailbox = AgentSteerMailbox()
        let accepted = await mailbox.enqueue("Pending instruction")
        XCTAssertTrue(accepted)
        await mailbox.close()
        let lateAccepted = await mailbox.enqueue("Late instruction")
        XCTAssertFalse(lateAccepted)
        let pending = await mailbox.closeAndDrain()
        XCTAssertEqual(pending, ["Pending instruction"])
    }

    private func finalResponse(_ content: String) -> AgentModelResponse {
        .init(content: content, reasoningSummary: nil, toolCalls: [], finishReason: "stop", usage: nil)
    }

    private func makeSession() throws -> (URL, AgentSession) {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-steer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var session = AgentSession(mode: .agent)
        session.workspace = AgentWorkspace(
            name: "steer-test",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        session.model = "mock-model"
        return (root, session)
    }
}
