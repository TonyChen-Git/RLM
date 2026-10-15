import Foundation
import Darwin
import XCTest
@testable import LumaChat

private struct LocalPTYSurrogateBackend: PTYBackend {
    let runner: RemoteRunnerConfiguration

    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        throw RemoteExecutionError.unsupported("A remote Task must not create a local workspace PTY.")
    }

    func makeRemoteSession(
        shell: String,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        guard cwd == ".", environment.isEmpty else {
            throw RemoteExecutionError.invalidRequest("Invalid surrogate cwd/environment")
        }
        let material = try SSHLaunchMaterialLease.create(
            configuration: runner,
            credential: nil,
            knownHostsData: Data("test-host-key\n".utf8)
        )
        return PseudoTerminalSession(
            directInvocation: SSHInvocation(
                executableURL: URL(fileURLWithPath: shell),
                arguments: ["-i"],
                environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
            ),
            launchMaterial: material,
            scrollbackBytes: 4_096
        )
    }
}

final class SSHInteractiveTerminalTests: XCTestCase {
    func testDirectPTYProvidesStreamingInputResizeAndBoundedOutput() async throws {
        let fixture = makeFixture()
        let transport = try LocalPTYSurrogateBackend(runner: fixture.runner)
            .makeRemoteSession(shell: "/bin/sh", cwd: ".", environment: [:])
        defer { Task { await transport.dispose() } }
        let started = try await transport.start(
            command: nil, cwd: ".", environment: [:], shell: "/bin/sh",
            rows: 24, columns: 80, allowsNetwork: true,
            allowsGitMetadata: false, allowsGitMetadataWrite: false
        )
        let resized = try await transport.resize(rows: 31, columns: 97)
        XCTAssertEqual(resized.dimensions.rows, 31)
        XCTAssertEqual(resized.dimensions.columns, 97)
        _ = try await transport.write(Data("stty size; printf 'PHASE_I_OK\\n'\n".utf8))
        let output = try await waitForOutput(transport, containing: "PHASE_I_OK")
        XCTAssertTrue(output.contains("31 97"), output)
        XCTAssertTrue(output.contains("PHASE_I_OK"), output)
        let bounds = try await transport.outputBounds()
        XCTAssertLessThanOrEqual(
            bounds.nextOffset - bounds.earliestAvailableOffset,
            4_096
        )
        _ = try await transport.stop()
        XCTAssertEqual(Darwin.kill(started.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testDirectPTYInterruptKeepsInteractiveShellUsable() async throws {
        let fixture = makeFixture()
        let transport = try LocalPTYSurrogateBackend(runner: fixture.runner)
            .makeRemoteSession(shell: "/bin/sh", cwd: ".", environment: [:])
        defer { Task { await transport.dispose() } }
        _ = try await transport.start(
            command: nil, cwd: ".", environment: [:], shell: "/bin/sh",
            rows: 24, columns: 80, allowsNetwork: true,
            allowsGitMetadata: false, allowsGitMetadataWrite: false
        )
        _ = try await transport.write(Data("sleep 30\n".utf8))
        _ = try await waitForOutput(transport, containing: "sleep 30")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await transport.signal(SIGINT)
        _ = try await transport.write(Data("printf 'AFTER_INTERRUPT\\n'\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        var completed = false
        while Date() < deadline {
            let output = try await transport.readOutput(offset: 0, maxBytes: 4_096)
            let text = String(decoding: output.data, as: UTF8.self)
            completed = text.components(separatedBy: "AFTER_INTERRUPT").count >= 3
            if completed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(completed, "Ctrl-C should interrupt the foreground job")
        _ = try await transport.stop()
    }

    func testRemoteTaskMetadataRejectsChangedAuthorityAndRecoversDisconnected() async throws {
        let fixture = makeFixture()
        let taskID = UUID()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-pty-test-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = fixture.binding
        let backend = LocalPTYSurrogateBackend(runner: fixture.runner)
        let original = TaskTerminalService(
            taskID: taskID, remoteBinding: binding,
            backend: backend, sessionsRoot: root
        )
        let created = try await original.create(shell: "/bin/sh")
        XCTAssertEqual(created.metadata.workspaceRootPath, "/srv/work")
        XCTAssertEqual(created.metadata.remoteAuthorityFingerprint, "authority-a")

        // A new App process has metadata only. It never claims the old SSH
        // connection or its unavailable raw scrollback.
        let relaunched = TaskTerminalService(
            taskID: taskID, remoteBinding: binding,
            backend: backend, sessionsRoot: root
        )
        let restoredList = try await relaunched.list()
        let restored = try XCTUnwrap(restoredList.first)
        XCTAssertEqual(restored.metadata.state, .disconnected)
        XCTAssertNil(restored.processIdentifier)

        var changed = binding
        changed.authorityFingerprint = "authority-b"
        let changedService = TaskTerminalService(
            taskID: taskID, remoteBinding: changed,
            backend: backend, sessionsRoot: root
        )
        let invalidatedList = try await changedService.list()
        let invalidated = try XCTUnwrap(invalidatedList.first)
        XCTAssertEqual(invalidated.metadata.state, .failed)
        await XCTAssertThrowsErrorAsync {
            _ = try await changedService.reconnect(id: created.id)
        }
        _ = await original.disposeAll()
    }

    func testRemoteTaskRefusesUnavailableCredentialBeforeOpeningTerminal() async throws {
        let fixture = makeFixture()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-pty-auth-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var binding = fixture.binding
        binding.verifyFreshHost = {
            throw RemoteExecutionError.credentialUnavailable(fixture.runner.id)
        }
        let service = TaskTerminalService(
            taskID: UUID(), remoteBinding: binding,
            backend: LocalPTYSurrogateBackend(runner: fixture.runner),
            sessionsRoot: root
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await service.create(shell: "/bin/sh")
        }
        let listed = try await service.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testRemoteDisconnectAndDuplicateReconnectDoNotReuseOldProcess() async throws {
        let fixture = makeFixture()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-pty-disconnect-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TaskTerminalService(
            taskID: UUID(), remoteBinding: fixture.binding,
            backend: LocalPTYSurrogateBackend(runner: fixture.runner),
            sessionsRoot: root
        )
        let original = try await service.create(shell: "/bin/sh")
        _ = try await service.write(id: original.id, text: "exit 255\n")
        let deadline = Date().addingTimeInterval(5)
        var disconnected = false
        while Date() < deadline {
            disconnected = try await service.list().first?.metadata.state == .disconnected
            if disconnected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(disconnected, "OpenSSH 255 must surface as disconnected")

        async let first = service.reconnect(id: original.id)
        async let second = service.reconnect(id: original.id)
        _ = try? await first
        _ = try? await second
        let listed = try await service.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.metadata.reconnectCount, 1)
        XCTAssertEqual(listed.first?.metadata.state, .running)
        _ = await service.disposeAll()
    }

    func testChangedHostIdentityAndRevokedAuthorityRefuseReuse() async throws {
        let fixture = makeFixture()
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-pty-host-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RemoteTerminalAuthorityGate()
        var binding = fixture.binding
        binding.validateCurrentAuthority = { try await gate.check() }
        binding.verifyFreshHost = { try await gate.check() }
        let backend = LocalPTYSurrogateBackend(runner: fixture.runner)
        let taskID = UUID()
        let service = TaskTerminalService(
            taskID: taskID, remoteBinding: binding,
            backend: backend, sessionsRoot: root
        )
        let original = try await service.create(shell: "/bin/sh")
        await gate.revoke()
        await XCTAssertThrowsErrorAsync {
            _ = try await service.write(id: original.id, text: "echo should-not-run\n")
        }
        // Close/Kill remains available for cleanup after authority loss.
        _ = try await service.kill(id: original.id)

        var restartedHost = binding
        restartedHost.host.serverReportedHostname = "worker-replaced"
        let reloaded = TaskTerminalService(
            taskID: taskID, remoteBinding: restartedHost,
            backend: backend, sessionsRoot: root
        )
        let listed = try await reloaded.list()
        XCTAssertEqual(listed.first?.metadata.state, .failed)
        await XCTAssertThrowsErrorAsync {
            _ = try await reloaded.reconnect(id: original.id)
        }
        _ = await service.disposeAll()
    }

    private func makeFixture() -> (
        runner: RemoteRunnerConfiguration,
        binding: RemoteTaskTerminalBinding
    ) {
        let runner = RemoteRunnerConfiguration(
            name: "Terminal fixture", host: "host.example.test",
            username: "builder", workspaceRoot: "/srv/work",
            knownHostsFile: "/dev/null", authentication: .systemAgent
        )
        let receipt = RemoteHostReceipt(
            runnerID: runner.id, transport: .ssh,
            configuredHost: runner.host, configuredPort: runner.port,
            configuredUser: runner.username,
            serverReportedHostname: "worker-1", effectiveUser: "builder",
            effectiveUserID: 501, configuredWorkspaceRoot: runner.workspaceRoot,
            canonicalWorkspaceRoot: "/srv/work", verifiedAt: Date()
        )
        return (
            runner,
            RemoteTaskTerminalBinding(
                workspaceID: UUID(),
                host: RemoteTaskTerminalHostIdentity(receipt),
                authorityFingerprint: "authority-a",
                permissionFingerprint: "permission-a",
                validateCurrentAuthority: {}, verifyFreshHost: {}
            )
        )
    }

    private func waitForOutput(
        _ transport: any PTYSessionTransport,
        containing marker: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let output = try await transport.readOutput(offset: 0, maxBytes: 4_096)
            let text = String(decoding: output.data, as: UTF8.self)
            if text.contains(marker) { return text }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for local PTY surrogate output")
        return ""
    }
}

private actor RemoteTerminalAuthorityGate {
    private var isRevoked = false

    func revoke() { isRevoked = true }

    func check() throws {
        if isRevoked { throw RemoteExecutionError.credentialUnavailable(UUID()) }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // The rejection itself is the contract under test.
    }
}
