import Darwin
import Foundation

struct SSHCommandRequest: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String]
    var standardInput: Data?
    var timeout: TimeInterval
    var outputLimit: Int
    var allocatePTY: Bool
    var operationLabel: String
    var redactionSecrets: [String]

    init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval,
        outputLimit: Int,
        allocatePTY: Bool = false,
        operationLabel: String,
        redactionSecrets: [String] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.allocatePTY = allocatePTY
        self.operationLabel = operationLabel
        self.redactionSecrets = redactionSecrets
    }

    func validated() throws -> SSHCommandRequest {
        guard !executable.isEmpty, !executable.contains("\0"),
              executable.utf8.count <= RemoteRunnerLimits.maximumArgumentBytes,
              executable.hasPrefix("/") || Self.isSafeCommandName(executable) else {
            throw RemoteExecutionError.invalidRequest("Remote executable is invalid.")
        }
        guard arguments.count <= RemoteRunnerLimits.maximumTransportArguments,
              arguments.allSatisfy({
                  !$0.contains("\0")
                      && $0.utf8.count <= RemoteRunnerLimits.maximumArgumentBytes
              }) else {
            throw RemoteExecutionError.invalidRequest("Remote argv exceeds its bounds.")
        }
        let totalArgumentBytes = arguments.reduce(executable.utf8.count) {
            $0 + $1.utf8.count + 1
        }
        guard totalArgumentBytes <= RemoteRunnerLimits.maximumCommandBytes else {
            throw RemoteExecutionError.invalidRequest("Remote argv exceeds 512 KiB.")
        }
        if let workingDirectory {
            _ = try RemotePathPolicy.absoluteLocalFile(workingDirectory)
        }
        guard environment.count <= RemoteRunnerLimits.maximumEnvironmentEntries else {
            throw RemoteExecutionError.invalidRequest("Remote environment has too many entries.")
        }
        for (name, value) in environment {
            guard Self.isSafeEnvironmentName(name), !value.contains("\0"),
                  value.utf8.count <= RemoteRunnerLimits.maximumEnvironmentValueBytes else {
                throw RemoteExecutionError.invalidRequest("Remote environment is invalid.")
            }
        }
        guard (standardInput?.count ?? 0) <= RemoteRunnerLimits.maximumStandardInputBytes else {
            throw RemoteExecutionError.invalidRequest("Remote standard input exceeds 8 MiB.")
        }
        guard timeout.isFinite, (0.5...3_600).contains(timeout) else {
            throw RemoteExecutionError.invalidRequest("Remote timeout is outside 0.5...3600 seconds.")
        }
        guard (1...RemoteRunnerLimits.maximumOutputBytes).contains(outputLimit) else {
            throw RemoteExecutionError.invalidRequest("Remote output limit is invalid.")
        }
        guard !operationLabel.isEmpty, operationLabel.utf8.count <= 128,
              RemoteTextPolicy.isDisplayText(operationLabel) else {
            throw RemoteExecutionError.invalidRequest("Remote operation label is invalid.")
        }
        return self
    }

    private static func isSafeCommandName(_ value: String) -> Bool {
        guard !value.hasPrefix("-") else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 43 || $0 == 45
                || $0 == 46 || $0 == 95
        }
    }

    private static func isSafeEnvironmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first) || first == 95 else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 95
        }
    }
}

struct SSHCommandResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var startedAt: Date
    var completedAt: Date
    var timedOut: Bool
    var outputTruncated: Bool
}

protocol SSHCommandTransporting: Sendable {
    func run(
        configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData: Data?,
        request: SSHCommandRequest
    ) async throws -> SSHCommandResult
}

/// OpenSSH ultimately asks the remote login shell to parse one command string.
/// This encoder frames every argv/environment value as a POSIX single-quoted
/// token; no caller bytes are concatenated as executable shell syntax.
enum SSHRemoteCommandFramer {
    static func frame(_ rawRequest: SSHCommandRequest) throws -> String {
        let request = try rawRequest.validated()
        var command = ""
        if let directory = request.workingDirectory {
            command += "cd -- \(quote(directory)) && "
        }
        command += "exec "
        if !request.environment.isEmpty {
            command += "/usr/bin/env "
            for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
                command += quote("\(name)=\(value)") + " "
            }
        }
        command += quote(request.executable)
        for argument in request.arguments {
            command += " " + quote(argument)
        }
        guard command.utf8.count <= RemoteRunnerLimits.maximumCommandBytes else {
            throw RemoteExecutionError.invalidRequest("Framed remote command exceeds 512 KiB.")
        }
        return command
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SSHInvocation: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
}

enum SSHInvocationBuilder {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh", isDirectory: false)

    static func invocation(
        configuration rawConfiguration: RemoteRunnerConfiguration,
        request rawRequest: SSHCommandRequest,
        knownHostsFile: URL,
        identityFile: URL?
    ) throws -> SSHInvocation {
        let configuration = try rawConfiguration.validated()
        let request = try rawRequest.validated()
        let remoteCommand = try SSHRemoteCommandFramer.frame(request)
        var arguments = [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "CheckHostIP=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=\(Int(configuration.connectTimeout.rounded(.up)))",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR"
        ]
        if let identityFile {
            arguments += [
                "-o", "IdentitiesOnly=yes",
                "-o", "IdentityAgent=none",
                "-i", identityFile.path
            ]
        }
        arguments += request.allocatePTY ? ["-tt"] : ["-T"]
        arguments += [
            "-p", String(configuration.port),
            "-l", configuration.username,
            "--", configuration.host,
            remoteCommand
        ]

        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8"
        ]
        if configuration.authentication == .systemAgent,
           let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           !socket.isEmpty, !socket.contains("\0") {
            environment["SSH_AUTH_SOCK"] = socket
        }
        return SSHInvocation(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
    }
}

struct ProcessSSHCommandTransport: SSHCommandTransporting, Sendable {
    func run(
        configuration rawConfiguration: RemoteRunnerConfiguration,
        credential rawCredential: RemoteRunnerCredential?,
        knownHostsData: Data?,
        request rawRequest: SSHCommandRequest
    ) async throws -> SSHCommandResult {
        let configuration = try rawConfiguration.validated()
        guard configuration.enabled else {
            throw RemoteExecutionError.runnerDisabled(configuration.id)
        }
        let request = try rawRequest.validated()
        let credential: RemoteRunnerCredential?
        switch configuration.authentication {
        case .systemAgent:
            credential = nil
        case .keychainPrivateKey:
            guard let rawCredential else {
                throw RemoteExecutionError.credentialUnavailable(configuration.id)
            }
            credential = try rawCredential.validated()
        }

        let material = try SSHLaunchMaterialLease.create(
            configuration: configuration,
            credential: credential,
            knownHostsData: knownHostsData
        )
        defer { material.dispose() }
        let invocation = try SSHInvocationBuilder.invocation(
            configuration: configuration,
            request: request,
            knownHostsFile: material.knownHostsFile,
            identityFile: material.identityFile
        )
        guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw RemoteExecutionError.launchFailed("The system SSH executable is unavailable.")
        }

        let stdout = SSHOutputCapture(limit: request.outputLimit)
        let stderr = SSHOutputCapture(limit: request.outputLimit)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.consume(handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.consume(handle)
        }

        let inputPipe = request.standardInput.map { _ in Pipe() }
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let controller = SSHProcessController(process)
        let startedAt = Date()
        let startedClock = ContinuousClock.now
        var operationError: Error?
        var didLaunch = false
        var timedOut = false

        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                do {
                    try process.run()
                    didLaunch = true
                    controller.didLaunch()
                } catch {
                    throw RemoteExecutionError.launchFailed(
                        RemoteTextPolicy.safeDiagnostic(error.localizedDescription)
                    )
                }
                if let inputPipe, let input = request.standardInput {
                    try? inputPipe.fileHandleForReading.close()
                    try Self.setNonblocking(inputPipe.fileHandleForWriting.fileDescriptor)
                    try await Self.write(
                        input,
                        to: inputPipe.fileHandleForWriting.fileDescriptor,
                        process: process,
                        timeout: request.timeout,
                        started: startedClock
                    )
                    try? inputPipe.fileHandleForWriting.close()
                }
                while process.isRunning {
                    try Task.checkCancellation()
                    if startedClock.duration(to: .now).timeInterval >= request.timeout {
                        timedOut = true
                        throw RemoteExecutionError.timedOut(request.timeout)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } onCancel: {
                controller.cancel()
            }
        } catch {
            operationError = error
        }

        if operationError != nil, didLaunch, process.isRunning {
            await controller.stop()
        }
        try? inputPipe?.fileHandleForWriting.close()
        if didLaunch, process.isRunning {
            await controller.stop()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdout.finish(stdoutPipe.fileHandleForReading)
        stderr.finish(stderrPipe.fileHandleForReading)
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        if let operationError {
            if operationError is CancellationError { throw CancellationError() }
            throw operationError
        }

        let secrets = request.redactionSecrets
            + Array(request.environment.values)
            + (credential.map { [$0.privateKey] } ?? [])
        let redactor = RemoteSecretRedactor(secrets: secrets)
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        let stdoutText = redactor.redact(String(decoding: stdoutSnapshot.data, as: UTF8.self))
        let stderrText = redactor.redact(String(decoding: stderrSnapshot.data, as: UTF8.self))
        let exitCode = process.terminationStatus
        if exitCode == 255 {
            if Self.isHostVerificationFailure(stderrText) {
                throw RemoteExecutionError.hostVerificationFailed
            }
            throw RemoteExecutionError.connectionFailed(
                RemoteTextPolicy.safeDiagnostic(stderrText)
            )
        }
        return SSHCommandResult(
            stdout: stdoutText,
            stderr: stderrText,
            exitCode: exitCode,
            startedAt: startedAt,
            completedAt: Date(),
            timedOut: timedOut,
            outputTruncated: stdoutSnapshot.truncated || stderrSnapshot.truncated
        )
    }

    private static func setNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw RemoteExecutionError.launchFailed("Unable to configure SSH standard input.")
        }
    }

    private static func write(
        _ data: Data,
        to descriptor: Int32,
        process: Process,
        timeout: TimeInterval,
        started: ContinuousClock.Instant
    ) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard process.isRunning else { return }
            guard started.duration(to: .now).timeInterval < timeout else {
                throw RemoteExecutionError.timedOut(timeout)
            }
            let count: Int = data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(5))
            } else if count == -1, errno == EPIPE || errno == EBADF {
                return
            } else {
                throw RemoteExecutionError.connectionFailed(
                    "Unable to stream bounded standard input to SSH."
                )
            }
        }
    }

    private static func isHostVerificationFailure(_ stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("host key verification failed")
            || normalized.contains("remote host identification has changed")
            || normalized.contains("no matching host key")
            || normalized.contains("no ed25519 host key is known")
    }
}

private final class SSHProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var launched = false
    private var cancellationRequested = false

    init(_ process: Process) {
        self.process = process
    }

    func didLaunch() {
        lock.lock()
        launched = true
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { signal(SIGTERM) }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldSignal = launched
        lock.unlock()
        if shouldSignal { signal(SIGTERM) }
    }

    func stop() async {
        signal(SIGTERM)
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { signal(SIGKILL) }
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func signal(_ signalNumber: Int32) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        Darwin.kill(pid, signalNumber)
    }
}

private final class SSHOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var retained = Data()
    private var totalBytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ handle: FileHandle) {
        lock.lock()
        appendLocked(handle.availableData)
        lock.unlock()
    }

    func finish(_ handle: FileHandle) {
        lock.lock()
        appendLocked(handle.readDataToEndOfFile())
        lock.unlock()
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (retained, totalBytes > retained.count)
    }

    private func appendLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count
        let remaining = max(0, limit - retained.count)
        if remaining > 0 { retained.append(data.prefix(remaining)) }
    }
}

/// Holds only per-launch copies. Cleanup names each file literally and uses
/// rmdir on the unique directory; it never recursively removes `._*` entries.
final class SSHLaunchMaterialLease: @unchecked Sendable {
    let directory: URL
    let knownHostsFile: URL
    let identityFile: URL?
    private let lock = NSLock()
    private var disposed = false

    private init(directory: URL, knownHostsFile: URL, identityFile: URL?) {
        self.directory = directory
        self.knownHostsFile = knownHostsFile
        self.identityFile = identityFile
    }

    deinit { dispose() }

    static func create(
        configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData suppliedKnownHostsData: Data?
    ) throws -> SSHLaunchMaterialLease {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("remote-runners", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try requireDirectory(root)
        let directory = root.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        guard Darwin.mkdir(directory.path, S_IRWXU) == 0 else {
            throw RemoteExecutionError.launchFailed("Unable to create SSH launch storage.")
        }

        let knownHosts = directory.appendingPathComponent("known_hosts", isDirectory: false)
        let identity = credential.map { _ in
            directory.appendingPathComponent("identity", isDirectory: false)
        }
        let lease = SSHLaunchMaterialLease(
            directory: directory,
            knownHostsFile: knownHosts,
            identityFile: identity
        )
        do {
            let knownHostsData = try suppliedKnownHostsData
                ?? captureKnownHostsData(configuration: configuration)
            guard !knownHostsData.isEmpty,
                  knownHostsData.count <= RemoteRunnerLimits.maximumKnownHostsBytes else {
                throw RemoteExecutionError.hostVerificationFailed
            }
            try writeExclusive(knownHostsData, to: knownHosts)
            if let credential, let identity {
                try writeExclusive(Data(credential.privateKey.utf8), to: identity)
            }
            return lease
        } catch {
            lease.dispose()
            throw error
        }
    }

    /// Captures the exact host-key authority used to mint a run identity.
    /// Production backends retain these bytes in memory, so replacing the
    /// configured file cannot silently change trust after an approval.
    static func captureKnownHostsData(
        configuration: RemoteRunnerConfiguration
    ) throws -> Data {
        let data = try readRegularFile(
            URL(fileURLWithPath: configuration.knownHostsFile, isDirectory: false),
            maximumBytes: RemoteRunnerLimits.maximumKnownHostsBytes
        )
        guard !data.isEmpty else {
            throw RemoteExecutionError.hostVerificationFailed
        }
        return data
    }

    func dispose() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        disposed = true
        lock.unlock()
        if let identityFile { _ = Darwin.unlink(identityFile.path) }
        _ = Darwin.unlink(knownHostsFile.path)
        _ = Darwin.rmdir(directory.path)
    }

    private static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw RemoteExecutionError.launchFailed(
                "SSH launch storage is not a real directory."
            )
        }
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw RemoteExecutionError.hostVerificationFailed }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else {
            throw RemoteExecutionError.hostVerificationFailed
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= maximumBytes else {
                    throw RemoteExecutionError.hostVerificationFailed
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino,
                      before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                      before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                      data.count == Int(after.st_size) else {
                    throw RemoteExecutionError.hostVerificationFailed
                }
                return data
            } else if errno != EINTR {
                throw RemoteExecutionError.hostVerificationFailed
            }
        }
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RemoteExecutionError.launchFailed("Unable to create SSH launch material.")
        }
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < data.count {
            let count: Int = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw RemoteExecutionError.launchFailed("Unable to write SSH launch material.")
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RemoteExecutionError.launchFailed("Unable to secure SSH launch material.")
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
