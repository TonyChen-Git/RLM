import Foundation
import XCTest
@testable import LumaChat

private actor TerminalProgressProbe {
    private var updates: [AgentToolProgress] = []
    private var commandCompleted = false
    private var observedBeforeCompletion = false

    func record(_ update: AgentToolProgress) {
        updates.append(update)
        if !commandCompleted { observedBeforeCompletion = true }
    }

    func markCompleted() { commandCompleted = true }

    func waitForOutput() async {
        while updates.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func snapshot() -> (updates: [AgentToolProgress], beforeCompletion: Bool) {
        (updates, observedBeforeCompletion)
    }
}

private actor TerminalProgressScriptProvider: AgentModelProvider {
    nonisolated let id = "terminal-progress-script"
    private var responses: [AgentModelResponse]

    init(responses: [AgentModelResponse]) { self.responses = responses }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 8_192,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        guard !responses.isEmpty else { throw ChatError.malformedResponse }
        return responses.removeFirst()
    }
}

private struct RuntimeProgressTerminalTool: AgentTool {
    var blocksUntilCancelled: Bool
    let id = "test.runtime-progress-terminal"
    let name = "run_command"
    let displayName = "Run Command"
    let description = "Emits bounded terminal progress for Runtime integration tests."
    let inputSchema = JSONValue.objectSchema(
        properties: ["command": .stringSchema()],
        required: ["command"]
    )
    let category = AgentToolCategory.terminal
    let permissionLevel = AgentPermissionLevel.execute
    let supportsParallelExecution = false

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        await context.progressHandler?(
            AgentToolProgress(
                stream: .stdout,
                delta: "ready at \(context.workspace.rootPath) API_TOKEN=runtime-stream-secret\n",
                totalBytes: 80,
                truncated: false
            )
        )
        await context.progressHandler?(
            AgentToolProgress(
                stream: .stdout,
                delta: String(repeating: "x", count: 100_000),
                totalBytes: 100_080,
                truncated: false
            )
        )
        await context.progressHandler?(
            AgentToolProgress(
                stream: .stderr,
                delta: "warning-stream\n",
                totalBytes: 15,
                truncated: false
            )
        )
        if blocksUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        return AgentToolResult(content: "authoritative final terminal result")
    }
}

private actor RuntimeProgressEventProbe {
    private var progressEvents: [(UUID, AgentTerminalProgress)] = []
    private var sawFormalResult = false
    private var progressArrivedBeforeResult = false

    func record(_ event: AgentEvent) {
        switch event {
        case .toolProgress(_, let stepID, let progress):
            progressEvents.append((stepID, progress))
            if !sawFormalResult { progressArrivedBeforeResult = true }
        case .sessionUpdated(let session), .finished(let session):
            if session.steps.contains(where: { $0.toolCall?.id == "live-command" && $0.toolResult != nil }) {
                sawFormalResult = true
            }
        case .approvalRequired, .modelStarted, .modelFinished, .failed:
            break
        }
    }

    func waitForProgress() async {
        while progressEvents.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func snapshot() -> (events: [(UUID, AgentTerminalProgress)], beforeResult: Bool) {
        (progressEvents, progressArrivedBeforeResult)
    }
}

final class AgentTerminalStreamingTests: XCTestCase {
    func testTerminalSessionPublishesRedactedSeparatedOutputBeforeCompletion() async throws {
        let root = try makeRoot("terminal-live")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: workspace(root))
        )
        let probe = TerminalProgressProbe()
        let secret = "terminal-live-secret"
        let result = try await terminal.run(
            command: "printf 'out:%s\\n' \"$API_TOKEN\"; printf 'err-line\\n' >&2; sleep 0.35; printf 'done\\n'",
            timeout: 5,
            environment: ["API_TOKEN": secret],
            progressHandler: { update in await probe.record(update) }
        )
        await probe.markCompleted()

        XCTAssertEqual(result.exitCode, 0)
        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.beforeCompletion, "At least one delta must arrive while the command is running")
        let stdout = snapshot.updates.filter { $0.stream == .stdout }.map(\.delta).joined()
        let stderr = snapshot.updates.filter { $0.stream == .stderr }.map(\.delta).joined()
        XCTAssertTrue(stdout.contains("out:[REDACTED]"), stdout)
        XCTAssertTrue(stdout.contains("done"), stdout)
        XCTAssertFalse(stdout.contains(secret), stdout)
        XCTAssertTrue(stderr.contains("err-line"), stderr)
        XCTAssertTrue(snapshot.updates.allSatisfy {
            $0.delta.utf8.count <= TerminalSession.maximumLiveOutputDeltaBytes
        })
    }

    func testTerminalSessionCancellationStopsStreamingAndRemainsReusable() async throws {
        let root = try makeRoot("terminal-live-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: workspace(root))
        )
        let probe = TerminalProgressProbe()
        let running = Task {
            try await terminal.run(
                command: "while true; do printf 'tick\\n'; sleep 0.05; done",
                timeout: 30,
                progressHandler: { update in await probe.record(update) }
            )
        }
        await probe.waitForOutput()
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("A cancelled live command must not report successful completion")
        } catch is CancellationError {
            // Expected: TerminalSession terminated/reaped its owned process.
        }

        let followUp = try await terminal.run(command: "printf 'after-cancel\\n'", timeout: 5)
        XCTAssertEqual(followUp.exitCode, 0)
        XCTAssertTrue(followUp.stdout.contains("after-cancel"))
    }

    func testTerminalSessionTimeoutRetainsProgressAndReturnsOneTimedOutResult() async throws {
        let root = try makeRoot("terminal-live-timeout")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: workspace(root))
        )
        let probe = TerminalProgressProbe()
        let result = try await terminal.run(
            command: "printf 'before-timeout\\n'; sleep 10",
            timeout: 0.2,
            progressHandler: { update in await probe.record(update) }
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.beforeCompletion)
        XCTAssertTrue(
            snapshot.updates.contains { update in
                update.stream == .stdout && update.delta.contains("before-timeout")
            }
        )
    }

    func testRuntimeUpdatesOneStepBeforeAppendingOneFinalToolResult() async throws {
        let fixture = try await runtimeFixture(blocksUntilCancelled: false, label: "complete")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RuntimeProgressEventProbe()
        let result = await fixture.runtime.run(
            session: makeSession(root: fixture.root),
            userRequest: "stream a command",
            provider: scriptedProvider(includeFinal: true),
            settings: runtimeSettings(),
            approvalHandler: nil,
            eventHandler: { event in await events.record(event) }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let eventSnapshot = await events.snapshot()
        XCTAssertTrue(eventSnapshot.beforeResult)
        XCTAssertFalse(eventSnapshot.events.isEmpty)
        XCTAssertEqual(Set(eventSnapshot.events.map(\.0)).count, 1, "Every delta must update the same card")

        let commandSteps = result.steps.filter { $0.toolCall?.id == "live-command" }
        XCTAssertEqual(commandSteps.count, 1)
        let step = try XCTUnwrap(commandSteps.first)
        XCTAssertEqual(step.id, eventSnapshot.events.first?.0)
        XCTAssertEqual(step.toolResult?.content, "authoritative final terminal result")
        let progress = try XCTUnwrap(step.terminalProgress)
        XCTAssertTrue(progress.stdout.contains("ready at ."), progress.stdout)
        XCTAssertFalse(progress.stdout.contains(fixture.root.path), progress.stdout)
        XCTAssertFalse(progress.stdout.contains("runtime-stream-secret"), progress.stdout)
        XCTAssertTrue(progress.stdout.contains("[REDACTED]"), progress.stdout)
        XCTAssertTrue(progress.stderr.contains("warning-stream"), progress.stderr)
        XCTAssertLessThanOrEqual(progress.stdout.utf8.count, 16 * 1_024)
        XCTAssertLessThanOrEqual(progress.stderr.utf8.count, 16 * 1_024)
        XCTAssertTrue(progress.truncated)

        let toolMessages = result.messages.filter {
            $0.role == .tool && $0.toolCallID == "live-command"
        }
        XCTAssertEqual(toolMessages.count, 1, "Progress must never become a provider tool message")
    }

    func testRuntimePauseKeepsPartialOutputWithoutFabricatingToolResult() async throws {
        let fixture = try await runtimeFixture(blocksUntilCancelled: true, label: "pause")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let events = RuntimeProgressEventProbe()
        let runtime = fixture.runtime
        let session = makeSession(root: fixture.root)
        let provider = scriptedProvider(includeFinal: false)
        let settings = runtimeSettings()
        let running = Task {
            await runtime.run(
                session: session,
                userRequest: "stream then pause",
                provider: provider,
                settings: settings,
                approvalHandler: nil,
                eventHandler: { event in await events.record(event) }
            )
        }
        await events.waitForProgress()
        let pausedFromController = await runtime.pause()
        let paused = await running.value

        XCTAssertEqual(pausedFromController?.state, .paused)
        XCTAssertEqual(paused.state, .paused)
        let commandSteps = paused.steps.filter { $0.toolCall?.id == "live-command" }
        XCTAssertEqual(commandSteps.count, 1)
        XCTAssertEqual(commandSteps.first?.status, .cancelled)
        XCTAssertNotNil(commandSteps.first?.terminalProgress)
        XCTAssertNil(commandSteps.first?.toolResult)
        XCTAssertFalse(paused.messages.contains {
            $0.role == .tool && $0.toolCallID == "live-command"
        })
    }

    private struct RuntimeFixture {
        var root: URL
        var runtime: AgentRuntime
    }

    private func runtimeFixture(
        blocksUntilCancelled: Bool,
        label: String
    ) async throws -> RuntimeFixture {
        let root = try makeRoot("runtime-live-\(label)")
        let registry = ToolRegistry()
        try await registry.register(
            RuntimeProgressTerminalTool(blocksUntilCancelled: blocksUntilCancelled)
        )
        return RuntimeFixture(
            root: root,
            runtime: AgentRuntime(
                registry: registry,
                executor: ToolExecutor(registry: registry)
            )
        )
    }

    private func scriptedProvider(includeFinal: Bool) -> TerminalProgressScriptProvider {
        var responses = [
            AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [
                    AgentToolCall(
                        id: "live-command",
                        name: "run_command",
                        arguments: .object(["command": .string("printf live")])
                    )
                ],
                finishReason: "tool_calls",
                usage: nil
            )
        ]
        if includeFinal {
            responses.append(
                AgentModelResponse(
                    content: "finished",
                    reasoningSummary: nil,
                    toolCalls: [],
                    finishReason: "stop",
                    usage: nil
                )
            )
        }
        return TerminalProgressScriptProvider(responses: responses)
    }

    private func runtimeSettings() -> AgentSettings {
        var settings = AgentSettings()
        settings.permissionMode = .fullAccess
        settings.autoRunTests = false
        settings.maxSteps = 4
        return settings
    }

    private func makeSession(root: URL) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.model = "terminal-progress-model"
        session.workspace = workspace(root)
        return session
    }

    private func workspace(_ root: URL) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false
        )
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "terminal-stream-agent-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
