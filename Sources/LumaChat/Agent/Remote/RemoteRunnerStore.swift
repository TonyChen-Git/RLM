import Darwin
import Foundation

protocol RemoteRunnerSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

struct RemoteRunnerKeychainSecretStore: RemoteRunnerSecretStore, Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore(service: "LumaChat.RemoteRunnerCredentials")) {
        self.keychain = keychain
    }

    func save(_ value: String, account: String) throws {
        try keychain.save(value, account: account)
    }

    func load(account: String) throws -> String? {
        try keychain.load(account: account)
    }

    func delete(account: String) throws {
        try keychain.delete(account: account)
    }
}

/// Narrow credential seam used by SSH execution. Production reads from the
/// dedicated Keychain service on demand; no backend or Task JSON owns a key.
protocol RemoteRunnerCredentialProviding: Sendable {
    func credential(for runnerID: UUID) throws -> RemoteRunnerCredential?
}

struct KeychainRemoteRunnerCredentialProvider: RemoteRunnerCredentialProviding, Sendable {
    private let secretStore: any RemoteRunnerSecretStore

    init(secretStore: any RemoteRunnerSecretStore = RemoteRunnerKeychainSecretStore()) {
        self.secretStore = secretStore
    }

    func credential(for runnerID: UUID) throws -> RemoteRunnerCredential? {
        guard let value = try secretStore.load(
            account: RemoteRunnerStore.credentialAccount(runnerID)
        ) else { return nil }
        return try RemoteRunnerCredential(privateKey: value).validated()
    }
}

private struct RemoteRunnerDocument: Codable, Sendable {
    var version: Int
    var runners: [RemoteRunnerConfiguration]
}

/// Atomic, bounded storage for non-secret runner metadata. Credential updates
/// are compensated if the metadata write fails, so the last durable document
/// never silently changes which Keychain value it refers to.
actor RemoteRunnerStore {
    static let defaultFileURL = AppPaths.appSupport
        .appendingPathComponent("RemoteRunners", isDirectory: true)
        .appendingPathComponent("runners.json", isDirectory: false)

    private let fileURL: URL
    private let secretStore: any RemoteRunnerSecretStore

    init(
        fileURL: URL = RemoteRunnerStore.defaultFileURL,
        secretStore: any RemoteRunnerSecretStore = RemoteRunnerKeychainSecretStore()
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
    }

    func list() throws -> [RemoteRunnerConfiguration] {
        try readConfigurations().sorted(by: Self.sort)
    }

    func configuration(id: UUID) throws -> RemoteRunnerConfiguration {
        guard let configuration = try readConfigurations().first(where: { $0.id == id }) else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        return configuration
    }

    func hasCredential(for runnerID: UUID) throws -> Bool {
        try secretStore.load(account: Self.credentialAccount(runnerID)) != nil
    }

    @discardableResult
    func upsert(
        _ rawConfiguration: RemoteRunnerConfiguration,
        credential update: RemoteRunnerCredentialUpdate = .unchanged
    ) throws -> [RemoteRunnerConfiguration] {
        let configuration = try rawConfiguration.validated()
        var configurations = try readConfigurations()
        let isExisting = configurations.contains { $0.id == configuration.id }
        guard isExisting || configurations.count < RemoteRunnerLimits.maximumRunners else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings exceed the 64-runner limit."
            )
        }

        let account = Self.credentialAccount(configuration.id)
        let previousSecret = try secretStore.load(account: account)
        let effectiveUpdate: RemoteRunnerCredentialUpdate
        if configuration.authentication == .systemAgent {
            if case .replace = update {
                throw RemoteExecutionError.invalidConfiguration(
                    "A system-agent runner cannot retain a private key."
                )
            }
            effectiveUpdate = .remove
        } else {
            effectiveUpdate = update
        }

        switch effectiveUpdate {
        case .unchanged:
            break
        case .replace(let credential):
            let validated = try credential.validated()
            try secretStore.save(validated.privateKey, account: account)
        case .remove:
            try secretStore.delete(account: account)
        }

        configurations.removeAll { $0.id == configuration.id }
        configurations.append(configuration)
        do {
            try persist(configurations)
        } catch {
            try? restore(previousSecret, account: account)
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: UUID) throws -> [RemoteRunnerConfiguration] {
        var configurations = try readConfigurations()
        guard let index = configurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        configurations[index].enabled = enabled
        try persist(configurations)
        return configurations.sorted(by: Self.sort)
    }

    @discardableResult
    func delete(id: UUID) throws -> [RemoteRunnerConfiguration] {
        var configurations = try readConfigurations()
        guard configurations.contains(where: { $0.id == id }) else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        let account = Self.credentialAccount(id)
        let previousSecret = try secretStore.load(account: account)
        try secretStore.delete(account: account)
        configurations.removeAll { $0.id == id }
        do {
            try persist(configurations)
        } catch {
            try? restore(previousSecret, account: account)
            throw error
        }
        return configurations.sorted(by: Self.sort)
    }

    nonisolated static func credentialAccount(_ runnerID: UUID) -> String {
        "remote-runner|ssh|\(runnerID.uuidString.lowercased())"
    }

    private func restore(_ value: String?, account: String) throws {
        if let value {
            try secretStore.save(value, account: account)
        } else {
            try secretStore.delete(account: account)
        }
    }

    private func readConfigurations() throws -> [RemoteRunnerConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Self.readBoundedRegularFile(fileURL)
        let document: RemoteRunnerDocument
        do {
            document = try JSONDecoder().decode(RemoteRunnerDocument.self, from: data)
        } catch is RemoteExecutionError {
            throw error
        } catch {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings could not be decoded."
            )
        }
        guard document.version == 1 else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings use an unsupported version."
            )
        }
        guard document.runners.count <= RemoteRunnerLimits.maximumRunners else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings exceed the 64-runner limit."
            )
        }
        var seen = Set<UUID>()
        return try document.runners.map { configuration in
            guard seen.insert(configuration.id).inserted else {
                throw RemoteExecutionError.invalidConfiguration(
                    "Remote runner settings contain duplicate identifiers."
                )
            }
            return try configuration.validated()
        }
    }

    private func persist(_ configurations: [RemoteRunnerConfiguration]) throws {
        guard configurations.count <= RemoteRunnerLimits.maximumRunners else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings exceed the 64-runner limit."
            )
        }
        var seen = Set<UUID>()
        let normalized = try configurations.map { configuration in
            guard seen.insert(configuration.id).inserted else {
                throw RemoteExecutionError.invalidConfiguration(
                    "Remote runner settings contain duplicate identifiers."
                )
            }
            return try configuration.validated()
        }.sorted(by: Self.sort)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(RemoteRunnerDocument(version: 1, runners: normalized))
        guard data.count <= RemoteRunnerLimits.maximumSettingsBytes else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings exceed the 1 MiB limit."
            )
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private nonisolated static func sort(
        _ lhs: RemoteRunnerConfiguration,
        _ rhs: RemoteRunnerConfiguration
    ) -> Bool {
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func readBoundedRegularFile(_ fileURL: URL) throws -> Data {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings must be a regular non-symbolic-link file."
            )
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= RemoteRunnerLimits.maximumSettingsBytes else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings must be a regular file no larger than 1 MiB."
            )
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= RemoteRunnerLimits.maximumSettingsBytes else {
                    throw RemoteExecutionError.invalidConfiguration(
                        "Remote runner settings changed beyond the 1 MiB limit while reading."
                    )
                }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw RemoteExecutionError.invalidConfiguration(
                    "Remote runner settings could not be read safely."
                )
            }
        }
        return data
    }
}
