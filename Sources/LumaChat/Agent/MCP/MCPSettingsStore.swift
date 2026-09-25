import Foundation
import Darwin

protocol MCPSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

struct MCPSettingsStoreRecoveryFailure: Sendable {
    let account: String
    let underlyingError: any Error
}

struct MCPSettingsStoreTransactionError: LocalizedError, Sendable {
    enum Operation: String, Sendable {
        case save
        case deleteAll = "delete all"
    }

    let operation: Operation
    let primaryError: any Error
    let recoveryFailures: [MCPSettingsStoreRecoveryFailure]

    var errorDescription: String? {
        "MCP settings \(operation.rawValue) failed, and credential rollback failed for "
            + "\(recoveryFailures.count) account(s). Persisted settings and Keychain state "
            + "may differ; no credential values are included in this diagnostic."
    }
}

/// The writer reported a durability error after the attempted atomic change.
/// Even when exact readback currently matches the request, a failed directory
/// fsync may allow metadata to roll back after a crash. Both credential
/// generations are therefore retained and callers must treat the outcome as
/// durability-uncertain.
struct MCPSettingsStoreDurabilityError: LocalizedError, Sendable {
    let primaryError: any Error

    var errorDescription: String? {
        "MCP settings filesystem durability could not be confirmed. Old and new "
            + "credential generations were retained so either crash-recovery state remains usable."
    }
}

/// The requested metadata is already authoritative, but one or more obsolete
/// Keychain entries could not be garbage-collected. This never means the
/// committed document should be rolled back: its versioned references still
/// resolve to the requested credentials.
struct MCPSettingsStoreCredentialCleanupError: LocalizedError, Sendable {
    let operation: MCPSettingsStoreTransactionError.Operation
    let failures: [MCPSettingsStoreRecoveryFailure]

    var errorDescription: String? {
        "MCP settings \(operation.rawValue) was committed, but "
            + "\(failures.count) obsolete credential account(s) could not be removed. "
            + "The committed settings remain usable; no credential values are included in this diagnostic."
    }
}

struct MCPKeychainSecretStore: MCPSecretStore {
    private let keychain = KeychainStore(service: "LumaChat.MCPSecrets")

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

actor MCPSettingsStore {
    static let defaultFileURL = AppPaths.appSupport
        .appendingPathComponent("MCP", isDirectory: true)
        .appendingPathComponent("servers.json")

    /// Version 1 documents used a fixed marker and derived the Keychain account
    /// solely from the server/field identity. Keep accepting that representation
    /// so existing installations migrate on their next successful save.
    private static let legacySecretMarker = "${LUMACHAT_MCP_KEYCHAIN}"
    private static let versionedSecretMarkerPrefix = "${LUMACHAT_MCP_KEYCHAIN:"
    private static let versionedSecretMarkerSuffix = "}"
    private static let maximumSettingsBytes = 4 * 1_024 * 1_024
    private static let processTransactionLock = NSLock()

    private let fileURL: URL
    private let fileManager: FileManager
    private let secretStore: any MCPSecretStore
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let removeData: @Sendable (URL) throws -> Void

    init(
        fileURL: URL = MCPSettingsStore.defaultFileURL,
        fileManager: FileManager = .default,
        secretStore: any MCPSecretStore = MCPKeychainSecretStore(),
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            try AtomicFileWriter.write($0, to: $1)
        },
        removeData: @escaping @Sendable (URL) throws -> Void = {
            try MCPSettingsStore.removeRegularFileDurably(at: $0)
        }
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.secretStore = secretStore
        self.writeData = writeData
        self.removeData = removeData
    }

    func load() throws -> [MCPServerConfiguration] {
        try withExclusiveSettingsLock { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> [MCPServerConfiguration] {
        guard let data = try persistedDocumentDataIfPresent() else { return [] }
        let persisted = try JSONDecoder().decode(
            MCPPersistedSettings.self,
            from: data
        )
        guard persisted.version == 1 else {
            throw MCPError.invalidConfiguration("MCP settings use an unsupported version.")
        }
        guard persisted.servers.count <= 200 else {
            throw MCPError.invalidConfiguration("MCP settings exceed the 200-server limit.")
        }
        try validateUniqueServerIDs(persisted.servers)
        var hydrated: [MCPServerConfiguration] = []
        hydrated.reserveCapacity(persisted.servers.count)
        for server in persisted.servers {
            hydrated.append(try hydrateSecrets(server))
        }
        return hydrated
    }

    func save(_ servers: [MCPServerConfiguration]) throws {
        try withExclusiveSettingsLock { try saveUnlocked(servers) }
    }

    private func saveUnlocked(_ servers: [MCPServerConfiguration]) throws {
        guard servers.count <= 200 else {
            throw MCPError.invalidConfiguration("MCP settings exceed the 200-server limit.")
        }
        try validateUniqueServerIDs(servers)
        // A malformed or unreadable previous document must stop the transaction.
        // Treating it as reference-free can orphan credentials and overwrite the
        // only durable record that identifies them.
        let previousDocument = try persistedDocumentDataIfPresent()
        let previousReferences = try persistedSecretReferences(in: previousDocument)
        var newReferences = Set<String>()
        var createdReferences = Set<String>()
        var storedServers: [MCPServerConfiguration] = []
        let encoded: Data

        do {
            for server in servers {
                let protected = try protectSecrets(
                    in: server,
                    references: &newReferences,
                    createdReferences: &createdReferences
                )
                storedServers.append(protected)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let document = MCPPersistedSettings(version: 1, servers: storedServers)
            encoded = try encoder.encode(document)
            guard encoded.count <= Self.maximumSettingsBytes else {
                throw MCPError.invalidConfiguration("MCP settings exceed the 4 MiB limit.")
            }
        } catch {
            // Every write uses a fresh account, so failure recovery only removes
            // accounts that no committed document can reference. The previous
            // document and its credentials are never mutated before commit.
            throw recoveryFailure(
                operation: .save,
                primaryError: error,
                accountsToDelete: createdReferences
            )
        }

        // A document without secrets may be byte-identical. Versioned markers
        // make every credential-bearing update distinct by construction.
        if previousDocument == encoded { return }
        do {
            try writeData(encoded, fileURL)
        } catch {
            switch persistedDocumentState(expected: encoded, previous: previousDocument) {
            case .requested, .uncertain:
                // Exact readback cannot prove crash durability when rename or
                // parent-directory fsync reported an error. A restart could
                // expose either generation (or a third state), so keep both.
                throw MCPSettingsStoreDurabilityError(primaryError: error)
            case .previous:
                throw recoveryFailure(
                    operation: .save,
                    primaryError: error,
                    accountsToDelete: createdReferences
                )
            }
        }

        // Metadata is committed before old credentials are removed. A crash at
        // any point therefore leaves either a fully usable old document or a
        // fully usable new one; cleanup failure can only leave an orphan.
        try removeObsoleteReferences(
            previousReferences.subtracting(newReferences),
            operation: .save
        )
    }

    func deleteAll() throws {
        try withExclusiveSettingsLock { try deleteAllUnlocked() }
    }

    private func deleteAllUnlocked() throws {
        let previousDocument = try persistedDocumentDataIfPresent()
        let references = try persistedSecretReferences(in: previousDocument)
        guard previousDocument != nil else { return }
        do {
            // Removing the metadata is the commit point. Credentials are only
            // garbage-collected afterward, so a crash can create an orphan but
            // can never leave live metadata pointing at a deleted credential.
            try removeData(fileURL)
        } catch {
            switch persistedDocumentState(expected: nil, previous: previousDocument) {
            case .requested, .uncertain:
                // Visible absence after an unlink/fsync error is not necessarily
                // crash-durable. Retain the old generation in case metadata
                // reappears after restart.
                throw MCPSettingsStoreDurabilityError(primaryError: error)
            case .previous:
                throw error
            }
        }
        try removeObsoleteReferences(references, operation: .deleteAll)
    }

    /// Decodes the conventional `mcpServers` JSON document without persisting
    /// it. Call `save` after the user has reviewed imported commands and URLs.
    func decodeImport(_ data: Data) throws -> [MCPServerConfiguration] {
        guard data.count <= Self.maximumSettingsBytes else {
            throw MCPError.invalidConfiguration("Imported MCP JSON exceeds the 4 MiB limit.")
        }
        let servers = try JSONDecoder().decode(MCPConfigurationDocument.self, from: data).servers
        try validateUniqueServerIDs(servers)
        return servers
    }

    /// Imports and persists configurations. Matching names retain their UUID so
    /// existing Keychain references and UI identity remain stable.
    @discardableResult
    func importAndSave(_ data: Data, merge: Bool = true) throws -> [MCPServerConfiguration] {
        try withExclusiveSettingsLock {
            var imported = try decodeImport(data)
            guard merge else {
                try saveUnlocked(imported)
                return imported
            }

            var merged = try loadUnlocked()
            for index in imported.indices {
                if let existingIndex = merged.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(imported[index].name) == .orderedSame
                }) {
                    imported[index].id = merged[existingIndex].id
                    merged[existingIndex] = imported[index]
                } else {
                    merged.append(imported[index])
                }
            }
            try saveUnlocked(merged)
            return merged
        }
    }

    private func protectSecrets(
        in original: MCPServerConfiguration,
        references: inout Set<String>,
        createdReferences: inout Set<String>
    ) throws -> MCPServerConfiguration {
        var server = original
        switch server.transport {
        case .stdio(var configuration):
            // Environment values frequently contain DSNs or opaque credentials
            // whose key names are not predictable. Protect every non-empty
            // configured value; JSON retains only its key and a marker.
            for key in configuration.environment.keys.sorted() {
                guard let value = configuration.environment[key], !value.isEmpty else { continue }
                let account = try saveFreshSecret(
                    value,
                    legacyAccount: secretAccount(serverID: server.id, scope: "env", key: key),
                    createdReferences: &createdReferences
                )
                references.insert(account)
                configuration.environment[key] = marker(for: account)
            }
            var nextArgumentIsSensitive = false
            for index in configuration.arguments.indices {
                let argument = configuration.arguments[index]
                let legacyAccount = secretAccount(
                    serverID: server.id,
                    scope: "arg",
                    key: String(index)
                )
                if nextArgumentIsSensitive {
                    let account = try saveFreshSecret(
                        argument,
                        legacyAccount: legacyAccount,
                        createdReferences: &createdReferences
                    )
                    references.insert(account)
                    configuration.arguments[index] = marker(for: account)
                    nextArgumentIsSensitive = false
                    continue
                }
                if let separator = argument.firstIndex(of: "=") {
                    let name = String(argument[..<separator])
                    if isSensitiveArgumentName(name) {
                        let value = String(argument[argument.index(after: separator)...])
                        let account = try saveFreshSecret(
                            value,
                            legacyAccount: legacyAccount,
                            createdReferences: &createdReferences
                        )
                        references.insert(account)
                        configuration.arguments[index] = name + "=" + marker(for: account)
                        continue
                    }
                }
                if isSensitiveArgumentName(argument) {
                    nextArgumentIsSensitive = true
                } else if SecretRedactor().redact(argument) != argument {
                    let account = try saveFreshSecret(
                        argument,
                        legacyAccount: legacyAccount,
                        createdReferences: &createdReferences
                    )
                    references.insert(account)
                    configuration.arguments[index] = marker(for: account)
                }
            }
            server.transport = .stdio(configuration)
        case .streamableHTTP(var configuration):
            try MCPHTTPPolicy.validate(configuration.endpoint)
            // Header values are credentials often enough that persisting all of
            // them in Keychain is safer than relying on a header-name allowlist.
            for key in configuration.headers.keys.sorted() {
                guard let value = configuration.headers[key], !value.isEmpty else { continue }
                let account = try saveFreshSecret(
                    value,
                    legacyAccount: secretAccount(serverID: server.id, scope: "header", key: key),
                    createdReferences: &createdReferences
                )
                references.insert(account)
                configuration.headers[key] = marker(for: account)
            }
            server.transport = .streamableHTTP(configuration)
        }
        return server
    }

    private func hydrateSecrets(_ original: MCPServerConfiguration) throws -> MCPServerConfiguration {
        var server = original
        switch server.transport {
        case .stdio(var configuration):
            for (key, persistedValue) in Array(configuration.environment) {
                let legacyAccount = secretAccount(serverID: server.id, scope: "env", key: key)
                guard let account = try referencedAccount(
                    in: persistedValue,
                    legacyAccount: legacyAccount
                ) else { continue }
                if let value = try secretStore.load(account: account) {
                    configuration.environment[key] = value
                } else {
                    throw missingPersistedSecretError()
                }
            }
            for index in configuration.arguments.indices {
                let argument = configuration.arguments[index]
                let legacyAccount = secretAccount(serverID: server.id, scope: "arg", key: String(index))
                if let account = try referencedAccount(in: argument, legacyAccount: legacyAccount) {
                    if let value = try secretStore.load(account: account) {
                        configuration.arguments[index] = value
                    } else {
                        throw missingPersistedSecretError()
                    }
                } else if let separator = argument.firstIndex(of: "=") {
                    let name = String(argument[..<separator])
                    let persistedValue = String(argument[argument.index(after: separator)...])
                    guard let account = try referencedAccount(
                        in: persistedValue,
                        legacyAccount: legacyAccount
                    ) else { continue }
                    if let value = try secretStore.load(account: account) {
                        configuration.arguments[index] = name + "=" + value
                    } else {
                        throw missingPersistedSecretError()
                    }
                }
            }
            server.transport = .stdio(configuration)
        case .streamableHTTP(var configuration):
            for (key, persistedValue) in Array(configuration.headers) {
                let legacyAccount = secretAccount(serverID: server.id, scope: "header", key: key)
                guard let account = try referencedAccount(
                    in: persistedValue,
                    legacyAccount: legacyAccount
                ) else { continue }
                if let value = try secretStore.load(account: account) {
                    configuration.headers[key] = value
                } else {
                    throw missingPersistedSecretError()
                }
            }
            server.transport = .streamableHTTP(configuration)
        }
        return server
    }

    private func persistedSecretReferences(in data: Data?) throws -> Set<String> {
        guard let data else { return [] }
        let persisted = try JSONDecoder().decode(
            MCPPersistedSettings.self,
            from: data
        )
        guard persisted.version == 1 else {
            throw MCPError.invalidConfiguration("MCP settings use an unsupported version.")
        }
        guard persisted.servers.count <= 200 else {
            throw MCPError.invalidConfiguration("MCP settings exceed the 200-server limit.")
        }
        try validateUniqueServerIDs(persisted.servers)
        var references = Set<String>()
        for server in persisted.servers {
            switch server.transport {
            case .stdio(let configuration):
                for (key, value) in configuration.environment {
                    let legacyAccount = secretAccount(serverID: server.id, scope: "env", key: key)
                    if let account = try referencedAccount(in: value, legacyAccount: legacyAccount) {
                        references.insert(account)
                    }
                }
                for (index, argument) in configuration.arguments.enumerated() {
                    let legacyAccount = secretAccount(
                        serverID: server.id,
                        scope: "arg",
                        key: String(index)
                    )
                    if let account = try referencedAccount(
                        in: argument,
                        legacyAccount: legacyAccount
                    ) {
                        references.insert(account)
                    } else if let separator = argument.firstIndex(of: "=") {
                        let persistedValue = String(argument[argument.index(after: separator)...])
                        if let account = try referencedAccount(
                            in: persistedValue,
                            legacyAccount: legacyAccount
                        ) {
                            references.insert(account)
                        }
                    }
                }
            case .streamableHTTP(let configuration):
                for (key, value) in configuration.headers {
                    let legacyAccount = secretAccount(serverID: server.id, scope: "header", key: key)
                    if let account = try referencedAccount(in: value, legacyAccount: legacyAccount) {
                        references.insert(account)
                    }
                }
            }
        }
        return references
    }

    private func recoveryFailure(
        operation: MCPSettingsStoreTransactionError.Operation,
        primaryError: any Error,
        accountsToDelete: Set<String>
    ) -> any Error {
        var recoveryFailures: [MCPSettingsStoreRecoveryFailure] = []
        for account in accountsToDelete.sorted() {
            do {
                try secretStore.delete(account: account)
            } catch {
                recoveryFailures.append(MCPSettingsStoreRecoveryFailure(
                    account: account,
                    underlyingError: error
                ))
            }
        }
        guard !recoveryFailures.isEmpty else { return primaryError }
        return MCPSettingsStoreTransactionError(
            operation: operation,
            primaryError: primaryError,
            recoveryFailures: recoveryFailures
        )
    }

    private func removeObsoleteReferences(
        _ references: Set<String>,
        operation: MCPSettingsStoreTransactionError.Operation
    ) throws {
        var failures: [MCPSettingsStoreRecoveryFailure] = []
        for account in references.sorted() {
            do {
                try secretStore.delete(account: account)
            } catch {
                failures.append(MCPSettingsStoreRecoveryFailure(
                    account: account,
                    underlyingError: error
                ))
            }
        }
        guard !failures.isEmpty else { return }
        throw MCPSettingsStoreCredentialCleanupError(
            operation: operation,
            failures: failures
        )
    }

    private func saveFreshSecret(
        _ value: String,
        legacyAccount: String,
        createdReferences: inout Set<String>
    ) throws -> String {
        let account = legacyAccount + "|v|" + UUID().uuidString.lowercased()
        // Register before the write. A provider that mutates and then throws is
        // still safely compensated because this account generation was never
        // reachable from the previous document.
        createdReferences.insert(account)
        try secretStore.save(value, account: account)
        return account
    }

    private func marker(for account: String) -> String {
        let encoded = Data(account.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.versionedSecretMarkerPrefix + encoded + Self.versionedSecretMarkerSuffix
    }

    /// Resolves either the legacy fixed marker or a versioned marker. Versioned
    /// references are constrained to the exact logical field account so a
    /// tampered settings document cannot read or garbage-collect an unrelated
    /// Keychain item.
    private func referencedAccount(
        in persistedValue: String,
        legacyAccount: String
    ) throws -> String? {
        if persistedValue == Self.legacySecretMarker { return legacyAccount }
        guard persistedValue.hasPrefix("${LUMACHAT_MCP_KEYCHAIN") else { return nil }
        guard persistedValue.hasPrefix(Self.versionedSecretMarkerPrefix),
              persistedValue.hasSuffix(Self.versionedSecretMarkerSuffix) else {
            throw invalidPersistedSecretReferenceError()
        }
        let payloadStart = persistedValue.index(
            persistedValue.startIndex,
            offsetBy: Self.versionedSecretMarkerPrefix.count
        )
        let payloadEnd = persistedValue.index(
            persistedValue.endIndex,
            offsetBy: -Self.versionedSecretMarkerSuffix.count
        )
        let payload = String(persistedValue[payloadStart..<payloadEnd])
        guard !payload.isEmpty else { throw invalidPersistedSecretReferenceError() }
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64),
              let account = String(data: data, encoding: .utf8) else {
            throw invalidPersistedSecretReferenceError()
        }
        let expectedPrefix = legacyAccount + "|v|"
        guard account.hasPrefix(expectedPrefix) else {
            throw invalidPersistedSecretReferenceError()
        }
        let generation = String(account.dropFirst(expectedPrefix.count))
        guard let identifier = UUID(uuidString: generation),
              identifier.uuidString.lowercased() == generation.lowercased() else {
            throw invalidPersistedSecretReferenceError()
        }
        return account
    }

    private func missingPersistedSecretError() -> MCPError {
        MCPError.invalidConfiguration(
            "A persisted Keychain credential reference cannot be resolved."
        )
    }

    private func invalidPersistedSecretReferenceError() -> MCPError {
        MCPError.invalidConfiguration(
            "A persisted Keychain credential reference is invalid."
        )
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
            return .uncertain
        } catch {
            return .uncertain
        }
    }

    private func persistedDocumentDataIfPresent() throws -> Data? {
        var metadata = stat()
        if Darwin.lstat(fileURL.path, &metadata) == 0 {
            return try readPersistedData()
        }
        guard errno == ENOENT else { throw currentPOSIXError() }
        return nil
    }

    private func validateUniqueServerIDs(_ servers: [MCPServerConfiguration]) throws {
        var identifiers = Set<UUID>()
        guard servers.allSatisfy({ identifiers.insert($0.id).inserted }) else {
            throw MCPError.invalidConfiguration(
                "MCP settings contain duplicate server identifiers."
            )
        }
    }

    private func readPersistedData() throws -> Data {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MCPError.invalidConfiguration("MCP settings must be a regular file no larger than 4 MiB.")
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumSettingsBytes else {
            throw MCPError.invalidConfiguration("MCP settings must be a regular file no larger than 4 MiB.")
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remaining
                )
            }
            guard count > 0 else {
                throw MCPError.invalidConfiguration("MCP settings changed while being read.")
            }
            offset += count
        }
        var trailing: UInt8 = 0
        guard Darwin.read(descriptor, &trailing, 1) == 0 else {
            throw MCPError.invalidConfiguration("MCP settings exceed the 4 MiB limit.")
        }
        return data
    }

    private func withExclusiveSettingsLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let parent = fileURL.standardizedFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
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

    /// Removes only the expected regular settings file relative to an opened,
    /// non-symbolic-link parent directory and durably records the unlink.
    private nonisolated static func removeRegularFileDurably(at fileURL: URL) throws {
        let fileURL = fileURL.standardizedFileURL
        let parent = fileURL.deletingLastPathComponent()
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              fileURL.path != "/",
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw POSIXError(.EINVAL)
        }
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(parentDescriptor) }

        var metadata = stat()
        guard Darwin.fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else {
            throw currentPOSIXError()
        }
        guard Darwin.unlinkat(parentDescriptor, name, 0) == 0,
              Darwin.fsync(parentDescriptor) == 0 else {
            throw currentPOSIXError()
        }
    }

    private nonisolated static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func currentPOSIXError() -> POSIXError {
        Self.currentPOSIXError()
    }

    private func isSensitiveArgumentName(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return [
            "key", "api_key", "apikey", "token", "password", "secret", "authorization",
            "credential", "private_key", "access_key"
        ].contains(where: normalized.contains)
    }

    private func secretAccount(serverID: UUID, scope: String, key: String) -> String {
        "mcp|\(serverID.uuidString.lowercased())|\(scope)|\(key)"
    }
}

private struct MCPPersistedSettings: Codable {
    var version: Int
    var servers: [MCPServerConfiguration]
}
