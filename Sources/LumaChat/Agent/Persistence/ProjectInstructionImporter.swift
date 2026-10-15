import Darwin
import Foundation
import CryptoKit

enum ExternalImportSanitizer {
    static func redact(_ input: String) -> String {
        let labeled = SecretRedactor().redact(input)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#
        ) else { return labeled }
        return expression.stringByReplacingMatches(
            in: labeled,
            range: NSRange(labeled.startIndex..<labeled.endIndex, in: labeled),
            withTemplate: "[REDACTED]"
        )
    }
}

enum ProjectInstructionImportSource: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case cursorLegacy
    case cursorRules
    case claudeSettings
    case cursorMCP

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .claudeCode: "CLAUDE.md"
        case .cursorLegacy: ".cursorrules"
        case .cursorRules: ".cursor/rules"
        case .claudeSettings: ".claude/settings.json"
        case .cursorMCP: ".cursor/mcp.json"
        }
    }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code · CLAUDE.md"
        case .cursorLegacy: "Cursor · .cursorrules"
        case .cursorRules: "Cursor · .mdc 規則"
        case .claudeSettings: "Claude Code · Project 設定"
        case .cursorMCP: "Cursor · MCP 設定"
        }
    }
}

enum ProjectInstructionImportError: LocalizedError, Equatable, Sendable {
    case invalidWorkspace
    case missingSource
    case unsafeSource
    case sourceTooLarge
    case invalidText
    case emptySource
    case sourceChanged
    case unsafeReference
    case referenceCycle
    case tooManySources
    case invalidRule

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            "請選擇有效的本機專案資料夾。"
        case .missingSource:
            "所選專案沒有這個指令檔。"
        case .unsafeSource:
            "指令檔不是安全的一般檔案，或無法讀取。"
        case .sourceTooLarge:
            "指令檔超過 256 KiB 上限。"
        case .invalidText:
            "指令檔必須是沒有 NUL 字元的 UTF-8 文字。"
        case .emptySource:
            "指令檔沒有可匯入的內容。"
        case .sourceChanged:
            "指令檔或專案在讀取期間變更，請重新預覽。"
        case .unsafeReference:
            "參照路徑超出 Project、指向憑證，或不是安全的一般檔案。"
        case .referenceCycle:
            "指令檔參照形成循環或超出深度上限。"
        case .tooManySources:
            "指令來源數量或合計大小超出安全上限。"
        case .invalidRule:
            "Cursor .mdc front matter 或 glob scope 無效。"
        }
    }
}

enum ProjectInstructionImportScope: Codable, Equatable, Sendable {
    case always
    case files([String])
    case agentRequested(String)
    case manual
}

struct ProjectInstructionImportComponent: Codable, Equatable, Sendable {
    let relativePath: String
    let redactedContent: String
    let sourceByteCount: Int
    let scope: ProjectInstructionImportScope
    var sourceDigest: String = ""
}

struct ProjectAssistantConfigurationSummary: Equatable, Sendable {
    let modelSuggestion: String?
    let topLevelKeys: [String]
    let mcpServerNames: [String]
}

/// Content is redacted before it leaves the importer. The component list keeps
/// Cursor activation scope visible instead of silently flattening it.
struct ProjectInstructionImportPreview: Equatable, Identifiable, Sendable {
    let projectIdentity: AgentProjectIdentity
    let source: ProjectInstructionImportSource
    let sourcePath: String
    let redactedContent: String
    let sourceByteCount: Int
    let components: [ProjectInstructionImportComponent]
    let configuration: ProjectAssistantConfigurationSummary?

    var id: String { source.rawValue + ":" + sourcePath }

    private let workspaceDevice: UInt64
    private let workspaceInode: UInt64

    init(
        projectIdentity: AgentProjectIdentity,
        source: ProjectInstructionImportSource,
        sourcePath: String,
        redactedContent: String,
        sourceByteCount: Int,
        components: [ProjectInstructionImportComponent],
        configuration: ProjectAssistantConfigurationSummary?,
        workspaceDevice: UInt64,
        workspaceInode: UInt64
    ) {
        self.projectIdentity = projectIdentity
        self.source = source
        self.sourcePath = sourcePath
        self.redactedContent = redactedContent
        self.sourceByteCount = sourceByteCount
        self.components = components
        self.configuration = configuration
        self.workspaceDevice = workspaceDevice
        self.workspaceInode = workspaceInode
    }

    /// Rejects applying a preview after the selected workspace changes, even
    /// if a different directory takes over the same pathname.
    func belongs(toWorkspaceRootPath rootPath: String) -> Bool {
        guard let current = try? AgentProjectIdentity.resolve(workspaceRootPath: rootPath),
              current == projectIdentity else { return false }
        var metadata = Darwin.stat()
        guard Darwin.lstat(projectIdentity.canonicalRootPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        return UInt64(metadata.st_dev) == workspaceDevice
            && UInt64(metadata.st_ino) == workspaceInode
    }
}

struct ProjectInstructionImporter: Sendable {
    static let maximumSourceBytes = AgentProjectSettingsLimits.maximumSystemPromptBytes
    static let maximumSources = 32
    static let maximumDepth = 6

    func preview(
        source: ProjectInstructionImportSource,
        workspaceRootPath: String
    ) throws -> ProjectInstructionImportPreview {
        let identity: AgentProjectIdentity
        do {
            identity = try AgentProjectIdentity.resolve(workspaceRootPath: workspaceRootPath)
        } catch {
            throw ProjectInstructionImportError.invalidWorkspace
        }

        // URL.resolvingSymlinksInPath leaves macOS's /var alias unresolved on
        // some systems. Resolve every ancestor before using O_NOFOLLOW_ANY.
        guard let resolvedRoot = identity.canonicalRootPath.withCString({
            Darwin.realpath($0, nil)
        }) else { throw ProjectInstructionImportError.invalidWorkspace }
        defer { Darwin.free(resolvedRoot) }
        let root = Darwin.open(
            String(cString: resolvedRoot),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard root >= 0 else { throw ProjectInstructionImportError.invalidWorkspace }
        defer { _ = Darwin.close(root) }
        var rootInfo = Darwin.stat()
        guard Darwin.fstat(root, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectInstructionImportError.invalidWorkspace
        }

        let components: [ProjectInstructionImportComponent]
        var configuration: ProjectAssistantConfigurationSummary?
        switch source {
        case .claudeCode:
            var visited = Set<String>()
            components = try claudeComponents(
                path: source.fileName,
                root: root,
                rootInfo: rootInfo,
                identity: identity,
                ancestors: [],
                visited: &visited
            )
        case .cursorLegacy:
            let text = try readSource(source.fileName, root: root, rootInfo: rootInfo, identity: identity)
            components = [ProjectInstructionImportComponent(
                relativePath: source.fileName,
                redactedContent: text.redacted,
                sourceByteCount: text.bytes,
                scope: .always,
                sourceDigest: text.digest
            )]
        case .cursorRules:
            let paths = try discoverCursorRules(rootPath: String(cString: resolvedRoot))
            components = try paths.map { path in
                let text = try readSource(path, root: root, rootInfo: rootInfo, identity: identity)
                return try parseCursorRule(
                    path: path, text: text.redacted, bytes: text.bytes,
                    digest: text.digest
                )
            }
        case .claudeSettings, .cursorMCP:
            let text = try readSource(source.fileName, root: root, rootInfo: rootInfo, identity: identity)
            guard let data = text.raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProjectInstructionImportError.invalidText
            }
            let model = object["model"] as? String
            let safeModel = model.flatMap { value -> String? in
                guard !value.isEmpty, value.utf8.count <= 1_024,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      ExternalImportSanitizer.redact(value) == value
                else { return nil }
                return value
            }
            configuration = ProjectAssistantConfigurationSummary(
                modelSuggestion: source == .claudeSettings ? safeModel : nil,
                topLevelKeys: object.keys.map(ExternalImportSanitizer.redact).sorted(),
                mcpServerNames: ((object["mcpServers"] as? [String: Any]) ?? [:])
                    .keys.map(ExternalImportSanitizer.redact).sorted()
            )
            components = [ProjectInstructionImportComponent(
                relativePath: source.fileName,
                redactedContent: "Project 設定欄位：\(configuration!.topLevelKeys.joined(separator: ", "))",
                sourceByteCount: text.bytes,
                scope: .manual,
                sourceDigest: text.digest
            )]
        }
        guard components.count <= Self.maximumSources,
              components.reduce(0, { $0 + $1.sourceByteCount }) <= Self.maximumSourceBytes else {
            throw ProjectInstructionImportError.tooManySources
        }
        let content: String
        if configuration != nil {
            content = components[0].redactedContent
        } else if source == .cursorRules {
            // The existing Project System Prompt is unconditional. Only rules
            // whose metadata says alwaysApply may be copied into that draft.
            content = components.compactMap { component in
                if case .always = component.scope {
                    return "### \(component.relativePath)\n\(component.redactedContent)"
                }
                return nil
            }.joined(separator: "\n\n")
        } else if source == .claudeCode {
            content = components.map {
                "### \($0.relativePath)\n\($0.redactedContent)"
            }.joined(separator: "\n\n")
        } else {
            content = components[0].redactedContent
        }
        guard content.utf8.count <= Self.maximumSourceBytes else {
            throw ProjectInstructionImportError.tooManySources
        }
        return ProjectInstructionImportPreview(
            projectIdentity: identity,
            source: source,
            sourcePath: identity.canonicalRootPath + "/" + source.fileName,
            redactedContent: content,
            sourceByteCount: components.reduce(0, { $0 + $1.sourceByteCount }),
            components: components,
            configuration: configuration,
            workspaceDevice: UInt64(rootInfo.st_dev),
            workspaceInode: UInt64(rootInfo.st_ino)
        )
    }

    private func readSource(
        _ path: String,
        root: Int32,
        rootInfo: Darwin.stat,
        identity: AgentProjectIdentity
    ) throws -> (raw: String, redacted: String, bytes: Int, digest: String) {
        guard Self.safeRelativePath(path) else {
            throw ProjectInstructionImportError.unsafeReference
        }
        let file = path.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        }
        guard file >= 0 else {
            throw errno == ENOENT
                ? ProjectInstructionImportError.missingSource
                : ProjectInstructionImportError.unsafeSource
        }
        defer { _ = Darwin.close(file) }

        var before = Darwin.stat()
        guard Darwin.fstat(file, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw ProjectInstructionImportError.unsafeSource
        }
        guard before.st_size <= off_t(Self.maximumSourceBytes) else {
            throw ProjectInstructionImportError.sourceTooLarge
        }

        var data = Data(count: Int(before.st_size))
        let expectedCount = data.count
        var offset = 0
        while offset < expectedCount {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(file, base.advanced(by: offset), expectedCount - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ProjectInstructionImportError.sourceChanged }
            offset += count
        }
        var extra: UInt8 = 0
        let extraCount = Darwin.read(file, &extra, 1)
        guard extraCount == 0 else {
            throw ProjectInstructionImportError.sourceChanged
        }

        var after = Darwin.stat()
        var namedFile = Darwin.stat()
        var namedRoot = Darwin.stat()
        let namedFileStatus = path.withCString {
            Darwin.fstatat(root, $0, &namedFile, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(file, &after) == 0,
              namedFileStatus == 0,
              Darwin.lstat(identity.canonicalRootPath, &namedRoot) == 0,
              Self.sameFile(before, after),
              Self.sameFile(before, namedFile),
              Self.sameFile(rootInfo, namedRoot) else {
            throw ProjectInstructionImportError.sourceChanged
        }

        guard !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw ProjectInstructionImportError.invalidText
        }
        let redacted = ExternalImportSanitizer.redact(text)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectInstructionImportError.emptySource
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return (text, redacted, data.count, digest)
    }

    private func claudeComponents(
        path: String,
        root: Int32,
        rootInfo: Darwin.stat,
        identity: AgentProjectIdentity,
        ancestors: Set<String>,
        visited: inout Set<String>
    ) throws -> [ProjectInstructionImportComponent] {
        guard ancestors.count < Self.maximumDepth else {
            throw ProjectInstructionImportError.referenceCycle
        }
        guard !ancestors.contains(path) else {
            throw ProjectInstructionImportError.referenceCycle
        }
        if visited.contains(path) { return [] }
        guard visited.count < Self.maximumSources else {
            throw ProjectInstructionImportError.tooManySources
        }
        let text = try readSource(path, root: root, rootInfo: rootInfo, identity: identity)
        visited.insert(path)
        var result = [ProjectInstructionImportComponent(
            relativePath: path,
            redactedContent: text.redacted,
            sourceByteCount: text.bytes,
            scope: .always,
            sourceDigest: text.digest
        )]
        let parent = (path as NSString).deletingLastPathComponent
        for reference in Self.references(in: text.redacted) {
            let candidate = parent.isEmpty ? reference : parent + "/" + reference
            guard Self.safeRelativePath(candidate) else {
                throw ProjectInstructionImportError.unsafeReference
            }
            let normalized = candidate.split(separator: "/")
                .filter { $0 != "." }
                .joined(separator: "/")
            result += try claudeComponents(
                path: normalized,
                root: root,
                rootInfo: rootInfo,
                identity: identity,
                ancestors: ancestors.union([path]),
                visited: &visited
            )
            guard result.reduce(0, { $0 + $1.sourceByteCount }) <= Self.maximumSourceBytes else {
                throw ProjectInstructionImportError.tooManySources
            }
        }
        return result
    }

    private static func references(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_@])@([~./A-Za-z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var references: [String] = []
        var fenced = false
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced { continue }
            let segments = line.components(separatedBy: "`")
            for (index, segment) in segments.enumerated() where index.isMultiple(of: 2) {
                let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
                for match in regex.matches(in: segment, range: range) {
                    guard let valueRange = Range(match.range(at: 1), in: segment) else { continue }
                    let value = String(segment[valueRange])
                    if value.contains("/") || value.hasSuffix(".md") {
                        references.append(value)
                    }
                }
            }
        }
        return references
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              path.utf8.count <= 4_096, !path.contains("\\"), !path.contains("\0") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == ".." }) else { return false }
        let lowered = parts.map { $0.lowercased() }
        return !lowered.contains(where: {
            $0 == ".env" || $0.hasPrefix(".env.") || $0.contains("credential")
                || $0 == "id_rsa" || $0.hasSuffix(".pem") || $0.hasSuffix(".key")
        })
    }

    private func discoverCursorRules(rootPath: String) throws -> [String] {
        let rulesRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(".cursor/rules", isDirectory: true)
        var info = Darwin.stat()
        guard Darwin.lstat(rulesRoot.path, &info) == 0 else {
            throw ProjectInstructionImportError.missingSource
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ProjectInstructionImportError.unsafeSource
        }
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rulesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { throw ProjectInstructionImportError.unsafeSource }
        var paths: [String] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= 256 else {
                throw ProjectInstructionImportError.tooManySources
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ProjectInstructionImportError.unsafeSource
            }
            let path = String(url.path.dropFirst(rootPath.count + 1))
            guard Self.safeRelativePath(path), path.split(separator: "/").count <= Self.maximumDepth + 2 else {
                throw ProjectInstructionImportError.unsafeReference
            }
            if values.isDirectory == true { continue }
            guard path.hasSuffix(".mdc") else { continue }
            paths.append(path)
            guard paths.count <= Self.maximumSources else {
                throw ProjectInstructionImportError.tooManySources
            }
        }
        guard !paths.isEmpty else { throw ProjectInstructionImportError.missingSource }
        return paths.sorted()
    }

    private func parseCursorRule(
        path: String,
        text: String,
        bytes: Int,
        digest: String
    ) throws -> ProjectInstructionImportComponent {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---",
              let end = lines.dropFirst().prefix(40).firstIndex(of: "---") else {
            throw ProjectInstructionImportError.invalidRule
        }
        var always = false
        var description = ""
        var globs: [String] = []
        var readingGlobs = false
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), readingGlobs {
                globs.append(String(trimmed.dropFirst(2)))
                continue
            }
            readingGlobs = false
            if trimmed.hasPrefix("alwaysApply:") {
                let value = trimmed.dropFirst("alwaysApply:".count).trimmingCharacters(in: .whitespaces)
                guard value == "true" || value == "false" else {
                    throw ProjectInstructionImportError.invalidRule
                }
                always = value == "true"
            } else if trimmed.hasPrefix("description:") {
                description = String(trimmed.dropFirst("description:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("globs:") {
                let value = String(trimmed.dropFirst("globs:".count))
                    .trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    readingGlobs = true
                } else {
                    globs += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map(String.init)
                }
            }
        }
        globs = globs.map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        guard globs.count <= 16,
              globs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256
                && !$0.hasPrefix("/") && !$0.contains("..") && !$0.contains("\\") }) else {
            throw ProjectInstructionImportError.invalidRule
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ProjectInstructionImportError.emptySource }
        let scope: ProjectInstructionImportScope
        if always { scope = .always }
        else if !globs.isEmpty { scope = .files(globs) }
        else if !description.isEmpty { scope = .agentRequested(description) }
        else { scope = .manual }
        return ProjectInstructionImportComponent(
            relativePath: path,
            redactedContent: body,
            sourceByteCount: bytes,
            scope: scope,
            sourceDigest: digest
        )
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
