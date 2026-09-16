import Darwin
import Foundation
import XCTest
@testable import LumaChat

final class PseudoTerminalSessionTests: XCTestCase {
    func testPTYOwnsControllingTerminalAndForegroundProcessGroup() async throws {
        let root = try makeWorkspaceRoot("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"/usr/bin/perl -MPOSIX -e '$|=1; print join(q{,},(-t STDIN?1:0),(-t STDOUT?1:0),POSIX::tcgetpgrp(fileno(STDIN)),getpgrp(0),$$),qq{,READY\n}; scalar <STDIN>'"#
            let started = try await session.start(command: command)
            let ready = try await waitForOutput(session, containing: "READY")
            let normalized = String(decoding: ready.data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            let line = try XCTUnwrap(normalized.split(separator: "\n").first)
            let fields = line.split(separator: ",").map(String.init)
            XCTAssertEqual(fields.count, 6, normalized)
            XCTAssertEqual(fields[0], "1")
            XCTAssertEqual(fields[1], "1")
            XCTAssertEqual(fields[2], fields[3], "The PTY foreground group must own the TTY.")
            XCTAssertEqual(Darwin.getsid(started.processIdentifier), started.processIdentifier)
            XCTAssertEqual(Darwin.getpgid(started.processIdentifier), started.processIdentifier)

            _ = try await session.write(text: "release\n")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRawModeRoundTripsBinaryBytesWithoutStringConversion() async throws {
        let root = try makeWorkspaceRoot("raw")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"/bin/stty raw -echo; /usr/bin/perl -e '$|=1; print q{READY}; my $data=q{}; while (length($data) < 8) { my $count=sysread(STDIN,my $chunk,8-length($data)); exit 31 unless defined($count) && $count > 0; $data.=$chunk; } syswrite(STDOUT,q{BEGIN},5); syswrite(STDOUT,$data,length($data));'"#
            _ = try await session.start(command: command)
            _ = try await waitForOutput(session, containing: "READY")
            let payload = Data([0x00, 0x03, 0x04, 0x0A, 0x0D, 0x7F, 0x80, 0xFF])
            let write = try await session.write(payload)
            XCTAssertEqual(write.bytesWritten, payload.count)
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.exitCode, 0)
            let output = try await session.readOutput(maxBytes: 1_024)
            let expectedSuffix = Data("BEGIN".utf8) + payload
            XCTAssertTrue(output.data.suffix(expectedSuffix.count) == expectedSuffix)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYCanonicalModeDoesNotDeliverPartialLineUntilNewline() async throws {
        let root = try makeWorkspaceRoot("canonical")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"/bin/stty icanon -echo; /usr/bin/perl -e '$|=1; print qq{READY\n}; my $line=<STDIN>; exit 61 unless defined($line); $line =~ s/\r?\n\z//; print qq{LINE:$line\n};'"#
            _ = try await session.start(command: command)
            _ = try await waitForOutput(session, containing: "READY")
            try await Task.sleep(for: .milliseconds(30))
            let checkpointBounds = try await session.outputBounds()
            let checkpoint = checkpointBounds.nextOffset

            _ = try await session.write(text: "partial-value")
            try await Task.sleep(for: .milliseconds(150))
            let beforeNewline = try await session.readOutput(
                offset: checkpoint,
                maxBytes: 4_096
            )
            XCTAssertFalse(
                String(decoding: beforeNewline.data, as: UTF8.self).contains("LINE:"),
                "Canonical input must stay buffered until a line delimiter arrives."
            )

            _ = try await session.write(text: "\n")
            let delivered = try await waitForOutput(
                session,
                containing: "LINE:partial-value"
            )
            XCTAssertTrue(
                String(decoding: delivered.data, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "")
                    .contains("LINE:partial-value\n")
            )
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.exitCode, 0)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYControlCIsHandledByForegroundJob() async throws {
        let root = try makeWorkspaceRoot("control-c")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            // Replace the non-interactive wrapper shell so it cannot exit on
            // SIGINT before the foreground fixture publishes its handler output.
            let command = #"/bin/stty isig -echo; exec /usr/bin/perl -e '$|=1; $SIG{INT}=sub { print qq{INTERRUPTED\n}; exit 23 }; print qq{READY\n}; select(undef,undef,undef,30); exit 62;'"#
            _ = try await session.start(command: command)
            _ = try await waitForOutput(session, containing: "READY")
            _ = try await session.write(Data([0x03]))
            _ = try await waitForOutput(session, containing: "INTERRUPTED")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 23)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYControlDProducesCanonicalEndOfFile() async throws {
        let root = try makeWorkspaceRoot("control-d")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"/bin/stty icanon -echo; /usr/bin/perl -e '$|=1; print qq{READY\n}; my $line=<STDIN>; print defined($line) ? qq{UNEXPECTED-DATA\n} : qq{EOF-RECEIVED\n};'"#
            _ = try await session.start(command: command)
            _ = try await waitForOutput(session, containing: "READY")
            let result = try await session.sendEndOfTransmission()
            XCTAssertEqual(result.bytesWritten, 1)
            _ = try await waitForOutput(session, containing: "EOF-RECEIVED")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.exitCode, 0)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYDefaultInteractiveShellAcceptsCommands() async throws {
        let root = try makeWorkspaceRoot("default-shell")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(shell: "/bin/sh")
            _ = try await session.write(
                text: "printf 'DEFAULT-SHELL-READY\\n'; exit 7\n"
            )
            _ = try await waitForOutput(session, containing: "DEFAULT-SHELL-READY")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.exitCode, 7)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsInteractiveVimInAlternateScreenAndDisposesAfterExit() async throws {
        let vimPath = "/usr/bin/vim"
        guard FileManager.default.isExecutableFile(atPath: vimPath) else {
            throw XCTSkip("The system Vim executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("vim-tui")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        let alternateScreenEnterSequences = [
            "\u{001B}[?1049h", "\u{001B}[?1047h", "\u{001B}[?47h"
        ]
        let alternateScreenLeaveSequences = [
            "\u{001B}[?1049l", "\u{001B}[?1047l", "\u{001B}[?47l"
        ]

        do {
            // NONE disables user/system vimrc and viminfo reads, while -n and
            // --noplugin prevent swap/plugin state. The PTY sandbox additionally
            // forces HOME to its per-session disposable runtime directory.
            let command = "exec \(shellQuote(vimPath)) -N -u NONE -U NONE -i NONE -n --noplugin"
            _ = try await session.start(
                command: command,
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"],
                rows: 24,
                columns: 80
            )

            _ = try await waitForOutput(
                session,
                containingAny: alternateScreenEnterSequences,
                timeout: .seconds(5)
            )

            // The expected marker does not occur verbatim in the input. It can
            // appear only after Vim accepts and evaluates this interactive Ex command.
            let interactionBounds = try await session.outputBounds()
            let interactionOffset = interactionBounds.nextOffset
            let interaction = ":echo \"PTY_\" . \"VIM_INTERACTIVE\"\r"
            let interactionWrite = try await session.write(text: interaction)
            XCTAssertEqual(interactionWrite.bytesWritten, interaction.utf8.count)
            _ = try await waitForOutput(
                session,
                offset: interactionOffset,
                containingAny: ["PTY_VIM_INTERACTIVE"],
                timeout: .seconds(5)
            )

            let releaseBounds = try await session.outputBounds()
            let releaseOffset = releaseBounds.nextOffset
            let quit = ":qa!\r"
            let quitWrite = try await session.write(text: quit)
            XCTAssertEqual(quitWrite.bytesWritten, quit.utf8.count)
            let finished = try await waitForFinalStatus(session, timeout: .seconds(5))
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
            XCTAssertNil(finished.terminationSignal)

            _ = try await waitForOutput(
                session,
                offset: releaseOffset,
                containingAny: alternateScreenLeaveSequences,
                timeout: .seconds(2)
            )
        } catch {
            await session.dispose()
            throw error
        }

        // Normal process completion must leave teardown safe and idempotent.
        await session.dispose()
        await session.dispose()
        let statusAfterDispose = try await session.status()
        XCTAssertEqual(statusAfterDispose.state, .exited)
        XCTAssertEqual(statusAfterDispose.exitCode, 0)
    }

    func testPTYRunsRealPythonREPLAndReturnsEvaluatedOutput() async throws {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("The system Python executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("python-repl")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(pythonPath)) -I -q",
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"]
            )
            _ = try await waitForOutput(session, containing: ">>> ")

            let interactionBounds = try await session.outputBounds()
            let interaction = #"print("PTY_" + "PYTHON_INTERACTIVE")"# + "\r"
            _ = try await session.write(text: interaction)
            _ = try await waitForOutput(
                session,
                offset: interactionBounds.nextOffset,
                containingAny: ["PTY_PYTHON_INTERACTIVE"],
                timeout: .seconds(5)
            )

            _ = try await session.write(text: "exit()\r")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealNanoAndAcceptsInteractiveQuit() async throws {
        let nanoPath = "/usr/bin/nano"
        guard FileManager.default.isExecutableFile(atPath: nanoPath) else {
            throw XCTSkip("The system nano executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("nano-tui")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt")
        try Data("PTY_NANO_EXISTING_CONTENT\n".utf8).write(to: fixture)
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(nanoPath)) -w \(shellQuote(fixture.path))",
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"],
                rows: 24,
                columns: 80
            )
            _ = try await waitForOutput(
                session,
                containing: "PTY_NANO_EXISTING_CONTENT",
                timeout: .seconds(5)
            )

            let quit = try await session.write(Data([0x18]))
            XCTAssertEqual(quit.bytesWritten, 1)
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
            XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "PTY_NANO_EXISTING_CONTENT\n")
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealTopSnapshot() async throws {
        let topPath = "/usr/bin/top"
        guard FileManager.default.isExecutableFile(atPath: topPath) else {
            throw XCTSkip("The system top executable is unavailable on this platform.")
        }
        var topInfo = Darwin.stat()
        if Darwin.lstat(topPath, &topInfo) == 0, topInfo.st_mode & S_ISUID != 0 {
            // macOS ships top setuid-root. Seatbelt deliberately refuses a
            // privilege-changing exec from an Agent terminal; htop exercises
            // the interactive process-monitor path without that escalation.
            throw XCTSkip("The system top executable is setuid and intentionally blocked by the PTY sandbox.")
        }

        let root = try makeWorkspaceRoot("top")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(topPath)) -l 1 -n 0 -stats pid,command",
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"]
            )
            let finished = try await waitForExit(session, timeout: .seconds(10))
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
            let output = try await session.readOutput(maxBytes: 1 * 1_024 * 1_024)
            let text = String(decoding: output.data, as: UTF8.self)
            XCTAssertTrue(text.contains("Processes:"), text)
            XCTAssertTrue(text.contains("Load Avg:"), text)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealHtopTUIAndAcceptsInteractiveQuit() async throws {
        let htopPath = "/opt/homebrew/bin/htop"
        guard FileManager.default.isExecutableFile(atPath: htopPath) else {
            throw XCTSkip("The Homebrew htop executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("htop-tui")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(htopPath)) --readonly --no-mouse --no-color --delay=1",
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"],
                rows: 24,
                columns: 100
            )
            _ = try await waitForOutput(
                session,
                containingAny: ["\u{001B}[?1049h", "\u{001B}[?1047h", "\u{001B}[?47h"],
                timeout: .seconds(5)
            )

            let quit = try await session.write(text: "q")
            XCTAssertEqual(quit.bytesWritten, 1)
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealGitPatchSelectionWithoutStagingRejectedHunk() async throws {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw XCTSkip("The system Git executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("git-patch")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt")
        try runProcess(gitPath, arguments: ["init", "--quiet"], cwd: root)
        try Data("base\n".utf8).write(to: fixture)
        try runProcess(gitPath, arguments: ["add", "--", "fixture.txt"], cwd: root)
        try runProcess(
            gitPath,
            arguments: [
                "-c", "user.name=LumaChat PTY Test",
                "-c", "user.email=pty-test@example.invalid",
                "commit", "--quiet", "-m", "fixture"
            ],
            cwd: root
        )
        try Data("base\nchanged\n".utf8).write(to: fixture)

        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(gitPath)) add --patch -- fixture.txt",
                environment: [
                    "TERM": "xterm-256color",
                    "LC_ALL": "C",
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_PAGER": "cat"
                ],
                allowsGitMetadata: true,
                allowsGitMetadataWrite: true
            )
            _ = try await waitForOutput(session, containing: "Stage this hunk")
            _ = try await session.write(text: "n\r")
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)

            XCTAssertEqual(
                try processExitCode(gitPath, arguments: ["diff", "--cached", "--quiet"], cwd: root),
                0,
                "Rejecting the hunk must leave the index unchanged."
            )
            XCTAssertEqual(
                try processExitCode(gitPath, arguments: ["diff", "--quiet"], cwd: root),
                1,
                "Rejecting the hunk must leave the working-tree change present."
            )
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealSSHConfigurationExpansionWithoutNetworkAccess() async throws {
        let sshPath = "/usr/bin/ssh"
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw XCTSkip("The system SSH executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("ssh-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("offline-config")
        try Data(
            "#!/bin/sh\nexec \(shellQuote(sshPath)) -F /dev/null -G example.invalid\n".utf8
        ).write(to: wrapper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: wrapper.path
        )
        let session = try makeSession(root: root)
        do {
            // `ssh -G` expands and prints configuration, then exits without
            // resolving a host, opening a socket, or contacting an SSH agent.
            // Keeping `ssh` out of the parent command also leaves Seatbelt's
            // network rules disabled, so an accidental socket would fail closed.
            _ = try await session.start(
                command: "exec \(shellQuote(wrapper.path))",
                environment: ["TERM": "xterm-256color", "LC_ALL": "C"]
            )
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
            let output = try await session.readOutput(maxBytes: 64 * 1_024)
            let text = String(decoding: output.data, as: UTF8.self)
            XCTAssertTrue(text.contains("hostname example.invalid"), text)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRunsRealPipPromptAndDeclinesWithoutMutation() async throws {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("The system Python executable is unavailable on this platform.")
        }

        let root = try makeWorkspaceRoot("pip-prompt")
        defer { try? FileManager.default.removeItem(at: root) }
        let environmentRoot = root.appendingPathComponent("venv", isDirectory: true)
        try runProcess(
            pythonPath,
            arguments: ["-m", "venv", environmentRoot.path],
            cwd: root
        )
        let isolatedPython = environmentRoot.appendingPathComponent("bin/python3").path
        guard FileManager.default.isExecutableFile(atPath: isolatedPython) else {
            throw XCTSkip("The isolated Python environment did not provide an executable.")
        }
        let purelibOutput = try runProcess(
            isolatedPython,
            arguments: [
                "-c",
                "import sysconfig; print(sysconfig.get_paths()['purelib'])"
            ],
            cwd: root
        )
        let purelibPath = String(decoding: purelibOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let purelib = URL(fileURLWithPath: purelibPath, isDirectory: true)
        let module = purelib.appendingPathComponent("lumachat_pty_prompt.py")
        let metadata = purelib.appendingPathComponent(
            "lumachat_pty_prompt-1.0.dist-info",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("MARKER = 'installed'\n".utf8).write(to: module)
        try Data(
            "Metadata-Version: 2.1\nName: lumachat-pty-prompt\nVersion: 1.0\n".utf8
        ).write(to: metadata.appendingPathComponent("METADATA"))
        try Data("pip\n".utf8).write(to: metadata.appendingPathComponent("INSTALLER"))
        try Data(
            "lumachat_pty_prompt.py,,\n"
                .appending("lumachat_pty_prompt-1.0.dist-info/INSTALLER,,\n")
                .appending("lumachat_pty_prompt-1.0.dist-info/METADATA,,\n")
                .appending("lumachat_pty_prompt-1.0.dist-info/RECORD,,\n")
                .utf8
        ).write(to: metadata.appendingPathComponent("RECORD"))

        let session = try makeSession(root: root)
        do {
            _ = try await session.start(
                command: "exec \(shellQuote(isolatedPython)) -m pip uninstall lumachat-pty-prompt",
                environment: [
                    "TERM": "xterm-256color",
                    "LC_ALL": "C",
                    "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                    "PYTHONNOUSERSITE": "1"
                ]
            )
            _ = try await waitForOutput(
                session,
                containing: "Proceed (Y/n)?",
                timeout: .seconds(10)
            )
            _ = try await session.write(text: "n\r")
            let finished = try await waitForExit(session, timeout: .seconds(10))
            XCTAssertEqual(finished.state, .exited)
            XCTAssertEqual(finished.exitCode, 0)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: module.path),
                "Declining the real package-manager prompt must not remove the package."
            )
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYGenericSignalReachesForegroundHandler() async throws {
        let root = try makeWorkspaceRoot("generic-signal")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"exec /usr/bin/perl -e '$|=1; $SIG{TERM}=sub { print qq{TERM-RECEIVED\n}; exit 29 }; print qq{READY\n}; select(undef,undef,undef,30); exit 63;'"#
            let started = try await session.start(command: command)
            _ = try await waitForOutput(session, containing: "READY")
            let signaled = try await session.signal(SIGTERM)
            XCTAssertEqual(signaled.processIdentifier, started.processIdentifier)
            _ = try await waitForOutput(session, containing: "TERM-RECEIVED")
            let finished = try await waitForExit(session)
            XCTAssertNotEqual(finished.state, .running)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYRepeatedImmediateExitLifecycleCompletesWithoutHanging() async throws {
        let root = try makeWorkspaceRoot("immediate-exit")
        defer { try? FileManager.default.removeItem(at: root) }

        for expectedCode in 0..<6 {
            let session = try makeSession(root: root)
            do {
                _ = try await session.start(command: "exit \(expectedCode)")
                let finished = try await waitForExit(session, timeout: .seconds(5))
                XCTAssertEqual(finished.state, .exited, "iteration \(expectedCode)")
                XCTAssertEqual(finished.exitCode, Int32(expectedCode), "iteration \(expectedCode)")
            } catch {
                await session.dispose()
                throw error
            }
            await session.dispose()
        }
    }

    func testPTYResizeDeliversSIGWINCHAndExactWindowSize() async throws {
        let root = try makeWorkspaceRoot("resize")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            let command = #"/usr/bin/perl -e '$|=1; my $done=0; $SIG{WINCH}=sub { open(my $size,q{-|},q{/bin/stty},q{size}) or exit 41; my $line=<$size>; close($size); print qq{SIZE:$line}; $done=1; }; open(my $initial,q{-|},q{/bin/stty},q{size}) or exit 42; my $line=<$initial>; close($initial); print qq{INITIAL:$line}; print qq{READY\n}; sleep 1 until $done;'"#
            let started = try await session.start(command: command, rows: 24, columns: 80)
            let ready = try await waitForOutput(session, containing: "READY")
            let readyText = String(decoding: ready.data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            XCTAssertTrue(readyText.contains("INITIAL:24 80"), readyText)
            let resized = try await session.resize(rows: 41, columns: 132)
            XCTAssertEqual(resized.dimensions, .init(rows: 41, columns: 132))
            let output = try await waitForOutput(session, containing: "SIZE:41 132")
            let outputText = String(decoding: output.data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            XCTAssertTrue(outputText.contains("SIZE:41 132"), outputText)
            let finished = try await waitForExit(session)
            XCTAssertEqual(finished.exitCode, 0)
            XCTAssertEqual(finished.processIdentifier, started.processIdentifier)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYContinuouslyDrainsAndBoundsScrollbackWithoutConsumer() async throws {
        let root = try makeWorkspaceRoot("bounded")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root, scrollbackBytes: 4_096)
        do {
            let command = #"/usr/bin/perl -e 'sub emit { my $value=shift; while (length($value)) { my $count=syswrite(STDOUT,$value); exit 51 unless defined($count) && $count > 0; substr($value,0,$count,q{}); } } my $chunk=q{A} x 65536; emit($chunk) for 1..64; emit(q{TAILMARK});'"#
            _ = try await session.start(command: command)
            let finished = try await waitForExit(session, timeout: .seconds(10))
            XCTAssertEqual(finished.exitCode, 0)
            let output = try await session.readOutput(offset: 0, maxBytes: 4_096)
            XCTAssertEqual(output.data.count, 4_096)
            XCTAssertTrue(output.truncatedBeforeOffset)
            XCTAssertGreaterThanOrEqual(output.earliestAvailableOffset, 4 * 1_024 * 1_024 - 4_096)
            XCTAssertTrue(output.data.suffix(8) == Data("TAILMARK".utf8))
            XCTAssertFalse(output.hasMore)
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYStopKillsOwnedProcessTreeAndDoesNotAffectAnotherSession() async throws {
        let firstRoot = try makeWorkspaceRoot("isolation-a")
        let secondRoot = try makeWorkspaceRoot("isolation-b")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let first = try makeSession(root: firstRoot)
        let second = try makeSession(root: secondRoot)
        let orphanMarker = firstRoot.appendingPathComponent("orphan.txt")
        do {
            let firstCommand = "trap '' TERM; (trap '' TERM; /bin/sleep 5; /usr/bin/touch \(shellQuote(orphanMarker.path))) & printf 'READY-A\\n'; wait"
            let secondCommand = "printf 'READY-B\\n'; IFS= read -r value; printf 'SECOND:%s\\n' \"$value\""
            let firstStatus = try await first.start(command: firstCommand)
            _ = try await second.start(command: secondCommand)
            _ = try await waitForOutput(first, containing: "READY-A")
            _ = try await waitForOutput(second, containing: "READY-B")

            let stopped = try await first.stop()
            XCTAssertEqual(stopped.state, .stopped)
            XCTAssertNotEqual(Darwin.kill(-firstStatus.processIdentifier, 0), 0)
            XCTAssertEqual(errno, ESRCH)

            _ = try await second.write(text: "still-alive\n")
            let secondOutput = try await waitForOutput(second, containing: "SECOND:still-alive")
            XCTAssertTrue(String(decoding: secondOutput.data, as: UTF8.self).contains("SECOND:still-alive"))
            let secondFinished = try await waitForExit(second)
            XCTAssertEqual(secondFinished.exitCode, 0)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        } catch {
            await first.dispose()
            await second.dispose()
            throw error
        }
        await first.dispose()
        await second.dispose()
    }

    func testPTYStopKillsDescendantsThatCreateANewSession() async throws {
        let root = try makeWorkspaceRoot("detached-session")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        let marker = root.appendingPathComponent("detached-marker.txt")
        do {
            let command = #"/usr/bin/perl -MPOSIX -e '$|=1; my $session=POSIX::setsid(); exit 71 if $session < 0; $SIG{TERM}=q{IGNORE}; my $child=fork(); exit 72 unless defined($child); if ($child == 0) { $SIG{TERM}=q{IGNORE}; sleep 3; open(my $file,q{>},$ENV{LUMA_MARKER}) or exit 73; print $file q{escaped}; close($file); exit 0; } print qq{DETACHED:$$:$child\n}; sleep 30;' & printf 'READY\n'; wait"#
            _ = try await session.start(
                command: command,
                environment: ["LUMA_MARKER": marker.path]
            )
            _ = try await waitForOutput(session, containing: "READY")
            let output = try await waitForOutput(session, containing: "DETACHED:")
            let normalized = String(decoding: output.data, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            let identityLine = try XCTUnwrap(
                normalized.split(separator: "\n").first(where: {
                    $0.hasPrefix("DETACHED:")
                })
            )
            let identifiers = identityLine.split(separator: ":").dropFirst().compactMap {
                Int32($0)
            }
            XCTAssertEqual(identifiers.count, 2, normalized)

            let stopped = try await session.stop()
            XCTAssertEqual(stopped.state, .stopped)
            try await Task.sleep(for: .milliseconds(300))
            for identifier in identifiers {
                XCTAssertNotEqual(Darwin.kill(identifier, 0), 0)
                XCTAssertEqual(errno, ESRCH)
            }
            try await Task.sleep(for: .seconds(3))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    func testPTYSandboxStillRejectsWorkspaceEscape() async throws {
        let root = try makeWorkspaceRoot("sandbox")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(root: root)
        do {
            _ = try await session.start(command: "/bin/cat /etc/passwd")
            let finished = try await waitForExit(session)
            XCTAssertNotEqual(finished.exitCode, 0)
            let output = try await session.readOutput(maxBytes: 64 * 1_024)
            XCTAssertFalse(String(decoding: output.data, as: UTF8.self).contains("root:*:"))
        } catch {
            await session.dispose()
            throw error
        }
        await session.dispose()
    }

    private func waitForOutput(
        _ session: PseudoTerminalSession,
        containing expected: String,
        timeout: Duration = .seconds(5)
    ) async throws -> PseudoTerminalOutput {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            let output = try await session.readOutput(offset: 0, maxBytes: 1 * 1_024 * 1_024)
            if String(decoding: output.data, as: UTF8.self).contains(expected) {
                return output
            }
            let state = try await session.status().state
            if state != .running {
                // Exit and read readiness are independent kernel events. Wait
                // for the reader completion before declaring a final marker
                // missing, otherwise a fast-exit process can race this poll.
                _ = try await session.waitForExit()
                let finalOutput = try await session.readOutput(
                    offset: 0,
                    maxBytes: 1 * 1_024 * 1_024
                )
                if String(decoding: finalOutput.data, as: UTF8.self).contains(expected) {
                    return finalOutput
                }
                XCTFail(
                    "PTY exited before emitting \(expected): "
                        + String(decoding: finalOutput.data, as: UTF8.self)
                )
                return finalOutput
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for PTY output: \(expected)")
        return try await session.readOutput(offset: 0, maxBytes: 1 * 1_024 * 1_024)
    }

    private func waitForOutput(
        _ session: PseudoTerminalSession,
        offset: Int64 = 0,
        containingAny expected: [String],
        timeout: Duration
    ) async throws -> PseudoTerminalOutput {
        let started = ContinuousClock.now
        var latest = try await session.readOutput(
            offset: offset,
            maxBytes: 1 * 1_024 * 1_024
        )
        while started.duration(to: .now) < timeout {
            let text = String(decoding: latest.data, as: UTF8.self)
            if expected.contains(where: text.contains) {
                return latest
            }
            try await Task.sleep(for: .milliseconds(10))
            latest = try await session.readOutput(
                offset: offset,
                maxBytes: 1 * 1_024 * 1_024
            )
        }
        XCTFail(
            "Timed out waiting for any PTY output marker \(expected): "
                + String(decoding: latest.data, as: UTF8.self)
        )
        throw PTYTestError.timeout
    }

    private func waitForFinalStatus(
        _ session: PseudoTerminalSession,
        timeout: Duration
    ) async throws -> PseudoTerminalStatus {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            let status = try await session.status()
            if status.state != .running {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for PTY process exit.")
        throw PTYTestError.timeout
    }

    private func waitForExit(
        _ session: PseudoTerminalSession,
        timeout: Duration = .seconds(5)
    ) async throws -> PseudoTerminalStatus {
        try await withThrowingTaskGroup(of: PseudoTerminalStatus.self) { group in
            group.addTask { try await session.waitForExit() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PTYTestError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func makeWorkspaceRoot(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("pty-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func runProcess(_ executable: String, arguments: [String], cwd: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": cwd.path,
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw PTYProcessError.failed(
                executable: executable,
                arguments: arguments,
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }

    private func processExitCode(_ executable: String, arguments: [String], cwd: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": cwd.path,
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus
    }

    private func makeSession(
        root: URL,
        scrollbackBytes: Int = PseudoTerminalSession.defaultScrollbackBytes
    ) throws -> PseudoTerminalSession {
        try PseudoTerminalSession(
            validator: WorkspaceSecurityValidator(
                workspace: AgentWorkspace(
                    name: root.lastPathComponent,
                    rootPath: root.path,
                    allowedPaths: [],
                    bookmarkData: nil,
                    gitRepository: false,
                    branch: nil
                )
            ),
            scrollbackBytes: scrollbackBytes
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum PTYTestError: Error { case timeout }

private enum PTYProcessError: Error, CustomStringConvertible {
    case failed(executable: String, arguments: [String], status: Int32, output: String)

    var description: String {
        switch self {
        case .failed(let executable, let arguments, let status, let output):
            "\(executable) \(arguments.joined(separator: " ")) failed with \(status): \(output)"
        }
    }
}
