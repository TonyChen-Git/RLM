import Foundation
import Darwin

actor MCPStdioTransport: MCPTransport {
    private let serverID: UUID
    private let configuration: MCPStdioConfiguration
    private let allowsNetwork: Bool
    private let sandboxBackend: any SandboxBackend
    private var process: Process?
    private var standardInput: Pipe?
    private var inputWriter: MCPStdioAsyncWriter?
    private var standardOutput: Pipe?
    private var standardError: Pipe?
    private var stdoutPump: MCPStdioReadPump?
    private var stderrPump: MCPStdioReadPump?
    private var stdoutConsumer: Task<Void, Never>?
    private var stderrConsumer: Task<Void, Never>?
    private var framer = MCPNewlineFramer()
    private var pending: [MCPJSONRPCID: PendingRequest] = [:]
    private var artifactLog: MCPTransportArtifactLog?
    private var running = false
    private var ownsDedicatedProcessGroup = false
    private var processEnvironmentRoot: URL?
    private var sandboxRuntimeRoot: URL?

    init(
        serverID: UUID,
        configuration: MCPStdioConfiguration,
        allowsNetwork: Bool,
        sandboxBackend: any SandboxBackend = MacOSSandboxBackend()
    ) {
        self.serverID = serverID
        self.configuration = configuration
        self.allowsNetwork = allowsNetwork
        self.sandboxBackend = sandboxBackend
    }

    func start() async throws {
        guard !running else { throw MCPError.alreadyRunning }
        guard !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidConfiguration("STDIO command is empty.")
        }

        let runtime = try MCPProcessEnvironment(
            serverID: serverID,
            configured: configuration.environment
        )
        var retainTemporaryRoots = false
        defer {
            if !retainTemporaryRoots {
                try? FileManager.default.removeItem(at: runtime.root)
            }
        }
        try MCPStdioPolicy.validate(configuration)
        let workingDirectory = configuration.workingDirectory
            .flatMap { raw -> URL? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            } ?? runtime.root
        let sandbox: any AgentSandboxPolicy
        let hasConfiguredWorkingDirectory = configuration.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false
        if !hasConfiguredWorkingDirectory {
            sandbox = try sandboxBackend.makeMCPPolicy(trustedRuntimeRoot: runtime.root)
        } else {
            let workspace = AgentWorkspace(
                name: "MCP \(serverID.uuidString.lowercased())",
                rootPath: workingDirectory.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            )
            sandbox = try sandboxBackend.makeWorkspacePolicy(
                validator: WorkspaceSecurityValidator(workspace: workspace),
                additionalReadOnlyRoots: []
            )
        }
        var retainSandboxRuntime = false
        defer {
            if !retainSandboxRuntime {
                try? FileManager.default.removeItem(at: sandbox.runtimeEnvironment.root)
            }
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        let outputPump = MCPStdioReadPump()
        let errorPump = MCPStdioReadPump()
        let log = try MCPTransportArtifactLog(
            serverID: serverID,
            configuredSecrets: Array(configuration.environment.values)
                + Self.sensitiveArgumentValues(configuration.arguments)
        )
        let invocation = ([configuration.command] + configuration.arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        process.executableURL = sandbox.launcherExecutable
        process.arguments = sandbox.launcherArguments(
            command: "exec \(invocation)",
            shell: "/bin/zsh",
            allowsNetwork: allowsNetwork
        )
        process.environment = sandbox.environment(session: runtime.values, command: [:])
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe

        output.fileHandleForReading.readabilityHandler = { [weak self, outputPump] handle in
            guard outputPump.receive(from: handle) else {
                Task { await self?.streamBufferOverflow(stream: "stdout") }
                return
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self, errorPump] handle in
            guard errorPump.receive(from: handle) else {
                Task { await self?.streamBufferOverflow(stream: "stderr") }
                return
            }
        }
        process.terminationHandler = { [weak self] terminated in
            Task { await self?.processDidTerminate(status: terminated.terminationStatus) }
        }

        do {
            try process.run()
            confirmDedicatedProcessGroup(process)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputPump.finishAndWait()
            errorPump.finishAndWait()
            log.close()
            throw MCPError.transport("Unable to start the configured STDIO process: \(error.localizedDescription)")
        }

        self.process = process
        standardInput = input
        inputWriter = MCPStdioAsyncWriter(handle: input.fileHandleForWriting)
        standardOutput = output
        standardError = errorPipe
        stdoutPump = outputPump
        stderrPump = errorPump
        artifactLog = log
        processEnvironmentRoot = runtime.root
        sandboxRuntimeRoot = sandbox.runtimeEnvironment.root
        running = true
        stdoutConsumer = Task { [weak self, outputPump] in
            for await data in outputPump.stream {
                guard let self else { return }
                await self.consumeStandardOutput(data)
            }
        }
        stderrConsumer = Task { [weak self, errorPump] in
            for await data in errorPump.stream {
                guard let self else { return }
                await self.consumeStandardError(data)
            }
        }
        retainTemporaryRoots = true
        retainSandboxRuntime = true
    }

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse? {
        try Task.checkCancellation()
        guard running, process?.isRunning == true, let writer = inputWriter else {
            throw MCPError.notConnected
        }

        var encoded = try MCPWireCodec.encode(request)
        encoded.append(0x0A)
        guard let id = request.id else {
            do {
                try await writer.write(encoded)
                return nil
            } catch {
                throw MCPError.transport("Unable to write to MCP STDIO: \(error.localizedDescription)")
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let holder = PendingRequest(continuation: continuation)
                guard pending[id] == nil else {
                    holder.resume(
                        throwing: MCPError.transport("Duplicate JSON-RPC request id.")
                    )
                    return
                }
                pending[id] = holder
                Task { [weak self, writer, encoded] in
                    do {
                        try await writer.write(encoded)
                    } catch {
                        await self?.writeFailed(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelRequest(id) }
        }
    }

    func stop() async {
        guard running || process != nil else { return }
        running = false
        inputWriter?.close()
        if managedProcessTreeIsAlive {
            signalProcess(SIGTERM)
            await waitForProcessTreeExit(maximum: 2)
            if managedProcessTreeIsAlive {
                signalProcess(SIGKILL)
                await waitForProcessTreeExit(maximum: 1)
            }
        }
        process?.terminationHandler = nil
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        stdoutPump?.finishAndWait()
        stderrPump?.finishAndWait()
        await stdoutConsumer?.value
        await stderrConsumer?.value
        process = nil
        standardInput = nil
        inputWriter = nil
        standardOutput = nil
        standardError = nil
        stdoutPump = nil
        stderrPump = nil
        stdoutConsumer = nil
        stderrConsumer = nil
        failPending(with: MCPError.notConnected)
        artifactLog?.close()
        artifactLog = nil
        framer = MCPNewlineFramer()
        ownsDedicatedProcessGroup = false
        removeTemporaryRoots()
    }

    private func consumeStandardOutput(_ data: Data) {
        do {
            for frame in try framer.append(data) {
                var loggedFrame = frame
                loggedFrame.append(0x0A)
                artifactLog?.appendSanitized(loggedFrame, stream: .stdout)
                guard let response = try? MCPWireCodec.decode(MCPJSONRPCResponse.self, from: frame),
                      response.result != nil || response.error != nil,
                      let id = response.id,
                      let request = pending.removeValue(forKey: id) else { continue }
                request.resume(returning: response)
            }
        } catch {
            running = false
            failPending(with: error)
            signalProcess(SIGKILL)
            Task { await self.stop() }
        }
    }

    private func consumeStandardError(_ data: Data) {
        artifactLog?.appendSanitized(data, stream: .stderr)
    }

    private func streamBufferOverflow(stream: String) {
        guard running else { return }
        running = false
        let error = MCPError.transport(
            "MCP \(stream) exceeded its bounded in-memory stream queue."
        )
        failPending(with: error)
        inputWriter?.close()
        signalProcess(SIGKILL)
        Task { await self.stop() }
    }

    private func cancelRequest(_ id: MCPJSONRPCID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.resume(throwing: CancellationError())
        // If a server stopped reading stdin, even a cancellation notification
        // can block behind the original frame. Closing the writer and killing
        // the dedicated group makes timeout/Stop fail closed and bounded.
        inputWriter?.close()
        signalProcess(SIGKILL)
        running = false
        failPending(with: CancellationError())
        Task { await self.stop() }
    }

    private func writeFailed(id: MCPJSONRPCID, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.resume(
            throwing: MCPError.transport("Unable to write to MCP STDIO: \(error.localizedDescription)")
        )
        inputWriter?.close()
        signalProcess(SIGKILL)
        running = false
        failPending(with: MCPError.notConnected)
        Task { await self.stop() }
    }

    private func processDidTerminate(status: Int32) {
        guard running else { return }
        running = false
        // A server may fork a background child and let its leader exit. The
        // launcher-created group remains addressable by the original PID, so
        // tear it down immediately instead of waiting for app termination.
        if managedProcessTreeIsAlive { signalProcess(SIGKILL) }
        inputWriter?.close()
        failPending(with: MCPError.transport("STDIO server exited with status \(status)."))
        Task { await self.stop() }
    }

    private func failPending(with error: Error) {
        let holders = pending.values
        pending.removeAll()
        for request in holders { request.resume(throwing: error) }
    }

    private func confirmDedicatedProcessGroup(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        for _ in 0..<50 {
            if Darwin.getpgid(pid) == pid || Darwin.kill(-pid, 0) == 0 {
                ownsDedicatedProcessGroup = true
                return
            }
            if !process.isRunning {
                if Darwin.kill(-pid, 0) == 0 { ownsDedicatedProcessGroup = true }
                return
            }
            usleep(1_000)
        }
    }

    private func signalProcess(_ signal: Int32) {
        guard let process, process.processIdentifier > 0 else { return }
        let pid = process.processIdentifier
        if ownsDedicatedProcessGroup {
            Darwin.kill(-pid, signal)
        } else {
            Darwin.kill(pid, signal)
        }
    }

    private var managedProcessTreeIsAlive: Bool {
        guard let process, process.processIdentifier > 0 else { return false }
        if ownsDedicatedProcessGroup {
            return Darwin.kill(-process.processIdentifier, 0) == 0 || errno == EPERM
        }
        return process.isRunning
    }

    private func waitForProcessTreeExit(maximum: TimeInterval) async {
        let deadline = Date().addingTimeInterval(maximum)
        while managedProcessTreeIsAlive, Date() < deadline {
            if Task.isCancelled {
                _ = await Task.detached(priority: .utility) { usleep(10_000) }.value
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func removeTemporaryRoots() {
        let allowedParent = AppPaths.projectTemporaryRoot.standardizedFileURL
        for root in [processEnvironmentRoot, sandboxRuntimeRoot].compactMap({ $0 }) {
            let candidate = root.standardizedFileURL
            if candidate.path.hasPrefix(allowedParent.path + "/") {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        processEnvironmentRoot = nil
        sandboxRuntimeRoot = nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sensitiveArgumentValues(_ arguments: [String]) -> [String] {
        var values: [String] = []
        var nextIsSensitive = false
        for argument in arguments {
            if nextIsSensitive {
                values.append(argument)
                nextIsSensitive = false
                continue
            }
            let normalized = argument
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let sensitive = ["key", "token", "password", "secret", "authorization", "credential"]
                .contains(where: normalized.contains)
            if sensitive, let separator = argument.firstIndex(of: "=") {
                values.append(String(argument[argument.index(after: separator)...]))
            } else if sensitive {
                nextIsSensitive = true
            } else if SecretRedactor().redact(argument) != argument {
                values.append(argument)
            }
        }
        return values.filter { !$0.isEmpty }
    }
}

/// MCP servers are extension processes, so they receive an isolated home and
/// cache tree instead of inheriting the app's credentials and system temp path.
private struct MCPProcessEnvironment {
    let root: URL
    let values: [String: String]

    init(serverID: UUID, configured: [String: String]) throws {
        let runtimeParent = AppPaths.projectTemporaryRoot
            .appendingPathComponent("mcp-runtime", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: runtimeParent, withIntermediateDirectories: true)
        let parentValues = try runtimeParent.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true,
              runtimeParent.resolvingSymlinksInPath().path == runtimeParent.path else {
            throw MCPError.invalidConfiguration("MCP runtime parent is not a trusted project tmp directory.")
        }
        root = runtimeParent.appendingPathComponent(
            "\(serverID.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let cargo = root.appendingPathComponent("cargo", isDirectory: true)
        let cargoTarget = root.appendingPathComponent("cargo-target", isDirectory: true)
        let rustup = root.appendingPathComponent("rustup", isDirectory: true)
        let swift = cache.appendingPathComponent("swift", isDirectory: true)
        let clang = cache.appendingPathComponent("clang", isDirectory: true)
        let gradle = cache.appendingPathComponent("gradle", isDirectory: true)
        let goCache = cache.appendingPathComponent("go", isDirectory: true)
        let goModules = cache.appendingPathComponent("gomod", isDirectory: true)
        let goPath = root.appendingPathComponent("go", isDirectory: true)
        for directory in [
            root, home, temporary, cache, config, data, state, cargo, cargoTarget,
            rustup, swift, clang, gradle, goCache, goModules, goPath
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let host = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": host["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": host["LANG"] ?? "en_US.UTF-8",
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "TMP": temporary.path,
            "TEMP": temporary.path,
            "XDG_CACHE_HOME": cache.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_DATA_HOME": data.path,
            "XDG_STATE_HOME": state.path,
            "SWIFTPM_MODULECACHE_OVERRIDE": swift.path,
            "CLANG_MODULE_CACHE_PATH": clang.path,
            "SWIFTPM_CACHE_PATH": cache.appendingPathComponent("swiftpm", isDirectory: true).path,
            "npm_config_cache": cache.appendingPathComponent("npm", isDirectory: true).path,
            "YARN_CACHE_FOLDER": cache.appendingPathComponent("yarn", isDirectory: true).path,
            "PIP_CACHE_DIR": cache.appendingPathComponent("pip", isDirectory: true).path,
            "UV_CACHE_DIR": cache.appendingPathComponent("uv", isDirectory: true).path,
            "CARGO_HOME": cargo.path,
            "CARGO_TARGET_DIR": cargoTarget.path,
            "RUSTUP_HOME": rustup.path,
            "GOCACHE": goCache.path,
            "GOMODCACHE": goModules.path,
            "GOPATH": goPath.path,
            "GRADLE_USER_HOME": gradle.path,
            "NUGET_PACKAGES": cache.appendingPathComponent("nuget", isDirectory: true).path,
            "GIT_CONFIG_GLOBAL": "/dev/null"
        ]
        let protectedKeys = Set([
            "HOME", "CFFIXED_USER_HOME", "TMPDIR", "TMP", "TEMP",
            "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
            "SWIFTPM_MODULECACHE_OVERRIDE", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_CACHE_PATH",
            "NPM_CONFIG_CACHE", "YARN_CACHE_FOLDER", "PIP_CACHE_DIR", "UV_CACHE_DIR",
            "CARGO_HOME", "CARGO_TARGET_DIR", "RUSTUP_HOME", "GOCACHE", "GOMODCACHE",
            "GOPATH", "GRADLE_USER_HOME", "NUGET_PACKAGES", "GIT_CONFIG_GLOBAL",
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD", "BASH_ENV", "ENV"
        ])
        for (key, value) in configured where !protectedKeys.contains(key.uppercased())
            && !key.contains("=") && !key.contains("\0") && !value.contains("\0") {
            environment[key] = value
        }
        values = environment
    }
}

private enum MCPArtifactStream {
    case stdout
    case stderr
}

/// FileHandle can invoke readability callbacks on arbitrary queues. Feeding a
/// bounded AsyncStream preserves byte-chunk order for JSON framing and gives
/// Stop a join point for callbacks that were already in flight.
private final class MCPStdioReadPump: @unchecked Sendable {
    let stream: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let condition = NSCondition()
    private var activeCallbacks = 0
    private var closed = false

    init() {
        let pair = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Returns false when the bounded queue dropped a chunk. A dropped JSON
    /// byte would corrupt framing, so the transport must fail closed.
    func receive(from handle: FileHandle) -> Bool {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return true
        }
        activeCallbacks += 1
        condition.unlock()

        let data = handle.availableData
        let accepted: Bool
        if data.isEmpty {
            accepted = true
        } else {
            switch continuation.yield(data) {
            case .enqueued:
                accepted = true
            case .dropped:
                accepted = false
            case .terminated:
                accepted = true
            @unknown default:
                accepted = false
            }
        }

        condition.lock()
        activeCallbacks -= 1
        if data.isEmpty { closed = true }
        if activeCallbacks == 0 { condition.broadcast() }
        condition.unlock()
        if data.isEmpty { continuation.finish() }
        return accepted
    }

    func finishAndWait() {
        condition.lock()
        closed = true
        while activeCallbacks > 0 { condition.wait() }
        condition.unlock()
        continuation.finish()
    }
}

/// Holds a checked continuation so it can be stored in an actor-isolated
/// dictionary and resumed from Sendable closures without exposing the
/// continuation as a sending capture.
private final class PendingRequest: @unchecked Sendable {
    private var continuation: CheckedContinuation<MCPJSONRPCResponse?, Error>?
    private var resumed = false
    private let lock = NSLock()

    init(continuation: CheckedContinuation<MCPJSONRPCResponse?, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: MCPJSONRPCResponse?) {
        lock.lock()
        guard !resumed, let continuation = continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !resumed, let continuation = continuation else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

/// Serializes potentially large JSON-RPC writes away from the transport actor.
/// `close()` is deliberately synchronous and thread-safe so Stop/cancellation
/// can interrupt a pipe whose server no longer reads stdin.
private final class MCPStdioAsyncWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.lumachat.mcp-stdio-writer")
    private let lock = NSLock()
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) async throws {
        guard data.count <= 16 * 1_024 * 1_024 + 1 else {
            throw MCPError.invalidConfiguration("STDIO request exceeds the 16 MiB limit.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock()
                let isClosed = closed
                lock.unlock()
                guard !isClosed else {
                    continuation.resume(throwing: MCPError.notConnected)
                    return
                }
                do {
                    try handle.write(contentsOf: data)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        try? handle.close()
    }
}

/// Locks are confined to this artifact sink because Foundation invokes pipe
/// handlers from arbitrary queues. Both files are rooted below project `tmp/`.
private final class MCPTransportArtifactLog: @unchecked Sendable {
    private let lock = NSLock()
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let configuredSecrets: [String]
    private var stderrBuffer = Data()
    private var isClosed = false
    private let maximumBytesPerStream = 64 * 1_024 * 1_024
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var stderrInsidePrivateKey = false

    init(serverID: UUID, configuredSecrets: [String]) throws {
        try AppPaths.ensureAgentDirectories()
        let directory = AppPaths.agentArtifacts.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "\(serverID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let stdoutURL = directory.appendingPathComponent("\(stem)-stdout.jsonl")
        let stderrURL = directory.appendingPathComponent("\(stem)-stderr.log")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw MCPError.transport("Unable to create repository-local MCP output artifacts.")
        }
        stdout = try FileHandle(forWritingTo: stdoutURL)
        stderr = try FileHandle(forWritingTo: stderrURL)
        var expandedSecrets: [String] = []
        for secret in configuredSecrets {
            expandedSecrets.append(secret)
            expandedSecrets.append(contentsOf: secret.split(whereSeparator: \Character.isNewline).map(String.init))
        }
        let minSecretBytes = 4
        let maxSecretBytes = 64 * 1_024
        let filteredSecrets = expandedSecrets.filter { $0.utf8.count >= minSecretBytes && $0.utf8.count <= maxSecretBytes }
        self.configuredSecrets = Array(Set(filteredSecrets))
        .sorted { $0.utf8.count > $1.utf8.count }
    }

    func appendSanitized(_ data: Data, stream: MCPArtifactStream) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        switch stream {
        case .stdout:
            writeBounded(
                sanitized(data),
                to: stdout,
                count: &stdoutBytes,
                didTruncate: &stdoutTruncated
            )
        case .stderr:
            stderrBuffer.append(data)
            flushCompleteStderrLines()
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if !stderrBuffer.isEmpty {
            writeBounded(
                sanitizedStderr(stderrBuffer),
                to: stderr,
                count: &stderrBytes,
                didTruncate: &stderrTruncated
            )
            stderrBuffer.removeAll()
        }
        try? stdout.close()
        try? stderr.close()
    }

    private func flushCompleteStderrLines() {
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let line = Data(stderrBuffer[...newline])
            stderrBuffer.removeSubrange(...newline)
            writeBounded(
                sanitizedStderr(line),
                to: stderr,
                count: &stderrBytes,
                didTruncate: &stderrTruncated
            )
        }

        // Avoid unbounded buffering for a server that never emits newlines. A
        // generous overlap prevents configured secrets from being split across
        // the sanitization boundary.
        let overlap = max(4_096, configuredSecrets.map { $0.utf8.count }.max() ?? 0)
        if stderrBuffer.count > 1_048_576 + overlap {
            let flushCount = stderrBuffer.count - overlap
            let prefix = Data(stderrBuffer.prefix(flushCount))
            stderrBuffer.removeFirst(flushCount)
            writeBounded(
                sanitizedStderr(prefix),
                to: stderr,
                count: &stderrBytes,
                didTruncate: &stderrTruncated
            )
        }
    }

    private func sanitized(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for secret in configuredSecrets {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return Data(SecretRedactor().redact(text).utf8)
    }

    private func sanitizedStderr(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let uppercase = text.uppercased()
        if stderrInsidePrivateKey {
            if uppercase.contains("-----END ") && uppercase.contains("PRIVATE KEY-----") {
                stderrInsidePrivateKey = false
            }
            return Data()
        }
        if uppercase.contains("-----BEGIN ") && uppercase.contains("PRIVATE KEY-----") {
            stderrInsidePrivateKey = !(
                uppercase.contains("-----END ") && uppercase.contains("PRIVATE KEY-----")
            )
            return Data("[REDACTED PRIVATE KEY]\n".utf8)
        }
        return sanitized(data)
    }

    private func writeBounded(
        _ data: Data,
        to handle: FileHandle,
        count: inout Int,
        didTruncate: inout Bool
    ) {
        guard !didTruncate else { return }
        let remaining = maximumBytesPerStream - count
        if remaining > 0 {
            let prefix = data.prefix(remaining)
            try? handle.write(contentsOf: prefix)
            count += prefix.count
        }
        guard data.count > remaining else { return }
        didTruncate = true
        let marker = Data("\n[MCP artifact truncated at 64 MiB]\n".utf8)
        try? handle.write(contentsOf: marker)
    }

    deinit { close() }
}
