import XCTest
@testable import LumaChat

final class AgentTaskForkBuilderTests: XCTestCase {
    func testWritableForkCopiesBoundedDurableContextButNotExecutionState() throws {
        let now = Date(timeIntervalSince1970: 42_000)
        let sourceWorkspace = AgentWorkspace(
            name: "source",
            rootPath: "/repo/source",
            allowedPaths: [],
            bookmarkData: Data([1, 2, 3]),
            gitRepository: true,
            branch: "main"
        )
        let targetWorkspace = AgentWorkspace(
            name: "fork-worktree",
            rootPath: "/managed/fork",
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "lumachat/fork"
        )
        var source = AgentSession(mode: .agent)
        source.title = "Implement the durable worktree handoff"
        source.state = .awaitingApproval
        source.workspace = sourceWorkspace
        source.projectID = UUID()
        source.projectFolderID = UUID()
        source.messages = [
            AgentMessage(role: .user, content: "Preserve this requirement"),
            AgentMessage(
                role: .assistant,
                content: "I inspected the repository.",
                toolCalls: [AgentToolCall(name: "read_file", arguments: .object([:]))]
            ),
            AgentMessage(role: .tool, content: "private execution result", toolCallID: "call-1")
        ]
        source.steps = [AgentStep(kind: .running, title: "Live", status: .running)]
        source.todos = [AgentTodo(title: "Keep me", status: .inProgress)]
        source.goal = try AgentGoal(objective: "Finish Phase A")
        source.changes = [
            AgentChangeRecord(
                relativePath: "file.swift",
                kind: .modify,
                unifiedDiff: "+change"
            )
        ]
        source.permissionAllowances = [
            AgentPermissionAllowance(
                toolID: "builtin.run_command",
                toolName: "run_command",
                category: "terminal",
                effectiveLevel: "execute",
                workspaceRoot: sourceWorkspace.rootPath,
                argumentScope: nil
            )
        ]

        let worktreeID = UUID()
        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: targetWorkspace,
            executionLocation: .worktree(id: worktreeID, label: "fork"),
            localWorkspace: sourceWorkspace,
            localProjectFolderID: source.projectFolderID,
            now: now
        )

        XCTAssertNotEqual(fork.id, source.id)
        XCTAssertEqual(fork.state, .idle)
        XCTAssertEqual(fork.workspace, targetWorkspace)
        XCTAssertEqual(fork.resolvedExecutionLocation.managedWorktreeID, worktreeID)
        XCTAssertEqual(fork.localWorkspace, sourceWorkspace)
        XCTAssertEqual(fork.projectID, source.projectID)
        XCTAssertNil(fork.projectFolderID)
        XCTAssertEqual(fork.localProjectFolderID, source.projectFolderID)
        XCTAssertTrue(fork.steps.isEmpty)
        XCTAssertTrue(fork.changes.isEmpty)
        XCTAssertEqual(fork.permissionAllowances, [])
        XCTAssertEqual(fork.messages.count, 1)
        XCTAssertEqual(fork.messages[0].role, .system)
        XCTAssertTrue(fork.messages[0].content.contains("Preserve this requirement"))
        XCTAssertFalse(fork.messages[0].content.contains("private execution result"))
        XCTAssertTrue(fork.messages[0].toolCalls.isEmpty)
        XCTAssertEqual(fork.todos.map(\.title), ["Keep me"])
        XCTAssertNotEqual(fork.todos[0].id, source.todos[0].id)
        XCTAssertEqual(fork.goal?.objective, source.goal?.objective)
        XCTAssertNotEqual(fork.goal?.id, source.goal?.id)
        XCTAssertEqual(fork.forkOrigin?.sourceSessionID, source.id)
        XCTAssertEqual(fork.createdAt, now)
    }

    func testForkSummaryIsBoundedOnAUnicodeBoundary() throws {
        let workspace = AgentWorkspace(
            name: "repo",
            rootPath: "/repo",
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        var source = AgentSession(mode: .plan)
        source.workspace = workspace
        source.messages = [
            AgentMessage(
                role: .user,
                content: String(repeating: "界", count: AgentTaskForkBuilder.maximumSummaryBytes)
            )
        ]

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: workspace,
            executionLocation: .local,
            localWorkspace: nil,
            localProjectFolderID: nil
        )

        let content = try XCTUnwrap(fork.messages.first?.content)
        XCTAssertLessThanOrEqual(
            content.utf8.count,
            AgentTaskForkBuilder.maximumSummaryBytes + 64
        )
        XCTAssertTrue(content.hasSuffix("[fork context truncated]"))
    }

    func testPrePhaseASessionDecodesAsLocalExecution() throws {
        let oldJSON = #"""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "title":"Legacy",
          "mode":"agent",
          "state":"idle",
          "messages":[],"steps":[],"todos":[],"changes":[],
          "model":"qwen","provider":"ollama",
          "createdAt":0,"updatedAt":0
        }
        """#
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(oldJSON.utf8))
        XCTAssertNil(session.executionLocation)
        XCTAssertEqual(session.resolvedExecutionLocation.kind, .local)
    }

    func testForkCarriesBoundedCheckpointProvenanceAndExplicitLocalBaseline() throws {
        let sourceWorkspace = AgentWorkspace(
            name: "source",
            rootPath: "/repo/source",
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let targetWorkspace = AgentWorkspace(
            name: "target",
            rootPath: "/repo/target",
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "fork"
        )
        var source = AgentSession(mode: .agent)
        source.workspace = sourceWorkspace
        source.checkpointReferences = (0..<300).map { index in
            AgentCheckpointReference(
                checkpointID: UUID(),
                sessionID: source.id,
                workspaceID: sourceWorkspace.id,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                relativeManifestPath: "checkpoint-\(index).json",
                gitState: nil
            )
        }
        let fingerprint = String(repeating: "a", count: 64)
        let worktreeID = UUID()

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: targetWorkspace,
            executionLocation: .worktree(id: worktreeID, label: "fork"),
            localWorkspace: sourceWorkspace,
            localProjectFolderID: nil,
            localCheckoutBaselineFingerprint: fingerprint,
            localCheckoutBaselineSupplementalPaths: ["Sources", "Package.swift"],
            localCheckoutBaselineReference: "refs/heads/main"
        )

        XCTAssertEqual(fork.localCheckoutBaselineFingerprint, fingerprint)
        XCTAssertEqual(
            fork.localCheckoutBaselineSupplementalPaths,
            ["Sources", "Package.swift"]
        )
        XCTAssertEqual(fork.localCheckoutBaselineReference, "refs/heads/main")
        XCTAssertEqual(fork.checkpointReferences?.count, 256)
        XCTAssertEqual(
            fork.checkpointReferences?.first?.relativeManifestPath,
            "checkpoint-44.json"
        )
        XCTAssertEqual(
            fork.checkpointReferences?.last?.relativeManifestPath,
            "checkpoint-299.json"
        )
    }
}
