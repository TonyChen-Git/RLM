import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AttachmentService {
    static let maximumImageBytes: Int64 = AttachmentProcessor.maximumImageBytes
    static let maximumDocumentBytes: Int64 = AttachmentProcessor.maximumDocumentBytes
    static let maximumGenericFileBytes: Int64 = AttachmentProcessor.maximumGenericFileBytes
    static let maximumExtractedCharacters = AttachmentProcessor.maximumExtractedCharacters

    /// Presents a native multi-selection picker and imports the selected files.
    func pickAndPrepareAttachments(for conversationID: UUID) async throws -> [PreparedAttachment] {
        let panel = NSOpenPanel()
        panel.title = "加入附件"
        panel.message = "可選擇任何一般檔案；圖片與文字格式可直接提供給模型"
        panel.prompt = "加入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return [] }
        return try await prepare(urls: panel.urls, for: conversationID)
    }

    /// Imports URLs received from SwiftUI drag/drop or another file source.
    func prepare(urls: [URL], for conversationID: UUID) async throws -> [PreparedAttachment] {
        guard !urls.isEmpty else { return [] }

        return try await Task.detached(priority: .userInitiated) {
            try AttachmentProcessor.prepare(urls: urls, for: conversationID)
        }.value
    }

    /// A named drag/drop convenience for views using `dropDestination(for: URL.self)`.
    func prepareDroppedURLs(_ urls: [URL], for conversationID: UUID) async throws -> [PreparedAttachment] {
        try await prepare(urls: urls, for: conversationID)
    }

    /// Reloads persisted bytes, for example when an image must be base64 encoded later.
    func loadData(for attachment: ChatAttachment, conversationID: UUID) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try AttachmentProcessor.loadData(for: attachment, conversationID: conversationID)
        }.value
    }

    /// Removes a staged or persisted attachment without touching any other file.
    func remove(_ attachment: ChatAttachment, from conversationID: UUID) throws {
        try AttachmentProcessor.remove(attachment, from: conversationID)
    }

    /// Removes a whole staged batch, validating every path before deleting any file.
    func removePreparedAttachments(
        _ preparedAttachments: [PreparedAttachment],
        from conversationID: UUID
    ) throws {
        try AttachmentProcessor.remove(
            preparedAttachments.map(\.attachment),
            from: conversationID
        )
    }
}

private enum AttachmentProcessor {
    static let maximumImageBytes: Int64 = 20 * 1_024 * 1_024
    static let maximumDocumentBytes: Int64 = 10 * 1_024 * 1_024
    static let maximumGenericFileBytes: Int64 = 50 * 1_024 * 1_024
    static let maximumExtractedCharacters = 160_000

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    private static let textExtensions: Set<String> = [
        "asm", "bash", "c", "cc", "cfg", "clj", "conf", "cpp", "cs", "css", "csv", "cxx",
        "dart", "diff", "env", "fish", "go", "graphql", "h", "hpp", "htm", "html", "ini",
        "java", "js", "json", "jsonl", "jsx", "kt", "kts", "less", "log", "lua", "m", "markdown",
        "md", "mm", "php", "pl", "properties", "ps1", "py", "r", "rb", "rs", "sass", "scala",
        "scss", "sh", "sql", "swift", "text", "toml", "ts", "tsv", "tsx", "txt", "vue", "xml",
        "yaml", "yml", "zsh"
    ]

    private static let extensionlessTextNames: Set<String> = [
        "brewfile", "dockerfile", "gemfile", "justfile", "license", "makefile", "podfile", "readme"
    ]

    private enum Category: Equatable {
        case image
        case text
        case pdf
        case rtf
        case file

        var attachmentKind: AttachmentKind {
            switch self {
            case .image: .image
            case .text, .rtf: .text
            case .pdf: .pdf
            case .file: .file
            }
        }

        var maximumBytes: Int64 {
            switch self {
            case .image: maximumImageBytes
            case .file: maximumGenericFileBytes
            case .text, .pdf, .rtf: maximumDocumentBytes
            }
        }
    }

    static func prepare(urls: [URL], for conversationID: UUID) throws -> [PreparedAttachment] {
        let fileManager = FileManager.default
        try AppPaths.ensureDirectories()
        try fileManager.createDirectory(
            at: AppPaths.attachmentsDirectory(conversationID),
            withIntermediateDirectories: true
        )

        var prepared: [PreparedAttachment] = []
        prepared.reserveCapacity(urls.count)

        do {
            for url in urls {
                try Task.checkCancellation()
                prepared.append(try prepare(url: url, for: conversationID))
            }
            return prepared
        } catch {
            // Treat a multi-file import as one transaction to avoid half-imported batches.
            for item in prepared {
                if let fileURL = try? safeFileURL(for: item.attachment, conversationID: conversationID) {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
            removeEmptyDraftDirectories(for: conversationID)
            throw error
        }
    }

    static func loadData(for attachment: ChatAttachment, conversationID: UUID) throws -> Data {
        let fileURL = try safeFileURL(for: attachment, conversationID: conversationID)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ChatError.unsupportedFile(attachment.name)
        }
        let maximumBytes = switch attachment.kind {
        case .image: maximumImageBytes
        case .file: maximumGenericFileBytes
        case .text, .pdf, .capturedContext: maximumDocumentBytes
        }
        if let fileSize = values.fileSize, Int64(fileSize) > maximumBytes {
            throw ChatError.fileTooLarge(attachment.name)
        }

        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard Int64(data.count) <= maximumBytes else {
            throw ChatError.fileTooLarge(attachment.name)
        }
        return data
    }

    static func remove(_ attachment: ChatAttachment, from conversationID: UUID) throws {
        try remove([attachment], from: conversationID)
    }

    static func remove(_ attachments: [ChatAttachment], from conversationID: UUID) throws {
        let fileManager = FileManager.default
        // Resolve all paths first so one malformed item cannot cause a partial batch delete.
        let fileURLs = try attachments.map {
            try safeFileURL(for: $0, conversationID: conversationID)
        }
        var existingFileURLs: [URL] = []
        for fileURL in fileURLs {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else {
                    throw ChatError.permissionDenied("附件目標不是一般檔案，已拒絕刪除。")
                }
                existingFileURLs.append(fileURL)
            }
        }
        for fileURL in existingFileURLs {
            try fileManager.removeItem(at: fileURL)
        }
        removeEmptyDraftDirectories(for: conversationID)
    }

    private static func prepare(url sourceURL: URL, for conversationID: UUID) throws -> PreparedAttachment {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try sourceURL.resourceValues(forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isRegularFileKey,
                .nameKey
            ])
        } catch {
            throw ChatError.permissionDenied("無法讀取 \(sourceURL.lastPathComponent)：\(error.localizedDescription)")
        }

        guard resourceValues.isRegularFile == true else {
            throw ChatError.unsupportedFile(sourceURL.lastPathComponent)
        }

        let originalName = resourceValues.name ?? sourceURL.lastPathComponent
        let fileExtension = sourceURL.pathExtension.lowercased()
        let contentType = resourceValues.contentType ?? UTType(filenameExtension: fileExtension)
        let category = category(
            fileExtension: fileExtension,
            fileName: originalName,
            contentType: contentType
        )
        let byteCount = try resolvedByteCount(
            resourceValue: resourceValues.fileSize,
            sourceURL: sourceURL
        )
        guard byteCount <= category.maximumBytes else {
            throw ChatError.fileTooLarge(originalName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw ChatError.permissionDenied("無法讀取 \(originalName)：\(error.localizedDescription)")
        }

        guard Int64(data.count) <= category.maximumBytes else {
            throw ChatError.fileTooLarge(originalName)
        }

        let extractedText: String?
        switch category {
        case .image, .file:
            extractedText = nil
        case .text:
            guard let text = decodeText(data) else {
                throw ChatError.unsupportedFile(originalName)
            }
            extractedText = truncate(text)
        case .pdf:
            guard let document = PDFDocument(data: data) else {
                throw ChatError.unsupportedFile(originalName)
            }
            extractedText = document.string.map(truncate)
        case .rtf:
            do {
                let attributedString = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                extractedText = truncate(attributedString.string)
            } catch {
                throw ChatError.unsupportedFile(originalName)
            }
        }

        let storedName = uniqueStoredName(for: originalName)
        let destinationURL = AppPaths.attachmentsDirectory(conversationID)
            .appendingPathComponent(storedName, isDirectory: false)

        do {
            // The UUID destination cannot collide; the helper keeps its short-lived
            // staging file in this same Attachments directory.
            try AtomicFileWriter.write(data, to: destinationURL)
        } catch {
            throw ChatError.permissionDenied("無法儲存 \(originalName)：\(error.localizedDescription)")
        }

        let attachment = ChatAttachment(
            name: originalName,
            relativePath: "Attachments/\(storedName)",
            mimeType: mimeType(for: contentType, fileExtension: fileExtension),
            kind: category.attachmentKind,
            byteCount: Int64(data.count),
            extractedText: extractedText,
            sourceLabel: "檔案"
        )

        // Images intentionally have no extracted text. Their bytes remain available
        // here for immediate base64 encoding and on disk for subsequent sends.
        return PreparedAttachment(
            attachment: attachment,
            data: category == .image ? data : nil
        )
    }

    private static func category(
        fileExtension: String,
        fileName: String,
        contentType: UTType?
    ) -> Category {
        if imageExtensions.contains(fileExtension) {
            return .image
        }
        if fileExtension == "pdf" || contentType?.conforms(to: .pdf) == true {
            return .pdf
        }
        if fileExtension == "rtf" || contentType?.conforms(to: .rtf) == true {
            return .rtf
        }

        let lowercaseName = fileName.lowercased()
        if textExtensions.contains(fileExtension)
            || extensionlessTextNames.contains(lowercaseName)
            || contentType?.conforms(to: .text) == true
            || contentType?.conforms(to: .sourceCode) == true
            || contentType?.conforms(to: .json) == true
        {
            return .text
        }
        return .file
    }

    private static func resolvedByteCount(resourceValue: Int?, sourceURL: URL) throws -> Int64 {
        if let resourceValue {
            return Int64(resourceValue)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ChatError.permissionDenied("無法取得 \(sourceURL.lastPathComponent) 的檔案大小。")
        }
        return number.int64Value
    }

    private static func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1
        ]

        for encoding in encodings {
            if var text = String(data: data, encoding: encoding) {
                if text.first == "\u{FEFF}" {
                    text.removeFirst()
                }
                return text
            }
        }
        return nil
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > maximumExtractedCharacters else { return text }
        return String(text.prefix(maximumExtractedCharacters))
            + "\n\n［附件文字已截斷，以避免超出模型 context。］"
    }

    private static func mimeType(for contentType: UTType?, fileExtension: String) -> String {
        if let mimeType = contentType?.preferredMIMEType {
            return mimeType
        }

        return switch fileExtension {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "pdf": "application/pdf"
        case "rtf": "application/rtf"
        case "json", "jsonl": "application/json"
        case "csv": "text/csv"
        case "md", "markdown": "text/markdown"
        case "log", "txt", "text": "text/plain"
        default: "application/octet-stream"
        }
    }

    private static func uniqueStoredName(for originalName: String) -> String {
        let sourceURL = URL(fileURLWithPath: originalName)
        let fileExtension = sourceURL.pathExtension
        let stem = sourceURL.deletingPathExtension().lastPathComponent

        let cleanedStem = stem.unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0)
                    && $0 != "/"
                    && $0 != ":"
            }
            .map(String.init)
            .joined()
        let safeStem = String((cleanedStem.isEmpty ? "attachment" : cleanedStem).prefix(96))
        let safeExtension = String(fileExtension.prefix(16))
        let suffix = safeExtension.isEmpty ? "" : ".\(safeExtension)"
        return "\(UUID().uuidString)-\(safeStem)\(suffix)"
    }

    private static func safeFileURL(
        for attachment: ChatAttachment,
        conversationID: UUID
    ) throws -> URL {
        guard let relativePath = attachment.relativePath else {
            throw ChatError.unsupportedFile(attachment.name)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard
            components.count == 2,
            components[0] == "Attachments",
            !components[1].isEmpty,
            components[1] != ".",
            components[1] != ".."
        else {
            throw ChatError.permissionDenied("附件路徑不安全，已拒絕存取。")
        }

        let conversationURL = AppPaths.conversationDirectory(conversationID)
            .standardizedFileURL
        let attachmentsURL = conversationURL
            .appendingPathComponent("Attachments", isDirectory: true)
            .standardizedFileURL
        let candidateURL = conversationURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL

        let resolvedConversationURL = conversationURL.resolvingSymlinksInPath()
        let resolvedAttachmentsURL = attachmentsURL.resolvingSymlinksInPath()
        let resolvedCandidateURL = candidateURL.resolvingSymlinksInPath()

        guard
            resolvedAttachmentsURL.path.hasPrefix(resolvedConversationURL.path + "/"),
            resolvedCandidateURL.path.hasPrefix(resolvedAttachmentsURL.path + "/")
        else {
            throw ChatError.permissionDenied("附件路徑不安全，已拒絕存取。")
        }
        return candidateURL
    }

    private static func removeEmptyDraftDirectories(for conversationID: UUID) {
        let fileManager = FileManager.default
        let attachmentsURL = AppPaths.attachmentsDirectory(conversationID)
        let conversationURL = AppPaths.conversationDirectory(conversationID)

        if (try? fileManager.contentsOfDirectory(atPath: attachmentsURL.path).isEmpty) == true {
            try? fileManager.removeItem(at: attachmentsURL)
        }

        let conversationJSON = conversationURL.appendingPathComponent("conversation.json")
        if !fileManager.fileExists(atPath: conversationJSON.path),
           (try? fileManager.contentsOfDirectory(atPath: conversationURL.path).isEmpty) == true
        {
            try? fileManager.removeItem(at: conversationURL)
        }
    }
}
