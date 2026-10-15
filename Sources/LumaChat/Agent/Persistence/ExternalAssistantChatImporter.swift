import CryptoKit
import Darwin
import Foundation

enum ExternalAssistantChatSource: String, CaseIterable, Identifiable, Sendable {
    case claudeCodeJSONL
    case cursorMarkdown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claudeCodeJSONL: "Claude Code · JSONL"
        case .cursorMarkdown: "Cursor · Markdown 匯出"
        }
    }
}

enum ExternalAssistantChatImportError: LocalizedError, Equatable {
    case unsafeFile
    case oversized
    case invalidText
    case unsupportedFormat
    case emptyTranscript
    case sourceChanged
    case duplicateImport
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .unsafeFile: "聊天匯出檔必須是安全、可讀的一般檔案。"
        case .oversized: "聊天匯出檔或可匯入文字超出大小上限。"
        case .invalidText: "聊天匯出檔必須是 UTF-8 文字。"
        case .unsupportedFormat: "聊天匯出格式不受支援。"
        case .emptyTranscript: "沒有可匯入的使用者或助理文字訊息。"
        case .sourceChanged: "聊天匯出檔在預覽後變更，請重新預覽。"
        case .duplicateImport: "這份聊天匯出已匯入目前 Project。"
        case .targetChanged: "匯入目標 Project 已變更，請重新預覽。"
        }
    }
}

struct ExternalAssistantChatImportPreview: Equatable, Identifiable {
    let source: ExternalAssistantChatSource
    let sourceURL: URL
    let sourceByteCount: Int
    let sourceDigest: String
    let proposedTitle: String
    let messages: [AgentMessage]

    var id: String { sourceDigest }
}

struct ExternalAssistantChatImporter {
    static let maximumSourceBytes = 5 * 1_024 * 1_024
    static let maximumTextBytes = 256 * 1_024
    static let maximumMessages = 500

    func preview(source: ExternalAssistantChatSource, url: URL) throws
        -> ExternalAssistantChatImportPreview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try readSafeFile(url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ExternalAssistantChatImportError.invalidText
        }
        let parsed: [(AgentMessageRole, String)]
        switch source {
        case .claudeCodeJSONL: parsed = try parseClaudeJSONL(text)
        case .cursorMarkdown: parsed = try parseCursorMarkdown(text)
        }
        guard !parsed.isEmpty else { throw ExternalAssistantChatImportError.emptyTranscript }
        guard parsed.count <= Self.maximumMessages else {
            throw ExternalAssistantChatImportError.oversized
        }
        var totalBytes = 0
        let messages = try parsed.map { role, content -> AgentMessage in
            guard !content.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    && $0 != "\n" && $0 != "\r" && $0 != "\t"
            }) else {
                throw ExternalAssistantChatImportError.invalidText
            }
            let redacted = ExternalImportSanitizer.redact(content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            totalBytes += redacted.utf8.count
            guard totalBytes <= Self.maximumTextBytes else {
                throw ExternalAssistantChatImportError.oversized
            }
            return AgentMessage(role: role, content: redacted)
        }.filter { !$0.content.isEmpty }
        guard !messages.isEmpty else { throw ExternalAssistantChatImportError.emptyTranscript }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let safeTitle = ExternalImportSanitizer.redact(url.deletingPathExtension().lastPathComponent)
            .unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = safeTitle.prefix(100)
        return ExternalAssistantChatImportPreview(
            source: source,
            sourceURL: url,
            sourceByteCount: data.count,
            sourceDigest: "\(source.rawValue):\(digest)",
            proposedTitle: title.isEmpty ? source.title : String(title),
            messages: messages
        )
    }

    func verifyUnchanged(_ preview: ExternalAssistantChatImportPreview) throws {
        let current = try self.preview(source: preview.source, url: preview.sourceURL)
        guard current.sourceDigest == preview.sourceDigest,
              current.messages.map(\.content) == preview.messages.map(\.content) else {
            throw ExternalAssistantChatImportError.sourceChanged
        }
    }

    private func readSafeFile(_ url: URL) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4_096 else {
            throw ExternalAssistantChatImportError.unsafeFile
        }
        var selected = Darwin.stat()
        guard Darwin.lstat(url.path, &selected) == 0,
              selected.st_mode & S_IFMT == S_IFREG,
              selected.st_nlink == 1,
              let resolved = url.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw ExternalAssistantChatImportError.unsafeFile
        }
        defer { Darwin.free(resolved) }
        let fd = Darwin.open(
            String(cString: resolved),
            O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC
        )
        guard fd >= 0 else { throw ExternalAssistantChatImportError.unsafeFile }
        defer { _ = Darwin.close(fd) }
        var before = Darwin.stat()
        guard Darwin.fstat(fd, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw ExternalAssistantChatImportError.unsafeFile
        }
        guard before.st_size <= off_t(Self.maximumSourceBytes) else {
            throw ExternalAssistantChatImportError.oversized
        }
        var data = Data(count: Int(before.st_size))
        let expectedCount = data.count
        var offset = 0
        while offset < expectedCount {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), expectedCount - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ExternalAssistantChatImportError.sourceChanged }
            offset += count
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else {
            throw ExternalAssistantChatImportError.sourceChanged
        }
        var after = Darwin.stat()
        var named = Darwin.stat()
        guard Darwin.fstat(fd, &after) == 0,
              Darwin.lstat(url.path, &named) == 0,
              Self.sameFile(before, selected),
              Self.sameFile(before, after),
              Self.sameFile(before, named) else {
            throw ExternalAssistantChatImportError.sourceChanged
        }
        return data
    }

    private func parseClaudeJSONL(_ text: String) throws -> [(AgentMessageRole, String)] {
        var result: [(AgentMessageRole, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.utf8.count <= 256 * 1_024,
                  let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExternalAssistantChatImportError.unsupportedFormat
            }
            let kind = record["type"] as? String
            let message = record["message"] as? [String: Any]
            let roleName = message?["role"] as? String ?? kind
            let role: AgentMessageRole
            switch roleName {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            let content = message?["content"]
            let parts: [String]
            if let string = content as? String {
                parts = [string]
            } else if let blocks = content as? [[String: Any]] {
                parts = blocks.compactMap { block in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }
            } else {
                continue
            }
            let joined = parts.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((role, joined))
            }
            guard result.count <= Self.maximumMessages else {
                throw ExternalAssistantChatImportError.oversized
            }
        }
        return result
    }

    private func parseCursorMarkdown(_ text: String) throws -> [(AgentMessageRole, String)] {
        var result: [(AgentMessageRole, String)] = []
        var role: AgentMessageRole?
        var body: [String] = []
        var inFence = false
        func flush() {
            guard let role else { body = []; return }
            let content = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { result.append((role, content)) }
            body = []
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence {
                let label = trimmed.lowercased()
                let next: AgentMessageRole?
                switch label {
                case "## user", "### user", "**user:**", "## human", "### human":
                    next = .user
                case "## assistant", "### assistant", "**assistant:**":
                    next = .assistant
                default: next = nil
                }
                if let next {
                    flush()
                    role = next
                    continue
                }
            }
            if role != nil { body.append(line) }
        }
        flush()
        guard result.count <= Self.maximumMessages else {
            throw ExternalAssistantChatImportError.oversized
        }
        return result
    }

    private static func sameFile(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_mode & S_IFMT == rhs.st_mode & S_IFMT
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
