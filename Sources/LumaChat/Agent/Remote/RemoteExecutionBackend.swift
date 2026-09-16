import Foundation

struct RemoteHostReceipt: Codable, Equatable, Sendable {
    var runnerID: UUID
    var transport: RemoteRunnerTransportKind
    /// User-selected network target. This is not claimed to be the server's
    /// own hostname; aliases and bastions can legitimately differ.
    var configuredHost: String
    var configuredPort: Int
    var configuredUser: String
    /// Values reported after authentication by a fixed remote probe.
    var serverReportedHostname: String
    var effectiveUser: String
    var effectiveUserID: UInt32
    var configuredWorkspaceRoot: String
    var canonicalWorkspaceRoot: String
    var verifiedAt: Date
}

struct RemoteOperationReceipt: Codable, Equatable, Sendable {
    var id: UUID
    var runnerID: UUID
    var operation: String
    var host: RemoteHostReceipt
    var requestedPath: String?
    var canonicalPath: String?
    var startedAt: Date
    var completedAt: Date
    var exitCode: Int32
    var timedOut: Bool
    var outputTruncated: Bool
}

enum RemoteFileKind: String, Codable, Equatable, Sendable {
    case file
    case directory
    case symbolicLink = "symbolic_link"
    case other
}

struct RemoteFileMetadata: Codable, Equatable, Sendable {
    var path: String
    var canonicalPath: String
    var kind: RemoteFileKind
    var byteCount: Int64
    var permissions: UInt16
    var modifiedAt: Date
}

struct RemoteDirectoryEntry: Codable, Equatable, Sendable {
    var name: String
    var kind: RemoteFileKind
    var byteCount: Int64
    var modifiedAt: Date
}

enum RemoteFilesystemRequest: Sendable, Equatable {
    case metadata(path: String)
    case list(path: String, maximumEntries: Int)
    case read(path: String, maximumBytes: Int)
    case write(path: String, data: Data, createParents: Bool)
    case createDirectory(path: String, recursive: Bool)
    /// Removes one regular file or one empty directory. Recursive deletion is
    /// deliberately not part of the v1 contract, and `._*` always fails.
    case remove(path: String)
    case move(source: String, destination: String)
}

enum RemoteFilesystemPayload: Sendable, Equatable {
    case metadata(RemoteFileMetadata)
    case listing([RemoteDirectoryEntry])
    case file(Data, metadata: RemoteFileMetadata, truncated: Bool)
    case mutation(RemoteFileMetadata?)
}

struct RemoteFilesystemResult: Sendable, Equatable {
    var payload: RemoteFilesystemPayload
    var receipt: RemoteOperationReceipt
}

protocol RemoteFilesystemExecutionBackend: Sendable {
    func executeFilesystem(
        _ request: RemoteFilesystemRequest
    ) async throws -> RemoteFilesystemResult
}

enum RemoteGitRequest: Sendable, Equatable {
    case status
    case diff(staged: Bool, paths: [String])
    case log(maximumCount: Int)
    case add(paths: [String])
    case commit(message: String)
}

struct RemoteGitResult: Codable, Equatable, Sendable {
    var stdout: String
    var stderr: String
    var receipt: RemoteOperationReceipt
}

protocol RemoteGitExecutionBackend: Sendable {
    func executeGit(_ request: RemoteGitRequest) async throws -> RemoteGitResult
}

enum RemoteValidationKind: String, Codable, Equatable, Sendable {
    case build
    case test
}

enum RemoteBuildConfiguration: String, Codable, CaseIterable, Equatable, Sendable {
    case debug
    case release
}

enum RemoteProjectToolchain: Sendable, Equatable {
    case swiftPackage
    case xcode(scheme: String)
}

struct RemoteValidationRequest: Sendable, Equatable {
    var kind: RemoteValidationKind
    var toolchain: RemoteProjectToolchain
    var configuration: RemoteBuildConfiguration
    var timeout: TimeInterval?

    init(
        kind: RemoteValidationKind,
        toolchain: RemoteProjectToolchain = .swiftPackage,
        configuration: RemoteBuildConfiguration = .debug,
        timeout: TimeInterval? = nil
    ) {
        self.kind = kind
        self.toolchain = toolchain
        self.configuration = configuration
        self.timeout = timeout
    }
}

struct RemoteValidationResult: Codable, Equatable, Sendable {
    var kind: RemoteValidationKind
    var stdout: String
    var stderr: String
    var receipt: RemoteOperationReceipt
}

protocol RemoteBuildExecutionBackend: Sendable {
    func executeBuild(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult
}

protocol RemoteTestExecutionBackend: Sendable {
    func executeTest(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult
}

enum RemoteShell: String, Codable, CaseIterable, Sendable {
    case sh = "/bin/sh"
    case bash = "/bin/bash"
    case zsh = "/bin/zsh"
}

struct RemoteShellRequest: Sendable, Equatable {
    var script: String
    var shell: RemoteShell
    var environment: [String: String]
    var timeout: TimeInterval?
    /// Requests an SSH-allocated pseudo terminal for this bounded, one-shot
    /// command. It does not claim Task Terminal reconnect/input semantics.
    var allocatePTY: Bool

    init(
        script: String,
        shell: RemoteShell = .sh,
        environment: [String: String] = [:],
        timeout: TimeInterval? = nil,
        allocatePTY: Bool = false
    ) {
        self.script = script
        self.shell = shell
        self.environment = environment
        self.timeout = timeout
        self.allocatePTY = allocatePTY
    }
}

struct RemoteShellResult: Codable, Equatable, Sendable {
    var stdout: String
    var stderr: String
    var receipt: RemoteOperationReceipt
}

protocol RemoteShellExecutionBackend: Sendable {
    func executeShell(_ request: RemoteShellRequest) async throws -> RemoteShellResult
}

protocol RemotePTYExecutionBackend: Sendable {
    /// Returns a TaskTerminal-compatible factory. Backend selection remains a
    /// host decision; no model argument names a runner or SSH target.
    func makePTYBackend() -> any PTYBackend
}

protocol RemoteExecutionBackend:
    RemoteFilesystemExecutionBackend,
    RemoteGitExecutionBackend,
    RemoteBuildExecutionBackend,
    RemoteTestExecutionBackend,
    RemoteShellExecutionBackend,
    RemotePTYExecutionBackend,
    Sendable
{
    var runnerID: UUID { get }
    func verifyConnection() async throws -> RemoteHostReceipt
}
