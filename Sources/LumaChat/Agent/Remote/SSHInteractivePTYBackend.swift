import Foundation

/// A Task-owned SSH PTY uses the same bounded/reaped Darwin PTY transport as a
/// local terminal. The local child is only the system OpenSSH client; the
/// remote shell is selected from a closed allow-list and framed as argv.
struct SSHInteractivePTYBackend: PTYBackend {
    let configuration: RemoteRunnerConfiguration
    let credential: RemoteRunnerCredential?
    let knownHostsData: Data
    let host: RemoteTaskTerminalHostIdentity

    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        throw RemoteExecutionError.unsupported(
            "An SSH PTY cannot be opened through a local workspace validator."
        )
    }

    func makeRemoteSession(
        shell: String,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        guard cwd == nil || cwd == ".",
              RemoteShell(rawValue: shell) != nil,
              environment.isEmpty,
              host.runnerID == configuration.id,
              host.configuredWorkspaceRoot == configuration.workspaceRoot else {
            throw RemoteExecutionError.invalidRequest("SSH terminal binding is invalid.")
        }
        let lease = try SSHLaunchMaterialLease.create(
            configuration: configuration,
            credential: credential,
            knownHostsData: knownHostsData
        )
        do {
            let request = SSHCommandRequest(
                executable: "/usr/bin/python3",
                arguments: [
                    "-I", "-c", Self.launchScript,
                    host.canonicalWorkspaceRoot, shell
                ],
                workingDirectory: nil,
                environment: ["TERM": "xterm-256color"],
                standardInput: nil,
                timeout: 3_600,
                outputLimit: min(configuration.maximumOutputBytes, 2 * 1_024 * 1_024),
                allocatePTY: true,
                operationLabel: "task_terminal"
            )
            let invocation = try SSHInvocationBuilder.invocation(
                configuration: configuration,
                request: request,
                knownHostsFile: lease.knownHostsFile,
                identityFile: lease.identityFile
            )
            return PseudoTerminalSession(
                directInvocation: invocation,
                launchMaterial: lease
            )
        } catch {
            lease.dispose()
            throw error
        }
    }

    /// Walk each component without following a symlink before handing the
    /// verified directory descriptor to the interactive shell. The shell
    /// never receives a model-supplied command or workspace path.
    private static let launchScript = #"""
import os,sys
root,shell=sys.argv[1:]
if not root.startswith('/') or '\x00' in root:sys.exit(126)
parts=root.split('/')[1:]
if not parts or any(p in ('','.','..') for p in parts):sys.exit(126)
fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
try:
    for part in parts:
        child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
        os.close(fd)
        fd=child
    os.fchdir(fd)
    os.execv(shell,[shell,'-i'])
finally:
    os.close(fd)
"""#
}
