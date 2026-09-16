import Foundation
import Darwin

protocol MCPSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
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

    private static let secretMarker = "${LUMACHAT_MCP_KEYCHAIN}"
    private static let maximumSettingsBytes = 4 * 1_024 * 1_024

    private let fileURL: URL
    private let fileManager: FileManager
    private let secretStore: any MCPSecretStore

    init(
        fileURL: URL = MCPSettingsStore.defaultFileURL,
        fileManager: FileManager = .default,
        secretStore: any MCPSecretStore = MCPKeychainSecretStore()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.secretStore = secretStore
    }

    func load() throws -> [MCPServerConfiguration] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let persisted = try JSONDecoder().decode(
            MCPPersistedSettings.self,
            from: readPersistedData()
        )
        var hydrated: [MCPServerConfiguration] = []
        hydrated.reserveCapacity(persisted.servers.count)
        for server in persisted.servers {
            hydrated.append(try hydrateSecrets(server))
        }
        return hydrated
    }

    func save(_ servers: [MCPServerConfiguration]) throws {
        let previousReferences = (try? persistedSecretReferences()) ?? []
        var newReferences = Set<String>()
        var storedServers: [MCPServerConfiguration] = []
        var backups: [String: MCPSecretBackup] = [:]

        do {
            guard servers.count <= 200 else {
                throw MCPError.invalidConfiguration("MCP settings exceed the 200-server limit.")
            }
            for server in servers {
                let protected = try protectSecrets(
                    in: server,
                    references: &newReferences,
                    backups: &backups
                )
                storedServers.append(protected)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let document = MCPPersistedSettings(version: 1, servers: storedServers)
            let encoded = try encoder.encode(document)
            guard encoded.count <= Self.maximumSettingsBytes else {
                throw MCPError.invalidConfiguration("MCP settings exceed the 4 MiB limit.")
            }
            try AtomicFileWriter.write(encoded, to: fileURL)
        } catch {
            // Restore both newly-created and overwritten accounts so the old
            // atomic settings file can never point at half-updated credentials.
            for (account, backup) in backups {
                if let value = backup.value {
                    try? secretStore.save(value, account: account)
                } else {
                    try? secretStore.delete(account: account)
                }
            }
            throw error
        }

        for obsolete in previousReferences.subtracting(newReferences) {
            try? secretStore.delete(account: obsolete)
        }
    }

    func deleteAll() throws {
        let references = (try? persistedSecretReferences()) ?? []
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        for account in references { try? secretStore.delete(account: account) }
    }

    /// Decodes the conventional `mcpServers` JSON document without persisting
    /// it. Call `save` after the user has reviewed imported commands and URLs.
    func decodeImport(_ data: Data) throws -> [MCPServerConfiguration] {
        guard data.count <= Self.maximumSettingsBytes else {
            throw MCPError.invalidConfiguration("Imported MCP JSON exceeds the 4 MiB limit.")
        }
        return try JSONDecoder().decode(MCPConfigurationDocument.self, from: data).servers
    }

    /// Imports and persists configurations. Matching names retain their UUID so
    /// existing Keychain references and UI identity remain stable.
    @discardableResult
    func importAndSave(_ data: Data, merge: Bool = true) throws -> [MCPServerConfiguration] {
        var imported = try decodeImport(data)
        guard merge else {
            try save(imported)
            return imported
        }

        var merged = try load()
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
        try save(merged)
        return merged
    }

    private func protectSecrets(
        in original: MCPServerConfiguration,
        references: inout Set<String>,
        backups: inout [String: MCPSecretBackup]
    ) throws -> MCPServerConfiguration {
        var server = original
        switch server.transport {
        case .stdio(var configuration):
            // Environment values frequently contain DSNs or opaque credentials
            // whose key names are not predictable. Protect every non-empty
            // configured value; JSON retains only its key and a marker.
            for (key, value) in Array(configuration.environment) where !value.isEmpty {
                let account = secretAccount(serverID: server.id, scope: "env", key: key)
                try saveSecret(value, account: account, backups: &backups)
                references.insert(account)
                configuration.environment[key] = Self.secretMarker
            }
            var nextArgumentIsSensitive = false
            for index in configuration.arguments.indices {
                let argument = configuration.arguments[index]
                let account = secretAccount(serverID: server.id, scope: "arg", key: String(index))
                if nextArgumentIsSensitive {
                    try saveSecret(argument, account: account, backups: &backups)
                    references.insert(account)
                    configuration.arguments[index] = Self.secretMarker
                    nextArgumentIsSensitive = false
                    continue
                }
                if let separator = argument.firstIndex(of: "=") {
                    let name = String(argument[..<separator])
                    if isSensitiveArgumentName(name) {
                        let value = String(argument[argument.index(after: separator)...])
                        try saveSecret(value, account: account, backups: &backups)
                        references.insert(account)
                        configuration.arguments[index] = name + "=" + Self.secretMarker
                        continue
                    }
                }
                if isSensitiveArgumentName(argument) {
                    nextArgumentIsSensitive = true
                } else if SecretRedactor().redact(argument) != argument {
                    try saveSecret(argument, account: account, backups: &backups)
                    references.insert(account)
                    configuration.arguments[index] = Self.secretMarker
                }
            }
            server.transport = .stdio(configuration)
        case .streamableHTTP(var configuration):
            try MCPHTTPPolicy.validate(configuration.endpoint)
            // Header values are credentials often enough that persisting all of
            // them in Keychain is safer than relying on a header-name allowlist.
            for (key, value) in Array(configuration.headers) where !value.isEmpty {
                let account = secretAccount(serverID: server.id, scope: "header", key: key)
                try saveSecret(value, account: account, backups: &backups)
                references.insert(account)
                configuration.headers[key] = Self.secretMarker
            }
            server.transport = .streamableHTTP(configuration)
        }
        return server
    }

    private func hydrateSecrets(_ original: MCPServerConfiguration) throws -> MCPServerConfiguration {
        var server = original
        switch server.transport {
        case .stdio(var configuration):
            for (key, marker) in Array(configuration.environment) where marker == Self.secretMarker {
                let account = secretAccount(serverID: server.id, scope: "env", key: key)
                if let value = try secretStore.load(account: account) {
                    configuration.environment[key] = value
                } else {
                    configuration.environment.removeValue(forKey: key)
                }
            }
            for index in configuration.arguments.indices {
                let argument = configuration.arguments[index]
                let account = secretAccount(serverID: server.id, scope: "arg", key: String(index))
                if argument == Self.secretMarker {
                    if let value = try secretStore.load(account: account) {
                        configuration.arguments[index] = value
                    } else {
                        configuration.arguments[index] = ""
                    }
                } else if argument.hasSuffix("=" + Self.secretMarker),
                          let separator = argument.firstIndex(of: "=") {
                    let name = String(argument[..<separator])
                    if let value = try secretStore.load(account: account) {
                        configuration.arguments[index] = name + "=" + value
                    } else {
                        configuration.arguments[index] = name + "="
                    }
                }
            }
            server.transport = .stdio(configuration)
        case .streamableHTTP(var configuration):
            for (key, marker) in Array(configuration.headers) where marker == Self.secretMarker {
                let account = secretAccount(serverID: server.id, scope: "header", key: key)
                if let value = try secretStore.load(account: account) {
                    configuration.headers[key] = value
                } else {
                    configuration.headers.removeValue(forKey: key)
                }
            }
            server.transport = .streamableHTTP(configuration)
        }
        return server
    }

    private func persistedSecretReferences() throws -> Set<String> {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let persisted = try JSONDecoder().decode(
            MCPPersistedSettings.self,
            from: readPersistedData()
        )
        var references = Set<String>()
        for server in persisted.servers {
            switch server.transport {
            case .stdio(let configuration):
                for (key, value) in configuration.environment where value == Self.secretMarker {
                    references.insert(secretAccount(serverID: server.id, scope: "env", key: key))
                }
                for (index, argument) in configuration.arguments.enumerated()
                    where argument == Self.secretMarker || argument.hasSuffix("=" + Self.secretMarker) {
                    references.insert(
                        secretAccount(serverID: server.id, scope: "arg", key: String(index))
                    )
                }
            case .streamableHTTP(let configuration):
                for (key, value) in configuration.headers where value == Self.secretMarker {
                    references.insert(secretAccount(serverID: server.id, scope: "header", key: key))
                }
            }
        }
        return references
    }

    private func saveSecret(
        _ value: String,
        account: String,
        backups: inout [String: MCPSecretBackup]
    ) throws {
        if backups[account] == nil {
            backups[account] = MCPSecretBackup(value: try secretStore.load(account: account))
        }
        try secretStore.save(value, account: account)
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

    private func isSensitiveArgumentName(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return [
            "api_key", "apikey", "token", "password", "secret", "authorization",
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

private struct MCPSecretBackup {
    var value: String?
}
