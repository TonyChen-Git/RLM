import CryptoKit
import Darwin
import Foundation

enum RemoteRunnerLimits {
    static let maximumRunners = 64
    static let maximumSettingsBytes = 1 * 1_024 * 1_024
    static let maximumNameBytes = 128
    static let maximumHostBytes = 253
    static let maximumUsernameBytes = 64
    static let maximumPathBytes = 4_096
    static let maximumKnownHostsBytes = 1 * 1_024 * 1_024
    static let maximumPrivateKeyBytes = 256 * 1_024
    static let maximumArguments = 256
    /// Internal SSH wrappers add a fixed prelude plus bounded environment
    /// pairs around a user-facing command. Public tool argv remains capped by
    /// `maximumArguments`; this larger ceiling applies only to transport framing.
    static let maximumTransportArguments = maximumArguments
        + (maximumEnvironmentEntries * 2) + 16
    static let maximumArgumentBytes = 128 * 1_024
    static let maximumCommandBytes = 512 * 1_024
    static let maximumEnvironmentEntries = 64
    static let maximumEnvironmentValueBytes = 64 * 1_024
    static let maximumStandardInputBytes = 8 * 1_024 * 1_024
    static let maximumFileTransferBytes = 4 * 1_024 * 1_024
    static let maximumOutputBytes = 8 * 1_024 * 1_024
    static let maximumDirectoryEntries = 2_000
    static let maximumShellScriptBytes = 512 * 1_024
}

enum RemoteRunnerTransportKind: String, Codable, CaseIterable, Sendable {
    case ssh
}

enum RemoteSSHAuthentication: String, Codable, CaseIterable, Sendable {
    /// Uses the caller's local ssh-agent. Agent forwarding to the remote host
    /// remains disabled; the agent is used only for this outer connection.
    case systemAgent = "system_agent"
    /// A private key is loaded from Keychain for one launch, materialized in a
    /// mode-0600 file below project `tmp`, then unlinked by exact pathname.
    case keychainPrivateKey = "keychain_private_key"
}

/// Non-secret, durable configuration for one user-selected SSH runner.
/// Authentication material is deliberately absent from Codable state.
struct RemoteRunnerConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var transport: RemoteRunnerTransportKind
    var host: String
    var port: Int
    var username: String
    var workspaceRoot: String
    var knownHostsFile: String
    var authentication: RemoteSSHAuthentication
    var connectTimeout: TimeInterval
    var commandTimeout: TimeInterval
    var maximumOutputBytes: Int

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        transport: RemoteRunnerTransportKind = .ssh,
        host: String,
        port: Int = 22,
        username: String,
        workspaceRoot: String,
        knownHostsFile: String,
        authentication: RemoteSSHAuthentication = .keychainPrivateKey,
        connectTimeout: TimeInterval = 15,
        commandTimeout: TimeInterval = 120,
        maximumOutputBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.transport = transport
        self.host = host
        self.port = port
        self.username = username
        self.workspaceRoot = workspaceRoot
        self.knownHostsFile = knownHostsFile
        self.authentication = authentication
        self.connectTimeout = connectTimeout
        self.commandTimeout = commandTimeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, transport, host, port, username, workspaceRoot
        case knownHostsFile, authentication, connectTimeout, commandTimeout
        case maximumOutputBytes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            name: try values.decode(String.self, forKey: .name),
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            transport: try values.decodeIfPresent(
                RemoteRunnerTransportKind.self,
                forKey: .transport
            ) ?? .ssh,
            host: try values.decode(String.self, forKey: .host),
            port: try values.decodeIfPresent(Int.self, forKey: .port) ?? 22,
            username: try values.decode(String.self, forKey: .username),
            workspaceRoot: try values.decode(String.self, forKey: .workspaceRoot),
            knownHostsFile: try values.decode(String.self, forKey: .knownHostsFile),
            authentication: try values.decodeIfPresent(
                RemoteSSHAuthentication.self,
                forKey: .authentication
            ) ?? .keychainPrivateKey,
            connectTimeout: try values.decodeIfPresent(
                TimeInterval.self,
                forKey: .connectTimeout
            ) ?? 15,
            commandTimeout: try values.decodeIfPresent(
                TimeInterval.self,
                forKey: .commandTimeout
            ) ?? 120,
            maximumOutputBytes: try values.decodeIfPresent(
                Int.self,
                forKey: .maximumOutputBytes
            ) ?? 1 * 1_024 * 1_024
        )
        do {
            self = try validated()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .host,
                in: values,
                debugDescription: "Remote runner configuration is invalid."
            )
        }
    }

    func validated() throws -> RemoteRunnerConfiguration {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.workspaceRoot = try RemotePathPolicy.absoluteWorkspaceRoot(workspaceRoot)
        result.knownHostsFile = try RemotePathPolicy.absoluteLocalFile(knownHostsFile)

        guard !result.name.isEmpty,
              result.name.utf8.count <= RemoteRunnerLimits.maximumNameBytes,
              RemoteTextPolicy.isDisplayText(result.name) else {
            throw RemoteExecutionError.invalidConfiguration("Runner name is invalid.")
        }
        guard Self.isValidHost(result.host) else {
            throw RemoteExecutionError.invalidConfiguration("SSH host is invalid.")
        }
        guard (1...65_535).contains(port) else {
            throw RemoteExecutionError.invalidConfiguration("SSH port is outside 1...65535.")
        }
        guard Self.isValidUsername(result.username) else {
            throw RemoteExecutionError.invalidConfiguration("SSH username is invalid.")
        }
        guard connectTimeout.isFinite, (1...60).contains(connectTimeout) else {
            throw RemoteExecutionError.invalidConfiguration(
                "SSH connection timeout is outside 1...60 seconds."
            )
        }
        guard commandTimeout.isFinite, (1...3_600).contains(commandTimeout) else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote command timeout is outside 1...3600 seconds."
            )
        }
        guard (4_096...RemoteRunnerLimits.maximumOutputBytes).contains(maximumOutputBytes) else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote output limit is outside the supported range."
            )
        }
        return result
    }

    /// Stable identity for every non-secret field that can change where or how
    /// a remote tool executes. A run pins this digest before presenting any
    /// approval; resolving a backend with a different digest fails closed.
    func executionConfigurationFingerprint() throws -> String {
        let value = try validated()
        var hasher = SHA256()

        func update(_ label: String, _ payload: String) {
            let bytes = Data("\(label.utf8.count):\(label):\(payload.utf8.count):\(payload)".utf8)
            hasher.update(data: bytes)
        }

        update("schema", "remote-runner-execution-v1")
        update("id", value.id.uuidString.lowercased())
        update("name", value.name)
        update("enabled", value.enabled ? "1" : "0")
        update("transport", value.transport.rawValue)
        update("host", value.host)
        update("port", String(value.port))
        update("username", value.username)
        update("workspace-root", value.workspaceRoot)
        update("known-hosts", value.knownHostsFile)
        update("authentication", value.authentication.rawValue)
        update("connect-timeout", String(value.connectTimeout.bitPattern))
        update("command-timeout", String(value.commandTimeout.bitPattern))
        update("maximum-output", String(value.maximumOutputBytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= RemoteRunnerLimits.maximumHostBytes,
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value != 127 })
        else { return false }

        // IPv6 literals are kept as one argv value and never interpolated.
        if value.contains(":") {
            var address = in6_addr()
            return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) == 1 }) == 1 {
            return true
        }
        guard !value.hasSuffix("."), !value.contains("..") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45
            }
        }
    }

    private static func isValidUsername(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= RemoteRunnerLimits.maximumUsernameBytes,
              !value.hasPrefix("-") else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}

struct RemoteRunnerCredential: Equatable, Sendable {
    var privateKey: String

    func validated() throws -> RemoteRunnerCredential {
        let bytes = privateKey.utf8.count
        guard bytes >= 64, bytes <= RemoteRunnerLimits.maximumPrivateKeyBytes,
              !privateKey.contains("\0"),
              privateKey.hasPrefix("-----BEGIN "),
              privateKey.contains("PRIVATE KEY-----"),
              privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix("PRIVATE KEY-----") else {
            throw RemoteExecutionError.invalidCredential
        }
        return self
    }
}

enum RemoteRunnerCredentialUpdate: Sendable {
    case unchanged
    case replace(RemoteRunnerCredential)
    case remove
}

enum RemoteFailureCode: String, Codable, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case notFound
    case disabled
    case missingCredential
    case hostVerification
    case launch
    case connection
    case remoteExit
    case timeout
    case cancelled
    case protocolViolation
    case unsupported
}

enum RemoteExecutionError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case runnerNotFound(UUID)
    case runnerDisabled(UUID)
    case invalidCredential
    case credentialUnavailable(UUID)
    case hostVerificationFailed
    case launchFailed(String)
    case connectionFailed(String)
    case remoteCommandFailed(exitCode: Int32, detail: String)
    case timedOut(TimeInterval)
    case protocolViolation(String)
    case unsupported(String)

    var code: RemoteFailureCode {
        switch self {
        case .invalidConfiguration: .invalidConfiguration
        case .invalidRequest: .invalidRequest
        case .runnerNotFound: .notFound
        case .runnerDisabled: .disabled
        case .invalidCredential, .credentialUnavailable: .missingCredential
        case .hostVerificationFailed: .hostVerification
        case .launchFailed: .launch
        case .connectionFailed: .connection
        case .remoteCommandFailed: .remoteExit
        case .timedOut: .timeout
        case .protocolViolation: .protocolViolation
        case .unsupported: .unsupported
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            "Remote runner configuration is invalid: \(Self.safe(detail))"
        case .invalidRequest(let detail):
            "Remote request is invalid: \(Self.safe(detail))"
        case .runnerNotFound(let id):
            "Remote runner was not found: \(id.uuidString.lowercased())"
        case .runnerDisabled(let id):
            "Remote runner is disabled: \(id.uuidString.lowercased())"
        case .invalidCredential:
            "The SSH credential is empty, malformed, or outside the size limit."
        case .credentialUnavailable:
            "The SSH credential is unavailable in Keychain."
        case .hostVerificationFailed:
            "SSH host-key verification failed. Check the selected known_hosts file."
        case .launchFailed(let detail):
            "Unable to launch the fixed SSH transport: \(Self.safe(detail))"
        case .connectionFailed(let detail):
            "The SSH connection failed: \(Self.safe(detail))"
        case .remoteCommandFailed(let exitCode, let detail):
            "The remote command failed with exit code \(exitCode): \(Self.safe(detail))"
        case .timedOut(let timeout):
            "The remote operation exceeded its \(Int(timeout.rounded()))-second timeout."
        case .protocolViolation(let detail):
            "The remote runner returned an invalid bounded response: \(Self.safe(detail))"
        case .unsupported(let detail):
            "Remote operation is not supported: \(Self.safe(detail))"
        }
    }

    private static func safe(_ value: String) -> String {
        RemoteTextPolicy.safeDiagnostic(value)
    }
}

enum RemoteTextPolicy {
    static func isDisplayText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || scalar == "\t" || scalar == "\n"
        }
    }

    static func safeDiagnostic(_ value: String, maximumBytes: Int = 2_048) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        var bytes = 0
        for scalar in value.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar)
                    || scalar == "\t" || scalar == "\n" else { continue }
            let text = String(scalar)
            let count = text.utf8.count
            guard bytes + count <= maximumBytes else { break }
            result += text
            bytes += count
        }
        return result.isEmpty ? "No safe diagnostic was provided." : result
    }
}

enum RemotePathPolicy {
    static func absoluteWorkspaceRoot(_ value: String) throws -> String {
        let result = try normalizedAbsolute(value)
        guard result != "/" else {
            throw RemoteExecutionError.invalidConfiguration(
                "The remote workspace root cannot grant the filesystem root."
            )
        }
        return result
    }

    static func absoluteLocalFile(_ value: String) throws -> String {
        try normalizedAbsolute(value)
    }

    static func relative(_ value: String, allowRoot: Bool = true) throws -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowRoot, candidate.isEmpty || candidate == "." { return "." }
        guard !candidate.isEmpty, !candidate.hasPrefix("/"),
              candidate.utf8.count <= RemoteRunnerLimits.maximumPathBytes,
              !candidate.contains("\0"),
              RemoteTextPolicy.isDisplayText(candidate) else {
            throw RemoteExecutionError.invalidRequest("Remote path is invalid.")
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RemoteExecutionError.invalidRequest(
                "Remote paths must be normalized workspace-relative paths."
            )
        }
        return components.joined(separator: "/")
    }

    static func refusesAppleDoubleMutation(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0.hasPrefix("._") }) else {
            throw RemoteExecutionError.invalidRequest(
                "AppleDouble ._* entries are never mutated or deleted."
            )
        }
    }

    static func refusesGitAdministrativePath(_ value: String) throws {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".git") else {
            throw RemoteExecutionError.invalidRequest(
                "Git administrative paths are available only through the dedicated Git backend."
            )
        }
    }

    private static func normalizedAbsolute(_ value: String) throws -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.hasPrefix("/"),
              candidate.utf8.count <= RemoteRunnerLimits.maximumPathBytes,
              !candidate.contains("\0"),
              RemoteTextPolicy.isDisplayText(candidate) else {
            throw RemoteExecutionError.invalidConfiguration("An absolute path is required.")
        }
        let components = candidate.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RemoteExecutionError.invalidConfiguration("Path traversal is not allowed.")
        }
        return "/" + components.joined(separator: "/")
    }
}

struct RemoteSecretRedactor: Sendable {
    private let secrets: [String]

    init(secrets: [String]) {
        self.secrets = Array(Set(secrets.filter { $0.utf8.count >= 4 }))
            .sorted { $0.utf8.count > $1.utf8.count }
    }

    func redact(_ value: String) -> String {
        secrets.reduce(value) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }
}
