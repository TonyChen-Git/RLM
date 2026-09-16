import Darwin
import CryptoKit
import Foundation

enum WorktreeStateMigrationError: LocalizedError, Equatable {
    case notRepository(String)
    case commandFailed(String)
    case outputTooLarge(Int)
    case targetNotClean(String)
    case revisionMismatch(source: String, target: String)
    case nonFastForward(expected: String, desired: String)
    case unsafePath(String)
    case unsupportedFile(String)
    case transferTooLarge(Int)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRepository(let path): "Not a usable Git worktree: \(path)"
        case .commandFailed(let detail): "Git state migration failed: \(detail)"
        case .outputTooLarge(let maximum): "Git state output exceeds \(maximum) bytes."
        case .targetNotClean(let path): "Destination checkout is not clean: \(path)"
        case .revisionMismatch(let source, let target):
            "Source and destination revisions differ (\(source) != \(target))."
        case .nonFastForward(let expected, let desired):
            "Refusing non-fast-forward state replacement (\(expected) -> \(desired))."
        case .unsafePath(let path): "Unsafe migration path: \(path)"
        case .unsupportedFile(let path): "Only regular files and directories can migrate: \(path)"
        case .transferTooLarge(let maximum): "Supplemental files exceed \(maximum) bytes."
        case .verificationFailed(let detail): "Migrated Git state could not be verified: \(detail)"
        }
    }
}

struct WorktreeSupplementalFile: Equatable, Sendable {
    var relativePath: String
    var data: Data
    var permissions: Int
}

enum WorktreeSupplementalPathKind: String, Equatable, Sendable {
    case absent
    case directory
    case regularFile
}

/// A complete manifest entry for Task-owned state that Git does not carry.
/// Keeping absent paths and directories is intentional: an ignored tombstone
/// and an empty directory are both meaningful state during a handoff.
struct WorktreeSupplementalPath: Equatable, Sendable {
    var relativePath: String
    var kind: WorktreeSupplementalPathKind
    var data: Data?
    var permissions: Int?
}

struct WorktreeStateSnapshot: Equatable, Sendable {
    var sourceRootPath: String
    var headObjectID: String
    var symbolicReference: String?
    var workingTreePatch: Data
    var stagedPatch: Data
    var supplementalFiles: [WorktreeSupplementalFile]
    var supplementalManifest: [WorktreeSupplementalPath]
    var supplementalRoots: [String]

    init(
        sourceRootPath: String,
        headObjectID: String,
        symbolicReference: String? = nil,
        workingTreePatch: Data,
        stagedPatch: Data,
        supplementalFiles: [WorktreeSupplementalFile],
        supplementalManifest: [WorktreeSupplementalPath]? = nil,
        supplementalRoots: [String]? = nil
    ) {
        self.sourceRootPath = sourceRootPath
        self.headObjectID = headObjectID
        self.symbolicReference = symbolicReference
        self.workingTreePatch = workingTreePatch
        self.stagedPatch = stagedPatch
        self.supplementalFiles = supplementalFiles
        self.supplementalManifest = supplementalManifest ?? supplementalFiles.map {
            WorktreeSupplementalPath(
                relativePath: $0.relativePath,
                kind: .regularFile,
                data: $0.data,
                permissions: $0.permissions
            )
        }
        self.supplementalRoots = supplementalRoots
            ?? supplementalFiles.map(\.relativePath)
    }

    /// Stable, fixed-size identity for conflict checks. Length-prefixed fields
    /// avoid delimiter ambiguity, and hashing is streamed so no second copy of
    /// a potentially large patch or supplemental payload is allocated.
    var fingerprint: String {
        var hasher = SHA256()

        func lengthData(_ count: Int) -> Data {
            var value = UInt64(max(0, count)).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }

        func update(_ label: String, _ data: Data) {
            let labelData = Data(label.utf8)
            hasher.update(data: lengthData(labelData.count))
            hasher.update(data: labelData)
            hasher.update(data: lengthData(data.count))
            hasher.update(data: data)
        }

        update("schema", Data("worktree-state-v2".utf8))
        update("head", Data(headObjectID.utf8))
        update("tracked-working-patch", workingTreePatch)
        update("tracked-staged-patch", stagedPatch)
        for root in supplementalRoots.sorted() {
            update("supplemental-root", Data(root.utf8))
        }
        for entry in supplementalManifest.sorted(by: { $0.relativePath < $1.relativePath }) {
            update("supplemental-path", Data(entry.relativePath.utf8))
            update("supplemental-kind", Data(entry.kind.rawValue.utf8))
            if let permissions = entry.permissions {
                update("supplemental-permissions", Data(String(permissions).utf8))
            } else {
                update("supplemental-permissions-absent", Data())
            }
            update("supplemental-untracked", Data([1]))
            if let data = entry.data {
                update("supplemental-data", data)
            } else {
                update("supplemental-data-absent", Data())
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Copies the logical Git state of one checkout into another checkout at the
/// same HEAD. Git patches preserve staged versus unstaged tracked state;
/// bounded supplemental copies preserve untracked files plus explicit Task
/// change paths that may be ignored by Git. Source files are never removed.
struct WorktreeStateMigrator: @unchecked Sendable {
    static let maximumPatchBytes = 64 * 1_024 * 1_024
    static let maximumPathListBytes = 8 * 1_024 * 1_024
    static let maximumSupplementalBytes = 256 * 1_024 * 1_024
    static let maximumSupplementalFiles = 10_000

    private let fileManager: FileManager
    private let temporaryRoot: URL

    init(
        fileManager: FileManager = .default,
        temporaryRoot: URL = AppPaths.agentWorktreeScratch.appendingPathComponent(
            "state-transfer",
            isDirectory: true
        )
    ) {
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot.standardizedFileURL
    }

    func capture(
        sourceRoot: URL,
        supplementalPaths: [String] = []
    ) async throws -> WorktreeStateSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try captureSync(sourceRoot: sourceRoot, supplementalPaths: supplementalPaths)
        }.value
    }

    func apply(
        _ snapshot: WorktreeStateSnapshot,
        destinationRoot: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try applySync(snapshot, destinationRoot: destinationRoot)
        }.value
    }

    /// Atomically, as far as Git's compare-and-swap ref primitive permits,
    /// replaces a checkout state that was captured earlier. This is the
    /// reverse-handoff primitive: unlike `apply`, the destination may be dirty,
    /// but it must still be byte-for-byte equal to `expectedCurrent` when the
    /// first mutation occurs.
    ///
    /// Only a same-commit or fast-forward transition is accepted. Supplemental
    /// files are removed only when the expected snapshot explicitly owns the
    /// path and the current inode, kind, permissions, and contents still match.
    func replace(
        expectedCurrent: WorktreeStateSnapshot,
        with desired: WorktreeStateSnapshot,
        destinationRoot: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try replaceSync(
                expectedCurrent: expectedCurrent,
                with: desired,
                destinationRoot: destinationRoot,
                permitsFastBackward: false
            )
        }.value
    }

    /// Recovery-only inverse of `replace`. The current state must still match
    /// the journaled desired snapshot exactly, and the rollback commit must be
    /// the same commit or an ancestor. This permits crash recovery to move a
    /// Local branch back without opening a general non-fast-forward API.
    func restore(
        expectedCurrent: WorktreeStateSnapshot,
        rollback: WorktreeStateSnapshot,
        destinationRoot: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try replaceSync(
                expectedCurrent: expectedCurrent,
                with: rollback,
                destinationRoot: destinationRoot,
                permitsFastBackward: true
            )
        }.value
    }

    func isEquivalent(
        _ snapshot: WorktreeStateSnapshot,
        checkoutRoot: URL
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let roots = snapshot.supplementalRoots.isEmpty
                ? snapshot.supplementalManifest.map(\.relativePath)
                : snapshot.supplementalRoots
            let current = try captureSync(
                sourceRoot: checkoutRoot,
                supplementalPaths: roots
            )
            return current.headObjectID == snapshot.headObjectID
                && current.workingTreePatch == snapshot.workingTreePatch
                && current.stagedPatch == snapshot.stagedPatch
                && current.supplementalManifest == snapshot.supplementalManifest
        }.value
    }

    private func captureSync(
        sourceRoot: URL,
        supplementalPaths: [String]
    ) throws -> WorktreeStateSnapshot {
        let root = try canonicalDirectory(sourceRoot)
        let head = try gitText(root: root, arguments: ["rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isObjectID(head) else {
            throw WorktreeStateMigrationError.notRepository(root.path)
        }
        let workingPatch = try runGit(
            root: root,
            arguments: ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
            maximumOutputBytes: Self.maximumPatchBytes
        ).stdout
        let symbolicValue = try gitText(
            root: root,
            arguments: ["rev-parse", "--symbolic-full-name", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let symbolicReference = symbolicValue.hasPrefix("refs/heads/")
            ? symbolicValue
            : nil
        let stagedPatch = try runGit(
            root: root,
            arguments: ["diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
            maximumOutputBytes: Self.maximumPatchBytes
        ).stdout
        let untrackedData = try runGit(
            root: root,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z", "--"],
            maximumOutputBytes: Self.maximumPathListBytes
        ).stdout
        let untracked = try Self.decodeNULPaths(untrackedData).filter {
            !Self.isAppleDoubleMetadataPath($0)
        }
        let explicit = try supplementalPaths.map(Self.validatedRelativePath)
        let requested = Self.orderedUnique(untracked + explicit)
        let tracked = try trackedPaths(root: root, requestedPaths: requested)
        let manifest = try collectSupplementalManifest(
            root: root,
            requestedPaths: requested,
            trackedPaths: tracked
        )
        let files = manifest.compactMap { entry -> WorktreeSupplementalFile? in
            guard entry.kind == .regularFile,
                  let data = entry.data,
                  let permissions = entry.permissions else { return nil }
            return WorktreeSupplementalFile(
                relativePath: entry.relativePath,
                data: data,
                permissions: permissions
            )
        }
        return WorktreeStateSnapshot(
            sourceRootPath: root.path,
            headObjectID: head,
            symbolicReference: symbolicReference,
            workingTreePatch: workingPatch,
            stagedPatch: stagedPatch,
            supplementalFiles: files,
            supplementalManifest: manifest,
            supplementalRoots: requested
        )
    }

    private func applySync(
        _ snapshot: WorktreeStateSnapshot,
        destinationRoot: URL
    ) throws {
        let root = try canonicalDirectory(destinationRoot)
        let status = try runGit(
            root: root,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            maximumOutputBytes: Self.maximumPathListBytes
        ).stdout
        guard try !Self.containsMeaningfulStatus(status) else {
            throw WorktreeStateMigrationError.targetNotClean(root.path)
        }
        let head = try gitText(root: root, arguments: ["rev-parse", "--verify", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == snapshot.headObjectID else {
            throw WorktreeStateMigrationError.revisionMismatch(
                source: snapshot.headObjectID,
                target: head
            )
        }

        let manifest = try validatedManifest(snapshot)
        let roots = try validatedRoots(snapshot, manifest: manifest)
        try preflightSupplementalManifest(manifest, roots: roots, root: root)

        var createdNodes: [CreatedNode] = []
        var gitMayHaveMutated = false
        do {
            if !snapshot.workingTreePatch.isEmpty {
                gitMayHaveMutated = true
                _ = try runGit(
                    root: root,
                    arguments: ["apply", "--binary", "--whitespace=nowarn", "-"],
                    standardInput: snapshot.workingTreePatch,
                    maximumOutputBytes: Self.maximumPathListBytes
                )
            }
            if !snapshot.stagedPatch.isEmpty {
                gitMayHaveMutated = true
                _ = try runGit(
                    root: root,
                    arguments: ["apply", "--cached", "--binary", "--whitespace=nowarn", "-"],
                    standardInput: snapshot.stagedPatch,
                    maximumOutputBytes: Self.maximumPathListBytes
                )
            }
            try installSupplementalManifest(
                manifest,
                root: root,
                createdNodes: &createdNodes
            )
            let verification = try captureSync(
                sourceRoot: root,
                supplementalPaths: roots
            )
            guard verification.headObjectID == snapshot.headObjectID,
                  verification.workingTreePatch == snapshot.workingTreePatch,
                  verification.stagedPatch == snapshot.stagedPatch,
                  verification.supplementalManifest == manifest else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "destination patch, index, or supplemental files differ"
                )
            }
        } catch {
            // Git was proven clean and supplemental state was fully preflighted
            // before the first mutation. Compensation resets only tracked Git
            // state and unlinks only inode identities created by this transfer.
            compensate(
                root: root,
                gitMayHaveMutated: gitMayHaveMutated,
                createdNodes: createdNodes
            )
            throw error
        }
    }

    private struct OwnedSupplementalNode {
        var entry: WorktreeSupplementalPath
        var path: String
        var device: UInt64
        var inode: UInt64
    }

    private func replaceSync(
        expectedCurrent expected: WorktreeStateSnapshot,
        with desired: WorktreeStateSnapshot,
        destinationRoot: URL,
        permitsFastBackward: Bool
    ) throws {
        let root = try canonicalDirectory(destinationRoot)
        try validateSnapshotBounds(expected)
        try validateSnapshotBounds(desired)
        let expectedManifest = try validatedManifest(expected)
        let desiredManifest = try validatedManifest(desired)
        let expectedRoots = try validatedRoots(expected, manifest: expectedManifest)
        let desiredRoots = try validatedRoots(desired, manifest: desiredManifest)
        let unionRoots = Self.orderedUnique(expectedRoots + desiredRoots)
        guard unionRoots.count <= Self.maximumSupplementalFiles else {
            throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
        }

        guard Self.isObjectID(expected.headObjectID),
              Self.isObjectID(desired.headObjectID) else {
            throw WorktreeStateMigrationError.notRepository(root.path)
        }

        // Validate both objects and the ancestry relationship before any
        // checkout, ref, index, or supplemental-path mutation.
        let resolvedExpected = try gitText(
            root: root,
            arguments: ["rev-parse", "--verify", "\(expected.headObjectID)^{commit}"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDesired = try gitText(
            root: root,
            arguments: ["rev-parse", "--verify", "\(desired.headObjectID)^{commit}"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedExpected == expected.headObjectID,
              resolvedDesired == desired.headObjectID else {
            throw WorktreeStateMigrationError.revisionMismatch(
                source: desired.headObjectID,
                target: expected.headObjectID
            )
        }
        if expected.headObjectID != desired.headObjectID {
            let ancestryIsAllowed = permitsFastBackward
                ? isAncestor(desired.headObjectID, of: expected.headObjectID, root: root)
                : isAncestor(expected.headObjectID, of: desired.headObjectID, root: root)
            guard ancestryIsAllowed else {
                throw WorktreeStateMigrationError.nonFastForward(
                    expected: expected.headObjectID,
                    desired: desired.headObjectID
                )
            }
        }

        // Capture the exact expected projection and the full union immediately
        // before mutation. The second expected capture closes the enumeration
        // window and provides the actual CAS check used by this transaction.
        let firstExpected = try captureSync(
            sourceRoot: root,
            supplementalPaths: expectedRoots
        )
        try requireExpectedSnapshot(firstExpected, equals: expected, root: root)
        let rollbackSnapshot = try captureSync(
            sourceRoot: root,
            supplementalPaths: unionRoots
        )
        let currentExpected = try captureSync(
            sourceRoot: root,
            supplementalPaths: expectedRoots
        )
        try requireExpectedSnapshot(currentExpected, equals: expected, root: root)

        let expectedByPath = Dictionary(uniqueKeysWithValues: expectedManifest.map {
            ($0.relativePath, $0)
        })
        let desiredByPath = Dictionary(uniqueKeysWithValues: desiredManifest.map {
            ($0.relativePath, $0)
        })
        let currentUnionByPath = Dictionary(uniqueKeysWithValues:
            rollbackSnapshot.supplementalManifest.map { ($0.relativePath, $0) }
        )

        // Anything already present in the union must either be owned by the
        // expected snapshot or already be exactly the desired node. This makes
        // desired-only paths collision-safe without claiming external data.
        for current in rollbackSnapshot.supplementalManifest where current.kind != .absent {
            if expectedByPath[current.relativePath] == current { continue }
            if desiredByPath[current.relativePath] == current { continue }
            throw WorktreeStateMigrationError.targetNotClean(
                "\(root.path)/\(current.relativePath)"
            )
        }
        for desiredEntry in desiredManifest where desiredEntry.kind == .absent {
            if let current = currentUnionByPath[desiredEntry.relativePath],
               current.kind != .absent,
               expectedByPath[desiredEntry.relativePath] != current {
                throw WorktreeStateMigrationError.targetNotClean(
                    "\(root.path)/\(desiredEntry.relativePath)"
                )
            }
        }

        var ownedNodes: [String: OwnedSupplementalNode] = [:]
        for entry in expectedManifest where entry.kind != .absent {
            ownedNodes[entry.relativePath] = try captureOwnedNode(
                entry,
                root: root
            )
        }
        let finalUnion = try captureSync(
            sourceRoot: root,
            supplementalPaths: unionRoots
        )
        guard finalUnion.fingerprint == rollbackSnapshot.fingerprint,
              finalUnion.symbolicReference == rollbackSnapshot.symbolicReference else {
            throw WorktreeStateMigrationError.verificationFailed(
                "destination changed during state-replacement preflight"
            )
        }

        let removals = expectedManifest.filter { entry in
            entry.kind != .absent && desiredByPath[entry.relativePath] != entry
        }
        var createdNodes: [CreatedNode] = []
        var refAdvanced = false
        do {
            try removeOwnedSupplementalNodes(
                removals,
                ownedNodes: ownedNodes,
                root: root
            )

            if expected.headObjectID != desired.headObjectID {
                try updateCheckoutReference(
                    symbolicReference: expected.symbolicReference,
                    from: expected.headObjectID,
                    to: desired.headObjectID,
                    root: root
                )
                refAdvanced = true
            }
            try requireCurrentHEAD(desired.headObjectID, root: root)
            _ = try runGit(
                root: root,
                arguments: ["reset", "--hard"],
                maximumOutputBytes: Self.maximumPathListBytes
            )
            try applyTrackedState(desired, root: root)
            try installSupplementalManifest(
                desiredManifest,
                root: root,
                createdNodes: &createdNodes
            )
            try verifyReplacement(
                desired,
                desiredManifest: desiredManifest,
                desiredRoots: desiredRoots,
                unionRoots: unionRoots,
                root: root
            )
        } catch {
            let originalError = error
            do {
                try removeTransactionCreatedNodes(
                    createdNodes,
                    installedManifest: desiredByPath,
                    root: root
                )
                if refAdvanced {
                    try updateCheckoutReference(
                        symbolicReference: expected.symbolicReference,
                        from: desired.headObjectID,
                        to: expected.headObjectID,
                        root: root
                    )
                }
                try requireCurrentHEAD(expected.headObjectID, root: root)
                _ = try runGit(
                    root: root,
                    arguments: ["reset", "--hard"],
                    maximumOutputBytes: Self.maximumPathListBytes
                )
                try installSupplementalManifest(
                    expectedManifest,
                    root: root,
                    createdNodes: &createdNodes
                )
                try applyTrackedState(expected, root: root)
                let restored = try captureSync(
                    sourceRoot: root,
                    supplementalPaths: unionRoots
                )
                guard restored.fingerprint == rollbackSnapshot.fingerprint,
                      restored.symbolicReference == rollbackSnapshot.symbolicReference else {
                    throw WorktreeStateMigrationError.verificationFailed(
                        "rollback snapshot differs after compensation"
                    )
                }
            } catch let rollbackError {
                throw WorktreeStateMigrationError.verificationFailed(
                    "replacement failed (\(originalError.localizedDescription)); "
                        + "rollback failed (\(rollbackError.localizedDescription))"
                )
            }
            throw originalError
        }
    }

    private func validateSnapshotBounds(_ snapshot: WorktreeStateSnapshot) throws {
        guard snapshot.workingTreePatch.count <= Self.maximumPatchBytes,
              snapshot.stagedPatch.count <= Self.maximumPatchBytes else {
            throw WorktreeStateMigrationError.outputTooLarge(Self.maximumPatchBytes)
        }
    }

    private func requireExpectedSnapshot(
        _ current: WorktreeStateSnapshot,
        equals expected: WorktreeStateSnapshot,
        root: URL
    ) throws {
        guard current.fingerprint == expected.fingerprint,
              current.headObjectID == expected.headObjectID,
              current.symbolicReference == expected.symbolicReference else {
            throw WorktreeStateMigrationError.verificationFailed(
                "destination no longer matches expected snapshot at \(root.path)"
            )
        }
    }

    private func isAncestor(_ ancestor: String, of descendant: String, root: URL) -> Bool {
        do {
            let mergeBase = try gitText(
                root: root,
                arguments: ["merge-base", ancestor, descendant]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return mergeBase == ancestor
        } catch {
            // An unreadable or unrelated graph is never permission to mutate.
            return false
        }
    }

    private func requireCurrentHEAD(_ expected: String, root: URL) throws {
        let current = try gitText(
            root: root,
            arguments: ["rev-parse", "--verify", "HEAD"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == expected else {
            throw WorktreeStateMigrationError.verificationFailed(
                "HEAD changed concurrently (expected \(expected), found \(current))"
            )
        }
    }

    private func updateCheckoutReference(
        symbolicReference: String?,
        from oldObjectID: String,
        to newObjectID: String,
        root: URL
    ) throws {
        if let symbolicReference {
            guard symbolicReference.hasPrefix("refs/heads/"),
                  !symbolicReference.contains("\0") else {
                throw WorktreeStateMigrationError.unsafePath(symbolicReference)
            }
            _ = try runGit(
                root: root,
                arguments: [
                    "update-ref",
                    symbolicReference,
                    newObjectID,
                    oldObjectID
                ],
                maximumOutputBytes: Self.maximumPathListBytes
            )
        } else {
            // --no-deref makes the detached-HEAD contract explicit and avoids
            // accidentally advancing a branch if HEAD changed concurrently.
            _ = try runGit(
                root: root,
                arguments: [
                    "update-ref",
                    "--no-deref",
                    "HEAD",
                    newObjectID,
                    oldObjectID
                ],
                maximumOutputBytes: Self.maximumPathListBytes
            )
        }
    }

    private func applyTrackedState(
        _ snapshot: WorktreeStateSnapshot,
        root: URL
    ) throws {
        if !snapshot.workingTreePatch.isEmpty {
            _ = try runGit(
                root: root,
                arguments: ["apply", "--binary", "--whitespace=nowarn", "-"],
                standardInput: snapshot.workingTreePatch,
                maximumOutputBytes: Self.maximumPathListBytes
            )
        }
        if !snapshot.stagedPatch.isEmpty {
            _ = try runGit(
                root: root,
                arguments: ["apply", "--cached", "--binary", "--whitespace=nowarn", "-"],
                standardInput: snapshot.stagedPatch,
                maximumOutputBytes: Self.maximumPathListBytes
            )
        }
    }

    private func captureOwnedNode(
        _ entry: WorktreeSupplementalPath,
        root: URL
    ) throws -> OwnedSupplementalNode {
        guard entry.kind != .absent else {
            throw WorktreeStateMigrationError.verificationFailed(
                "an absent path cannot be recorded as owned"
            )
        }
        let relative = try Self.validatedRelativePath(entry.relativePath)
        try validateExistingParentComponents(root: root, relativePath: relative)
        let url = root.appendingPathComponent(relative).standardizedFileURL
        guard Self.isAtOrBelow(url, root) else {
            throw WorktreeStateMigrationError.unsafePath(relative)
        }
        var before = Darwin.stat()
        guard Darwin.lstat(url.path, &before) == 0 else {
            throw WorktreeStateMigrationError.verificationFailed(
                "owned path disappeared: \(relative)"
            )
        }
        guard try inspectSupplementalPath(root: root, relativePath: relative) == entry else {
            throw WorktreeStateMigrationError.verificationFailed(
                "owned path changed: \(relative)"
            )
        }
        var after = Darwin.stat()
        guard Darwin.lstat(url.path, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode & S_IFMT == after.st_mode & S_IFMT else {
            throw WorktreeStateMigrationError.verificationFailed(
                "owned path identity changed: \(relative)"
            )
        }
        return OwnedSupplementalNode(
            entry: entry,
            path: url.path,
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino)
        )
    }

    private func removeOwnedSupplementalNodes(
        _ entries: [WorktreeSupplementalPath],
        ownedNodes: [String: OwnedSupplementalNode],
        root: URL
    ) throws {
        let ordered = entries.sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            if $0.kind != $1.kind { return $0.kind == .regularFile }
            return $0.relativePath > $1.relativePath
        }
        for entry in ordered {
            guard let owned = ownedNodes[entry.relativePath] else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "refusing to remove an unowned supplemental node: \(entry.relativePath)"
                )
            }
            try validateExistingParentComponents(
                root: root,
                relativePath: entry.relativePath
            )
            var info = Darwin.stat()
            guard Darwin.lstat(owned.path, &info) == 0,
                  UInt64(info.st_dev) == owned.device,
                  UInt64(info.st_ino) == owned.inode,
                  try inspectSupplementalPath(
                    root: root,
                    relativePath: entry.relativePath
                  ) == owned.entry else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "owned supplemental node changed before removal: \(entry.relativePath)"
                )
            }
            let result: Int32
            switch entry.kind {
            case .regularFile:
                guard info.st_mode & S_IFMT == S_IFREG else {
                    throw WorktreeStateMigrationError.unsafePath(entry.relativePath)
                }
                result = Darwin.unlink(owned.path)
            case .directory:
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorktreeStateMigrationError.unsafePath(entry.relativePath)
                }
                // Deliberately non-recursive. A new child from another actor
                // turns this into a safe failure rather than external deletion.
                result = Darwin.rmdir(owned.path)
            case .absent:
                continue
            }
            guard result == 0 else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "unable to remove owned supplemental node: \(entry.relativePath)"
                )
            }
        }
    }

    private func removeTransactionCreatedNodes(
        _ nodes: [CreatedNode],
        installedManifest: [String: WorktreeSupplementalPath],
        root: URL
    ) throws {
        for node in nodes.sorted(by: {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }) {
            var info = Darwin.stat()
            guard Darwin.lstat(node.path, &info) == 0 else {
                if errno == ENOENT { continue }
                throw WorktreeStateMigrationError.verificationFailed(
                    "cannot inspect transaction-created node: \(node.path)"
                )
            }
            guard UInt64(info.st_dev) == node.device,
                  UInt64(info.st_ino) == node.inode else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "transaction-created node was replaced: \(node.path)"
                )
            }
            let relative = String(node.path.dropFirst(root.path.count + 1))
            switch node.kind {
            case .regularFile:
                guard let installed = installedManifest[relative],
                      installed.kind == .regularFile,
                      try inspectSupplementalPath(
                        root: root,
                        relativePath: relative
                      ) == installed else {
                    throw WorktreeStateMigrationError.verificationFailed(
                        "transaction-created file changed: \(relative)"
                    )
                }
                guard Darwin.unlink(node.path) == 0 else {
                    throw WorktreeStateMigrationError.verificationFailed(
                        "cannot remove transaction-created file: \(relative)"
                    )
                }
            case .directory:
                guard info.st_mode & S_IFMT == S_IFDIR,
                      Darwin.rmdir(node.path) == 0 else {
                    throw WorktreeStateMigrationError.verificationFailed(
                        "transaction-created directory is no longer empty: \(relative)"
                    )
                }
            case .absent:
                break
            }
        }
    }

    private func verifyReplacement(
        _ desired: WorktreeStateSnapshot,
        desiredManifest: [WorktreeSupplementalPath],
        desiredRoots: [String],
        unionRoots: [String],
        root: URL
    ) throws {
        let desiredCapture = try captureSync(
            sourceRoot: root,
            supplementalPaths: desiredRoots
        )
        guard desiredCapture.fingerprint == desired.fingerprint,
              desiredCapture.headObjectID == desired.headObjectID else {
            throw WorktreeStateMigrationError.verificationFailed(
                "destination does not equal desired snapshot"
            )
        }

        let desiredByPath = Dictionary(uniqueKeysWithValues: desiredManifest.map {
            ($0.relativePath, $0)
        })
        let unionCapture = try captureSync(
            sourceRoot: root,
            supplementalPaths: unionRoots
        )
        guard unionCapture.headObjectID == desired.headObjectID,
              unionCapture.workingTreePatch == desired.workingTreePatch,
              unionCapture.stagedPatch == desired.stagedPatch else {
            throw WorktreeStateMigrationError.verificationFailed(
                "union verification found different Git state"
            )
        }
        for entry in unionCapture.supplementalManifest where entry.kind != .absent {
            guard desiredByPath[entry.relativePath] == entry else {
                throw WorktreeStateMigrationError.verificationFailed(
                    "unexpected supplemental node after replacement: \(entry.relativePath)"
                )
            }
        }
        for entry in desiredManifest where entry.kind == .absent {
            if let current = unionCapture.supplementalManifest.first(where: {
                $0.relativePath == entry.relativePath
            }), current.kind != .absent {
                throw WorktreeStateMigrationError.verificationFailed(
                    "supplemental tombstone was not preserved: \(entry.relativePath)"
                )
            }
        }
    }

    private func trackedPaths(
        root: URL,
        requestedPaths: [String]
    ) throws -> Set<String> {
        let paths = try Self.orderedUnique(requestedPaths.map(Self.validatedRelativePath))
        guard paths.count <= Self.maximumSupplementalFiles else {
            throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
        }
        guard !paths.isEmpty else { return [] }

        // Query each requested path and all of its non-root ancestors. A newly
        // discovered untracked file such as `Sources/New.swift` must still
        // reveal tracked siblings below `Sources`; otherwise that existing
        // Git-owned directory could be mistaken for a transaction-created
        // supplemental node during rollback.
        let queryPaths = Self.orderedUnique(paths.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { return [path] }
            var result = [path]
            var prefix: [String] = []
            for component in components.dropLast() {
                prefix.append(component)
                result.append(prefix.joined(separator: "/"))
            }
            return result
        })
        let argumentBytes = queryPaths.reduce(0) { partial, path in
            partial + path.utf8.count + 12
        }
        guard argumentBytes <= Self.maximumPathListBytes else {
            throw WorktreeStateMigrationError.outputTooLarge(Self.maximumPathListBytes)
        }
        let pathspecs = queryPaths.map { ":(literal)\($0)" }
        let indexData = try runGit(
            root: root,
            arguments: ["ls-files", "-z", "--"] + pathspecs,
            maximumOutputBytes: Self.maximumPathListBytes
        ).stdout
        let headData = try runGit(
            root: root,
            arguments: ["ls-tree", "-r", "--name-only", "-z", "HEAD", "--"] + pathspecs,
            maximumOutputBytes: Self.maximumPathListBytes
        ).stdout
        // A staged deletion is no longer present in the index but remains
        // Git-owned by HEAD. Treating its retained working-tree file as
        // supplemental would make apply collide with an existing tracked file.
        return Set(try Self.decodeNULPaths(indexData))
            .union(try Self.decodeNULPaths(headData))
    }

    private func collectSupplementalManifest(
        root: URL,
        requestedPaths: [String],
        trackedPaths: Set<String>
    ) throws -> [WorktreeSupplementalPath] {
        var result: [WorktreeSupplementalPath] = []
        var seen = Set<String>()
        var totalBytes = 0

        func append(_ entry: WorktreeSupplementalPath) throws {
            let relativePath = entry.relativePath
            guard seen.insert(relativePath).inserted else { return }
            guard result.count < Self.maximumSupplementalFiles else {
                throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
            }
            if let data = entry.data {
                guard data.count <= Self.maximumSupplementalBytes,
                      totalBytes <= Self.maximumSupplementalBytes - data.count else {
                    throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
                }
                totalBytes += data.count
            }
            result.append(entry)
        }

        func isTracked(_ relativePath: String, includeDescendants: Bool) -> Bool {
            if trackedPaths.contains(relativePath) { return true }
            guard includeDescendants else { return false }
            return trackedPaths.contains { $0.hasPrefix(relativePath + "/") }
        }

        /// Preserve ancestor-directory state explicitly. A nested untracked
        /// file alone does not reveal whether its parents pre-existed at the
        /// destination, which makes a later transactional rollback ambiguous.
        func appendParentDirectories(of rawRelative: String) throws {
            let relative = try Self.validatedRelativePath(rawRelative)
            let components = relative.split(separator: "/").map(String.init)
            guard components.count > 1 else { return }
            var prefix: [String] = []
            for component in components.dropLast() {
                prefix.append(component)
                let parentRelative = prefix.joined(separator: "/")
                // A directory containing tracked descendants is recreated by
                // the same Git commit and is never transaction-owned.
                if isTracked(parentRelative, includeDescendants: true) { continue }
                try validateExistingParentComponents(
                    root: root,
                    relativePath: parentRelative
                )
                let candidate = root.appendingPathComponent(
                    parentRelative,
                    isDirectory: true
                ).standardizedFileURL
                var info = Darwin.stat()
                guard Darwin.lstat(candidate.path, &info) == 0 else {
                    if errno == ENOENT { return }
                    throw WorktreeStateMigrationError.unsupportedFile(parentRelative)
                }
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    if info.st_mode & S_IFMT == S_IFLNK {
                        throw WorktreeStateMigrationError.unsafePath(parentRelative)
                    }
                    throw WorktreeStateMigrationError.unsupportedFile(parentRelative)
                }
                try append(WorktreeSupplementalPath(
                    relativePath: parentRelative,
                    kind: .directory,
                    data: nil,
                    permissions: Int(info.st_mode & 0o777)
                ))
            }
        }

        func walk(_ relative: String) throws {
            let relative = try Self.validatedRelativePath(relative)
            try validateExistingParentComponents(root: root, relativePath: relative)
            let candidate = root.appendingPathComponent(relative, isDirectory: false)
                .standardizedFileURL
            guard Self.isAtOrBelow(candidate, root) else {
                throw WorktreeStateMigrationError.unsafePath(relative)
            }
            var info = Darwin.stat()
            guard Darwin.lstat(candidate.path, &info) == 0 else {
                if errno == ENOENT {
                    guard !isTracked(relative, includeDescendants: true) else { return }
                    try append(WorktreeSupplementalPath(
                        relativePath: relative,
                        kind: .absent,
                        data: nil,
                        permissions: nil
                    ))
                    return
                }
                throw WorktreeStateMigrationError.unsupportedFile(relative)
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard !isTracked(relative, includeDescendants: false) else { return }
                let size = max(0, Int(info.st_size))
                guard size <= Self.maximumSupplementalBytes else {
                    throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
                }
                let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
                guard data.count == size else {
                    throw WorktreeStateMigrationError.unsupportedFile(relative)
                }
                try append(WorktreeSupplementalPath(
                    relativePath: relative,
                    kind: .regularFile,
                    data: data,
                    permissions: Int(info.st_mode & 0o777)
                ))
            case S_IFDIR:
                try append(WorktreeSupplementalPath(
                    relativePath: relative,
                    kind: .directory,
                    data: nil,
                    permissions: Int(info.st_mode & 0o777)
                ))
                // Do not use FileManager's package-skipping enumerator here.
                // Each directory read must either succeed or abort the capture.
                let children = try fileManager.contentsOfDirectory(
                    at: candidate,
                    includingPropertiesForKeys: nil,
                    options: []
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    if Self.isAppleDoubleMetadataComponent(child.lastPathComponent) {
                        continue
                    }
                    let childURL = child.standardizedFileURL
                    guard Self.isAtOrBelow(childURL, root),
                          childURL.path.hasPrefix(candidate.path + "/") else {
                        throw WorktreeStateMigrationError.unsafePath(child.path)
                    }
                    let childRelative = String(childURL.path.dropFirst(root.path.count + 1))
                    try walk(childRelative)
                }
            case S_IFLNK:
                throw WorktreeStateMigrationError.unsafePath(relative)
            default:
                throw WorktreeStateMigrationError.unsupportedFile(relative)
            }
        }

        for rawPath in requestedPaths {
            try appendParentDirectories(of: rawPath)
            try walk(rawPath)
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func preflightSupplementalManifest(
        _ manifest: [WorktreeSupplementalPath],
        roots: [String],
        root: URL
    ) throws {
        let tracked = try trackedPaths(root: root, requestedPaths: roots)
        let current = try collectSupplementalManifest(
            root: root,
            requestedPaths: roots,
            trackedPaths: tracked
        )
        let expectedByPath = Dictionary(uniqueKeysWithValues: manifest.map {
            ($0.relativePath, $0)
        })
        let currentByPath = Dictionary(uniqueKeysWithValues: current.map {
            ($0.relativePath, $0)
        })

        for currentEntry in current where currentEntry.kind != .absent {
            guard let expected = expectedByPath[currentEntry.relativePath],
                  expected == currentEntry else {
                throw WorktreeStateMigrationError.targetNotClean(
                    "\(root.path)/\(currentEntry.relativePath)"
                )
            }
        }
        for expected in manifest where expected.kind == .absent {
            if let currentEntry = currentByPath[expected.relativePath],
               currentEntry.kind != .absent {
                throw WorktreeStateMigrationError.targetNotClean(
                    "\(root.path)/\(expected.relativePath)"
                )
            }
        }

        // A manifest child can be absent even when its requested parent exists;
        // validate every parent chain explicitly instead of trusting enumeration.
        for expected in manifest {
            try validateExistingParentComponents(
                root: root,
                relativePath: expected.relativePath
            )
        }
    }

    private struct CreatedNode {
        var path: String
        var device: UInt64
        var inode: UInt64
        var kind: WorktreeSupplementalPathKind
    }

    private func installSupplementalManifest(
        _ manifest: [WorktreeSupplementalPath],
        root: URL,
        createdNodes: inout [CreatedNode]
    ) throws {
        let ordered = manifest.sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.relativePath < $1.relativePath
        }
        for entry in ordered {
            let existing = try inspectSupplementalPath(
                root: root,
                relativePath: entry.relativePath
            )
            if let existing {
                guard existing == entry else {
                    throw WorktreeStateMigrationError.targetNotClean(
                        "\(root.path)/\(entry.relativePath)"
                    )
                }
                continue
            }
            guard entry.kind != .absent else { continue }
            try createParentDirectories(
                root: root,
                relativePath: entry.relativePath,
                createdNodes: &createdNodes
            )
            let destination = root.appendingPathComponent(entry.relativePath).standardizedFileURL
            switch entry.kind {
            case .absent:
                break
            case .directory:
                guard let permissions = entry.permissions else {
                    throw WorktreeStateMigrationError.unsupportedFile(entry.relativePath)
                }
                try createDirectory(
                    destination,
                    permissions: permissions,
                    createdNodes: &createdNodes
                )
            case .regularFile:
                guard let data = entry.data,
                      let permissions = entry.permissions else {
                    throw WorktreeStateMigrationError.unsupportedFile(entry.relativePath)
                }
                try createRegularFile(
                    destination,
                    data: data,
                    permissions: permissions,
                    createdNodes: &createdNodes
                )
            }
        }
    }

    private func validatedManifest(
        _ snapshot: WorktreeStateSnapshot
    ) throws -> [WorktreeSupplementalPath] {
        let manifest = snapshot.supplementalManifest
        var seen = Set<String>()
        var totalBytes = 0
        guard manifest.count <= Self.maximumSupplementalFiles else {
            throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
        }
        for entry in manifest {
            let relative = try Self.validatedRelativePath(entry.relativePath)
            guard relative == entry.relativePath,
                  seen.insert(relative).inserted else {
                throw WorktreeStateMigrationError.unsafePath(entry.relativePath)
            }
            switch entry.kind {
            case .absent:
                guard entry.data == nil, entry.permissions == nil else {
                    throw WorktreeStateMigrationError.unsupportedFile(relative)
                }
            case .directory:
                guard entry.data == nil,
                      let permissions = entry.permissions,
                      (0...0o777).contains(permissions) else {
                    throw WorktreeStateMigrationError.unsupportedFile(relative)
                }
            case .regularFile:
                guard let data = entry.data,
                      let permissions = entry.permissions,
                      (0...0o777).contains(permissions),
                      data.count <= Self.maximumSupplementalBytes,
                      totalBytes <= Self.maximumSupplementalBytes - data.count else {
                    throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
                }
                totalBytes += data.count
            }
        }
        let normalized = manifest.sorted { $0.relativePath < $1.relativePath }
        let files = normalized.compactMap { entry -> WorktreeSupplementalFile? in
            guard entry.kind == .regularFile,
                  let data = entry.data,
                  let permissions = entry.permissions else { return nil }
            return WorktreeSupplementalFile(
                relativePath: entry.relativePath,
                data: data,
                permissions: permissions
            )
        }
        guard files == snapshot.supplementalFiles.sorted(by: {
            $0.relativePath < $1.relativePath
        }) else {
            throw WorktreeStateMigrationError.verificationFailed(
                "supplemental file list and explicit manifest disagree"
            )
        }
        return normalized
    }

    private func validatedRoots(
        _ snapshot: WorktreeStateSnapshot,
        manifest: [WorktreeSupplementalPath]
    ) throws -> [String] {
        let rawRoots = snapshot.supplementalRoots.isEmpty
            ? manifest.map(\.relativePath)
            : snapshot.supplementalRoots
        let roots = try Self.orderedUnique(rawRoots.map(Self.validatedRelativePath))
        guard roots.count == rawRoots.count,
              roots.count <= Self.maximumSupplementalFiles else {
            throw WorktreeStateMigrationError.unsafePath("duplicate or excessive supplemental roots")
        }
        for entry in manifest {
            guard roots.contains(where: {
                entry.relativePath == $0 || entry.relativePath.hasPrefix($0 + "/")
            }) else {
                throw WorktreeStateMigrationError.unsafePath(entry.relativePath)
            }
        }
        return roots
    }

    private func inspectSupplementalPath(
        root: URL,
        relativePath: String
    ) throws -> WorktreeSupplementalPath? {
        let relative = try Self.validatedRelativePath(relativePath)
        try validateExistingParentComponents(root: root, relativePath: relative)
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard Self.isAtOrBelow(candidate, root) else {
            throw WorktreeStateMigrationError.unsafePath(relative)
        }
        var info = Darwin.stat()
        guard Darwin.lstat(candidate.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw WorktreeStateMigrationError.unsupportedFile(relative)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return WorktreeSupplementalPath(
                relativePath: relative,
                kind: .directory,
                data: nil,
                permissions: Int(info.st_mode & 0o777)
            )
        case S_IFREG:
            let size = max(0, Int(info.st_size))
            guard size <= Self.maximumSupplementalBytes else {
                throw WorktreeStateMigrationError.transferTooLarge(Self.maximumSupplementalBytes)
            }
            let data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
            guard data.count == size else {
                throw WorktreeStateMigrationError.unsupportedFile(relative)
            }
            return WorktreeSupplementalPath(
                relativePath: relative,
                kind: .regularFile,
                data: data,
                permissions: Int(info.st_mode & 0o777)
            )
        default:
            throw WorktreeStateMigrationError.unsafePath(relative)
        }
    }

    private func validateExistingParentComponents(
        root: URL,
        relativePath: String
    ) throws {
        let relative = try Self.validatedRelativePath(relativePath)
        let components = relative.split(separator: "/").map(String.init)
        var cursor = root
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard Self.isAtOrBelow(cursor.standardizedFileURL, root) else {
                throw WorktreeStateMigrationError.unsafePath(relative)
            }
            var info = Darwin.stat()
            if Darwin.lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorktreeStateMigrationError.unsafePath(relative)
                }
            } else if errno == ENOENT {
                // Descendants cannot exist below a genuinely missing parent.
                return
            } else {
                throw WorktreeStateMigrationError.unsafePath(relative)
            }
        }
    }

    private func createParentDirectories(
        root: URL,
        relativePath: String,
        createdNodes: inout [CreatedNode]
    ) throws {
        let relative = try Self.validatedRelativePath(relativePath)
        let components = relative.split(separator: "/").map(String.init)
        var cursor = root
        for component in components.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard Self.isAtOrBelow(cursor.standardizedFileURL, root) else {
                throw WorktreeStateMigrationError.unsafePath(relative)
            }
            var info = Darwin.stat()
            if Darwin.lstat(cursor.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorktreeStateMigrationError.unsafePath(relative)
                }
                continue
            }
            guard errno == ENOENT else {
                throw WorktreeStateMigrationError.unsafePath(relative)
            }
            try createDirectory(
                cursor,
                permissions: 0o755,
                createdNodes: &createdNodes
            )
        }
    }

    private func createDirectory(
        _ url: URL,
        permissions: Int,
        createdNodes: inout [CreatedNode]
    ) throws {
        guard Darwin.mkdir(url.path, mode_t(permissions)) == 0 else {
            throw WorktreeStateMigrationError.targetNotClean(url.path)
        }
        try recordCreatedNode(url, kind: .directory, into: &createdNodes)
        guard Darwin.chmod(url.path, mode_t(permissions)) == 0 else {
            throw WorktreeStateMigrationError.unsupportedFile(url.path)
        }
    }

    private func createRegularFile(
        _ url: URL,
        data: Data,
        permissions: Int,
        createdNodes: inout [CreatedNode]
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(permissions)
        )
        guard descriptor >= 0 else {
            throw WorktreeStateMigrationError.targetNotClean(url.path)
        }
        try recordCreatedNode(url, kind: .regularFile, into: &createdNodes)
        defer { _ = Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw WorktreeStateMigrationError.unsupportedFile(url.path)
                }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw WorktreeStateMigrationError.unsupportedFile(url.path)
                }
                offset += written
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(permissions)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw WorktreeStateMigrationError.unsupportedFile(url.path)
        }
    }

    private func recordCreatedNode(
        _ url: URL,
        kind: WorktreeSupplementalPathKind,
        into nodes: inout [CreatedNode]
    ) throws {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw WorktreeStateMigrationError.unsupportedFile(url.path)
        }
        let expectedKind = kind == .directory ? S_IFDIR : S_IFREG
        guard info.st_mode & S_IFMT == expectedKind else {
            throw WorktreeStateMigrationError.unsafePath(url.path)
        }
        nodes.append(CreatedNode(
            path: url.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            kind: kind
        ))
    }

    private func compensate(
        root: URL,
        gitMayHaveMutated: Bool,
        createdNodes: [CreatedNode]
    ) {
        if gitMayHaveMutated {
            _ = try? runGit(
                root: root,
                arguments: ["reset", "--hard", "HEAD"],
                maximumOutputBytes: Self.maximumPathListBytes
            )
        }
        for node in createdNodes.sorted(by: {
            $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
        }) {
            var info = Darwin.stat()
            guard Darwin.lstat(node.path, &info) == 0,
                  UInt64(info.st_dev) == node.device,
                  UInt64(info.st_ino) == node.inode else { continue }
            switch node.kind {
            case .regularFile:
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                _ = Darwin.unlink(node.path)
            case .directory:
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                // rmdir is deliberately non-recursive: data created by another
                // actor after preflight must never be erased by compensation.
                _ = Darwin.rmdir(node.path)
            case .absent:
                break
            }
        }
    }

    private func gitText(root: URL, arguments: [String]) throws -> String {
        let data = try runGit(
            root: root,
            arguments: arguments,
            maximumOutputBytes: Self.maximumPathListBytes
        ).stdout
        guard let value = String(data: data, encoding: .utf8) else {
            throw WorktreeStateMigrationError.commandFailed("Git output is not UTF-8")
        }
        return value
    }

    private func runGit(
        root: URL,
        arguments: [String],
        standardInput: Data? = nil,
        maximumOutputBytes: Int
    ) throws -> (stdout: Data, stderr: Data) {
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let invocationRoot = temporaryRoot
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: invocationRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: invocationRoot) }
        let stdoutURL = invocationRoot.appendingPathComponent("stdout")
        let stderrURL = invocationRoot.appendingPathComponent("stderr")
        let stdinURL = invocationRoot.appendingPathComponent("stdin")
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw WorktreeStateMigrationError.commandFailed("unable to create bounded output files")
        }
        if let standardInput {
            try standardInput.write(to: stdinURL, options: .atomic)
        }
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let stdinHandle = standardInput == nil ? nil : try FileHandle(forReadingFrom: stdinURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? stdinHandle?.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "-c", "core.fsmonitor=false",
            "-C", root.path
        ] + arguments
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
            "TMPDIR": temporaryRoot.path
        ]
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = stdinHandle ?? FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.synchronize()
            try stderrHandle.synchronize()
        } catch {
            throw WorktreeStateMigrationError.commandFailed(error.localizedDescription)
        }
        let stdout = try boundedRead(stdoutURL, maximumBytes: maximumOutputBytes)
        let stderr = try boundedRead(stderrURL, maximumBytes: min(maximumOutputBytes, 1 * 1_024 * 1_024))
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr.prefix(16 * 1_024), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeStateMigrationError.commandFailed(
                detail.isEmpty ? "git exited \(process.terminationStatus)" : detail
            )
        }
        return (stdout, stderr)
    }

    private func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw WorktreeStateMigrationError.outputTooLarge(maximumBytes)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw WorktreeStateMigrationError.outputTooLarge(maximumBytes)
        }
        return data
    }

    private func canonicalDirectory(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL
        var info = Darwin.stat()
        guard canonical.path != "/",
              Darwin.lstat(canonical.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw WorktreeStateMigrationError.notRepository(url.path)
        }
        return canonical
    }

    private static func validatedRelativePath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\0") else {
            throw WorktreeStateMigrationError.unsafePath(raw)
        }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.lowercased() != ".git"
        }) else {
            throw WorktreeStateMigrationError.unsafePath(raw)
        }
        return raw
    }

    private static func decodeNULPaths(_ data: Data) throws -> [String] {
        if data.isEmpty { return [] }
        guard data.isEmpty || data.last == 0 else {
            throw WorktreeStateMigrationError.commandFailed("unterminated Git path list")
        }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if data.last == 0 { fields.removeLast() }
        guard fields.count <= maximumSupplementalFiles else {
            throw WorktreeStateMigrationError.transferTooLarge(maximumSupplementalBytes)
        }
        return try fields.map {
            guard let path = String(data: Data($0), encoding: .utf8) else {
                throw WorktreeStateMigrationError.unsafePath("non-UTF-8 Git path")
            }
            return try validatedRelativePath(path)
        }
    }

    /// AppleDouble sidecars are filesystem implementation details generated
    /// on non-APFS volumes. They are never Task-owned untracked content and
    /// must not make a logically clean checkout dirty or enter a handoff.
    private static func isAppleDoubleMetadataComponent(_ component: String) -> Bool {
        component.hasPrefix("._")
    }

    private static func isAppleDoubleMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains {
            isAppleDoubleMetadataComponent(String($0))
        }
    }

    private static func containsMeaningfulStatus(_ data: Data) throws -> Bool {
        if data.isEmpty { return false }
        guard data.isEmpty || data.last == 0 else {
            throw WorktreeStateMigrationError.commandFailed("unterminated Git status output")
        }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if data.last == 0 { fields.removeLast() }
        for field in fields {
            guard field.count >= 3,
                  let record = String(data: Data(field), encoding: .utf8) else {
                throw WorktreeStateMigrationError.commandFailed("malformed Git status output")
            }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            if status == "??", isAppleDoubleMetadataPath(path) {
                continue
            }
            return true
        }
        return false
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (40...64).contains(value.count)
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private static func isAtOrBelow(_ candidate: URL, _ root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
