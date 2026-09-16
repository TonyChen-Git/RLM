import Foundation
import XCTest
@testable import LumaChat

private actor MockProvider: AgentModelProvider {
    nonisolated let id = "mock"
    nonisolated let supportsVision: Bool
    private var responses: [AgentModelResponse]

    init(_ responses: [AgentModelResponse], supportsVision: Bool = false) {
        self.responses = responses
        self.supportsVision = supportsVision
    }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        .init(
            supportsTools: true,
            supportsVision: supportsVision,
            supportsStreaming: false,
            supportsParallelTools: true,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 16_384,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }
}

private actor ToolProbe {
    private(set) var executions = 0
    private(set) var active = 0
    private(set) var maximumConcurrent = 0

    func begin() {
        executions += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
    }

    func end() { active -= 1 }

    func snapshot() -> (Int, Int) { (executions, maximumConcurrent) }
}

private struct ProbeTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let category: AgentToolCategory
    let permissionLevel: AgentPermissionLevel
    let supportsParallelExecution: Bool
    let probe: ToolProbe
    var description: String { "Test tool" }
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await probe.begin()
        try await Task.sleep(for: .milliseconds(80))
        await probe.end()
        return AgentToolResult(content: "ok \(name)")
    }
}

private struct WorkspacePathEchoTool: AgentTool {
    let workspaceRoot: String
    let probe: ToolProbe
    let id = "test.path-echo"
    let name = "path_echo"
    let displayName = "Path Echo"
    let category = AgentToolCategory.filesystem
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = true
    var description: String { "Return a path for privacy testing." }
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await probe.begin()
        await probe.end()
        return AgentToolResult(content: "\(workspaceRoot)/Sources/File.swift")
    }
}

private struct ComputerUseContextEchoTool: AgentTool {
    let id = "test.computer-use-context"
    let name = "computer_use_context"
    let displayName = "Computer Use Context"
    let category = AgentToolCategory.system
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = false
    var description: String { "Echo the Computer Use context for testing." }
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        let identifiers = context.computerUseAllowedBundleIdentifiers.sorted().joined(separator: ",")
        return AgentToolResult(
            content: "enabled=\(context.computerUseEnabled);apps=\(identifiers)"
        )
    }
}

private struct BrowserContextEchoTool: AgentTool {
    let id = "test.browser-context"
    let name = "browser_context"
    let displayName = "Browser Context"
    let category = AgentToolCategory.browser
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = false
    var description: String { "Echo the immutable Browser context for testing." }
    var inputSchema: JSONValue { .objectSchema(properties: [:]) }

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        AgentToolResult(
            content: [
                "enabled=\(context.browserEnabled)",
                "mode=\(context.browserProfileMode.rawValue)",
                "profile=\(context.browserPersistentProfileName)",
                "endpoint=\(context.browserExistingDebugEndpoint)"
            ].joined(separator: ";")
        )
    }
}

final class AgentCoreTests: XCTestCase {
    func testBrowserSettingsMigrateFailClosedAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(#"{"networkAccess":true}"#.utf8)
        )
        XCTAssertFalse(legacy.browserEnabled)
        XCTAssertEqual(legacy.browserProfileMode, .isolatedTemporary)
        XCTAssertEqual(
            legacy.browserExistingDebugEndpoint,
            AgentBrowserSettingsLimits.defaultExistingDebugEndpoint
        )

        let unsafeAttach = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(
                #"{"browserEnabled":true,"browserProfileMode":"attachExisting","browserExistingDebugEndpoint":"http://example.com:9222"}"#.utf8
            )
        )
        XCTAssertTrue(unsafeAttach.browserEnabled)
        XCTAssertEqual(unsafeAttach.browserProfileMode, .isolatedTemporary)
        XCTAssertEqual(
            unsafeAttach.browserExistingDebugEndpoint,
            AgentBrowserSettingsLimits.defaultExistingDebugEndpoint
        )

        var persistent = legacy
        persistent.browserEnabled = true
        persistent.browserProfileMode = .persistent
        persistent.browserPersistentProfileName = "qa-profile_1"
        let restored = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(persistent)
        )
        XCTAssertEqual(restored, persistent)
    }

    func testAgentRuntimePropagatesBrowserProfileAsImmutableToolContext() async throws {
        let fixture = try workspaceFixture(name: "browser-context")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let registry = ToolRegistry()
        try await registry.register(BrowserContextEchoTool())
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let provider = MockProvider([
            .init(
                content: "",
                reasoningSummary: nil,
                toolCalls: [.init(id: "browser-context", name: "browser_context")],
                finishReason: "tool_calls",
                usage: nil
            ),
            .init(
                content: "Done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        var session = AgentSession(mode: .agent)
        session.workspace = fixture.workspace
        session.model = "mock-model"
        var settings = AgentSettings()
        settings.browserEnabled = true
        settings.browserProfileMode = .persistent
        settings.browserPersistentProfileName = "signed-in-qa"

        let result = await runtime.run(
            session: session,
            userRequest: "Inspect the test page",
            provider: provider,
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.messages.first(where: { $0.role == .tool })?.content,
            "enabled=true;mode=persistent;profile=signed-in-qa;endpoint=http://127.0.0.1:9222"
        )
    }

    func testAgentVisionSettingMigratesLegacyDataAndRoundTripsExplicitOverride() throws {
        let legacy = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(#"{"networkAccess":true}"#.utf8)
        )
        XCTAssertEqual(legacy.visionMode, .automatic)
        XCTAssertNil(legacy.visionMode.capabilityOverride)

        var enabled = legacy
        enabled.visionMode = .enabled
        let restored = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(enabled)
        )
        XCTAssertEqual(restored.visionMode, .enabled)
        XCTAssertEqual(restored.visionMode.capabilityOverride, true)
    }

    func testComputerUseSettingsMigrateNormalizeAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(#"{"networkAccess":true}"#.utf8)
        )
        XCTAssertFalse(legacy.computerUseEnabled)
        XCTAssertEqual(legacy.computerUseAllowedBundleIdentifiers, [])

        let validIdentifiers = (0..<(AgentComputerUseSettingsLimits.maximumAllowedApplications + 4))
            .map { "com.example.App\($0)" }
        let payload: [String: Any] = [
            "computerUseEnabled": true,
            "computerUseAllowedBundleIdentifiers": [
                " com.example.Editor ",
                "com.example.Editor",
                "com.example.Bad\u{0007}",
                String(repeating: "x", count: AgentComputerUseSettingsLimits.maximumBundleIdentifierBytes + 1)
            ] + validIdentifiers
        ]
        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertTrue(decoded.computerUseEnabled)
        XCTAssertEqual(
            decoded.computerUseAllowedBundleIdentifiers.count,
            AgentComputerUseSettingsLimits.maximumAllowedApplications
        )
        XCTAssertEqual(decoded.computerUseAllowedBundleIdentifiers.first, "com.example.Editor")
        XCTAssertEqual(Set(decoded.computerUseAllowedBundleIdentifiers).count, decoded.computerUseAllowedBundleIdentifiers.count)
        XCTAssertFalse(decoded.computerUseAllowedBundleIdentifiers.contains { identifier in
            identifier.utf8.count > AgentComputerUseSettingsLimits.maximumBundleIdentifierBytes
                || identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        })

        let restored = try JSONDecoder().decode(
            AgentSettings.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(restored, decoded)
    }

    func testAgentRuntimePropagatesComputerUseSettingsIntoToolContext() async throws {
        let fixture = try workspaceFixture(name: "computer-use-context")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let registry = ToolRegistry()
        try await registry.register(ComputerUseContextEchoTool())
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let provider = MockProvider([
            .init(
                content: "",
                reasoningSummary: nil,
                toolCalls: [.init(id: "computer-use", name: "computer_use_context")],
                finishReason: "tool_calls",
                usage: nil
            ),
            .init(
                content: "Done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ], supportsVision: true)
        var session = AgentSession(mode: .agent)
        session.workspace = fixture.workspace
        session.model = "mock-model"
        var settings = AgentSettings()
        settings.computerUseEnabled = true
        settings.computerUseAllowedBundleIdentifiers = [
            "com.example.Terminal", "com.example.Editor", "com.example.Editor"
        ]

        let result = await runtime.run(
            session: session,
            userRequest: "Inspect an allowed app",
            provider: provider,
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.messages.first(where: { $0.role == .tool })?.content,
            "enabled=true;apps=com.example.Editor,com.example.Terminal"
        )
    }

    func testAgentRuntimeFailsComputerUseClosedWhenModelHasNoVision() async throws {
        let fixture = try workspaceFixture(name: "computer-use-no-vision")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let registry = ToolRegistry()
        try await registry.register(ComputerUseContextEchoTool())
        let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
        let provider = MockProvider([
            .init(
                content: "",
                reasoningSummary: nil,
                toolCalls: [.init(id: "computer-use", name: "computer_use_context")],
                finishReason: "tool_calls",
                usage: nil
            ),
            .init(
                content: "Done",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        var session = AgentSession(mode: .agent)
        session.workspace = fixture.workspace
        session.model = "text-only-model"
        var settings = AgentSettings()
        settings.computerUseEnabled = true
        settings.computerUseAllowedBundleIdentifiers = ["com.example.Editor"]

        let result = await runtime.run(
            session: session,
            userRequest: "Inspect an allowed app",
            provider: provider,
            settings: settings,
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(
            result.messages.first(where: { $0.role == .tool })?.content,
            "enabled=false;apps=com.example.Editor"
        )
    }

    func testDefaultModeSelectsOnlyMatchingAgentSession() {
        let plan = AgentSession(mode: .plan)
        let agent = AgentSession(mode: .agent)
        XCTAssertEqual(
            AgentViewModel.initialSessionID(in: [agent, plan], defaultMode: .plan),
            plan.id
        )
        XCTAssertEqual(
            AgentViewModel.initialSessionID(in: [plan, agent], defaultMode: .agent),
            agent.id
        )
        XCTAssertNil(
            AgentViewModel.initialSessionID(in: [agent], defaultMode: .plan)
        )
        XCTAssertEqual(
            AgentViewModel.initialSessionID(in: [plan, agent], defaultMode: .chat),
            plan.id
        )
    }

    func testClassicChatDefersAgentLifecycleUntilAgentModeIsActive() {
        XCTAssertFalse(AgentViewModel.shouldActivateAgentLifecycle(mode: .chat, isStarting: false))
        XCTAssertFalse(AgentViewModel.shouldActivateAgentLifecycle(mode: .agent, isStarting: true))
        XCTAssertTrue(AgentViewModel.shouldActivateAgentLifecycle(mode: .plan, isStarting: false))
        XCTAssertTrue(AgentViewModel.shouldActivateAgentLifecycle(mode: .agent, isStarting: false))
    }

    func testInterruptedRunRecoveryPersistsTruthfulPausedState() {
        let recoveredAt = Date(timeIntervalSince1970: 1_800_000_000)
        var running = AgentSession(mode: .agent)
        running.state = .awaitingApproval
        let workspaceID = UUID()
        let pending = AgentTurnReviewBaseline(
            version: AgentTurnReviewBaseline.currentVersion,
            runID: UUID(),
            sessionID: running.id,
            capturedAt: recoveredAt.addingTimeInterval(-10),
            workspaceID: workspaceID,
            canonicalRootPath: "/tmp/interrupted",
            rootDevice: 1,
            rootInode: 2,
            startRevision: nil,
            files: []
        )
        let previous = AgentTurnReviewSnapshot(
            version: AgentTurnReviewSnapshot.currentVersion,
            runID: UUID(),
            sessionID: running.id,
            finalizedAt: recoveredAt.addingTimeInterval(-20),
            workspaceID: workspaceID,
            canonicalRootPath: "/tmp/interrupted",
            rootDevice: 1,
            rootInode: 2,
            source: "previous frozen source",
            sourceSHA256: String(repeating: "a", count: 64),
            truncated: false
        )
        running.lastAgentTurnReviewBaseline = pending
        running.pendingAgentTurnReviewBaseline = pending
        running.lastAgentTurnReviewSnapshot = previous
        running.steps = [
            AgentStep(kind: .thinking, title: "working", status: .running)
        ]
        let completed = AgentSession(mode: .agent, state: .completed)

        let recovered = AgentViewModel.recoverInterruptedSessions(
            [running, completed],
            recoveredAt: recoveredAt
        )

        XCTAssertEqual(recovered[0].state, .paused)
        XCTAssertEqual(recovered[0].steps.first?.status, .cancelled)
        XCTAssertEqual(recovered[0].steps.first?.completedAt, recoveredAt)
        XCTAssertEqual(recovered[0].steps.last?.title, "上次執行中斷")
        XCTAssertTrue(recovered[0].messages.isEmpty, "Recovery must not fabricate tool results")
        XCTAssertNil(recovered[0].lastAgentTurnReviewBaseline)
        XCTAssertNil(recovered[0].pendingAgentTurnReviewBaseline)
        XCTAssertEqual(
            recovered[0].lastAgentTurnReviewSnapshot,
            previous,
            "Crash recovery must retain the previous completed snapshot."
        )
        XCTAssertEqual(recovered[1], completed)
    }

    func testActiveRunNeverLocksSessionSelection() {
        let runningSessionID = UUID()
        XCTAssertTrue(
            AgentViewModel.permitsSessionSelection(
                requestedSessionID: UUID(),
                isRunning: false,
                activeRunSessionID: runningSessionID
            )
        )
        XCTAssertTrue(
            AgentViewModel.permitsSessionSelection(
                requestedSessionID: runningSessionID,
                isRunning: true,
                activeRunSessionID: runningSessionID
            )
        )
        XCTAssertTrue(
            AgentViewModel.permitsSessionSelection(
                requestedSessionID: UUID(),
                isRunning: true,
                activeRunSessionID: runningSessionID
            )
        )
        XCTAssertTrue(
            AgentViewModel.permitsSessionSelection(
                requestedSessionID: nil,
                isRunning: true,
                activeRunSessionID: runningSessionID
            )
        )
    }

    func testUndoResultDecodesExactPersistedChangeIDs() throws {
        let taskID = UUID()
        let retainedID = UUID()
        let first = FileChangeRecord(
            id: UUID(),
            taskID: taskID,
            operation: .write,
            paths: ["Sources/First.swift"],
            diffs: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = FileChangeRecord(
            id: UUID(),
            taskID: taskID,
            operation: .edit,
            paths: ["Sources/Second.swift"],
            diffs: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let single = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(first))
        let multiple = try JSONDecoder().decode(JSONValue.self, from: encoder.encode([first, second]))

        XCTAssertEqual(AgentViewModel.undoneChangeIDs(from: single), Set([first.id]))
        XCTAssertEqual(AgentViewModel.undoneChangeIDs(from: multiple), Set([first.id, second.id]))
        XCTAssertFalse(AgentViewModel.undoneChangeIDs(from: multiple)?.contains(retainedID) == true)
        XCTAssertNil(AgentViewModel.undoneChangeIDs(from: .string("invalid")))
    }

    func testProjectScopedMCPRequiresCanonicalSelectedWorkspaceMatch() {
        let root = FileManager.default.currentDirectoryPath
        let equivalentRoot = URL(fileURLWithPath: root)
            .appendingPathComponent("Sources")
            .appendingPathComponent("..")
            .path
        let global = MCPServerConfiguration(
            name: "Global",
            scope: .global,
            transport: .stdio(.init(command: "/usr/bin/true"))
        )
        let projectOnly = MCPServerConfiguration(
            name: "Project",
            scope: .projectOnly,
            projectPath: equivalentRoot,
            transport: .stdio(.init(command: "/usr/bin/true"))
        )

        XCTAssertTrue(AgentViewModel.mcpServer(global, matchesWorkspaceRoot: nil))
        XCTAssertTrue(AgentViewModel.mcpServer(projectOnly, matchesWorkspaceRoot: root))
        XCTAssertFalse(AgentViewModel.mcpServer(projectOnly, matchesWorkspaceRoot: root + "-other"))
        XCTAssertFalse(AgentViewModel.mcpServer(projectOnly, matchesWorkspaceRoot: nil))
    }

    func testAgentLoopExecutesParallelReadToolsThenReturnsFinal() async throws {
        let fixture = try workspaceFixture(name: "parallel")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let probe = ToolProbe()
        let registry = ToolRegistry()
        try await registry.register([
            ProbeTool(
                id: "read-a", name: "read_a", displayName: "Read A",
                category: .filesystem, permissionLevel: .read,
                supportsParallelExecution: true, probe: probe
            ),
            ProbeTool(
                id: "read-b", name: "read_b", displayName: "Read B",
                category: .filesystem, permissionLevel: .read,
                supportsParallelExecution: true, probe: probe
            )
        ])
        let executor = ToolExecutor(registry: registry)
        let runtime = AgentRuntime(registry: registry, executor: executor)
        let provider = MockProvider([
            .init(
                content: "",
                reasoningSummary: "private detail must not persist",
                toolCalls: [
                    .init(id: "a", name: "read_a"),
                    .init(id: "b", name: "read_b")
                ],
                finishReason: "tool_calls",
                usage: nil
            ),
            .init(
                content: "Finished after real tool output.",
                reasoningSummary: nil,
                toolCalls: [],
                finishReason: "stop",
                usage: nil
            )
        ])
        var session = AgentSession(mode: .agent)
        session.workspace = fixture.workspace
        session.model = "mock-model"

        let result = await runtime.run(
            session: session,
            userRequest: "Inspect both",
            provider: provider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        let probeSnapshot = await probe.snapshot()
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(probeSnapshot.0, 2)
        XCTAssertEqual(probeSnapshot.1, 2)
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.count, 2)
        XCTAssertEqual(result.messages.last?.content, "Finished after real tool output.")
        XCTAssertFalse(result.messages.contains { $0.reasoningSummary?.contains("private detail") == true })
    }

    func testPlanModeRejectsWriteBeforeToolExecution() async throws {
        let fixture = try workspaceFixture(name: "plan")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let probe = ToolProbe()
        let registry = ToolRegistry()
        try await registry.register(
            ProbeTool(
                id: "write", name: "write_file", displayName: "Write",
                category: .filesystem, permissionLevel: .write,
                supportsParallelExecution: false, probe: probe
            )
        )
        let executor = ToolExecutor(registry: registry)
        let result = try await executor.execute(
            .init(name: "write_file", arguments: .object(["path": .string("a.txt")])),
            context: AgentToolContext(
                sessionID: UUID(), mode: .plan, workspace: fixture.workspace
            ),
            permissionMode: .fullAccess,
            networkAccess: true,
            approvalHandler: { _ in .allowOnce }
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Plan"))
        let invocationCount = await probe.snapshot().0
        XCTAssertEqual(invocationCount, 0)
    }

    func testPlanReadToolStillRequiresApprovalWhenItUsesDisabledNetwork() async throws {
        let fixture = try workspaceFixture(name: "plan-network")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let metadata = ToolMetadata(
            id: "builtin.fetch_url",
            name: "fetch_url",
            displayName: "Fetch URL",
            category: .web,
            permissionLevel: .read,
            requiresNetwork: true,
            supportsParallelExecution: true
        )
        let authorization = await PermissionManager().authorize(
            metadata: metadata,
            call: AgentToolCall(
                name: "fetch_url",
                arguments: .object(["url": .string("https://example.invalid")])
            ),
            context: AgentToolContext(
                sessionID: UUID(),
                mode: .plan,
                workspace: fixture.workspace
            ),
            permissionMode: .autoApproveSafe,
            networkAccess: false
        )
        guard case .requireApproval(let level, _) = authorization else {
            return XCTFail("Plan-mode network read was silently approved")
        }
        XCTAssertEqual(level, .network)
    }

    func testToolExecutorRejectsOversizedArgumentsBeforeExecution() async throws {
        let fixture = try workspaceFixture(name: "argument-limit")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let probe = ToolProbe()
        let registry = ToolRegistry()
        try await registry.register(
            ProbeTool(
                id: "write", name: "write_file", displayName: "Write",
                category: .filesystem, permissionLevel: .write,
                supportsParallelExecution: false, probe: probe
            )
        )
        let executor = ToolExecutor(registry: registry)
        do {
            _ = try await executor.execute(
                .init(
                    name: "write_file",
                    arguments: .object(["content": .string(String(repeating: "x", count: 4 * 1_024 * 1_024))])
                ),
                context: AgentToolContext(
                    sessionID: UUID(), mode: .agent, workspace: fixture.workspace
                ),
                permissionMode: .fullAccess,
                networkAccess: true,
                approvalHandler: nil
            )
            XCTFail("Oversized arguments should be rejected")
        } catch let error as ToolExecutionError {
            guard case .invalidArguments = error else {
                return XCTFail("Unexpected tool error: \(error)")
            }
        }
        let invocationCount = await probe.snapshot().0
        XCTAssertEqual(invocationCount, 0)
    }

    func testToolResultDoesNotDiscloseAbsoluteWorkspacePathToRemoteModel() async throws {
        let fixture = try workspaceFixture(name: "model-path-privacy")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let probe = ToolProbe()
        let registry = ToolRegistry()
        try await registry.register(
            WorkspacePathEchoTool(workspaceRoot: fixture.workspace.rootPath, probe: probe)
        )
        let result = try await ToolExecutor(registry: registry).execute(
            AgentToolCall(name: "path_echo"),
            context: AgentToolContext(
                sessionID: UUID(),
                mode: .agent,
                workspace: fixture.workspace
            ),
            permissionMode: .autoApproveSafe,
            networkAccess: false,
            approvalHandler: nil
        )

        XCTAssertFalse(result.content.contains(fixture.workspace.rootPath))
        XCTAssertTrue(result.content.contains("./Sources/File.swift"))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.0, 1)
    }

    func testDangerousCommandAlwaysRequiresApproval() async throws {
        let fixture = try workspaceFixture(name: "danger")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let probe = ToolProbe()
        let registry = ToolRegistry()
        try await registry.register(
            ProbeTool(
                id: "run", name: "run_command", displayName: "Terminal",
                category: .terminal, permissionLevel: .execute,
                supportsParallelExecution: false, probe: probe
            )
        )
        let executor = ToolExecutor(registry: registry)
        let result = try await executor.execute(
            .init(name: "run_command", arguments: .object(["command": .string("rm -rf build")])),
            context: AgentToolContext(
                sessionID: UUID(), mode: .agent, workspace: fixture.workspace
            ),
            permissionMode: .fullAccess,
            networkAccess: true,
            approvalHandler: { request in
                XCTAssertEqual(request.permissionLevel, .dangerous)
                return .deny
            }
        )
        XCTAssertTrue(result.isError)
        let invocationCount = await probe.snapshot().0
        XCTAssertEqual(invocationCount, 0)
    }

    func testWriteApprovalIncludesDescriptorSafeDiffPreview() async throws {
        let fixture = try workspaceFixture(name: "approval-diff")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        try Data("before\n".utf8).write(to: fixture.url.appendingPathComponent("value.txt"))
        let registry = ToolRegistry()
        try await registry.register(
            ProbeTool(
                id: "write", name: "write_file", displayName: "Write",
                category: .filesystem, permissionLevel: .write,
                supportsParallelExecution: false, probe: ToolProbe()
            )
        )
        let executor = ToolExecutor(registry: registry)
        _ = try await executor.execute(
            AgentToolCall(
                name: "write_file",
                arguments: .object([
                    "path": .string("value.txt"),
                    "content": .string("after\n")
                ])
            ),
            context: AgentToolContext(
                sessionID: UUID(),
                mode: .agent,
                workspace: fixture.workspace
            ),
            permissionMode: .askEveryTime,
            networkAccess: false,
            approvalHandler: { request in
                XCTAssertTrue(request.diffPreview?.contains("-before") == true)
                XCTAssertTrue(request.diffPreview?.contains("+after") == true)
                return .deny
            }
        )
    }

    func testSessionAllowanceCannotBypassLaterDangerousCommand() async throws {
        let fixture = try workspaceFixture(name: "session-risk")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let tool = ProbeTool(
            id: "run", name: "run_command", displayName: "Terminal",
            category: .terminal, permissionLevel: .execute,
            supportsParallelExecution: false, probe: ToolProbe()
        )
        let manager = PermissionManager()
        let sessionID = UUID()
        let context = AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: fixture.workspace
        )
        await manager.allowForSession(
            metadata: ToolMetadata(tool: tool),
            context: context,
            effectiveLevel: .execute
        )

        let authorization = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(
                name: tool.name,
                arguments: .object(["command": .string("rm -rf build")])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: true
        )
        guard case .requireApproval(let level, _) = authorization else {
            return XCTFail("Dangerous command incorrectly inherited the session allowance")
        }
        XCTAssertEqual(level, .dangerous)
    }

    func testSessionAllowanceCannotBypassDisabledNetworkAccess() async throws {
        let fixture = try workspaceFixture(name: "session-network")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let tool = ProbeTool(
            id: "run", name: "run_command", displayName: "Terminal",
            category: .terminal, permissionLevel: .execute,
            supportsParallelExecution: false, probe: ToolProbe()
        )
        let manager = PermissionManager()
        let sessionID = UUID()
        let context = AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: fixture.workspace
        )
        await manager.allowForSession(
            metadata: ToolMetadata(tool: tool),
            context: context,
            effectiveLevel: .execute
        )
        let authorization = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(
                name: tool.name,
                arguments: .object(["command": .string("/usr/bin/curl https://example.com")])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: false
        )
        guard case .requireApproval(let level, _) = authorization else {
            return XCTFail("Network command incorrectly inherited the session allowance")
        }
        XCTAssertEqual(level, .network)
    }

    func testExplicitNetworkSessionAllowanceCoversOnlyTheApprovedTerminalArguments() async throws {
        let fixture = try workspaceFixture(name: "session-explicit-network")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let tool = ProbeTool(
            id: "run", name: "run_command", displayName: "Terminal",
            category: .terminal, permissionLevel: .execute,
            supportsParallelExecution: false, probe: ToolProbe()
        )
        let metadata = ToolMetadata(tool: tool)
        let manager = PermissionManager()
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: fixture.workspace
        )
        let approved = AgentToolCall(
            name: tool.name,
            arguments: .object(["command": .string("/usr/bin/curl https://example.com")])
        )
        await manager.allowForSession(
            metadata: metadata,
            context: context,
            effectiveLevel: .network,
            call: approved
        )

        let repeated = await manager.authorize(
            metadata: metadata,
            call: approved,
            context: context,
            permissionMode: .fullAccess,
            networkAccess: false
        )
        XCTAssertEqual(repeated, .allow)

        let different = await manager.authorize(
            metadata: metadata,
            call: AgentToolCall(
                name: tool.name,
                arguments: .object(["command": .string("/usr/bin/curl https://other.example")])
            ),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: false
        )
        guard case .requireApproval(let level, _) = different else {
            return XCTFail("A network allowance crossed its terminal argument scope")
        }
        XCTAssertEqual(level, .network)
    }

    func testPlanNetworkReadHonorsExplicitSessionAllowance() async throws {
        let fixture = try workspaceFixture(name: "plan-network-allowance")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let metadata = ToolMetadata(
            id: "builtin.fetch_url",
            name: "fetch_url",
            displayName: "Fetch URL",
            category: .web,
            permissionLevel: .read,
            requiresNetwork: true,
            supportsParallelExecution: true
        )
        let manager = PermissionManager()
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .plan,
            workspace: fixture.workspace
        )
        let call = AgentToolCall(
            name: "fetch_url",
            arguments: .object(["url": .string("https://example.invalid")])
        )
        await manager.allowForSession(
            metadata: metadata,
            context: context,
            effectiveLevel: .network,
            call: call
        )

        let authorization = await manager.authorize(
            metadata: metadata,
            call: call,
            context: context,
            permissionMode: .autoApproveSafe,
            networkAccess: false
        )
        XCTAssertEqual(authorization, .allow)
    }

    func testTerminalSessionAllowanceIsScopedToTheExactApprovedArguments() async throws {
        let fixture = try workspaceFixture(name: "terminal-allowance")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let tool = ProbeTool(
            id: "run", name: "run_command", displayName: "Terminal",
            category: .terminal, permissionLevel: .execute,
            supportsParallelExecution: false, probe: ToolProbe()
        )
        let manager = PermissionManager()
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: fixture.workspace
        )
        let approved = AgentToolCall(
            name: tool.name,
            arguments: .object(["command": .string("/usr/bin/file Package.swift")])
        )
        await manager.allowForSession(
            metadata: ToolMetadata(tool: tool),
            context: context,
            effectiveLevel: .execute,
            call: approved
        )

        let repeated = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: approved,
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        XCTAssertEqual(repeated, .allow)

        let different = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(
                name: tool.name,
                arguments: .object(["command": .string("/usr/bin/file README.md")])
            ),
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        guard case .requireApproval(let level, _) = different else {
            return XCTFail("A different command inherited an unrelated terminal allowance")
        }
        XCTAssertEqual(level, .execute)
    }

    func testSessionAllowancePersistsOnlyStableBuiltinAuthority() async throws {
        let fixture = try workspaceFixture(name: "persisted-allowance")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let sessionID = UUID()
        let context = AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: fixture.workspace
        )
        let write = ToolMetadata(
            id: "builtin.edit_file",
            name: "edit_file",
            displayName: "Edit File",
            category: .filesystem,
            permissionLevel: .write,
            requiresNetwork: false,
            supportsParallelExecution: false
        )
        let mcp = ToolMetadata(
            id: "mcp.dynamic.write",
            name: "mcp.dynamic.write",
            displayName: "Dynamic MCP",
            category: .mcp,
            permissionLevel: .write,
            requiresNetwork: false,
            supportsParallelExecution: false
        )
        let browser = ToolMetadata(
            id: "builtin.browser_type",
            name: "browser_type",
            displayName: "Browser Type",
            category: .browser,
            permissionLevel: .write,
            requiresNetwork: true,
            supportsParallelExecution: false
        )
        let original = PermissionManager()
        await original.allowForSession(
            metadata: write,
            context: context,
            effectiveLevel: .write
        )
        await original.allowForSession(
            metadata: mcp,
            context: context,
            effectiveLevel: .write
        )
        await original.allowForSession(
            metadata: browser,
            context: context,
            effectiveLevel: .write
        )
        let persisted = await original.persistedAllowances(for: sessionID)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.toolID, write.id)

        let restored = PermissionManager()
        await restored.restorePersistedAllowances(
            persisted,
            for: sessionID,
            workspace: fixture.workspace
        )
        let authorization = await restored.authorize(
            metadata: write,
            call: AgentToolCall(name: write.name),
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        XCTAssertEqual(authorization, .allow)

        var otherWorkspace = fixture.workspace
        otherWorkspace.rootPath += "-different"
        await restored.restorePersistedAllowances(
            persisted,
            for: sessionID,
            workspace: otherWorkspace
        )
        let afterMismatch = await restored.authorize(
            metadata: write,
            call: AgentToolCall(name: write.name),
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        guard case .requireApproval = afterMismatch else {
            return XCTFail("A persisted allowance crossed workspace authority")
        }
    }

    func testAutoApproveSafePromptsForMCPExecuteAndScopesAllowanceToWorkspace() async throws {
        let first = try workspaceFixture(name: "allowance-a")
        let second = try workspaceFixture(name: "allowance-b")
        defer {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        let tool = ProbeTool(
            id: "mcp.server.run", name: "mcp.server.run", displayName: "MCP Run",
            category: .mcp, permissionLevel: .execute,
            supportsParallelExecution: false, probe: ToolProbe()
        )
        let manager = PermissionManager()
        let sessionID = UUID()
        let firstContext = AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: first.workspace
        )
        let initial = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(name: tool.name),
            context: firstContext,
            permissionMode: .autoApproveSafe,
            networkAccess: false
        )
        guard case .requireApproval(let initialLevel, _) = initial else {
            return XCTFail("MCP execute was silently auto-approved")
        }
        XCTAssertEqual(initialLevel, .execute)

        await manager.allowForSession(
            metadata: ToolMetadata(tool: tool),
            context: firstContext,
            effectiveLevel: .execute
        )
        let sameWorkspace = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(name: tool.name),
            context: firstContext,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        XCTAssertEqual(sameWorkspace, .allow)

        let changedWorkspace = await manager.authorize(
            metadata: ToolMetadata(tool: tool),
            call: AgentToolCall(name: tool.name),
            context: AgentToolContext(
                sessionID: sessionID,
                mode: .agent,
                workspace: second.workspace
            ),
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        guard case .requireApproval(let changedLevel, _) = changedWorkspace else {
            return XCTFail("A session allowance crossed workspace authority")
        }
        XCTAssertEqual(changedLevel, .execute)
    }

    func testAutoApproveSafeAllowsOnlyFixedBuiltinValidationActions() async throws {
        let fixture = try workspaceFixture(name: "fixed-validation-permission")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let manager = PermissionManager()
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: fixture.workspace
        )

        for name in ["build", "test"] {
            let authorization = await manager.authorize(
                metadata: ToolMetadata(
                    id: "builtin.\(name)",
                    name: name,
                    displayName: name.capitalized,
                    category: .terminal,
                    permissionLevel: .execute,
                    supportsParallelExecution: false
                ),
                call: AgentToolCall(name: name),
                context: context,
                permissionMode: .autoApproveSafe,
                networkAccess: false
            )
            XCTAssertEqual(authorization, .allow)
        }

        for name in ["build", "test"] {
            let lookalike = await manager.authorize(
                metadata: ToolMetadata(
                    id: "extension.\(name)",
                    name: name,
                    displayName: "Untrusted \(name.capitalized)",
                    category: .terminal,
                    permissionLevel: .execute,
                    supportsParallelExecution: false
                ),
                call: AgentToolCall(name: name),
                context: context,
                permissionMode: .autoApproveSafe,
                networkAccess: false
            )
            guard case .requireApproval(let level, _) = lookalike else {
                return XCTFail("A lookalike extension tool bypassed execute approval")
            }
            XCTAssertEqual(level, .execute)
        }
    }

    func testDangerousRemoteMCPApprovalDisclosesNetworkUse() async throws {
        let fixture = try workspaceFixture(name: "mcp-danger-network")
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let metadata = ToolMetadata(
            id: "mcp.remote.destroy",
            name: "mcp.remote.destroy",
            displayName: "Remote destroy",
            category: .mcp,
            permissionLevel: .dangerous,
            requiresNetwork: true,
            supportsParallelExecution: false
        )
        let authorization = await PermissionManager().authorize(
            metadata: metadata,
            call: AgentToolCall(name: metadata.name),
            context: AgentToolContext(
                sessionID: UUID(), mode: .agent, workspace: fixture.workspace
            ),
            permissionMode: .autoApproveSafe,
            networkAccess: false
        )
        guard case .requireApproval(let level, let reasons) = authorization else {
            return XCTFail("Dangerous remote MCP call should require approval")
        }
        XCTAssertEqual(level, .dangerous)
        XCTAssertTrue(reasons.contains(where: { $0.contains("網路") }))
    }

    func testSecretRedactorUsesSensitiveJSONKeys() {
        let redacted = SecretRedactor().redact(
            JSONValue.object([
                "api_key": .string("plain-value-without-prefix"),
                "nested": .object(["password": .string("also-plain")]),
                "AWS_SECRET_ACCESS_KEY": .string("plain-aws-secret"),
                "credential_path": .string("plain-credential"),
                "safe": .string("visible")
            ])
        )
        XCTAssertEqual(redacted["api_key"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(redacted["nested"]?["password"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(redacted["AWS_SECRET_ACCESS_KEY"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(redacted["credential_path"]?.stringValue, "[REDACTED]")
        XCTAssertEqual(redacted["safe"]?.stringValue, "visible")
        let rawSecret = "sk-abcdefghijklmnopqrstuvwxyz"
        let redactedText = SecretRedactor().redact("credential \(rawSecret)")
        XCTAssertFalse(redactedText.contains(rawSecret))
        XCTAssertTrue(redactedText.contains("[REDACTED]"))

        let samples = [
            "OPENAI_API_KEY=ordinary-value-12345",
            "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz",
            "tool --password ordinary-password-12345",
            "https://user:ordinary-password-12345@example.com/path",
            "DATABASE_URL=postgres://user:ordinary-password-12345@db.example/app",
            "REDIS_URL=redis://:ordinary-password-12345@cache.example/0",
            "-----BEGIN PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"
        ]
        for sample in samples {
            let sanitized = SecretRedactor().redact(sample)
            XCTAssertTrue(sanitized.contains("[REDACTED]"), sanitized)
            XCTAssertFalse(sanitized.contains("ordinary-password-12345"), sanitized)
            XCTAssertFalse(sanitized.contains("private-material"), sanitized)
        }
    }

    func testWorkspaceValidatorBlocksTraversalAndSymlinkEscape() throws {
        let fixture = try workspaceFixture(name: "security")
        let outside = fixture.url.deletingLastPathComponent().appendingPathComponent("outside-security")
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outsideFile)
        let link = fixture.url.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)

        let validator = try WorkspaceSecurityValidator(workspace: fixture.workspace)
        XCTAssertThrowsError(try validator.validate(path: "../outside-security/secret.txt"))
        XCTAssertThrowsError(try validator.validate(path: outsideFile.path))
        XCTAssertThrowsError(try validator.validate(path: "escape.txt"))
        let internalTarget = fixture.url.appendingPathComponent("nested")
        let internalLink = fixture.url.appendingPathComponent("internal-link")
        try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: internalTarget)
        XCTAssertThrowsError(try validator.validate(path: "internal-link", access: .write))
        let safe = try validator.validate(path: "nested/new.swift", access: .write, allowNonexistentLeaf: true)
        XCTAssertTrue(safe.path.hasPrefix(fixture.url.path + "/"))
    }

    func testContextCompressionKeepsGoalAndRecentToolFacts() {
        let manager = ContextManager()
        var messages = [AgentMessage(role: .user, content: "Fix the important bug")]
        for index in 0..<30 {
            messages.append(
                AgentMessage(
                    role: .tool,
                    content: String(repeating: "result \(index) ", count: 80),
                    name: "read_file"
                )
            )
        }
        let prepared = manager.prepare(
            messages: messages,
            contextWindow: 2_048,
            maxOutputTokens: 512,
            autoCompress: true
        )
        XCTAssertLessThan(prepared.count, messages.count)
        XCTAssertTrue(prepared.first?.content.contains("Original goal") == true)
        XCTAssertTrue(prepared.first?.content.contains("Fix the important bug") == true)
    }

    func testProjectInstructionsUseNoFollowBoundedDescriptorRead() throws {
        let fixture = try workspaceFixture(name: "instructions-security")
        let outside = fixture.url.deletingLastPathComponent().appendingPathComponent(
            "outside-instructions-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideInstructions = outside.appendingPathComponent("AGENTS.md")
        try Data("OUTSIDE-INSTRUCTION-MUST-NOT-LOAD".utf8).write(to: outsideInstructions)
        let workspaceInstructions = fixture.url.appendingPathComponent("AGENTS.md")
        try FileManager.default.createSymbolicLink(
            at: workspaceInstructions,
            withDestinationURL: outsideInstructions
        )

        let linkedPrompt = ContextManager().systemPrompt(mode: .agent, workspace: fixture.workspace)
        XCTAssertFalse(linkedPrompt.contains("OUTSIDE-INSTRUCTION-MUST-NOT-LOAD"))
        XCTAssertTrue(linkedPrompt.contains("no root AGENTS.md was found"))

        try FileManager.default.removeItem(at: workspaceInstructions)
        try Data(repeating: 0x41, count: 128 * 1_024 + 1).write(to: workspaceInstructions)
        let oversizedPrompt = ContextManager().systemPrompt(mode: .agent, workspace: fixture.workspace)
        XCTAssertTrue(oversizedPrompt.contains("no root AGENTS.md was found"))

        try Data("Use descriptor-safe instructions.".utf8).write(
            to: workspaceInstructions,
            options: .atomic
        )
        let safePrompt = ContextManager().systemPrompt(mode: .agent, workspace: fixture.workspace)
        XCTAssertTrue(safePrompt.contains("Use descriptor-safe instructions."))
    }

    private func workspaceFixture(name: String) throws -> (url: URL, workspace: AgentWorkspace) {
        let url = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-core-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (
            url,
            AgentWorkspace(
                name: name,
                rootPath: url.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            )
        )
    }
}
