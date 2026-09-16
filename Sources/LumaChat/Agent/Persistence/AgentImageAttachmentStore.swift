import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imports model-visible images through the pinned workspace descriptor, then
/// keeps a private copy with the Agent session. The returned reference contains
/// no authority to read an arbitrary path; loading always revalidates the fixed
/// `Attachments/<UUID>.<ext>` shape below the caller-provided session ID.
final class AgentImageAttachmentStore: @unchecked Sendable {
    private let sessionsRoot: URL
    private let maximumFileBytes: Int
    private let maximumSessionAttachments: Int
    private let maximumSessionBytes: Int

    init(
        sessionsRoot: URL = AppPaths.agentSessions,
        maximumFileBytes: Int = AgentImageAttachmentLimits.maximumFileBytes,
        maximumSessionAttachments: Int = AgentImageAttachmentLimits.maximumStoredAttachmentsPerSession,
        maximumSessionBytes: Int = AgentImageAttachmentLimits.maximumStoredBytesPerSession
    ) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.maximumFileBytes = min(
            max(1, maximumFileBytes),
            AgentImageAttachmentLimits.maximumFileBytes
        )
        self.maximumSessionAttachments = min(
            max(1, maximumSessionAttachments),
            AgentImageAttachmentLimits.maximumStoredAttachmentsPerSession
        )
        self.maximumSessionBytes = min(
            max(1, maximumSessionBytes),
            AgentImageAttachmentLimits.maximumStoredBytesPerSession
        )
    }

    func importWorkspaceImage(
        path: String,
        sessionID: UUID,
        validator: WorkspaceSecurityValidator
    ) throws -> AgentImageAttachmentReference {
        let sourceExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let expectedMIME = try Self.mimeType(forExtension: sourceExtension)
        let secureIO = try SecureWorkspaceIO(validator: validator)
        let read = try secureIO.readRegularFile(path: path, maximumBytes: maximumFileBytes)
        guard !read.truncated else {
            throw AgentImageAttachmentError.fileTooLarge(maximumFileBytes)
        }
        let fallbackExtension = expectedMIME == "image/jpeg"
            ? "jpg"
            : String(expectedMIME.dropFirst("image/".count))
        return try storeImageData(
            read.data,
            expectedMIME: expectedMIME,
            displayName: Self.safeDisplayName(
                path: path,
                fallbackExtension: fallbackExtension
            ),
            sessionID: sessionID
        )
    }

    /// Stores a host-generated screenshot without granting it authority to an
    /// arbitrary filesystem path. The bytes pass through the same signature,
    /// decode, dimension and per-session quota checks as workspace images.
    func importGeneratedPNG(
        _ data: Data,
        name: String,
        sessionID: UUID
    ) throws -> AgentImageAttachmentReference {
        try storeImageData(
            data,
            expectedMIME: "image/png",
            displayName: Self.safeDisplayName(
                path: name.hasSuffix(".png") ? name : name + ".png",
                fallbackExtension: "png"
            ),
            sessionID: sessionID
        )
    }

    func loadPayload(
        for reference: AgentImageAttachmentReference,
        sessionID: UUID
    ) throws -> AgentImagePayload {
        try AgentImageAttachmentLimits.validate([reference])
        let components = reference.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2, components[0] == "Attachments" else {
            throw AgentImageAttachmentError.invalidReference(reference.relativePath)
        }

        let root = try openSessionsRoot(createIfNeeded: false)
        defer { Darwin.close(root) }
        let session = try openDirectory(
            named: sessionID.uuidString,
            below: root,
            createIfNeeded: false,
            displayPath: sessionID.uuidString
        )
        defer { Darwin.close(session) }
        let attachments = try openDirectory(
            named: "Attachments",
            below: session,
            createIfNeeded: false,
            displayPath: "\(sessionID.uuidString)/Attachments"
        )
        defer { Darwin.close(attachments) }
        let data = try readRegularFile(
            named: String(components[1]),
            below: attachments,
            expectedBytes: reference.byteCount,
            displayPath: reference.relativePath
        )
        let inspected = try Self.inspect(
            data,
            expectedMIME: reference.mimeType,
            maximumFileBytes: maximumFileBytes
        )
        guard inspected.width == reference.pixelWidth,
              inspected.height == reference.pixelHeight else {
            throw AgentImageAttachmentError.payloadMismatch(reference.id)
        }
        return try AgentImagePayload(reference: reference, data: data)
    }

    func loadPayloads(
        for references: [AgentImageAttachmentReference],
        sessionID: UUID
    ) throws -> [AgentImagePayload] {
        try AgentImageAttachmentLimits.validate(references)
        let payloads = try references.map { try loadPayload(for: $0, sessionID: sessionID) }
        try AgentImageAttachmentLimits.validate(payloads)
        return payloads
    }

    func remove(
        _ reference: AgentImageAttachmentReference,
        sessionID: UUID
    ) throws {
        try AgentImageAttachmentLimits.validate([reference])
        let components = reference.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 2, components[0] == "Attachments" else {
            throw AgentImageAttachmentError.invalidReference(reference.relativePath)
        }
        let root = try openSessionsRoot(createIfNeeded: false)
        defer { Darwin.close(root) }
        let session = try openDirectory(
            named: sessionID.uuidString,
            below: root,
            createIfNeeded: false,
            displayPath: sessionID.uuidString
        )
        defer { Darwin.close(session) }
        let attachments = try openDirectory(
            named: "Attachments",
            below: session,
            createIfNeeded: false,
            displayPath: "\(sessionID.uuidString)/Attachments"
        )
        defer { Darwin.close(attachments) }
        try withAttachmentLock(below: attachments) {
            let name = String(components[1])
            guard Self.isSafeComponent(name) else {
                throw AgentImageAttachmentError.invalidReference(reference.relativePath)
            }
            var info = Darwin.stat()
            guard Darwin.fstatat(attachments, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size == off_t(reference.byteCount) else {
                throw AgentImageAttachmentError.payloadMismatch(reference.id)
            }
            guard Darwin.unlinkat(attachments, name, 0) == 0 else {
                throw persistenceError("unlinkat", reference.relativePath)
            }
            _ = Darwin.fsync(attachments)
        }
    }

    private struct InspectedImage {
        var mimeType: String
        var width: Int
        var height: Int
    }

    private func storeImageData(
        _ data: Data,
        expectedMIME: String,
        displayName: String,
        sessionID: UUID
    ) throws -> AgentImageAttachmentReference {
        let inspected = try Self.inspect(
            data,
            expectedMIME: expectedMIME,
            maximumFileBytes: maximumFileBytes
        )
        let id = UUID()
        let storedExtension = inspected.mimeType == "image/jpeg"
            ? "jpg"
            : String(inspected.mimeType.dropFirst("image/".count))
        let storedName = "\(id.uuidString.lowercased()).\(storedExtension)"
        let reference = try AgentImageAttachmentReference(
            id: id,
            name: displayName,
            relativePath: "Attachments/\(storedName)",
            mimeType: inspected.mimeType,
            byteCount: data.count,
            pixelWidth: inspected.width,
            pixelHeight: inspected.height,
            sha256: AgentImageAttachmentLimits.digestHex(data)
        )

        let root = try openSessionsRoot(createIfNeeded: true)
        defer { Darwin.close(root) }
        let session = try openDirectory(
            named: sessionID.uuidString,
            below: root,
            createIfNeeded: true,
            displayPath: sessionID.uuidString
        )
        defer { Darwin.close(session) }
        let attachments = try openDirectory(
            named: "Attachments",
            below: session,
            createIfNeeded: true,
            displayPath: "\(sessionID.uuidString)/Attachments"
        )
        defer { Darwin.close(attachments) }
        try withAttachmentLock(below: attachments) {
            try validateSessionQuota(below: attachments, addingBytes: data.count)
            try writeExclusive(
                data,
                named: storedName,
                below: attachments,
                displayPath: reference.relativePath
            )
        }
        return reference
    }

    private static func inspect(
        _ data: Data,
        expectedMIME: String,
        maximumFileBytes: Int
    ) throws -> InspectedImage {
        guard !data.isEmpty, data.count <= maximumFileBytes else {
            throw AgentImageAttachmentError.fileTooLarge(maximumFileBytes)
        }
        guard sniffedMIMEType(data) == expectedMIME else {
            throw AgentImageAttachmentError.invalidImage("副檔名與檔案 signature 不一致")
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) == 1,
           CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
           let typeIdentifier = CGImageSourceGetType(source) as String?,
           mimeType(forImageSourceType: typeIdentifier) == expectedMIME,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0,
           height > 0,
           width <= AgentImageAttachmentLimits.maximumDimension,
           height <= AgentImageAttachmentLimits.maximumDimension,
           width <= AgentImageAttachmentLimits.maximumPixels / height else {
            throw AgentImageAttachmentError.invalidImage("無法安全解碼影像或尺寸超過上限")
        }
        guard CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
            ] as CFDictionary
        ) != nil else {
            throw AgentImageAttachmentError.invalidImage("影像資料不完整")
        }
        return InspectedImage(mimeType: expectedMIME, width: width, height: height)
    }

    private static func mimeType(forExtension value: String) throws -> String {
        switch value {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: throw AgentImageAttachmentError.unsupportedType(value.isEmpty ? "unknown" : value)
        }
    }

    private static func mimeType(forImageSourceType identifier: String) -> String? {
        let normalized = identifier.lowercased()
        let candidates: [(String, String)] = [
            ("png", "image/png"),
            ("jpg", "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("webp", "image/webp")
        ]
        for (fileExtension, mimeType) in candidates {
            if UTType(filenameExtension: fileExtension)?.identifier.lowercased() == normalized {
                return mimeType
            }
        }
        return switch normalized {
        case "public.png": "image/png"
        case "public.jpeg": "image/jpeg"
        case "org.webmproject.webp", "public.webp": "image/webp"
        default: nil
        }
    }

    private static func sniffedMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A][0...7] {
            return "image/png"
        }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46][0...3],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50][0...3] {
            return "image/webp"
        }
        return nil
    }

    private static func safeDisplayName(path: String, fallbackExtension: String) -> String {
        let original = URL(fileURLWithPath: path).lastPathComponent
        var output = ""
        for scalar in original.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let candidate = output + String(scalar)
            guard candidate.utf8.count <= AgentImageAttachmentLimits.maximumNameBytes else { break }
            output = candidate
        }
        return output.isEmpty ? "image.\(fallbackExtension)" : output
    }

    private func openSessionsRoot(createIfNeeded: Bool) throws -> Int32 {
        if createIfNeeded {
            do {
                try FileManager.default.createDirectory(
                    at: sessionsRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                // This failure can become a model-visible tool result. Do not
                // include the host's Application Support path in that result.
                throw storageRootError("createDirectory")
            }
        }
        let descriptor = sessionsRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        }
        guard descriptor >= 0 else {
            throw storageRootError("open")
        }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            let error = storageRootError("fstat")
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func openDirectory(
        named name: String,
        below parent: Int32,
        createIfNeeded: Bool,
        displayPath: String
    ) throws -> Int32 {
        guard Self.isSafeComponent(name) else {
            throw AgentImageAttachmentError.invalidReference(displayPath)
        }
        if createIfNeeded, Darwin.mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw persistenceError("mkdirat", displayPath)
        }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw persistenceError("openat", displayPath) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            let error = persistenceError("fstat", displayPath)
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func writeExclusive(
        _ data: Data,
        named name: String,
        below parent: Int32,
        displayPath: String
    ) throws {
        guard Self.isSafeComponent(name) else {
            throw AgentImageAttachmentError.invalidReference(displayPath)
        }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY,
            0o600
        )
        guard descriptor >= 0 else { throw persistenceError("openat", displayPath) }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { _ = Darwin.unlinkat(parent, name, 0) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if Task.isCancelled { throw CancellationError() }
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw persistenceError("write", displayPath)
                }
                guard count > 0 else { throw persistenceError("write", displayPath) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw persistenceError("fsync", displayPath) }
        shouldRemove = false
        _ = Darwin.fsync(parent)
    }

    private func validateSessionQuota(below directoryFD: Int32, addingBytes: Int) throws {
        let duplicate = Darwin.dup(directoryFD)
        guard duplicate >= 0 else { throw persistenceError("dup", "Attachments") }
        guard let directory = Darwin.fdopendir(duplicate) else {
            let savedErrno = errno
            Darwin.close(duplicate)
            errno = savedErrno
            throw persistenceError("fdopendir", "Attachments")
        }
        defer { Darwin.closedir(directory) }

        var count = 0
        var bytes = 0
        errno = 0
        while let entry = Darwin.readdir(directory) {
            if Task.isCancelled { throw CancellationError() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." {
                errno = 0
                continue
            }
            if name == ".attachment-lock" || name == "._.attachment-lock" {
                errno = 0
                continue
            }
            var info = Darwin.stat()
            guard Darwin.fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw AgentImageAttachmentError.invalidReference(
                    "session Attachments 無法檢查 entry：\(name)"
                )
            }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0,
                  info.st_size <= off_t(maximumSessionBytes) else {
                throw AgentImageAttachmentError.invalidReference(
                    "session Attachments 含有不安全的 entry：\(name)"
                )
            }
            let appleDoubleSidecar = name.hasPrefix("._")
            guard appleDoubleSidecar || Self.isStoredAttachmentName(name) else {
                throw AgentImageAttachmentError.invalidReference(
                    "session Attachments 含有未知檔案"
                )
            }
            if !appleDoubleSidecar { count += 1 }
            let fileBytes = Int(info.st_size)
            guard bytes <= maximumSessionBytes - min(fileBytes, maximumSessionBytes) else {
                throw AgentImageAttachmentError.totalSizeExceeded(maximumSessionBytes)
            }
            bytes += fileBytes
            errno = 0
        }
        if errno != 0 { throw persistenceError("readdir", "Attachments") }
        guard count < maximumSessionAttachments else {
            throw AgentImageAttachmentError.tooManyAttachments(maximumSessionAttachments)
        }
        guard addingBytes <= maximumSessionBytes - min(bytes, maximumSessionBytes) else {
            throw AgentImageAttachmentError.totalSizeExceeded(maximumSessionBytes)
        }
    }

    private func withAttachmentLock<T>(
        below directoryFD: Int32,
        operation: () throws -> T
    ) throws -> T {
        let lockFD = Darwin.openat(
            directoryFD,
            ".attachment-lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY,
            0o600
        )
        guard lockFD >= 0 else { throw persistenceError("openat", "Attachments lock") }
        defer { Darwin.close(lockFD) }
        var lockInfo = Darwin.stat()
        guard Darwin.fstat(lockFD, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            throw persistenceError("fstat", "Attachments lock")
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
                    errno = EBUSY
                    throw persistenceError("fcntl(F_SETLK)", "Attachments lock")
                }
                Darwin.usleep(10_000)
                continue
            }
            throw persistenceError("fcntl(F_SETLK)", "Attachments lock")
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(lockFD, F_SETLK, &lock)
        }
        return try operation()
    }

    private func readRegularFile(
        named name: String,
        below parent: Int32,
        expectedBytes: Int,
        displayPath: String
    ) throws -> Data {
        guard Self.isSafeComponent(name),
              expectedBytes > 0,
              expectedBytes <= maximumFileBytes else {
            throw AgentImageAttachmentError.invalidReference(displayPath)
        }
        let descriptor = Darwin.openat(
            parent,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else { throw persistenceError("openat", displayPath) }
        defer { Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size == off_t(expectedBytes) else {
            throw AgentImageAttachmentError.payloadMismatch(
                UUID(uuidString: name.split(separator: ".").first.map(String.init) ?? "") ?? UUID()
            )
        }
        var data = Data(count: expectedBytes)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < expectedBytes {
                if Task.isCancelled { throw CancellationError() }
                let count = Darwin.read(descriptor, base.advanced(by: offset), expectedBytes - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw persistenceError("read", displayPath)
                }
                guard count > 0 else {
                    throw AgentImageAttachmentError.invalidImage("附件內容提前結束")
                }
                offset += count
            }
        }
        var extra: UInt8 = 0
        let extraCount = Darwin.read(descriptor, &extra, 1)
        guard extraCount == 0 else {
            throw AgentImageAttachmentError.invalidImage("附件大小與 reference 不一致")
        }
        return data
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func isStoredAttachmentName(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              UUID(uuidString: String(parts[0])) != nil else { return false }
        return parts[1] == "png" || parts[1] == "jpg" || parts[1] == "webp"
    }

    private func persistenceError(_ operation: String, _ path: String) -> NSError {
        NSError(
            domain: "LumaChat.AgentImageAttachmentStore",
            code: Int(errno == 0 ? EIO : errno),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed for \(path): \(String(cString: strerror(errno == 0 ? EIO : errno)))"
            ]
        )
    }

    private func storageRootError(_ operation: String) -> NSError {
        NSError(
            domain: "LumaChat.AgentImageAttachmentStore",
            code: Int(EIO),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed for Agent session attachment storage."
            ]
        )
    }
}
