import Darwin
import Foundation

enum GitRepositoryLayoutError: LocalizedError, Equatable, Sendable {
    case invalidWorkspace
    case unsafeGitEntry(String)
    case invalidPointer(String)
    case unsafeMetadataDirectory(String)
    case invalidMetadata(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            "The Git repository workspace is not a safe directory."
        case .unsafeGitEntry(let detail):
            "The workspace .git entry is unsafe: \(detail)"
        case .invalidPointer(let detail):
            "The workspace .git pointer is invalid: \(detail)"
        case .unsafeMetadataDirectory(let detail):
            "The Git metadata directory is unsafe: \(detail)"
        case .invalidMetadata(let detail):
            "The Git metadata is invalid: \(detail)"
        }
    }
}

enum GitRepositoryLayoutKind: String, Codable, Equatable, Sendable {
    case normalCheckout
    case linkedWorktree
    case gitDirectoryPointer
}

struct GitRepositoryHead: Equatable, Sendable {
    let rawValue: String
    let symbolicReference: String?
    let objectID: String?
}

/// A host-only, bounded description of the repository metadata needed by Git.
///
/// `metadataRoots` must never be copied into `AgentWorkspace.allowedPaths` or
/// accepted by `WorkspaceSecurityValidator`. TerminalSandbox consumes them as
/// a separate capability that is enabled only for GitService's closed command
/// surface, so a model-authored shell command does not gain filesystem access
/// to a main checkout merely because its workspace is a linked worktree.
struct GitRepositoryLayout: Equatable, Sendable {
    static let maximumPointerBytes = 4 * 1_024
    static let maximumHeadBytes = 4 * 1_024
    static let maximumRefBytes = 512
    static let maximumConfigBytes = 64 * 1_024
    static let maximumPackedRefsBytes = 1 * 1_024 * 1_024
    static let maximumPackedRefLines = 20_000

    let workspaceRoot: URL
    let gitEntry: URL
    let worktreeGitDirectory: URL
    let commonGitDirectory: URL
    let kind: GitRepositoryLayoutKind
    let head: GitRepositoryHead

    /// The minimal verified roots Git must read or update. This is deliberately
    /// not a set of workspace roots and is not suitable for model-facing path
    /// validation or as a terminal cwd.
    var metadataRoots: [URL] {
        Self.removingNestedDuplicates([worktreeGitDirectory, commonGitDirectory])
    }

    /// ChangeManager can truthfully snapshot normal `.git/...` paths. Pointer
    /// layouts store those paths somewhere else, outside its descriptor-pinned
    /// workspace boundary, so GitService mutations must fail closed for now.
    var supportsWorkspaceMetadataSnapshots: Bool {
        kind == .normalCheckout
    }

    static func inspect(workspaceRoot rawWorkspaceRoot: URL) throws -> GitRepositoryLayout? {
        let workspaceRoot = try verifiedDirectory(
            rawWorkspaceRoot,
            role: "workspace root",
            allowCanonicalization: true
        )
        let gitEntry = workspaceRoot.appendingPathComponent(".git", isDirectory: false)
            .standardizedFileURL

        var entryInfo = Darwin.stat()
        guard Darwin.lstat(gitEntry.path, &entryInfo) == 0 else {
            if errno == ENOENT { return nil }
            throw GitRepositoryLayoutError.unsafeGitEntry(Self.posixDetail("lstat", path: gitEntry))
        }

        let worktreeGitDirectory: URL
        let commonGitDirectory: URL
        let kind: GitRepositoryLayoutKind
        switch entryInfo.st_mode & S_IFMT {
        case S_IFDIR:
            worktreeGitDirectory = try verifiedDirectory(gitEntry, role: ".git directory")
            commonGitDirectory = worktreeGitDirectory
            kind = .normalCheckout

        case S_IFREG:
            let pointer = try boundedSingleLine(
                at: gitEntry,
                maximumBytes: maximumPointerBytes,
                role: ".git pointer"
            )
            guard pointer.hasPrefix("gitdir: ") else {
                throw GitRepositoryLayoutError.invalidPointer("expected a gitdir declaration")
            }
            let rawGitDirectory = String(pointer.dropFirst("gitdir: ".count))
            guard !rawGitDirectory.isEmpty,
                  !rawGitDirectory.contains("\0"),
                  rawGitDirectory.utf8.count <= maximumPointerBytes else {
                throw GitRepositoryLayoutError.invalidPointer("the target path is empty or oversized")
            }
            let candidate = resolve(
                rawGitDirectory,
                relativeTo: gitEntry.deletingLastPathComponent()
            )
            worktreeGitDirectory = try verifiedDirectory(candidate, role: "gitdir target")
            try rejectUnsafeMetadataAuthority(
                worktreeGitDirectory,
                workspaceRoot: workspaceRoot
            )

            let commondirEntry = worktreeGitDirectory
                .appendingPathComponent("commondir", isDirectory: false)
            if try pathKind(at: commondirEntry) != nil {
                guard try pathKind(at: commondirEntry) == S_IFREG else {
                    throw GitRepositoryLayoutError.invalidMetadata("commondir is not a regular file")
                }
                let rawCommonDirectory = try boundedSingleLine(
                    at: commondirEntry,
                    maximumBytes: maximumPointerBytes,
                    role: "commondir"
                )
                guard !rawCommonDirectory.isEmpty else {
                    throw GitRepositoryLayoutError.invalidMetadata("commondir is empty")
                }
                commonGitDirectory = try verifiedDirectory(
                    resolve(rawCommonDirectory, relativeTo: worktreeGitDirectory),
                    role: "common Git directory"
                )
                try rejectUnsafeMetadataAuthority(
                    commonGitDirectory,
                    workspaceRoot: workspaceRoot
                )
                try verifyLinkedWorktreeRelationship(
                    workspaceRoot: workspaceRoot,
                    gitEntry: gitEntry,
                    worktreeGitDirectory: worktreeGitDirectory,
                    commonGitDirectory: commonGitDirectory
                )
                kind = .linkedWorktree
            } else {
                commonGitDirectory = worktreeGitDirectory
                try verifySeparateGitDirectoryRelationship(
                    workspaceRoot: workspaceRoot,
                    gitDirectory: worktreeGitDirectory
                )
                kind = .gitDirectoryPointer
            }

        default:
            throw GitRepositoryLayoutError.unsafeGitEntry(".git is neither a directory nor a regular file")
        }

        let head = try inspectHead(
            worktreeGitDirectory: worktreeGitDirectory,
            commonGitDirectory: commonGitDirectory
        )
        return GitRepositoryLayout(
            workspaceRoot: workspaceRoot,
            gitEntry: gitEntry,
            worktreeGitDirectory: worktreeGitDirectory,
            commonGitDirectory: commonGitDirectory,
            kind: kind,
            head: head
        )
    }

    private static func inspectHead(
        worktreeGitDirectory: URL,
        commonGitDirectory: URL
    ) throws -> GitRepositoryHead {
        let head = try boundedSingleLine(
            at: worktreeGitDirectory.appendingPathComponent("HEAD", isDirectory: false),
            maximumBytes: maximumHeadBytes,
            role: "HEAD"
        )
        guard !head.isEmpty else {
            throw GitRepositoryLayoutError.invalidMetadata("HEAD is empty")
        }
        if head.hasPrefix("ref: ") {
            let reference = String(head.dropFirst("ref: ".count))
            guard isSafeGitReference(reference) else {
                throw GitRepositoryLayoutError.invalidMetadata("HEAD contains an unsafe reference")
            }
            return GitRepositoryHead(
                rawValue: head,
                symbolicReference: reference,
                objectID: try readObjectID(
                    reference: reference,
                    worktreeGitDirectory: worktreeGitDirectory,
                    commonGitDirectory: commonGitDirectory
                )
            )
        }
        guard let objectID = normalizedObjectID(head) else {
            throw GitRepositoryLayoutError.invalidMetadata("detached HEAD contains an invalid object ID")
        }
        return GitRepositoryHead(rawValue: head, symbolicReference: nil, objectID: objectID)
    }

    private static func readObjectID(
        reference: String,
        worktreeGitDirectory: URL,
        commonGitDirectory: URL
    ) throws -> String? {
        // Most refs live in the common directory. Per-worktree refs are tried
        // first only for namespaces Git documents as worktree-local.
        let isPerWorktreeReference = reference == "HEAD"
            || reference.hasPrefix("refs/bisect/")
            || reference.hasPrefix("refs/worktree/")
            || reference.hasPrefix("refs/rewritten/")
        let roots = isPerWorktreeReference
            ? [worktreeGitDirectory, commonGitDirectory]
            : [commonGitDirectory]
        for root in orderedUnique(roots) {
            let looseRef = root.appendingPathComponent(reference, isDirectory: false)
            if let kind = try pathKind(at: looseRef) {
                guard kind == S_IFREG else {
                    throw GitRepositoryLayoutError.invalidMetadata("the loose HEAD reference is unsafe")
                }
                let value = try boundedSingleLine(
                    at: looseRef,
                    maximumBytes: maximumRefBytes,
                    role: "Git reference"
                )
                guard let objectID = normalizedObjectID(value) else {
                    throw GitRepositoryLayoutError.invalidMetadata("the loose HEAD reference is invalid")
                }
                return objectID
            }
        }

        let packedRefs = commonGitDirectory.appendingPathComponent("packed-refs", isDirectory: false)
        guard let packedKind = try pathKind(at: packedRefs) else {
            // Unborn branches and reftable repositories may not have a loose
            // or packed object ID. The symbolic HEAD remains valid evidence.
            return nil
        }
        guard packedKind == S_IFREG else {
            throw GitRepositoryLayoutError.invalidMetadata("packed-refs is unsafe")
        }
        let data = try boundedRegularFile(
            at: packedRefs,
            maximumBytes: maximumPackedRefsBytes,
            role: "packed-refs"
        )
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw GitRepositoryLayoutError.invalidMetadata("packed-refs is not bounded UTF-8")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= maximumPackedRefLines else {
            throw GitRepositoryLayoutError.invalidMetadata("packed-refs has too many lines")
        }
        for line in lines where !line.isEmpty && line.first != "#" && line.first != "^" {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else {
                throw GitRepositoryLayoutError.invalidMetadata("packed-refs is malformed")
            }
            if fields[1] == Substring(reference) {
                guard let objectID = normalizedObjectID(String(fields[0])) else {
                    throw GitRepositoryLayoutError.invalidMetadata("the packed HEAD reference is invalid")
                }
                return objectID
            }
        }
        return nil
    }

    /// Linked-worktree admin directories contain a reverse `gitdir` pointer.
    /// Requiring that exact, bounded relationship prevents a malicious .git
    /// file from granting GitService access to an unrelated repository.
    private static func verifyLinkedWorktreeRelationship(
        workspaceRoot: URL,
        gitEntry: URL,
        worktreeGitDirectory: URL,
        commonGitDirectory: URL
    ) throws {
        guard worktreeGitDirectory.path.hasPrefix(commonGitDirectory.path + "/") else {
            throw GitRepositoryLayoutError.invalidMetadata(
                "the linked-worktree directory is outside its common Git directory"
            )
        }
        let reversePointer = try boundedSingleLine(
            at: worktreeGitDirectory.appendingPathComponent("gitdir", isDirectory: false),
            maximumBytes: maximumPointerBytes,
            role: "linked-worktree gitdir"
        )
        let reverseTarget = resolve(reversePointer, relativeTo: worktreeGitDirectory)
        guard reverseTarget.path == gitEntry.path,
              gitEntry.deletingLastPathComponent().path == workspaceRoot.path else {
            throw GitRepositoryLayoutError.invalidMetadata(
                "the linked-worktree reverse pointer does not identify this workspace"
            )
        }
    }

    /// Submodules and `--separate-git-dir` repositories have no commondir.
    /// Their bounded core.worktree setting is the ownership proof that keeps a
    /// forged pointer from borrowing authority to an unrelated Git directory.
    private static func verifySeparateGitDirectoryRelationship(
        workspaceRoot: URL,
        gitDirectory: URL
    ) throws {
        let configURL = gitDirectory.appendingPathComponent("config", isDirectory: false)
        let data = try boundedRegularFile(
            at: configURL,
            maximumBytes: maximumConfigBytes,
            role: "Git config"
        )
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw GitRepositoryLayoutError.invalidMetadata("Git config is not bounded UTF-8")
        }
        guard let rawWorktree = coreWorktree(in: text), !rawWorktree.isEmpty else {
            throw GitRepositoryLayoutError.invalidMetadata(
                "a separate Git directory has no bounded core.worktree relationship"
            )
        }
        let configuredWorktree = resolve(rawWorktree, relativeTo: gitDirectory)
        let verifiedWorktree = try verifiedDirectory(
            configuredWorktree,
            role: "configured Git worktree",
            allowCanonicalization: true
        )
        guard verifiedWorktree.path == workspaceRoot.path else {
            throw GitRepositoryLayoutError.invalidMetadata(
                "the separate Git directory belongs to a different worktree"
            )
        }
    }

    private static func coreWorktree(in config: String) -> String? {
        var inCoreSection = false
        var result: String?
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { return nil }
                let section = line[line.index(after: line.startIndex)..<close]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                inCoreSection = section.caseInsensitiveCompare("core") == .orderedSame
                continue
            }
            guard inCoreSection else { continue }
            let separator = line.firstIndex(of: "=")
            let key: String
            let value: String
            if let separator {
                key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let pieces = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
                guard pieces.count == 2 else { continue }
                key = String(pieces[0])
                value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard key.caseInsensitiveCompare("worktree") == .orderedSame else { continue }
            line = value
            if line.hasPrefix("\"") && line.hasSuffix("\"") && line.count >= 2 {
                line.removeFirst()
                line.removeLast()
                // Git-generated submodule paths are unquoted. Support the
                // common quoted form, but reject escape syntax rather than
                // implementing Git config's broader interpolation grammar.
                guard !line.contains("\\") else { return nil }
            } else if line.hasPrefix("\"") || line.hasSuffix("\"") {
                return nil
            }
            result = line
        }
        return result
    }

    private static func rejectUnsafeMetadataAuthority(
        _ metadataDirectory: URL,
        workspaceRoot: URL
    ) throws {
        guard metadataDirectory.path != "/" else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory("the filesystem root is never Git metadata")
        }
        let metadataPath = comparisonPath(metadataDirectory)
        let workspacePath = comparisonPath(workspaceRoot)
        let metadataIsWorkspaceAncestor = workspacePath.hasPrefix(metadataPath + "/")
        let metadataIsInsideWorkspace = metadataPath.hasPrefix(workspacePath + "/")
        guard !metadataIsWorkspaceAncestor || metadataIsInsideWorkspace else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory(
                "a metadata directory cannot be an ancestor of the workspace"
            )
        }

        let protectedRoots = [
            AppPaths.appSupport,
            AppPaths.agentArtifacts,
            AppPaths.agentSnapshots,
            AppPaths.agentProcesses,
            AppPaths.agentLogs,
            AppPaths.agentWorktreeScratch,
            AppPaths.extensionScratch,
            AppPaths.hookLogs,
            AppPaths.browserAnnotations,
            AppPaths.browserRuntime,
            workspaceRoot.appendingPathComponent("tmp/browser", isDirectory: true),
            AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-runtime", isDirectory: true)
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !protectedRoots.contains(where: { protected in
            let protectedPath = comparisonPath(protected)
            return metadataPath == protectedPath
                || metadataPath.hasPrefix(protectedPath + "/")
        }) else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory(
                "host-owned Agent state cannot become repository metadata authority"
            )
        }
    }

    private static func boundedSingleLine(
        at url: URL,
        maximumBytes: Int,
        role: String
    ) throws -> String {
        let data = try boundedRegularFile(at: url, maximumBytes: maximumBytes, role: role)
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw GitRepositoryLayoutError.invalidMetadata("\(role) is not bounded UTF-8")
        }
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        guard !text.contains("\n"), !text.contains("\r") else {
            throw GitRepositoryLayoutError.invalidMetadata("\(role) is not a single line")
        }
        return text
    }

    private static func boundedRegularFile(
        at url: URL,
        maximumBytes: Int,
        role: String
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else {
            throw GitRepositoryLayoutError.invalidMetadata(Self.posixDetail("open \(role)", path: url))
        }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Int64(maximumBytes) else {
            throw GitRepositoryLayoutError.invalidMetadata("\(role) is not a bounded regular file")
        }

        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1_024, maximumBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw GitRepositoryLayoutError.invalidMetadata(Self.posixDetail("read \(role)", path: url))
            }
            guard result.count <= maximumBytes - count else {
                throw GitRepositoryLayoutError.invalidMetadata("\(role) exceeds its size limit")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == Int(info.st_size) else {
            throw GitRepositoryLayoutError.invalidMetadata("\(role) changed while it was inspected")
        }
        return result
    }

    private static func verifiedDirectory(
        _ rawURL: URL,
        role: String,
        allowCanonicalization: Bool = false
    ) throws -> URL {
        let standardized = rawURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard allowCanonicalization || resolved.path == standardized.path else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory("\(role) contains a symbolic link")
        }
        guard resolved.path != "/" else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory("\(role) is not a directory")
        }
        let descriptor = Darwin.open(
            resolved.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory("\(role) is not a directory")
        }
        defer { _ = Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw GitRepositoryLayoutError.unsafeMetadataDirectory("\(role) is not a directory")
        }
        return resolved
    }

    private static func pathKind(at url: URL) throws -> mode_t? {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw GitRepositoryLayoutError.invalidMetadata(Self.posixDetail("lstat", path: url))
        }
        return info.st_mode & S_IFMT
    }

    private static func resolve(_ rawPath: String, relativeTo base: URL) -> URL {
        (rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : base.appendingPathComponent(rawPath))
            .standardizedFileURL
    }

    private static func normalizedObjectID(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bytes = Array(normalized.utf8)
        guard bytes.count == 40 || bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return normalized
    }

    private static func isSafeGitReference(_ value: String) -> Bool {
        guard value.hasPrefix("refs/"), value.utf8.count <= maximumRefBytes,
              !value.hasSuffix("/"), !value.hasSuffix("."),
              !value.contains(".."), !value.contains("@{"), !value.contains("//"),
              !value.contains("\\"), !value.contains(" "), !value.contains("~"),
              !value.contains("^"), !value.contains(":"), !value.contains("?"),
              !value.contains("*"), !value.contains("["), !value.contains("\0"),
              value.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    private static func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func removingNestedDuplicates(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in orderedUnique(urls).sorted(by: { $0.path.count < $1.path.count }) {
            guard !result.contains(where: { root in
                url.path == root.path || url.path.hasPrefix(root.path + "/")
            }) else { continue }
            result.append(url)
        }
        return result
    }

    private static func comparisonPath(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func posixDetail(_ operation: String, path: URL) -> String {
        "\(operation) failed for \(path.lastPathComponent): \(String(cString: strerror(errno)))"
    }
}
