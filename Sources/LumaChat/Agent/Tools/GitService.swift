import CryptoKit
import Darwin
import Foundation

enum GitServiceError: LocalizedError, Sendable {
    case notRepository
    case invalidReference(String)
    case commandFailed(command: String, exitCode: Int32, output: String)
    case tooManyChangedFiles(Int)
    case unsafeFilteredPath(String)
    case unsafeAttributePath(path: String, attribute: String)
    case directoryStagingRequiresFiles(String)
    case unsafePathInventory(String)
    case invalidRepositoryLayout(String)
    case metadataSnapshotsUnavailable
    case unsafeRemote(String)
    case invalidMessage(String)
    case unsafeReviewSource(String)
    case unsafeReviewPatch(String)
    case operationStateMismatch(expected: String, active: [String])

    var errorDescription: String? {
        switch self {
        case .notRepository: "The workspace is not a Git repository."
        case .invalidReference(let reference): "Invalid Git reference: \(reference)"
        case .commandFailed(let command, let exitCode, let output):
            "Git command failed (\(exitCode)): \(command)\n\(output)"
        case .tooManyChangedFiles(let maximum):
            "Git mutation would affect more than \(maximum) files; narrow the operation or use a separately approved terminal flow."
        case .unsafeFilteredPath(let path):
            "Refusing to mutate \(path) because a repository-controlled Git content filter applies."
        case .unsafeAttributePath(let path, let attribute):
            "Refusing to mutate \(path) because repository attribute \(attribute) can execute a custom driver."
        case .directoryStagingRequiresFiles(let path):
            "Stage explicit files instead of directory \(path) so clean-filter safety can be verified."
        case .unsafePathInventory(let detail):
            "Unable to establish a complete, unambiguous Git path inventory: \(detail)"
        case .invalidRepositoryLayout(let detail):
            "The workspace Git repository layout is unsafe: \(detail)"
        case .metadataSnapshotsUnavailable:
            "This Git mutation cannot provide a truthful workspace Undo snapshot."
        case .unsafeRemote(let detail):
            "The Git remote is unavailable or violates the non-interactive remote policy: \(detail)"
        case .invalidMessage(let detail):
            "Invalid Git message: \(detail)"
        case .unsafeReviewSource(let detail):
            "The Review source was refused: \(detail)"
        case .unsafeReviewPatch(let detail):
            "The Review patch was refused: \(detail)"
        case .operationStateMismatch(let expected, let active):
            if active.isEmpty {
                "Git \(expected) is unavailable because that operation is not in progress."
            } else {
                "Git \(expected) is unavailable while \(active.joined(separator: ", ")) is in progress."
            }
        }
    }
}

enum GitReviewPatchTarget: String, Codable, CaseIterable, Sendable {
    case index
    case worktree
}

/// File-level fallback actions are deliberately separate from patch apply.
/// The caller cannot supply a Git subcommand: this enum maps to three fixed,
/// host-owned operations after the displayed Review identity is revalidated.
enum GitReviewFileMutation: String, Codable, CaseIterable, Sendable {
    case stage
    case unstage
    case revert
}

enum GitPullStrategy: String, Codable, CaseIterable, Sendable {
    case fastForwardOnly = "ff-only"
    case merge
    case rebase
}

enum GitMergeStrategy: String, Codable, CaseIterable, Sendable {
    case fastForwardOnly = "ff-only"
    case merge
}

/// A closed, reviewable policy table for Git operations. Tool registration uses
/// this table rather than inferring risk from model-provided arguments.
enum GitOperationSafety: String, Codable, Sendable {
    case readOnly
    case localMutation
    case networkRead
    case destructiveLocal
    case destructiveNetwork

    var permissionLevel: AgentPermissionLevel {
        switch self {
        case .readOnly: .read
        case .localMutation: .write
        case .networkRead: .network
        case .destructiveLocal, .destructiveNetwork: .dangerous
        }
    }

    var requiresNetwork: Bool {
        self == .networkRead || self == .destructiveNetwork
    }

    var requiresExplicitApproval: Bool {
        permissionLevel == .dangerous
    }
}

enum GitOperation: String, Codable, CaseIterable, Sendable {
    case status, diff, log, show, branches, remotes, tags, stashList
    case add, commit, createBranch, merge, mergeContinue, cherryPick, cherryPickContinue
    case stashPush, stashApply, createTag
    case fetch
    case restore, checkout, switchBranch, deleteBranch, hardReset
    case mergeAbort, rebase, rebaseContinue, rebaseAbort
    case cherryPickAbort, stashDrop, deleteTag
    case addRemote, removeRemote
    case pull, push

    var safety: GitOperationSafety {
        switch self {
        case .status, .diff, .log, .show, .branches, .remotes, .tags, .stashList:
            .readOnly
        case .add, .commit, .createBranch, .merge, .mergeContinue,
             .cherryPick, .cherryPickContinue,
             .stashPush, .stashApply, .createTag:
            .localMutation
        case .fetch:
            .networkRead
        case .restore, .checkout, .switchBranch, .deleteBranch, .hardReset,
             .mergeAbort, .rebase, .rebaseContinue, .rebaseAbort,
             .cherryPickAbort, .stashDrop, .deleteTag, .addRemote, .removeRemote:
            .destructiveLocal
        case .pull, .push:
            .destructiveNetwork
        }
    }
}

struct GitCommandResult: Codable, Sendable, Equatable {
    var output: String
    var exitCode: Int32
    var truncated: Bool
    var artifactPath: String?
    var change: FileChangeRecord?
}

private struct ValidatedGitReviewPatch: Sendable {
    var data: Data
    var paths: [String]
}

private struct TrackedReviewFallbackEntry: Sendable {
    var path: String
    var oldMode: String
    var newMode: String
    var oldObjectID: String
    var newObjectID: String
    var status: Character
}

private enum GitOperationState: String, CaseIterable, Sendable {
    case merge
    case rebase
    case cherryPick = "cherry-pick"
}

private enum GitRemoteDirection: Sendable {
    case fetch
    case push
}

/// A deliberately closed Git API. Every supported operation maps to fixed Git
/// arguments; model-generated input can never become an arbitrary subcommand.
actor GitService {
    private static let maximumReviewSourceBytes = 16 * 1_024 * 1_024
    private static let maximumReviewFileBytes = 2 * 1_024 * 1_024
    private static let maximumReviewIdentityBytes = 256 * 1_024 * 1_024
    private static let maximumTurnBaselineContentBytes = 16 * 1_024 * 1_024
    private static let maximumTurnBaselineFileBytes = 4 * 1_024 * 1_024
    private static let maximumReviewFiles = 512
    private static let maximumTurnFinalizationAttempts = 3

    private struct AgentTurnCheckoutIdentity: Equatable, Sendable {
        var headRevision: String?
        var files: [AgentTurnReviewFileIdentity]
    }

    private struct AgentTurnReviewFileIdentity: Equatable, Sendable {
        var path: String
        var existed: Bool
        var byteCount: Int64
        var permissions: Int?
        var sha256: String?
    }

    private let validator: WorkspaceSecurityValidator
    private let secureIO: SecureWorkspaceIO
    private let terminal: TerminalSession
    private let changes: ChangeManager
    private let timeout: TimeInterval
    private let repositoryLayout: GitRepositoryLayout
    private let remoteCredentialResolver: GitRemoteCredentialResolver
    /// Internal dependency-injection seam used by deterministic concurrency
    /// tests. Production leaves it nil.
    private let agentTurnFinalizationBoundaryHook: (@Sendable (Int) async throws -> Void)?
    private var activeGitCommandCount = 0
    private var reviewPatchHasExclusiveAccess = false
    private var commandGateWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        validator: WorkspaceSecurityValidator,
        terminal: TerminalSession,
        changes: ChangeManager,
        timeout: TimeInterval = 60,
        remoteCredentialResolver: GitRemoteCredentialResolver = .disabled,
        agentTurnFinalizationBoundaryHook: (@Sendable (Int) async throws -> Void)? = nil
    ) throws {
        self.validator = validator
        secureIO = try SecureWorkspaceIO(validator: validator)
        self.terminal = terminal
        self.changes = changes
        self.timeout = max(1, timeout)
        self.remoteCredentialResolver = remoteCredentialResolver
        self.agentTurnFinalizationBoundaryHook = agentTurnFinalizationBoundaryHook
        do {
            guard let layout = try GitRepositoryLayout.inspect(
                workspaceRoot: URL(fileURLWithPath: validator.secureRootPath, isDirectory: true)
            ) else {
                throw GitServiceError.notRepository
            }
            repositoryLayout = layout
        } catch let error as GitServiceError {
            throw error
        } catch {
            throw GitServiceError.invalidRepositoryLayout(error.localizedDescription)
        }
        guard repositoryLayout.workspaceRoot.path == validator.secureRootPath else {
            throw GitServiceError.notRepository
        }
    }

    func status() async throws -> GitCommandResult {
        try await read(["status", "--short", "--branch"])
    }

    func diff(staged: Bool = false, contextLines: Int = 3) async throws -> GitCommandResult {
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=\(max(0, min(contextLines, 100)))"]
        if staged { arguments.append("--cached") }
        return try await read(arguments)
    }

    func diffFile(path: String, staged: Bool = false) async throws -> GitCommandResult {
        let relative = try validatedRelativePath(path, access: .read)
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if staged { arguments.append("--cached") }
        arguments += ["--", relative]
        return try await read(arguments)
    }

    /// Branch Review uses Git's three-dot form: changes reachable from `head`
    /// since the merge-base with `base`, rather than unrelated changes on both
    /// branch tips.
    func diff(
        baseRevision: String,
        headRevision: String,
        contextLines: Int = 3
    ) async throws -> GitCommandResult {
        let base = try validatedReference(baseRevision)
        let head = try validatedReference(headRevision)
        return try await read([
            "diff", "--no-ext-diff", "--no-textconv", "--no-color",
            "--unified=\(max(0, min(contextLines, 100)))",
            "\(base)...\(head)", "--"
        ])
    }

    func log(maximumCount: Int = 20) async throws -> GitCommandResult {
        try await read([
            "log", "--no-color", "--decorate=short",
            "--pretty=format:%h%x09%ad%x09%an%x09%d %s", "--date=iso-strict",
            "--max-count=\(max(1, min(maximumCount, 200)))"
        ])
    }

    func branches(includeRemote: Bool = false) async throws -> GitCommandResult {
        var arguments = ["branch", "--no-color", "--verbose", "--no-abbrev"]
        if includeRemote { arguments.append("--all") }
        return try await read(arguments)
    }

    func currentBranch() async throws -> GitCommandResult {
        try await read(["branch", "--show-current"])
    }

    func remotes() async throws -> GitCommandResult {
        // Deliberately list names only. `remote --verbose` can echo credentials
        // embedded by a user in a pre-existing URL into model-visible output.
        try await read(["remote"])
    }

    func tags(maximumCount: Int = 100) async throws -> GitCommandResult {
        try await read([
            "for-each-ref", "--no-color", "--sort=-creatordate",
            "--count=\(max(1, min(maximumCount, 500)))",
            "--format=%(refname:short)%09%(objectname:short)%09%(creatordate:iso-strict)",
            "refs/tags"
        ])
    }

    func stashList(maximumCount: Int = 50) async throws -> GitCommandResult {
        try await read([
            "stash", "list", "--no-color",
            "--format=%gd%x09%H%x09%ci%x09%s",
            "--max-count=\(max(1, min(maximumCount, 200)))"
        ])
    }

    func show(reference: String, path: String? = nil) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        var object = reference
        if let path {
            object += ":" + (try validatedRelativePath(path, access: .read))
        }
        return try await read(["show", "--no-ext-diff", "--no-textconv", "--no-color", object])
    }

    /// Loads a production Review source from the complete app-owned stdout
    /// artifact, never from Terminal's head/tail presentation. The returned
    /// text is strictly UTF-8 and bounded to the parser's 16 MiB document
    /// limit. Unstaged Review additionally includes every bounded, unignored
    /// untracked regular file as a real or host-generated fallback diff.
    func reviewSource(for source: ReviewSource) async throws -> GitCommandResult {
        switch source {
        case .lastAgentTurn:
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn must be loaded from durable Task changes"
            )
        case .unstaged, .staged, .commit, .branch:
            break
        }

        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }
        return try await reviewSourceWithoutGate(for: source)
    }

    /// Captures the exact pre-run worktree state needed to subtract changes
    /// that already existed before an Agent turn. Clean tracked files remain
    /// anchored to `startRevision`; only dirty/untracked paths consume the
    /// bounded durable-content budget.
    func captureAgentTurnReviewBaseline(
        runID: UUID,
        sessionID: UUID
    ) async throws -> AgentTurnReviewBaseline {
        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }
        return try await captureAgentTurnReviewBaselineWithoutGate(
            runID: runID,
            sessionID: sessionID
        )
    }

    private func captureAgentTurnReviewBaselineWithoutGate(
        runID: UUID,
        sessionID: UUID
    ) async throws -> AgentTurnReviewBaseline {
        try validateLiveAgentTurnReviewRoot()

        let revision = try await currentHeadRevisionWithoutGate()
        var paths: [String]
        if let revision {
            paths = try decodeNULTerminatedStrings(
                try await rawGitBytesWithoutGate([
                    "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                    "--name-only", "-z", "--diff-filter=ACDMRTUXB", revision, "--"
                ], maximumDecodedBytes: 8 * 1_024 * 1_024),
                maximumCount: Self.maximumReviewFiles
            )
        } else {
            paths = try decodeNULTerminatedStrings(
                try await rawGitBytesWithoutGate(
                    ["ls-files", "--cached", "-z", "--"],
                    maximumDecodedBytes: 8 * 1_024 * 1_024
                ),
                maximumCount: Self.maximumReviewFiles
            )
        }
        let untracked = try decodeNULTerminatedStrings(
            try await rawGitBytesWithoutGate(
                ["ls-files", "--others", "--exclude-standard", "-z", "--"],
                maximumDecodedBytes: 8 * 1_024 * 1_024
            ),
            maximumCount: Self.maximumReviewFiles
        )
        paths.append(contentsOf: untracked)
        paths = Array(Set(paths)).sorted()
        guard paths.count <= Self.maximumReviewFiles else {
            throw GitServiceError.tooManyChangedFiles(Self.maximumReviewFiles)
        }

        var durableBytes = 0
        var identityBytes: Int64 = 0
        var files: [AgentTurnReviewFileBaseline] = []
        files.reserveCapacity(paths.count)
        for rawPath in paths {
            try Task.checkCancellation()
            let path = try validatedAgentTurnReviewPath(rawPath, access: .read)
            guard try secureIO.exists(path: path) else {
                files.append(AgentTurnReviewFileBaseline(
                    path: path,
                    existed: false,
                    byteCount: 0,
                    permissions: nil,
                    sha256: nil,
                    data: nil
                ))
                continue
            }
            let metadata = try secureIO.metadata(path: path)
            guard metadata.kind == .regularFile,
                  metadata.byteCount >= 0,
                  identityBytes + metadata.byteCount
                    <= Int64(Self.maximumReviewIdentityBytes) else {
                throw GitServiceError.unsafeReviewSource(
                    "pre-run file identities exceed the 256 MiB Last Agent Turn limit"
                )
            }
            let remainingIdentityBytes = Self.maximumReviewIdentityBytes - Int(identityBytes)
            let fileData: Data?
            let digest: String
            let capturedMetadata: SecureWorkspaceMetadata
            if metadata.byteCount <= Int64(Self.maximumTurnBaselineFileBytes) {
                let read = try secureIO.readRegularFile(
                    path: path,
                    maximumBytes: remainingIdentityBytes
                )
                guard !read.truncated, read.metadata.byteCount == metadata.byteCount else {
                    throw GitServiceError.unsafeReviewSource(
                        "pre-run file \(path) changed during Last Agent Turn capture"
                    )
                }
                fileData = read.data
                digest = Self.sha256(read.data)
                capturedMetadata = read.metadata
            } else {
                let streamed = try secureIO.sha256RegularFile(
                    path: path,
                    maximumBytes: remainingIdentityBytes
                )
                guard streamed.metadata.byteCount == metadata.byteCount else {
                    throw GitServiceError.unsafeReviewSource(
                        "pre-run file \(path) changed during Last Agent Turn capture"
                    )
                }
                fileData = nil
                digest = streamed.sha256
                capturedMetadata = streamed.metadata
            }
            identityBytes += capturedMetadata.byteCount
            let retained: Data?
            if let fileData,
               durableBytes <= Self.maximumTurnBaselineContentBytes - fileData.count {
                retained = fileData
                durableBytes += fileData.count
            } else {
                retained = nil
            }
            files.append(AgentTurnReviewFileBaseline(
                path: path,
                existed: true,
                byteCount: capturedMetadata.byteCount,
                permissions: capturedMetadata.permissions,
                sha256: digest,
                data: retained
            ))
        }

        let finalRevision = try await currentHeadRevisionWithoutGate()
        guard finalRevision == revision else {
            throw GitServiceError.unsafeReviewSource(
                "HEAD changed during Last Agent Turn checkout capture"
            )
        }
        try validateLiveAgentTurnReviewRoot()
        let identity = validator.secureRootIdentity
        return AgentTurnReviewBaseline(
            version: AgentTurnReviewBaseline.currentVersion,
            runID: runID,
            sessionID: sessionID,
            capturedAt: Date(),
            workspaceID: validator.workspace.id,
            canonicalRootPath: validator.secureRootPath,
            rootDevice: identity.device,
            rootInode: identity.inode,
            startRevision: revision,
            files: files
        )
    }

    /// Reconstructs the net worktree delta from a durable pre-run baseline.
    /// This includes direct shell writes and commits made during the run while
    /// excluding dirty/untracked content that was already present at capture.
    func reviewSource(since baseline: AgentTurnReviewBaseline) async throws -> GitCommandResult {
        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }
        return try await reviewSourceSinceBaselineWithoutGate(baseline)
    }

    private func reviewSourceSinceBaselineWithoutGate(
        _ baseline: AgentTurnReviewBaseline
    ) async throws -> GitCommandResult {
        try validateAgentTurnReviewBaseline(baseline)
        try validateLiveAgentTurnReviewRoot()

        let baselinePaths = Set(baseline.files.map(\.path))
        var segments: [String] = []
        var semanticallyTruncated = false

        if let revision = baseline.startRevision {
            let arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                "--no-renames", "--unified=3", revision, "--"
            ]
            let result = try await rawWithoutGate(arguments)
            defer { removeTransientArtifacts(from: result) }
            try ensureSuccess(result, arguments: arguments)
            let raw = try completeReviewStdout(result)
            let filtered = try reviewDiffSegments(raw).filter { segment in
                let file = try parsedSingleReviewFile(segment)
                return baselinePaths.isDisjoint(with: [file.oldPath, file.newPath].compactMap { $0 })
            }
            segments.append(contentsOf: filtered)

            let untracked = try await untrackedReviewDiffsWithoutGate()
            let filteredUntracked = try reviewDiffSegments(untracked.text).filter { segment in
                let file = try parsedSingleReviewFile(segment)
                return baselinePaths.isDisjoint(with: [file.oldPath, file.newPath].compactMap { $0 })
            }
            segments.append(contentsOf: filteredUntracked)
            semanticallyTruncated = semanticallyTruncated || untracked.truncated
        }

        var compared = Dictionary(uniqueKeysWithValues: baseline.files.map { ($0.path, $0) })
        if baseline.startRevision == nil {
            var currentPaths = try decodeNULTerminatedStrings(
                try await rawGitBytesWithoutGate(
                    ["ls-files", "--cached", "-z", "--"],
                    maximumDecodedBytes: 8 * 1_024 * 1_024
                ),
                maximumCount: Self.maximumReviewFiles
            )
            currentPaths += try decodeNULTerminatedStrings(
                try await rawGitBytesWithoutGate(
                    ["ls-files", "--others", "--exclude-standard", "-z", "--"],
                    maximumDecodedBytes: 8 * 1_024 * 1_024
                ),
                maximumCount: Self.maximumReviewFiles
            )
            for rawPath in currentPaths {
                let path = try validatedAgentTurnReviewPath(rawPath, access: .read)
                if compared[path] == nil {
                    compared[path] = AgentTurnReviewFileBaseline(
                        path: path,
                        existed: false,
                        byteCount: 0,
                        permissions: nil,
                        sha256: nil,
                        data: nil
                    )
                }
            }
            guard compared.count <= Self.maximumReviewFiles else {
                throw GitServiceError.tooManyChangedFiles(Self.maximumReviewFiles)
            }
        }

        var identityBytes: Int64 = 0
        for old in compared.values.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let current = try currentAgentTurnFile(path: old.path, identityBytes: &identityBytes)
            guard old.existed != current.existed
                    || old.sha256 != current.sha256
                    || old.permissions != current.permissions else { continue }
            let diff = Self.agentTurnDiff(path: old.path, old: old, new: current)
            if Self.reviewSourceContainsOmission(diff) { semanticallyTruncated = true }
            segments.append(diff)
        }

        let output = segments.filter { !$0.isEmpty }.joined(separator: "\n")
        guard output.utf8.count <= Self.maximumReviewSourceBytes else {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn diff exceeds the 16 MiB source limit"
            )
        }
        if !output.isEmpty {
            do {
                let document = try ReviewDiffParser().parse(
                    output,
                    source: .lastAgentTurn(taskID: baseline.sessionID)
                )
                if document.files.contains(where: { $0.fallback != nil }) {
                    semanticallyTruncated = true
                }
            } catch {
                throw GitServiceError.unsafeReviewSource(error.localizedDescription)
            }
        }
        try validateLiveAgentTurnReviewRoot()
        return GitCommandResult(
            output: output,
            exitCode: 0,
            truncated: semanticallyTruncated,
            artifactPath: nil,
            change: nil
        )
    }

    /// Atomically promotes a pending pre-run baseline into a durable immutable
    /// Review source. Callers persist the returned value only after the coding
    /// runtime and its Task-owned processes have reached a terminal boundary.
    func finalizeAgentTurnReviewSnapshot(
        since baseline: AgentTurnReviewBaseline
    ) async throws -> AgentTurnReviewSnapshot {
        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }
        try validateAgentTurnReviewBaseline(baseline)

        // Task Terminal and external processes are allowed to coexist with an
        // Agent. Establish an optimistic global read transaction: two complete
        // renders must agree, while three surrounding identities (HEAD plus
        // every changed/deleted/untracked path's size, mode, and SHA-256) stay
        // identical. Per-file reads additionally validate descriptor metadata
        // before/after each stream. A writer that does not quiesce is retried a
        // bounded number of times and then fails closed.
        for attempt in 0..<Self.maximumTurnFinalizationAttempts {
            try Task.checkCancellation()
            let before = try await agentTurnCheckoutIdentityWithoutGate(baseline)
            let first = try await reviewSourceSinceBaselineWithoutGate(baseline)
            let middle = try await agentTurnCheckoutIdentityWithoutGate(baseline)
            try await agentTurnFinalizationBoundaryHook?(attempt)
            let second = try await reviewSourceSinceBaselineWithoutGate(baseline)
            let after = try await agentTurnCheckoutIdentityWithoutGate(baseline)

            guard before == middle,
                  middle == after,
                  first.output == second.output,
                  first.truncated == second.truncated else {
                continue
            }

            try validateLiveAgentTurnReviewRoot()
            let rootIdentity = validator.secureRootIdentity
            let bytes = Data(second.output.utf8)
            guard bytes.count <= Self.maximumReviewSourceBytes else {
                throw GitServiceError.unsafeReviewSource(
                    "Last Agent Turn frozen source exceeds the 16 MiB source limit"
                )
            }
            return AgentTurnReviewSnapshot(
                version: AgentTurnReviewSnapshot.currentVersion,
                runID: baseline.runID,
                sessionID: baseline.sessionID,
                finalizedAt: Date(),
                workspaceID: validator.workspace.id,
                canonicalRootPath: validator.secureRootPath,
                rootDevice: rootIdentity.device,
                rootInode: rootIdentity.inode,
                source: second.output,
                sourceSHA256: Self.sha256(bytes),
                truncated: second.truncated
            )
        }

        throw GitServiceError.unsafeReviewSource(
            "workspace remained unstable during Last Agent Turn finalization"
        )
    }

    private func agentTurnCheckoutIdentityWithoutGate(
        _ baseline: AgentTurnReviewBaseline
    ) async throws -> AgentTurnCheckoutIdentity {
        let current = try await captureAgentTurnReviewBaselineWithoutGate(
            runID: baseline.runID,
            sessionID: baseline.sessionID
        )
        return AgentTurnCheckoutIdentity(
            headRevision: current.startRevision,
            files: current.files.map { file in
                AgentTurnReviewFileIdentity(
                    path: file.path,
                    existed: file.existed,
                    byteCount: file.byteCount,
                    permissions: file.permissions,
                    sha256: file.sha256
                )
            }
        )
    }

    /// Reads only the frozen payload. The current checkout is consulted solely
    /// for its root identity, never for file content, so post-run edits cannot
    /// change an already finalized Last Agent Turn.
    func reviewSource(from snapshot: AgentTurnReviewSnapshot) throws -> GitCommandResult {
        try validateAgentTurnReviewSnapshot(snapshot)
        return GitCommandResult(
            output: snapshot.source,
            exitCode: 0,
            truncated: snapshot.truncated,
            artifactPath: nil,
            change: nil
        )
    }

    func add(paths: [String], taskID: UUID) async throws -> GitCommandResult {
        guard paths.count <= 500 else { throw GitServiceError.tooManyChangedFiles(500) }
        var relativePaths: [String] = []
        for path in paths {
            let url = try validator.validate(path: path, access: .write, allowNonexistentLeaf: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true {
                    throw GitServiceError.directoryStagingRequiresFiles(path)
                }
                if values.isSymbolicLink == true { throw WorkspaceSecurityError.symbolicLinkMutation(path) }
            }
            let relative = validator.relativePath(for: url)
            relativePaths.append(relative)
        }
        try await ensureNoContentFilters(paths: relativePaths)
        let trackedPaths = [".git/index"]
        return try await mutate(
            ["add", "--"] + relativePaths,
            snapshotPaths: trackedPaths,
            taskID: taskID
        )
    }

    func restore(
        paths: [String],
        staged: Bool = false,
        source: String? = nil,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let relativePaths = try paths.map { try validatedRelativePath($0, access: .write) }
        try await ensureNoContentFilters(paths: relativePaths)
        var arguments = ["restore"]
        if staged { arguments.append("--staged") }
        if let source { arguments += ["--source", try validatedReference(source)] }
        arguments += ["--"] + relativePaths
        var snapshots = relativePaths
        if staged { snapshots.append(".git/index") }
        return try await mutate(arguments, snapshotPaths: snapshots, taskID: taskID)
    }

    func checkout(
        reference: String,
        paths: [String] = [],
        taskID: UUID
    ) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        if !paths.isEmpty {
            let relativePaths = try paths.map { try validatedRelativePath($0, access: .write) }
            try await ensureNoContentFilters(paths: relativePaths)
            return try await mutate(
                ["checkout", reference, "--"] + relativePaths,
                snapshotPaths: relativePaths + [".git/index"],
                taskID: taskID
            )
        }

        // A normal newline-rendered Git path list is ambiguous for legal file
        // names containing newlines and the terminal summary can be truncated.
        // Preserve Git's NUL-delimited bytes through a base64 envelope, then
        // refuse the checkout unless the complete bounded inventory is present.
        let affectedData = try await rawGitBytes([
            "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z",
            "--diff-filter=ACDMRTUXB", "HEAD", reference, "--"
        ], maximumDecodedBytes: 8 * 1_024 * 1_024)
        let affected = try decodeNULTerminatedStrings(affectedData, maximumCount: 2_000)
        for path in affected {
            _ = try validator.validate(path: path, access: .write, allowNonexistentLeaf: true)
        }
        try await ensureNoContentFilters(paths: affected)
        return try await mutate(
            ["checkout", reference],
            snapshotPaths: affected + [".git/HEAD", ".git/index"],
            taskID: taskID
        )
    }

    func commit(message: String, taskID: UUID) async throws -> GitCommandResult {
        let branch = try await raw(["branch", "--show-current"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshots = [".git/HEAD", ".git/index"]
        if !branch.isEmpty { snapshots.append(".git/refs/heads/\(branch)") }
        return try await mutate(
            ["commit", "--no-gpg-sign", "--message", message],
            snapshotPaths: snapshots,
            taskID: taskID
        )
    }

    func createBranch(
        name: String,
        startPoint: String? = nil,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let name = try validatedBranchName(name)
        var arguments = ["branch", name]
        if let startPoint { arguments.append(try validatedReference(startPoint)) }
        return try await mutate(
            arguments,
            snapshotPaths: [".git/refs/heads/\(name)", ".git/packed-refs"],
            taskID: taskID
        )
    }

    func fetch(
        remote: String,
        branch: String? = nil,
        taskID: UUID,
        providerConfiguration: PullRequestProviderConfiguration? = nil
    ) async throws -> GitCommandResult {
        let remote = try validatedRemoteName(remote)
        let remoteURL = try await validateConfiguredRemote(
            remote,
            direction: .fetch,
            access: .read
        )
        let authentication = try providerConfiguration.flatMap {
            try remoteCredentialResolver.resolve(remoteURL, $0)
        }
        var arguments = ["fetch", "--no-tags", "--no-recurse-submodules", remote]
        if let branch {
            arguments.append("refs/heads/\(try validatedBranchName(branch))")
        }
        return try await mutate(
            arguments,
            snapshotPaths: fetchSnapshotPaths(remote: remote),
            taskID: taskID,
            allowsNetwork: true,
            authentication: authentication
        )
    }

    func pull(
        remote: String,
        branch: String,
        strategy: GitPullStrategy = .fastForwardOnly,
        taskID: UUID,
        providerConfiguration: PullRequestProviderConfiguration? = nil
    ) async throws -> GitCommandResult {
        let remote = try validatedRemoteName(remote)
        let branch = try validatedBranchName(branch)
        let fetched = try await fetch(
            remote: remote,
            branch: branch,
            taskID: taskID,
            providerConfiguration: providerConfiguration
        )
        let integrated: GitCommandResult
        switch strategy {
        case .fastForwardOnly:
            integrated = try await merge(
                reference: "FETCH_HEAD",
                strategy: .fastForwardOnly,
                taskID: taskID
            )
        case .merge:
            integrated = try await merge(
                reference: "FETCH_HEAD",
                strategy: .merge,
                taskID: taskID
            )
        case .rebase:
            integrated = try await rebase(onto: "FETCH_HEAD", taskID: taskID)
        }
        let output = [fetched.output, integrated.output]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return GitCommandResult(
            output: output,
            exitCode: integrated.exitCode,
            truncated: fetched.truncated || integrated.truncated,
            artifactPath: integrated.artifactPath ?? fetched.artifactPath,
            change: integrated.change
        )
    }

    func push(
        remote: String,
        branch: String? = nil,
        destinationBranch: String? = nil,
        setUpstream: Bool = false,
        forceWithLease: Bool = false,
        taskID: UUID,
        providerConfiguration: PullRequestProviderConfiguration? = nil
    ) async throws -> GitCommandResult {
        let remote = try validatedRemoteName(remote)
        let remoteURL = try await validateConfiguredRemote(
            remote,
            direction: .push,
            access: .write
        )
        let authentication = try providerConfiguration.flatMap {
            try remoteCredentialResolver.resolve(remoteURL, $0)
        }
        let source: String
        if let branch {
            source = try validatedBranchName(branch)
        } else {
            source = try await currentLocalBranchName()
        }
        let destination = try destinationBranch.map(validatedBranchName) ?? source
        var arguments = ["push", "--porcelain", "--recurse-submodules=no"]
        if setUpstream { arguments.append("--set-upstream") }
        if forceWithLease {
            // Plain --force is intentionally absent from this closed API.
            arguments.append("--force-with-lease=refs/heads/\(destination)")
        }
        arguments += [
            remote,
            "refs/heads/\(source):refs/heads/\(destination)"
        ]

        var result: GitCommandResult
        if setUpstream {
            result = try await mutate(
                arguments,
                snapshotPaths: [".git/config"],
                taskID: taskID,
                allowsNetwork: true,
                authentication: authentication
            )
        } else {
            result = try await executeWithoutSnapshot(
                arguments,
                allowsNetwork: true,
                metadataWrite: true,
                workspaceWrite: true,
                authentication: authentication
            )
        }
        let warning = "Remote branch changes are not covered by workspace Undo."
        result.output = result.output.isEmpty ? warning : result.output + "\n" + warning
        return result
    }

    func switchBranch(name: String, taskID: UUID) async throws -> GitCommandResult {
        let name = try validatedBranchName(name)
        let affected = try await affectedPaths(between: "HEAD", and: name)
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["switch", name],
            snapshotPaths: affected + (try await currentBranchMetadataSnapshotPaths()),
            taskID: taskID
        )
    }

    func deleteBranch(
        name: String,
        force: Bool = false,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let name = try validatedBranchName(name)
        let arguments = force
            ? ["branch", "--delete", "--force", name]
            : ["branch", "--delete", name]
        return try await mutate(
            arguments,
            snapshotPaths: [".git/refs/heads/\(name)", ".git/packed-refs"],
            taskID: taskID
        )
    }

    /// Move the current checked-out ref, index, and tracked worktree to one
    /// validated revision. Unlike the more permissive terminal command, this
    /// host-owned surface first proves a complete, bounded set of workspace
    /// paths (including untracked/ignored obstructions that Git would remove)
    /// and refuses layouts where metadata cannot participate in Undo.
    func hardReset(reference: String, taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let reference = try validatedReference(reference)
        try requireNoOperationState(for: "hard reset")
        guard repositoryLayout.supportsWorkspaceMetadataSnapshots else {
            throw GitServiceError.metadataSnapshotsUnavailable
        }
        let affected = try await hardResetAffectedPaths(reference: reference)
        try await ensureNoContentFilters(paths: affected)
        return try await mutate(
            ["reset", "--hard", reference],
            snapshotPaths: affected + (try await currentBranchMetadataSnapshotPaths()) + [
                ".git/ORIG_HEAD"
            ],
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func merge(
        reference: String,
        strategy: GitMergeStrategy = .merge,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        let affected = try await affectedPaths(between: "HEAD", and: reference)
        try await ensureSafeMutationAttributes(paths: affected)
        var arguments = ["merge", "--no-edit", "--no-gpg-sign"]
        if strategy == .fastForwardOnly { arguments.append("--ff-only") }
        arguments.append(reference)
        return try await mutate(
            arguments,
            snapshotPaths: affected + (try await currentBranchMetadataSnapshotPaths()) + [
                ".git/MERGE_HEAD", ".git/MERGE_MSG", ".git/MERGE_MODE",
                ".git/AUTO_MERGE", ".git/ORIG_HEAD"
            ],
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func mergeContinue(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.merge)
        let affected = try await workingTreeDifferencePaths(relativeTo: "HEAD")
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["merge", "--continue"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .merge)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func mergeAbort(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.merge)
        let affected = try await workingTreeDifferencePaths(relativeTo: "ORIG_HEAD")
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["merge", "--abort"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .merge)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func rebase(onto reference: String, taskID: UUID) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        let affected = try await rebaseAffectedPaths(onto: reference)
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["rebase", "--no-autostash", reference],
            snapshotPaths: affected + (try await currentBranchMetadataSnapshotPaths()) + [
                ".git/rebase-apply", ".git/rebase-merge", ".git/ORIG_HEAD"
            ],
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func rebaseContinue(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.rebase)
        let affected = try await rebaseContinuationAffectedPaths()
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["rebase", "--continue"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .rebase)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func rebaseAbort(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.rebase)
        let affected = try await workingTreeDifferencePaths(relativeTo: "ORIG_HEAD")
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["rebase", "--abort"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .rebase)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func cherryPick(reference: String, taskID: UUID) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        let affected = try await changedPaths([
            "diff-tree", "--root", "--no-commit-id", "--name-only", "-z", "-r", reference
        ])
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["cherry-pick", "--no-edit", reference],
            snapshotPaths: affected + (try await currentBranchMetadataSnapshotPaths()) + [
                ".git/CHERRY_PICK_HEAD", ".git/MERGE_MSG", ".git/ORIG_HEAD"
            ],
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func cherryPickContinue(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.cherryPick)
        let affected = try await workingTreeDifferencePaths(relativeTo: "HEAD")
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["cherry-pick", "--continue"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .cherryPick)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func cherryPickAbort(taskID: UUID) async throws -> GitCommandResult {
        try Task.checkCancellation()
        try requireOperationState(.cherryPick)
        // This closed API starts exactly one commit. A conflicted cherry-pick
        // leaves HEAD at the pre-operation commit and does not necessarily
        // create ORIG_HEAD, so HEAD is the authoritative abort baseline.
        let affected = try await workingTreeDifferencePaths(relativeTo: "HEAD")
        try await ensureSafeMutationAttributes(paths: affected)
        return try await mutate(
            ["cherry-pick", "--abort"],
            snapshotPaths: affected + (try await lifecycleMetadataSnapshotPaths(for: .cherryPick)),
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func stashPush(
        message: String? = nil,
        includeUntracked: Bool = false,
        keepIndex: Bool = false,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let affected = try await changedPaths([
            "ls-files", "-m", "-d", "-o", "--exclude-standard", "-z", "--"
        ])
        try await ensureSafeMutationAttributes(paths: affected)
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if keepIndex { arguments.append("--keep-index") }
        if let message {
            arguments += ["--message", try validatedMessage(message)]
        }
        arguments.append("--")
        return try await mutate(
            arguments,
            snapshotPaths: affected + [
                ".git/index", ".git/refs/stash", ".git/logs/refs/stash"
            ],
            taskID: taskID
        )
    }

    func stashApply(
        reference: String = "stash@{0}",
        reinstateIndex: Bool = false,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        let affected = try await affectedPaths(between: "\(reference)^1", and: reference)
        try await ensureSafeMutationAttributes(paths: affected)
        var arguments = ["stash", "apply"]
        if reinstateIndex { arguments.append("--index") }
        arguments.append(reference)
        return try await mutate(
            arguments,
            snapshotPaths: affected + [".git/index"],
            taskID: taskID,
            recordFailedOutcome: true
        )
    }

    func stashDrop(
        reference: String = "stash@{0}",
        taskID: UUID
    ) async throws -> GitCommandResult {
        let reference = try validatedReference(reference)
        return try await mutate(
            ["stash", "drop", reference],
            snapshotPaths: [".git/refs/stash", ".git/logs/refs/stash"],
            taskID: taskID
        )
    }

    func createTag(
        name: String,
        target: String = "HEAD",
        message: String? = nil,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let name = try validatedTagName(name)
        let target = try validatedReference(target)
        var arguments = ["tag", "--no-sign"]
        if let message {
            arguments += ["--annotate", "--message", try validatedMessage(message)]
        }
        arguments += [name, target]
        return try await mutate(
            arguments,
            snapshotPaths: [".git/refs/tags/\(name)", ".git/packed-refs"],
            taskID: taskID
        )
    }

    func deleteTag(name: String, taskID: UUID) async throws -> GitCommandResult {
        let name = try validatedTagName(name)
        return try await mutate(
            ["tag", "--delete", name],
            snapshotPaths: [".git/refs/tags/\(name)", ".git/packed-refs"],
            taskID: taskID
        )
    }

    func addRemote(name: String, url: String, taskID: UUID) async throws -> GitCommandResult {
        let name = try validatedRemoteName(name)
        _ = try validatedRemoteURL(url, access: .read)
        return try await mutate(
            ["remote", "add", name, url],
            snapshotPaths: [".git/config"],
            taskID: taskID
        )
    }

    func removeRemote(name: String, taskID: UUID) async throws -> GitCommandResult {
        let name = try validatedRemoteName(name)
        return try await mutate(
            ["remote", "remove", name],
            snapshotPaths: [
                ".git/config", ".git/refs/remotes/\(name)", ".git/packed-refs"
            ],
            taskID: taskID
        )
    }

    /// Checks and applies one core-validated Review file/hunk patch while this
    /// GitService has exclusive command access. ReviewPatchBuilder already
    /// materializes reverse intent into the patch bytes, so no model-controlled
    /// option is derived from `direction` here.
    func applyReviewPatch(
        _ payload: ReviewPatchPayload,
        target: GitReviewPatchTarget,
        taskID: UUID
    ) async throws -> GitCommandResult {
        let validated = try validatedReviewPatch(payload)
        try await ensureNoContentFilters(paths: validated.paths)

        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }

        var baseArguments = ["apply", "--whitespace=nowarn"]
        if target == .index { baseArguments.append("--cached") }
        // Project-level artifacts intentionally sit outside an arbitrary
        // selected workspace and therefore outside its Seatbelt profile. Feed
        // the already-bounded patch through stdin instead of weakening that
        // boundary or leaving a transient file in the user's repository.
        let checkArguments = baseArguments + ["--check", "-"]
        let applyArguments = baseArguments + ["-"]
        let metadataWrite = target == .index
        let workspaceWrite = target == .worktree

        if target == .index, !repositoryLayout.supportsWorkspaceMetadataSnapshots {
            let checked = try await rawWithoutGate(
                checkArguments,
                metadataWrite: false,
                workspaceWrite: false,
                standardInput: validated.data
            )
            try ensureSuccess(checked, arguments: checkArguments)
            let applied = try await rawWithoutGate(
                applyArguments,
                metadataWrite: true,
                workspaceWrite: false,
                standardInput: validated.data
            )
            try ensureSuccess(applied, arguments: applyArguments)
            let combined = applied.stdout
                + (applied.stderr.isEmpty ? "" : "\n" + applied.stderr)
            let warning = "Undo unavailable for this linked-worktree index mutation."
            return GitCommandResult(
                output: combined.isEmpty ? warning : combined + "\n" + warning,
                exitCode: applied.exitCode,
                truncated: applied.truncated,
                artifactPath: applied.stdoutArtifactPath ?? applied.stderrArtifactPath,
                change: nil
            )
        }

        let snapshotPaths = target == .index ? [".git/index"] : validated.paths
        let transaction = try await changes.beginChange(
            paths: snapshotPaths,
            operation: .git,
            taskID: taskID
        )
        do {
            let checked = try await rawWithoutGate(
                checkArguments,
                metadataWrite: false,
                workspaceWrite: false,
                standardInput: validated.data
            )
            try ensureSuccess(checked, arguments: checkArguments)
            let applied = try await rawWithoutGate(
                applyArguments,
                metadataWrite: metadataWrite,
                workspaceWrite: workspaceWrite,
                standardInput: validated.data
            )
            try ensureSuccess(applied, arguments: applyArguments)
            let change = try await changes.commitChange(transaction)
            let combined = applied.stdout
                + (applied.stderr.isEmpty ? "" : "\n" + applied.stderr)
            let summary = "Applied \(payload.direction.rawValue) Review patch to \(target.rawValue)."
            return GitCommandResult(
                output: combined.isEmpty ? summary : combined + "\n" + summary,
                exitCode: applied.exitCode,
                truncated: applied.truncated,
                artifactPath: applied.stdoutArtifactPath ?? applied.stderrArtifactPath,
                change: change
            )
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    /// Applies a file-level action when Review intentionally omitted textual
    /// patch bytes (binary, large, or malformed/oversized line fallback).
    /// The full current source is rebuilt while the Git command gate is held;
    /// both the stable file ID and content-bearing fingerprint must still
    /// match what the user saw. Hunk identities are never accepted here.
    func applyReviewFileMutation(
        _ mutation: GitReviewFileMutation,
        source: ReviewSource,
        path: String,
        selection: ReviewPatchSelection,
        taskID: UUID
    ) async throws -> GitCommandResult {
        guard selection.hunkID == nil,
              selection.hunkFingerprint == nil,
              Self.isReviewFingerprint(selection.fileID),
              Self.isReviewFingerprint(selection.fileFingerprint) else {
            throw GitServiceError.unsafeReviewPatch(
                "file fallback actions require one well-formed file identity"
            )
        }
        switch (mutation, source) {
        case (.stage, .unstaged), (.revert, .unstaged), (.unstage, .staged):
            break
        default:
            throw GitServiceError.unsafeReviewPatch(
                "the requested file action does not match its Review source"
            )
        }
        guard repositoryLayout.supportsWorkspaceMetadataSnapshots || mutation == .revert else {
            throw GitServiceError.metadataSnapshotsUnavailable
        }

        await beginExclusiveReviewPatch()
        defer { endExclusiveReviewPatch() }

        let current = try await reviewSourceWithoutGate(for: source)
        let document: ReviewDocument
        do {
            document = try ReviewDiffParser().parse(current.output, source: source)
        } catch {
            throw GitServiceError.unsafeReviewSource(
                "the current file identity cannot be parsed safely"
            )
        }
        guard let file = document.files.first(where: { $0.id == selection.fileID }),
              file.fingerprint == selection.fileFingerprint,
              file.displayPath == path,
              file.fallback != nil else {
            throw GitServiceError.unsafeReviewPatch(
                "the file changed after it was displayed; refresh Review"
            )
        }
        let relative = try validatedReviewRegularFile(path)
        try await ensureNoContentFilters(paths: [relative], gateAlreadyHeld: true)

        let snapshotPaths = mutation == .revert ? [relative] : [".git/index"]
        let transaction = try await changes.beginChange(
            paths: snapshotPaths,
            operation: .git,
            taskID: taskID
        )
        do {
            // Snapshot creation is an actor hop and may read several files. Rebuild
            // the source once more immediately before mutation so an external
            // writer cannot silently replace the displayed bytes during that gap.
            let latest = try await reviewSourceWithoutGate(for: source)
            let latestDocument = try ReviewDiffParser().parse(latest.output, source: source)
            guard let latestFile = latestDocument.files.first(where: {
                $0.id == selection.fileID
            }),
            latestFile.fingerprint == selection.fileFingerprint,
            latestFile.displayPath == relative,
            latestFile.fallback != nil else {
                throw GitServiceError.unsafeReviewPatch(
                    "the file changed while its Undo snapshot was being prepared"
                )
            }
            let result: TerminalCommandResult?
            if mutation == .revert, file.isUntracked == true {
                try secureIO.remove(path: relative)
                result = nil
            } else {
                let arguments: [String]
                let metadataWrite: Bool
                let workspaceWrite: Bool
                switch mutation {
                case .stage:
                    arguments = ["add", "--", relative]
                    metadataWrite = true
                    workspaceWrite = false
                case .unstage:
                    arguments = ["restore", "--staged", "--", relative]
                    metadataWrite = true
                    workspaceWrite = false
                case .revert:
                    arguments = ["restore", "--worktree", "--", relative]
                    metadataWrite = false
                    workspaceWrite = true
                }
                let executed = try await rawWithoutGate(
                    arguments,
                    metadataWrite: metadataWrite,
                    workspaceWrite: workspaceWrite
                )
                try ensureSuccess(executed, arguments: arguments)
                result = executed
            }
            let change = try await changes.commitChange(transaction)
            let commandOutput = result.map {
                $0.stdout + ($0.stderr.isEmpty ? "" : "\n" + $0.stderr)
            } ?? ""
            let summary = "Applied Review \(mutation.rawValue) to \(relative)."
            return GitCommandResult(
                output: commandOutput.isEmpty ? summary : commandOutput + "\n" + summary,
                exitCode: result?.exitCode ?? 0,
                truncated: result?.truncated ?? false,
                artifactPath: result?.stdoutArtifactPath ?? result?.stderrArtifactPath,
                change: change
            )
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    private func reviewSourceWithoutGate(
        for source: ReviewSource
    ) async throws -> GitCommandResult {
        let arguments: [String]
        switch source {
        case .unstaged:
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                "--unified=3", "--"
            ]
        case .staged:
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                "--unified=3", "--cached", "--"
            ]
        case .commit(let rawRevision):
            let revision = try validatedReference(rawRevision)
            arguments = [
                "show", "--no-ext-diff", "--no-textconv", "--no-color",
                "--format=", revision, "--"
            ]
        case .branch(let rawBase, let rawHead):
            let base = try validatedReference(rawBase)
            let head = try validatedReference(rawHead)
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                "--unified=3", "\(base)...\(head)", "--"
            ]
        case .lastAgentTurn:
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn must be loaded from durable Task changes"
            )
        }

        let trackedResult = try await rawWithoutGate(arguments)
        defer { removeTransientArtifacts(from: trackedResult) }
        try ensureSuccess(trackedResult, arguments: arguments)
        let outputAndFallback: (String, Bool)
        do {
            let complete = try completeReviewStdout(trackedResult)
            if Self.reviewSourceTransportWasAltered(complete) {
                outputAndFallback = (
                    try await trackedReviewFallbacksWithoutGate(for: source),
                    true
                )
            } else {
                outputAndFallback = (complete, false)
            }
        } catch {
            outputAndFallback = (try await trackedReviewFallbacksWithoutGate(for: source), true)
        }
        var output = outputAndFallback.0
        var semanticallyTruncated = outputAndFallback.1
            || Self.reviewSourceContainsOmission(output)

        if source == .unstaged {
            let untracked = try await untrackedReviewDiffsWithoutGate()
            if !untracked.text.isEmpty {
                let separator = output.isEmpty || output.hasSuffix("\n") ? "" : "\n"
                let additionalBytes = separator.utf8.count + untracked.text.utf8.count
                guard output.utf8.count + additionalBytes <= Self.maximumReviewSourceBytes else {
                    throw GitServiceError.unsafeReviewSource(
                        "tracked and untracked diffs exceed the 16 MiB source limit"
                    )
                }
                output += separator + untracked.text
            }
            semanticallyTruncated = semanticallyTruncated || untracked.truncated
        }

        // Parse once at the trust boundary. This simultaneously validates all
        // Git-quoted paths and enforces the shared document/file/count limits.
        if !output.isEmpty {
            do {
                let document = try ReviewDiffParser().parse(output, source: source)
                if document.files.contains(where: { $0.fallback != nil }) {
                    semanticallyTruncated = true
                }
            } catch {
                throw GitServiceError.unsafeReviewSource(error.localizedDescription)
            }
        }
        return GitCommandResult(
            output: output,
            exitCode: 0,
            truncated: semanticallyTruncated,
            artifactPath: nil,
            change: nil
        )
    }

    /// If a tracked diff cannot fit the complete 16 MiB Review document, retain
    /// every changed path as a stable file-level fallback instead of dropping
    /// the source or presenting Terminal head/tail output as complete.
    private func trackedReviewFallbacksWithoutGate(
        for source: ReviewSource
    ) async throws -> String {
        let arguments: [String]
        switch source {
        case .unstaged:
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                "--raw", "-z", "--no-abbrev", "--"
            ]
        case .staged:
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                "--raw", "-z", "--no-abbrev", "--cached", "--"
            ]
        case .commit(let rawRevision):
            let revision = try validatedReference(rawRevision)
            arguments = [
                "diff-tree", "--root", "--no-commit-id", "-r", "--no-renames",
                "--raw", "-z", "--no-abbrev", revision, "--"
            ]
        case .branch(let rawBase, let rawHead):
            let base = try validatedReference(rawBase)
            let head = try validatedReference(rawHead)
            arguments = [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                "--raw", "-z", "--no-abbrev", "\(base)...\(head)", "--"
            ]
        case .lastAgentTurn:
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn uses its durable baseline fallback"
            )
        }
        let raw = try await rawGitBytesWithoutGate(
            arguments,
            maximumDecodedBytes: 8 * 1_024 * 1_024
        )
        let entries = try parseTrackedReviewFallbackEntries(raw)
        guard !entries.isEmpty else {
            throw GitServiceError.unsafeReviewSource(
                "oversized tracked diff had no bounded file inventory"
            )
        }

        var identityBytes: Int64 = 0
        var rendered: [String] = []
        rendered.reserveCapacity(entries.count)
        for entry in entries {
            try Task.checkCancellation()
            var identity = "old=\(entry.oldObjectID) new=\(entry.newObjectID)"
            if source == .unstaged, entry.status != "D" {
                guard try secureIO.exists(path: entry.path) else {
                    throw GitServiceError.unsafeReviewSource(
                        "tracked path \(entry.path) disappeared during fallback capture"
                    )
                }
                let metadata = try secureIO.metadata(path: entry.path)
                guard metadata.kind == .regularFile,
                      metadata.byteCount >= 0,
                      identityBytes + metadata.byteCount
                        <= Int64(Self.maximumReviewIdentityBytes) else {
                    throw GitServiceError.unsafeReviewSource(
                        "tracked fallback identities exceed the 256 MiB source limit"
                    )
                }
                let digest = try secureIO.sha256RegularFile(
                    path: entry.path,
                    maximumBytes: Self.maximumReviewIdentityBytes - Int(identityBytes)
                )
                guard digest.metadata.byteCount == metadata.byteCount else {
                    throw GitServiceError.unsafeReviewSource(
                        "tracked path \(entry.path) changed during fallback capture"
                    )
                }
                identityBytes += digest.metadata.byteCount
                identity += " worktree-sha256=\(digest.sha256)"
            }
            rendered.append(Self.trackedReviewFallback(entry, identity: identity))
        }
        let output = rendered.joined(separator: "\n")
        guard output.utf8.count <= Self.maximumReviewSourceBytes else {
            throw GitServiceError.unsafeReviewSource(
                "tracked fallback inventory exceeds the 16 MiB source limit"
            )
        }
        return output
    }

    private func parseTrackedReviewFallbackEntries(
        _ data: Data
    ) throws -> [TrackedReviewFallbackEntry] {
        guard !data.isEmpty, data.last == 0 else {
            throw GitServiceError.unsafeReviewSource(
                "tracked fallback inventory is empty or unterminated"
            )
        }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        fields.removeLast()
        guard fields.count.isMultiple(of: 2),
              fields.count / 2 <= Self.maximumReviewFiles else {
            throw GitServiceError.unsafeReviewSource(
                "tracked fallback inventory is ambiguous or oversized"
            )
        }
        var result: [TrackedReviewFallbackEntry] = []
        result.reserveCapacity(fields.count / 2)
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let metadata = String(data: Data(fields[index]), encoding: .utf8),
                  let rawPath = String(data: Data(fields[index + 1]), encoding: .utf8),
                  metadata.hasPrefix(":"),
                  !rawPath.isEmpty else {
                throw GitServiceError.unsafeReviewSource(
                    "tracked fallback inventory is not valid UTF-8"
                )
            }
            let parts = metadata.dropFirst().split(separator: " ")
            guard parts.count == 5,
                  parts[0].range(of: #"^[0-7]{6}$"#, options: .regularExpression) != nil,
                  parts[1].range(of: #"^[0-7]{6}$"#, options: .regularExpression) != nil,
                  parts[2].range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil,
                  parts[3].range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil,
                  parts[4].count == 1,
                  let status = parts[4].first,
                  "ACDMTUXB".contains(status) else {
                throw GitServiceError.unsafeReviewSource(
                    "tracked fallback metadata is malformed"
                )
            }
            let path = try validatedAgentTurnReviewPath(rawPath, access: .read)
            result.append(TrackedReviewFallbackEntry(
                path: path,
                oldMode: String(parts[0]),
                newMode: String(parts[1]),
                oldObjectID: String(parts[2]).lowercased(),
                newObjectID: String(parts[3]).lowercased(),
                status: status
            ))
        }
        return result
    }

    private static func trackedReviewFallback(
        _ entry: TrackedReviewFallbackEntry,
        identity: String
    ) -> String {
        let old = reviewGitToken("a/\(entry.path)")
        let new = reviewGitToken("b/\(entry.path)")
        var output = "diff --git \(old) \(new)\n"
        if entry.status == "A" {
            output += "new file mode \(entry.newMode)\n"
        } else if entry.status == "D" {
            output += "deleted file mode \(entry.oldMode)\n"
        } else if entry.oldMode != entry.newMode,
                  entry.oldMode != "000000", entry.newMode != "000000" {
            output += "old mode \(entry.oldMode)\nnew mode \(entry.newMode)\n"
        }
        output += "LumaChat review tracked file identity \(identity) status=\(entry.status)\n"
        output += "--- \(entry.status == "A" ? "/dev/null" : old)\n"
        output += "+++ \(entry.status == "D" ? "/dev/null" : new)\n"
        output += "Files \(entry.status == "A" ? "/dev/null" : old) and "
            + "\(entry.status == "D" ? "/dev/null" : new) differ "
            + "(diff omitted: tracked Review source exceeds the complete document limit).\n"
        return output
    }

    private func completeReviewStdout(_ result: TerminalCommandResult) throws -> String {
        guard result.stderrArtifactPath == nil else {
            throw GitServiceError.unsafeReviewSource(
                "Git produced oversized diagnostic output"
            )
        }
        let data: Data
        do {
            data = try completeStdout(
                result,
                maximumBytes: Self.maximumReviewSourceBytes
            )
        } catch {
            throw GitServiceError.unsafeReviewSource(
                "complete stdout is unavailable or exceeds 16 MiB"
            )
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw GitServiceError.unsafeReviewSource("Git stdout is not valid UTF-8")
        }
        return output
    }

    private func untrackedReviewDiffsWithoutGate() async throws -> (
        text: String,
        truncated: Bool
    ) {
        let inventory = try await rawGitBytesWithoutGate(
            ["ls-files", "--others", "--exclude-standard", "-z", "--"],
            maximumDecodedBytes: 8 * 1_024 * 1_024
        )
        let paths = try decodeNULTerminatedStrings(
            inventory,
            maximumCount: Self.maximumReviewFiles
        )
        var rendered: [String] = []
        rendered.reserveCapacity(paths.count)
        var totalBytes = 0
        var totalIdentityBytes: Int64 = 0
        var truncated = false

        for rawPath in paths {
            try Task.checkCancellation()
            let validated = try validatedUntrackedReviewPath(rawPath)
            let path = validated.path
            guard validated.metadata.byteCount >= 0,
                  totalIdentityBytes + validated.metadata.byteCount
                    <= Int64(Self.maximumReviewIdentityBytes) else {
                throw GitServiceError.unsafeReviewSource(
                    "untracked file identities exceed the 256 MiB source limit"
                )
            }
            let remainingIdentityBytes = Self.maximumReviewIdentityBytes - Int(totalIdentityBytes)
            let digest: String
            let capturedMetadata: SecureWorkspaceMetadata
            if validated.metadata.byteCount <= Int64(Self.maximumReviewFileBytes) {
                let read = try secureIO.readRegularFile(
                    path: path,
                    maximumBytes: remainingIdentityBytes
                )
                guard !read.truncated,
                      read.metadata.byteCount == validated.metadata.byteCount else {
                    throw GitServiceError.unsafeReviewSource(
                        "untracked file \(path) changed during Review capture"
                    )
                }
                digest = Self.sha256(read.data)
                capturedMetadata = read.metadata
            } else {
                let streamed = try secureIO.sha256RegularFile(
                    path: path,
                    maximumBytes: remainingIdentityBytes
                )
                guard streamed.metadata.byteCount == validated.metadata.byteCount else {
                    throw GitServiceError.unsafeReviewSource(
                        "untracked file \(path) changed during Review capture"
                    )
                }
                digest = streamed.sha256
                capturedMetadata = streamed.metadata
            }
            totalIdentityBytes += capturedMetadata.byteCount
            let fileDiff: String
            if capturedMetadata.byteCount > Int64(Self.maximumReviewFileBytes) {
                fileDiff = Self.largeUntrackedFallback(
                    path: path,
                    byteCount: Int(capturedMetadata.byteCount),
                    digest: digest,
                    executable: capturedMetadata.permissions & 0o111 != 0
                )
                truncated = true
            } else {
                let arguments = [
                    "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                    "--no-color", "--unified=3", "--", "/dev/null", path
                ]
                let result = try await rawWithoutGate(arguments)
                defer { removeTransientArtifacts(from: result) }
                guard !result.timedOut, result.exitCode == 0 || result.exitCode == 1 else {
                    let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
                    throw GitServiceError.commandFailed(
                        command: "git diff --no-index",
                        exitCode: result.exitCode,
                        output: diagnostic
                    )
                }
                let raw = try completeReviewStdout(result)
                if raw.isEmpty {
                    fileDiff = Self.emptyUntrackedFallback(
                        path: path,
                        digest: digest,
                        executable: capturedMetadata.permissions & 0o111 != 0
                    )
                    truncated = true
                } else {
                    fileDiff = try Self.insertingUntrackedIdentity(
                        digest,
                        into: raw
                    )
                    if Self.reviewSourceContainsOmission(fileDiff) { truncated = true }
                }
            }
            let separatorBytes = rendered.isEmpty ? 0 : 1
            let bytes = fileDiff.utf8.count
            guard totalBytes + separatorBytes + bytes <= Self.maximumReviewSourceBytes else {
                throw GitServiceError.unsafeReviewSource(
                    "untracked diffs exceed the 16 MiB source limit"
                )
            }
            rendered.append(fileDiff)
            totalBytes += separatorBytes + bytes
        }
        return (rendered.joined(separator: "\n"), truncated)
    }

    private func validatedUntrackedReviewPath(
        _ rawPath: String
    ) throws -> (path: String, metadata: SecureWorkspaceMetadata) {
        guard !rawPath.isEmpty,
              rawPath.utf8.count <= 16 * 1_024,
              !rawPath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw GitServiceError.unsafeReviewSource(
                "an untracked path is empty, oversized, or contains controls"
            )
        }
        let relative = try validator.secureRelativePath(for: rawPath, access: .read)
        let metadata: SecureWorkspaceMetadata
        do {
            metadata = try secureIO.metadata(path: relative)
        } catch {
            throw GitServiceError.unsafeReviewSource(
                "untracked path \(rawPath) is symbolic or cannot be opened safely"
            )
        }
        guard metadata.kind == .regularFile else {
            throw GitServiceError.unsafeReviewSource(
                "untracked path \(rawPath) is not a regular file"
            )
        }
        return (relative, metadata)
    }

    private func validatedReviewRegularFile(_ rawPath: String) throws -> String {
        guard !rawPath.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw GitServiceError.unsafeReviewPatch("file path contains controls")
        }
        let relative = try validator.secureRelativePath(for: rawPath, access: .write)
        if try secureIO.exists(path: relative) {
            let metadata = try secureIO.metadata(path: relative)
            guard metadata.kind == .regularFile else {
                throw GitServiceError.unsafeReviewPatch("file is not a regular file")
            }
        }
        return relative
    }

    private func currentHeadRevisionWithoutGate() async throws -> String? {
        let arguments = ["rev-parse", "--verify", "HEAD^{commit}"]
        let result = try await rawWithoutGate(arguments)
        defer { removeTransientArtifacts(from: result) }
        guard !result.timedOut else {
            throw GitServiceError.commandFailed(
                command: "git rev-parse --verify HEAD^{commit}",
                exitCode: result.exitCode,
                output: result.stderr
            )
        }
        guard result.exitCode == 0 else { return nil }
        let lines = result.stdout.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count == 1,
              lines[0].range(
                of: #"^[0-9a-fA-F]{40,64}$"#,
                options: .regularExpression
              ) != nil else {
            throw GitServiceError.unsafeReviewSource("HEAD object identity is malformed")
        }
        return lines[0].lowercased()
    }

    private func validateAgentTurnReviewBaseline(
        _ baseline: AgentTurnReviewBaseline
    ) throws {
        try validateLiveAgentTurnReviewRoot()
        let identity = validator.secureRootIdentity
        guard baseline.version == AgentTurnReviewBaseline.currentVersion,
              baseline.workspaceID == validator.workspace.id,
              baseline.canonicalRootPath == validator.secureRootPath,
              baseline.rootDevice == identity.device,
              baseline.rootInode == identity.inode,
              baseline.files.count <= Self.maximumReviewFiles,
              baseline.startRevision.map({ revision in
                  revision.range(
                    of: #"^[0-9a-f]{40,64}$"#,
                    options: .regularExpression
                  ) != nil
              }) ?? true else {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn baseline does not match this workspace"
            )
        }
        var seen: Set<String> = []
        var durableBytes = 0
        for file in baseline.files {
            let path = try validatedAgentTurnReviewPath(file.path, access: .read)
            guard path == file.path, seen.insert(path).inserted else {
                throw GitServiceError.unsafeReviewSource(
                    "Last Agent Turn baseline contains an invalid or duplicate path"
                )
            }
            if file.existed {
                guard file.byteCount >= 0,
                      file.permissions != nil,
                      file.sha256.map(Self.isReviewFingerprint) == true else {
                    throw GitServiceError.unsafeReviewSource(
                        "Last Agent Turn baseline file identity is malformed"
                    )
                }
                if let data = file.data {
                    guard Int64(data.count) == file.byteCount,
                          Self.sha256(data) == file.sha256,
                          data.count <= Self.maximumTurnBaselineFileBytes,
                          durableBytes <= Self.maximumTurnBaselineContentBytes - data.count else {
                        throw GitServiceError.unsafeReviewSource(
                            "Last Agent Turn baseline content is malformed or oversized"
                        )
                    }
                    durableBytes += data.count
                }
            } else {
                guard file.byteCount == 0,
                      file.permissions == nil,
                      file.sha256 == nil,
                      file.data == nil else {
                    throw GitServiceError.unsafeReviewSource(
                        "Last Agent Turn absent-file identity is malformed"
                    )
                }
            }
        }
    }

    private func validateAgentTurnReviewSnapshot(
        _ snapshot: AgentTurnReviewSnapshot
    ) throws {
        try validateLiveAgentTurnReviewRoot()
        let identity = validator.secureRootIdentity
        let bytes = Data(snapshot.source.utf8)
        guard snapshot.version == AgentTurnReviewSnapshot.currentVersion,
              snapshot.workspaceID == validator.workspace.id,
              snapshot.canonicalRootPath == validator.secureRootPath,
              snapshot.rootDevice == identity.device,
              snapshot.rootInode == identity.inode,
              bytes.count <= Self.maximumReviewSourceBytes,
              Self.isReviewFingerprint(snapshot.sourceSHA256),
              Self.sha256(bytes) == snapshot.sourceSHA256 else {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn snapshot is malformed or does not match this workspace"
            )
        }
    }

    private func validateLiveAgentTurnReviewRoot() throws {
        do {
            try validator.validateLiveRootIdentity()
        } catch {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn workspace root was replaced or is no longer securely reachable"
            )
        }
    }

    private func validatedAgentTurnReviewPath(
        _ rawPath: String,
        access: WorkspacePathAccess
    ) throws -> String {
        guard !rawPath.isEmpty,
              rawPath.utf8.count <= 16 * 1_024,
              !rawPath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn contains an empty, oversized, or control-bearing path"
            )
        }
        let relative = try validator.secureRelativePath(for: rawPath, access: access)
        guard relative != "." else {
            throw GitServiceError.unsafeReviewSource(
                "Last Agent Turn cannot snapshot the workspace root"
            )
        }
        return relative
    }

    private func currentAgentTurnFile(
        path: String,
        identityBytes: inout Int64
    ) throws -> AgentTurnReviewFileBaseline {
        let relative = try validatedAgentTurnReviewPath(path, access: .read)
        guard try secureIO.exists(path: relative) else {
            return AgentTurnReviewFileBaseline(
                path: relative,
                existed: false,
                byteCount: 0,
                permissions: nil,
                sha256: nil,
                data: nil
            )
        }
        let metadata = try secureIO.metadata(path: relative)
        guard metadata.kind == .regularFile,
              metadata.byteCount >= 0,
              identityBytes + metadata.byteCount
                <= Int64(Self.maximumReviewIdentityBytes) else {
            throw GitServiceError.unsafeReviewSource(
                "current file identities exceed the 256 MiB Last Agent Turn limit"
            )
        }
        let remainingIdentityBytes = Self.maximumReviewIdentityBytes - Int(identityBytes)
        let fileData: Data?
        let digest: String
        let capturedMetadata: SecureWorkspaceMetadata
        if metadata.byteCount <= Int64(Self.maximumTurnBaselineFileBytes) {
            let read = try secureIO.readRegularFile(
                path: relative,
                maximumBytes: remainingIdentityBytes
            )
            guard !read.truncated, read.metadata.byteCount == metadata.byteCount else {
                throw GitServiceError.unsafeReviewSource(
                    "current file \(relative) changed during Last Agent Turn Review"
                )
            }
            fileData = read.data
            digest = Self.sha256(read.data)
            capturedMetadata = read.metadata
        } else {
            let streamed = try secureIO.sha256RegularFile(
                path: relative,
                maximumBytes: remainingIdentityBytes
            )
            guard streamed.metadata.byteCount == metadata.byteCount else {
                throw GitServiceError.unsafeReviewSource(
                    "current file \(relative) changed during Last Agent Turn Review"
                )
            }
            fileData = nil
            digest = streamed.sha256
            capturedMetadata = streamed.metadata
        }
        identityBytes += capturedMetadata.byteCount
        return AgentTurnReviewFileBaseline(
            path: relative,
            existed: true,
            byteCount: capturedMetadata.byteCount,
            permissions: capturedMetadata.permissions,
            sha256: digest,
            data: fileData
        )
    }

    private func reviewDiffSegments(_ raw: String) throws -> [String] {
        guard !raw.isEmpty else { return [] }
        guard raw.hasPrefix("diff --git ") else {
            throw GitServiceError.unsafeReviewSource(
                "Git diff output does not begin with a file boundary"
            )
        }
        let pieces = raw.components(separatedBy: "\ndiff --git ")
        return pieces.enumerated().map { index, piece in
            index == 0 ? piece : "diff --git " + piece
        }
    }

    private func parsedSingleReviewFile(_ raw: String) throws -> ReviewFileDiff {
        let document = try ReviewDiffParser().parse(raw, source: .unstaged)
        guard document.files.count == 1, let file = document.files.first else {
            throw GitServiceError.unsafeReviewSource(
                "a Git diff file boundary could not be parsed unambiguously"
            )
        }
        return file
    }

    private static func agentTurnDiff(
        path: String,
        old: AgentTurnReviewFileBaseline,
        new: AgentTurnReviewFileBaseline
    ) -> String {
        let oldToken = old.existed ? reviewGitToken("a/\(path)") : "/dev/null"
        let newToken = new.existed ? reviewGitToken("b/\(path)") : "/dev/null"
        var header = "diff --git \(reviewGitToken("a/\(path)")) \(reviewGitToken("b/\(path)"))\n"
        if !old.existed, new.existed {
            header += "new file mode \(reviewFileMode(new.permissions))\n"
        } else if old.existed, !new.existed {
            header += "deleted file mode \(reviewFileMode(old.permissions))\n"
        } else if old.permissions.map(reviewFileMode) != new.permissions.map(reviewFileMode) {
            header += "old mode \(reviewFileMode(old.permissions))\n"
            header += "new mode \(reviewFileMode(new.permissions))\n"
        }

        if let oldData = old.existed ? old.data : nil,
           let newData = new.existed ? new.data : nil {
            let body = UnifiedDiffBuilder().make(path: path, old: oldData, new: newData)
            return header + body
        }
        if !old.existed, let newData = new.data {
            return header + UnifiedDiffBuilder().make(path: path, old: nil, new: newData)
        }
        if !new.existed, let oldData = old.data {
            return header + UnifiedDiffBuilder().make(path: path, old: oldData, new: nil)
        }

        let oldDigest = old.sha256 ?? "absent"
        let newDigest = new.sha256 ?? "absent"
        var body = "LumaChat review last-agent-turn old-sha256=\(oldDigest) new-sha256=\(newDigest)\n"
        body += "Files \(oldToken) and \(newToken) differ (diff omitted: durable baseline content unavailable).\n"
        let maximumBytes = max(old.byteCount, new.byteCount)
        if maximumBytes > Int64(Self.maximumTurnBaselineFileBytes),
           let digest = new.sha256 ?? old.sha256 {
            body += "LumaChat review large file bytes=\(maximumBytes) "
                + "limit=\(Self.maximumTurnBaselineFileBytes) sha256=\(digest)\n"
        }
        return header + body
    }

    private static func reviewFileMode(_ permissions: Int?) -> String {
        ((permissions ?? 0) & 0o111) == 0 ? "100644" : "100755"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func reviewSourceContainsOmission(_ value: String) -> Bool {
        value.contains("[… oversized terminal line omitted …]")
            || value.contains("[REDACTED")
            || value.contains("Binary files ")
            || value.contains("GIT binary patch")
            || value.contains("LumaChat review large file ")
            || value.contains("diff omitted:")
    }

    private static func reviewSourceTransportWasAltered(_ value: String) -> Bool {
        value.contains("[… oversized terminal line omitted …]")
            || value.contains("[REDACTED")
    }

    private static func insertingUntrackedIdentity(
        _ digest: String,
        into diff: String
    ) throws -> String {
        guard digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              diff.hasPrefix("diff --git "),
              let newline = diff.firstIndex(of: "\n") else {
            throw GitServiceError.unsafeReviewSource(
                "Git did not return a bounded untracked file diff"
            )
        }
        let insertion = diff.index(after: newline)
        return String(diff[..<insertion])
            + "LumaChat review untracked file sha256=\(digest)\n"
            + String(diff[insertion...])
    }

    private static func emptyUntrackedFallback(
        path: String,
        digest: String,
        executable: Bool
    ) -> String {
        let old = reviewGitToken("a/\(path)")
        let new = reviewGitToken("b/\(path)")
        return """
        diff --git \(old) \(new)
        LumaChat review untracked file sha256=\(digest)
        new file mode \(executable ? "100755" : "100644")
        --- /dev/null
        +++ \(new)
        Files /dev/null and \(new) differ (diff omitted: empty untracked file)
        """
    }

    private static func largeUntrackedFallback(
        path: String,
        byteCount: Int,
        digest: String,
        executable: Bool
    ) -> String {
        let old = reviewGitToken("a/\(path)")
        let new = reviewGitToken("b/\(path)")
        return """
        diff --git \(old) \(new)
        LumaChat review untracked file sha256=\(digest)
        LumaChat review large file bytes=\(byteCount) limit=\(maximumReviewFileBytes) sha256=\(digest)
        new file mode \(executable ? "100755" : "100644")
        --- /dev/null
        +++ \(new)
        """
    }

    private static func reviewGitToken(_ value: String) -> String {
        let needsQuotes = value.contains { character in
            character.isWhitespace || character == "\\" || character == "\""
                || !character.isASCII
        }
        guard needsQuotes else { return value }
        var result = "\""
        for byte in value.utf8 {
            switch byte {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x20...0x7E: result.append(Character(UnicodeScalar(byte)))
            default: result += String(format: "\\%03o", byte)
            }
        }
        return result + "\""
    }

    private func read(_ arguments: [String]) async throws -> GitCommandResult {
        let result = try await raw(arguments)
        try ensureSuccess(result, arguments: arguments)
        let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        return GitCommandResult(
            output: combined,
            exitCode: result.exitCode,
            truncated: result.truncated,
            artifactPath: result.stdoutArtifactPath ?? result.stderrArtifactPath,
            change: nil
        )
    }

    private func mutate(
        _ arguments: [String],
        snapshotPaths: [String],
        taskID: UUID,
        allowsNetwork: Bool = false,
        recordFailedOutcome: Bool = false,
        authentication: GitRemoteCommandAuthentication? = nil
    ) async throws -> GitCommandResult {
        guard repositoryLayout.supportsWorkspaceMetadataSnapshots else {
            // Linked worktree metadata lives outside the selected workspace, so
            // ChangeManager cannot truthfully restore its index/HEAD/refs. Keep
            // the Git operation functional through the closed command surface,
            // but do not manufacture an Undo card. The output says so plainly.
            let result = try await raw(
                arguments,
                metadataWrite: true,
                workspaceWrite: true,
                allowsNetwork: allowsNetwork,
                authentication: authentication
            )
            if !recordFailedOutcome {
                try ensureSuccess(result, arguments: arguments)
            }
            let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            let warning = "Undo unavailable for this linked-worktree Git metadata mutation."
            return GitCommandResult(
                output: combined.isEmpty ? warning : combined + "\n" + warning,
                exitCode: result.exitCode,
                truncated: result.truncated,
                artifactPath: result.stdoutArtifactPath ?? result.stderrArtifactPath,
                change: nil
            )
        }
        let transaction = try await changes.beginChange(
            paths: snapshotPaths,
            operation: .git,
            taskID: taskID
        )
        do {
            let result = try await raw(
                arguments,
                metadataWrite: true,
                workspaceWrite: true,
                allowsNetwork: allowsNetwork,
                authentication: authentication
            )
            if !recordFailedOutcome {
                try ensureSuccess(result, arguments: arguments)
            }
            let change = try await changes.commitChange(transaction)
            let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            return GitCommandResult(
                output: combined,
                exitCode: result.exitCode,
                truncated: result.truncated,
                artifactPath: result.stdoutArtifactPath ?? result.stderrArtifactPath,
                change: change
            )
        } catch {
            try? await changes.rollbackChange(transaction)
            throw error
        }
    }

    private func raw(
        _ arguments: [String],
        metadataWrite: Bool = false,
        workspaceWrite: Bool = false,
        allowsNetwork: Bool = false,
        authentication: GitRemoteCommandAuthentication? = nil
    ) async throws -> TerminalCommandResult {
        await beginRegularGitCommand()
        defer { endRegularGitCommand() }
        return try await rawWithoutGate(
            arguments,
            metadataWrite: metadataWrite,
            workspaceWrite: workspaceWrite,
            allowsNetwork: allowsNetwork,
            authentication: authentication
        )
    }

    private func rawWithoutGate(
        _ arguments: [String],
        metadataWrite: Bool = false,
        workspaceWrite: Bool = false,
        allowsNetwork: Bool = false,
        standardInput: Data? = nil,
        authentication: GitRemoteCommandAuthentication? = nil
    ) async throws -> TerminalCommandResult {
        let authenticationArguments = authentication.map {
            $0.gitGlobalArguments + ["-c", "http.followRedirects=false"]
        } ?? []
        let command = (gitPrefix + authenticationArguments + arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        let commandEnvironment = Self.nonInteractiveGitEnvironment.merging(
            authentication?.environment ?? [:]
        ) { _, authenticatedValue in authenticatedValue }
        return try await terminal.run(
            command: command,
            cwd: ".",
            timeout: timeout,
            environment: commandEnvironment,
            redactionSecrets: authentication?.redactionSecrets ?? [],
            allowsNetwork: allowsNetwork,
            allowsGitMetadata: true,
            allowsGitMetadataWrite: metadataWrite,
            allowsWorkspaceWrite: workspaceWrite,
            standardInput: standardInput
        )
    }

    private func executeWithoutSnapshot(
        _ arguments: [String],
        allowsNetwork: Bool,
        metadataWrite: Bool,
        workspaceWrite: Bool,
        authentication: GitRemoteCommandAuthentication? = nil
    ) async throws -> GitCommandResult {
        let result = try await raw(
            arguments,
            metadataWrite: metadataWrite,
            workspaceWrite: workspaceWrite,
            allowsNetwork: allowsNetwork,
            authentication: authentication
        )
        try ensureSuccess(result, arguments: arguments)
        let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
        return GitCommandResult(
            output: combined,
            exitCode: result.exitCode,
            truncated: result.truncated,
            artifactPath: result.stdoutArtifactPath ?? result.stderrArtifactPath,
            change: nil
        )
    }

    /// Returns complete binary Git output without relying on the terminal's
    /// head/tail rendering. `/usr/bin/base64` on macOS emits one unbounded line,
    /// so fold it before the line-oriented secret-redacting artifact spool.
    private func rawGitBytes(
        _ arguments: [String],
        maximumDecodedBytes: Int
    ) async throws -> Data {
        await beginRegularGitCommand()
        defer { endRegularGitCommand() }
        return try await rawGitBytesWithoutGate(
            arguments,
            maximumDecodedBytes: maximumDecodedBytes
        )
    }

    private func rawGitBytesWithoutGate(
        _ arguments: [String],
        maximumDecodedBytes: Int
    ) async throws -> Data {
        let invocation = (gitPrefix + arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        let result = try await terminal.run(
            command: "set -o pipefail; \(invocation) | /usr/bin/base64 | /usr/bin/fold -w 76",
            cwd: ".",
            timeout: timeout,
            environment: Self.nonInteractiveGitEnvironment,
            allowsGitMetadata: true,
            allowsGitMetadataWrite: false,
            allowsWorkspaceWrite: false
        )
        defer { removeTransientArtifacts(from: result) }
        try ensureSuccess(result, arguments: arguments)

        let maximumEncodedBytes = maximumDecodedBytes * 4 / 3 + 8_192
        let encoded = try completeStdout(result, maximumBytes: maximumEncodedBytes)
        let compact = Data(encoded.filter { byte in
            byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x20
        })
        let isBase64 = compact.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2B || byte == 0x2F || byte == 0x3D
        }
        guard isBase64,
              let decoded = Data(base64Encoded: compact),
              decoded.count <= maximumDecodedBytes else {
            throw GitServiceError.unsafePathInventory("invalid or oversized encoded output")
        }
        return decoded
    }

    private func beginRegularGitCommand() async {
        while reviewPatchHasExclusiveAccess {
            await waitForCommandGateChange()
        }
        activeGitCommandCount += 1
    }

    private func endRegularGitCommand() {
        precondition(activeGitCommandCount > 0)
        activeGitCommandCount -= 1
        signalCommandGateChange()
    }

    private func beginExclusiveReviewPatch() async {
        while reviewPatchHasExclusiveAccess || activeGitCommandCount > 0 {
            await waitForCommandGateChange()
        }
        reviewPatchHasExclusiveAccess = true
    }

    private func endExclusiveReviewPatch() {
        precondition(reviewPatchHasExclusiveAccess)
        reviewPatchHasExclusiveAccess = false
        signalCommandGateChange()
    }

    private func waitForCommandGateChange() async {
        await withCheckedContinuation { continuation in
            commandGateWaiters.append(continuation)
        }
    }

    private func signalCommandGateChange() {
        let waiters = commandGateWaiters
        commandGateWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    private func completeStdout(
        _ result: TerminalCommandResult,
        maximumBytes: Int
    ) throws -> Data {
        guard let artifactPath = result.stdoutArtifactPath else {
            let data = Data(result.stdout.utf8)
            guard data.count <= maximumBytes else {
                throw GitServiceError.unsafePathInventory("stdout exceeds the bounded inventory size")
            }
            return data
        }

        let artifactRoot = AppPaths.agentArtifacts.resolvingSymlinksInPath().standardizedFileURL
        let artifact = URL(fileURLWithPath: artifactPath, isDirectory: false).standardizedFileURL
        let resolved = artifact.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(artifactRoot.path + "/") else {
            throw GitServiceError.unsafePathInventory("terminal artifact escaped app-owned storage")
        }
        let values = try artifact.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw GitServiceError.unsafePathInventory("terminal artifact is not a bounded regular file")
        }
        let handle = try FileHandle(forReadingFrom: artifact)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw GitServiceError.unsafePathInventory("terminal artifact exceeds the bounded inventory size")
        }
        return data
    }

    private func decodeNULTerminatedStrings(
        _ data: Data,
        maximumCount: Int
    ) throws -> [String] {
        // An empty Git inventory is a valid zero-path result. `Data.split`
        // with `omittingEmptySubsequences: false` represents it as one empty
        // field, which must not be confused with an empty pathname emitted by
        // Git (the latter is only possible inside non-empty malformed data).
        guard !data.isEmpty else { return [] }
        guard data.last == 0 else {
            throw GitServiceError.unsafePathInventory("Git did not terminate the path list")
        }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if data.last == 0 { fields.removeLast() }
        guard fields.count <= maximumCount else {
            throw GitServiceError.tooManyChangedFiles(maximumCount)
        }
        return try fields.map { bytes in
            guard !bytes.isEmpty, let path = String(data: Data(bytes), encoding: .utf8) else {
                throw GitServiceError.unsafePathInventory("a path is empty or not valid UTF-8")
            }
            return path
        }
    }

    private func changedPaths(
        _ arguments: [String],
        maximumCount: Int = 2_000
    ) async throws -> [String] {
        let data = try await rawGitBytes(arguments, maximumDecodedBytes: 8 * 1_024 * 1_024)
        let decoded = try decodeNULTerminatedStrings(data, maximumCount: maximumCount)
        var seen: Set<String> = []
        var result: [String] = []
        for path in decoded where seen.insert(path).inserted {
            _ = try validator.validate(path: path, access: .write, allowNonexistentLeaf: true)
            result.append(path)
        }
        return result
    }

    private func affectedPaths(between left: String, and right: String) async throws -> [String] {
        try await changedPaths([
            "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
            "--name-only", "-z", "--diff-filter=ACDMRTUXB", left, right, "--"
        ])
    }

    private func rebaseAffectedPaths(onto reference: String) async throws -> [String] {
        let baseResult = try await raw(["merge-base", "HEAD", reference])
        try ensureSuccess(baseResult, arguments: ["merge-base", "HEAD", reference])
        let mergeBase = baseResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mergeBase.range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil else {
            throw GitServiceError.invalidReference(mergeBase)
        }
        let currentSide = try await affectedPaths(between: mergeBase, and: "HEAD")
        let targetSide = try await affectedPaths(between: mergeBase, and: reference)
        var seen: Set<String> = []
        return (currentSide + targetSide).filter { seen.insert($0).inserted }
    }

    private func workingTreeDifferencePaths(relativeTo reference: String) async throws -> [String] {
        try await changedPaths([
            "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
            "--name-only", "-z", "--diff-filter=ACDMRTUXB", reference, "--"
        ])
    }

    /// A stopped rebase can apply more than the currently conflicted commit on
    /// its next `--continue`. Include the current original commit, the bounded
    /// net remainder through ORIG_HEAD, and the user's staged resolution.
    private func rebaseContinuationAffectedPaths() async throws -> [String] {
        let currentCommit = try await changedPaths([
            "diff-tree", "--root", "--no-commit-id", "--name-only", "-z", "-r",
            "REBASE_HEAD"
        ])
        let remaining = try await affectedPaths(between: "REBASE_HEAD", and: "ORIG_HEAD")
        let resolution = try await workingTreeDifferencePaths(relativeTo: "HEAD")
        return try boundedOrderedUniquePaths(currentCommit + remaining + resolution)
    }

    /// Establish every workspace path that `reset --hard` can replace or
    /// remove. Git diff covers tracked/index changes. The target tree plus the
    /// current index lets us also identify untracked or ignored filesystem
    /// entries that obstruct a target path and that Git would otherwise delete.
    private func hardResetAffectedPaths(reference: String) async throws -> [String] {
        let maximum = 20_000
        let differences = try await changedPaths([
            "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
            "--name-only", "-z", "--diff-filter=ACDMRTUXB", reference, "--"
        ], maximumCount: maximum)
        let targetPaths = try await changedPaths([
            "ls-tree", "-r", "-z", "--name-only", reference, "--"
        ], maximumCount: maximum)
        let trackedPaths = try await changedPaths([
            "ls-files", "--cached", "-z", "--"
        ], maximumCount: maximum)
        let tracked = Set(trackedPaths)
        var obstructions: [String] = []

        for targetPath in targetPaths {
            let components = targetPath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty }) else {
                throw GitServiceError.unsafePathInventory("a target-tree path was malformed")
            }

            var hasAncestorObstruction = false
            if components.count > 1 {
                var prefix = ""
                for component in components.dropLast() {
                    prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                    guard let kind = try workspaceEntryKind(prefix) else { break }
                    if kind != S_IFDIR {
                        if !tracked.contains(prefix) { obstructions.append(prefix) }
                        hasAncestorObstruction = true
                        break
                    }
                }
            }
            if !hasAncestorObstruction,
               !tracked.contains(targetPath),
               try workspaceEntryExists(targetPath) {
                obstructions.append(targetPath)
            }
        }

        return try boundedOrderedUniquePaths(
            differences + obstructions,
            maximumCount: maximum,
            collapseNestedPaths: true
        )
    }

    private func boundedOrderedUniquePaths(
        _ paths: [String],
        maximumCount: Int = 2_000,
        collapseNestedPaths: Bool = false
    ) throws -> [String] {
        var seen: Set<String> = []
        var unique = paths.filter { seen.insert($0).inserted }
        if collapseNestedPaths {
            unique.sort {
                let leftDepth = $0.split(separator: "/", omittingEmptySubsequences: false).count
                let rightDepth = $1.split(separator: "/", omittingEmptySubsequences: false).count
                return leftDepth == rightDepth ? $0 < $1 : leftDepth < rightDepth
            }
            var collapsed: [String] = []
            for path in unique where !collapsed.contains(where: { path.hasPrefix($0 + "/") }) {
                collapsed.append(path)
            }
            unique = collapsed
        }
        guard unique.count <= maximumCount else {
            throw GitServiceError.tooManyChangedFiles(maximumCount)
        }
        return unique
    }

    private func workspaceEntryExists(_ path: String) throws -> Bool {
        try workspaceEntryKind(path) != nil
    }

    private func workspaceEntryKind(_ path: String) throws -> mode_t? {
        let url = try validator.validate(path: path, access: .write, allowNonexistentLeaf: true)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw GitServiceError.unsafePathInventory("unable to inspect \(path)")
        }
        return info.st_mode & S_IFMT
    }

    private func requireNoOperationState(for expected: String) throws {
        let active = try activeOperationStateLabels()
        guard active.isEmpty else {
            throw GitServiceError.operationStateMismatch(expected: expected, active: active)
        }
    }

    private func requireOperationState(_ expected: GitOperationState) throws {
        let active = try activeOperationStateLabels()
        guard active == [expected.rawValue] else {
            throw GitServiceError.operationStateMismatch(
                expected: expected.rawValue,
                active: active
            )
        }
    }

    /// Inspect only fixed, host-selected state markers in the already-verified
    /// per-worktree Git directory. Unexpected marker file types fail closed.
    private func activeOperationStateLabels() throws -> [String] {
        var active: [String] = []
        if try metadataEntryExists("MERGE_HEAD", expectedKind: S_IFREG) {
            active.append(GitOperationState.merge.rawValue)
        }

        let rebaseMerge = try metadataEntryExists("rebase-merge", expectedKind: S_IFDIR)
        let rebaseApply = try metadataEntryExists("rebase-apply", expectedKind: S_IFDIR)
        var applyIsRebase = false
        if rebaseApply {
            applyIsRebase = try metadataEntryExists(
                "rebase-apply/rebasing",
                expectedKind: S_IFREG
            )
        }
        if rebaseMerge || applyIsRebase {
            active.append(GitOperationState.rebase.rawValue)
        } else if rebaseApply {
            active.append("mailbox-apply")
        }

        let cherryPick = try metadataEntryExists("CHERRY_PICK_HEAD", expectedKind: S_IFREG)
        if cherryPick { active.append(GitOperationState.cherryPick.rawValue) }
        if try metadataEntryExists("REVERT_HEAD", expectedKind: S_IFREG) {
            active.append("revert")
        }
        if !cherryPick,
           try metadataEntryExists("sequencer", expectedKind: S_IFDIR) {
            active.append("sequencer")
        }
        if try metadataEntryExists("BISECT_START", expectedKind: S_IFREG) {
            active.append("bisect")
        }
        return active
    }

    private func metadataEntryExists(
        _ relativePath: String,
        expectedKind: mode_t
    ) throws -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GitServiceError.invalidRepositoryLayout("invalid internal metadata path")
        }
        let url = repositoryLayout.worktreeGitDirectory
            .appendingPathComponent(relativePath, isDirectory: expectedKind == S_IFDIR)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw GitServiceError.invalidRepositoryLayout("unable to inspect Git operation state")
        }
        guard info.st_mode & S_IFMT == expectedKind else {
            throw GitServiceError.invalidRepositoryLayout(
                "Git operation marker \(relativePath) has an unsafe file type"
            )
        }
        return true
    }

    private func lifecycleMetadataSnapshotPaths(
        for state: GitOperationState
    ) async throws -> [String] {
        var paths: [String]
        switch state {
        case .merge:
            paths = try await currentBranchMetadataSnapshotPaths()
            paths += [
                ".git/MERGE_HEAD", ".git/MERGE_MSG", ".git/MERGE_MODE",
                ".git/AUTO_MERGE", ".git/ORIG_HEAD"
            ]
        case .cherryPick:
            paths = try await currentBranchMetadataSnapshotPaths()
            paths += [
                ".git/CHERRY_PICK_HEAD", ".git/MERGE_MSG", ".git/ORIG_HEAD",
                ".git/sequencer"
            ]
        case .rebase:
            paths = [
                ".git/HEAD", ".git/index", ".git/packed-refs", ".git/ORIG_HEAD",
                ".git/REBASE_HEAD", ".git/rebase-apply", ".git/rebase-merge"
            ]
            if let branchPath = try rebaseOriginalBranchSnapshotPath() {
                paths.append(branchPath)
            }
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private func rebaseOriginalBranchSnapshotPath() throws -> String? {
        let stateDirectory = try metadataEntryExists("rebase-merge", expectedKind: S_IFDIR)
            ? "rebase-merge"
            : "rebase-apply"
        let raw = try boundedMetadataLine("\(stateDirectory)/head-name")
        if raw == "detached HEAD" { return nil }
        let prefix = "refs/heads/"
        guard raw.hasPrefix(prefix) else {
            throw GitServiceError.invalidRepositoryLayout("rebase head-name is not a local branch")
        }
        let branch = try validatedBranchName(String(raw.dropFirst(prefix.count)))
        return ".git/refs/heads/\(branch)"
    }

    private func boundedMetadataLine(_ relativePath: String) throws -> String {
        guard try metadataEntryExists(relativePath, expectedKind: S_IFREG) else {
            throw GitServiceError.invalidRepositoryLayout("missing rebase metadata")
        }
        let url = repositoryLayout.worktreeGitDirectory.appendingPathComponent(relativePath)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8) else {
            throw GitServiceError.invalidRepositoryLayout("rebase metadata is oversized or invalid")
        }
        let line = value.trimmingCharacters(in: .newlines)
        guard !line.isEmpty,
              !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw GitServiceError.invalidRepositoryLayout("rebase metadata contains controls")
        }
        return line
    }

    private func currentLocalBranchName() async throws -> String {
        let result = try await raw(["branch", "--show-current"])
        try ensureSuccess(result, arguments: ["branch", "--show-current"])
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw GitServiceError.invalidReference("detached HEAD has no local branch")
        }
        return try validatedBranchName(name)
    }

    private func currentBranchMetadataSnapshotPaths() async throws -> [String] {
        let branch = try await currentLocalBranchName()
        return [
            ".git/HEAD", ".git/index", ".git/refs/heads/\(branch)", ".git/packed-refs"
        ]
    }

    private func fetchSnapshotPaths(remote: String) -> [String] {
        [
            ".git/FETCH_HEAD", ".git/refs/remotes/\(remote)",
            ".git/packed-refs", ".git/shallow"
        ]
    }

    private func ensureSafeMutationAttributes(paths: [String]) async throws {
        try await ensureNoContentFilters(paths: paths)
        try await ensureNoCustomMergeDrivers(paths: paths)
    }

    private func ensureNoContentFilters(
        paths: [String],
        gateAlreadyHeld: Bool = false
    ) async throws {
        var start = 0
        while start < paths.count {
            var end = start
            var byteBudget = 0
            while end < paths.count, end - start < 100 {
                let next = paths[end].utf8.count + 1
                if end > start, byteBudget + next > 32 * 1_024 { break }
                byteBudget += next
                end += 1
            }
            let batch = Array(paths[start..<end])
            let arguments = ["check-attr", "-z", "filter", "--"] + batch
            let maximumBytes = max(64 * 1_024, byteBudget * 4 + 4_096)
            let output = if gateAlreadyHeld {
                try await rawGitBytesWithoutGate(
                    arguments,
                    maximumDecodedBytes: maximumBytes
                )
            } else {
                try await rawGitBytes(
                    arguments,
                    maximumDecodedBytes: maximumBytes
                )
            }
            var fields = output.split(separator: 0, omittingEmptySubsequences: false)
            guard output.isEmpty || output.last == 0 else {
                throw GitServiceError.unsafePathInventory("Git attribute output was incomplete")
            }
            if output.last == 0 { fields.removeLast() }
            guard fields.count.isMultiple(of: 3) else {
                throw GitServiceError.unsafePathInventory("Git attribute output was malformed")
            }
            for index in stride(from: 0, to: fields.count, by: 3) {
                guard let path = String(data: Data(fields[index]), encoding: .utf8),
                      let value = String(data: Data(fields[index + 2]), encoding: .utf8) else {
                    throw GitServiceError.unsafePathInventory("Git attribute output was not valid UTF-8")
                }
                if value != "unspecified", value != "unset", value != "set", !value.isEmpty {
                    throw GitServiceError.unsafeFilteredPath(path)
                }
                // `filter` with no explicit value is represented as `set` and
                // can still select a repository-configured driver.
                if value == "set" { throw GitServiceError.unsafeFilteredPath(path) }
            }
            start = end
        }
    }

    private func ensureNoCustomMergeDrivers(paths: [String]) async throws {
        var start = 0
        while start < paths.count {
            var end = start
            var byteBudget = 0
            while end < paths.count, end - start < 100 {
                let next = paths[end].utf8.count + 1
                if end > start, byteBudget + next > 32 * 1_024 { break }
                byteBudget += next
                end += 1
            }
            let batch = Array(paths[start..<end])
            let output = try await rawGitBytes(
                ["check-attr", "-z", "merge", "--"] + batch,
                maximumDecodedBytes: max(64 * 1_024, byteBudget * 4 + 4_096)
            )
            var fields = output.split(separator: 0, omittingEmptySubsequences: false)
            guard output.isEmpty || output.last == 0 else {
                throw GitServiceError.unsafePathInventory("Git merge-attribute output was incomplete")
            }
            if output.last == 0 { fields.removeLast() }
            guard fields.count.isMultiple(of: 3) else {
                throw GitServiceError.unsafePathInventory("Git merge-attribute output was malformed")
            }
            for index in stride(from: 0, to: fields.count, by: 3) {
                guard let path = String(data: Data(fields[index]), encoding: .utf8),
                      let value = String(data: Data(fields[index + 2]), encoding: .utf8) else {
                    throw GitServiceError.unsafePathInventory(
                        "Git merge-attribute output was not valid UTF-8"
                    )
                }
                let builtInValues = Set(["", "unspecified", "unset", "set", "text", "binary", "union"])
                if !builtInValues.contains(value) {
                    throw GitServiceError.unsafeAttributePath(
                        path: path,
                        attribute: "merge=\(value)"
                    )
                }
            }
            start = end
        }
    }

    private var gitPrefix: [String] {
        ["/usr/bin/git", "--no-optional-locks"] + [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "credential.helper=",
            "-c", "core.askPass=/usr/bin/false",
            "-c", "core.editor=/usr/bin/true",
            "-c", "sequence.editor=/usr/bin/true",
            "-c", "merge.autoEdit=no",
            "-c", "protocol.ext.allow=never",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
            "-c", "rebase.autoStash=false"
        ]
    }

    private static let nonInteractiveGitEnvironment = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/false",
        "SSH_ASKPASS": "/usr/bin/false",
        "GIT_EDITOR": "/usr/bin/true",
        "GIT_SEQUENCE_EDITOR": "/usr/bin/true",
        "GIT_MERGE_AUTOEDIT": "no",
        "EDITOR": "/usr/bin/true",
        "VISUAL": "/usr/bin/true",
        "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes -oNumberOfPasswordPrompts=0"
    ]

    private func ensureSuccess(_ result: TerminalCommandResult, arguments: [String]) throws {
        guard result.exitCode == 0, !result.timedOut else {
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            throw GitServiceError.commandFailed(
                command: "git " + arguments.joined(separator: " "),
                exitCode: result.exitCode,
                output: output
            )
        }
    }

    private func validatedRelativePath(_ path: String, access: WorkspacePathAccess) throws -> String {
        let url = try validator.validate(
            path: path,
            access: access,
            allowNonexistentLeaf: access == .write
        )
        return validator.relativePath(for: url)
    }

    private func validatedReference(_ reference: String) throws -> String {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 1_024,
              !trimmed.hasPrefix("-"),
              !trimmed.contains(".."),
              trimmed.range(of: #"^[A-Za-z0-9_./@{}~^+-]+$"#, options: .regularExpression) != nil
        else { throw GitServiceError.invalidReference(reference) }
        return trimmed
    }

    private func validatedBranchName(_ name: String) throws -> String {
        try validatedRefName(name, kind: "branch")
    }

    private func validatedTagName(_ name: String) throws -> String {
        try validatedRefName(name, kind: "tag")
    }

    private func validatedRemoteName(_ name: String) throws -> String {
        let value = try validatedRefName(name, kind: "remote")
        guard !value.contains("/") else { throw GitServiceError.invalidReference(name) }
        return value
    }

    private func validatedRefName(_ raw: String, kind: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              value != "@",
              value != "HEAD",
              !value.hasPrefix("-"),
              !value.hasPrefix("."),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              !value.contains("//"),
              !value.contains(".."),
              !value.contains("@{"),
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil,
              components.allSatisfy({ !$0.hasSuffix(".lock") && !$0.hasPrefix(".") })
        else {
            throw GitServiceError.invalidReference("\(kind): \(raw)")
        }
        return value
    }

    private func validatedMessage(_ message: String) throws -> String {
        guard !message.contains("\0"), message.utf8.count <= 64 * 1_024 else {
            throw GitServiceError.invalidMessage("must be at most 65536 UTF-8 bytes and contain no NUL")
        }
        return message
    }

    private func validateConfiguredRemote(
        _ remote: String,
        direction: GitRemoteDirection,
        access: WorkspacePathAccess
    ) async throws -> String {
        var arguments = ["remote", "get-url"]
        if direction == .push { arguments.append("--push") }
        arguments += ["--all", remote]
        let result = try await raw(arguments)
        defer { removeTransientArtifacts(from: result) }
        try ensureSuccess(result, arguments: arguments)
        let lines = result.stdout
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        guard lines.count == 1 else {
            throw GitServiceError.unsafeRemote("the configured URL is missing or ambiguous")
        }
        return try validatedRemoteURL(lines[0], access: access)
    }

    @discardableResult
    private func validatedRemoteURL(
        _ raw: String,
        access: WorkspacePathAccess
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw GitServiceError.unsafeRemote("the configured URL is empty, oversized, or contains controls")
        }

        // Accept the conventional SCP-like SSH form without accepting arbitrary
        // `transport::command` remote helpers.
        if value.range(
            of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._~/-]+$"#,
            options: .regularExpression
        ) != nil {
            return value
        }

        guard let components = URLComponents(string: value) else {
            throw GitServiceError.unsafeRemote("the configured URL cannot be parsed")
        }
        if let scheme = components.scheme?.lowercased() {
            guard components.query == nil, components.fragment == nil else {
                throw GitServiceError.unsafeRemote("query strings and fragments are not accepted")
            }
            switch scheme {
            case "https", "git":
                guard components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil else {
                    throw GitServiceError.unsafeRemote(
                        "HTTPS/Git URLs must have a host and cannot embed credentials"
                    )
                }
                return value
            case "ssh":
                guard components.host?.isEmpty == false,
                      components.password == nil else {
                    throw GitServiceError.unsafeRemote(
                        "SSH URLs must have a host and cannot embed a password"
                    )
                }
                return value
            case "file":
                guard let url = components.url, url.isFileURL else {
                    throw GitServiceError.unsafeRemote("the file URL is malformed")
                }
                _ = try validator.validate(
                    path: url.path,
                    access: access,
                    allowNonexistentLeaf: false
                )
                return value
            default:
                throw GitServiceError.unsafeRemote("unsupported URL scheme \(scheme)")
            }
        }

        _ = try validator.validate(
            path: value,
            access: access,
            allowNonexistentLeaf: false
        )
        return value
    }

    private func removeTransientArtifacts(from result: TerminalCommandResult) {
        let root = AppPaths.agentArtifacts.standardizedFileURL.resolvingSymlinksInPath()
        for rawPath in [result.stdoutArtifactPath, result.stderrArtifactPath].compactMap({ $0 }) {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL
            let resolved = path.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            try? FileManager.default.removeItem(at: path)
        }
    }

    private func validatedReviewPatch(
        _ payload: ReviewPatchPayload
    ) throws -> ValidatedGitReviewPatch {
        let data = Data(payload.unifiedDiff.utf8)
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 else {
            throw GitServiceError.unsafeReviewPatch("patch size must be between 1 byte and 2 MiB")
        }
        guard !payload.unifiedDiff.contains("\0"),
              !payload.unifiedDiff.contains("GIT binary patch"),
              !payload.unifiedDiff.contains("Binary files "),
              payload.unifiedDiff.hasPrefix("diff --git ") else {
            throw GitServiceError.unsafeReviewPatch("binary, control, or non-unified patch data")
        }
        guard Self.isReviewFingerprint(payload.selection.fileID),
              Self.isReviewFingerprint(payload.selection.fileFingerprint) else {
            throw GitServiceError.unsafeReviewPatch("file identity or fingerprint is malformed")
        }
        switch (payload.selection.hunkID, payload.selection.hunkFingerprint) {
        case (nil, nil):
            break
        case (.some(let id), .some(let fingerprint))
            where Self.isReviewFingerprint(id) && Self.isReviewFingerprint(fingerprint):
            break
        default:
            throw GitServiceError.unsafeReviewPatch("hunk identity and fingerprint are inconsistent")
        }

        let document: ReviewDocument
        do {
            document = try ReviewDiffParser().parse(payload.unifiedDiff, source: .unstaged)
        } catch {
            throw GitServiceError.unsafeReviewPatch("the textual patch cannot be parsed safely")
        }
        guard document.files.count == 1,
              let file = document.files.first,
              file.fallback == nil else {
            throw GitServiceError.unsafeReviewPatch("exactly one textual file patch is required")
        }
        var seen: Set<String> = []
        var paths: [String] = []
        for path in [file.oldPath, file.newPath].compactMap({ $0 })
            where seen.insert(path).inserted {
            _ = try validator.validate(
                path: path,
                access: .write,
                allowNonexistentLeaf: true
            )
            paths.append(path)
        }
        guard !paths.isEmpty, paths.count <= 2 else {
            throw GitServiceError.unsafeReviewPatch("the patch has no bounded workspace path")
        }
        return ValidatedGitReviewPatch(data: data, paths: paths)
    }

    private static func isReviewFingerprint(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
