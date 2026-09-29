import Darwin
import Foundation

/// A deliberately small import surface. Cursor's `.cursor/rules/*.mdc` files
/// have activation and path scopes, so treating them as one always-on prompt
/// would change their meaning.
enum ProjectInstructionImportSource: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case cursorLegacy

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .claudeCode: "CLAUDE.md"
        case .cursorLegacy: ".cursorrules"
        }
    }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code · CLAUDE.md"
        case .cursorLegacy: "Cursor · .cursorrules"
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
        }
    }
}

/// Content is redacted before it leaves the importer. It remains editable in
/// the settings draft, where the user decides whether to save it. No `@path`
/// references or other vendor-specific syntax are expanded here.
struct ProjectInstructionImportPreview: Equatable, Sendable {
    let projectIdentity: AgentProjectIdentity
    let source: ProjectInstructionImportSource
    let sourcePath: String
    let redactedContent: String
    let sourceByteCount: Int

    private let workspaceDevice: UInt64
    private let workspaceInode: UInt64

    init(
        projectIdentity: AgentProjectIdentity,
        source: ProjectInstructionImportSource,
        sourcePath: String,
        redactedContent: String,
        sourceByteCount: Int,
        workspaceDevice: UInt64,
        workspaceInode: UInt64
    ) {
        self.projectIdentity = projectIdentity
        self.source = source
        self.sourcePath = sourcePath
        self.redactedContent = redactedContent
        self.sourceByteCount = sourceByteCount
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

    private let redactor = SecretRedactor()

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

        let file = source.fileName.withCString {
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
        let namedFileStatus = source.fileName.withCString {
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
        let redacted = redactor.redact(text)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectInstructionImportError.emptySource
        }
        return ProjectInstructionImportPreview(
            projectIdentity: identity,
            source: source,
            sourcePath: identity.canonicalRootPath + "/" + source.fileName,
            redactedContent: redacted,
            sourceByteCount: data.count,
            workspaceDevice: UInt64(rootInfo.st_dev),
            workspaceInode: UInt64(rootInfo.st_ino)
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
