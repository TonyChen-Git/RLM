import Darwin
import Foundation

protocol RemoteRunnerSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

struct RemoteRunnerStoreRecoveryFailure: Sendable {
    let account: String
    let underlyingError: any Error
}

struct RemoteRunnerStoreTransactionError: LocalizedError, Sendable {
    enum Operation: String, Sendable {
        case upsert
        case delete
    }

    let operation: Operation
    let primaryError: any Error
    let recoveryFailures: [RemoteRunnerStoreRecoveryFailure]

    var errorDescription: String? {
        "Remote runner \(operation.rawValue) failed, and staged credential cleanup failed for "
            + "\(recoveryFailures.count) account(s). Persisted runner metadata and Keychain "
            + "state may differ; no credential values are included in this diagnostic."
    }
}

/// The atomic writer failed and the durable document is neither the exact
/// previous bytes nor the exact requested bytes. Both old and staged
/// credentials are preserved because either may still be referenced.
struct RemoteRunnerStoreDurabilityError: LocalizedError, Sendable {
    enum State: Sendable {
        /// Requested bytes are currently visible, but the writer reported a
        /// late durability failure. A reboot could still expose old bytes.
        case requestedVisible
        /// The visible bytes are neither the previous nor requested document,
        /// or could not be read safely.
        case uncertain
    }

    let primaryError: any Error
    let state: State

    var errorDescription: String? {
        switch state {
        case .requestedVisible:
            return "Remote runner settings are visible, but crash durability could not be "
                + "confirmed. Existing and staged credentials were preserved."
        case .uncertain:
            return "Remote runner settings durability is uncertain. Existing and staged "
                + "credentials were preserved, and the operation failed closed."
        }
    }
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
    func credential(for configuration: RemoteRunnerConfiguration) throws
        -> RemoteRunnerCredential?
}

struct KeychainRemoteRunnerCredentialProvider: RemoteRunnerCredentialProviding, Sendable {
    private let secretStore: any RemoteRunnerSecretStore

    init(secretStore: any RemoteRunnerSecretStore = RemoteRunnerKeychainSecretStore()) {
        self.secretStore = secretStore
    }

    func credential(for configuration: RemoteRunnerConfiguration) throws
        -> RemoteRunnerCredential? {
        guard let value = try secretStore.load(
            account: RemoteRunnerStore.credentialAccount(for: configuration)
        ) else { return nil }
        return try RemoteRunnerCredential(privateKey: value).validated()
    }
}

private struct RemoteRunnerDocument: Codable, Sendable {
    var version: Int
    var runners: [RemoteRunnerConfiguration]
}

/// Atomic, bounded storage for non-secret runner metadata. New credentials are
/// written to a fresh generation account before metadata commit. Old accounts
/// are retired only after metadata commit, so a crash can leave an unreachable
/// orphan but cannot silently rebind live metadata to another credential.
actor RemoteRunnerStore {
    static let defaultFileURL = AppPaths.appSupport
        .appendingPathComponent("RemoteRunners", isDirectory: true)
        .appendingPathComponent("runners.json", isDirectory: false)
    private static let processTransactionLock = NSLock()

    private let fileURL: URL
    private let secretStore: any RemoteRunnerSecretStore
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(
        fileURL: URL = RemoteRunnerStore.defaultFileURL,
        secretStore: any RemoteRunnerSecretStore = RemoteRunnerKeychainSecretStore(),
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            try AtomicFileWriter.write($0, to: $1)
        }
    ) {
        self.fileURL = fileURL
        self.secretStore = secretStore
        self.writeData = writeData
    }

    func list() throws -> [RemoteRunnerConfiguration] {
        try withExclusiveSettingsLock {
            try readConfigurations().sorted(by: Self.sort)
        }
    }

    func configuration(id: UUID) throws -> RemoteRunnerConfiguration {
        try withExclusiveSettingsLock {
            guard let configuration = try readConfigurations().first(where: { $0.id == id }) else {
                throw RemoteExecutionError.runnerNotFound(id)
            }
            return configuration
        }
    }

    func hasCredential(for runnerID: UUID) throws -> Bool {
        try withExclusiveSettingsLock {
            guard let configuration = try readConfigurations().first(where: {
                $0.id == runnerID
            }) else {
                throw RemoteExecutionError.runnerNotFound(runnerID)
            }
            return try secretStore.load(
                account: Self.credentialAccount(for: configuration)
            ) != nil
        }
    }

    @discardableResult
    func upsert(
        _ rawConfiguration: RemoteRunnerConfiguration,
        credential update: RemoteRunnerCredentialUpdate = .unchanged
    ) throws -> [RemoteRunnerConfiguration] {
        try withExclusiveSettingsLock {
            try upsertUnlocked(rawConfiguration, credential: update)
        }
    }

    private func upsertUnlocked(
        _ rawConfiguration: RemoteRunnerConfiguration,
        credential update: RemoteRunnerCredentialUpdate
    ) throws -> [RemoteRunnerConfiguration] {
        var candidate = rawConfiguration
        // UI editors may submit a copy of an existing key-backed record while
        // switching it to system-agent authentication. The reference is store
        // owned and must be removed before public-field validation.
        if candidate.authentication == .systemAgent {
            candidate.credentialReference = nil
        }
        var configuration = try candidate.validated()
        var configurations = try readConfigurations()
        let existing = configurations.first { $0.id == configuration.id }
        let isExisting = existing != nil
        guard isExisting || configurations.count < RemoteRunnerLimits.maximumRunners else {
            throw RemoteExecutionError.invalidConfiguration(
                "Remote runner settings exceed the 64-runner limit."
            )
        }

        let previousDocument = try persistedDocumentDataIfPresent()
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

        let oldAccount = existing.flatMap { oldConfiguration in
            oldConfiguration.authentication == .keychainPrivateKey
                ? Self.credentialAccount(for: oldConfiguration)
                : nil
        }
        var stagedAccount: String?
        var stagedSecretWasAttempted = false
        switch effectiveUpdate {
        case .unchanged:
            if configuration.authentication == .keychainPrivateKey {
                // The reference belongs to durable state, not UI input. Keep
                // the current generation for edits; use a fresh empty
                // generation for a new or authentication-transitioned runner.
                if let existing, existing.authentication == .keychainPrivateKey {
                    configuration.credentialReference = existing.credentialReference
                } else {
                    configuration.credentialReference = Self.newCredentialReference()
                }
            } else {
                configuration.credentialReference = nil
            }
        case .replace(let credential):
            let validated = try credential.validated()
            configuration.credentialReference = Self.newCredentialReference()
            let account = Self.credentialAccount(for: configuration)
            stagedAccount = account
            stagedSecretWasAttempted = true
            do {
                try secretStore.save(validated.privateKey, account: account)
            } catch {
                throw stagingFailure(
                    operation: .upsert,
                    primaryError: error,
                    stagedAccount: account
                )
            }
        case .remove:
            // A key-backed runner points at a fresh, deliberately empty
            // generation. Nil remains reserved for legacy document fallback.
            configuration.credentialReference = configuration.authentication
                == .keychainPrivateKey ? Self.newCredentialReference() : nil
        }

        configurations.removeAll { $0.id == configuration.id }
        configurations.append(configuration)
        do {
            try persist(configurations, previousDocument: previousDocument)
        } catch let error as RemoteRunnerStoreDurabilityError {
            // The document may reference either generation. Preserve both.
            throw error
        } catch {
            guard stagedSecretWasAttempted, let stagedAccount else { throw error }
            throw stagingFailure(
                operation: .upsert,
                primaryError: error,
                stagedAccount: stagedAccount
            )
        }
        let currentAccount = configuration.authentication == .keychainPrivateKey
            ? Self.credentialAccount(for: configuration)
            : nil
        if let oldAccount, oldAccount != currentAccount {
            // Metadata no longer references this account. Cleanup is
            // deliberately post-commit; failure can only leave an orphan.
            try? secretStore.delete(account: oldAccount)
        }
        return configurations.sorted(by: Self.sort)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: UUID) throws -> [RemoteRunnerConfiguration] {
        try withExclusiveSettingsLock {
            try setEnabledUnlocked(enabled, id: id)
        }
    }

    private func setEnabledUnlocked(
        _ enabled: Bool,
        id: UUID
    ) throws -> [RemoteRunnerConfiguration] {
        var configurations = try readConfigurations()
        guard let index = configurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        let previousDocument = try persistedDocumentDataIfPresent()
        configurations[index].enabled = enabled
        try persist(configurations, previousDocument: previousDocument)
        return configurations.sorted(by: Self.sort)
    }

    @discardableResult
    func delete(id: UUID) throws -> [RemoteRunnerConfiguration] {
        try withExclusiveSettingsLock { try deleteUnlocked(id: id) }
    }

    private func deleteUnlocked(id: UUID) throws -> [RemoteRunnerConfiguration] {
        var configurations = try readConfigurations()
        guard configurations.contains(where: { $0.id == id }) else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        let removedConfiguration = configurations.first { $0.id == id }
        let previousDocument = try persistedDocumentDataIfPresent()
        configurations.removeAll { $0.id == id }
        try persist(configurations, previousDocument: previousDocument)
        if let removedConfiguration,
           removedConfiguration.authentication == .keychainPrivateKey {
            // Removing metadata first makes a crash/failure an orphan-only
            // outcome; no live runner can be left without its referenced key.
            try? secretStore.delete(
                account: Self.credentialAccount(for: removedConfiguration)
            )
        }
        return configurations.sorted(by: Self.sort)
    }

    nonisolated static func credentialAccount(_ runnerID: UUID) -> String {
        "remote-runner|ssh|\(runnerID.uuidString.lowercased())"
    }

    nonisolated static func credentialAccount(
        for configuration: RemoteRunnerConfiguration
    ) -> String {
        let legacy = credentialAccount(configuration.id)
        guard let reference = configuration.credentialReference else { return legacy }
        return "\(legacy)|generation|\(reference)"
    }

    private nonisolated static func newCredentialReference() -> String {
        UUID().uuidString.lowercased()
    }

    private func stagingFailure(
        operation: RemoteRunnerStoreTransactionError.Operation,
        primaryError: any Error,
        stagedAccount: String
    ) -> any Error {
        do {
            try secretStore.delete(account: stagedAccount)
            return primaryError
        } catch {
            return RemoteRunnerStoreTransactionError(
                operation: operation,
                primaryError: primaryError,
                recoveryFailures: [
                    RemoteRunnerStoreRecoveryFailure(
                        account: stagedAccount,
                        underlyingError: error
                    )
                ]
            )
        }
    }

    private func readConfigurations() throws -> [RemoteRunnerConfiguration] {
        guard let data = try persistedDocumentDataIfPresent() else { return [] }
        let document: RemoteRunnerDocument
        do {
            document = try JSONDecoder().decode(RemoteRunnerDocument.self, from: data)
        } catch let error as RemoteExecutionError {
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

    private func persist(
        _ configurations: [RemoteRunnerConfiguration],
        previousDocument: Data?
    ) throws {
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
        if previousDocument == data {
            return
        }
        do {
            try writeData(data, fileURL)
        } catch let writeError {
            switch persistedDocumentState(expected: data, previous: previousDocument) {
            case .requested:
                // Rename visibility is not equivalent to parent-directory
                // durability. Preserve both generations because a reboot may
                // still reveal the previous document.
                throw RemoteRunnerStoreDurabilityError(
                    primaryError: writeError,
                    state: .requestedVisible
                )
            case .uncertain:
                throw RemoteRunnerStoreDurabilityError(
                    primaryError: writeError,
                    state: .uncertain
                )
            case .previous:
                throw writeError
            }
        }
    }

    private enum PersistedDocumentState {
        case requested
        case previous
        case uncertain
    }

    private func persistedDocumentState(
        expected: Data?,
        previous: Data?
    ) -> PersistedDocumentState {
        do {
            let current = try persistedDocumentDataIfPresent()
            if current == expected { return .requested }
            if current == previous { return .previous }
            // A third-party version is neither safely compensable nor a
            // confirmed commit of this request.
            return .uncertain
        } catch {
            return .uncertain
        }
    }

    private func persistedDocumentDataIfPresent() throws -> Data? {
        var metadata = stat()
        if Darwin.lstat(fileURL.path, &metadata) == 0 {
            return try Self.readBoundedRegularFile(fileURL)
        }
        guard errno == ENOENT else { throw currentPOSIXError() }
        return nil
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func withExclusiveSettingsLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let parent = fileURL.standardizedFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(parentDescriptor) }

        let lockName = ".\(fileURL.lastPathComponent).lock"
        let lockDescriptor = Darwin.openat(
            parentDescriptor,
            lockName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY,
            mode_t(0o600)
        )
        guard lockDescriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(lockDescriptor) }
        var metadata = stat()
        guard Darwin.fstat(lockDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else {
            throw currentPOSIXError()
        }

        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while Darwin.fcntl(lockDescriptor, F_SETLK, &lock) != 0 {
            if errno == EINTR { continue }
            if errno == EACCES || errno == EAGAIN {
                if Task.isCancelled { throw CancellationError() }
                guard ContinuousClock.now < deadline else {
                    throw POSIXError(.EBUSY)
                }
                Darwin.usleep(10_000)
                continue
            }
            throw currentPOSIXError()
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(lockDescriptor, F_SETLK, &lock)
        }
        return try operation()
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
