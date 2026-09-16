import CryptoKit
import Darwin
import Foundation

struct WorktreeStateRecoveryReference: Codable, Equatable, Sendable {
    var transactionID: UUID
    var relativePath: String
    var byteCount: Int
    var sha256: String
    var snapshotFingerprint: String
}

enum WorktreeStateRecoveryStoreError: LocalizedError, Equatable {
    case invalidReference(String)
    case invalidSnapshot(String)
    case invalidStorage(String)
    case oversized(Int)
    case integrityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidReference(let detail):
            return "Worktree recovery reference is invalid: \(detail)"
        case .invalidSnapshot(let detail):
            return "Worktree recovery snapshot is invalid: \(detail)"
        case .invalidStorage(let detail):
            return "Worktree recovery storage is invalid: \(detail)"
        case .oversized(let maximum):
            return "Worktree recovery snapshot exceeds \(maximum) bytes."
        case .integrityMismatch(let detail):
            return "Worktree recovery snapshot integrity check failed: \(detail)"
        }
    }
}

/// Durable, content-addressed rollback state for a handoff transaction.
///
/// Files are installed without following links and without replacing an
/// existing transaction. A journal stores only the returned reference, so a
/// recovery attempt verifies the filename, exact byte count, SHA-256 digest,
/// schema, transaction identity and logical snapshot fingerprint before any
/// of the decoded state can be used.
actor WorktreeStateRecoveryStore {
    static let schemaVersion = 1
    static let fileExtension = "snapshot"

    /// Two bounded patches, one bounded supplemental payload, the bounded path
    /// list, and a small allowance for the binary-property-list structure.
    static let maximumEncodedBytes = (2 * WorktreeStateMigrator.maximumPatchBytes)
        + WorktreeStateMigrator.maximumSupplementalBytes
        + WorktreeStateMigrator.maximumPathListBytes
        + (16 * 1_024 * 1_024)

    private let fileManager: FileManager
    private let root: URL
    private let encodedByteLimit: Int

    init(
        fileManager: FileManager = .default,
        root: URL = AppPaths.appSupport.appendingPathComponent(
            "AgentHandoffRecovery",
            isDirectory: true
        ),
        maximumEncodedBytes: Int = WorktreeStateRecoveryStore.maximumEncodedBytes
    ) {
        self.fileManager = fileManager
        self.root = root.standardizedFileURL
        self.encodedByteLimit = min(
            max(1, maximumEncodedBytes),
            Self.maximumEncodedBytes
        )
    }

    func save(
        snapshot: WorktreeStateSnapshot,
        transactionID: UUID
    ) throws -> WorktreeStateRecoveryReference {
        try Self.validate(snapshot)
        let fingerprint = snapshot.fingerprint
        guard Self.isDigest(fingerprint) else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "fingerprint is not a SHA-256 digest"
            )
        }

        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            transactionID: transactionID,
            snapshotFingerprint: fingerprint,
            snapshot: SnapshotPayload(snapshot)
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "encoding failed: \(error.localizedDescription)"
            )
        }
        guard !data.isEmpty, data.count <= encodedByteLimit else {
            throw WorktreeStateRecoveryStoreError.oversized(encodedByteLimit)
        }

        let reference = WorktreeStateRecoveryReference(
            transactionID: transactionID,
            relativePath: Self.fileName(for: transactionID),
            byteCount: data.count,
            sha256: Self.digestHex(data),
            snapshotFingerprint: fingerprint
        )
        try validate(reference)

        let rootDescriptor = try openRoot()
        defer { _ = Darwin.close(rootDescriptor) }
        try installExclusively(
            data,
            named: reference.relativePath,
            below: rootDescriptor
        )
        return reference
    }

    func load(_ reference: WorktreeStateRecoveryReference) throws -> WorktreeStateSnapshot {
        try validate(reference)
        let rootDescriptor = try openRoot()
        defer { _ = Darwin.close(rootDescriptor) }
        let stored = try readRegularFile(
            named: reference.relativePath,
            below: rootDescriptor,
            expectedBytes: reference.byteCount
        )
        guard Self.digestHex(stored.data) == reference.sha256 else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch("SHA-256 digest differs")
        }

        let envelope: Envelope
        do {
            envelope = try PropertyListDecoder().decode(Envelope.self, from: stored.data)
        } catch {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "payload or schema cannot be decoded"
            )
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch("schema version differs")
        }
        guard envelope.transactionID == reference.transactionID else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch("transaction ID differs")
        }
        guard envelope.snapshotFingerprint == reference.snapshotFingerprint,
              Self.isDigest(envelope.snapshotFingerprint) else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "stored fingerprint differs from the journal reference"
            )
        }

        let snapshot = try envelope.snapshot.materialize()
        try Self.validate(snapshot)
        guard snapshot.fingerprint == reference.snapshotFingerprint else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "decoded snapshot fingerprint differs"
            )
        }
        return snapshot
    }

    /// Removal is idempotent, but a present path is unlinked only after its
    /// size, digest and inode have been proven to be the exact referenced file.
    func remove(_ reference: WorktreeStateRecoveryReference) throws {
        try validate(reference)
        let rootDescriptor = try openRoot()
        defer { _ = Darwin.close(rootDescriptor) }

        var pathInfo = Darwin.stat()
        guard Darwin.fstatat(
            rootDescriptor,
            reference.relativePath,
            &pathInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT { return }
            throw Self.storageError("inspect recovery file")
        }
        guard pathInfo.st_mode & S_IFMT == S_IFREG else {
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "recovery path is not a regular file"
            )
        }

        let stored = try readRegularFile(
            named: reference.relativePath,
            below: rootDescriptor,
            expectedBytes: reference.byteCount
        )
        guard Self.digestHex(stored.data) == reference.sha256 else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "refusing to remove content with a different digest"
            )
        }

        var currentInfo = Darwin.stat()
        guard Darwin.fstatat(
            rootDescriptor,
            reference.relativePath,
            &currentInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              currentInfo.st_mode & S_IFMT == S_IFREG,
              UInt64(currentInfo.st_dev) == stored.device,
              UInt64(currentInfo.st_ino) == stored.inode,
              currentInfo.st_size == off_t(reference.byteCount) else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "recovery file changed before removal"
            )
        }
        guard Darwin.unlinkat(rootDescriptor, reference.relativePath, 0) == 0 else {
            throw Self.storageError("remove recovery file")
        }
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw Self.storageError("synchronize recovery directory")
        }
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var transactionID: UUID
        var snapshotFingerprint: String
        var snapshot: SnapshotPayload
    }

    /// The manifest intentionally stores regular-file metadata without a
    /// second copy of its bytes. `supplementalFiles` carries the bounded bytes,
    /// and materialization joins the two representations by validated path.
    private struct SnapshotPayload: Codable {
        var sourceRootPath: String
        var headObjectID: String
        var symbolicReference: String?
        var workingTreePatch: Data
        var stagedPatch: Data
        var supplementalFiles: [FilePayload]
        var supplementalManifest: [ManifestPayload]
        var supplementalRoots: [String]

        init(_ snapshot: WorktreeStateSnapshot) {
            sourceRootPath = snapshot.sourceRootPath
            headObjectID = snapshot.headObjectID
            symbolicReference = snapshot.symbolicReference
            workingTreePatch = snapshot.workingTreePatch
            stagedPatch = snapshot.stagedPatch
            supplementalFiles = snapshot.supplementalFiles.map(FilePayload.init)
            supplementalManifest = snapshot.supplementalManifest.map(ManifestPayload.init)
            supplementalRoots = snapshot.supplementalRoots
        }

        func materialize() throws -> WorktreeStateSnapshot {
            let files = supplementalFiles.map { file in
                WorktreeSupplementalFile(
                    relativePath: file.relativePath,
                    data: file.data,
                    permissions: file.permissions
                )
            }
            var fileData: [String: FilePayload] = [:]
            for file in supplementalFiles {
                guard fileData.updateValue(file, forKey: file.relativePath) == nil else {
                    throw WorktreeStateRecoveryStoreError.integrityMismatch(
                        "duplicate supplemental file path"
                    )
                }
            }
            let manifest = try supplementalManifest.map { entry -> WorktreeSupplementalPath in
                guard let kind = WorktreeSupplementalPathKind(rawValue: entry.kind) else {
                    throw WorktreeStateRecoveryStoreError.integrityMismatch(
                        "unknown supplemental path kind"
                    )
                }
                let data = kind == .regularFile ? fileData[entry.relativePath]?.data : nil
                return WorktreeSupplementalPath(
                    relativePath: entry.relativePath,
                    kind: kind,
                    data: data,
                    permissions: entry.permissions
                )
            }
            return WorktreeStateSnapshot(
                sourceRootPath: sourceRootPath,
                headObjectID: headObjectID,
                symbolicReference: symbolicReference,
                workingTreePatch: workingTreePatch,
                stagedPatch: stagedPatch,
                supplementalFiles: files,
                supplementalManifest: manifest,
                supplementalRoots: supplementalRoots
            )
        }
    }

    private struct FilePayload: Codable {
        var relativePath: String
        var data: Data
        var permissions: Int

        init(_ file: WorktreeSupplementalFile) {
            relativePath = file.relativePath
            data = file.data
            permissions = file.permissions
        }
    }

    private struct ManifestPayload: Codable {
        var relativePath: String
        var kind: String
        var permissions: Int?

        init(_ path: WorktreeSupplementalPath) {
            relativePath = path.relativePath
            kind = path.kind.rawValue
            permissions = path.permissions
        }
    }

    private struct StoredFile {
        var data: Data
        var device: UInt64
        var inode: UInt64
    }

    private func validate(_ reference: WorktreeStateRecoveryReference) throws {
        guard reference.relativePath == Self.fileName(for: reference.transactionID) else {
            throw WorktreeStateRecoveryStoreError.invalidReference(
                "path does not match the transaction UUID"
            )
        }
        guard reference.byteCount > 0, reference.byteCount <= encodedByteLimit else {
            throw WorktreeStateRecoveryStoreError.invalidReference(
                "byte count is outside the configured bound"
            )
        }
        guard Self.isDigest(reference.sha256),
              Self.isDigest(reference.snapshotFingerprint) else {
            throw WorktreeStateRecoveryStoreError.invalidReference(
                "digest fields are not lowercase SHA-256 values"
            )
        }
    }

    private static func validate(_ snapshot: WorktreeStateSnapshot) throws {
        guard !snapshot.sourceRootPath.isEmpty,
              snapshot.sourceRootPath.hasPrefix("/"),
              snapshot.sourceRootPath != "/",
              !snapshot.sourceRootPath.contains("\0"),
              URL(fileURLWithPath: snapshot.sourceRootPath).standardizedFileURL.path
                == snapshot.sourceRootPath else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot("source root is unsafe")
        }
        guard isObjectID(snapshot.headObjectID) else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot("HEAD object ID is invalid")
        }
        if let reference = snapshot.symbolicReference, !isSafeSymbolicReference(reference) {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "symbolic reference is unsafe"
            )
        }
        guard snapshot.workingTreePatch.count <= WorktreeStateMigrator.maximumPatchBytes,
              snapshot.stagedPatch.count <= WorktreeStateMigrator.maximumPatchBytes else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot("a patch exceeds its bound")
        }
        guard snapshot.supplementalFiles.count <= WorktreeStateMigrator.maximumSupplementalFiles,
              snapshot.supplementalManifest.count <= WorktreeStateMigrator.maximumSupplementalFiles,
              snapshot.supplementalRoots.count <= WorktreeStateMigrator.maximumSupplementalFiles else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "supplemental entry count exceeds its bound"
            )
        }

        var pathBytes = snapshot.sourceRootPath.utf8.count
            + snapshot.headObjectID.utf8.count
            + (snapshot.symbolicReference?.utf8.count ?? 0)
        func consumePath(_ path: String) throws {
            let count = path.utf8.count
            guard count <= WorktreeStateMigrator.maximumPathListBytes,
                  pathBytes <= WorktreeStateMigrator.maximumPathListBytes - count else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "supplemental paths exceed their aggregate bound"
                )
            }
            pathBytes += count
        }

        var filesByPath: [String: WorktreeSupplementalFile] = [:]
        var totalSupplementalBytes = 0
        for file in snapshot.supplementalFiles {
            try validateRelativePath(file.relativePath)
            try consumePath(file.relativePath)
            guard (0...0o777).contains(file.permissions),
                  file.data.count <= WorktreeStateMigrator.maximumSupplementalBytes,
                  totalSupplementalBytes
                    <= WorktreeStateMigrator.maximumSupplementalBytes - file.data.count else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "supplemental file permissions or byte count is invalid"
                )
            }
            totalSupplementalBytes += file.data.count
            guard filesByPath.updateValue(file, forKey: file.relativePath) == nil else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "duplicate supplemental file path"
                )
            }
        }

        var manifestPaths = Set<String>()
        var regularManifest: [WorktreeSupplementalFile] = []
        for entry in snapshot.supplementalManifest {
            try validateRelativePath(entry.relativePath)
            try consumePath(entry.relativePath)
            guard manifestPaths.insert(entry.relativePath).inserted else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "duplicate supplemental manifest path"
                )
            }
            switch entry.kind {
            case .absent:
                guard entry.data == nil, entry.permissions == nil else {
                    throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                        "absent manifest entry carries file state"
                    )
                }
            case .directory:
                guard entry.data == nil,
                      let permissions = entry.permissions,
                      (0...0o777).contains(permissions) else {
                    throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                        "directory manifest entry is malformed"
                    )
                }
            case .regularFile:
                guard let data = entry.data,
                      let permissions = entry.permissions,
                      (0...0o777).contains(permissions) else {
                    throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                        "regular-file manifest entry is malformed"
                    )
                }
                regularManifest.append(WorktreeSupplementalFile(
                    relativePath: entry.relativePath,
                    data: data,
                    permissions: permissions
                ))
            }
        }
        guard regularManifest.sorted(by: { $0.relativePath < $1.relativePath })
                == snapshot.supplementalFiles.sorted(by: { $0.relativePath < $1.relativePath }) else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "supplemental files and manifest disagree"
            )
        }

        var rawRoots = Set<String>()
        for root in snapshot.supplementalRoots {
            try validateRelativePath(root)
            try consumePath(root)
            guard rawRoots.insert(root).inserted else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "duplicate supplemental root"
                )
            }
        }
        let effectiveRoots = snapshot.supplementalRoots.isEmpty
            ? snapshot.supplementalManifest.map(\.relativePath)
            : snapshot.supplementalRoots
        for entry in snapshot.supplementalManifest {
            guard effectiveRoots.contains(where: {
                entry.relativePath == $0 || entry.relativePath.hasPrefix($0 + "/")
            }) else {
                throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                    "manifest path is outside supplemental roots"
                )
            }
        }
    }

    private static func validateRelativePath(_ value: String) throws {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\0") else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "supplemental path is absolute or empty"
            )
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.first?.lowercased() != ".git" else {
            throw WorktreeStateRecoveryStoreError.invalidSnapshot(
                "supplemental path escapes the checkout or addresses Git metadata"
            )
        }
    }

    private func openRoot() throws -> Int32 {
        try ensureRoot()
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.storageError("open recovery directory")
        }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            _ = Darwin.close(descriptor)
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "recovery root is not a directory"
            )
        }
        return descriptor
    }

    private func ensureRoot() throws {
        let allowedParents = [
            AppPaths.appSupport.standardizedFileURL,
            AppPaths.projectTemporaryRoot.standardizedFileURL
        ]
        guard let parent = allowedParents
            .filter({ root.path.hasPrefix($0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }) else {
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "recovery root escaped allowed storage"
            )
        }

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentInfo = Darwin.stat()
        guard Darwin.lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "allowed storage parent is not a directory"
            )
        }

        let suffix = String(root.path.dropFirst(parent.path.count + 1))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "recovery root path is malformed"
            )
        }
        var cursor = parent
        for component in components {
            cursor.appendPathComponent(String(component), isDirectory: true)
            var info = Darwin.stat()
            if Darwin.lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorktreeStateRecoveryStoreError.invalidStorage(
                        "recovery root contains a link or non-directory component"
                    )
                }
            } else {
                guard errno == ENOENT else {
                    throw Self.storageError("inspect recovery directory")
                }
                guard Darwin.mkdir(cursor.path, 0o700) == 0 || errno == EEXIST else {
                    throw Self.storageError("create recovery directory")
                }
                guard Darwin.lstat(cursor.path, &info) == 0,
                      info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorktreeStateRecoveryStoreError.invalidStorage(
                        "created recovery component is not a directory"
                    )
                }
            }
        }
    }

    /// Installs directly into a UUID-derived name with O_EXCL. Some removable
    /// filesystems reject both hard-link and rename-with-exclusion primitives;
    /// an exclusive target descriptor still provides the required no-follow,
    /// no-replacement contract. A crash can leave an unreferenced partial file,
    /// which subsequent access rejects rather than overwrites.
    private func installExclusively(
        _ data: Data,
        named name: String,
        below rootDescriptor: Int32
    ) throws {
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            guard errno == EEXIST else {
                throw Self.storageError("create recovery file")
            }
            let existing = try readRegularFile(
                named: name,
                below: rootDescriptor,
                expectedBytes: data.count
            )
            guard existing.data == data else {
                throw WorktreeStateRecoveryStoreError.invalidStorage(
                    "transaction UUID already stores different recovery state"
                )
            }
            return
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { _ = Darwin.close(descriptor) }
        }
        try Self.writeAll(data, to: descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw Self.storageError("synchronize recovery file")
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorOpen = false
            throw Self.storageError("close recovery file")
        }
        descriptorOpen = false
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw Self.storageError("synchronize recovery directory")
        }
    }

    private func readRegularFile(
        named name: String,
        below rootDescriptor: Int32,
        expectedBytes: Int
    ) throws -> StoredFile {
        guard expectedBytes > 0, expectedBytes <= encodedByteLimit else {
            throw WorktreeStateRecoveryStoreError.oversized(encodedByteLimit)
        }
        let descriptor = Darwin.openat(
            rootDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw WorktreeStateRecoveryStoreError.invalidStorage(
                "recovery file is missing, linked, or unreadable"
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size == off_t(expectedBytes),
              info.st_size > 0,
              info.st_size <= off_t(encodedByteLimit) else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "stored file type or size differs"
            )
        }
        var data = Data(count: expectedBytes)
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw WorktreeStateRecoveryStoreError.invalidStorage(
                    "unable to allocate recovery payload"
                )
            }
            var offset = 0
            while offset < bytes.count {
                let readCount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    throw WorktreeStateRecoveryStoreError.integrityMismatch(
                        "stored file ended before its declared size"
                    )
                }
                offset += readCount
            }
        }
        var finalInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0,
              finalInfo.st_mode & S_IFMT == S_IFREG,
              finalInfo.st_size == info.st_size,
              finalInfo.st_dev == info.st_dev,
              finalInfo.st_ino == info.st_ino else {
            throw WorktreeStateRecoveryStoreError.integrityMismatch(
                "stored file changed while it was read"
            )
        }
        return StoredFile(
            data: data,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino)
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw WorktreeStateRecoveryStoreError.invalidStorage(
                    "encoded recovery payload is empty"
                )
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw storageError("write recovery payload")
                }
                offset += written
            }
        }
    }

    private static func fileName(for transactionID: UUID) -> String {
        transactionID.uuidString.lowercased() + "." + fileExtension
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (40...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isSafeSymbolicReference(_ value: String) -> Bool {
        guard value.hasPrefix("refs/heads/"),
              !value.hasSuffix("/"),
              !value.contains("//"),
              !value.contains(".."),
              !value.contains("@{"),
              !value.contains("\\") else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[")
            .union(.controlCharacters)
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".lock")
        }
    }

    private static func storageError(_ operation: String) -> WorktreeStateRecoveryStoreError {
        WorktreeStateRecoveryStoreError.invalidStorage(
            "\(operation) failed (errno \(errno))"
        )
    }
}
