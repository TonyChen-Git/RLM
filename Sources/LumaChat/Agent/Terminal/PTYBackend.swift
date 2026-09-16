import Foundation

/// Platform-neutral transport consumed by TaskTerminalService. Implementations
/// own all OS-specific PTY handles, process-group behavior, readiness sources,
/// and cleanup. The UI, structured tools, and Task lifecycle never receive a
/// file descriptor or assume a Darwin process implementation.
protocol PTYSessionTransport: Actor {
    func start(
        command: String?,
        cwd: String?,
        environment: [String: String],
        shell: String,
        rows: Int,
        columns: Int,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool,
        allowsGitMetadataWrite: Bool
    ) throws -> PseudoTerminalStatus

    func status() throws -> PseudoTerminalStatus
    func readOutput(offset: Int64, maxBytes: Int) throws -> PseudoTerminalOutput
    func outputBounds() throws -> PseudoTerminalOutputBounds
    func outputEvents() throws -> AsyncStream<PseudoTerminalOutput>
    func write(_ data: Data) async throws -> PseudoTerminalWriteResult
    func resize(rows: Int, columns: Int) throws -> PseudoTerminalStatus
    func signal(_ signal: Int32) throws -> PseudoTerminalStatus
    func waitForExit() async throws -> PseudoTerminalStatus
    func stop() async throws -> PseudoTerminalStatus
    func dispose() async
}

/// Factory seam for local, remote, or future platform PTY implementations.
/// Backend choice is captured when a TaskTerminalService is created and cannot
/// be influenced by model-provided tool arguments.
protocol PTYBackend: Sendable {
    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport
}

/// Current macOS implementation. PseudoTerminalSession contains the Darwin C
/// bridge; no consumer above this factory imports or manipulates its handles.
struct DarwinPTYBackend: PTYBackend {
    private let sandboxBackend: any SandboxBackend

    init(sandboxBackend: any SandboxBackend = MacOSSandboxBackend()) {
        self.sandboxBackend = sandboxBackend
    }

    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        try PseudoTerminalSession(
            validator: validator,
            cwd: cwd,
            environment: environment,
            sandboxBackend: sandboxBackend
        )
    }
}

extension PseudoTerminalSession: PTYSessionTransport {}
