import Darwin
import Foundation

enum WorkspacePathAccess: Equatable, Sendable {
    case read
    case write
    case execute
}

enum WorkspaceSecurityError: LocalizedError, Equatable, Sendable {
    case invalidWorkspace
    case emptyPath
    case pathDoesNotExist(String)
    case pathEscapesWorkspace(String)
    case symbolicLinkEscape(String)
    case symbolicLinkMutation(String)
    case expectedDirectory(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: "Workspace 根目錄無效。"
        case .emptyPath: "路徑不可為空白。"
        case .pathDoesNotExist(let path): "Workspace 中找不到「\(path)」。"
        case .pathEscapesWorkspace(let path): "路徑「\(path)」超出 Workspace 安全範圍。"
        case .symbolicLinkEscape(let path): "符號連結「\(path)」會離開 Workspace。"
        case .symbolicLinkMutation(let path): "拒絕直接修改符號連結「\(path)」。"
        case .expectedDirectory(let path): "「\(path)」不是可用的資料夾。"
        }
    }
}

struct WorkspaceSecurityValidator: @unchecked Sendable {
    let workspace: AgentWorkspace
    private let fileManager: FileManager
    private let canonicalRoot: URL
    private let canonicalAllowedRoots: [URL]
    private let protectedRuntimeRoots: [URL]
    private let rootDevice: UInt64
    private let rootInode: UInt64

    /// The canonical root is exposed only to the descriptor-based workspace
    /// boundary. Callers must not append paths to this string and then perform
    /// filesystem operations; use `secureRelativePath(for:)` and `openat(2)`.
    var secureRootPath: String { canonicalRoot.path }
    var secureRootIdentity: (device: UInt64, inode: UInt64) {
        (rootDevice, rootInode)
    }

    /// Reopens the canonical workspace path without following symlinks and
    /// verifies that it still names the directory authorized at construction.
    /// Long-lived services pin descriptors to that original directory, while
    /// path-based subprocesses reopen `secureRootPath`; rejecting a replaced
    /// pathname prevents those two authorities from silently diverging.
    func validateLiveRootIdentity() throws {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        let descriptor = Darwin.open(canonicalRoot.path, flags)
        guard descriptor >= 0 else {
            throw WorkspaceSecurityError.invalidWorkspace
        }
        defer { Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              UInt64(info.st_dev) == rootDevice,
              UInt64(info.st_ino) == rootInode else {
            throw WorkspaceSecurityError.invalidWorkspace
        }
    }

    init(workspace: AgentWorkspace, fileManager: FileManager = .default) throws {
        self.workspace = workspace
        self.fileManager = fileManager

        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.path != "/",
              fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceSecurityError.invalidWorkspace
        }
        var rootInfo = Darwin.stat()
        guard Darwin.lstat(root.path, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw WorkspaceSecurityError.invalidWorkspace
        }
        let projectTemporaryRoot = AppPaths.projectTemporaryRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let persistentStateRoot = AppPaths.appSupport
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let persistentStateUsesTestTemporaryRoot = Self.isAtOrBelow(
            persistentStateRoot,
            projectTemporaryRoot
        )
        // Managed worktrees are the sole workspace-shaped exception below
        // Application Support. The capability is restricted to one existing,
        // non-symbolic UUID direct child of the app-owned Checkouts directory;
        // the registry, sibling checkouts, and every other persistent path stay
        // outside this validator's root authority.
        let isManagedWorktreeCheckout = Self.isManagedWorktreeCheckout(root)
        let hostRuntimeRoots = [
            AppPaths.agentArtifacts,
            AppPaths.agentSnapshots,
            AppPaths.agentProcesses,
            AppPaths.agentLogs,
            AppPaths.agentWorktreeScratch,
            AppPaths.extensionScratch,
            AppPaths.hookLogs,
            AppPaths.browserAnnotations,
            AppPaths.browserRuntime,
            AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-runtime", isDirectory: true)
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !Self.pathsEqual(root, projectTemporaryRoot),
              // A workspace above Application Support could rewrite LumaChat's
              // settings/session/MCP state; a workspace below it is itself
              // host-owned persistent state. Reject both directions instead
              // of relying on a lexical subtree filter for self-authority.
              (!Self.isAtOrBelow(root, persistentStateRoot) || isManagedWorktreeCheckout),
              (persistentStateUsesTestTemporaryRoot
                  || isManagedWorktreeCheckout
                  || !Self.isAtOrBelow(persistentStateRoot, root)),
              !hostRuntimeRoots.contains(where: { protected in
                  Self.isAtOrBelow(root, protected)
              }) else {
            throw WorkspaceSecurityError.invalidWorkspace
        }
        canonicalRoot = root
        rootDevice = UInt64(rootInfo.st_dev)
        rootInode = UInt64(rootInfo.st_ino)

        var allowed = [root]
        for rawPath in workspace.allowedPaths {
            let candidate = URL(fileURLWithPath: rawPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var candidateIsDirectory: ObjCBool = false
            // AgentWorkspace currently carries one security-scoped bookmark for
            // its root. Persisted/tampered `allowedPaths` must not expand that
            // authority until per-path bookmarks are modeled explicitly.
            guard candidate.path != "/",
                  (candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")),
                  fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory),
                  candidateIsDirectory.boolValue else { continue }
            allowed.append(candidate)
        }
        canonicalAllowedRoots = Self.removingNestedDuplicates(allowed)

        // Runtime artifacts live below this repository's tmp directory. When
        // LumaChat itself is opened as the workspace, those files must not
        // become model-readable project data or be renamed/deleted through a
        // workspace mutation. Artifact handles are consumed by the host UI,
        // outside the native workspace tool boundary.
        protectedRuntimeRoots = [
            AppPaths.agentArtifacts,
            AppPaths.agentSnapshots,
            AppPaths.agentProcesses,
            AppPaths.agentLogs,
            AppPaths.agentWorktreeScratch,
            AppPaths.extensionScratch,
            AppPaths.hookLogs,
            AppPaths.browserAnnotations,
            AppPaths.browserRuntime,
            root.appendingPathComponent("tmp/browser", isDirectory: true),
            AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-runtime", isDirectory: true),
            persistentStateRoot
        ]
        .map(\.standardizedFileURL)
        .filter { path in
            Self.isAtOrBelow(path, root)
        }
    }

    func validate(
        path rawPath: String,
        access: WorkspacePathAccess = .read,
        allowNonexistentLeaf: Bool = false,
        rejectLeafSymlink: Bool = false
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw WorkspaceSecurityError.emptyPath
        }

        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains("..") else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }

        let candidate = (trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : canonicalRoot.appendingPathComponent(trimmed))
            .standardizedFileURL

        guard isWithinAllowedRoot(candidate) else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }
        try rejectProtectedRuntimePath(candidate, access: access, originalPath: trimmed)

        if fileManager.fileExists(atPath: candidate.path) {
            let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true && (access == .write || rejectLeafSymlink) {
                throw WorkspaceSecurityError.symbolicLinkMutation(trimmed)
            }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isWithinAllowedRoot(resolved) else {
                throw WorkspaceSecurityError.symbolicLinkEscape(trimmed)
            }
            try rejectProtectedRuntimePath(resolved, access: access, originalPath: trimmed)
            return resolved
        }

        guard allowNonexistentLeaf, access == .write else {
            throw WorkspaceSecurityError.pathDoesNotExist(trimmed)
        }

        var existingAncestor = candidate.deletingLastPathComponent()
        var missingComponents = [candidate.lastPathComponent]
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }

        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        guard isWithinAllowedRoot(resolvedAncestor) else {
            throw WorkspaceSecurityError.symbolicLinkEscape(trimmed)
        }

        let rebuilt = missingComponents.reduce(resolvedAncestor) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
        guard isWithinAllowedRoot(rebuilt) else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }
        try rejectProtectedRuntimePath(rebuilt, access: access, originalPath: trimmed)
        return rebuilt
    }

    func validate(cwd rawPath: String?) throws -> URL {
        let directory = try validate(path: rawPath?.isEmpty == false ? rawPath! : ".")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceSecurityError.expectedDirectory(rawPath ?? ".")
        }
        return directory
    }

    /// Converts a user supplied path into a lexical path relative to the
    /// workspace root. This intentionally does not resolve symlinks. Native
    /// filesystem tools pass the result to `openat(2)` with
    /// `O_RESOLVE_BENEATH | O_NOFOLLOW_ANY`, closing the validation/use race
    /// that exists when a URL is checked and opened in separate operations.
    func secureRelativePath(
        for rawPath: String,
        access: WorkspacePathAccess = .read
    ) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw WorkspaceSecurityError.emptyPath
        }

        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains("..") else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }

        let candidate = (trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : canonicalRoot.appendingPathComponent(trimmed))
            .standardizedFileURL
        let rootPrefix = canonicalRoot.path + "/"
        guard candidate.path == canonicalRoot.path || candidate.path.hasPrefix(rootPrefix) else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }
        try rejectProtectedRuntimePath(candidate, access: access, originalPath: trimmed)

        if candidate.path == canonicalRoot.path { return "." }
        let relative = String(candidate.path.dropFirst(rootPrefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw WorkspaceSecurityError.pathEscapesWorkspace(trimmed)
        }
        return components.joined(separator: "/")
    }

    /// True when a descendant is host-owned runtime state and must be omitted
    /// from directory listings and search traversal.
    func isProtectedRuntimePath(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        return protectedRuntimeRoots.contains { protected in
            Self.isAtOrBelow(candidate, protected)
        }
    }

    func isProtectedRuntimeRelativePath(_ relativePath: String) -> Bool {
        let candidate = relativePath == "." || relativePath.isEmpty
            ? canonicalRoot
            : canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        return isProtectedRuntimePath(candidate)
    }

    /// Runtime roots expressed relative to a validated search/list root.
    func protectedRuntimePaths(relativeTo directory: URL) -> [String] {
        let base = directory.standardizedFileURL
        let baseComponents = base.pathComponents
        return protectedRuntimeRoots.compactMap { protected in
            let protectedComponents = protected.pathComponents
            guard protectedComponents.count > baseComponents.count,
                  zip(baseComponents, protectedComponents).allSatisfy({ lhs, rhs in
                      lhs.precomposedStringWithCanonicalMapping.lowercased()
                          == rhs.precomposedStringWithCanonicalMapping.lowercased()
                  }) else { return nil }
            return protectedComponents.dropFirst(baseComponents.count).joined(separator: "/")
        }
    }

    func relativePath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        if resolved.path == canonicalRoot.path { return "." }
        if resolved.path.hasPrefix(rootPrefix) {
            return String(resolved.path.dropFirst(rootPrefix.count))
        }
        return resolved.lastPathComponent
    }

    private func isWithinAllowedRoot(_ url: URL) -> Bool {
        canonicalAllowedRoots.contains { root in
            url.path == root.path || url.path.hasPrefix(root.path + "/")
        }
    }

    private func rejectProtectedRuntimePath(
        _ candidate: URL,
        access: WorkspacePathAccess,
        originalPath: String
    ) throws {
        for protected in protectedRuntimeRoots {
            let atOrBelowProtected = Self.isAtOrBelow(candidate, protected)
            // Mutating an ancestor could rename/delete the pinned runtime root
            // and defeat the lexical exclusion, so ancestors are write-denied.
            let ancestorOfProtected = Self.isAtOrBelow(protected, candidate)
                && !Self.pathsEqual(protected, candidate)
            if atOrBelowProtected || (access == .write && ancestorOfProtected) {
                throw WorkspaceSecurityError.pathEscapesWorkspace(originalPath)
            }
        }
    }

    private static func removingNestedDuplicates(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) {
            if result.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func isManagedWorktreeCheckout(_ canonicalRoot: URL) -> Bool {
        let configuredManagedRoot = AppPaths.managedWorktrees.standardizedFileURL
        var managedInfo = Darwin.stat()
        guard Darwin.lstat(configuredManagedRoot.path, &managedInfo) == 0,
              managedInfo.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        let managedRoot = configuredManagedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalRoot.deletingLastPathComponent().path == managedRoot.path,
              ManagedWorktreeRegistryAuthorization.record(
                authorizing: canonicalRoot,
                managedRoot: managedRoot
              ) != nil else {
            return false
        }
        return true
    }

    /// exFAT (the development volume used by this project) is
    /// case-insensitive. A conservative Unicode-normalized fold also safely
    /// over-blocks aliases on case-sensitive filesystems rather than exposing
    /// host runtime state through alternate casing.
    private static func comparisonPath(_ url: URL) -> String {
        url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func pathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        comparisonPath(lhs) == comparisonPath(rhs)
    }

    private static func isAtOrBelow(_ candidate: URL, _ root: URL) -> Bool {
        let candidatePath = comparisonPath(candidate)
        let rootPath = comparisonPath(root)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
