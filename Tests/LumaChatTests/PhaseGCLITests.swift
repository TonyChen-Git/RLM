import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class PhaseGCLITests: XCTestCase {
    func testParserRecognizesCompleteTopLevelCommandSurface() throws {
        let parser = LumaCLIParser()
        let taskID = UUID()

        XCTAssertEqual(
            try parser.parse(arguments: ["chat", "hello"]).command,
            .chat(prompt: "hello", timeoutSeconds: nil)
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["agent", "inspect", "this"]).command,
            .agent(
                prompt: "inspect this",
                options: LumaCLITaskOptions(
                    taskID: nil,
                    mode: .agent,
                    title: nil,
                    workspacePath: nil,
                    backendID: nil,
                    modelID: nil,
                    timeoutSeconds: nil
                )
            )
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["resume", "--task-id", taskID.uuidString]).command,
            .resume(LumaCLIResumeOptions(
                taskID: taskID,
                prompt: nil,
                timeoutSeconds: nil
            ))
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["tasks"]).command,
            .tasks(.list(includeArchived: false))
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["projects", "--all"]).command,
            .projects(.list(includeArchived: true))
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["skills", "show", "swift-review"]).command,
            .skills(.show(id: "swift-review"))
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["mcp"]).command,
            .mcp(.list(includeArchived: false))
        )
        XCTAssertEqual(
            try parser.parse(arguments: ["plugins", "show", "com.example.plugin"]).command,
            .plugins(.show(id: "com.example.plugin"))
        )
    }

    func testExecParsesSharedServerContractFieldsAndForcesNonInteractiveMode() throws {
        let taskID = UUID()
        let invocation = try LumaCLIParser().parse(arguments: [
            "--jsonl",
            "exec",
            "--task-id", taskID.uuidString,
            "--backend", "ollama",
            "--model", "qwen3.8:latest",
            "--timeout", "120",
            "fix", "the", "tests"
        ])

        XCTAssertEqual(invocation.outputFormat, .jsonLines)
        XCTAssertEqual(invocation.interactionMode, .nonInteractive)
        XCTAssertEqual(invocation.approvalPolicy, .deny)
        XCTAssertEqual(invocation.backend.backendID, "ollama")
        XCTAssertEqual(invocation.backend.modelID, "qwen3.8:latest")
        XCTAssertEqual(
            invocation.command,
            .exec(
                prompt: "fix the tests",
                options: LumaCLITaskOptions(
                    taskID: taskID,
                    mode: .agent,
                    title: nil,
                    workspacePath: nil,
                    backendID: "ollama",
                    modelID: "qwen3.8:latest",
                    timeoutSeconds: 120
                )
            )
        )
    }

    func testParserRejectsAmbiguousOrInteractiveOnlyNoninteractiveInput() throws {
        let parser = LumaCLIParser()

        XCTAssertThrowsError(try parser.parse(arguments: ["exec"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["chat", "--non-interactive"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["agent", "--non-interactive"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["resume", "continue"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["tasks", "show", "one", "two"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["tasks", "show", "not-a-uuid"]))
        XCTAssertThrowsError(try parser.parse(arguments: ["projects", "show", "id", "--all"]))
        XCTAssertThrowsError(try parser.parse(arguments: [
            "agent", "--task-id", UUID().uuidString, "--mode", "plan", "continue"
        ]))
        XCTAssertThrowsError(try parser.parse(arguments: [
            "exec", "--task-id", UUID().uuidString, "--workspace", "/tmp", "work"
        ]))
        XCTAssertThrowsError(try parser.parse(arguments: [
            "exec", "--backend", "ollama", "--backend", "mlx", "work"
        ]))
        XCTAssertThrowsError(try parser.parse(arguments: ["unknown-command"]))
    }

    func testRunnerCreatesTaskThenSendsUsingReturnedExplicitID() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.createResult = LumaCLIHostResult(
            summary: "created",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.sendResult = LumaCLIHostResult(
            summary: "done",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.sendEvents = [
            LumaCLIEvent(kind: .content, message: "fixed", taskID: taskID, sequence: 1)
        ]
        let io = RecordingCLIIO()
        let workspace = try makeCLIWorkspace()
        let runner = LumaCLIRunner(
            host: host,
            io: io,
            workingDirectory: workspace.path
        )

        let exit = await runner.run(arguments: [
            "exec", "--backend", "ollama", "--model", "qwen3.8", "fix tests"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.success.rawValue)
        XCTAssertEqual(host.createdRequests, [LumaCLICreateTaskRequest(
            mode: .agent,
            title: nil,
            workspacePath: workspace.path,
            backendID: "ollama",
            modelID: "qwen3.8"
        )])
        XCTAssertEqual(host.sentTaskIDs, [taskID])
        let request = try XCTUnwrap(host.sentRequests.first)
        XCTAssertEqual(request.prompt, "fix tests")
        XCTAssertEqual(request.interactionMode, .nonInteractive)
        XCTAssertEqual(request.approvalPolicy, .deny)
        XCTAssertTrue(io.standardOutput.contains("done"))
        XCTAssertTrue(io.standardOutput.contains("fixed"))
    }

    func testExistingTaskExecutionNeverCreatesOrSelectsImplicitTask() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.sendResult = LumaCLIHostResult(
            summary: "continued",
            taskID: taskID,
            backendID: "mlx",
            modelID: "local-model"
        )
        host.taskResult = LumaCLIHostResult(
            summary: "task",
            taskID: taskID,
            backendID: "mlx",
            modelID: "local-model"
        )
        let io = RecordingCLIIO()
        let runner = LumaCLIRunner(host: host, io: io)

        let exit = await runner.run(arguments: [
            "agent", "--task-id", taskID.uuidString,
            "--backend", "mlx", "--model", "local-model", "continue"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.success.rawValue)
        XCTAssertTrue(host.createdRequests.isEmpty)
        XCTAssertEqual(host.sentTaskIDs, [taskID])
        XCTAssertEqual(host.sentRequests.first?.prompt, "continue")
    }

    func testExplicitBackendMismatchFailsClosedInsteadOfAcceptingFallback() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.sendResult = LumaCLIHostResult(
            summary: "unexpected fallback",
            taskID: taskID,
            backendID: "openAI",
            modelID: "cloud-model"
        )
        host.taskResult = LumaCLIHostResult(
            summary: "task",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        let io = RecordingCLIIO()
        let runner = LumaCLIRunner(host: host, io: io)

        let exit = await runner.run(arguments: [
            "exec", "--task-id", taskID.uuidString,
            "--backend", "ollama", "--model", "qwen3.8", "work"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.unavailable.rawValue)
        XCTAssertTrue(io.standardError.contains("fallback is disabled"))
    }

    func testBackendUnavailableUsesStableServiceUnavailableExitCode() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.sendError = LumaCLIError.backendUnavailable("Ollama is not reachable.")
        let io = RecordingCLIIO()

        let exit = await LumaCLIRunner(host: host, io: io).run(arguments: [
            "exec", "--task-id", taskID.uuidString, "repair"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.unavailable.rawValue)
        XCTAssertTrue(io.standardError.contains("Ollama is not reachable"))
        XCTAssertFalse(io.standardError.localizedCaseInsensitiveContains("cloud fallback"))
    }

    func testNoninteractiveApprovalEventFailsWithPermissionExitCode() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.sendResult = LumaCLIHostResult(
            summary: "must not succeed",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen"
        )
        host.sendEvents = [
            LumaCLIEvent(
                kind: .approvalRequired,
                message: "shell approval required",
                taskID: taskID
            )
        ]
        let io = RecordingCLIIO()

        let exit = await LumaCLIRunner(host: host, io: io).run(arguments: [
            "exec", "--task-id", taskID.uuidString, "run command"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.permissionDenied.rawValue)
        XCTAssertTrue(io.standardError.contains("approval was required"))
    }

    func testResumeAndCatalogCommandsForwardExplicitRequests() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.resumeResult = LumaCLIHostResult(
            summary: "resumed",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.taskResult = LumaCLIHostResult(
            summary: "task",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.tasksResult = LumaCLIHostResult(
            summary: "1 task",
            payload: .array([.object(["id": .string(taskID.uuidString.lowercased())])])
        )
        let resumeIO = RecordingCLIIO()
        let tasksIO = RecordingCLIIO()

        let resumeExit = await LumaCLIRunner(host: host, io: resumeIO).run(arguments: [
            "resume", "--task-id", taskID.uuidString, "continue carefully"
        ])
        let tasksExit = await LumaCLIRunner(host: host, io: tasksIO).run(arguments: [
            "tasks", "list", "--all", "--json"
        ])

        XCTAssertEqual(resumeExit, LumaCLIExitCode.success.rawValue)
        XCTAssertEqual(host.resumedTaskIDs, [taskID])
        let resumeRequest = try XCTUnwrap(host.resumeRequests.first)
        XCTAssertEqual(resumeRequest.prompt, "continue carefully")
        XCTAssertEqual(tasksExit, LumaCLIExitCode.success.rawValue)
        XCTAssertEqual(host.taskActions, [.list(includeArchived: true)])
        XCTAssertTrue(tasksIO.standardOutput.contains("\"success\" : true"))
    }

    func testMachineReadableUsageFailureDoesNotPolluteStandardOutput() async throws {
        let host = RecordingCLIHost()
        let io = RecordingCLIIO()

        let exit = await LumaCLIRunner(host: host, io: io).run(arguments: [
            "--json", "exec"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.usage.rawValue)
        XCTAssertTrue(io.standardOutput.isEmpty)
        XCTAssertTrue(io.standardError.contains("\"type\" : \"error\""))
        XCTAssertTrue(io.standardError.contains("\"code\" : 2"))
    }

    func testSingleJSONEnvelopeBoundsRetainedLongRunningEvents() async throws {
        let taskID = UUID()
        let host = RecordingCLIHost()
        host.taskResult = LumaCLIHostResult(
            summary: "task",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.sendResult = LumaCLIHostResult(
            summary: "done",
            taskID: taskID,
            backendID: "ollama",
            modelID: "qwen3.8"
        )
        host.sendEvents = (0..<4_100).map {
            LumaCLIEvent(kind: .status, message: "event-\($0)", taskID: taskID)
        }
        let io = RecordingCLIIO()

        let exit = await LumaCLIRunner(host: host, io: io).run(arguments: [
            "--json", "exec", "--task-id", taskID.uuidString, "inspect"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.success.rawValue)
        XCTAssertTrue(io.standardOutput.contains("\"eventsTruncated\" : true"))
        XCTAssertTrue(io.standardOutput.contains("\"droppedEventCount\" : 4"))
    }

    func testFrontendOnlyCommandsDoNotRequireAHost() async throws {
        let helpIO = RecordingCLIIO()
        let versionIO = RecordingCLIIO()

        let helpExit = await LumaCLIRunner(host: nil, io: helpIO).run(arguments: ["--help"])
        let versionExit = await LumaCLIRunner(host: nil, io: versionIO).run(arguments: ["--version"])

        XCTAssertEqual(helpExit, LumaCLIExitCode.success.rawValue)
        XCTAssertEqual(versionExit, LumaCLIExitCode.success.rawValue)
        XCTAssertTrue(helpIO.standardOutput.contains("Usage: lumachat"))
        XCTAssertTrue(versionIO.standardOutput.contains("LumaChat"))
    }

    func testSingleJSONEnvelopeDropsOversizedTerminalPayload() async throws {
        let host = RecordingCLIHost()
        host.tasksResult = LumaCLIHostResult(
            summary: "tasks",
            payload: .string(String(repeating: "x", count: 16 * 1_024 * 1_024))
        )
        let io = RecordingCLIIO()

        let exit = await LumaCLIRunner(host: host, io: io).run(arguments: [
            "--json", "tasks"
        ])

        XCTAssertEqual(exit, LumaCLIExitCode.success.rawValue)
        XCTAssertTrue(io.standardOutput.contains("\"resultTruncated\" : true"))
        XCTAssertFalse(io.standardOutput.contains(String(repeating: "x", count: 1_024)))
    }

    private func makeCLIWorkspace() throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-g-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Retain project-local fixtures because this checkout may be on ExFAT;
        // recursive teardown could silently remove filesystem-created `._*`
        // AppleDouble files, which repository policy explicitly preserves.
        return root.standardizedFileURL
    }
}

@MainActor
private final class RecordingCLIIO: LumaCLIIO {
    var standardOutput = ""
    var standardError = ""
    var inputLines: [String] = []

    func writeStandardOutput(_ text: String) {
        standardOutput += text
    }

    func writeStandardError(_ text: String) {
        standardError += text
    }

    func readLine(prompt: String) -> String? {
        standardError += prompt
        guard !inputLines.isEmpty else { return nil }
        return inputLines.removeFirst()
    }
}

@MainActor
private final class RecordingCLIHost: LumaCLIHost {
    var createdRequests: [LumaCLICreateTaskRequest] = []
    var sentTaskIDs: [UUID] = []
    var sentRequests: [LumaCLITaskMessageRequest] = []
    var resumedTaskIDs: [UUID] = []
    var resumeRequests: [LumaCLIResumeRequest] = []
    var taskActions: [LumaCLIResourceAction] = []
    var projectActions: [LumaCLIResourceAction] = []
    var skillActions: [LumaCLIResourceAction] = []
    var mcpActions: [LumaCLIResourceAction] = []
    var pluginActions: [LumaCLIResourceAction] = []

    var chatResult = LumaCLIHostResult(summary: "chat")
    var createResult = LumaCLIHostResult(summary: "created")
    var sendResult = LumaCLIHostResult(summary: "sent")
    var resumeResult = LumaCLIHostResult(summary: "resumed")
    var tasksResult = LumaCLIHostResult(summary: "tasks")
    var projectsResult = LumaCLIHostResult(summary: "projects")
    var skillsResult = LumaCLIHostResult(summary: "skills")
    var mcpResult = LumaCLIHostResult(summary: "mcp")
    var pluginsResult = LumaCLIHostResult(summary: "plugins")
    var taskResult: LumaCLIHostResult?
    var sendEvents: [LumaCLIEvent] = []
    var sendError: Error?
    var resolvedBackend = LumaCLIBackendSelection(backendID: "ollama", modelID: "qwen3.8")

    func resolveBackend(
        selection: LumaCLIBackendSelection
    ) async throws -> LumaCLIBackendSelection {
        LumaCLIBackendSelection(
            backendID: selection.backendID ?? resolvedBackend.backendID,
            modelID: selection.modelID ?? resolvedBackend.modelID
        )
    }

    func chat(
        request _: LumaCLIChatRequest,
        eventHandler _: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        chatResult
    }

    func createTask(request: LumaCLICreateTaskRequest) async throws -> LumaCLIHostResult {
        createdRequests.append(request)
        return createResult
    }

    func task(id: UUID) async throws -> LumaCLIHostResult {
        taskResult ?? LumaCLIHostResult(
            summary: "task",
            taskID: id,
            backendID: sendResult.backendID ?? resolvedBackend.backendID,
            modelID: sendResult.modelID ?? resolvedBackend.modelID
        )
    }

    func sendMessage(
        taskID: UUID,
        request: LumaCLITaskMessageRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        sentTaskIDs.append(taskID)
        sentRequests.append(request)
        if let sendError { throw sendError }
        for event in sendEvents { await eventHandler(event) }
        return sendResult
    }

    func resume(
        taskID: UUID,
        request: LumaCLIResumeRequest,
        eventHandler _: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        resumedTaskIDs.append(taskID)
        resumeRequests.append(request)
        return resumeResult
    }

    func tasks(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        taskActions.append(action)
        return tasksResult
    }

    func projects(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        projectActions.append(action)
        return projectsResult
    }

    func skills(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        skillActions.append(action)
        return skillsResult
    }

    func mcp(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        mcpActions.append(action)
        return mcpResult
    }

    func plugins(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        pluginActions.append(action)
        return pluginsResult
    }
}
