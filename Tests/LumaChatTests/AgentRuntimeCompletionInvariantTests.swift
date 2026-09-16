import Foundation
import XCTest
@testable import LumaChat

private actor CompletionInvariantProvider: AgentModelProvider {
    nonisolated let id = "completion-invariant"
    private let modelCapabilities: ModelCapabilities
    private var responses: [AgentModelResponse]
    private var requests: [AgentModelRequest] = []

    init(
        contextWindow: Int = 8_192,
        maxOutputTokens: Int = 1_024,
        responses: [AgentModelResponse]
    ) {
        modelCapabilities = ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens
        )
        self.responses = responses
    }

    func capabilities(for model: String) async -> ModelCapabilities {
        modelCapabilities
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }

    func capturedRequests() -> [AgentModelRequest] { requests }
}

private struct CompletionSchemaTool: AgentTool {
    let description: String
    let id = "test.completion-schema"
    let name = "completion_schema_probe"
    let displayName = "Completion Schema Probe"
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = false
    var inputSchema: JSONValue {
        .objectSchema(
            properties: [
                "value": .stringSchema(description: description)
            ]
        )
    }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        AgentToolResult(content: "unused")
    }
}

final class AgentRuntimeCompletionInvariantTests: XCTestCase {
    func testLengthAndMaxTokensPersistPartialAssistantAndContinueUntilNormalEnd() async throws {
        let fixture = try makeFixture(label: "continuation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = CompletionInvariantProvider(
            responses: [
                response(content: "Partial one", finishReason: "length"),
                response(content: "Partial two", finishReason: "max_tokens"),
                response(content: "Final continuation", finishReason: "end_turn")
            ]
        )

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Produce a long answer",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.messages.filter { $0.role == .assistant }.map(\.content),
            ["Partial one", "Partial two", "Final continuation"]
        )
        XCTAssertFalse(result.messages.contains { $0.name == "luma-agent-output-continuation" })
        let requests = await provider.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[0].messages.contains { $0.name == "luma-agent-output-continuation" })
        XCTAssertTrue(requests[1].messages.contains { $0.name == "luma-agent-output-continuation" })
        XCTAssertTrue(requests[2].messages.contains { $0.name == "luma-agent-output-continuation" })
    }

    func testOutputLimitAtStepCeilingIsNotMarkedCompletedAndRemainsResumable() async throws {
        let fixture = try makeFixture(label: "continuation-step-limit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = CompletionInvariantProvider(
            responses: [response(content: "Still partial", finishReason: "length")]
        )
        var settings = AgentSettings()
        settings.maxSteps = 1

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Produce a long answer",
            provider: provider,
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        XCTAssertEqual(result.messages.last { $0.role == .assistant }?.content, "Still partial")
        XCTAssertTrue(result.messages.contains { $0.name == "luma-agent-output-continuation" })
        XCTAssertFalse(result.steps.contains { $0.kind == .completed })
    }

    func testStopEndTurnAndNilRemainNormalCompletionReasons() async throws {
        let reasons: [String?] = ["stop", "end_turn", nil]
        for (index, reason) in reasons.enumerated() {
            let fixture = try makeFixture(label: "normal-\(index)")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let provider = CompletionInvariantProvider(
                responses: [response(content: "Done \(index)", finishReason: reason)]
            )

            let result = await fixture.runtime.run(
                session: fixture.session,
                userRequest: "Finish",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )

            XCTAssertEqual(result.state, .completed, "reason: \(reason ?? "nil")")
        }
    }

    func testAbnormalAndToolFinishReasonsWithoutCallsFailVisible() async throws {
        let reasons = ["content_filter", "tool_calls", "tool_use", "provider_error"]
        for reason in reasons {
            let fixture = try makeFixture(label: "abnormal-\(reason)")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let provider = CompletionInvariantProvider(
                responses: [response(content: "Not a valid final", finishReason: reason)]
            )

            let result = await fixture.runtime.run(
                session: fixture.session,
                userRequest: "Finish",
                provider: provider,
                settings: AgentSettings(),
                approvalHandler: nil,
                eventHandler: { _ in }
            )

            XCTAssertEqual(result.state, .failed, "reason: \(reason)")
            XCTAssertTrue(result.lastError?.contains(reason) == true, result.lastError ?? "")
            XCTAssertFalse(result.steps.contains { $0.kind == .completed })
        }
    }

    func testOversizedToolSchemaFailsBeforeAnyProviderRequest() async throws {
        let registry = ToolRegistry()
        try await registry.register(
            CompletionSchemaTool(description: String(repeating: "schema ", count: 4_000))
        )
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let root = try makeWorkspaceRoot(label: "oversized-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let provider = CompletionInvariantProvider(
            contextWindow: 1_024,
            maxOutputTokens: 512,
            responses: [response(content: "Must not be called", finishReason: "stop")]
        )

        let result = await runtime.run(
            session: session,
            userRequest: "Use tools",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.lastError?.contains("definitions/schema") == true, result.lastError ?? "")
        let requests = await provider.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPreparedRequestCountsToolDefinitionsAndNeverExceedsContextWindow() async throws {
        let registry = ToolRegistry()
        try await registry.register(
            CompletionSchemaTool(description: String(repeating: "bounded schema ", count: 24))
        )
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let root = try makeWorkspaceRoot(label: "bounded-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(root: root)
        let provider = CompletionInvariantProvider(
            contextWindow: 2_048,
            maxOutputTokens: 1_024,
            responses: [response(content: "Done", finishReason: "stop")]
        )

        let result = await runtime.run(
            session: session,
            userRequest: String(repeating: "Inspect safely. ", count: 200),
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let requests = await provider.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        let manager = ContextManager()
        let estimatedTotal = manager.estimatedTokens(request.messages)
            + manager.estimatedTokens(request.tools)
            + request.maxOutputTokens
        XCTAssertLessThanOrEqual(estimatedTotal, 2_048)
        XCTAssertGreaterThan(manager.estimatedTokens(request.tools), 0)
    }

    func testEveryContinuationTurnKeepsTheSameEffectiveModelProfile() async throws {
        let fixture = try makeFixture(label: "parameter-continuation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = CompletionInvariantProvider(
            contextWindow: 8_192,
            maxOutputTokens: 2_048,
            responses: [
                response(content: "one", finishReason: "length"),
                response(content: "two", finishReason: "max_tokens"),
                response(content: "done", finishReason: "stop")
            ]
        )
        let route = ModelParameterRoute(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://unit.test:11434",
            modelID: fixture.session.model,
            useCase: .agent
        )
        var values = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: []
        ).values
        values.contextWindowTokens = 4_096
        values.maxOutputTokens = 777
        values.temperature = 0.31
        values.topP = 0.82
        values.topK = 17
        let profiles = ModelParameterRecommendationEngine.replacingCustomProfile(
            in: [],
            route: route,
            values: values
        )
        let parameters = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: profiles
        )

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "continue",
            provider: provider,
            modelParameters: parameters,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        let requests = await provider.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.contextWindowTokens == 4_096 })
        XCTAssertTrue(requests.allSatisfy { $0.maxOutputTokens == 777 })
        XCTAssertTrue(requests.allSatisfy { $0.temperature == 0.31 })
        XCTAssertTrue(requests.allSatisfy { $0.topP == 0.82 })
        XCTAssertTrue(requests.allSatisfy { $0.topK == 17 })
    }

    private func makeFixture(label: String) throws -> (
        root: URL,
        runtime: AgentRuntime,
        session: AgentSession
    ) {
        let registry = ToolRegistry()
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let root = try makeWorkspaceRoot(label: label)
        return (root, runtime, makeSession(root: root))
    }

    private func makeWorkspaceRoot(label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "agent-completion-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(root: URL) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.model = "model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        return session
    }

    private func response(
        content: String,
        finishReason: String?
    ) -> AgentModelResponse {
        AgentModelResponse(
            content: content,
            reasoningSummary: nil,
            toolCalls: [],
            finishReason: finishReason,
            usage: nil
        )
    }
}
