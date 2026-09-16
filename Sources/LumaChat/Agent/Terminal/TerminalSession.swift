import Foundation
import Darwin

enum TerminalSessionError: LocalizedError, Sendable {
    case invalidShell(String)
    case processNotFound(UUID)
    case processNotRunning(UUID)
    case processInputClosed(UUID)
    case processInputBusy(UUID)
    case processInputTooLarge(maxBytes: Int)
    case processInputBackpressure(UUID, bytesWritten: Int)
    case emptyProcessInput
    case launchFailed(String)
    case sandboxUnavailable(String)
    case workspaceBoundary(String)

    var errorDescription: String? {
        switch self {
        case .invalidShell(let shell): "Unsupported shell: \(shell)"
        case .processNotFound(let id): "Managed process not found: \(id.uuidString)"
        case .processNotRunning(let id): "Managed process is no longer running: \(id.uuidString)"
        case .processInputClosed(let id): "Managed process stdin is already closed: \(id.uuidString)"
        case .processInputBusy(let id): "Managed process already has an input write in progress: \(id.uuidString)"
        case .processInputTooLarge(let maxBytes): "Managed process input exceeds the \(maxBytes)-byte UTF-8 limit."
        case .processInputBackpressure(let id, let bytesWritten):
            "Managed process did not accept more input in time: \(id.uuidString) (\(bytesWritten) bytes written)"
        case .emptyProcessInput: "Managed process input must contain text or request stdin closure."
        case .launchFailed(let detail): "Unable to launch command: \(detail)"
        case .sandboxUnavailable(let detail): "Secure terminal sandbox unavailable: \(detail)"
        case .workspaceBoundary(let path): "Terminal path is outside the selected workspace: \(path)"
        }
    }
}

struct TerminalCommandResult: Codable, Sendable, Equatable {
    var command: String
    var cwd: String
    var finalCWD: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var duration: TimeInterval
    var timedOut: Bool
    var truncated: Bool
    var stdoutArtifactPath: String?
    var stderrArtifactPath: String?
}

enum ManagedProcessState: String, Codable, Sendable {
    case running
    case exited
    case stopped
}

struct ManagedProcessStatus: Codable, Sendable, Equatable {
    var id: UUID
    var command: String
    var cwd: String
    var processIdentifier: Int32
    var state: ManagedProcessState
    var exitCode: Int32?
    var startedAt: Date
    var duration: TimeInterval
}

struct ManagedProcessOutput: Codable, Sendable, Equatable {
    var id: UUID
    var stdout: ProcessOutputChunk
    var stderr: ProcessOutputChunk
}

struct ManagedProcessInputResult: Codable, Sendable, Equatable {
    var id: UUID
    var bytesWritten: Int
    var stdinClosed: Bool
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var ownsDedicatedProcessGroup = false

    init(_ process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }

    /// The fixed launcher calls setsid() before sandbox-exec. Wait briefly for
    /// that transition so cancellation can signal the entire descendant group
    /// instead of leaving compilers, servers, or `sleep` children orphaned.
    func confirmDedicatedProcessGroup() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        for _ in 0..<50 {
            // The fixed Perl launcher either creates group `pid` before exec or
            // was already its own group leader. `kill(-pid, 0)` also detects a
            // surviving descendant group after an extremely fast leader exit.
            if Darwin.getpgid(pid) == pid || Darwin.kill(-pid, 0) == 0 {
                lock.lock()
                ownsDedicatedProcessGroup = true
                lock.unlock()
                return
            }
            if !process.isRunning {
                if Darwin.kill(-pid, 0) == 0 {
                    lock.lock()
                    ownsDedicatedProcessGroup = true
                    lock.unlock()
                }
                return
            }
            usleep(1_000)
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        signal(SIGTERM)
    }

    func forceTerminate() {
        signal(SIGKILL)
    }

    /// Natural shell exit must not detach a background grandchild. A process
    /// group remains addressable after its leader exits while members survive.
    func terminateRemainingDescendants() {
        lock.lock()
        let ownsGroup = ownsDedicatedProcessGroup
        lock.unlock()
        guard ownsGroup else { return }
        let group = -process.processIdentifier
        guard Darwin.kill(group, 0) == 0 else { return }
        Darwin.kill(group, SIGTERM)
        usleep(50_000)
        if Darwin.kill(group, 0) == 0 {
            Darwin.kill(group, SIGKILL)
        }
    }

    private func signal(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        lock.lock()
        let ownsGroup = ownsDedicatedProcessGroup
        lock.unlock()
        if ownsGroup {
            Darwin.kill(-pid, signal)
        } else {
            // During the very short pre-setsid window no user command has run;
            // signalling the fixed launcher PID is therefore fail-safe.
            Darwin.kill(pid, signal)
        }
    }
}

private final class ManagedProcessRecord: @unchecked Sendable {
    let id: UUID
    let command: String
    let launchCWD: URL
    let cwdStateURL: URL
    let startedAt: Date
    let startedClock: ContinuousClock.Instant
    let box: ProcessBox
    let stdout: OutputSpool
    let stderr: OutputSpool
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let stdinPipe: Pipe
    var didFinalize = false
    var wasStopped = false
    var isStdinClosed = false
    var isWritingStdin = false
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()

    init(
        id: UUID,
        command: String,
        launchCWD: URL,
        cwdStateURL: URL,
        process: Process,
        stdout: OutputSpool,
        stderr: OutputSpool,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdinPipe: Pipe
    ) {
        self.id = id
        self.command = command
        self.launchCWD = launchCWD
        self.cwdStateURL = cwdStateURL
        startedAt = Date()
        startedClock = .now
        box = ProcessBox(process)
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdinPipe = stdinPipe
    }

    func finalizeCapture() {
        guard !didFinalize else { return }
        didFinalize = true
        closeStdin()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        drain(stdoutPipe, into: stdout, lock: stdoutReadLock)
        drain(stderrPipe, into: stderr, lock: stderrReadLock)
    }

    func closeStdin() {
        guard !isStdinClosed else { return }
        isStdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    func consumeStdout(from handle: FileHandle) {
        consume(handle, into: stdout, lock: stdoutReadLock)
    }

    func consumeStderr(from handle: FileHandle) {
        consume(handle, into: stderr, lock: stderrReadLock)
    }

    private func consume(_ handle: FileHandle, into spool: OutputSpool, lock: NSLock) {
        lock.lock()
        defer { lock.unlock() }
        spool.append(handle.availableData)
    }

    private func drain(_ pipe: Pipe, into spool: OutputSpool, lock: NSLock) {
        // Disabling a FileHandle callback does not join a callback that was
        // already scheduled. Serializing both callback reads and the final EOF
        // drain makes the no-newline tail deterministic and prevents a late
        // callback from appending after `finish()`/summary.
        lock.lock()
        defer { lock.unlock() }
        spool.append(pipe.fileHandleForReading.readDataToEndOfFile())
        spool.finish()
    }
}

/// A workspace-bound shell session. Each command is a child process, while the
/// final shell working directory is captured and retained for the next command.
actor TerminalSession {
    /// One tool call cannot enqueue an unbounded prompt, pasted document, or
    /// binary-looking payload into a child process. `String` guarantees the
    /// accepted bytes are valid UTF-8.
    static let maximumProcessInputBytes = 64 * 1_024
    /// One-shot commands may consume a larger, host-validated payload over
    /// stdin (for example a bounded Review patch). The bytes never need a
    /// temporary file outside the command's Seatbelt-visible workspace.
    private static let maximumCommandInputBytes = 2 * 1_024 * 1_024
    /// Live UI output is intentionally much smaller than the retained final
    /// result/artifact. This prevents a noisy process from flooding actor hops
    /// or growing a running step without bound.
    static let maximumLiveOutputBytesPerStream = 32 * 1_024
    static let maximumLiveOutputDeltaBytes = 8 * 1_024

    private let validator: WorkspaceSecurityValidator
    private let sandbox: any AgentSandboxPolicy
    private let riskAnalyzer = CommandRiskAnalyzer()
    private var currentDirectory: URL
    private var environment: [String: String]
    private var processes: [UUID: ManagedProcessRecord] = [:]
    private let retainedOutputBytes: Int
    private let artifactOutputBytes: Int
    private let captureBudget: OutputCaptureBudget

    init(
        validator: WorkspaceSecurityValidator,
        cwd: String? = nil,
        environment: [String: String] = [:],
        retainedOutputBytes: Int = 64 * 1_024,
        artifactOutputBytes: Int = 32 * 1_024 * 1_024,
        sessionArtifactOutputBytes: Int = 256 * 1_024 * 1_024,
        sandboxBackend: any SandboxBackend = MacOSSandboxBackend()
    ) throws {
        self.validator = validator
        sandbox = try sandboxBackend.makeWorkspacePolicy(
            validator: validator,
            additionalReadOnlyRoots: []
        )
        let initialDirectory: URL
        do {
            initialDirectory = try validator.validate(cwd: cwd)
        } catch {
            throw TerminalSessionError.workspaceBoundary(cwd ?? ".")
        }
        guard sandbox.containsWorkspacePath(initialDirectory) else {
            throw TerminalSessionError.workspaceBoundary(initialDirectory.path)
        }
        currentDirectory = initialDirectory
        self.environment = Self.safeEnvironment(environment)
        self.retainedOutputBytes = max(4_096, retainedOutputBytes)
        self.artifactOutputBytes = max(64 * 1_024, artifactOutputBytes)
        captureBudget = OutputCaptureBudget(
            byteLimit: max(artifactOutputBytes, sessionArtifactOutputBytes)
        )
    }

    func workingDirectory() -> String {
        validator.relativePath(for: currentDirectory)
    }

    func updateEnvironment(_ values: [String: String]) {
        environment.merge(Self.safeEnvironment(values)) { _, new in new }
    }

    func run(
        command: String,
        cwd: String? = nil,
        timeout: TimeInterval,
        environment commandEnvironment: [String: String] = [:],
        redactionSecrets: [String] = [],
        shell: String = "/bin/zsh",
        allowsNetwork: Bool = false,
        allowsGitMetadata: Bool = false,
        allowsGitMetadataWrite: Bool = false,
        allowsWorkspaceWrite: Bool = true,
        standardInput: Data? = nil,
        progressHandler: AgentToolProgressHandler? = nil
    ) async throws -> TerminalCommandResult {
        try Task.checkCancellation()
        let input = standardInput ?? Data()
        guard input.count <= Self.maximumCommandInputBytes else {
            throw TerminalSessionError.processInputTooLarge(
                maxBytes: Self.maximumCommandInputBytes
            )
        }
        let record = try launch(
            command: command,
            cwd: cwd,
            environment: commandEnvironment,
            redactionSecrets: redactionSecrets,
            shell: shell,
            allowsNetwork: allowsNetwork,
            allowsGitMetadata: allowsGitMetadata,
            allowsGitMetadataWrite: allowsGitMetadataWrite,
            allowsWorkspaceWrite: allowsWorkspaceWrite,
            keepStandardInputOpen: !input.isEmpty
        )
        if !input.isEmpty {
            record.isWritingStdin = true
            do {
                _ = try await writeNonblocking(input, to: record)
                record.isWritingStdin = false
                record.closeStdin()
            } catch {
                record.isWritingStdin = false
                record.closeStdin()
                record.box.forceTerminate()
                await waitForExit(record)
                try? finalize(record)
                throw error
            }
        }
        var progress = LiveProgressCursor()
        let race = await waitForExitOrTimeout(
            record,
            timeout: max(0.1, timeout),
            progress: &progress,
            progressHandler: progressHandler
        )
        await waitForExit(record)
        try finalize(record)
        // `OutputSpool` withholds an unterminated line until finalization so a
        // secret split across readability callbacks can never leak. Drain the
        // newly-safe tail through the same bounded progress channel.
        if let progressHandler {
            for _ in 0..<8 {
                let previous = (progress.stdoutOffset, progress.stderrOffset)
                await publishLiveProgress(
                    record,
                    progress: &progress,
                    progressHandler: progressHandler
                )
                if previous == (progress.stdoutOffset, progress.stderrOffset) { break }
            }
        }
        try Task.checkCancellation()

        let stdout = record.stdout.summary()
        let stderr = record.stderr.summary()
        let duration = record.startedClock.duration(to: .now).timeInterval
        return TerminalCommandResult(
            command: record.command,
            cwd: validator.relativePath(for: record.launchCWD),
            finalCWD: validator.relativePath(for: currentDirectory),
            stdout: stdout.text,
            stderr: stderr.text,
            exitCode: record.box.process.terminationStatus,
            duration: duration,
            timedOut: race == .timedOut,
            truncated: stdout.truncated || stderr.truncated,
            stdoutArtifactPath: stdout.artifactPath,
            stderrArtifactPath: stderr.artifactPath
        )
    }

    func start(
        command: String,
        cwd: String? = nil,
        environment commandEnvironment: [String: String] = [:],
        shell: String = "/bin/zsh",
        allowsNetwork: Bool = false
    ) throws -> ManagedProcessStatus {
        let record = try launch(
            command: command,
            cwd: cwd,
            environment: commandEnvironment,
            redactionSecrets: [],
            shell: shell,
            allowsNetwork: allowsNetwork,
            allowsGitMetadata: false,
            allowsGitMetadataWrite: false,
            allowsWorkspaceWrite: true,
            keepStandardInputOpen: true
        )
        processes[record.id] = record
        return status(for: record)
    }

    func processStatus(id: UUID) throws -> ManagedProcessStatus {
        guard let record = processes[id] else { throw TerminalSessionError.processNotFound(id) }
        if !record.box.process.isRunning { try finalize(record) }
        return status(for: record)
    }

    func readProcessOutput(
        id: UUID,
        stdoutOffset: Int64 = 0,
        stderrOffset: Int64 = 0,
        maxBytes: Int = 64 * 1_024
    ) throws -> ManagedProcessOutput {
        guard let record = processes[id] else { throw TerminalSessionError.processNotFound(id) }
        if !record.box.process.isRunning { try finalize(record) }
        return ManagedProcessOutput(
            id: id,
            stdout: try record.stdout.read(offset: stdoutOffset, maxBytes: maxBytes),
            stderr: try record.stderr.read(offset: stderrOffset, maxBytes: maxBytes)
        )
    }

    /// Sends bounded UTF-8 text to a process created by `start`. The pipe is
    /// nonblocking so a child that stops reading cannot hang the Agent. Actor
    /// reentrancy is explicitly guarded to preserve input ordering while the
    /// method yields during backpressure.
    func writeProcessInput(
        id: UUID,
        input: String = "",
        close: Bool = false
    ) async throws -> ManagedProcessInputResult {
        try Task.checkCancellation()
        guard let record = processes[id] else { throw TerminalSessionError.processNotFound(id) }
        guard record.box.process.isRunning else {
            try finalize(record)
            throw TerminalSessionError.processNotRunning(id)
        }
        guard !record.isStdinClosed else { throw TerminalSessionError.processInputClosed(id) }
        guard !record.isWritingStdin else { throw TerminalSessionError.processInputBusy(id) }

        let data = Data(input.utf8)
        guard data.count <= Self.maximumProcessInputBytes else {
            throw TerminalSessionError.processInputTooLarge(
                maxBytes: Self.maximumProcessInputBytes
            )
        }
        guard !data.isEmpty || close else { throw TerminalSessionError.emptyProcessInput }

        record.isWritingStdin = true
        defer { record.isWritingStdin = false }
        let bytesWritten = try await writeNonblocking(data, to: record)
        try Task.checkCancellation()
        if close { record.closeStdin() }
        return ManagedProcessInputResult(
            id: id,
            bytesWritten: bytesWritten,
            stdinClosed: record.isStdinClosed
        )
    }

    func stopProcess(id: UUID) async throws -> ManagedProcessStatus {
        guard let record = processes[id] else { throw TerminalSessionError.processNotFound(id) }
        record.wasStopped = true
        record.closeStdin()
        if record.box.process.isRunning {
            await terminate(record)
        }
        try finalize(record)
        return status(for: record)
    }

    func stopAll() async {
        for record in processes.values where record.box.process.isRunning {
            record.wasStopped = true
            record.closeStdin()
            record.box.terminate()
        }
        for record in processes.values {
            record.closeStdin()
            if record.box.process.isRunning { await terminate(record) }
            try? finalize(record)
        }
    }

    func dispose() async {
        await stopAll()
        let runtime = sandbox.runtimeEnvironment.root.standardizedFileURL
        let parent = AppPaths.agentProcesses.standardizedFileURL
        guard runtime.path.hasPrefix(parent.path + "/") else { return }
        try? FileManager.default.removeItem(at: runtime)
    }

    private func launch(
        command: String,
        cwd: String?,
        environment commandEnvironment: [String: String],
        redactionSecrets: [String],
        shell: String,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool,
        allowsGitMetadataWrite: Bool,
        allowsWorkspaceWrite: Bool,
        keepStandardInputOpen: Bool
    ) throws -> ManagedProcessRecord {
        guard ["/bin/zsh", "/bin/bash", "/bin/sh"].contains(shell) else {
            throw TerminalSessionError.invalidShell(shell)
        }
        let launchCWD: URL
        do {
            launchCWD = try cwd.map { try validator.validate(cwd: $0) } ?? currentDirectory
        } catch {
            throw TerminalSessionError.workspaceBoundary(cwd ?? ".")
        }
        guard sandbox.containsWorkspacePath(launchCWD) else {
            throw TerminalSessionError.workspaceBoundary(launchCWD.path)
        }
        try AppPaths.ensureAgentDirectories()
        let id = UUID()
        let stateURL = sandbox.runtimeEnvironment.root
            .appendingPathComponent("cwd-\(id.uuidString.lowercased()).txt")
        guard FileManager.default.createFile(atPath: stateURL.path, contents: Data()) else {
            throw TerminalSessionError.launchFailed("Unable to create the bounded cwd state file.")
        }
        let configuredSecrets = Self.secretValues(
            in: environment.merging(commandEnvironment) { _, commandValue in commandValue }
        ) + Self.secretValues(inCommand: command) + redactionSecrets.filter {
            $0.utf8.count >= 4 && !$0.contains("\0")
        }
        let displayCommand = Self.redactedCommand(command, configuredSecrets: configuredSecrets)
        let stdout = try OutputSpool(
            prefix: "stdout-\(id.uuidString)",
            retainedByteLimit: retainedOutputBytes,
            artifactByteLimit: artifactOutputBytes,
            configuredSecrets: configuredSecrets,
            captureBudget: captureBudget
        )
        let stderr = try OutputSpool(
            prefix: "stderr-\(id.uuidString)",
            retainedByteLimit: retainedOutputBytes,
            artifactByteLimit: artifactOutputBytes,
            configuredSecrets: configuredSecrets,
            captureBudget: captureBudget
        )
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        do {
            try Self.configureNonblockingInputPipe(stdinPipe)
        } catch {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: stateURL)
            throw TerminalSessionError.launchFailed("Unable to configure managed process input.")
        }
        let process = Process()
        process.executableURL = sandbox.launcherExecutable
        let assessment = riskAnalyzer.assess(command)
        process.arguments = sandbox.launcherArguments(
            command: Self.wrappedCommand(command, cwdStateURL: stateURL),
            shell: shell,
            allowsNetwork: allowsNetwork || assessment.usesNetwork,
            allowsGitMetadata: allowsGitMetadata,
            allowsGitMetadataWrite: allowsGitMetadataWrite,
            allowsWorkspaceWrite: allowsWorkspaceWrite
        )
        process.currentDirectoryURL = launchCWD
        process.environment = sandbox.environment(
            session: environment,
            command: Self.safeEnvironment(commandEnvironment)
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let record = ManagedProcessRecord(
            id: id,
            command: displayCommand,
            launchCWD: launchCWD,
            cwdStateURL: stateURL,
            process: process,
            stdout: stdout,
            stderr: stderr,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdinPipe: stdinPipe
        )
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak record] handle in
            record?.consumeStdout(from: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak record] handle in
            record?.consumeStderr(from: handle)
        }
        do {
            try process.run()
            // The child inherited its own read descriptor. The host owns only
            // the private write endpoint, so closing it produces a real EOF.
            try? stdinPipe.fileHandleForReading.close()
            if !keepStandardInputOpen { record.closeStdin() }
            record.box.confirmDedicatedProcessGroup()
        } catch {
            record.closeStdin()
            try? stdinPipe.fileHandleForReading.close()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw TerminalSessionError.launchFailed(error.localizedDescription)
        }
        return record
    }

    private func writeNonblocking(
        _ data: Data,
        to record: ManagedProcessRecord
    ) async throws -> Int {
        guard !data.isEmpty else { return 0 }
        let descriptor = record.stdinPipe.fileHandleForWriting.fileDescriptor
        let started = ContinuousClock.now
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard record.box.process.isRunning else {
                record.closeStdin()
                throw TerminalSessionError.processNotRunning(record.id)
            }
            guard !record.isStdinClosed else {
                throw TerminalSessionError.processInputClosed(record.id)
            }

            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                guard started.duration(to: .now) < .seconds(2) else {
                    throw TerminalSessionError.processInputBackpressure(
                        record.id,
                        bytesWritten: offset
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            if errno == EINTR { continue }
            if errno == EPIPE {
                record.closeStdin()
                throw TerminalSessionError.processNotRunning(record.id)
            }
            record.closeStdin()
            throw TerminalSessionError.launchFailed("Managed process input write failed.")
        }
        return offset
    }

    private static func configureNonblockingInputPipe(_ pipe: Pipe) throws {
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(.EIO)
        }
    }

    private func finalize(_ record: ManagedProcessRecord) throws {
        record.box.terminateRemainingDescendants()
        record.finalizeCapture()
        defer { try? FileManager.default.removeItem(at: record.cwdStateURL) }
        guard let raw = Self.secureCWDState(at: record.cwdStateURL),
              !raw.isEmpty,
              let validated = try? validator.validate(cwd: raw),
              sandbox.containsWorkspacePath(validated)
        else { return }
        currentDirectory = validated
    }

    /// The sandboxed child can replace its cwd-state leaf. Read it through a
    /// no-follow, nonblocking descriptor and accept only a tiny regular file;
    /// this prevents a symlink/FIFO/device from turning the unsandboxed host
    /// into an arbitrary read, hang, or `/dev/zero` allocation.
    private static func secureCWDState(at url: URL) -> String? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= 16 * 1_024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            guard count > 0 else { return nil }
            offset += count
        }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func status(for record: ManagedProcessRecord) -> ManagedProcessStatus {
        let isRunning = record.box.process.isRunning
        return ManagedProcessStatus(
            id: record.id,
            command: record.command,
            cwd: validator.relativePath(for: record.launchCWD),
            processIdentifier: record.box.process.processIdentifier,
            state: isRunning ? .running : (record.wasStopped ? .stopped : .exited),
            exitCode: isRunning ? nil : record.box.process.terminationStatus,
            startedAt: record.startedAt,
            duration: record.startedClock.duration(to: .now).timeInterval
        )
    }

    private enum WaitRace: Equatable, Sendable { case exited, timedOut }

    private struct LiveProgressCursor: Sendable {
        var stdoutOffset: Int64 = 0
        var stderrOffset: Int64 = 0
        var stdoutEmittedBytes = 0
        var stderrEmittedBytes = 0
        var stdoutTruncationReported = false
        var stderrTruncationReported = false
    }

    private func waitForExitOrTimeout(
        _ record: ManagedProcessRecord,
        timeout: TimeInterval,
        progress: inout LiveProgressCursor,
        progressHandler: AgentToolProgressHandler?
    ) async -> WaitRace {
        let box = record.box
        return await withTaskCancellationHandler {
            let started = ContinuousClock.now
            var lastProgressAt = ContinuousClock.now
            while box.isRunning {
                if Task.isCancelled {
                    box.forceTerminate()
                    await waitForProcessState(box, maximum: 1)
                    return .exited
                }
                if started.duration(to: .now).timeInterval >= timeout {
                    box.terminate()
                    await waitForProcessState(box, maximum: 2)
                    if box.isRunning {
                        box.forceTerminate()
                        await waitForProcessState(box, maximum: 1)
                    }
                    return .timedOut
                }
                if let progressHandler,
                   lastProgressAt.duration(to: .now) >= .milliseconds(100) {
                    await publishLiveProgress(
                        record,
                        progress: &progress,
                        progressHandler: progressHandler
                    )
                    lastProgressAt = .now
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return .exited
        } onCancel: {
            // A cancelled Swift task must not wait for a child that traps TERM.
            // The command already received an explicit Stop, so terminate its
            // dedicated process group immediately and let the polling operation
            // observe Foundation's state transition.
            box.forceTerminate()
        }
    }

    private func publishLiveProgress(
        _ record: ManagedProcessRecord,
        progress: inout LiveProgressCursor,
        progressHandler: AgentToolProgressHandler
    ) async {
        await publishLiveProgress(
            spool: record.stdout,
            stream: .stdout,
            offset: &progress.stdoutOffset,
            emittedBytes: &progress.stdoutEmittedBytes,
            truncationReported: &progress.stdoutTruncationReported,
            progressHandler: progressHandler
        )
        await publishLiveProgress(
            spool: record.stderr,
            stream: .stderr,
            offset: &progress.stderrOffset,
            emittedBytes: &progress.stderrEmittedBytes,
            truncationReported: &progress.stderrTruncationReported,
            progressHandler: progressHandler
        )
    }

    private func publishLiveProgress(
        spool: OutputSpool,
        stream: AgentToolOutputStream,
        offset: inout Int64,
        emittedBytes: inout Int,
        truncationReported: inout Bool,
        progressHandler: AgentToolProgressHandler
    ) async {
        let remaining = Self.maximumLiveOutputBytesPerStream - emittedBytes
        if remaining <= 0 {
            guard !truncationReported else { return }
            truncationReported = true
            let total = spool.summary().byteCount
            await progressHandler(
                AgentToolProgress(
                    stream: stream,
                    delta: "",
                    totalBytes: total,
                    truncated: true
                )
            )
            return
        }
        guard let chunk = try? spool.read(
            offset: offset,
            maxBytes: min(Self.maximumLiveOutputDeltaBytes, remaining)
        ) else { return }
        let dataBytes = chunk.text.utf8.count
        let reachedLimit = emittedBytes + dataBytes >= Self.maximumLiveOutputBytesPerStream
            && (chunk.hasMore || chunk.totalBytes > emittedBytes + dataBytes)
        guard !chunk.text.isEmpty || (reachedLimit && !truncationReported) else { return }
        offset = chunk.nextOffset
        emittedBytes += dataBytes
        if reachedLimit { truncationReported = true }
        await progressHandler(
            AgentToolProgress(
                stream: stream,
                delta: chunk.text,
                totalBytes: chunk.totalBytes,
                truncated: reachedLimit
            )
        )
    }

    private func waitForExit(_ record: ManagedProcessRecord) async {
        await waitForProcessState(record.box, maximum: 2)
        if record.box.isRunning {
            record.box.forceTerminate()
            await waitForProcessState(record.box, maximum: 1)
        }
    }

    private func terminate(_ record: ManagedProcessRecord) async {
        let box = record.box
        box.terminate()
        await waitForProcessState(box, maximum: 2)
        if box.isRunning {
            box.forceTerminate()
            await waitForProcessState(box, maximum: 1)
        }
    }

    /// `Foundation.Process.waitUntilExit()` is a blocking run-loop wait. Putting
    /// it in a cancelled task-group can keep the group alive forever even after
    /// the child has been reaped. Polling `isRunning` keeps timeout and Stop
    /// paths cancellation-safe and bounded.
    private func waitForProcessState(_ box: ProcessBox, maximum: TimeInterval) async {
        let started = ContinuousClock.now
        while box.isRunning, started.duration(to: .now).timeInterval < maximum {
            if Task.isCancelled {
                _ = await Task.detached(priority: .utility) { usleep(10_000) }.value
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private static func wrappedCommand(_ command: String, cwdStateURL: URL) -> String {
        let statePath = shellQuote(cwdStateURL.path)
        return "\(command)\n__luma_status=$?\npwd -P > \(statePath)\nexit $__luma_status"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeEnvironment(_ values: [String: String]) -> [String: String] {
        let blocked = Set([
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD", "BASH_ENV", "ENV"
        ])
        return values.filter { key, value in
            !blocked.contains(key.uppercased()) && !key.contains("=") && !key.contains("\0")
                && !value.contains("\0")
        }
    }

    private static func secretValues(in environment: [String: String]) -> [String] {
        environment.compactMap { key, value in
            let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
            let isSensitive = normalized.contains("token")
                || normalized.contains("password")
                || normalized.contains("passwd")
                || normalized.contains("secret")
                || normalized.contains("api_key")
                || normalized.contains("access_key")
                || normalized.contains("authorization")
                || normalized.contains("credential")
                || normalized.contains("private_key")
                || normalized.contains("cookie")
            return isSensitive && value.utf8.count >= 4 ? value : nil
        }
    }

    private static func secretValues(inCommand command: String) -> [String] {
        let sensitiveName = "(?:api[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|password|passwd|secret|authorization|credential|private[_-]?key|client[_-]?secret|cookie)"
        let patterns = [
            "(?i)--?[A-Za-z0-9_.-]{0,128}\(sensitiveName)[A-Za-z0-9_.-]{0,128}\\s+(\\\"[^\\\"]{4,65536}\\\"|'[^']{4,65536}'|[^\\s\\\"'`;]{4,65536})",
            "(?i)\\b[A-Za-z0-9_.-]{0,128}\(sensitiveName)[A-Za-z0-9_.-]{0,128}\\s*[:=]\\s*(\\\"[^\\\"]{4,65536}\\\"|'[^']{4,65536}'|[^\\s\\\"',;]{4,65536})"
        ]
        var values: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
            for match in expression.matches(in: command, range: fullRange) where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: command) else { continue }
                let value = String(command[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value.utf8.count >= 4 { values.append(value) }
            }
        }
        return Array(Set(values))
    }

    private static func redactedCommand(
        _ command: String,
        configuredSecrets: [String]
    ) -> String {
        var result = command
        for secret in configuredSecrets.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return SecretRedactor().redact(result)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
