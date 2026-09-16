import Darwin
import Foundation

protocol WorktreeRegistryPersisting: Sendable {
    func list() async throws -> [ManagedWorktreeRecord]
    func record(id: UUID) async throws -> ManagedWorktreeRecord?
    func save(_ record: ManagedWorktreeRecord) async throws
    func remove(id: UUID) async throws
}

struct ManagedWorktreeRegistryEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var records: [ManagedWorktreeRecord]

    init(version: Int = currentVersion, records: [ManagedWorktreeRecord]) {
        self.version = version
        self.records = records
    }
}

/// Synchronous, read-only authorization used by the filesystem boundary before
/// actor-backed services can be constructed. A UUID-looking directory is not a
/// capability: it must be the exact lowercase checkout path in the bounded,
/// no-follow registry and the record must still be usable.
enum ManagedWorktreeRegistryAuthorization {
    static func record(
        authorizing checkout: URL,
        registryFile: URL = AppPaths.managedWorktreeRegistryFile,
        managedRoot: URL = AppPaths.managedWorktrees
    ) -> ManagedWorktreeRecord? {
        let candidate = checkout.standardizedFileURL
        let root = managedRoot.standardizedFileURL
        guard let id = UUID(uuidString: candidate.lastPathComponent),
              candidate.lastPathComponent == id.uuidString.lowercased(),
              candidate.deletingLastPathComponent().path == root.path else {
            return nil
        }

        var checkoutInfo = Darwin.stat()
        guard Darwin.lstat(candidate.path, &checkoutInfo) == 0,
              checkoutInfo.st_mode & S_IFMT == S_IFDIR else { return nil }

        let descriptor = Darwin.open(
            registryFile.standardizedFileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(ManagedWorktreeLimits.maximumRegistryBytes) else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= ManagedWorktreeLimits.maximumRegistryBytes {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= ManagedWorktreeLimits.maximumRegistryBytes,
              let envelope = try? JSONDecoder().decode(
                ManagedWorktreeRegistryEnvelope.self,
                from: data
              ),
              envelope.version == ManagedWorktreeRegistryEnvelope.currentVersion,
              (try? ManagedWorktreeValidation.validate(
                records: envelope.records,
                managedRoot: root
              )) != nil,
              let record = envelope.records.first(where: {
                $0.id == id && $0.worktreePath == candidate.path
              }),
              record.state == .ready else {
            return nil
        }
        return record
    }
}

actor WorktreeRegistry: WorktreeRegistryPersisting {
    nonisolated let registryFileURL: URL
    nonisolated let managedRootURL: URL

    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        registryFile: URL = AppPaths.managedWorktreeRegistryFile,
        managedRoot: URL = AppPaths.managedWorktrees
    ) {
        self.fileManager = fileManager
        registryFileURL = registryFile.standardizedFileURL
        managedRootURL = managedRoot.standardizedFileURL
    }

    func list() throws -> [ManagedWorktreeRecord] {
        try prepareStorage()
        guard fileManager.fileExists(atPath: registryFileURL.path) else { return [] }

        let values = try registryFileURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ManagedWorktreeError.invalidRegistry("registry.json 不是安全的一般檔案。")
        }
        if let size = values.fileSize,
           size > ManagedWorktreeLimits.maximumRegistryBytes {
            throw ManagedWorktreeError.registryTooLarge(
                ManagedWorktreeLimits.maximumRegistryBytes
            )
        }
        let data = try Data(contentsOf: registryFileURL, options: [.mappedIfSafe])
        guard data.count <= ManagedWorktreeLimits.maximumRegistryBytes else {
            throw ManagedWorktreeError.registryTooLarge(
                ManagedWorktreeLimits.maximumRegistryBytes
            )
        }

        let envelope: ManagedWorktreeRegistryEnvelope
        do {
            envelope = try JSONDecoder().decode(
                ManagedWorktreeRegistryEnvelope.self,
                from: data
            )
        } catch {
            throw ManagedWorktreeError.invalidRegistry("registry.json 無法解碼。")
        }
        guard envelope.version == ManagedWorktreeRegistryEnvelope.currentVersion else {
            throw ManagedWorktreeError.invalidRegistry(
                "不支援 registry version \(envelope.version)。"
            )
        }
        try ManagedWorktreeValidation.validate(
            records: envelope.records,
            managedRoot: managedRootURL
        )
        return envelope.records.sorted(by: Self.sortRecords)
    }

    func record(id: UUID) throws -> ManagedWorktreeRecord? {
        try list().first(where: { $0.id == id })
    }

    func save(_ record: ManagedWorktreeRecord) throws {
        var records = try list()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try write(records)
    }

    func remove(id: UUID) throws {
        var records = try list()
        records.removeAll(where: { $0.id == id })
        try write(records)
    }

    private func write(_ records: [ManagedWorktreeRecord]) throws {
        try prepareStorage()
        let sorted = records.sorted(by: Self.sortRecords)
        try ManagedWorktreeValidation.validate(records: sorted, managedRoot: managedRootURL)
        let envelope = ManagedWorktreeRegistryEnvelope(records: sorted)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= ManagedWorktreeLimits.maximumRegistryBytes else {
            throw ManagedWorktreeError.registryTooLarge(
                ManagedWorktreeLimits.maximumRegistryBytes
            )
        }
        try AtomicFileWriter.write(data, to: registryFileURL)
        guard Darwin.chmod(registryFileURL.path, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func prepareStorage() throws {
        try validateStorageURL(registryFileURL, mayBeFile: true, label: "registry")
        let parent = registryFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try validateDirectory(parent, label: "registry parent")
        try fileManager.createDirectory(at: managedRootURL, withIntermediateDirectories: true)
        try validateDirectory(managedRootURL, label: "managed root")
        _ = Darwin.chmod(parent.path, mode_t(0o700))
        _ = Darwin.chmod(managedRootURL.path, mode_t(0o700))
    }

    private func validateStorageURL(
        _ url: URL,
        mayBeFile: Bool,
        label: String
    ) throws {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path != "/",
              url.path.utf8.count <= ManagedWorktreeLimits.maximumPathBytes else {
            throw ManagedWorktreeError.unsafeManagedRoot("\(label) path 無效。")
        }
        var info = Darwin.stat()
        if Darwin.lstat(url.path, &info) == 0 {
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK || (!mayBeFile && kind != S_IFDIR) {
                throw ManagedWorktreeError.unsafeManagedRoot("\(label) 是 symlink 或非目錄。")
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func validateDirectory(_ url: URL, label: String) throws {
        try validateStorageURL(url, mayBeFile: false, label: label)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw ManagedWorktreeError.unsafeManagedRoot("\(label) 不是目錄。")
        }
    }

    private static func sortRecords(
        _ lhs: ManagedWorktreeRecord,
        _ rhs: ManagedWorktreeRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
