import Foundation
import XCTest
@testable import LumaChat

private actor PhaseDExtensionProvider: AgentModelProvider {
    nonisolated let id = "phase-d-extension-provider"
    private var responses: [AgentModelResponse]
    private var requests: [AgentModelRequest] = []

    init(responses: [AgentModelResponse]) {
        self.responses = responses
    }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 16_384,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }

    func capturedRequests() -> [AgentModelRequest] {
        requests
    }
}

private actor PhaseDHookProbe {
    private var events: [LifecycleHookEvent] = []

    func record(_ event: LifecycleHookEvent) {
        events.append(event)
    }

    func snapshot() -> [LifecycleHookEvent] {
        events
    }
}

private struct PhaseDHostHookProbeTool: AgentTool {
    let probe: PhaseDHookProbe
    let id = "test.phase-d-host-hook"
    let name = "phase_d_host_hook_probe"
    let displayName = "Phase D Host Hook Probe"
    let description = "Host-only lifecycle hook probe."
    let category = AgentToolCategory.plugin
    let permissionLevel = AgentPermissionLevel.execute
    let supportsParallelExecution = false
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func isAvailable(in context: AgentToolContext) -> Bool {
        context.lifecycleHookInvocation != nil
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let invocation = context.lifecycleHookInvocation else {
            return AgentToolResult(content: "Missing host invocation.", isError: true)
        }
        await probe.record(invocation.event)
        return AgentToolResult(content: "recorded")
    }
}

@MainActor
final class PhaseDRuntimeExtensionTests: XCTestCase {
    func testLoadedSkillInstructionsAreTransientAndReappliedToEveryModelTurn() async throws {
        let fixture = try makeFixture(label: "transient-skill")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = "PHASE_D_TRANSIENT_SKILL_MARKER"
        let skill = ResolvedSkill(
            descriptor: SkillDescriptor(
                id: "project/release",
                name: "release",
                description: "Prepare a release",
                usage: "$release",
                permissions: [.filesystemRead],
                source: .project,
                sourcePath: fixture.root.appendingPathComponent("SKILL.md").path,
                pluginID: nil,
                hasReferences: false,
                hasScripts: false,
                hasTemplates: false,
                hasAssets: false
            ),
            instructions: "Always preserve this instruction: \(marker)"
        )
        let provider = PhaseDExtensionProvider(
            responses: [
                response(content: "partial", finishReason: "length"),
                response(content: "complete", finishReason: "stop")
            ]
        )

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Use $release and finish the task.",
            provider: provider,
            loadedSkills: [skill],
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        XCTAssertEqual(result.loadedSkills?.map(\.id) ?? [], [skill.descriptor.id])
        XCTAssertFalse(result.messages.contains { $0.content.contains(marker) })
        XCTAssertFalse(result.messages.contains { $0.name?.hasPrefix("luma-skill-") == true })

        let requests = await provider.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { request in
            request.messages.contains { message in
                message.name?.hasPrefix("luma-skill-") == true
                    && message.content.contains(marker)
            }
        })
    }

    func testStepLimitStillDispatchesSessionEndHook() async throws {
        let root = try makeRoot(label: "step-limit-hook")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ToolRegistry()
        let probe = PhaseDHookProbe()
        try await registry.register(PhaseDHostHookProbeTool(probe: probe))
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        var settings = AgentSettings()
        settings.maxSteps = 1
        let provider = PhaseDExtensionProvider(
            responses: [response(content: "partial", finishReason: "length")]
        )
        let binding = PluginHookBinding(
            pluginID: "com.example.phase-d-test",
            hookIndex: 0,
            event: .sessionEnd,
            toolName: "phase_d_host_hook_probe",
            failurePolicy: .continueTask
        )

        let result = await runtime.run(
            session: makeSession(root: root),
            userRequest: "Run until the configured ceiling.",
            provider: provider,
            hookBindings: [binding],
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        let events = await probe.snapshot()
        XCTAssertEqual(events, [.sessionEnd])
    }

    private func makeFixture(label: String) throws -> (
        root: URL,
        runtime: AgentRuntime,
        session: AgentSession
    ) {
        let root = try makeRoot(label: label)
        let registry = ToolRegistry()
        return (
            root,
            AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry)),
            makeSession(root: root)
        )
    }

    private func makeRoot(label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "phase-d-runtime-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession(root: URL) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.model = "phase-d-model"
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
