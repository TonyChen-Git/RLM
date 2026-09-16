import CryptoKit
import Darwin
import Foundation

enum SecureWorkspaceIOError: LocalizedError, Sendable {
    case cannotOpenWorkspace(String)
    case invalidMutationPath(String)
    case pathDoesNotExist(String)
    case alreadyExists(String)
    case symbolicLink(String)
    case notRegularFile(String)
    case notDirectory(String)
    case unsupportedFileType(String)
    case snapshotTooLarge(Int)
    case traversalLimit(kind: String, limit: Int)
    case fileChangedDuringRead(String)
    case cancelled
    case mutationMayHaveCommitted(String)
    case posix(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .cannotOpenWorkspace(let path):
            "Cannot securely open workspace: \(path)"
        case .invalidMutationPath(let path):
            "Refusing to mutate the workspace root: \(path)"
        case .pathDoesNotExist(let path):
            "Workspace path does not exist: \(path)"
        case .alreadyExists(let path):
            "A workspace entry already exists at \(path)."
        case .symbolicLink(let path):
            "Refusing to follow or mutate symbolic link: \(path)"
        case .notRegularFile(let path):
            "Not a regular file: \(path)"
        case .notDirectory(let path):
            "Not a directory: \(path)"
        case .unsupportedFileType(let path):
            "Unsupported workspace entry type: \(path)"
        case .snapshotTooLarge(let maximumBytes):
            "Change snapshot exceeds the \(maximumBytes)-byte safety limit."
        case .traversalLimit(let kind, let limit):
            "Workspace traversal exceeded the \(kind) safety limit (\(limit))."
        case .fileChangedDuringRead(let path):
            "Workspace file changed while it was being read: \(path)"
        case .cancelled:
            "Workspace operation was cancelled."
        case .mutationMayHaveCommitted(let detail):
            "Workspace mutation needs rollback: \(detail)"
        case .posix(let operation, let path, let code):
            "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

enum SecureWorkspaceEntryKind: Sendable, Equatable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

struct SecureWorkspaceMetadata: Sendable, Equatable {
    var kind: SecureWorkspaceEntryKind
    var byteCount: Int64
    var permissions: Int
    var createdAt: Date
    var modifiedAt: Date
}

struct SecureWorkspaceRead: Sendable {
    var data: Data
    var metadata: SecureWorkspaceMetadata
    var truncated: Bool
}

struct SecureWorkspaceDigest: Sendable, Equatable {
    var sha256: String
    var metadata: SecureWorkspaceMetadata
}

struct SecureWorkspaceTreeEntry: Sendable, Equatable {
    var relativePath: String
    var name: String
    var depth: Int
    var metadata: SecureWorkspaceMetadata
}

struct SecureWorkspaceEnumeration: Sendable, Equatable {
    var entries: [SecureWorkspaceTreeEntry]
    var truncated: Bool
}

enum SecureSnapshotEntryKind: Codable, Sendable, Equatable {
    case file(Data)
    case directory

    private enum CodingKeys: String, CodingKey { case kind, data }
    private enum Kind: String, Codable { case file, directory }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            self = .file(try container.decode(Data.self, forKey: .data))
        case .directory:
            self = .directory
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .file(let data):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(data, forKey: .data)
        case .directory:
            try container.encode(Kind.directory, forKey: .kind)
        }
    }
}

struct SecureSnapshotEntry: Codable, Sendable, Equatable {
    var relativePath: String
    var kind: SecureSnapshotEntryKind
    var permissions: Int
}

struct SecurePathSnapshot: Codable, Sendable, Equatable {
    var requestedPath: String
    var existed: Bool
    var entries: [SecureSnapshotEntry]
}

/// Descriptor-based filesystem boundary for native Agent tools.
///
/// Every path is resolved relative to a pinned workspace directory descriptor.
/// `O_RESOLVE_BENEATH` prevents resolution from escaping that descriptor and
/// `O_NOFOLLOW_ANY` rejects a symlink in any component. Mutation syscalls use
/// parent descriptors (`renameat`, `renameatx_np`, `unlinkat`, `mkdirat`) so an
/// attacker swapping an ancestor for a symlink between validation and use can
/// only make the operation fail closed.
final class SecureWorkspaceIO: @unchecked Sendable {
    private static let maximumDirectoryEntries = 50_000
    private static let maximumTreeEntries = 100_000
    private static let maximumTreeDepth = 128
    private static let maximumCopyBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    private static let maximumRemovalBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static var maximumTreeDepthForTesting: Int { maximumTreeDepth }

    private struct TraversalBudget {
        var entries = 0
        var bytes: Int64 = 0
        let maximumEntries: Int
        let maximumBytes: Int64
        var honorCancellation = true

        mutating func consume(info: Darwin.stat, depth: Int) throws {
            if honorCancellation, Task.isCancelled {
                throw SecureWorkspaceIOError.cancelled
            }
            guard depth <= SecureWorkspaceIO.maximumTreeDepth else {
                throw SecureWorkspaceIOError.traversalLimit(
                    kind: "depth",
                    limit: SecureWorkspaceIO.maximumTreeDepth
                )
            }
            entries += 1
            guard entries <= maximumEntries else {
                throw SecureWorkspaceIOError.traversalLimit(
                    kind: "entry count",
                    limit: maximumEntries
                )
            }
            if SecureWorkspaceIO.kind(of: info) == .regularFile {
                let fileBytes = max(0, info.st_size)
                guard fileBytes <= maximumBytes,
                      bytes <= maximumBytes - fileBytes else {
                    throw SecureWorkspaceIOError.traversalLimit(
                        kind: "byte count",
                        limit: maximumBytes > Int64(Int.max) ? Int.max : Int(maximumBytes)
                    )
                }
                bytes += fileBytes
            }
        }
    }
    private final class Descriptor {
        let rawValue: Int32

        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { Darwin.close(rawValue) }
    }

    private struct ParentReference {
        var descriptor: Descriptor
        var leaf: String
        var displayPath: String
    }

    private let validator: WorkspaceSecurityValidator
    private let root: Descriptor

    init(validator: WorkspaceSecurityValidator) throws {
        self.validator = validator
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        let descriptor = Darwin.open(validator.secureRootPath, flags)
        guard descriptor >= 0 else {
            throw SecureWorkspaceIOError.cannotOpenWorkspace(validator.secureRootPath)
        }
        var info = Darwin.stat()
        let expectedIdentity = validator.secureRootIdentity
        guard Darwin.fstat(descriptor, &info) == 0,
              Self.kind(of: info) == .directory,
              UInt64(info.st_dev) == expectedIdentity.device,
              UInt64(info.st_ino) == expectedIdentity.inode else {
            let savedErrno = errno
            Darwin.close(descriptor)
            if savedErrno != 0 { errno = savedErrno }
            throw SecureWorkspaceIOError.cannotOpenWorkspace(validator.secureRootPath)
        }
        root = Descriptor(descriptor)
    }

    func metadata(path: String) throws -> SecureWorkspaceMetadata {
        let relative = try validator.secureRelativePath(for: path)
        let descriptor = try openExisting(
            relative: relative,
            flags: O_RDONLY | O_NONBLOCK,
            displayPath: path
        )
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &info) == 0 else {
            throw posix("fstat", path)
        }
        return Self.metadata(from: info)
    }

    func exists(path: String) throws -> Bool {
        let relative = try validator.secureRelativePath(for: path)
        if relative == "." { return true }
        let parent = try parentReference(relative: relative, displayPath: path)
        var info = Darwin.stat()
        if Darwin.fstatat(parent.descriptor.rawValue, parent.leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if Self.kind(of: info) == .symbolicLink {
                throw SecureWorkspaceIOError.symbolicLink(path)
            }
            return true
        }
        if errno == ENOENT { return false }
        throw posix("fstatat", path)
    }

    func readRegularFile(path: String, maximumBytes: Int) throws -> SecureWorkspaceRead {
        let relative = try validator.secureRelativePath(for: path)
        let descriptor = try openExisting(
            relative: relative,
            flags: O_RDONLY | O_NONBLOCK,
            displayPath: path
        )
        var initial = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &initial) == 0 else {
            throw posix("fstat", path)
        }
        guard Self.kind(of: initial) == .regularFile else {
            throw SecureWorkspaceIOError.notRegularFile(path)
        }

        let limit = max(0, maximumBytes)
        let (data, truncated) = try read(
            descriptor: descriptor.rawValue,
            maximumBytes: limit,
            displayPath: path,
            honorCancellation: true
        )
        var final = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &final) == 0 else {
            throw posix("fstat", path)
        }
        guard Self.hasStableReadIdentity(initial: initial, final: final),
              truncated || (final.st_size >= 0 && Int64(data.count) == final.st_size) else {
            throw SecureWorkspaceIOError.fileChangedDuringRead(path)
        }
        return SecureWorkspaceRead(
            data: data,
            metadata: Self.metadata(from: final),
            truncated: truncated
        )
    }

    /// Hashes a regular file through one no-follow descriptor without retaining
    /// its contents in memory. Metadata is compared before/after the stream so
    /// a concurrent writer makes the identity fail closed.
    func sha256RegularFile(
        path: String,
        maximumBytes: Int,
        honorCancellation: Bool = true
    ) throws -> SecureWorkspaceDigest {
        let relative = try validator.secureRelativePath(for: path)
        let descriptor = try openExisting(
            relative: relative,
            flags: O_RDONLY | O_NONBLOCK,
            displayPath: path
        )
        var initial = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &initial) == 0 else {
            throw posix("fstat", path)
        }
        guard Self.kind(of: initial) == .regularFile else {
            throw SecureWorkspaceIOError.notRegularFile(path)
        }
        let limit = max(0, maximumBytes)
        guard initial.st_size >= 0, initial.st_size <= off_t(limit) else {
            throw SecureWorkspaceIOError.snapshotTooLarge(limit)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total = 0
        while true {
            if honorCancellation, Task.isCancelled {
                throw SecureWorkspaceIOError.cancelled
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor.rawValue, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posix("read", path)
            }
            if count == 0 { break }
            guard total <= limit - count else {
                throw SecureWorkspaceIOError.snapshotTooLarge(limit)
            }
            hasher.update(data: Data(buffer[0..<count]))
            total += count
        }

        var final = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &final) == 0 else {
            throw posix("fstat", path)
        }
        guard total == final.st_size,
              Self.hasStableReadIdentity(initial: initial, final: final) else {
            throw SecureWorkspaceIOError.fileChangedDuringRead(path)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return SecureWorkspaceDigest(
            sha256: digest,
            metadata: Self.metadata(from: final)
        )
    }

    /// Enumerates from pinned directory descriptors without following links.
    /// Protected host-runtime roots are omitted even when the selected
    /// workspace is the LumaChat repository itself.
    func enumerate(
        path: String,
        maximumDepth: Int,
        maximumEntries: Int,
        includeHidden: Bool,
        ignoredDirectoryNames: Set<String> = [],
        regularFilesOnly: Bool = false
    ) throws -> SecureWorkspaceEnumeration {
        let workspaceRelative = try validator.secureRelativePath(for: path)
        let directory = try openExisting(
            relative: workspaceRelative,
            flags: O_RDONLY | O_DIRECTORY | O_NONBLOCK,
            displayPath: path
        )
        var rootInfo = Darwin.stat()
        guard Darwin.fstat(directory.rawValue, &rootInfo) == 0 else {
            throw posix("fstat", path)
        }
        guard Self.kind(of: rootInfo) == .directory else {
            throw SecureWorkspaceIOError.notDirectory(path)
        }

        let depthLimit = max(1, min(maximumDepth, 128))
        let entryLimit = max(1, maximumEntries)
        var entries: [SecureWorkspaceTreeEntry] = []
        var truncated = false
        var visitedEntries = 0

        func visit(
            _ descriptor: Int32,
            workspaceBase: String,
            resultBase: String,
            depth: Int
        ) throws {
            guard depth <= depthLimit, !truncated else { return }
            if Task.isCancelled { throw SecureWorkspaceIOError.cancelled }
            let directoryListing = try directoryNames(
                descriptor: descriptor,
                displayPath: path,
                maximumEntries: min(Self.maximumDirectoryEntries, entryLimit)
            )
            for name in directoryListing.names {
                if truncated { return }
                visitedEntries += 1
                guard visitedEntries <= Self.maximumTreeEntries else {
                    truncated = true
                    return
                }
                if !includeHidden, name.hasPrefix(".") { continue }
                let workspaceChild = Self.join(workspaceBase, name)
                if validator.isProtectedRuntimeRelativePath(workspaceChild) { continue }

                var info = Darwin.stat()
                guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw posix("fstatat", workspaceChild)
                }
                let kind = Self.kind(of: info)
                let resultPath = Self.join(resultBase, name)
                let isIgnoredDirectory = kind == .directory
                    && ignoredDirectoryNames.contains(name)

                if !regularFilesOnly || kind == .regularFile {
                    guard entries.count < entryLimit else {
                        truncated = true
                        return
                    }
                    entries.append(SecureWorkspaceTreeEntry(
                        relativePath: resultPath,
                        name: name,
                        depth: depth,
                        metadata: Self.metadata(from: info)
                    ))
                }

                if kind == .directory,
                   !isIgnoredDirectory,
                   depth < depthLimit {
                    let child = try openAt(
                        parentFD: descriptor,
                        name: name,
                        flags: O_RDONLY | O_DIRECTORY | O_NONBLOCK,
                        displayPath: workspaceChild
                    )
                    try visit(
                        child.rawValue,
                        workspaceBase: workspaceChild,
                        resultBase: resultPath,
                        depth: depth + 1
                    )
                }
            }
            if directoryListing.truncated { truncated = true }
        }

        try visit(
            directory.rawValue,
            workspaceBase: workspaceRelative,
            resultBase: "",
            depth: 1
        )
        return SecureWorkspaceEnumeration(entries: entries, truncated: truncated)
    }

    func replaceRegularFile(
        path: String,
        data: Data,
        createOnly: Bool,
        honorCancellation: Bool = true
    ) throws {
        let relative = try mutationRelativePath(path)
        let parent = try parentReference(relative: relative, displayPath: path)
        let existing = try lstat(parent: parent)
        if createOnly {
            guard existing == nil else {
                if existing.map({ Self.kind(of: $0) }) == .symbolicLink {
                    throw SecureWorkspaceIOError.symbolicLink(path)
                }
                throw SecureWorkspaceIOError.alreadyExists(path)
            }
        } else {
            guard let existing else { throw SecureWorkspaceIOError.pathDoesNotExist(path) }
            let kind = Self.kind(of: existing)
            if kind == .symbolicLink { throw SecureWorkspaceIOError.symbolicLink(path) }
            guard kind == .regularFile else {
                throw SecureWorkspaceIOError.notRegularFile(path)
            }
        }

        let mode = mode_t(existing.map { Int($0.st_mode & 0o7777) } ?? 0o644)
        if createOnly {
            // Some workspace volumes (notably exFAT) do not implement
            // `RENAME_EXCL`. `openat(O_CREAT | O_EXCL)` still gives an atomic,
            // descriptor-relative exclusive create without a path precheck.
            let destinationFD = Darwin.openat(
                parent.descriptor.rawValue,
                parent.leaf,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
            guard destinationFD >= 0 else {
                if errno == EEXIST { throw SecureWorkspaceIOError.alreadyExists(path) }
                throw posix("openat", path)
            }
            var createdInfo = Darwin.stat()
            guard Darwin.fstat(destinationFD, &createdInfo) == 0 else {
                let failure = posix("fstat", path)
                Darwin.close(destinationFD)
                throw failure
            }
            var completed = false
            defer {
                Darwin.close(destinationFD)
                if !completed {
                    var currentInfo = Darwin.stat()
                    if Darwin.fstatat(
                        parent.descriptor.rawValue,
                        parent.leaf,
                        &currentInfo,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                    currentInfo.st_dev == createdInfo.st_dev,
                    currentInfo.st_ino == createdInfo.st_ino {
                        _ = Darwin.unlinkat(parent.descriptor.rawValue, parent.leaf, 0)
                    }
                }
            }
            try write(
                data,
                descriptor: destinationFD,
                displayPath: path,
                honorCancellation: honorCancellation
            )
            guard Darwin.fchmod(destinationFD, mode) == 0 else {
                throw posix("fchmod", path)
            }
            guard Darwin.fsync(destinationFD) == 0 else {
                throw posix("fsync", path)
            }
            completed = true
            _ = Darwin.fsync(parent.descriptor.rawValue)
            return
        }

        let temporary = ".luma-write-\(UUID().uuidString)"
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                _ = Darwin.unlinkat(parent.descriptor.rawValue, temporary, 0)
            }
        }

        let temporaryFD = Darwin.openat(
            parent.descriptor.rawValue,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryFD >= 0 else { throw posix("openat", path) }
        do {
            try write(
                data,
                descriptor: temporaryFD,
                displayPath: path,
                honorCancellation: honorCancellation
            )
            guard Darwin.fchmod(temporaryFD, mode) == 0 else {
                throw posix("fchmod", path)
            }
            guard Darwin.fsync(temporaryFD) == 0 else {
                throw posix("fsync", path)
            }
        } catch {
            Darwin.close(temporaryFD)
            throw error
        }
        Darwin.close(temporaryFD)

        let result = Darwin.renameat(
            parent.descriptor.rawValue,
            temporary,
            parent.descriptor.rawValue,
            parent.leaf
        )
        guard result == 0 else {
            throw posix("renameat", path)
        }
        shouldRemoveTemporary = false
        _ = Darwin.fsync(parent.descriptor.rawValue)
    }

    func createDirectory(path: String, permissions: Int = 0o755) throws {
        let relative = try mutationRelativePath(path)
        let parent = try parentReference(relative: relative, displayPath: path)
        guard try lstat(parent: parent) == nil else {
            throw SecureWorkspaceIOError.alreadyExists(path)
        }
        guard Darwin.mkdirat(parent.descriptor.rawValue, parent.leaf, mode_t(permissions)) == 0 else {
            if errno == EEXIST { throw SecureWorkspaceIOError.alreadyExists(path) }
            throw posix("mkdirat", path)
        }
        _ = Darwin.fsync(parent.descriptor.rawValue)
    }

    func remove(
        path: String,
        ifExists: Bool = false,
        honorCancellation: Bool = true
    ) throws {
        let relative = try mutationRelativePath(path)
        let parent = try parentReference(relative: relative, displayPath: path)
        guard let info = try lstat(parent: parent) else {
            if ifExists { return }
            throw SecureWorkspaceIOError.pathDoesNotExist(path)
        }
        if Self.kind(of: info) == .symbolicLink {
            throw SecureWorkspaceIOError.symbolicLink(path)
        }
        var validationBudget = TraversalBudget(
            maximumEntries: Self.maximumTreeEntries,
            maximumBytes: Self.maximumRemovalBytes,
            honorCancellation: honorCancellation
        )
        try assertNoSymbolicLinks(
            parentFD: parent.descriptor.rawValue,
            name: parent.leaf,
            path: path,
            info: info,
            depth: 0,
            budget: &validationBudget
        )
        var removalBudget = TraversalBudget(
            maximumEntries: Self.maximumTreeEntries,
            maximumBytes: Self.maximumRemovalBytes,
            honorCancellation: honorCancellation
        )
        try removeEntry(
            parentFD: parent.descriptor.rawValue,
            name: parent.leaf,
            path: path,
            knownInfo: info,
            depth: 0,
            budget: &removalBudget
        )
        _ = Darwin.fsync(parent.descriptor.rawValue)
    }

    func move(source: String, destination: String) throws {
        let sourceRelative = try mutationRelativePath(source)
        let destinationRelative = try mutationRelativePath(destination)
        let sourceParent = try parentReference(relative: sourceRelative, displayPath: source)
        let destinationParent = try parentReference(
            relative: destinationRelative,
            displayPath: destination
        )
        guard let sourcePathInfo = try lstat(parent: sourceParent) else {
            throw SecureWorkspaceIOError.pathDoesNotExist(source)
        }
        if Self.kind(of: sourcePathInfo) == .symbolicLink {
            throw SecureWorkspaceIOError.symbolicLink(source)
        }
        let sourceDescriptor = try openAt(
            parentFD: sourceParent.descriptor.rawValue,
            name: sourceParent.leaf,
            flags: O_RDONLY | O_NONBLOCK,
            displayPath: source
        )
        var sourceInfo = Darwin.stat()
        guard Darwin.fstat(sourceDescriptor.rawValue, &sourceInfo) == 0 else {
            throw posix("fstat", source)
        }
        let sourceKind = Self.kind(of: sourceInfo)
        guard sourceKind == .regularFile || sourceKind == .directory else {
            throw SecureWorkspaceIOError.unsupportedFileType(source)
        }
        guard try lstat(parent: destinationParent) == nil else {
            throw SecureWorkspaceIOError.alreadyExists(destination)
        }
        var traversalBudget = TraversalBudget(
            maximumEntries: Self.maximumTreeEntries,
            maximumBytes: Self.maximumRemovalBytes
        )
        try assertNoSymbolicLinks(
            parentFD: sourceParent.descriptor.rawValue,
            name: sourceParent.leaf,
            path: source,
            info: sourceInfo,
            depth: 0,
            budget: &traversalBudget
        )
        let usedAtomicRename = try renameExclusively(
            sourceParentFD: sourceParent.descriptor.rawValue,
            sourceName: sourceParent.leaf,
            destinationParentFD: destinationParent.descriptor.rawValue,
            destinationName: destinationParent.leaf,
            displayPath: "\(source) -> \(destination)"
        )
        var expectedDestinationInfo = sourceInfo
        if !usedAtomicRename {
            // exFAT and a few network filesystems reject RENAME_EXCL. Keep the
            // no-overwrite invariant by using copy's descriptor-relative
            // O_EXCL/mkdirat path, then remove the source. This is bounded and
            // transactional rather than atomic: after the destination exists,
            // every failure is reported as possibly committed so the caller
            // restores both pre-move snapshots.
            do {
                try copy(source: source, destination: destination)
                guard let copiedInfo = try lstat(parent: destinationParent) else {
                    throw SecureWorkspaceIOError.pathDoesNotExist(destination)
                }
                expectedDestinationInfo = copiedInfo
                try remove(path: source, honorCancellation: false)
            } catch {
                throw SecureWorkspaceIOError.mutationMayHaveCommitted(
                    "exclusive rename is unsupported and the safe copy/remove fallback failed: "
                        + error.localizedDescription
                )
            }
        }
        do {
            guard let movedInfo = try lstat(parent: destinationParent),
                  movedInfo.st_dev == expectedDestinationInfo.st_dev,
                  movedInfo.st_ino == expectedDestinationInfo.st_ino else {
                throw SecureWorkspaceIOError.posix(
                    operation: "rename identity verification",
                    path: "\(source) -> \(destination)",
                    code: ESTALE
                )
            }
            var postMoveBudget = TraversalBudget(
                maximumEntries: Self.maximumTreeEntries,
                maximumBytes: Self.maximumRemovalBytes,
                honorCancellation: false
            )
            try assertNoSymbolicLinks(
                parentFD: destinationParent.descriptor.rawValue,
                name: destinationParent.leaf,
                path: destination,
                info: movedInfo,
                depth: 0,
                budget: &postMoveBudget
            )
        } catch {
            throw SecureWorkspaceIOError.mutationMayHaveCommitted(error.localizedDescription)
        }
        _ = Darwin.fsync(sourceParent.descriptor.rawValue)
        _ = Darwin.fsync(destinationParent.descriptor.rawValue)
    }

    func copy(source: String, destination: String) throws {
        let sourceRelative = try validator.secureRelativePath(for: source)
        let destinationRelative = try mutationRelativePath(destination)
        let sourceDescriptor = try openExisting(
            relative: sourceRelative,
            flags: O_RDONLY | O_NONBLOCK,
            displayPath: source
        )
        var sourceInfo = Darwin.stat()
        guard Darwin.fstat(sourceDescriptor.rawValue, &sourceInfo) == 0 else {
            throw posix("fstat", source)
        }
        let sourceKind = Self.kind(of: sourceInfo)
        guard sourceKind == .regularFile || sourceKind == .directory else {
            if sourceKind == .symbolicLink { throw SecureWorkspaceIOError.symbolicLink(source) }
            throw SecureWorkspaceIOError.unsupportedFileType(source)
        }
        if sourceKind == .directory,
           (sourceRelative == "."
            || destinationRelative.hasPrefix(sourceRelative + "/")) {
            throw SecureWorkspaceIOError.invalidMutationPath(destination)
        }

        let destinationParent = try parentReference(
            relative: destinationRelative,
            displayPath: destination
        )
        guard try lstat(parent: destinationParent) == nil else {
            throw SecureWorkspaceIOError.alreadyExists(destination)
        }

        var traversalBudget = TraversalBudget(
            maximumEntries: Self.maximumTreeEntries,
            maximumBytes: Self.maximumCopyBytes
        )
        if sourceKind == .regularFile {
            try copyRegularFile(
                sourceFD: sourceDescriptor.rawValue,
                destinationParentFD: destinationParent.descriptor.rawValue,
                destinationName: destinationParent.leaf,
                path: destination,
                depth: 0,
                budget: &traversalBudget
            )
        } else {
            try copyDirectory(
                sourceFD: sourceDescriptor.rawValue,
                destinationParentFD: destinationParent.descriptor.rawValue,
                destinationName: destinationParent.leaf,
                path: destination,
                workspaceRelativePath: sourceRelative,
                depth: 0,
                budget: &traversalBudget
            )
        }
        _ = Darwin.fsync(destinationParent.descriptor.rawValue)
    }

    func snapshot(
        path: String,
        maximumBytes: Int,
        honorCancellation: Bool = true
    ) throws -> SecurePathSnapshot {
        let relative = try validator.secureRelativePath(for: path)
        let descriptor: Descriptor
        do {
            descriptor = try openExisting(
                relative: relative,
                flags: O_RDONLY | O_NONBLOCK,
                displayPath: path
            )
        } catch SecureWorkspaceIOError.pathDoesNotExist {
            return SecurePathSnapshot(requestedPath: path, existed: false, entries: [])
        }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor.rawValue, &info) == 0 else {
            throw posix("fstat", path)
        }
        var remainingBytes = maximumBytes
        var remainingEntries = Self.maximumTreeEntries
        var entries: [SecureSnapshotEntry] = []
        try snapshotEntry(
            descriptor: descriptor.rawValue,
            relativePath: "",
            displayPath: path,
            depth: 0,
            honorCancellation: honorCancellation,
            remainingBytes: &remainingBytes,
            remainingEntries: &remainingEntries,
            maximumBytes: maximumBytes,
            entries: &entries
        )
        return SecurePathSnapshot(requestedPath: path, existed: true, entries: entries)
    }

    func restore(_ snapshots: [SecurePathSnapshot]) throws {
        for snapshot in snapshots.reversed() {
            try remove(
                path: snapshot.requestedPath,
                ifExists: true,
                honorCancellation: false
            )
            guard snapshot.existed else { continue }

            let directories = snapshot.entries.compactMap { entry -> SecureSnapshotEntry? in
                if case .directory = entry.kind { return entry }
                return nil
            }.sorted {
                Self.pathDepth($0.relativePath) < Self.pathDepth($1.relativePath)
            }
            for entry in directories {
                let path = Self.join(snapshot.requestedPath, entry.relativePath)
                try createDirectory(path: path, permissions: entry.permissions)
            }
            for entry in snapshot.entries {
                guard case .file(let data) = entry.kind else { continue }
                let path = Self.join(snapshot.requestedPath, entry.relativePath)
                // ExFAT may synthesize an AppleDouble sidecar as soon as its
                // paired directory is recreated. The sidecar was part of the
                // trusted snapshot, but an exclusive create would now collide
                // with that kernel-generated file. Only this reserved metadata
                // basename may replace an already-present regular file; all
                // normal workspace files retain strict exclusive recreation.
                let isGeneratedAppleDouble = path.split(separator: "/").last?
                    .hasPrefix("._") == true
                let replaceGeneratedSidecar = isGeneratedAppleDouble
                    ? try exists(path: path)
                    : false
                try replaceRegularFile(
                    path: path,
                    data: data,
                    createOnly: !replaceGeneratedSidecar,
                    honorCancellation: false
                )
                try setPermissions(path: path, permissions: entry.permissions)
            }
            for entry in directories.reversed() {
                try setPermissions(
                    path: Self.join(snapshot.requestedPath, entry.relativePath),
                    permissions: entry.permissions
                )
            }
        }
    }

    private func snapshotEntry(
        descriptor: Int32,
        relativePath: String,
        displayPath: String,
        depth: Int,
        honorCancellation: Bool,
        remainingBytes: inout Int,
        remainingEntries: inout Int,
        maximumBytes: Int,
        entries: inout [SecureSnapshotEntry]
    ) throws {
        var pinnedInfo = Darwin.stat()
        guard Darwin.fstat(descriptor, &pinnedInfo) == 0 else {
            throw posix("fstat", displayPath)
        }
        if honorCancellation, Task.isCancelled {
            throw SecureWorkspaceIOError.cancelled
        }
        guard depth <= Self.maximumTreeDepth else {
            throw SecureWorkspaceIOError.traversalLimit(
                kind: "depth",
                limit: Self.maximumTreeDepth
            )
        }
        remainingEntries -= 1
        guard remainingEntries >= 0 else {
            throw SecureWorkspaceIOError.traversalLimit(
                kind: "entry count",
                limit: Self.maximumTreeEntries
            )
        }
        switch Self.kind(of: pinnedInfo) {
        case .regularFile:
            guard pinnedInfo.st_size <= Int64(max(0, remainingBytes)) else {
                throw SecureWorkspaceIOError.snapshotTooLarge(maximumBytes)
            }
            let (data, truncated) = try read(
                descriptor: descriptor,
                maximumBytes: max(0, remainingBytes),
                displayPath: displayPath,
                honorCancellation: honorCancellation
            )
            guard !truncated else {
                throw SecureWorkspaceIOError.snapshotTooLarge(maximumBytes)
            }
            remainingBytes -= data.count
            entries.append(SecureSnapshotEntry(
                relativePath: relativePath,
                kind: .file(data),
                permissions: Int(pinnedInfo.st_mode & 0o7777)
            ))
        case .directory:
            entries.append(SecureSnapshotEntry(
                relativePath: relativePath,
                kind: .directory,
                permissions: Int(pinnedInfo.st_mode & 0o7777)
            ))
            let listing = try directoryNames(
                descriptor: descriptor,
                displayPath: displayPath,
                honorCancellation: honorCancellation
            )
            if listing.truncated {
                throw SecureWorkspaceIOError.traversalLimit(
                    kind: "entries per directory",
                    limit: Self.maximumDirectoryEntries
                )
            }
            for name in listing.names {
                var childInfo = Darwin.stat()
                guard Darwin.fstatat(descriptor, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw posix("fstatat", Self.join(displayPath, name))
                }
                let childPath = Self.join(displayPath, name)
                let childRelative = Self.join(relativePath, name)
                let childKind = Self.kind(of: childInfo)
                if childKind == .symbolicLink {
                    throw SecureWorkspaceIOError.symbolicLink(childPath)
                }
                guard childKind == .regularFile || childKind == .directory else {
                    throw SecureWorkspaceIOError.unsupportedFileType(childPath)
                }
                let child = try openAt(
                    parentFD: descriptor,
                    name: name,
                    flags: O_RDONLY | O_NONBLOCK,
                    displayPath: childPath
                )
                try snapshotEntry(
                    descriptor: child.rawValue,
                    relativePath: childRelative,
                    displayPath: childPath,
                    depth: depth + 1,
                    honorCancellation: honorCancellation,
                    remainingBytes: &remainingBytes,
                    remainingEntries: &remainingEntries,
                    maximumBytes: maximumBytes,
                    entries: &entries
                )
            }
        case .symbolicLink:
            throw SecureWorkspaceIOError.symbolicLink(displayPath)
        case .other:
            throw SecureWorkspaceIOError.unsupportedFileType(displayPath)
        }
    }

    private func copyRegularFile(
        sourceFD: Int32,
        destinationParentFD: Int32,
        destinationName: String,
        path: String,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        var pinnedInfo = Darwin.stat()
        guard Darwin.fstat(sourceFD, &pinnedInfo) == 0,
              Self.kind(of: pinnedInfo) == .regularFile else {
            throw SecureWorkspaceIOError.notRegularFile(path)
        }
        try budget.consume(info: pinnedInfo, depth: depth)
        let destinationFD = Darwin.openat(
            destinationParentFD,
            destinationName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard destinationFD >= 0 else { throw posix("openat", path) }
        var destinationInfo = Darwin.stat()
        guard Darwin.fstat(destinationFD, &destinationInfo) == 0 else {
            let failure = posix("fstat", path)
            Darwin.close(destinationFD)
            throw failure
        }
        var completed = false
        defer {
            Darwin.close(destinationFD)
            if !completed {
                removeEntryIfIdentityMatches(
                    parentFD: destinationParentFD,
                    name: destinationName,
                    expected: destinationInfo,
                    path: path,
                    maximumBytes: Self.maximumCopyBytes
                )
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var remainingSourceBytes = max(0, pinnedInfo.st_size)
        while remainingSourceBytes > 0 {
            if Task.isCancelled { throw SecureWorkspaceIOError.cancelled }
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    sourceFD,
                    $0.baseAddress,
                    min($0.count, Int(remainingSourceBytes))
                )
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posix("read", path)
            }
            try buffer.withUnsafeBytes { rawBuffer in
                try writeBytes(
                    rawBuffer.baseAddress!,
                    count: count,
                    descriptor: destinationFD,
                    displayPath: path
                )
            }
            remainingSourceBytes -= Int64(count)
        }
        guard Darwin.fchmod(destinationFD, pinnedInfo.st_mode & 0o7777) == 0 else {
            throw posix("fchmod", path)
        }
        guard Darwin.fsync(destinationFD) == 0 else { throw posix("fsync", path) }
        completed = true
    }

    private func copyDirectory(
        sourceFD: Int32,
        destinationParentFD: Int32,
        destinationName: String,
        path: String,
        workspaceRelativePath: String,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        var pinnedInfo = Darwin.stat()
        guard Darwin.fstat(sourceFD, &pinnedInfo) == 0,
              Self.kind(of: pinnedInfo) == .directory else {
            throw SecureWorkspaceIOError.notDirectory(path)
        }
        try budget.consume(info: pinnedInfo, depth: depth)
        guard Darwin.mkdirat(destinationParentFD, destinationName, mode_t(0o700)) == 0 else {
            throw posix("mkdirat", path)
        }
        let destination = try openAt(
            parentFD: destinationParentFD,
            name: destinationName,
            flags: O_RDONLY | O_DIRECTORY,
            displayPath: path
        )
        var destinationInfo = Darwin.stat()
        guard Darwin.fstat(destination.rawValue, &destinationInfo) == 0 else {
            throw posix("fstat", path)
        }
        var completed = false
        defer {
            if !completed {
                removeEntryIfIdentityMatches(
                    parentFD: destinationParentFD,
                    name: destinationName,
                    expected: destinationInfo,
                    path: path,
                    maximumBytes: Self.maximumCopyBytes
                )
            }
        }

        let listing = try directoryNames(descriptor: sourceFD, displayPath: path)
        if listing.truncated {
            throw SecureWorkspaceIOError.traversalLimit(
                kind: "entries per directory",
                limit: Self.maximumDirectoryEntries
            )
        }
        for name in listing.names {
            let childWorkspacePath = Self.join(workspaceRelativePath, name)
            if validator.isProtectedRuntimeRelativePath(childWorkspacePath) {
                throw WorkspaceSecurityError.pathEscapesWorkspace(childWorkspacePath)
            }
            var info = Darwin.stat()
            guard Darwin.fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posix("fstatat", Self.join(path, name))
            }
            let childPath = Self.join(path, name)
            let kind = Self.kind(of: info)
            if kind == .symbolicLink { throw SecureWorkspaceIOError.symbolicLink(childPath) }
            switch kind {
            case .regularFile:
                let sourceChild = try openAt(
                    parentFD: sourceFD,
                    name: name,
                    flags: O_RDONLY | O_NONBLOCK,
                    displayPath: childPath
                )
                try copyRegularFile(
                    sourceFD: sourceChild.rawValue,
                    destinationParentFD: destination.rawValue,
                    destinationName: name,
                    path: childPath,
                    depth: depth + 1,
                    budget: &budget
                )
            case .directory:
                let sourceChild = try openAt(
                    parentFD: sourceFD,
                    name: name,
                    flags: O_RDONLY | O_DIRECTORY | O_NONBLOCK,
                    displayPath: childPath
                )
                try copyDirectory(
                    sourceFD: sourceChild.rawValue,
                    destinationParentFD: destination.rawValue,
                    destinationName: name,
                    path: childPath,
                    workspaceRelativePath: childWorkspacePath,
                    depth: depth + 1,
                    budget: &budget
                )
            case .symbolicLink:
                throw SecureWorkspaceIOError.symbolicLink(childPath)
            case .other:
                throw SecureWorkspaceIOError.unsupportedFileType(childPath)
            }
        }
        guard Darwin.fchmod(destination.rawValue, pinnedInfo.st_mode & 0o7777) == 0 else {
            throw posix("fchmod", path)
        }
        _ = Darwin.fsync(destination.rawValue)
        completed = true
    }

    private func assertNoSymbolicLinks(
        parentFD: Int32,
        name: String,
        path: String,
        info: Darwin.stat,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        try budget.consume(info: info, depth: depth)
        let kind = Self.kind(of: info)
        if kind == .symbolicLink { throw SecureWorkspaceIOError.symbolicLink(path) }
        guard kind == .directory else { return }
        let directory = try openAt(
            parentFD: parentFD,
            name: name,
            flags: O_RDONLY | O_DIRECTORY,
            displayPath: path
        )
        try assertNoSymbolicLinks(
            directoryFD: directory.rawValue,
            path: path,
            depth: depth,
            budget: &budget
        )
    }

    private func assertNoSymbolicLinks(
        directoryFD: Int32,
        path: String,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        let listing = try directoryNames(
            descriptor: directoryFD,
            displayPath: path,
            honorCancellation: budget.honorCancellation
        )
        if listing.truncated {
            throw SecureWorkspaceIOError.traversalLimit(
                kind: "entries per directory",
                limit: Self.maximumDirectoryEntries
            )
        }
        for name in listing.names {
            var info = Darwin.stat()
            let childPath = Self.join(path, name)
            guard Darwin.fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posix("fstatat", childPath)
            }
            switch Self.kind(of: info) {
            case .symbolicLink:
                throw SecureWorkspaceIOError.symbolicLink(childPath)
            case .directory:
                try budget.consume(info: info, depth: depth + 1)
                let child = try openAt(
                    parentFD: directoryFD,
                    name: name,
                    flags: O_RDONLY | O_DIRECTORY,
                    displayPath: childPath
                )
                try assertNoSymbolicLinks(
                    directoryFD: child.rawValue,
                    path: childPath,
                    depth: depth + 1,
                    budget: &budget
                )
            case .regularFile:
                try budget.consume(info: info, depth: depth + 1)
            case .other:
                throw SecureWorkspaceIOError.unsupportedFileType(childPath)
            }
        }
    }

    private func removeEntry(
        parentFD: Int32,
        name: String,
        path: String,
        knownInfo: Darwin.stat,
        depth: Int,
        budget: inout TraversalBudget
    ) throws {
        try budget.consume(info: knownInfo, depth: depth)
        switch Self.kind(of: knownInfo) {
        case .regularFile:
            guard Darwin.unlinkat(parentFD, name, 0) == 0 else {
                throw posix("unlinkat", path)
            }
        case .directory:
            let directory = try openAt(
                parentFD: parentFD,
                name: name,
                flags: O_RDONLY | O_DIRECTORY,
                displayPath: path
            )
            let listing = try directoryNames(
                descriptor: directory.rawValue,
                displayPath: path,
                honorCancellation: budget.honorCancellation
            )
            if listing.truncated {
                throw SecureWorkspaceIOError.traversalLimit(
                    kind: "entries per directory",
                    limit: Self.maximumDirectoryEntries
                )
            }
            for childName in listing.names {
                var childInfo = Darwin.stat()
                let childPath = Self.join(path, childName)
                guard Darwin.fstatat(
                    directory.rawValue,
                    childName,
                    &childInfo,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    throw posix("fstatat", childPath)
                }
                if Self.kind(of: childInfo) == .symbolicLink {
                    throw SecureWorkspaceIOError.symbolicLink(childPath)
                }
                try removeEntry(
                    parentFD: directory.rawValue,
                    name: childName,
                    path: childPath,
                    knownInfo: childInfo,
                    depth: depth + 1,
                    budget: &budget
                )
            }
            guard Darwin.unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else {
                throw posix("unlinkat", path)
            }
        case .symbolicLink:
            throw SecureWorkspaceIOError.symbolicLink(path)
        case .other:
            throw SecureWorkspaceIOError.unsupportedFileType(path)
        }
    }

    private func removeEntryIfIdentityMatches(
        parentFD: Int32,
        name: String,
        expected: Darwin.stat,
        path: String,
        maximumBytes: Int64
    ) {
        guard let current = try? lstat(parentFD: parentFD, name: name, path: path),
              current.st_dev == expected.st_dev,
              current.st_ino == expected.st_ino else { return }
        var cleanupBudget = TraversalBudget(
            maximumEntries: Self.maximumTreeEntries,
            maximumBytes: maximumBytes,
            honorCancellation: false
        )
        try? removeEntry(
            parentFD: parentFD,
            name: name,
            path: path,
            knownInfo: current,
            depth: 0,
            budget: &cleanupBudget
        )
    }

    private func setPermissions(path: String, permissions: Int) throws {
        let relative = try validator.secureRelativePath(for: path)
        let descriptor = try openExisting(relative: relative, flags: O_RDONLY, displayPath: path)
        guard Darwin.fchmod(descriptor.rawValue, mode_t(permissions)) == 0 else {
            throw posix("fchmod", path)
        }
    }

    /// Returns false only when the mounted filesystem explicitly reports that
    /// exclusive rename is unsupported. The caller then uses the bounded,
    /// exclusive-create copy/remove transaction; all other failures remain
    /// fail-closed.
    private func renameExclusively(
        sourceParentFD: Int32,
        sourceName: String,
        destinationParentFD: Int32,
        destinationName: String,
        displayPath: String
    ) throws -> Bool {
        let flags = RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        if Darwin.renameatx_np(
            sourceParentFD,
            sourceName,
            destinationParentFD,
            destinationName,
            UInt32(flags)
        ) == 0 {
            return true
        }
        let failureCode = errno
        if failureCode == EEXIST {
            throw SecureWorkspaceIOError.alreadyExists(displayPath)
        }
        if failureCode == ENOTSUP || failureCode == EINVAL || failureCode == ENOSYS {
            return false
        }
        throw SecureWorkspaceIOError.posix(
            operation: "renameatx_np exclusive",
            path: displayPath,
            code: failureCode
        )
    }

    private func mutationRelativePath(_ path: String) throws -> String {
        let relative = try validator.secureRelativePath(for: path, access: .write)
        guard relative != "." else {
            throw SecureWorkspaceIOError.invalidMutationPath(path)
        }
        return relative
    }

    private func parentReference(relative: String, displayPath: String) throws -> ParentReference {
        let components = relative.split(separator: "/").map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw SecureWorkspaceIOError.invalidMutationPath(displayPath)
        }
        let parentPath = components.dropLast().joined(separator: "/")
        let descriptor = try openExisting(
            relative: parentPath.isEmpty ? "." : parentPath,
            flags: O_RDONLY | O_DIRECTORY,
            displayPath: displayPath
        )
        return ParentReference(descriptor: descriptor, leaf: leaf, displayPath: displayPath)
    }

    private func openExisting(
        relative: String,
        flags: Int32,
        displayPath: String
    ) throws -> Descriptor {
        let descriptor = Darwin.openat(
            root.rawValue,
            relative,
            flags | O_CLOEXEC | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw SecureWorkspaceIOError.pathDoesNotExist(displayPath) }
            if errno == ELOOP { throw SecureWorkspaceIOError.symbolicLink(displayPath) }
            throw posix("openat", displayPath)
        }
        return Descriptor(descriptor)
    }

    private func openAt(
        parentFD: Int32,
        name: String,
        flags: Int32,
        displayPath: String
    ) throws -> Descriptor {
        let descriptor = Darwin.openat(
            parentFD,
            name,
            flags | O_CLOEXEC | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw SecureWorkspaceIOError.pathDoesNotExist(displayPath) }
            if errno == ELOOP { throw SecureWorkspaceIOError.symbolicLink(displayPath) }
            throw posix("openat", displayPath)
        }
        return Descriptor(descriptor)
    }

    private func lstat(parent: ParentReference) throws -> Darwin.stat? {
        try lstat(
            parentFD: parent.descriptor.rawValue,
            name: parent.leaf,
            path: parent.displayPath
        )
    }

    private func lstat(parentFD: Int32, name: String, path: String) throws -> Darwin.stat? {
        var info = Darwin.stat()
        if Darwin.fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw posix("fstatat", path)
    }

    private func directoryNames(
        descriptor: Int32,
        displayPath: String,
        maximumEntries: Int = SecureWorkspaceIO.maximumDirectoryEntries,
        honorCancellation: Bool = true
    ) throws -> (names: [String], truncated: Bool) {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw posix("dup", displayPath) }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            errno = savedErrno
            throw posix("fdopendir", displayPath)
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        var truncated = false
        errno = 0
        while let entry = Darwin.readdir(directory) {
            if honorCancellation, Task.isCancelled {
                throw SecureWorkspaceIOError.cancelled
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." {
                guard names.count < max(1, maximumEntries) else {
                    truncated = true
                    break
                }
                names.append(name)
            }
            errno = 0
        }
        if errno != 0 { throw posix("readdir", displayPath) }
        return (
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            truncated
        )
    }

    private func read(
        descriptor: Int32,
        maximumBytes: Int,
        displayPath: String,
        honorCancellation: Bool
    ) throws -> (Data, Bool) {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw posix("lseek", displayPath)
        }
        let limit = max(0, maximumBytes)
        var output = Data()
        output.reserveCapacity(min(limit, 1_048_576))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while output.count <= limit {
            if honorCancellation, Task.isCancelled {
                throw SecureWorkspaceIOError.cancelled
            }
            let remaining = limit - min(output.count, limit)
            let desired = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, desired)
            }
            if count == 0 { return (output, false) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posix("read", displayPath)
            }
            let appendCount = min(count, max(0, limit - output.count))
            if appendCount > 0 { output.append(contentsOf: buffer.prefix(appendCount)) }
            if count > appendCount { return (output, true) }
        }
        return (output, true)
    }

    private func write(
        _ data: Data,
        descriptor: Int32,
        displayPath: String,
        honorCancellation: Bool
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            try writeBytes(
                base,
                count: bytes.count,
                descriptor: descriptor,
                displayPath: displayPath,
                honorCancellation: honorCancellation
            )
        }
    }

    private func writeBytes(
        _ baseAddress: UnsafeRawPointer,
        count: Int,
        descriptor: Int32,
        displayPath: String,
        honorCancellation: Bool = true
    ) throws {
        var offset = 0
        while offset < count {
            if honorCancellation, Task.isCancelled {
                throw SecureWorkspaceIOError.cancelled
            }
            let written = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                count - offset
            )
            if written < 0 {
                if errno == EINTR { continue }
                throw posix("write", displayPath)
            }
            guard written > 0 else { throw posix("write", displayPath) }
            offset += written
        }
    }

    private func posix(_ operation: String, _ path: String) -> SecureWorkspaceIOError {
        SecureWorkspaceIOError.posix(operation: operation, path: path, code: errno)
    }

    private static func metadata(from info: Darwin.stat) -> SecureWorkspaceMetadata {
        SecureWorkspaceMetadata(
            kind: kind(of: info),
            byteCount: info.st_size,
            permissions: Int(info.st_mode & 0o7777),
            createdAt: date(from: info.st_birthtimespec),
            modifiedAt: date(from: info.st_mtimespec)
        )
    }

    /// Returns true only when a descriptor still represents the exact file
    /// version observed before a read. Size alone is insufficient because an
    /// in-place writer can replace bytes without changing the file length.
    /// Comparing both timestamp components is intentional: APFS exposes
    /// sub-second changes that a whole-second comparison would miss.
    static func hasStableReadIdentity(initial: Darwin.stat, final: Darwin.stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }

    private static func kind(of info: Darwin.stat) -> SecureWorkspaceEntryKind {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }

    private static func date(from value: timespec) -> Date {
        Date(
            timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
        )
    }

    private static func join(_ parent: String, _ child: String) -> String {
        if parent.isEmpty || parent == "." { return child.isEmpty ? parent : child }
        if child.isEmpty { return parent }
        return parent + "/" + child
    }

    private static func pathDepth(_ path: String) -> Int {
        path.isEmpty ? 0 : path.split(separator: "/").count
    }
}
