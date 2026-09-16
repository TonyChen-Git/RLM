import Foundation
import XCTest

@testable import LumaChat

final class BuiltinToolRegistrationTests: XCTestCase {
  func testSpecListedToolsExposeExpectedMetadataAndSchemas() async throws {
    let registry = ToolRegistry()
    try await BuiltinToolFactory.register(in: registry, todoManager: TodoManager())

    let expected: [String: (AgentToolCategory, AgentPermissionLevel, Bool, Set<String>)] = [
      "create_file": (.filesystem, .write, false, ["path", "content"]),
      "write_file": (.filesystem, .write, false, ["path", "content"]),
      "create_directory": (.filesystem, .write, false, ["path"]),
      "process_status": (.terminal, .read, true, ["process_id"]),
      "read_process_output": (.terminal, .read, true, ["process_id"]),
      "write_process_input": (.terminal, .execute, false, ["process_id"]),
      "stop_process": (.terminal, .execute, false, ["process_id"]),
      "undo_change": (.filesystem, .write, false, ["change_id"]),
      "git_status": (.git, .read, true, []),
      "git_branch": (.git, .read, true, []),
      "git_current_branch": (.git, .read, true, []),
      "git_reset_hard": (.git, .dangerous, false, ["reference"]),
      "git_merge_continue": (.git, .write, false, []),
      "git_merge_abort": (.git, .dangerous, false, []),
      "git_rebase_continue": (.git, .dangerous, false, []),
      "git_rebase_abort": (.git, .dangerous, false, []),
      "git_cherry_pick_continue": (.git, .write, false, []),
      "git_cherry_pick_abort": (.git, .dangerous, false, []),
      "pull_request_get": (.git, .read, true, ["repository", "pull_request_id"]),
      "pull_request_context": (.git, .read, true, ["repository", "pull_request_id"]),
      "pull_request_create": (
        .git,
        .dangerous,
        false,
        ["repository", "title", "head_branch", "base_branch"]
      ),
      "fetch_url": (.web, .read, true, ["url"]),
      "http_request": (.web, .dangerous, false, ["url", "method"]),
    ]

    for (name, value) in expected {
      let registered = await registry.tool(named: name)
      let tool = try XCTUnwrap(registered, "Missing built-in tool \(name)")
      XCTAssertEqual(tool.id, "builtin.\(name)")
      XCTAssertEqual(tool.category, value.0)
      XCTAssertEqual(tool.permissionLevel, value.1)
      XCTAssertEqual(tool.supportsParallelExecution, value.2)
      let required = Set(
        tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      )
      XCTAssertEqual(required, value.3, "Unexpected required arguments for \(name)")
      XCTAssertEqual(tool.inputSchema["additionalProperties"]?.boolValue, false)
    }
  }

  func testPullRequestToolsExposeNetworkCapabilityAndGateRemoteMutation() async throws {
    let registry = ToolRegistry()
    try await BuiltinToolFactory.register(in: registry, todoManager: TodoManager())

    for name in ["pull_request_get", "pull_request_context"] {
      let registered = await registry.tool(named: name)
      let tool = try XCTUnwrap(registered, "Missing built-in tool \(name)")
      XCTAssertEqual(tool.permissionLevel, .read)
      XCTAssertTrue(tool.requiresNetwork)
      XCTAssertTrue(tool.supportsParallelExecution)
    }

    let registeredCreate = await registry.tool(named: "pull_request_create")
    let create = try XCTUnwrap(
      registeredCreate,
      "Missing built-in tool pull_request_create"
    )
    XCTAssertEqual(create.permissionLevel, .dangerous)
    XCTAssertTrue(create.requiresNetwork)
    XCTAssertFalse(create.supportsParallelExecution)

    let context = AgentToolContext(
      sessionID: UUID(),
      mode: .agent,
      workspace: AgentWorkspace(
        name: "pull-request-authorization",
        rootPath: FileManager.default.temporaryDirectory.path,
        allowedPaths: [],
        bookmarkData: nil,
        gitRepository: false,
        branch: nil
      )
    )
    let authorization = await PermissionManager().authorize(
      metadata: ToolMetadata(tool: create),
      call: AgentToolCall(
        name: create.name,
        arguments: .object([
          "repository": .string("acme/luma"),
          "title": .string("Review"),
          "head_branch": .string("feature/review"),
          "base_branch": .string("main")
        ])
      ),
      context: context,
      permissionMode: .fullAccess,
      networkAccess: true
    )
    guard case .requireApproval(let level, _) = authorization else {
      return XCTFail("Remote Pull Request creation bypassed explicit approval")
    }
    XCTAssertEqual(level, .dangerous)
  }

  func testSpecListedFilesystemProcessAndGitToolsExecuteThroughRegistry() async throws {
    let root = try makeWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try initializeGitRepository(at: root)

    let registry = ToolRegistry()
    let environment = BuiltinToolEnvironment()
    try await BuiltinToolFactory.register(
      in: registry,
      environment: environment,
      todoManager: TodoManager()
    )
    let context = AgentToolContext(
      sessionID: UUID(),
      mode: .agent,
      workspace: AgentWorkspace(
        name: root.lastPathComponent,
        rootPath: root.path,
        allowedPaths: [],
        bookmarkData: nil,
        gitRepository: true,
        branch: "main"
      ),
      commandTimeout: 10
    )

    do {
      _ = try await execute(
        "create_directory",
        arguments: .object(["path": .string("generated")]),
        registry: registry,
        context: context
      )
      _ = try await execute(
        "create_file",
        arguments: .object([
          "path": .string("generated/note.txt"),
          "content": .string("first\n"),
        ]),
        registry: registry,
        context: context
      )
      _ = try await execute(
        "write_file",
        arguments: .object([
          "path": .string("generated/note.txt"),
          "content": .string("updated\n"),
        ]),
        registry: registry,
        context: context
      )
      XCTAssertEqual(
        try String(
          contentsOf: root.appendingPathComponent("generated/note.txt"),
          encoding: .utf8
        ),
        "updated\n"
      )

      let status = try await execute(
        "git_status",
        arguments: .emptyObject,
        registry: registry,
        context: context
      )
      XCTAssertTrue(status.content.contains("## main"))
      XCTAssertTrue(status.content.contains("generated/"))

      let branches = try await execute(
        "git_branch",
        arguments: .emptyObject,
        registry: registry,
        context: context
      )
      XCTAssertTrue(branches.content.contains("main"))

      let currentBranch = try await execute(
        "git_current_branch",
        arguments: .emptyObject,
        registry: registry,
        context: context
      )
      XCTAssertEqual(
        currentBranch.content.trimmingCharacters(in: .whitespacesAndNewlines),
        "main"
      )

      let started = try await execute(
        "start_process",
        arguments: .object([
          "command": .string("printf 'tool-ready\\n'; while IFS= read -r line; do printf 'input-bytes:%s\\n' \"${#line}\"; done")
        ]),
        registry: registry,
        context: context
      )
      let processID = try XCTUnwrap(
        started.data?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
      )

      let processStatus = try await execute(
        "process_status",
        arguments: .object(["process_id": .string(processID.uuidString)]),
        registry: registry,
        context: context
      )
      XCTAssertEqual(processStatus.data?["state"]?.stringValue, "running")

      let submittedInput = "opaque-interactive-secret-98765\n"
      let inputResult = try await execute(
        "write_process_input",
        arguments: .object([
          "process_id": .string(processID.uuidString),
          "input": .string(submittedInput),
        ]),
        registry: registry,
        context: context
      )
      XCTAssertEqual(inputResult.data?["bytesWritten"]?.intValue, submittedInput.utf8.count)
      XCTAssertFalse(inputResult.content.contains("opaque-interactive-secret-98765"))

      var output: AgentToolResult?
      for _ in 0..<50 {
        let candidate = try await execute(
          "read_process_output",
          arguments: .object(["process_id": .string(processID.uuidString)]),
          registry: registry,
          context: context
        )
        if candidate.content.contains("tool-ready") {
          output = candidate
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(output?.content.contains("tool-ready") == true)

      var inputOutput: AgentToolResult?
      for _ in 0..<50 {
        let candidate = try await execute(
          "read_process_output",
          arguments: .object(["process_id": .string(processID.uuidString)]),
          registry: registry,
          context: context
        )
        if candidate.content.contains("input-bytes:31") {
          inputOutput = candidate
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(inputOutput?.content.contains("input-bytes:31") == true)
      XCTAssertFalse(inputOutput?.content.contains("opaque-interactive-secret-98765") == true)

      let stopped = try await execute(
        "stop_process",
        arguments: .object(["process_id": .string(processID.uuidString)]),
        registry: registry,
        context: context
      )
      XCTAssertEqual(stopped.data?["state"]?.stringValue, "stopped")
    } catch {
      await environment.stopAllProcesses()
      throw error
    }
    await environment.stopAllProcesses()
  }

  private func execute(
    _ name: String,
    arguments: JSONValue,
    registry: ToolRegistry,
    context: AgentToolContext
  ) async throws -> AgentToolResult {
    let registered = await registry.tool(named: name)
    let tool = try XCTUnwrap(registered, "Missing built-in tool \(name)")
    return try await tool.execute(arguments: arguments, context: context)
  }

  private func makeWorkspaceRoot() throws -> URL {
    let root = AppPaths.projectTemporaryRoot
      .appendingPathComponent("builtin-tool-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func initializeGitRepository(at root: URL) throws {
    _ = try runGit(["init", "--initial-branch=main"], at: root)
    _ = try runGit(["config", "user.name", "Luma Chat Tests"], at: root)
    _ = try runGit(["config", "user.email", "tests@invalid.local"], at: root)
    try Data("seed\n".utf8).write(to: root.appendingPathComponent("seed.txt"))
    _ = try runGit(["add", "seed.txt"], at: root)
    _ = try runGit(["commit", "--no-gpg-sign", "-m", "seed"], at: root)
  }

  @discardableResult
  private func runGit(_ arguments: [String], at root: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
    guard process.terminationStatus == 0 else {
      throw GitServiceError.commandFailed(
        command: "git \(arguments.joined(separator: " "))",
        exitCode: process.terminationStatus,
        output: text
      )
    }
    return text
  }
}
