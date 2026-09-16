import Darwin
import Foundation
import XCTest
@testable import LumaChat

final class AgentCheckpointManagerTests: XCTestCase {
    func testCheckpointPersistsSanitizedSessionGitIdentityAndUndoReference() async throws {
        let root = try makeWorkspace(name: "persistence")
        let workspace = AgentWorkspace(
            name: "checkpoint-workspace",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: Data("bookmark-authority".utf8),
            gitRepository: true,
            branch: "main"
        )
        var session = AgentSession(mode: .agent)
        session.workspace = workspace
        session.title = "api_key=checkpoint-super-secret"
        session.messages = [
            AgentMessage(
                role: .user,
                content: "Authorization: Bearer checkpoint-bearer-secret",
                toolCalls: [
                    AgentToolCall(
                        name: "example",
                        arguments: .object(["token": .string("json-secret-value")])
                    )
                ]
            )
        ]
        session.changes = [
            AgentChangeRecord(
                relativePath: "Sources/example.swift",
                kind: .modify,
                unifiedDiff: "password=diff-secret-value"
            )
        ]
        session.lastAgentTurnReviewBaseline = AgentTurnReviewBaseline(
            version: AgentTurnReviewBaseline.currentVersion,
            runID: UUID(),
            sessionID: session.id,
            capturedAt: Date(),
            workspaceID: workspace.id,
            canonicalRootPath: root.path,
            rootDevice: 1,
            rootInode: 1,
            startRevision: nil,
            files: [AgentTurnReviewFileBaseline(
                path: "large-before-run.bin",
                existed: true,
                byteCount: 9 * 1_024 * 1_024,
                permissions: 0o600,
                sha256: String(repeating: "a", count: 64),
                data: Data(repeating: 0x61, count: 9 * 1_024 * 1_024)
            )]
        )
        session.pendingAgentTurnReviewBaseline = session.lastAgentTurnReviewBaseline
        session.lastAgentTurnReviewSnapshot = AgentTurnReviewSnapshot(
            version: AgentTurnReviewSnapshot.currentVersion,
            runID: UUID(),
            sessionID: session.id,
            finalizedAt: Date(),
            workspaceID: workspace.id,
            canonicalRootPath: root.path,
            rootDevice: 1,
            rootInode: 1,
            source: "password=frozen-secret-value",
            sourceSHA256: String(repeating: "b", count: 64),
            truncated: false
        )
        let todos = [AgentTodo(title: "password=todo-secret-value", detail: "safe detail")]
        let objectID = String(repeating: "a", count: 40)
        try write(
            "checkpoint file content\n",
            to: root.appendingPathComponent("Sources/example.swift")
        )
        try write("ref: refs/heads/main\n", to: root.appendingPathComponent(".git/HEAD"))
        try write("\(objectID)\n", to: root.appendingPathComponent(".git/refs/heads/main"))

        defer { cleanup(sessionID: session.id, workspaceRoot: root) }
        let manager = AgentCheckpointManager()
        let created = try await manager.createCheckpointIfNeeded(
            settings: AgentSettings(),
            session: session,
            todos: todos
        )
        let reference = try XCTUnwrap(created)
        let manifestURL = AppPaths.agentSnapshots
            .appendingPathComponent(reference.relativeManifestPath)
        let manifest = try await AgentCheckpointManager().load(reference)

        XCTAssertEqual(manifest.reference, reference)
        XCTAssertEqual(manifest.gitState?.head, "ref: refs/heads/main")
        XCTAssertEqual(manifest.gitState?.symbolicReference, "refs/heads/main")
        XCTAssertEqual(manifest.gitState?.objectID, objectID)
        XCTAssertEqual(manifest.workspaceIdentity.workspaceID, workspace.id)
        XCTAssertEqual(manifest.workspaceIdentity.canonicalRootPath, root.path)
        XCTAssertEqual(manifest.session.todos, manifest.todos)
        XCTAssertNil(manifest.session.workspace?.bookmarkData)
        XCTAssertNil(
            manifest.session.lastAgentTurnReviewBaseline,
            "Last-Agent-Turn state is Review provenance, not checkpoint rollback payload"
        )
        XCTAssertNil(manifest.session.pendingAgentTurnReviewBaseline)
        XCTAssertNil(manifest.session.lastAgentTurnReviewSnapshot)
        XCTAssertEqual(manifest.existingChangeIDs, session.changes.map(\.id))
        XCTAssertEqual(manifest.version, AgentCheckpointManifest.currentVersion)
        let fileSnapshot = try XCTUnwrap(
            manifest.fileSnapshots.first { $0.requestedPath == "Sources/example.swift" }
        )
        XCTAssertTrue(fileSnapshot.existed)
        guard case .file(let checkpointFileData)? = fileSnapshot.entries.first?.kind else {
            return XCTFail("Expected a regular-file checkpoint snapshot")
        }
        XCTAssertEqual(String(decoding: checkpointFileData, as: UTF8.self), "checkpoint file content\n")
        XCTAssertEqual(
            manifest.undoHistoryManifest.relativePath,
            "\(session.id.uuidString.lowercased())/"
                + "\(workspace.id.uuidString.lowercased())/history.json"
        )
        XCTAssertEqual(
            manifest.undoHistoryManifest.workspaceIdentityDigest,
            manifest.workspaceIdentity.authorizationDigest
        )
        XCTAssertTrue(manifest.session.title.contains("[REDACTED]"))
        XCTAssertTrue(manifest.session.messages[0].content.contains("[REDACTED]"))
        XCTAssertEqual(
            manifest.session.messages[0].toolCalls[0].arguments["token"]?.stringValue,
            "[REDACTED]"
        )
        XCTAssertTrue(manifest.todos[0].title.contains("[REDACTED]"))

        let raw = try String(decoding: Data(contentsOf: manifestURL), as: UTF8.self)
        for secret in [
            "checkpoint-super-secret", "checkpoint-bearer-secret", "json-secret-value",
            "diff-secret-value", "todo-secret-value", "bookmark-authority"
        ] {
            XCTAssertFalse(raw.contains(secret), secret)
        }
        // APFS reports the requested 0600 exactly. This ExFAT workspace forces
        // owner-execute on every file, so assert the security boundary shared
        // by both: owner read/write and no group/other authority.
        let manifestPermissions = try permissions(of: manifestURL)
        XCTAssertEqual(manifestPermissions & 0o077, 0)
        XCTAssertEqual(manifestPermissions & 0o600, 0o600)
        for directory in checkpointDirectories(sessionID: session.id, workspaceID: workspace.id) {
            XCTAssertEqual(try permissions(of: directory), 0o700, directory.path)
        }
    }

    func testDisabledAndPlanModesDoNotTouchCheckpointStorage() async throws {
        let missingRoot = AppPaths.projectTemporaryRoot
            .appendingPathComponent("checkpoint-manager-tests/missing-\(UUID().uuidString)")
        let workspace = AgentWorkspace(
            name: "not-opened",
            rootPath: missingRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        var disabledSession = AgentSession(mode: .agent)
        disabledSession.workspace = workspace
        var disabledSettings = AgentSettings()
        disabledSettings.gitCheckpoint = false
        let manager = AgentCheckpointManager()

        let disabled = try await manager.createCheckpointIfNeeded(
            settings: disabledSettings,
            session: disabledSession,
            todos: []
        )
        XCTAssertNil(disabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: checkpointSessionDirectory(disabledSession.id).path
        ))

        var planSession = AgentSession(mode: .plan)
        planSession.workspace = workspace
        let plan = try await manager.createCheckpointIfNeeded(
            settings: AgentSettings(),
            session: planSession,
            todos: []
        )
        XCTAssertNil(plan)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: checkpointSessionDirectory(planSession.id).path
        ))
    }

    func testVersionOneCheckpointRemainsReadableWithEmptyFileSnapshots() async throws {
        let root = try makeWorkspace(name: "version-one")
        var session = AgentSession(mode: .agent)
        session.workspace = workspace(root: root)
        defer { cleanup(sessionID: session.id, workspaceRoot: root) }

        let manager = AgentCheckpointManager()
        let created = try await manager.createCheckpointIfNeeded(
            settings: AgentSettings(),
            session: session,
            todos: []
        )
        let reference = try XCTUnwrap(created)
        let manifestURL = AppPaths.agentSnapshots
            .appendingPathComponent(reference.relativeManifestPath)
        let currentData = try Data(contentsOf: manifestURL)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacy["version"] = 1
        legacy.removeValue(forKey: "fileSnapshots")
        try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
            .write(to: manifestURL)

        let loaded = try await manager.load(reference)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertTrue(loaded.fileSnapshots.isEmpty)
    }

    func testCheckpointStorageAndManifestReadsRejectSymlinks() async throws {
        let root = try makeWorkspace(name: "storage-symlink")
        let workspace = workspace(root: root)
        var session = AgentSession(mode: .agent)
        session.workspace = workspace
        let outside = AppPaths.projectTemporaryRoot
            .appendingPathComponent("checkpoint-manager-tests/outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: AppPaths.agentSnapshots,
            withIntermediateDirectories: true
        )
        _ = Darwin.chmod(AppPaths.agentSnapshots.path, mode_t(0o700))
        let sessionDirectory = checkpointSessionDirectory(session.id)
        try FileManager.default.createSymbolicLink(
            at: sessionDirectory,
            withDestinationURL: outside
        )
        defer {
            try? FileManager.default.removeItem(at: sessionDirectory)
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: root)
        }

        do {
            _ = try await AgentCheckpointManager().createCheckpointIfNeeded(
                settings: AgentSettings(),
                session: session,
                todos: []
            )
            XCTFail("Expected symbolic checkpoint directory to fail closed")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])

        try FileManager.default.removeItem(at: sessionDirectory)
        let created = try await AgentCheckpointManager().createCheckpointIfNeeded(
            settings: AgentSettings(),
            session: session,
            todos: []
        )
        let reference = try XCTUnwrap(created)
        let manifestURL = AppPaths.agentSnapshots
            .appendingPathComponent(reference.relativeManifestPath)
        let outsideManifest = outside.appendingPathComponent("outside.json")
        try write("{\"secret\":\"must-not-be-read\"}", to: outsideManifest)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestURL,
            withDestinationURL: outsideManifest
        )
        do {
            _ = try await AgentCheckpointManager().load(reference)
            XCTFail("Expected symbolic checkpoint manifest to fail closed")
        } catch {}
    }

    func testGitMetadataReadsAreBoundedAndDoNotFollowHeadSymlink() async throws {
        let outside = AppPaths.projectTemporaryRoot
            .appendingPathComponent("checkpoint-manager-tests/git-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        for variant in ["symlink", "oversized"] {
            let root = try makeWorkspace(name: "git-\(variant)")
            let workspace = workspace(root: root, gitRepository: true)
            var session = AgentSession(mode: .agent)
            session.workspace = workspace
            defer { cleanup(sessionID: session.id, workspaceRoot: root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
            let head = root.appendingPathComponent(".git/HEAD")
            if variant == "symlink" {
                let outsideHead = outside.appendingPathComponent("HEAD")
                try write("\(String(repeating: "b", count: 40))\n", to: outsideHead)
                try FileManager.default.createSymbolicLink(
                    at: head,
                    withDestinationURL: outsideHead
                )
            } else {
                try Data(repeating: 0x61, count: 4 * 1_024 + 1).write(to: head)
            }

            do {
                _ = try await AgentCheckpointManager().createCheckpointIfNeeded(
                    settings: AgentSettings(),
                    session: session,
                    todos: []
                )
                XCTFail("Expected unsafe \(variant) Git HEAD to fail closed")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: checkpointSessionDirectory(session.id).path
            ))
        }
    }

    private func makeWorkspace(name: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("checkpoint-manager-tests/workspaces", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func workspace(root: URL, gitRepository: Bool = false) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: gitRepository,
            branch: nil
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func checkpointSessionDirectory(_ id: UUID) -> URL {
        AppPaths.agentSnapshots
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func checkpointDirectories(sessionID: UUID, workspaceID: UUID) -> [URL] {
        let session = checkpointSessionDirectory(sessionID)
        let workspace = session.appendingPathComponent(
            workspaceID.uuidString.lowercased(),
            isDirectory: true
        )
        return [AppPaths.projectTemporaryRoot, AppPaths.agentSnapshots, session, workspace,
                workspace.appendingPathComponent("checkpoints", isDirectory: true)]
    }

    private func cleanup(sessionID: UUID, workspaceRoot: URL) {
        try? FileManager.default.removeItem(at: checkpointSessionDirectory(sessionID))
        try? FileManager.default.removeItem(at: workspaceRoot)
    }

    private func permissions(of url: URL) throws -> Int {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(info.st_mode & 0o777)
    }
}
