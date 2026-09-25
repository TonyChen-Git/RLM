import CryptoKit
import Foundation

struct RemoteRunnerSummary: Equatable, Identifiable, Sendable {
    var configuration: RemoteRunnerConfiguration
    var hasCredential: Bool

    var id: UUID { configuration.id }
}

protocol RemoteRunnerServicing: Sendable {
    func list() async throws -> [RemoteRunnerConfiguration]
    func summaries() async throws -> [RemoteRunnerSummary]
    func configuration(id: UUID) async throws -> RemoteRunnerConfiguration
    func upsert(
        _ configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredentialUpdate
    ) async throws -> [RemoteRunnerConfiguration]
    func setEnabled(_ enabled: Bool, id: UUID) async throws -> [RemoteRunnerConfiguration]
    func delete(id: UUID) async throws -> [RemoteRunnerConfiguration]
    func executionIdentity(for id: UUID) async throws -> AgentRemoteExecutionIdentity
    func verifyConnection(id: UUID) async throws -> RemoteHostReceipt
    func backend(for id: UUID) async throws -> any RemoteExecutionBackend
    func backend(
        for id: UUID,
        matching expectedIdentity: AgentRemoteExecutionIdentity
    ) async throws -> any RemoteExecutionBackend
}

/// Host-owned facade over durable runner metadata, Keychain credentials, and
/// the concrete transport. It deliberately creates a backend only after
/// resolving an opaque runner UUID from trusted Task state.
actor RemoteRunnerService: RemoteRunnerServicing {
    private struct CapturedAuthority: Sendable {
        var configuration: RemoteRunnerConfiguration
        var credential: RemoteRunnerCredential?
        var knownHostsData: Data
    }

    private let store: RemoteRunnerStore
    private let credentialProvider: any RemoteRunnerCredentialProviding
    private let transport: any SSHCommandTransporting

    init(
        store: RemoteRunnerStore = RemoteRunnerStore(),
        credentialProvider: any RemoteRunnerCredentialProviding =
            KeychainRemoteRunnerCredentialProvider(),
        transport: any SSHCommandTransporting = ProcessSSHCommandTransport()
    ) {
        self.store = store
        self.credentialProvider = credentialProvider
        self.transport = transport
    }

    func list() async throws -> [RemoteRunnerConfiguration] {
        try await store.list()
    }

    func summaries() async throws -> [RemoteRunnerSummary] {
        let configurations = try await store.list()
        var result: [RemoteRunnerSummary] = []
        result.reserveCapacity(configurations.count)
        for configuration in configurations {
            let hasCredential: Bool
            if configuration.authentication == .systemAgent {
                hasCredential = true
            } else {
                hasCredential = try await store.hasCredential(for: configuration.id)
            }
            result.append(RemoteRunnerSummary(
                configuration: configuration,
                hasCredential: hasCredential
            ))
        }
        return result
    }

    func configuration(id: UUID) async throws -> RemoteRunnerConfiguration {
        try await store.configuration(id: id)
    }

    @discardableResult
    func upsert(
        _ configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredentialUpdate = .unchanged
    ) async throws -> [RemoteRunnerConfiguration] {
        try await store.upsert(configuration, credential: credential)
    }

    @discardableResult
    func setEnabled(
        _ enabled: Bool,
        id: UUID
    ) async throws -> [RemoteRunnerConfiguration] {
        try await store.setEnabled(enabled, id: id)
    }

    @discardableResult
    func delete(id: UUID) async throws -> [RemoteRunnerConfiguration] {
        try await store.delete(id: id)
    }

    func executionIdentity(for id: UUID) async throws -> AgentRemoteExecutionIdentity {
        let authority = try await capturedAuthority(for: id)
        return try identity(
            for: authority.configuration,
            credential: authority.credential,
            knownHostsData: authority.knownHostsData
        )
    }

    private func identity(
        for configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData: Data
    ) throws -> AgentRemoteExecutionIdentity {
        let configurationDigest = try configuration.executionConfigurationFingerprint()
        var hasher = SHA256()
        // Every variable-length authority component is reduced to a fixed-size
        // digest before composition, preventing ambiguous concatenations while
        // keeping private-key and known_hosts bytes out of the durable identity.
        hasher.update(data: Data("remote-runner-authority-v2".utf8))
        hasher.update(data: Data(configurationDigest.utf8))
        hasher.update(data: Data(SHA256.hash(data: knownHostsData)))
        switch configuration.authentication {
        case .systemAgent:
            hasher.update(data: Data([0]))
        case .keychainPrivateKey:
            guard let credential else {
                throw RemoteExecutionError.credentialUnavailable(configuration.id)
            }
            hasher.update(data: Data([1]))
            hasher.update(data: Data(SHA256.hash(data: Data(credential.privateKey.utf8))))
        }
        let authorityFingerprint = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return AgentRemoteExecutionIdentity(
            runnerID: configuration.id,
            backendLabel: "SSH · system OpenSSH",
            host: configuration.host,
            port: configuration.port,
            user: configuration.username,
            workspaceRoot: configuration.workspaceRoot,
            configurationFingerprint: authorityFingerprint
        )
    }

    func verifyConnection(id: UUID) async throws -> RemoteHostReceipt {
        let backend = try await backend(for: id)
        return try await backend.verifyConnection()
    }

    func backend(id: UUID) async throws -> any RemoteExecutionBackend {
        try await backend(for: id)
    }

    func backend(for id: UUID) async throws -> any RemoteExecutionBackend {
        let authority = try await capturedAuthority(for: id)
        return try makeBackend(
            configuration: authority.configuration,
            credential: authority.credential,
            knownHostsData: authority.knownHostsData
        )
    }

    func backend(
        for id: UUID,
        matching expectedIdentity: AgentRemoteExecutionIdentity
    ) async throws -> any RemoteExecutionBackend {
        let authority = try await capturedAuthority(for: id)
        let currentIdentity = try identity(
            for: authority.configuration,
            credential: authority.credential,
            knownHostsData: authority.knownHostsData
        )
        guard currentIdentity == expectedIdentity else {
            throw RemoteExecutionError.invalidRequest(
                "Remote runner configuration changed after this run started."
            )
        }
        // Configuration and credential were captured as one authority
        // snapshot before comparison; this backend never re-reads either.
        return try makeBackend(
            configuration: authority.configuration,
            credential: authority.credential,
            knownHostsData: authority.knownHostsData
        )
    }

    private func makeBackend(
        configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData: Data
    ) throws -> any RemoteExecutionBackend {
        switch configuration.transport {
        case .ssh:
            return try SSHRemoteExecutionBackend(
                configuration: configuration,
                capturedCredential: credential,
                capturedKnownHostsData: knownHostsData,
                transport: transport
            )
        }
    }

    private func capturedCredential(
        for configuration: RemoteRunnerConfiguration
    ) throws -> RemoteRunnerCredential? {
        switch configuration.authentication {
        case .systemAgent:
            return nil
        case .keychainPrivateKey:
            guard let credential = try credentialProvider.credential(for: configuration) else {
                throw RemoteExecutionError.credentialUnavailable(configuration.id)
            }
            return try credential.validated()
        }
    }

    /// Captures all mutable authority inputs and then re-reads the durable
    /// configuration after the only actor suspension. A concurrent service
    /// mutation therefore cannot combine an old runner record with newer
    /// credential/trust material in one execution identity.
    private func capturedAuthority(for id: UUID) async throws -> CapturedAuthority {
        let configuration = try await enabledConfiguration(id: id)
        let credential = try capturedCredential(for: configuration)
        let knownHostsData = try SSHLaunchMaterialLease.captureKnownHostsData(
            configuration: configuration
        )
        let confirmedConfiguration = try await store.configuration(id: id)
        guard confirmedConfiguration.enabled else {
            throw RemoteExecutionError.runnerDisabled(id)
        }
        guard confirmedConfiguration == configuration else {
            throw RemoteExecutionError.invalidRequest(
                "Remote runner configuration changed while capturing its authority."
            )
        }
        return CapturedAuthority(
            configuration: configuration,
            credential: credential,
            knownHostsData: knownHostsData
        )
    }

    private func enabledConfiguration(id: UUID) async throws -> RemoteRunnerConfiguration {
        let configuration = try await store.configuration(id: id)
        guard configuration.enabled else { throw RemoteExecutionError.runnerDisabled(id) }
        return configuration
    }
}
