import Foundation
import XCTest
@testable import LumaChat

final class AgentTerminalAndGitTests: XCTestCase {
    func testTerminalRetainsCWDTruncatesToRepositoryArtifactAndTimesOut() async throws {
        let root = try makeWorkspaceRoot("terminal")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let terminal = try TerminalSession(validator: validator, retainedOutputBytes: 4_096)

        let changeDirectory = try await terminal.run(command: "cd nested", timeout: 5)
        XCTAssertEqual(changeDirectory.exitCode, 0)
        XCTAssertEqual(changeDirectory.finalCWD, "nested")
        let pwd = try await terminal.run(command: "pwd -P", timeout: 5)
        XCTAssertEqual(pwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines), root.appendingPathComponent("nested").path)

        let large = try await terminal.run(
            command: "printf 'x%.0s' {1..10000}",
            cwd: ".",
            timeout: 5
        )
        XCTAssertTrue(large.truncated)
        let artifact = try XCTUnwrap(large.stdoutArtifactPath)
        XCTAssertTrue(artifact.hasPrefix(AppPaths.agentArtifacts.path + "/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: artifact)).count, 10_000)

        let timeout = try await terminal.run(command: "sleep 10", cwd: ".", timeout: 0.1)
        XCTAssertTrue(timeout.timedOut)
        XCTAssertNotEqual(timeout.exitCode, 0)
    }

    func testTerminalDeterministicallyCapturesFinalOutputWithoutNewline() async throws {
        let root = try makeWorkspaceRoot("terminal-tail")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )
        for index in 0..<20 {
            let expected = "tail-\(index)-" + String(repeating: "x", count: 4_096)
            let result = try await terminal.run(
                command: "printf %s \(shellQuote(expected))",
                timeout: 5
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout, expected)
        }
    }

    func testManagedProcessCanStreamStatusAndStopOnlyOwnedProcess() async throws {
        let root = try makeWorkspaceRoot("process")
        defer { try? FileManager.default.removeItem(at: root) }
        let validator = try WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        let terminal = try TerminalSession(validator: validator)
        let started = try await terminal.start(
            command: "while true; do echo tick; sleep 0.05; done"
        )
        try await Task.sleep(for: .milliseconds(180))
        let status = try await terminal.processStatus(id: started.id)
        XCTAssertEqual(status.state, .running)
        let output = try await terminal.readProcessOutput(id: started.id)
        XCTAssertTrue(output.stdout.text.contains("tick"))
        let stopped = try await terminal.stopProcess(id: started.id)
        XCTAssertEqual(stopped.state, .stopped)
        do {
            _ = try await terminal.processStatus(id: UUID())
            XCTFail("An unknown process must not be addressable.")
        } catch let error as TerminalSessionError {
            guard case .processNotFound = error else { throw error }
            // Expected: stop/status can target only IDs created by this session.
        }
    }

    func testManagedProcessAcceptsBoundedInputAndExplicitEOF() async throws {
        let root = try makeWorkspaceRoot("process-input")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )
        let started = try await terminal.start(
            command: "while IFS= read -r line; do printf 'received:%s\\n' \"$line\"; done"
        )

        let first = try await terminal.writeProcessInput(
            id: started.id,
            input: "alpha beta\n"
        )
        XCTAssertEqual(first.bytesWritten, "alpha beta\n".utf8.count)
        XCTAssertFalse(first.stdinClosed)

        let closed = try await terminal.writeProcessInput(
            id: started.id,
            input: "omega\n",
            close: true
        )
        XCTAssertEqual(closed.bytesWritten, "omega\n".utf8.count)
        XCTAssertTrue(closed.stdinClosed)

        var output = try await terminal.readProcessOutput(id: started.id)
        for _ in 0..<100 where !output.stdout.text.contains("received:omega") {
            try await Task.sleep(for: .milliseconds(20))
            output = try await terminal.readProcessOutput(id: started.id)
        }
        XCTAssertTrue(output.stdout.text.contains("received:alpha beta"), output.stdout.text)
        XCTAssertTrue(output.stdout.text.contains("received:omega"), output.stdout.text)

        do {
            _ = try await terminal.writeProcessInput(id: started.id, input: "late\n")
            XCTFail("Input after EOF or process exit must fail.")
        } catch let error as TerminalSessionError {
            switch error {
            case .processInputClosed, .processNotRunning: break
            default: throw error
            }
        }
    }

    func testManagedProcessInputRejectsOversizedEmptyAndStoppedWrites() async throws {
        let root = try makeWorkspaceRoot("process-input-errors")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )
        let started = try await terminal.start(command: "while IFS= read -r line; do :; done")

        do {
            _ = try await terminal.writeProcessInput(id: started.id)
            XCTFail("An empty write without EOF must fail.")
        } catch TerminalSessionError.emptyProcessInput {
            // Expected.
        }

        do {
            _ = try await terminal.writeProcessInput(
                id: started.id,
                input: String(repeating: "x", count: TerminalSession.maximumProcessInputBytes + 1)
            )
            XCTFail("An oversized input must fail before writing any bytes.")
        } catch TerminalSessionError.processInputTooLarge(let maximum) {
            XCTAssertEqual(maximum, TerminalSession.maximumProcessInputBytes)
        }

        _ = try await terminal.stopProcess(id: started.id)
        do {
            _ = try await terminal.writeProcessInput(id: started.id, input: "late\n")
            XCTFail("A stopped process must reject input.")
        } catch TerminalSessionError.processNotRunning {
            // Expected.
        }
    }

    func testSandboxDeniesWorkspaceEscapeAndTamperedAllowedPaths() async throws {
        let root = try makeWorkspaceRoot("sandbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = AppPaths.projectTemporaryRoot.deletingLastPathComponent()
        let externalFile = projectRoot.appendingPathComponent("Package.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))

        var workspace = makeWorkspace(root)
        // Simulates a persisted session edited to inject a broad writable path.
        workspace.allowedPaths = [projectRoot.path, "/"]
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let terminal = try TerminalSession(validator: validator)

        let externalRead = try await terminal.run(
            command: "/bin/cat \(shellQuote(externalFile.path))",
            timeout: 5
        )
        XCTAssertNotEqual(externalRead.exitCode, 0)
        XCTAssertFalse(externalRead.stdout.contains("swift-tools-version"))

        let dataVolumeAlias = "/System/Volumes/Data" + externalFile.path
        if FileManager.default.fileExists(atPath: dataVolumeAlias) {
            let aliasRead = try await terminal.run(
                command: "/bin/cat \(shellQuote(dataVolumeAlias))",
                timeout: 5
            )
            XCTAssertNotEqual(aliasRead.exitCode, 0)
            XCTAssertFalse(aliasRead.stdout.contains("swift-tools-version"))
        }

        let escapeLink = root.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: externalFile)
        let symbolicLinkRead = try await terminal.run(
            command: "/bin/cat \(shellQuote(escapeLink.path))",
            timeout: 5
        )
        XCTAssertNotEqual(symbolicLinkRead.exitCode, 0)
        XCTAssertFalse(symbolicLinkRead.stdout.contains("swift-tools-version"))

        let identityRead = try await terminal.run(command: "/bin/cat /etc/passwd", timeout: 5)
        XCTAssertNotEqual(identityRead.exitCode, 0)
        XCTAssertFalse(identityRead.stdout.contains("root:"))

        let siblingArtifact = AppPaths.agentProcesses
            .appendingPathComponent("other-session-\(UUID().uuidString).txt")
        try Data("cross-session-secret".utf8).write(to: siblingArtifact)
        defer { try? FileManager.default.removeItem(at: siblingArtifact) }
        let siblingRead = try await terminal.run(
            command: "/bin/cat \(shellQuote(siblingArtifact.path))",
            timeout: 5
        )
        XCTAssertNotEqual(siblingRead.exitCode, 0)
        XCTAssertFalse(siblingRead.stdout.contains("cross-session-secret"))

        let environmentResult = try await terminal.run(
            command: "printf '%s\\n' \"$HOME\" \"$TMPDIR\" \"$XDG_CACHE_HOME\" \"$MY_TOKEN\"",
            timeout: 5,
            environment: [
                "HOME": projectRoot.path,
                "TMPDIR": "/tmp/escape-attempt",
                "MY_TOKEN": "opaque-environment-secret-98765"
            ]
        )
        let environmentLines = environmentResult.stdout.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(environmentLines.count, 4)
        for path in environmentLines.prefix(3) {
            XCTAssertTrue(String(path).hasPrefix(AppPaths.projectTemporaryRoot.path + "/"), String(path))
        }
        XCTAssertEqual(environmentLines[3], "[REDACTED]")
        XCTAssertFalse(environmentResult.stdout.contains("opaque-environment-secret-98765"))

        let escapedWrite = projectRoot
            .appendingPathComponent("terminal-escape-\(UUID().uuidString).txt")
        defer {
            if FileManager.default.fileExists(atPath: escapedWrite.path) {
                try? FileManager.default.removeItem(at: escapedWrite)
            }
        }
        let writeResult = try await terminal.run(
            command: "printf nope > \(shellQuote(escapedWrite.path))",
            timeout: 5
        )
        XCTAssertNotEqual(writeResult.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedWrite.path))

        do {
            _ = try await terminal.run(command: "pwd", cwd: projectRoot.path, timeout: 5)
            XCTFail("A tampered allowedPaths entry must not become a terminal cwd.")
        } catch let error as TerminalSessionError {
            guard case .workspaceBoundary = error else { throw error }
        }
    }

    func testUnknownNetworkMechanismIsDeniedBySandbox() async throws {
        let root = try makeWorkspaceRoot("network-deny")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )
        let result = try await terminal.run(
            command: "/usr/bin/perl -MSocket -e 'socket(my $s, PF_INET, SOCK_STREAM, getprotobyname(\"tcp\")) or die \"$!\\n\"; connect($s, sockaddr_in(9, inet_aton(\"127.0.0.1\"))) or die \"$!\\n\"'",
            timeout: 5
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stderr.localizedCaseInsensitiveContains("not permitted")
                || result.stderr.localizedCaseInsensitiveContains("denied"),
            result.stderr
        )

        let enabled = try await terminal.run(
            command: "/usr/bin/perl -MSocket -e 'socket(my $s, PF_INET, SOCK_STREAM, getprotobyname(\"tcp\")) or die \"$!\\n\"; connect($s, sockaddr_in(9, inet_aton(\"127.0.0.1\"))) or die \"$!\\n\"'",
            timeout: 5,
            allowsNetwork: true
        )
        XCTAssertFalse(
            enabled.stderr.localizedCaseInsensitiveContains("not permitted")
                || enabled.stderr.localizedCaseInsensitiveContains("denied"),
            enabled.stderr
        )
    }

    func testStopAndTimeoutTerminateWholeProcessGroup() async throws {
        let root = try makeWorkspaceRoot("process-group")
        defer { try? FileManager.default.removeItem(at: root) }
        let terminal = try TerminalSession(
            validator: WorkspaceSecurityValidator(workspace: makeWorkspace(root))
        )

        let stoppedMarker = root.appendingPathComponent("stopped-orphan.txt")
        let started = try await terminal.start(
            command: "(/bin/sleep 1; /usr/bin/touch \(shellQuote(stoppedMarker.path))) & wait"
        )
        try await Task.sleep(for: .milliseconds(100))
        _ = try await terminal.stopProcess(id: started.id)

        let timeoutMarker = root.appendingPathComponent("timeout-orphan.txt")
        let timedOut = try await terminal.run(
            command: "(/bin/sleep 1; /usr/bin/touch \(shellQuote(timeoutMarker.path))) & wait",
            timeout: 0.1
        )
        XCTAssertTrue(timedOut.timedOut)

        let cancellation = Task {
            try await terminal.run(
                command: "trap '' TERM; while true; do /bin/sleep 10; done",
                timeout: 60
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = ContinuousClock.now
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            XCTFail("A cancelled command should throw CancellationError.")
        } catch is CancellationError {
            // Expected. The force-kill escalation must make this bounded even
            // when the shell explicitly ignores SIGTERM.
        }
        XCTAssertLessThan(
            cancellationStarted.duration(to: .now),
            .seconds(2)
        )
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stoppedMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: timeoutMarker.path))
    }

    func testOutputIsRedactedBeforeArtifactWriteAndHardCapped() throws {
        let configuredSecret = "opaque-session-secret-12345"
        let multilineSecret = "multiline-part-alpha\nmultiline-part-beta"
        let spool = try OutputSpool(
            prefix: "redaction-test",
            retainedByteLimit: 4_096,
            artifactByteLimit: 64 * 1_024,
            configuredSecrets: [configuredSecret, multilineSecret]
        )
        spool.append(Data("MY_TOKEN=opaque-session-".utf8))
        spool.append(Data("secret-12345 Bear".utf8))
        spool.append(Data("er bearer-value-987654321\n".utf8))
        spool.append(Data("multiline-part-alpha\nmultiline-part-beta\n".utf8))
        spool.append(Data("-----BEGIN PRIVATE KEY-----\nprivate-key-material\n".utf8))
        spool.append(Data("-----END PRIVATE KEY-----\n".utf8))
        for _ in 0..<2_000 {
            spool.append(Data("bounded-output-without-a-secret-value-0123456789\n".utf8))
        }
        spool.finish()

        let output = try spool.read(offset: 0, maxBytes: 1_048_576)
        XCTAssertFalse(output.text.contains(configuredSecret))
        XCTAssertFalse(output.text.contains("bearer-value-987654321"))
        XCTAssertFalse(output.text.contains("private-key-material"))
        XCTAssertTrue(output.text.contains("[REDACTED]"))
        XCTAssertLessThanOrEqual(output.totalBytes, 64 * 1_024)
        XCTAssertTrue(spool.summary().truncated)
        let artifactData = try Data(contentsOf: URL(fileURLWithPath: output.artifactPath))
        let artifactText = String(decoding: artifactData, as: UTF8.self)
        XCTAssertFalse(artifactText.contains(configuredSecret))
        XCTAssertFalse(artifactText.contains("multiline-part-alpha"))
        XCTAssertFalse(artifactText.contains("multiline-part-beta"))
        XCTAssertFalse(artifactText.contains("bearer-value-987654321"))
    }

    func testGitReadAndWriteToolsStayLocalAndProduceSnapshots() async throws {
        let root = try makeWorkspaceRoot("git")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = makeWorkspace(root, gitRepository: true)
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let terminal = try TerminalSession(validator: validator)
        _ = try await terminal.run(command: "/usr/bin/git init", timeout: 10)
        _ = try await terminal.run(command: "/usr/bin/git config user.name 'Luma Tests'", timeout: 10)
        _ = try await terminal.run(command: "/usr/bin/git config user.email 'luma@example.invalid'", timeout: 10)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        _ = try await terminal.run(command: "/usr/bin/git add sample.txt && /usr/bin/git commit -m initial --no-gpg-sign", timeout: 10)

        let changes = ChangeManager(validator: validator)
        let git = try GitService(validator: validator, terminal: terminal, changes: changes)
        let status = try await git.status()
        XCTAssertTrue(status.output.contains("##"))
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        let diff = try await git.diffFile(path: "sample.txt")
        XCTAssertTrue(diff.output.contains("+two"))

        let add = try await git.add(paths: ["sample.txt"], taskID: UUID())
        XCTAssertNotNil(add.change)
        let staged = try await git.diff(staged: true)
        XCTAssertTrue(staged.output.contains("+two"))
        let branch = try await git.currentBranch()
        XCTAssertFalse(branch.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testGitRestoreAndCheckoutRejectRepositoryControlledContentFilters() async throws {
        let root = try makeWorkspaceRoot("git-filter")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = makeWorkspace(root, gitRepository: true)
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        let terminal = try TerminalSession(validator: validator)
        _ = try await terminal.run(command: "/usr/bin/git init", timeout: 10)
        _ = try await terminal.run(command: "/usr/bin/git config user.name 'Luma Tests'", timeout: 10)
        _ = try await terminal.run(command: "/usr/bin/git config user.email 'luma@example.invalid'", timeout: 10)
        try Data("main\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        _ = try await terminal.run(
            command: "/usr/bin/git add sample.txt && /usr/bin/git commit -m initial --no-gpg-sign",
            timeout: 10
        )
        _ = try await terminal.run(command: "/usr/bin/git checkout -b filtered-target", timeout: 10)
        try Data("target\n".utf8).write(to: root.appendingPathComponent("sample.txt"))
        _ = try await terminal.run(
            command: "/usr/bin/git add sample.txt && /usr/bin/git commit -m target --no-gpg-sign",
            timeout: 10
        )
        _ = try await terminal.run(command: "/usr/bin/git checkout -", timeout: 10)

        let marker = root.appendingPathComponent("filter-ran.txt")
        let filterCommand = "/usr/bin/touch \(shellQuote(marker.path)); /bin/cat"
        _ = try await terminal.run(
            command: "/usr/bin/git config filter.hostile.smudge \(shellQuote(filterCommand))",
            timeout: 10
        )
        try Data("sample.txt filter=hostile\n".utf8)
            .write(to: root.appendingPathComponent(".gitattributes"))
        try Data("locally modified\n".utf8).write(to: root.appendingPathComponent("sample.txt"))

        let changes = ChangeManager(validator: validator)
        let git = try GitService(validator: validator, terminal: terminal, changes: changes)
        do {
            _ = try await git.restore(paths: ["sample.txt"], taskID: UUID())
            XCTFail("restore should reject a repository-controlled content filter")
        } catch GitServiceError.unsafeFilteredPath(let path) {
            XCTAssertEqual(path, "sample.txt")
        }
        do {
            _ = try await git.checkout(reference: "filtered-target", taskID: UUID())
            XCTFail("checkout should reject a repository-controlled content filter")
        } catch GitServiceError.unsafeFilteredPath(let path) {
            XCTAssertEqual(path, "sample.txt")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeWorkspaceRoot(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeWorkspace(_ root: URL, gitRepository: Bool = false) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: gitRepository,
            branch: nil
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
