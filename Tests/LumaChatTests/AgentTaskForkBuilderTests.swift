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
                reasoningSummary: "private reasoning summary",
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
        XCTAssertEqual(fork.messages.count, 3)
        XCTAssertEqual(fork.messages[0].role, .system)
        XCTAssertEqual(fork.messages[1].role, .user)
        XCTAssertEqual(fork.messages[1].content, "Preserve this requirement")
        XCTAssertEqual(fork.messages[2].role, .assistant)
        XCTAssertEqual(fork.messages[2].content, "I inspected the repository.")
        XCTAssertTrue(fork.messages.allSatisfy(\.toolCalls.isEmpty))
        XCTAssertTrue(fork.messages.allSatisfy { $0.toolCallID == nil })
        XCTAssertTrue(fork.messages.allSatisfy { $0.reasoningSummary == nil })
        XCTAssertTrue(fork.messages.allSatisfy { $0.imageAttachments.isEmpty })
        XCTAssertFalse(fork.messages.map(\.content).joined().contains("private execution result"))
        XCTAssertNotEqual(fork.messages[1].id, source.messages[0].id)
        XCTAssertNotEqual(fork.messages[2].id, source.messages[1].id)
        XCTAssertEqual(fork.todos.map(\.title), ["Keep me"])
        XCTAssertNotEqual(fork.todos[0].id, source.todos[0].id)
        XCTAssertEqual(fork.goal?.objective, source.goal?.objective)
        XCTAssertNotEqual(fork.goal?.id, source.goal?.id)
        XCTAssertEqual(fork.forkOrigin?.sourceSessionID, source.id)
        XCTAssertEqual(fork.createdAt, now)
    }

    func testForkHistoryIsBoundedOnAUnicodeBoundary() throws {
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
                content: String(repeating: "界", count: AgentTaskForkBuilder.maximumHistoryBytes)
            )
        ]

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: workspace,
            executionLocation: .local,
            localWorkspace: nil,
            localProjectFolderID: nil
        )

        XCTAssertEqual(fork.messages.count, 2)
        XCTAssertLessThanOrEqual(
            fork.messages.reduce(0) { $0 + $1.content.utf8.count },
            AgentTaskForkBuilder.maximumHistoryBytes
        )
        XCTAssertTrue(fork.messages[1].content.hasSuffix("[fork message truncated]"))
        XCTAssertTrue(fork.messages[1].content.contains("界"))
    }

    func testForkKeepsRecentTurnsInOrderAndDropsUnsafePayloads() throws {
        let workspace = AgentWorkspace(
            name: "repo", rootPath: "/repo", allowedPaths: [], bookmarkData: nil,
            gitRepository: true, branch: "main"
        )
        var source = AgentSession(mode: .agent)
        source.workspace = workspace
        let attachment = try AgentImageAttachmentReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "screen.png",
            relativePath: "Attachments/00000000-0000-0000-0000-000000000001.png",
            mimeType: "image/png",
            byteCount: 4,
            pixelWidth: 1,
            pixelHeight: 1,
            sha256: String(repeating: "a", count: 64)
        )
        var first = AgentMessage(role: .user, content: "Inspect this screenshot")
        first.imageAttachments = [attachment]
        var imageOnly = AgentMessage(role: .user)
        imageOnly.imageAttachments = [attachment]
        let second = AgentMessage(
            role: .assistant,
            content: "I can inspect the code next.",
            toolCalls: [AgentToolCall(name: "run_command", arguments: .object([
                "token": .string("secret-value")
            ]))]
        )
        source.messages = [
            first,
            second,
            AgentMessage(role: .tool, content: "tool result secret-value", toolCallID: second.toolCalls[0].id),
            AgentMessage(role: .user, content: "Next, test the change."),
            imageOnly
        ]

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: workspace,
            executionLocation: .local,
            localWorkspace: nil,
            localProjectFolderID: nil
        )

        XCTAssertEqual(fork.messages.map(\.role), [.system, .user, .assistant, .user, .user])
        XCTAssertEqual(fork.messages.dropFirst().map(\.content), [
            "Inspect this screenshot\n[Parent image attachment omitted; reattach it if needed.]",
            "I can inspect the code next.",
            "Next, test the change.",
            "[Parent image attachment omitted; reattach it if needed.]"
        ])
        XCTAssertTrue(fork.messages[0].content.contains("image attachments were not carried"))
        XCTAssertTrue(fork.messages.allSatisfy { $0.imageAttachments.isEmpty && $0.toolCalls.isEmpty })
        XCTAssertFalse(fork.messages.map(\.content).joined().contains("secret-value"))
        XCTAssertFalse(fork.messages.map(\.content).joined().contains(attachment.relativePath))
        XCTAssertEqual(source.messages[0].imageAttachments, [attachment])
    }

    func testForkRedactsSensitiveTextAndRetainsNewestBoundedConversation() throws {
        let workspace = AgentWorkspace(
            name: "repo", rootPath: "/repo", allowedPaths: [], bookmarkData: nil,
            gitRepository: true, branch: "main"
        )
        var source = AgentSession(mode: .agent)
        source.workspace = workspace
        source.title = "Fix password=super-secret-value"
        source.goal = try AgentGoal(objective: "Use token=super-secret-value safely")
        source.todos = [AgentTodo(title: "Check api_key=super-secret-value")]
        source.messages = (0..<AgentTaskForkBuilder.maximumSourceMessages + 5).map { index in
            AgentMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Turn \(index): password=super-secret-value"
            )
        }

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: workspace,
            executionLocation: .local,
            localWorkspace: nil,
            localProjectFolderID: nil
        )

        XCTAssertEqual(fork.messages.count, AgentTaskForkBuilder.maximumSourceMessages + 1)
        XCTAssertTrue(fork.messages[1].content.contains("Turn 5"))
        XCTAssertTrue(fork.messages.last?.content.contains("Turn 84") == true)
        XCTAssertFalse(fork.messages.map(\.content).joined().contains("super-secret-value"))
        XCTAssertFalse(fork.title.contains("super-secret-value"))
        XCTAssertFalse(fork.goal?.objective.contains("super-secret-value") == true)
        XCTAssertFalse(fork.todos[0].title.contains("super-secret-value"))
    }

    func testToolOnlyAssistantEnvelopesDoNotCrowdOutConversation() throws {
        let workspace = AgentWorkspace(
            name: "repo", rootPath: "/repo", allowedPaths: [], bookmarkData: nil,
            gitRepository: true, branch: "main"
        )
        var source = AgentSession(mode: .agent)
        source.workspace = workspace
        source.messages = [AgentMessage(role: .user, content: "Original request")]
            + (0..<AgentTaskForkBuilder.maximumSourceMessages + 5).map { _ in
                AgentMessage(role: .assistant, toolCalls: [AgentToolCall(name: "read_file")])
            }
            + [AgentMessage(role: .user, content: "Latest request")]

        let fork = try AgentTaskForkBuilder().makeFork(
            from: source,
            workspace: workspace,
            executionLocation: .local,
            localWorkspace: nil,
            localProjectFolderID: nil
        )

        XCTAssertEqual(fork.messages.dropFirst().map(\.content), [
            "Original request", "Latest request"
        ])
        XCTAssertTrue(fork.messages.allSatisfy(\.toolCalls.isEmpty))
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
