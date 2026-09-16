import Darwin
import Foundation

protocol BrowserAnnotationPersisting: Sendable {
    func annotations(sessionID: UUID) async throws -> [BrowserAnnotationContext]
    func save(_ draft: BrowserAnnotationDraft) async throws -> BrowserAnnotationContext
    func save(_ context: BrowserAnnotationContext) async throws -> BrowserAnnotationContext
    func remove(annotationID: UUID, sessionID: UUID) async throws
    func removeAll(sessionID: UUID) async throws
}

enum BrowserAnnotationStoreError: LocalizedError, Equatable, Sendable {
    case invalidStorageRoot
    case invalidStorageEntry
    case invalidSessionFile
    case unsupportedEnvelope(Int)
    case sessionMismatch
    case duplicateAnnotation
    case tooManyAnnotations(Int)
    case tooManySessions(Int)
    case oversized(Int)
    case totalSizeExceeded(Int)
    case persistenceFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidStorageRoot:
            "Browser annotation storage is outside the repository-local temporary root."
        case .invalidStorageEntry:
            "Browser annotation storage contains an unsafe entry."
        case .invalidSessionFile:
            "Browser annotation session data is not a bounded regular file."
        case .unsupportedEnvelope(let version):
            "Unsupported browser annotation store version \(version)."
        case .sessionMismatch:
            "Browser annotation session identity does not match its storage record."
        case .duplicateAnnotation:
            "Browser annotation storage contains a duplicate annotation ID."
        case .tooManyAnnotations(let maximum):
            "Browser annotation session exceeds \(maximum) annotations."
        case .tooManySessions(let maximum):
            "Browser annotation storage exceeds \(maximum) sessions."
        case .oversized(let maximum):
            "Browser annotation session data exceeds \(maximum) bytes."
        case .totalSizeExceeded(let maximum):
            "Browser annotation storage exceeds \(maximum) bytes."
        case .persistenceFailure(let operation):
            "Browser annotation persistence failed during \(operation)."
        }
    }
}

/// Repository-local, metadata-only annotation storage.
///
/// Each Session is one atomically replaced JSON file under the exact
/// `tmp/browser-annotations` tree. Directory and file access is descriptor
/// relative with `O_NOFOLLOW_ANY`; caller strings never become path
/// components. Screenshot bytes are not accepted by this API or represented in
/// the encoded envelope.
actor BrowserAnnotationStore: BrowserAnnotationPersisting {
    private struct Envelope: Codable {
        var version: Int
        var sessionID: UUID
        var annotations: [BrowserAnnotationContext]
    }

    private static let envelopeVersion = 1
    private static let lockName = ".browser-annotation.lock"
    private static let temporaryPrefix = ".temporary-"

    private let root: URL
    private let validator: BrowserAnnotationContextValidator

    init(
        root: URL = AppPaths.browserAnnotations,
        validator: BrowserAnnotationContextValidator = BrowserAnnotationContextValidator()
    ) {
        self.root = root.standardizedFileURL
        self.validator = validator
    }

    func annotations(sessionID: UUID) throws -> [BrowserAnnotationContext] {
        guard isNonzero(sessionID) else {
            throw BrowserAnnotationStoreError.sessionMismatch
        }
        guard let rootFD = try openStorageRoot(createIfNeeded: false) else { return [] }
        defer { Darwin.close(rootFD) }
        return try withStoreLock(below: rootFD) {
            try readAnnotations(sessionID: sessionID, below: rootFD)
        }
    }

    func annotation(
        id: UUID,
        sessionID: UUID
    ) throws -> BrowserAnnotationContext? {
        guard isNonzero(id) else { return nil }
        return try annotations(sessionID: sessionID).first { $0.id == id }
    }

    func save(_ draft: BrowserAnnotationDraft) throws -> BrowserAnnotationContext {
        try save(validator.validated(draft))
    }

    @discardableResult
    func save(_ context: BrowserAnnotationContext) throws -> BrowserAnnotationContext {
        let canonical = try validator.validated(context)
        let rootFD = try requireStorageRoot(createIfNeeded: true)
        defer { Darwin.close(rootFD) }
        return try withStoreLock(below: rootFD) {
            var records = try readAnnotations(sessionID: canonical.sessionID, below: rootFD)
            if let index = records.firstIndex(where: { $0.id == canonical.id }) {
                records[index] = canonical
            } else {
                records.append(canonical)
            }
            records = try validatedCollection(records, sessionID: canonical.sessionID)
            let envelope = Envelope(
                version: Self.envelopeVersion,
                sessionID: canonical.sessionID,
                annotations: records
            )
            let data = try encode(envelope)
            let fileName = sessionFileName(canonical.sessionID)
            try validateRootQuota(
                below: rootFD,
                replacing: fileName,
                withBytes: data.count
            )
            try atomicWrite(data, named: fileName, below: rootFD)
            return canonical
        }
    }

    func remove(annotationID: UUID, sessionID: UUID) throws {
        guard isNonzero(annotationID), isNonzero(sessionID) else {
            throw BrowserAnnotationStoreError.sessionMismatch
        }
        guard let rootFD = try openStorageRoot(createIfNeeded: false) else { return }
        defer { Darwin.close(rootFD) }
        try withStoreLock(below: rootFD) {
            var records = try readAnnotations(sessionID: sessionID, below: rootFD)
            guard records.contains(where: { $0.id == annotationID }) else { return }
            records.removeAll { $0.id == annotationID }
            if records.isEmpty {
                try unlinkSessionFile(sessionID: sessionID, below: rootFD)
            } else {
                let envelope = Envelope(
                    version: Self.envelopeVersion,
                    sessionID: sessionID,
                    annotations: try validatedCollection(records, sessionID: sessionID)
                )
                let data = try encode(envelope)
                let fileName = sessionFileName(sessionID)
                try validateRootQuota(
                    below: rootFD,
                    replacing: fileName,
                    withBytes: data.count
                )
                try atomicWrite(data, named: fileName, below: rootFD)
            }
        }
    }

    func removeAll(sessionID: UUID) throws {
        guard isNonzero(sessionID) else {
            throw BrowserAnnotationStoreError.sessionMismatch
        }
        guard let rootFD = try openStorageRoot(createIfNeeded: false) else { return }
        defer { Darwin.close(rootFD) }
        try withStoreLock(below: rootFD) {
            try unlinkSessionFile(sessionID: sessionID, below: rootFD)
        }
    }

    private func readAnnotations(
        sessionID: UUID,
        below rootFD: Int32
    ) throws -> [BrowserAnnotationContext] {
        let fileName = sessionFileName(sessionID)
        guard let data = try readRegularFileIfPresent(named: fileName, below: rootFD) else {
            return []
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw BrowserAnnotationStoreError.invalidSessionFile
        }
        guard envelope.version == Self.envelopeVersion else {
            throw BrowserAnnotationStoreError.unsupportedEnvelope(envelope.version)
        }
        guard envelope.sessionID == sessionID else {
            throw BrowserAnnotationStoreError.sessionMismatch
        }
        let validated = try validatedCollection(
            envelope.annotations,
            sessionID: sessionID
        )
        // The persistence boundary never repairs hostile/tampered content in
        // place. Any string requiring trimming, secret redaction, URL
        // sanitization, or trust relabeling makes the record fail closed.
        guard validated == envelope.annotations else {
            throw BrowserAnnotationValidationError.nonCanonicalPersistedContext
        }
        return validated
    }

    private func validatedCollection(
        _ contexts: [BrowserAnnotationContext],
        sessionID: UUID
    ) throws -> [BrowserAnnotationContext] {
        guard contexts.count <= BrowserAnnotationLimits.maximumContextsPerSession else {
            throw BrowserAnnotationStoreError.tooManyAnnotations(
                BrowserAnnotationLimits.maximumContextsPerSession
            )
        }
        var ids = Set<UUID>()
        var ownerTaskID: UUID?
        var validated: [BrowserAnnotationContext] = []
        validated.reserveCapacity(contexts.count)
        for context in contexts {
            guard context.sessionID == sessionID else {
                throw BrowserAnnotationStoreError.sessionMismatch
            }
            if let ownerTaskID, context.ownerTaskID != ownerTaskID {
                throw BrowserAnnotationStoreError.sessionMismatch
            }
            ownerTaskID = context.ownerTaskID
            guard ids.insert(context.id).inserted else {
                throw BrowserAnnotationStoreError.duplicateAnnotation
            }
            validated.append(try validator.validated(context))
        }
        return validated.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= BrowserAnnotationLimits.maximumSessionFileBytes else {
            throw BrowserAnnotationStoreError.oversized(
                BrowserAnnotationLimits.maximumSessionFileBytes
            )
        }
        return data
    }

    /// Opens every component from the checked repository descriptor. A test
    /// may select a descendant of `browser-annotations`, but no initializer can
    /// redirect persistence elsewhere.
    private func openStorageRoot(createIfNeeded: Bool) throws -> Int32? {
        let allowedRoot = AppPaths.browserAnnotations.standardizedFileURL
        guard root.isFileURL,
              root.path == allowedRoot.path || root.path.hasPrefix(allowedRoot.path + "/") else {
            throw BrowserAnnotationStoreError.invalidStorageRoot
        }

        let repositoryRoot = AppPaths.projectTemporaryRoot
            .deletingLastPathComponent()
            .standardizedFileURL
        guard allowedRoot.path.hasPrefix(repositoryRoot.path + "/"),
              root.path.hasPrefix(repositoryRoot.path + "/") else {
            throw BrowserAnnotationStoreError.invalidStorageRoot
        }
        let relative = String(root.path.dropFirst(repositoryRoot.path.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ isSafeStorageComponent(String($0)) }) else {
            throw BrowserAnnotationStoreError.invalidStorageRoot
        }

        var current = repositoryRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
        }
        guard current >= 0 else {
            throw BrowserAnnotationStoreError.invalidStorageRoot
        }

        for component in components {
            let name = String(component)
            if createIfNeeded,
               Darwin.mkdirat(current, name, mode_t(0o700)) != 0,
               errno != EEXIST {
                Darwin.close(current)
                throw persistenceFailure("creating storage directory")
            }
            let next = Darwin.openat(
                current,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
            )
            if next < 0 {
                let savedErrno = errno
                Darwin.close(current)
                if !createIfNeeded, savedErrno == ENOENT { return nil }
                errno = savedErrno
                throw BrowserAnnotationStoreError.invalidStorageRoot
            }
            var info = Darwin.stat()
            guard Darwin.fstat(next, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(next)
                Darwin.close(current)
                throw BrowserAnnotationStoreError.invalidStorageRoot
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private func requireStorageRoot(createIfNeeded: Bool) throws -> Int32 {
        guard let descriptor = try openStorageRoot(createIfNeeded: createIfNeeded) else {
            throw BrowserAnnotationStoreError.invalidStorageRoot
        }
        return descriptor
    }

    private func withStoreLock<T>(
        below rootFD: Int32,
        operation: () throws -> T
    ) throws -> T {
        let lockFD = Darwin.openat(
            rootFD,
            Self.lockName,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY,
            mode_t(0o600)
        )
        guard lockFD >= 0 else { throw persistenceFailure("opening storage lock") }
        defer { Darwin.close(lockFD) }
        var info = Darwin.stat()
        guard Darwin.fstat(lockFD, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            throw BrowserAnnotationStoreError.invalidStorageEntry
        }

        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while Darwin.fcntl(lockFD, F_SETLK, &lock) != 0 {
            if errno == EINTR { continue }
            if errno == EACCES || errno == EAGAIN {
                if Task.isCancelled { throw CancellationError() }
                guard ContinuousClock.now < deadline else {
                    throw persistenceFailure("acquiring storage lock")
                }
                Darwin.usleep(10_000)
                continue
            }
            throw persistenceFailure("acquiring storage lock")
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(lockFD, F_SETLK, &lock)
        }
        return try operation()
    }

    private func readRegularFileIfPresent(
        named name: String,
        below rootFD: Int32
    ) throws -> Data? {
        let descriptor = Darwin.openat(
            rootFD,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BrowserAnnotationStoreError.invalidSessionFile
        }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= off_t(BrowserAnnotationLimits.maximumSessionFileBytes) else {
            throw BrowserAnnotationStoreError.invalidSessionFile
        }
        let expectedBytes = Int(info.st_size)
        var data = Data(count: expectedBytes)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < expectedBytes {
                if Task.isCancelled { throw CancellationError() }
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    expectedBytes - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw persistenceFailure("reading session file")
                }
                guard count > 0 else {
                    throw BrowserAnnotationStoreError.invalidSessionFile
                }
                offset += count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else {
            throw BrowserAnnotationStoreError.invalidSessionFile
        }
        return data
    }

    private func atomicWrite(
        _ data: Data,
        named destinationName: String,
        below rootFD: Int32
    ) throws {
        var destinationInfo = Darwin.stat()
        if Darwin.fstatat(
            rootFD,
            destinationName,
            &destinationInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard destinationInfo.st_mode & S_IFMT == S_IFREG,
                  destinationInfo.st_nlink == 1 else {
                throw BrowserAnnotationStoreError.invalidSessionFile
            }
        } else if errno != ENOENT {
            throw persistenceFailure("checking destination")
        }

        let temporaryName = Self.temporaryPrefix + UUID().uuidString.lowercased()
        let descriptor = Darwin.openat(
            rootFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw persistenceFailure("creating temporary file") }
        var descriptorIsOpen = true
        var temporaryExists = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if temporaryExists { _ = Darwin.unlinkat(rootFD, temporaryName, 0) }
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if Task.isCancelled { throw CancellationError() }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw persistenceFailure("writing temporary file")
                }
                guard count > 0 else {
                    throw persistenceFailure("writing temporary file")
                }
                offset += count
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw persistenceFailure("synchronizing temporary file")
        }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw persistenceFailure("closing temporary file") }
        guard Darwin.renameat(
            rootFD,
            temporaryName,
            rootFD,
            destinationName
        ) == 0 else {
            throw persistenceFailure("replacing session file")
        }
        temporaryExists = false
        guard Darwin.fsync(rootFD) == 0 else {
            throw persistenceFailure("synchronizing storage directory")
        }
    }

    private func validateRootQuota(
        below rootFD: Int32,
        replacing destinationName: String,
        withBytes newBytes: Int
    ) throws {
        let duplicate = Darwin.dup(rootFD)
        guard duplicate >= 0 else { throw persistenceFailure("duplicating storage handle") }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            errno = savedErrno
            throw persistenceFailure("opening storage directory")
        }
        defer { Darwin.closedir(directory) }

        var sessionCount = 0
        var storedBytes = 0
        var destinationBytes = 0
        var destinationExists = false
        errno = 0
        while let entry = Darwin.readdir(directory) {
            if Task.isCancelled { throw CancellationError() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." || name == Self.lockName {
                errno = 0
                continue
            }
            var info = Darwin.stat()
            guard Darwin.fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1,
                  info.st_size >= 0,
                  info.st_size <= off_t(BrowserAnnotationLimits.maximumSessionFileBytes) else {
                throw BrowserAnnotationStoreError.invalidStorageEntry
            }
            let bytes = Int(info.st_size)
            guard storedBytes <= BrowserAnnotationLimits.maximumStoredBytes - bytes else {
                throw BrowserAnnotationStoreError.totalSizeExceeded(
                    BrowserAnnotationLimits.maximumStoredBytes
                )
            }
            storedBytes += bytes

            if isSessionFileName(name) {
                sessionCount += 1
                if name == destinationName {
                    destinationExists = true
                    destinationBytes = bytes
                }
            } else if name.hasPrefix(Self.temporaryPrefix) || name.hasPrefix("._") {
                // A crash may leave a same-directory temporary file. It has no
                // authority and still counts toward the byte quota.
            } else {
                throw BrowserAnnotationStoreError.invalidStorageEntry
            }
            errno = 0
        }
        if errno != 0 { throw persistenceFailure("enumerating storage directory") }
        let prospectiveCount = sessionCount + (destinationExists ? 0 : 1)
        guard prospectiveCount <= BrowserAnnotationLimits.maximumStoredSessions else {
            throw BrowserAnnotationStoreError.tooManySessions(
                BrowserAnnotationLimits.maximumStoredSessions
            )
        }
        let retainedBytes = storedBytes - destinationBytes
        guard newBytes <= BrowserAnnotationLimits.maximumStoredBytes - retainedBytes else {
            throw BrowserAnnotationStoreError.totalSizeExceeded(
                BrowserAnnotationLimits.maximumStoredBytes
            )
        }
    }

    private func unlinkSessionFile(sessionID: UUID, below rootFD: Int32) throws {
        let name = sessionFileName(sessionID)
        var info = Darwin.stat()
        guard Darwin.fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw persistenceFailure("checking session file")
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else {
            throw BrowserAnnotationStoreError.invalidSessionFile
        }
        guard Darwin.unlinkat(rootFD, name, 0) == 0,
              Darwin.fsync(rootFD) == 0 else {
            throw persistenceFailure("removing session file")
        }
    }

    private func sessionFileName(_ sessionID: UUID) -> String {
        sessionID.uuidString.lowercased() + ".json"
    }

    private func isSessionFileName(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[1] == "json",
              let id = UUID(uuidString: String(parts[0])) else { return false }
        return String(parts[0]) == id.uuidString.lowercased()
    }

    private func isNonzero(_ value: UUID) -> Bool {
        value.uuidString != "00000000-0000-0000-0000-000000000000"
    }

    private func isSafeStorageComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...90, 97...122, 45, 46, 95: // 0-9 A-Z a-z - . _
                    true
                default:
                    false
                }
            }
    }

    private func persistenceFailure(_ operation: String) -> BrowserAnnotationStoreError {
        .persistenceFailure(operation)
    }
}
