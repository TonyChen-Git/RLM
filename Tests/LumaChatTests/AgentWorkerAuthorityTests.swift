import Foundation
import Darwin
import XCTest
@testable import LumaChat

final class AgentWorkerAuthorityTests: XCTestCase {
    private func fixture() throws -> (AgentSession, AgentSettings, AgentWorkerJobBinding) {
        let runnerID = UUID()
        var session = AgentSession(mode: .agent)
        session.workspace = AgentWorkspace(
            name: "remote", rootPath: "/srv/project", allowedPaths: [],
            bookmarkData: nil, gitRepository: true
        )
        session.executionLocation = .ssh(runnerID: runnerID)
        let settings = AgentSettings()
        let identity = AgentRemoteExecutionIdentity(
            runnerID: runnerID, backendLabel: "SSH", host: "worker.example",
            port: 22, user: "worker", workspaceRoot: "/srv/project",
            configurationFingerprint: "pinned-host-and-credential"
        )
        let binding = AgentWorkerJobBinding(
            sessionID: session.id, jobID: UUID(), identity: identity, submittedAt: Date(),
            workspaceID: session.workspace?.id,
            permissionFingerprint: try AgentViewModel.remoteWorkerPermissionFingerprint(
                session: session, settings: settings
            )
        )
        return (session, settings, binding)
    }

    func testTaskModeIdentityAndWorkspaceChangesRevokeBinding() throws {
        let (original, settings, binding) = try fixture()
        XCTAssertTrue(AgentViewModel.remoteWorkerAuthorityMatches(binding, session: original, settings: settings))
        let changes: [(inout AgentSession) -> Void] = [
            { $0.mode = .plan },
            { $0.archivedAt = Date() },
            { $0.id = UUID() },
            { $0.executionLocation = .local },
            { $0.executionLocation = .ssh(runnerID: UUID()) },
            { $0.workspace?.id = UUID() },
            { $0.workspace?.rootPath = "/srv/other" },
            { $0.workspace?.gitRepository = false },
            { $0.workspace?.allowedPaths = ["/srv/extra"] },
            { $0.taskType = .subagent(parentSessionID: UUID(), subagentID: UUID(), depth: 1) }
        ]
        for (index, change) in changes.enumerated() {
            var session = original
            change(&session)
            XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(
                binding, session: session, settings: settings
            ), "Authority change \(index) must revoke the old binding")
        }
    }

    func testPermissionChangesAndLegacyBindingsFailClosed() throws {
        let (session, originalSettings, originalBinding) = try fixture()
        var settings = originalSettings
        settings.networkAccess.toggle()
        XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(originalBinding, session: session, settings: settings))
        settings = originalSettings
        settings.permissionMode = .fullAccess
        XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(originalBinding, session: session, settings: settings))
        var changed = session
        changed.permissionAllowances = [AgentPermissionAllowance(
            toolID: "shell", toolName: "shell", category: "terminal", effectiveLevel: "execute",
            workspaceRoot: "/srv/project", argumentScope: nil
        )]
        XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(originalBinding, session: changed, settings: originalSettings))
        var binding = originalBinding
        binding.permissionFingerprint = nil
        XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(binding, session: session, settings: originalSettings))
        binding = originalBinding
        binding.workspaceID = nil
        XCTAssertFalse(AgentViewModel.remoteWorkerAuthorityMatches(binding, session: session, settings: originalSettings))
    }

    func testWorkerBindingRoundTripRejectsSubstitutedDirectoryAndFIFO() throws {
        let (session, _, binding) = try fixture()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent("worker-binding-\(UUID())")
        let directory = root.appendingPathComponent(session.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentWorkerJobStore(sessionsRoot: root)
        try store.save(binding)
        XCTAssertEqual(try store.load(sessionID: session.id), binding)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load(sessionID: session.id))
        XCTAssertThrowsError(try store.save(binding))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: outside, to: directory)
        let file = directory.appendingPathComponent("remote-worker-job.json")
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(Darwin.mkfifo(file.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try store.load(sessionID: session.id))
        XCTAssertThrowsError(try store.save(binding))
    }
}
