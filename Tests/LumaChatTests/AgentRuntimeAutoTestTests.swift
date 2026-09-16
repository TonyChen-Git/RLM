import Foundation
import XCTest

@testable import LumaChat

private actor AutoTestScriptProvider: AgentModelProvider {
  nonisolated let id = "auto-test-script"
  private var responses: [AgentModelResponse]
  private var capturedRequests: [AgentModelRequest] = []

  init(_ responses: [AgentModelResponse]) {
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
      contextWindow: 8_192,
      maxOutputTokens: 1_024
    )
  }

  func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
    capturedRequests.append(request)
    guard !responses.isEmpty else {
      throw ProviderWireError.invalidRequest("auto-test response script exhausted")
    }
    return responses.removeFirst()
  }

  func requests() -> [AgentModelRequest] { capturedRequests }
}

private actor AutoTestToolProbe {
  private var testFailures: [Bool]
  private(set) var changeCount = 0
  private(set) var testCount = 0

  init(testFailures: [Bool]) {
    self.testFailures = testFailures
  }

  func makeChange() -> AgentToolResult {
    changeCount += 1
    let path = "Changed-\(changeCount).swift"
    return AgentToolResult(
      content: "changed \(path)",
      change: AgentChangeRecord(
        relativePath: path,
        kind: .modify,
        unifiedDiff: "--- a/\(path)\n+++ b/\(path)"
      )
    )
  }

  func runTest() -> AgentToolResult {
    testCount += 1
    let failed = testFailures.isEmpty ? false : testFailures.removeFirst()
    return AgentToolResult(
      content: failed ? "tests failed" : "tests passed",
      isError: failed
    )
  }

  func counts() -> (changes: Int, tests: Int) {
    (changeCount, testCount)
  }
}

private struct AutoTestChangeTool: AgentTool {
  let probe: AutoTestToolProbe
  let id = "auto-test-change"
  let name = "auto_test_change"
  let displayName = "Change File"
  let description = "Produces a tracked filesystem change for runtime tests."
  let inputSchema = JSONValue.objectSchema(properties: [:])
  let category = AgentToolCategory.filesystem
  let permissionLevel = AgentPermissionLevel.write
  let supportsParallelExecution = false

  func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
    await probe.makeChange()
  }
}

private struct AutoTestValidationTool: AgentTool {
  let probe: AutoTestToolProbe
  let id = "auto-test-validation"
  let name = "test"
  let displayName = "Test Project"
  let description = "Runs the project test suite."
  let inputSchema = JSONValue.objectSchema(properties: [:])
  let category = AgentToolCategory.terminal
  let permissionLevel = AgentPermissionLevel.execute
  let supportsParallelExecution = false

  func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
    await probe.runTest()
  }
}

private struct AutoTestTerminalMutationTool: AgentTool {
  let id = "auto-test-terminal-mutation"
  let name = "run_command"
  let displayName = "Run Command"
  let description = "Represents an arbitrary shell command without a native change record."
  let inputSchema = JSONValue.objectSchema(
    properties: ["command": .stringSchema()],
    required: ["command"]
  )
  let category = AgentToolCategory.terminal
  let permissionLevel = AgentPermissionLevel.execute
  let supportsParallelExecution = false

  func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
    AgentToolResult(content: "shell command completed")
  }
}

private struct AutoTestMCPMutationTool: AgentTool {
  let id = "mcp.auto-test.mutate"
  let name = "mcp.auto-test.mutate"
  let displayName = "MCP Mutate"
  let description = "Represents a mutation-capable MCP tool."
  let inputSchema = JSONValue.objectSchema(properties: [:])
  let category = AgentToolCategory.mcp
  let permissionLevel = AgentPermissionLevel.execute
  let supportsParallelExecution = false

  func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
    AgentToolResult(
      content: "external MCP mutation completed",
      mayHaveChangedWorkspace: true
    )
  }
}

private actor AutoTestBlockingProbe {
  private var started = false

  func markStarted() { started = true }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }
}

private struct AutoTestBlockingValidationTool: AgentTool {
  let probe: AutoTestBlockingProbe
  let id = "auto-test-blocking-validation"
  let name = "test"
  let displayName = "Test Project"
  let description = "Waits until the automatic test is cancelled."
  let inputSchema = JSONValue.objectSchema(properties: [:])
  let category = AgentToolCategory.terminal
  let permissionLevel = AgentPermissionLevel.execute
  let supportsParallelExecution = false

  func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
    await probe.markStarted()
    try await Task.sleep(for: .seconds(60))
    return AgentToolResult(content: "unexpected test completion")
  }
}

private actor AutoTestApprovalProbe {
  private var toolNames: [String] = []

  func approve(_ request: AgentApprovalRequest) -> AgentApprovalDecision {
    toolNames.append(request.toolName)
    return .allowOnce
  }

  func names() -> [String] { toolNames }
}

final class AgentRuntimeAutoTestTests: XCTestCase {
  func testExecutedShellCommandTriggersAutomaticValidationWithoutNativeChangeRecord() async throws {
    let root = AppPaths.projectTemporaryRoot
      .appendingPathComponent("auto-test-shell-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = AutoTestToolProbe(testFailures: [false])
    let registry = ToolRegistry()
    try await registry.register([
      AutoTestTerminalMutationTool(),
      AutoTestValidationTool(probe: probe),
    ])
    let runtime = AgentRuntime(
      registry: registry,
      executor: ToolExecutor(registry: registry)
    )
    let provider = AutoTestScriptProvider([
      AgentModelResponse(
        content: "",
        reasoningSummary: nil,
        toolCalls: [
          AgentToolCall(
            id: "shell-1",
            name: "run_command",
            arguments: .object(["command": .string("formatter .")])
          )
        ],
        finishReason: "tool_calls",
        usage: nil
      ),
      Self.finalResponse("shell validated"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 4

    let result = await runtime.run(
      session: makeSession(root: root),
      userRequest: "run formatter",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed, result.lastError ?? "")
    let counts = await probe.counts()
    XCTAssertEqual(counts.tests, 1)
    XCTAssertTrue(result.steps.contains { $0.kind == .testing && $0.status == .completed })
  }

  func testMutationCapableMCPResultTriggersAutomaticValidation() async throws {
    let root = try makeWorkspaceRoot("mcp-mutation")
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = AutoTestToolProbe(testFailures: [false])
    let registry = ToolRegistry()
    try await registry.register([
      AutoTestMCPMutationTool(),
      AutoTestValidationTool(probe: probe),
    ])
    let runtime = AgentRuntime(
      registry: registry,
      executor: ToolExecutor(registry: registry)
    )
    let provider = AutoTestScriptProvider([
      AgentModelResponse(
        content: "",
        reasoningSummary: nil,
        toolCalls: [AgentToolCall(id: "mcp-1", name: "mcp.auto-test.mutate")],
        finishReason: "tool_calls",
        usage: nil
      ),
      Self.finalResponse("MCP side effect validated"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 4

    let result = await runtime.run(
      session: makeSession(root: root),
      userRequest: "Run the MCP mutation",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed, result.lastError ?? "")
    let counts = await probe.counts()
    XCTAssertEqual(counts.tests, 1)
    XCTAssertTrue(
      result.steps.contains {
        $0.toolCall?.name == "mcp.auto-test.mutate"
          && $0.toolResult?.mayHaveChangedWorkspace == true
      }
    )
  }

  func testAutomaticTestSucceedsBeforeFinalIsAdopted() async throws {
    let fixture = try await makeFixture(testFailures: [false], label: "success")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("validated final"),
    ])
    let approvals = AutoTestApprovalProbe()
    var settings = AgentSettings()
    settings.maxSteps = 4

    let result = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make a change",
      provider: provider,
      settings: settings,
      approvalHandler: { request in await approvals.approve(request) },
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed)
    XCTAssertEqual(result.messages.last?.content, "validated final")
    let counts = await fixture.probe.counts()
    let approvalNames = await approvals.names()
    XCTAssertEqual(counts.tests, 1)
    XCTAssertEqual(approvalNames, ["test"])
    let testingStep = try XCTUnwrap(
      result.steps.last { $0.kind == AgentStepKind.testing }
    )
    XCTAssertEqual(testingStep.status, .completed)
    XCTAssertEqual(testingStep.toolCall?.name, "test")
    XCTAssertEqual(testingStep.toolResult?.isError, false)
  }

  func testFailedAutomaticTestIsFedBackThenNewChangeIsRetested() async throws {
    let fixture = try await makeFixture(testFailures: [true, false], label: "repair")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("premature final"),
      Self.toolResponse(id: "change-2"),
      Self.finalResponse("fixed final"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 8

    let result = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make and verify a change",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed)
    XCTAssertEqual(result.messages.last?.content, "fixed final")
    XCTAssertFalse(result.messages.contains { $0.content == "premature final" })
    let counts = await fixture.probe.counts()
    XCTAssertEqual(counts.changes, 2)
    XCTAssertEqual(counts.tests, 2)
    let testingStatuses: [AgentStepStatus] = result.steps
      .filter { $0.kind == AgentStepKind.testing }
      .map { $0.status }
    XCTAssertEqual(testingStatuses, [.failed, .completed])
    let requests = await provider.requests()
    XCTAssertEqual(requests.count, 4)
    let sawFailedTest = requests[2].messages.contains { message in
      message.role == AgentMessageRole.tool
        && message.name == "test"
        && message.isError
        && message.content == "tests failed"
    }
    XCTAssertTrue(sawFailedTest)
  }

  func testFailedAutomaticTestDoesNotRepeatWithoutANewChange() async throws {
    let fixture = try await makeFixture(testFailures: [true], label: "no-repeat")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("first invalid final"),
      Self.finalResponse("second invalid final"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 6

    let result = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make and verify a change",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .failed)
    let counts = await fixture.probe.counts()
    let requestCount = await provider.requests().count
    XCTAssertEqual(counts.tests, 1)
    XCTAssertEqual(requestCount, 3)
    XCTAssertFalse(result.messages.contains { $0.content.contains("invalid final") })
  }

  func testAutomaticTestsCanBeDisabled() async throws {
    let fixture = try await makeFixture(testFailures: [false], label: "disabled")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("unchecked final"),
    ])
    var settings = AgentSettings()
    settings.autoRunTests = false
    settings.permissionMode = .fullAccess
    settings.maxSteps = 3

    let result = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make a change",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed)
    XCTAssertEqual(result.messages.last?.content, "unchecked final")
    let counts = await fixture.probe.counts()
    XCTAssertEqual(counts.tests, 0)
    XCTAssertFalse(result.steps.contains { $0.kind == AgentStepKind.testing })
  }

  func testStepLimitPreventsOutOfBudgetAutomaticTest() async throws {
    let fixture = try await makeFixture(testFailures: [false], label: "limit")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("must not be adopted"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 3

    let result = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make a change",
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .stepLimit)
    let counts = await fixture.probe.counts()
    XCTAssertEqual(counts.tests, 0)
    XCTAssertFalse(result.steps.contains { $0.kind == AgentStepKind.testing })
    XCTAssertFalse(result.messages.contains { $0.content == "must not be adopted" })
  }

  func testContinueFromStepLimitRestoresDirtyChangeAndRunsValidation() async throws {
    let fixture = try await makeFixture(testFailures: [false], label: "resume-limit")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let firstProvider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-before-limit"),
    ])
    var firstSettings = AgentSettings()
    firstSettings.permissionMode = .fullAccess
    firstSettings.maxSteps = 2

    let limited = await fixture.runtime.run(
      session: makeSession(root: fixture.root),
      userRequest: "Make a change before the step limit",
      provider: firstProvider,
      settings: firstSettings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(limited.state, .stepLimit)
    let limitedCounts = await fixture.probe.counts()
    XCTAssertEqual(limitedCounts.tests, 0)

    let resumedProvider = AutoTestScriptProvider([
      Self.finalResponse("validated after continue"),
    ])
    var resumedSettings = firstSettings
    resumedSettings.maxSteps = 2
    let resumed = await fixture.runtime.run(
      session: limited,
      userRequest: nil,
      provider: resumedProvider,
      settings: resumedSettings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(resumed.state, .completed, resumed.lastError ?? "")
    XCTAssertEqual(resumed.messages.last?.content, "validated after continue")
    let resumedCounts = await fixture.probe.counts()
    XCTAssertEqual(resumedCounts.tests, 1)
    XCTAssertEqual(
      resumed.steps.filter { $0.kind == .testing }.map { $0.status },
      [.completed]
    )
  }

  func testRetryRestoresPersistedTerminalAndUndoDirtyState() async throws {
    for (label, callName, duration, mayHaveChangedWorkspace) in [
      ("terminal", "run_command", 0.01, false),
      ("undo", "undo_last_change", 0.01, false),
      ("mcp", "mcp.server.mutate", nil, true),
    ] {
      let fixture = try await makeFixture(testFailures: [false], label: "restore-\(label)")
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      var session = makeSession(root: fixture.root)
      session.state = .failed
      session.steps.append(
        AgentStep(
          kind: callName == "run_command" ? .running : .editing,
          title: label,
          status: .completed,
          toolCall: AgentToolCall(name: callName),
          toolResult: AgentToolResult(
            content: "workspace may have changed",
            duration: duration,
            mayHaveChangedWorkspace: mayHaveChangedWorkspace
          ),
          completedAt: Date()
        )
      )
      let provider = AutoTestScriptProvider([
        Self.finalResponse("validated \(label) retry"),
      ])
      var settings = AgentSettings()
      settings.permissionMode = .fullAccess
      settings.maxSteps = 2

      let result = await fixture.runtime.run(
        session: session,
        userRequest: nil,
        provider: provider,
        settings: settings,
        approvalHandler: nil,
        eventHandler: { _ in }
      )

      XCTAssertEqual(result.state, .completed, "\(label): \(result.lastError ?? "")")
      let counts = await fixture.probe.counts()
      XCTAssertEqual(counts.tests, 1, label)
    }
  }

  func testPlanModeNeverRunsAutomaticTests() async throws {
    let fixture = try await makeFixture(testFailures: [false], label: "plan")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let provider = AutoTestScriptProvider([Self.finalResponse("plan final")])
    var session = makeSession(root: fixture.root, mode: .plan)
    session.state = .paused
    session.steps.append(
      AgentStep(
        kind: .editing,
        title: "Existing change",
        status: .completed,
        toolResult: AgentToolResult(
          content: "changed",
          change: AgentChangeRecord(
            relativePath: "Plan.swift",
            kind: .modify,
            unifiedDiff: "plan"
          )
        ),
        completedAt: Date()
      )
    )
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 1

    let result = await fixture.runtime.run(
      session: session,
      userRequest: nil,
      provider: provider,
      settings: settings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(result.state, .completed)
    XCTAssertEqual(result.messages.last?.content, "plan final")
    let counts = await fixture.probe.counts()
    XCTAssertEqual(counts.tests, 0)
  }

  func testPauseDuringAutomaticTestPersistsPausedAndResumeRetests() async throws {
    let root = try makeWorkspaceRoot("pause")
    defer { try? FileManager.default.removeItem(at: root) }
    let changeProbe = AutoTestToolProbe(testFailures: [false])
    let blockingProbe = AutoTestBlockingProbe()
    let registry = ToolRegistry()
    try await registry.register([
      AutoTestChangeTool(probe: changeProbe),
      AutoTestBlockingValidationTool(probe: blockingProbe),
    ])
    let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
    let provider = AutoTestScriptProvider([
      Self.toolResponse(id: "change-1"),
      Self.finalResponse("paused candidate"),
    ])
    var settings = AgentSettings()
    settings.permissionMode = .fullAccess
    settings.maxSteps = 4
    let runningSettings = settings
    let initialSession = makeSession(root: root)
    let running = Task {
      await runtime.run(
        session: initialSession,
        userRequest: "Make and verify a change",
        provider: provider,
        settings: runningSettings,
        approvalHandler: nil,
        eventHandler: { _ in }
      )
    }

    await blockingProbe.waitUntilStarted()
    let pauseResult = await runtime.pause()
    let paused = await running.value
    XCTAssertEqual(pauseResult?.state, .paused)
    XCTAssertEqual(paused.state, .paused)
    XCTAssertEqual(paused.steps.last?.kind, .testing)
    XCTAssertEqual(paused.steps.last?.status, .cancelled)
    XCTAssertFalse(
      paused.messages.contains { message in
        message.toolCalls.contains { $0.id.hasPrefix("luma_auto_test_") }
      }
    )

    _ = await registry.unregister(named: "test")
    try await registry.register(AutoTestValidationTool(probe: changeProbe))
    let resumedProvider = AutoTestScriptProvider([Self.finalResponse("resumed final")])
    var resumedSettings = settings
    resumedSettings.maxSteps = 2
    let resumed = await runtime.run(
      session: paused,
      userRequest: nil,
      provider: resumedProvider,
      settings: resumedSettings,
      approvalHandler: nil,
      eventHandler: { _ in }
    )

    XCTAssertEqual(resumed.state, .completed)
    XCTAssertEqual(resumed.messages.last?.content, "resumed final")
    let counts = await changeProbe.counts()
    XCTAssertEqual(counts.tests, 1)
    XCTAssertEqual(
      resumed.steps.filter { $0.kind == .testing }.map { $0.status },
      [.cancelled, .completed]
    )
  }

  private struct Fixture {
    let root: URL
    let runtime: AgentRuntime
    let probe: AutoTestToolProbe
  }

  private func makeFixture(testFailures: [Bool], label: String) async throws -> Fixture {
    let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
      "agent-auto-test-\(label)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let probe = AutoTestToolProbe(testFailures: testFailures)
    let registry = ToolRegistry()
    try await registry.register([
      AutoTestChangeTool(probe: probe),
      AutoTestValidationTool(probe: probe),
    ])
    return Fixture(
      root: root,
      runtime: AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry)),
      probe: probe
    )
  }

  private func makeWorkspaceRoot(_ label: String) throws -> URL {
    let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
      "agent-auto-test-\(label)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeSession(root: URL, mode: AppMode = .agent) -> AgentSession {
    var session = AgentSession(mode: mode)
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

  private static func toolResponse(id: String) -> AgentModelResponse {
    AgentModelResponse(
      content: "",
      reasoningSummary: nil,
      toolCalls: [AgentToolCall(id: id, name: "auto_test_change")],
      finishReason: "tool_calls",
      usage: nil
    )
  }

  private static func finalResponse(_ content: String) -> AgentModelResponse {
    AgentModelResponse(
      content: content,
      reasoningSummary: nil,
      toolCalls: [],
      finishReason: "stop",
      usage: nil
    )
  }
}
