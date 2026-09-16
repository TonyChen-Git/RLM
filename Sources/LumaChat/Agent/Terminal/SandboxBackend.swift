import Foundation

/// Platform-neutral command confinement contract. Callers receive only launch
/// material and scoped environment; they do not know whether the host uses
/// Seatbelt, namespaces/seccomp, an AppContainer, or another future backend.
protocol AgentSandboxPolicy: Sendable {
    var runtimeEnvironment: AgentExecutionEnvironment { get }
    var launcherExecutable: URL { get }
    var pseudoTerminalLauncherExecutable: URL { get }

    func containsWorkspacePath(_ url: URL) -> Bool
    func launcherArguments(
        command: String,
        shell: String,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool,
        allowsGitMetadataWrite: Bool,
        allowsWorkspaceWrite: Bool
    ) -> [String]
    func launcherArguments(
        executable: URL,
        arguments: [String],
        allowsNetwork: Bool,
        allowsWorkspaceWrite: Bool
    ) -> [String]
    func pseudoTerminalLauncherArguments(
        command: String,
        shell: String,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool,
        allowsGitMetadataWrite: Bool,
        allowsWorkspaceWrite: Bool
    ) -> [String]
    func environment(session: [String: String], command: [String: String]) -> [String: String]
}

protocol SandboxBackend: Sendable {
    var identifier: String { get }
    func makeWorkspacePolicy(
        validator: WorkspaceSecurityValidator,
        additionalReadOnlyRoots: [URL]
    ) throws -> any AgentSandboxPolicy
    func makeMCPPolicy(trustedRuntimeRoot: URL) throws -> any AgentSandboxPolicy
    func makeExtensionPolicy(
        trustedRuntimeRoot: URL,
        pluginReadOnlyRoot: URL
    ) throws -> any AgentSandboxPolicy
}

struct MacOSSandboxBackend: SandboxBackend {
    let identifier = "macos-seatbelt"

    func makeWorkspacePolicy(
        validator: WorkspaceSecurityValidator,
        additionalReadOnlyRoots: [URL] = []
    ) throws -> any AgentSandboxPolicy {
        try TerminalSandbox(
            validator: validator,
            additionalReadOnlyRoots: additionalReadOnlyRoots
        )
    }

    func makeMCPPolicy(trustedRuntimeRoot: URL) throws -> any AgentSandboxPolicy {
        try TerminalSandbox(trustedMCPRuntimeRoot: trustedRuntimeRoot)
    }

    func makeExtensionPolicy(
        trustedRuntimeRoot: URL,
        pluginReadOnlyRoot: URL
    ) throws -> any AgentSandboxPolicy {
        try TerminalSandbox(
            trustedExtensionRuntimeRoot: trustedRuntimeRoot,
            pluginReadOnlyRoot: pluginReadOnlyRoot
        )
    }
}

/// Composition fallback for a future platform before its mandatory sandbox is
/// installed. Executing unsandboxed is never an implicit compatibility mode.
struct UnavailableSandboxBackend: SandboxBackend {
    let identifier: String

    init(identifier: String = "unavailable") { self.identifier = identifier }

    func makeWorkspacePolicy(
        validator _: WorkspaceSecurityValidator,
        additionalReadOnlyRoots _: [URL]
    ) throws -> any AgentSandboxPolicy {
        throw TerminalSessionError.sandboxUnavailable(
            "No secure SandboxBackend is available for this platform."
        )
    }

    func makeMCPPolicy(trustedRuntimeRoot _: URL) throws -> any AgentSandboxPolicy {
        throw TerminalSessionError.sandboxUnavailable(
            "No secure SandboxBackend is available for this platform."
        )
    }

    func makeExtensionPolicy(
        trustedRuntimeRoot _: URL,
        pluginReadOnlyRoot _: URL
    ) throws -> any AgentSandboxPolicy {
        throw TerminalSessionError.sandboxUnavailable(
            "No secure SandboxBackend is available for this platform."
        )
    }
}
