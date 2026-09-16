import Darwin
import Dispatch
import Foundation

struct WorkspaceSearchLimits: Sendable {
    var maximumEntries = 100_000
    var maximumTraversalBytes = 64 * 1_024 * 1_024
    var maximumDuration: TimeInterval = 10
    var maximumDepth = 128
    var maximumRegexOperationsPerFile = 250_000
    var maximumRegexOperationsTotal = 5_000_000
    var maximumRegexDurationPerFile: TimeInterval = 0.100
    var maximumRegexDurationTotal: TimeInterval = 2
    var maximumRegexLineBytes = 32 * 1_024

    init(
        maximumEntries: Int = 100_000,
        maximumTraversalBytes: Int = 64 * 1_024 * 1_024,
        maximumDuration: TimeInterval = 10,
        maximumDepth: Int = 128,
        maximumRegexOperationsPerFile: Int = 250_000,
        maximumRegexOperationsTotal: Int = 5_000_000,
        maximumRegexDurationPerFile: TimeInterval = 0.100,
        maximumRegexDurationTotal: TimeInterval = 2,
        maximumRegexLineBytes: Int = 32 * 1_024
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumTraversalBytes = max(1, maximumTraversalBytes)
        self.maximumDuration = max(0, maximumDuration)
        self.maximumDepth = max(1, min(maximumDepth, 128))
        self.maximumRegexOperationsPerFile = max(1, maximumRegexOperationsPerFile)
        self.maximumRegexOperationsTotal = max(1, maximumRegexOperationsTotal)
        self.maximumRegexDurationPerFile = max(0, maximumRegexDurationPerFile)
        self.maximumRegexDurationTotal = max(0, maximumRegexDurationTotal)
        self.maximumRegexLineBytes = max(1, maximumRegexLineBytes)
    }
}

struct SecureWorkspaceSearchEntry: Sendable, Equatable {
    var relativePath: String
    var name: String
    var byteCount: Int64
}

/// Streaming, descriptor-relative traversal dedicated to workspace search.
///
/// `SecureWorkspaceIO.enumerate` intentionally returns a materialized tree for
/// list/diff callers. Search has a different requirement: it must be able to stop
/// after a result, entry, byte, time, or cancellation limit without ever building
/// an array proportional to the workspace. This walker therefore consumes
/// `readdir(3)` entries one at a time and opens child directories relative to the
/// already-pinned parent descriptor with no-follow/beneath constraints.
final class SecureWorkspaceSearchTraversal: @unchecked Sendable {
    private final class Descriptor {
        let rawValue: Int32
        init(_ rawValue: Int32) { self.rawValue = rawValue }
        deinit { Darwin.close(rawValue) }
    }

    private struct Budget {
        let limits: WorkspaceSearchLimits
        let deadline: UInt64
        var visitedEntries = 0
        var consumedBytes = 0
        var truncated = false

        init(limits: WorkspaceSearchLimits) {
            self.limits = limits
            let duration = limits.maximumDuration
            let nanoseconds = !duration.isFinite
                || duration >= Double(UInt64.max) / 1_000_000_000
                ? UInt64.max
                : UInt64(duration * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            deadline = UInt64.max - now < nanoseconds ? UInt64.max : now + nanoseconds
        }

        mutating func consumeEntry(path: String) throws -> Bool {
            try Task.checkCancellation()
            guard DispatchTime.now().uptimeNanoseconds <= deadline else {
                truncated = true
                return false
            }
            guard visitedEntries < limits.maximumEntries else {
                truncated = true
                return false
            }
            visitedEntries += 1
            return consumeBytes(path.utf8.count + 1)
        }

        mutating func consumeBytes(_ count: Int) -> Bool {
            let amount = max(0, count)
            guard amount <= limits.maximumTraversalBytes - min(
                consumedBytes,
                limits.maximumTraversalBytes
            ) else {
                truncated = true
                return false
            }
            consumedBytes += amount
            return true
        }
    }

    private let validator: WorkspaceSecurityValidator
    private let baseRelativePath: String
    private let directory: Descriptor
    private var budget: Budget

    init(
        validator: WorkspaceSecurityValidator,
        path: String,
        limits: WorkspaceSearchLimits
    ) throws {
        self.validator = validator
        baseRelativePath = try validator.secureRelativePath(for: path)
        budget = Budget(limits: limits)

        let rootFD = Darwin.open(
            validator.secureRootPath,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard rootFD >= 0 else {
            throw SecureWorkspaceIOError.cannotOpenWorkspace(validator.secureRootPath)
        }
        let root = Descriptor(rootFD)
        let directoryFD = Darwin.openat(
            root.rawValue,
            baseRelativePath,
            O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC
                | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY
        )
        guard directoryFD >= 0 else {
            let code = errno
            if code == ELOOP { throw SecureWorkspaceIOError.symbolicLink(path) }
            if code == ENOENT { throw SecureWorkspaceIOError.pathDoesNotExist(path) }
            throw SecureWorkspaceIOError.posix(operation: "openat", path: path, code: code)
        }
        directory = Descriptor(directoryFD)
    }

    /// Remaining aggregate capacity available for a bounded content read.
    /// The caller passes this value to `SecureWorkspaceIO.readRegularFile`, then
    /// accounts for the bytes actually returned. This also closes a grow-after-
    /// metadata-check race that could otherwise read beyond the aggregate cap.
    func maximumContentReadBytes(upTo requestedMaximum: Int) -> Int {
        max(0, min(
            requestedMaximum,
            budget.limits.maximumTraversalBytes - min(
                budget.consumedBytes,
                budget.limits.maximumTraversalBytes
            )
        ))
    }

    func consumeContentBytes(_ count: Int) -> Bool {
        budget.consumeBytes(count)
    }

    /// Calls `body` for each regular file. Returning false stops immediately and
    /// marks the result truncated. Directory filtering happens before descent.
    func forEachRegularFile(
        shouldDescend: (_ relativePath: String, _ name: String) throws -> Bool,
        body: (SecureWorkspaceSearchEntry) throws -> Bool
    ) throws -> Bool {
        try visit(
            descriptor: directory.rawValue,
            workspaceBase: baseRelativePath,
            resultBase: "",
            depth: 1,
            shouldDescend: shouldDescend,
            body: body
        )
        return budget.truncated
    }

    private func visit(
        descriptor: Int32,
        workspaceBase: String,
        resultBase: String,
        depth: Int,
        shouldDescend: (_ relativePath: String, _ name: String) throws -> Bool,
        body: (SecureWorkspaceSearchEntry) throws -> Bool
    ) throws {
        guard !budget.truncated else { return }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw posix("dup", path: workspaceBase)
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let code = errno
            Darwin.close(duplicate)
            throw SecureWorkspaceIOError.posix(
                operation: "fdopendir",
                path: workspaceBase,
                code: code
            )
        }
        defer { Darwin.closedir(stream) }

        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." {
                errno = 0
                continue
            }

            let relativePath = Self.join(resultBase, name)
            guard try budget.consumeEntry(path: relativePath) else { return }
            if name.hasPrefix(".") {
                errno = 0
                continue
            }
            let workspaceChild = Self.join(workspaceBase, name)
            if validator.isProtectedRuntimeRelativePath(workspaceChild) {
                errno = 0
                continue
            }

            var info = Darwin.stat()
            guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                // Entries may disappear during a search. They cannot be followed
                // outside the pinned descriptor, so treating a race as skipped is
                // both safe and more useful than aborting the whole query.
                if code == ENOENT || code == ELOOP {
                    errno = 0
                    continue
                }
                throw SecureWorkspaceIOError.posix(
                    operation: "fstatat",
                    path: workspaceChild,
                    code: code
                )
            }

            switch info.st_mode & S_IFMT {
            case S_IFREG:
                let shouldContinue = try body(SecureWorkspaceSearchEntry(
                    relativePath: relativePath,
                    name: name,
                    byteCount: info.st_size
                ))
                guard shouldContinue else {
                    budget.truncated = true
                    return
                }

            case S_IFDIR:
                guard try shouldDescend(relativePath, name) else {
                    errno = 0
                    continue
                }
                guard depth < budget.limits.maximumDepth else {
                    budget.truncated = true
                    errno = 0
                    continue
                }
                let childFD = Darwin.openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC
                        | O_RESOLVE_BENEATH | O_NOFOLLOW_ANY
                )
                if childFD >= 0 {
                    let child = Descriptor(childFD)
                    try visit(
                        descriptor: child.rawValue,
                        workspaceBase: workspaceChild,
                        resultBase: relativePath,
                        depth: depth + 1,
                        shouldDescend: shouldDescend,
                        body: body
                    )
                    if budget.truncated { return }
                } else if errno != ENOENT && errno != ELOOP {
                    throw posix("openat", path: workspaceChild)
                }

            default:
                // Symlinks, FIFOs, sockets, and devices are never opened.
                break
            }
            errno = 0
        }
        if errno != 0 { throw posix("readdir", path: workspaceBase) }
    }

    private func posix(_ operation: String, path: String) -> SecureWorkspaceIOError {
        .posix(operation: operation, path: path, code: errno)
    }

    private static func join(_ parent: String, _ child: String) -> String {
        if parent.isEmpty || parent == "." { return child }
        return parent + "/" + child
    }
}
