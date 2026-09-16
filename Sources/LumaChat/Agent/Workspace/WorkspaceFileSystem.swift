import Foundation

enum WorkspaceFileSystemError: LocalizedError, Sendable {
    case notDirectory(String)
    case notRegularFile(String)
    case alreadyExists(String)
    case fileDoesNotExist(String)
    case binaryFile(String)
    case fileTooLarge(path: String, maximumBytes: Int)
    case invalidLineRange
    case exactTextNotFound
    case exactTextIsAmbiguous(Int)
    case tooManyFiles(Int)
    case symbolicLinkInTree(String)
    case mutationInputTooLarge(label: String, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "Not a directory: \(path)"
        case .notRegularFile(let path): "Not a regular file: \(path)"
        case .alreadyExists(let path): "A file already exists at \(path)."
        case .fileDoesNotExist(let path): "File does not exist: \(path)"
        case .binaryFile(let path): "Refusing to edit binary file: \(path)"
        case .fileTooLarge(let path, let maximumBytes):
            "File \(path) exceeds the \(maximumBytes)-byte edit limit."
        case .invalidLineRange: "Line ranges are 1-based and endLine must not precede startLine."
        case .exactTextNotFound: "The exact text to replace was not found."
        case .exactTextIsAmbiguous(let count):
            "The exact text occurs \(count) times; provide a unique match or use a line range."
        case .tooManyFiles(let limit): "A maximum of \(limit) files can be read at once."
        case .symbolicLinkInTree(let path): "Directory tree contains a symbolic link: \(path)"
        case .mutationInputTooLarge(let label, let maximumBytes):
            "\(label) exceeds the \(maximumBytes)-byte mutation input limit."
        }
    }
}

enum WorkspaceEntryType: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

struct WorkspaceDirectoryEntry: Codable, Sendable, Equatable {
    var path: String
    var name: String
    var type: WorkspaceEntryType
    var depth: Int
    var byteCount: Int64?
    var modifiedAt: Date?
}

struct DirectoryListing: Codable, Sendable, Equatable {
    var path: String
    var entries: [WorkspaceDirectoryEntry]
    var truncated: Bool
}

struct ReadFileResult: Codable, Sendable, Equatable {
    var path: String
    var content: String?
    var isBinary: Bool
    var byteCount: Int64
    var startLine: Int?
    var endLine: Int?
    var truncated: Bool
    var message: String?
}

struct WorkspaceFileInfo: Codable, Sendable, Equatable {
    var path: String
    var type: WorkspaceEntryType
    var byteCount: Int64?
    var createdAt: Date?
    var modifiedAt: Date?
    var permissions: String?
    var isReadable: Bool
    var isWritable: Bool
}

struct FileMutationResult: Codable, Sendable, Equatable {
    var paths: [String]
    var change: FileChangeRecord
}

/// The single filesystem boundary used by built-in tools. It deliberately owns
/// no raw workspace root: every operation resolves its path through
/// WorkspaceSecurityValidator immediately before touching the filesystem.
final class WorkspaceFileSystem: @unchecked Sendable {
    private static let maximumMutationInputBytes = 4 * 1_024 * 1_024
    private static let maximumPatchPaths = 256
    private let validator: WorkspaceSecurityValidator
    private let changes: ChangeManager
    private let secureIO: SecureWorkspaceIO?
    private let maximumEditableBytes: Int

    init(
        validator: WorkspaceSecurityValidator,
        changes: ChangeManager,
        fileManager: FileManager = .default,
        maximumEditableBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.validator = validator
        self.changes = changes
        _ = fileManager // Kept for source compatibility with existing callers.
        secureIO = try? SecureWorkspaceIO(validator: validator)
        self.maximumEditableBytes = max(64 * 1_024, maximumEditableBytes)
    }

    func listDirectory(
        path: String,
        depth requestedDepth: Int = 1,
        includeHidden: Bool = false,
        maximumEntries: Int = 2_000
    ) throws -> DirectoryListing {
        let result: SecureWorkspaceEnumeration
        do {
            result = try requireSecureIO().enumerate(
                path: path,
                maximumDepth: max(1, min(requestedDepth, 20)),
                maximumEntries: max(1, min(maximumEntries, 10_000)),
                includeHidden: includeHidden
            )
        } catch SecureWorkspaceIOError.notDirectory {
            throw WorkspaceFileSystemError.notDirectory(path)
        }
        return DirectoryListing(
            path: path,
            entries: result.entries.map { entry in
                WorkspaceDirectoryEntry(
                    path: displayPath(entry.relativePath, base: path),
                    name: entry.name,
                    type: Self.entryType(entry.metadata.kind),
                    depth: entry.depth,
                    byteCount: entry.metadata.kind == .regularFile
                        ? entry.metadata.byteCount
                        : nil,
                    modifiedAt: entry.metadata.modifiedAt
                )
            },
            truncated: result.truncated
        )
    }

    func readFile(
        path: String,
        startLine: Int? = nil,
        endLine: Int? = nil,
        maxBytes requestedMaxBytes: Int = 256 * 1_024
    ) throws -> ReadFileResult {
        let secureIO = try requireSecureIO()
        let maxBytes = max(1_024, min(requestedMaxBytes, 1_048_576))
        let scanLimit = max(8 * 1_024 * 1_024, min(64 * 1_024 * 1_024, maxBytes * 64))
        let read: SecureWorkspaceRead
        do {
            read = try secureIO.readRegularFile(path: path, maximumBytes: scanLimit)
        } catch SecureWorkspaceIOError.notRegularFile {
            throw WorkspaceFileSystemError.notRegularFile(path)
        }
        let byteCount = read.metadata.byteCount
        let sample = read.data.prefix(8_192)
        if Self.looksBinary(sample) {
            return ReadFileResult(
                path: path,
                content: nil,
                isBinary: true,
                byteCount: byteCount,
                startLine: nil,
                endLine: nil,
                truncated: false,
                message: "Binary content omitted; metadata only."
            )
        }

        let firstLine = max(1, startLine ?? 1)
        let lastLine = endLine.map { max(firstLine, $0) }
        guard endLine == nil || endLine! >= firstLine else {
            throw WorkspaceFileSystemError.invalidLineRange
        }

        var output = Data()
        var lineNumber = 1
        var finalReturnedLine: Int?
        var truncated = false
        var scannedBytes = 0
        var truncationMessage: String?

        readLoop: for byte in read.data {
                scannedBytes += 1
                if scannedBytes > scanLimit {
                    truncated = true
                    truncationMessage = "Stopped after scanning \(scanLimit) bytes; search first or request a nearer line range."
                    break readLoop
                }
                let shouldInclude = lineNumber >= firstLine
                    && (lastLine.map { lineNumber <= $0 } ?? true)
                if shouldInclude {
                    guard output.count < maxBytes else {
                        truncated = true
                        truncationMessage = "Content was truncated at \(maxBytes) bytes."
                        break readLoop
                    }
                    output.append(byte)
                    finalReturnedLine = lineNumber
                }
                if byte == 0x0A {
                    if let lastLine, lineNumber >= lastLine { break readLoop }
                    lineNumber += 1
                }
        }
        if read.truncated, !truncated {
            truncated = true
            truncationMessage = "Stopped after scanning \(scanLimit) bytes; search first or request a nearer line range."
        }

        return ReadFileResult(
            path: path,
            content: String(decoding: output, as: UTF8.self),
            isBinary: false,
            byteCount: byteCount,
            startLine: finalReturnedLine == nil ? nil : firstLine,
            endLine: finalReturnedLine,
            truncated: truncated,
            message: truncationMessage
        )
    }

    func readMultipleFiles(
        paths: [String],
        maxBytesPerFile: Int = 128 * 1_024
    ) throws -> [ReadFileResult] {
        guard paths.count <= 32 else { throw WorkspaceFileSystemError.tooManyFiles(32) }
        return try paths.map { try readFile(path: $0, maxBytes: maxBytesPerFile) }
    }

    func createFile(path: String, content: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        try validateMutationInput(content, label: "File content")
        let secureIO = try requireSecureIO()
        let transaction = try await changes.beginChange(paths: [path], operation: .create, taskID: taskID)
        do {
            try secureIO.replaceRegularFile(path: path, data: Data(content.utf8), createOnly: true)
        } catch {
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [path], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func writeFile(path: String, content: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        try validateMutationInput(content, label: "File content")
        let secureIO = try requireSecureIO()
        let transaction = try await changes.beginChange(paths: [path], operation: .write, taskID: taskID)
        do {
            try secureIO.replaceRegularFile(path: path, data: Data(content.utf8), createOnly: false)
        } catch {
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [path], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func editFile(
        path: String,
        exactText: String,
        replacement: String,
        replaceAll: Bool = false,
        taskID: UUID
    ) async throws -> FileMutationResult {
        try Task.checkCancellation()
        try validateMutationInput(exactText, label: "Edit match text")
        try validateMutationInput(replacement, label: "Edit replacement")
        let source = try editableText(path)
        let occurrences = source.ranges(of: exactText)
        guard !occurrences.isEmpty else { throw WorkspaceFileSystemError.exactTextNotFound }
        guard replaceAll || occurrences.count == 1 else {
            throw WorkspaceFileSystemError.exactTextIsAmbiguous(occurrences.count)
        }
        let result = replaceAll
            ? source.replacingOccurrences(of: exactText, with: replacement)
            : source.replacingCharacters(in: occurrences[0], with: replacement)
        guard result.utf8.count <= maximumEditableBytes else {
            throw WorkspaceFileSystemError.fileTooLarge(
                path: path,
                maximumBytes: maximumEditableBytes
            )
        }
        try Task.checkCancellation()
        return try await commitTextEdit(path: path, content: result, taskID: taskID)
    }

    func editFile(
        path: String,
        startLine: Int,
        endLine: Int,
        replacement: String,
        taskID: UUID
    ) async throws -> FileMutationResult {
        try Task.checkCancellation()
        try validateMutationInput(replacement, label: "Edit replacement")
        guard startLine >= 1, endLine >= startLine else {
            throw WorkspaceFileSystemError.invalidLineRange
        }
        let source = try editableText(path)
        let hadTrailingNewline = source.hasSuffix("\n")
        var lines = source.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        guard startLine <= lines.count, endLine <= lines.count else {
            throw WorkspaceFileSystemError.invalidLineRange
        }
        var replacementLines = replacement.components(separatedBy: "\n")
        if replacement.hasSuffix("\n") { replacementLines.removeLast() }
        lines.replaceSubrange((startLine - 1)...(endLine - 1), with: replacementLines)
        var result = lines.joined(separator: "\n")
        if hadTrailingNewline { result.append("\n") }
        guard result.utf8.count <= maximumEditableBytes else {
            throw WorkspaceFileSystemError.fileTooLarge(
                path: path,
                maximumBytes: maximumEditableBytes
            )
        }
        try Task.checkCancellation()
        return try await commitTextEdit(path: path, content: result, taskID: taskID)
    }

    func applyPatch(_ text: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        try validateMutationInput(text, label: "Patch")
        let patches = try UnifiedDiffParser().parse(text)
        let paths = Array(Set(patches.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } })).sorted()
        guard paths.count <= Self.maximumPatchPaths else {
            throw UnifiedDiffError.limitExceeded(
                "patch references more than \(Self.maximumPatchPaths) paths"
            )
        }
        let secureIO = try requireSecureIO()
        // Validate every header before taking a snapshot or mutating any file.
        for path in paths {
            _ = try validator.secureRelativePath(for: path, access: .write)
        }
        let transaction = try await changes.beginChange(paths: paths, operation: .patch, taskID: taskID)
        do {
            for patch in patches {
                try Task.checkCancellation()
                let source: String
                if let oldPath = patch.oldPath {
                    source = try editableText(oldPath)
                } else {
                    source = ""
                }
                let updated = try UnifiedDiffApplier().apply(patch, to: source)

                if let newPath = patch.newPath {
                    try secureIO.replaceRegularFile(
                        path: newPath,
                        data: Data(updated.utf8),
                        createOnly: patch.oldPath == nil || patch.oldPath != newPath
                    )
                }
                if let oldPath = patch.oldPath,
                   patch.newPath == nil || patch.newPath != oldPath {
                    try secureIO.remove(path: oldPath)
                }
            }
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: paths, change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func deleteFile(path: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        let secureIO = try requireSecureIO()
        let transaction = try await changes.beginChange(paths: [path], operation: .delete, taskID: taskID)
        do {
            try secureIO.remove(path: path)
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [path], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func moveFile(source: String, destination: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        let secureIO = try requireSecureIO()
        let paths = [source, destination]
        let transaction = try await changes.beginChange(paths: paths, operation: .move, taskID: taskID)
        do {
            try secureIO.move(source: source, destination: destination)
        } catch SecureWorkspaceIOError.mutationMayHaveCommitted(let detail) {
            // The exclusive rename completed but post-rename identity/tree
            // verification failed. Restore both snapshotted paths.
            try? await changes.rollbackChange(transaction)
            throw SecureWorkspaceIOError.mutationMayHaveCommitted(detail)
        } catch {
            // A failed exclusive rename did not mutate either path. Restoring
            // here could overwrite a concurrent writer that won the race.
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: paths, change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func copyFile(source: String, destination: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        let secureIO = try requireSecureIO()
        _ = try validator.secureRelativePath(for: destination, access: .write)
        let transaction = try await changes.beginChange(paths: [destination], operation: .copy, taskID: taskID)
        do {
            try secureIO.copy(source: source, destination: destination)
        } catch {
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [destination], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func createDirectory(path: String, taskID: UUID) async throws -> FileMutationResult {
        try Task.checkCancellation()
        let secureIO = try requireSecureIO()
        let transaction = try await changes.beginChange(
            paths: [path],
            operation: .createDirectory,
            taskID: taskID
        )
        do {
            try secureIO.createDirectory(path: path)
        } catch {
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [path], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    func fileInfo(path: String) throws -> WorkspaceFileInfo {
        let metadata = try requireSecureIO().metadata(path: path)
        return WorkspaceFileInfo(
            path: path,
            type: Self.entryType(metadata.kind),
            byteCount: metadata.kind == .regularFile ? metadata.byteCount : nil,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            permissions: String(format: "%04o", metadata.permissions),
            isReadable: metadata.permissions & 0o444 != 0,
            isWritable: metadata.permissions & 0o222 != 0
        )
    }

    private func commitTextEdit(
        path: String,
        content: String,
        taskID: UUID
    ) async throws -> FileMutationResult {
        try Task.checkCancellation()
        let secureIO = try requireSecureIO()
        let transaction = try await changes.beginChange(paths: [path], operation: .edit, taskID: taskID)
        do {
            try secureIO.replaceRegularFile(path: path, data: Data(content.utf8), createOnly: false)
        } catch {
            try? await changes.abandonChange(transaction)
            throw error
        }
        do {
            let record = try await changes.commitChange(transaction)
            return FileMutationResult(paths: [path], change: record)
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    private func editableText(_ path: String) throws -> String {
        _ = try validator.secureRelativePath(for: path, access: .write)
        let read: SecureWorkspaceRead
        do {
            read = try requireSecureIO().readRegularFile(
                path: path,
                maximumBytes: maximumEditableBytes
            )
        } catch SecureWorkspaceIOError.notRegularFile {
            throw WorkspaceFileSystemError.notRegularFile(path)
        }
        guard read.metadata.byteCount <= maximumEditableBytes, !read.truncated else {
            throw WorkspaceFileSystemError.fileTooLarge(
                path: path,
                maximumBytes: maximumEditableBytes
            )
        }
        guard !Self.looksBinary(read.data.prefix(8_192)),
              let text = String(data: read.data, encoding: .utf8) else {
            throw WorkspaceFileSystemError.binaryFile(path)
        }
        return text
    }

    private func requireSecureIO() throws -> SecureWorkspaceIO {
        guard let secureIO else {
            throw SecureWorkspaceIOError.cannotOpenWorkspace(validator.secureRootPath)
        }
        return secureIO
    }

    private func validateMutationInput(_ value: String, label: String) throws {
        guard value.utf8.count <= Self.maximumMutationInputBytes else {
            throw WorkspaceFileSystemError.mutationInputTooLarge(
                label: label,
                maximumBytes: Self.maximumMutationInputBytes
            )
        }
    }

    private func displayPath(_ relativePath: String, base: String) -> String {
        if base == "." || base.isEmpty { return relativePath }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + relativePath
    }

    private static func entryType(_ kind: SecureWorkspaceEntryKind) -> WorkspaceEntryType {
        switch kind {
        case .regularFile: .file
        case .directory: .directory
        case .symbolicLink: .symbolicLink
        case .other: .other
        }
    }

    private static func looksBinary<T: DataProtocol>(_ data: T) -> Bool {
        let bytes = Array(data)
        guard !bytes.isEmpty else { return false }
        if bytes.contains(0) { return true }
        let suspicious = bytes.filter { byte in
            byte < 0x09 || (byte > 0x0D && byte < 0x20)
        }.count
        if Double(suspicious) / Double(bytes.count) > 0.08 { return true }
        return String(data: Data(bytes), encoding: .utf8) == nil
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let range = range(of: needle, range: cursor..<endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
