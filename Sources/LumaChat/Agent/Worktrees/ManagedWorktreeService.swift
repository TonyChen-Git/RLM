import Darwin
import Foundation

actor ManagedWorktreeService {
    private struct SourceContext: Sendable {
        var repositoryRoot: URL
        var sourceCheckout: URL
        var headObjectID: String
    }

    private struct WorktreeListEntry: Sendable {
        var path: String
        var headObjectID: String?
        var branchName: String?
    }

    private enum LeafState: Equatable {
        case missing
        case directory
        case symbolicLink
        case other
    }

    private let registry: any WorktreeRegistryPersisting
    private let managedRoot: URL
    private let runner: any WorktreeCommandRunning
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Date
    private let conflictResolver = WorktreeConflictResolver()

    // Actor reentrancy would otherwise allow two Git mutations to overlap at
    // an `await`. This small FIFO gate serializes lifecycle transactions while
    // still keeping Process execution off the actor's executor.
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        registry: any WorktreeRegistryPersisting = WorktreeRegistry(),
        managedRoot: URL = AppPaths.managedWorktrees,
        runner: any WorktreeCommandRunning = ProcessWorktreeCommandRunner(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.managedRoot = managedRoot.standardizedFileURL
        self.runner = runner
        self.fileManager = fileManager
        nowProvider = now
    }

    func create(
        repositoryRoot: URL,
        taskID: UUID,
        options: ManagedWorktreeCreateOptions = ManagedWorktreeCreateOptions()
    ) async throws -> ManagedWorktreeRecord {
        await beginOperation()
        defer { endOperation() }
        return try await createLocked(
            repositoryRoot: repositoryRoot,
            taskID: taskID,
            options: options
        )
    }

    func reuse(id: UUID, taskID: UUID) async throws -> ManagedWorktreeRecord {
        await beginOperation()
        defer { endOperation() }

        var record = try await requiredRecord(id: id)
        guard record.state != .orphaned, record.state != .removalPending else {
            throw ManagedWorktreeError.unavailableWorktree(id, record.state)
        }
        let inspection = await inspectRecord(record)
        apply(inspection: inspection, to: &record)
        try await registry.save(record)
        guard inspection.state == .ready else {
            throw ManagedWorktreeError.unavailableWorktree(id, inspection.state)
        }
        if record.lease == nil, inspection.isClean != true {
            throw ManagedWorktreeError.dirtyWorktree(id)
        }

        let timestamp = nowProvider()
        record.lease = try conflictResolver.lease(
            existing: record.lease,
            worktreeID: record.id,
            taskID: taskID,
            now: timestamp
        )
        record.updatedAt = max(record.updatedAt, timestamp)
        try await registry.save(record)
        return record
    }

    func release(_ lease: WorktreeLease) async throws -> ManagedWorktreeRecord {
        await beginOperation()
        defer { endOperation() }

        var record = try await requiredRecord(id: lease.worktreeID)
        try conflictResolver.validateRemovalLease(record: record, provided: lease)
        record.lease = nil
        record.updatedAt = max(record.updatedAt, nowProvider())
        try await registry.save(record)
        return record
    }

    func list() async throws -> [ManagedWorktreeRecord] {
        await beginOperation()
        defer { endOperation() }
        return try await registry.list()
    }

    func inspect(id: UUID) async throws -> ManagedWorktreeInspection {
        await beginOperation()
        defer { endOperation() }

        var record = try await requiredRecord(id: id)
        let inspection = await inspectRecord(record)
        apply(inspection: inspection, to: &record)
        try await registry.save(record)
        return inspection
    }

    func remove(
        id: UUID,
        lease: WorktreeLease? = nil,
        force: Bool = false
    ) async throws {
        await beginOperation()
        defer { endOperation() }
        let record = try await requiredRecord(id: id)
        try await removeLocked(record: record, lease: lease, force: force)
    }

    func cleanup(
        olderThan age: TimeInterval = ManagedWorktreeLimits.defaultCleanupAge,
        now suppliedNow: Date? = nil
    ) async throws -> WorktreeMaintenanceReport {
        await beginOperation()
        defer { endOperation() }
        guard age.isFinite, age >= 0 else {
            throw ManagedWorktreeError.invalidConfiguration("cleanup age 無效。")
        }

        let timestamp = suppliedNow ?? nowProvider()
        var report = WorktreeMaintenanceReport()
        let records = try await registry.list()
        for original in records {
            guard original.lease == nil,
                  original.state == .ready,
                  timestamp.timeIntervalSince(original.updatedAt) >= age else {
                report.skippedIDs.append(original.id)
                continue
            }
            do {
                var record = original
                let inspection = await inspectRecord(record)
                apply(inspection: inspection, to: &record)
                try await registry.save(record)
                guard inspection.state == .ready, inspection.isClean == true else {
                    report.skippedIDs.append(record.id)
                    continue
                }
                try await removeLocked(record: record, lease: nil, force: false)
                report.removedIDs.append(record.id)
            } catch {
                report.appendFailure(worktreeID: original.id, operation: "cleanup", error: error)
            }
        }
        return report
    }

    func repair() async throws -> WorktreeMaintenanceReport {
        await beginOperation()
        defer { endOperation() }

        try ensureManagedRoot()
        var report = WorktreeMaintenanceReport()
        let originalRecords = try await registry.list()
        var knownIDs = Set(originalRecords.map(\ManagedWorktreeRecord.id))

        for original in originalRecords {
            do {
                // A pending removal with a lease may still be referenced by a
                // durable Task or handoff journal. Repair has no proof that
                // releasing that exact Task checkout was committed, so leave
                // it for the transaction recovery owner.
                if original.state == .removalPending, original.lease != nil {
                    report.skippedIDs.append(original.id)
                    continue
                }
                var record = original
                var inspection = await inspectRecord(record)

                if original.state == .removalPending {
                    if inspection.exists == false {
                        try await prune(record: record)
                        try await registry.remove(id: record.id)
                        report.removedIDs.append(record.id)
                        continue
                    }
                    if inspection.isRegistered, inspection.isClean == true {
                        try await removeLocked(
                            record: record,
                            lease: nil,
                            force: false
                        )
                        report.removedIDs.append(record.id)
                        continue
                    }
                }

                if inspection.exists,
                   inspection.state == .invalid,
                   let context = existingGitContext(for: record) {
                    _ = try? await runGit(
                        ["-C", context.path, "worktree", "repair", record.worktreePath],
                        operation: "worktree repair"
                    )
                    inspection = await inspectRecord(record)
                    if inspection.state == .ready { report.repairedIDs.append(record.id) }
                }

                apply(inspection: inspection, to: &record)
                if inspection.state == .missing {
                    try await prune(record: record)
                    report.missingIDs.append(record.id)
                } else if inspection.state == .invalid {
                    report.invalidIDs.append(record.id)
                }
                try await registry.save(record)
            } catch {
                report.appendFailure(worktreeID: original.id, operation: "repair", error: error)
            }
        }

        let children = try fileManager.contentsOfDirectory(
            at: managedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children.prefix(ManagedWorktreeLimits.maximumMaintenanceItems) {
            guard let id = UUID(uuidString: child.lastPathComponent),
                  child.lastPathComponent == id.uuidString.lowercased(),
                  !knownIDs.contains(id) else { continue }
            knownIDs.insert(id)
            do {
                guard leafState(at: child) == .directory,
                      child.standardizedFileURL.path
                        == ManagedWorktreeValidation.ownedURL(
                            id: id,
                            managedRoot: managedRoot
                        ).path else {
                    report.invalidIDs.append(id)
                    continue
                }
                let orphan = try await adoptOrphan(id: id, checkout: child)
                try await registry.save(orphan)
                report.adoptedIDs.append(id)
            } catch {
                report.appendFailure(worktreeID: id, operation: "adopt orphan", error: error)
                report.invalidIDs.append(id)
            }
        }
        return report
    }

    private func createLocked(
        repositoryRoot: URL,
        taskID: UUID,
        options: ManagedWorktreeCreateOptions
    ) async throws -> ManagedWorktreeRecord {
        try ManagedWorktreeValidation.validate(options: options)
        try ensureManagedRoot()
        let existingRecords = try await registry.list()
        guard existingRecords.count < ManagedWorktreeLimits.maximumRecords else {
            throw ManagedWorktreeError.invalidRegistry("record 數量已達安全上限。")
        }

        let source = try await resolveSourceContext(
            repositoryRoot,
            baseReference: options.baseReference
        )
        let worktreeID = options.plannedWorktreeID ?? UUID()
        guard !existingRecords.contains(where: { $0.id == worktreeID }) else {
            throw ManagedWorktreeError.invalidConfiguration(
                "planned worktree ID 已存在。"
            )
        }
        let destination = ManagedWorktreeValidation.ownedURL(
            id: worktreeID,
            managedRoot: managedRoot
        )
        guard leafState(at: destination) == .missing else {
            throw ManagedWorktreeError.unsafeManagedRoot("UUID checkout path 已存在。")
        }

        let existingBranches = try await localBranches(at: source.sourceCheckout)
        let branchName: String?
        if options.detached {
            branchName = nil
        } else {
            branchName = try conflictResolver.branchName(
                preferredName: options.preferredBranchName,
                taskID: taskID,
                worktreeID: worktreeID,
                existingBranches: existingBranches
            )
        }
        let timestamp = nowProvider()
        let lease = WorktreeLease(
            worktreeID: worktreeID,
            taskID: taskID,
            acquiredAt: timestamp
        )

        var createdCheckout = false
        do {
            if let branchName {
                _ = try await runGit(
                    [
                        "-C", source.sourceCheckout.path,
                        "worktree", "add", "-b", branchName,
                        destination.path, source.headObjectID
                    ],
                    operation: "worktree add"
                )
            } else {
                _ = try await runGit(
                    [
                        "-C", source.sourceCheckout.path,
                        "worktree", "add", "--detach",
                        destination.path, source.headObjectID
                    ],
                    operation: "worktree add"
                )
            }
            // Only a successful `worktree add` proves that this transaction
            // created the checkout and, for `-b`, owns the new branch. A failed
            // command can race another process that created the same branch;
            // compensation must never delete that unrelated ref.
            createdCheckout = true

            var record = ManagedWorktreeRecord(
                id: worktreeID,
                repositoryRootPath: source.repositoryRoot.path,
                sourceCheckoutPath: source.sourceCheckout.path,
                worktreePath: destination.path,
                baseObjectID: source.headObjectID,
                headObjectID: source.headObjectID,
                branchName: branchName,
                createdBranch: branchName != nil,
                state: .ready,
                lease: lease,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            let inspection = await inspectRecord(record)
            apply(inspection: inspection, to: &record)
            guard inspection.state == .ready else {
                throw ManagedWorktreeError.unavailableWorktree(
                    worktreeID,
                    inspection.state
                )
            }
            try await registry.save(record)
            return record
        } catch {
            if createdCheckout || leafState(at: destination) != .missing {
                await compensateCreation(
                    sourceCheckout: source.sourceCheckout,
                    destination: destination,
                    branchName: createdCheckout ? branchName : nil
                )
            }
            throw error
        }
    }

    private func removeLocked(
        record original: ManagedWorktreeRecord,
        lease: WorktreeLease?,
        force: Bool
    ) async throws {
        try conflictResolver.validateRemovalLease(record: original, provided: lease)
        if original.state == .orphaned, !force {
            throw ManagedWorktreeError.unavailableWorktree(original.id, .orphaned)
        }

        var record = original
        let inspection = await inspectRecord(record)
        apply(inspection: inspection, to: &record)
        if inspection.isClean == false, !force {
            throw ManagedWorktreeError.dirtyWorktree(record.id)
        }
        if inspection.exists,
           inspection.state == .invalid,
           !force {
            throw ManagedWorktreeError.unavailableWorktree(record.id, .invalid)
        }
        if inspection.exists, inspection.isClean == true, !force {
            try await removeAppleDoubleSidecarsIfPresent(
                checkout: URL(fileURLWithPath: record.worktreePath, isDirectory: true)
            )
        }

        record.state = .removalPending
        record.updatedAt = max(record.updatedAt, nowProvider())
        try await registry.save(record)

        do {
            if inspection.exists {
                if inspection.isRegistered, let context = existingGitContext(for: record) {
                    var arguments = ["-C", context.path, "worktree", "remove"]
                    if force { arguments.append("--force") }
                    arguments.append(record.worktreePath)
                    _ = try await runGit(arguments, operation: "worktree remove")
                } else if force {
                    try removeOwnedDirectory(record: record)
                } else {
                    throw ManagedWorktreeError.unavailableWorktree(record.id, .invalid)
                }

                if leafState(at: URL(fileURLWithPath: record.worktreePath)) != .missing {
                    guard force else {
                        throw ManagedWorktreeError.gitCommandFailed(
                            operation: "worktree remove",
                            status: 1,
                            detail: "Git 成功回傳後 checkout 仍存在。"
                        )
                    }
                    try removeOwnedDirectory(record: record)
                }
            }
            try await prune(record: record)
            try await registry.remove(id: record.id)
        } catch {
            var recovered = record
            let current = await inspectRecord(recovered)
            apply(inspection: current, to: &recovered)
            try? await registry.save(recovered)
            throw error
        }
    }

    private func resolveSourceContext(
        _ requestedURL: URL,
        baseReference: String
    ) async throws -> SourceContext {
        let requested = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard leafState(at: requested) == .directory else {
            throw ManagedWorktreeError.notRepository(requested.path)
        }
        do {
            try ManagedWorktreeValidation.validateAbsolutePath(
                requested.path,
                label: "source checkout"
            )
        } catch {
            throw ManagedWorktreeError.notRepository(requested.path)
        }

        let topLevelResult = try await runGit(
            ["-C", requested.path, "rev-parse", "--show-toplevel"],
            operation: "inspect source checkout"
        )
        let sourceCheckout = try canonicalGitPath(topLevelResult.stdout)
        guard leafState(at: sourceCheckout) == .directory else {
            throw ManagedWorktreeError.notRepository(requested.path)
        }
        let bare = try await runGit(
            ["-C", sourceCheckout.path, "rev-parse", "--is-bare-repository"],
            operation: "inspect repository"
        )
        guard trimmed(bare.stdout) == "false" else {
            throw ManagedWorktreeError.notRepository(sourceCheckout.path)
        }

        let listResult = try await runGit(
            ["-C", sourceCheckout.path, "worktree", "list", "--porcelain", "-z"],
            operation: "list worktrees"
        )
        let entries = parseWorktreeList(listResult.stdout)
        guard let first = entries.first else {
            throw ManagedWorktreeError.notRepository(sourceCheckout.path)
        }
        let repositoryRoot = try canonicalGitPath(first.path)

        let head = try await runGit(
            [
                "-C", sourceCheckout.path,
                "rev-parse", "--verify", "--end-of-options", "\(baseReference)^{commit}"
            ],
            operation: "resolve base reference"
        )
        let objectID = trimmed(head.stdout)
        try ManagedWorktreeValidation.validateObjectID(objectID, label: "base object ID")
        return SourceContext(
            repositoryRoot: repositoryRoot,
            sourceCheckout: sourceCheckout,
            headObjectID: objectID.lowercased()
        )
    }

    private func inspectRecord(
        _ record: ManagedWorktreeRecord
    ) async -> ManagedWorktreeInspection {
        let timestamp = nowProvider()
        let checkout = URL(fileURLWithPath: record.worktreePath, isDirectory: true)
            .standardizedFileURL
        var issues: [ManagedWorktreeInspectionIssue] = []

        switch leafState(at: checkout) {
        case .missing:
            return ManagedWorktreeInspection(
                worktreeID: record.id,
                state: .missing,
                worktreePath: record.worktreePath,
                exists: false,
                isRegistered: false,
                isClean: nil,
                headObjectID: nil,
                branchName: nil,
                issues: [.checkoutMissing],
                inspectedAt: timestamp
            )
        case .symbolicLink:
            issues.append(.checkoutIsSymbolicLink)
        case .other:
            issues.append(.checkoutIsNotDirectory)
        case .directory:
            break
        }
        guard issues.isEmpty else {
            return ManagedWorktreeInspection(
                worktreeID: record.id,
                state: .invalid,
                worktreePath: record.worktreePath,
                exists: true,
                isRegistered: false,
                isClean: nil,
                headObjectID: nil,
                branchName: nil,
                issues: issues,
                inspectedAt: timestamp
            )
        }

        do {
            let topResult = try await runGit(
                ["-C", checkout.path, "rev-parse", "--show-toplevel"],
                operation: "inspect worktree top-level"
            )
            let top = try canonicalGitPath(topResult.stdout)
            if top.path != checkout.path { issues.append(.topLevelMismatch) }

            let headResult = try await runGit(
                ["-C", checkout.path, "rev-parse", "--verify", "HEAD"],
                operation: "inspect worktree HEAD"
            )
            let head = trimmed(headResult.stdout).lowercased()
            try ManagedWorktreeValidation.validateObjectID(head, label: "HEAD")
            if head != record.headObjectID.lowercased() { issues.append(.headMismatch) }

            let branchResult = try await runGit(
                ["-C", checkout.path, "symbolic-ref", "--quiet", "--short", "HEAD"],
                operation: "inspect worktree branch",
                accepting: [0, 1]
            )
            let branch = branchResult.terminationStatus == 0
                ? optionalTrimmed(branchResult.stdout)
                : nil
            if branch != record.branchName { issues.append(.branchMismatch) }

            let listResult = try await runGit(
                ["-C", checkout.path, "worktree", "list", "--porcelain", "-z"],
                operation: "inspect worktree registration"
            )
            let registered = parseWorktreeList(listResult.stdout).contains { entry in
                (try? canonicalGitPath(entry.path).path) == checkout.path
            }
            if !registered { issues.append(.notRegistered) }

            let statusResult = try await runGit(
                [
                    "-C", checkout.path, "status", "--porcelain=v1", "-z",
                    "--untracked-files=all"
                ],
                operation: "inspect worktree status"
            )
            let clean = !hasMeaningfulStatus(statusResult.stdout)
            let hasStructuralIssue = issues.contains(.topLevelMismatch)
                || issues.contains(.notRegistered)
            let state: ManagedWorktreeState
            if hasStructuralIssue {
                state = .invalid
            } else if record.state == .orphaned {
                state = .orphaned
            } else if record.state == .removalPending {
                state = .removalPending
            } else {
                state = .ready
            }
            return ManagedWorktreeInspection(
                worktreeID: record.id,
                state: state,
                worktreePath: record.worktreePath,
                exists: true,
                isRegistered: registered,
                isClean: clean,
                headObjectID: head,
                branchName: branch,
                issues: issues,
                inspectedAt: timestamp
            )
        } catch {
            if issues.isEmpty { issues.append(.notGitWorktree) }
            issues.append(.commandFailed)
            return ManagedWorktreeInspection(
                worktreeID: record.id,
                state: .invalid,
                worktreePath: record.worktreePath,
                exists: true,
                isRegistered: false,
                isClean: nil,
                headObjectID: nil,
                branchName: nil,
                issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue },
                inspectedAt: timestamp
            )
        }
    }

    private func apply(
        inspection: ManagedWorktreeInspection,
        to record: inout ManagedWorktreeRecord
    ) {
        let oldBranch = record.branchName
        record.state = inspection.state
        if let head = inspection.headObjectID { record.headObjectID = head }
        if inspection.exists, inspection.state != .invalid {
            record.branchName = inspection.branchName
            if oldBranch != inspection.branchName { record.createdBranch = false }
        }
        record.lastInspectedAt = inspection.inspectedAt
    }

    private func adoptOrphan(
        id: UUID,
        checkout: URL
    ) async throws -> ManagedWorktreeRecord {
        let context = try await resolveSourceContext(checkout, baseReference: "HEAD")
        let branchResult = try await runGit(
            ["-C", checkout.path, "symbolic-ref", "--quiet", "--short", "HEAD"],
            operation: "inspect orphan branch",
            accepting: [0, 1]
        )
        let branch = branchResult.terminationStatus == 0
            ? optionalTrimmed(branchResult.stdout)
            : nil
        let timestamp = nowProvider()
        let record = ManagedWorktreeRecord(
            id: id,
            repositoryRootPath: context.repositoryRoot.path,
            sourceCheckoutPath: checkout.path,
            worktreePath: checkout.path,
            baseObjectID: context.headObjectID,
            headObjectID: context.headObjectID,
            branchName: branch,
            createdBranch: false,
            state: .orphaned,
            lease: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastInspectedAt: timestamp
        )
        try ManagedWorktreeValidation.validate(record: record, managedRoot: managedRoot)
        return record
    }

    private func localBranches(at checkout: URL) async throws -> Set<String> {
        let result = try await runGit(
            [
                "-C", checkout.path, "for-each-ref",
                "--format=%(refname:short)", "refs/heads"
            ],
            operation: "list branches"
        )
        let branches = result.stdout.split(whereSeparator: \Character.isNewline).map(String.init)
        guard branches.count <= ManagedWorktreeLimits.maximumRecords * 16 else {
            throw ManagedWorktreeError.commandOutputTooLarge(
                ManagedWorktreeLimits.maximumCommandOutputBytes
            )
        }
        return Set(branches)
    }

    private func compensateCreation(
        sourceCheckout: URL,
        destination: URL,
        branchName: String?
    ) async {
        if leafState(at: destination) != .missing {
            _ = try? await runGit(
                [
                    "-C", sourceCheckout.path, "worktree", "remove", "--force",
                    destination.path
                ],
                operation: "rollback worktree add"
            )
            if leafState(at: destination) == .directory,
               destination.path.hasPrefix(managedRoot.path + "/") {
                try? fileManager.removeItem(at: destination)
            }
        }
        _ = try? await runGit(
            ["-C", sourceCheckout.path, "worktree", "prune", "--expire=now"],
            operation: "rollback worktree prune"
        )
        if let branchName {
            _ = try? await runGit(
                ["-C", sourceCheckout.path, "branch", "-D", branchName],
                operation: "rollback branch"
            )
        }
    }

    private func prune(record: ManagedWorktreeRecord) async throws {
        guard let context = existingGitContext(for: record) else { return }
        _ = try await runGit(
            ["-C", context.path, "worktree", "prune", "--expire=now"],
            operation: "worktree prune"
        )
    }

    private func existingGitContext(for record: ManagedWorktreeRecord) -> URL? {
        for path in [
            record.repositoryRootPath,
            record.sourceCheckoutPath,
            record.worktreePath
        ] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if leafState(at: url) == .directory { return url }
        }
        return nil
    }

    private func removeOwnedDirectory(record: ManagedWorktreeRecord) throws {
        let expected = ManagedWorktreeValidation.ownedURL(
            id: record.id,
            managedRoot: managedRoot
        )
        guard record.worktreePath == expected.path,
              expected.path.hasPrefix(managedRoot.path + "/") else {
            throw ManagedWorktreeError.unsafeManagedRoot("拒絕移除非 registry-owned path。")
        }
        switch leafState(at: expected) {
        case .missing:
            return
        case .directory:
            try fileManager.removeItem(at: expected)
        case .symbolicLink, .other:
            throw ManagedWorktreeError.unsafeManagedRoot("拒絕移除 symlink 或非目錄 checkout。")
        }
    }

    private func requiredRecord(id: UUID) async throws -> ManagedWorktreeRecord {
        guard let record = try await registry.record(id: id) else {
            throw ManagedWorktreeError.recordNotFound(id)
        }
        return record
    }

    private func ensureManagedRoot() throws {
        guard managedRoot.isFileURL,
              managedRoot.path.hasPrefix("/"),
              managedRoot.path != "/",
              managedRoot.path.utf8.count <= ManagedWorktreeLimits.maximumPathBytes else {
            throw ManagedWorktreeError.unsafeManagedRoot("managed root path 無效。")
        }
        try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        guard leafState(at: managedRoot) == .directory else {
            throw ManagedWorktreeError.unsafeManagedRoot("managed root 是 symlink 或非目錄。")
        }
        _ = Darwin.chmod(managedRoot.path, mode_t(0o700))
    }

    private func leafState(at url: URL) -> LeafState {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    private func canonicalGitPath(_ output: String) throws -> URL {
        let path = trimmed(output)
        guard !path.isEmpty else {
            throw ManagedWorktreeError.invalidConfiguration("Git 回傳空白 path。")
        }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try ManagedWorktreeValidation.validateAbsolutePath(canonical.path, label: "Git path")
        return canonical
    }

    private func parseWorktreeList(_ output: String) -> [WorktreeListEntry] {
        let fields: [String]
        if output.contains("\0") {
            fields = output.components(separatedBy: "\0")
        } else {
            fields = output.components(separatedBy: .newlines)
        }
        var entries: [WorktreeListEntry] = []
        var current: WorktreeListEntry?
        for field in fields {
            if field.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeListEntry(
                    path: String(field.dropFirst("worktree ".count)),
                    headObjectID: nil,
                    branchName: nil
                )
            } else if field.hasPrefix("HEAD ") {
                current?.headObjectID = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch refs/heads/") {
                current?.branchName = String(field.dropFirst("branch refs/heads/".count))
            }
        }
        if let current { entries.append(current) }
        return Array(entries.prefix(ManagedWorktreeLimits.maximumRecords * 2))
    }

    private func runGit(
        _ arguments: [String],
        operation: String,
        accepting acceptedStatuses: Set<Int32> = [0]
    ) async throws -> WorktreeCommandResult {
        try ensureWorktreeScratch()
        let command = WorktreeCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/git", isDirectory: false),
            arguments: [
                "-c", "core.hooksPath=/dev/null",
                "-c", "credential.helper=",
                "-c", "core.fsmonitor=false",
                "-c", "gc.auto=0"
            ] + arguments,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "GCM_INTERACTIVE": "never",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
                "TMPDIR": AppPaths.agentWorktreeScratch.path
            ],
            outputLimit: ManagedWorktreeLimits.maximumCommandOutputBytes
        )
        let result = try await runner.run(command)
        guard !result.outputTruncated else {
            throw ManagedWorktreeError.commandOutputTooLarge(command.outputLimit)
        }
        guard acceptedStatuses.contains(result.terminationStatus) else {
            let rawDetail = optionalTrimmed(result.stderr)
                ?? optionalTrimmed(result.stdout)
                ?? ""
            let bounded = String(
                decoding: Data(
                    rawDetail.utf8.prefix(ManagedWorktreeLimits.maximumFailureDetailBytes)
                ),
                as: UTF8.self
            )
            throw ManagedWorktreeError.gitCommandFailed(
                operation: operation,
                status: result.terminationStatus,
                detail: bounded
            )
        }
        return result
    }

    private func ensureWorktreeScratch() throws {
        let scratch = AppPaths.agentWorktreeScratch.standardizedFileURL
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        var info = Darwin.stat()
        guard Darwin.lstat(scratch.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw ManagedWorktreeError.unsafeManagedRoot(
                "agent worktree scratch 不是安全目錄。"
            )
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }

    private func hasMeaningfulStatus(_ output: String) -> Bool {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        for recordValue in records {
            let record = String(recordValue)
            guard record.count >= 3 else { return true }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            if status == "??", isAppleDoubleMetadataPath(path) {
                continue
            }
            return true
        }
        return false
    }

    private func removeAppleDoubleSidecarsIfPresent(checkout: URL) async throws {
        let status = try await runGit(
            [
                "-C", checkout.path, "status", "--porcelain=v1", "-z",
                "--untracked-files=all"
            ],
            operation: "inspect AppleDouble metadata"
        )
        var paths: [String] = []
        var totalPathBytes = 0
        for recordValue in status.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let record = String(recordValue)
            guard record.count >= 3 else {
                throw ManagedWorktreeError.invalidConfiguration(
                    "malformed Git status during metadata cleanup"
                )
            }
            let code = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            guard code == "??", isAppleDoubleMetadataPath(path) else {
                throw ManagedWorktreeError.invalidConfiguration(
                    "worktree changed during metadata cleanup"
                )
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"),
                  !path.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.count < ManagedWorktreeLimits.maximumMaintenanceItems,
                  totalPathBytes <= ManagedWorktreeLimits.maximumCommandOutputBytes
                    - path.utf8.count else {
                throw ManagedWorktreeError.invalidConfiguration(
                    "AppleDouble metadata path is unsafe or excessive"
                )
            }
            totalPathBytes += path.utf8.count
            paths.append(path)
        }
        guard !paths.isEmpty else { return }

        _ = try await runGit(
            ["-C", checkout.path, "clean", "-f", "--"]
                + paths.map { ":(literal)\($0)" },
            operation: "remove AppleDouble metadata"
        )
        let verification = try await runGit(
            [
                "-C", checkout.path, "status", "--porcelain=v1", "-z",
                "--untracked-files=all"
            ],
            operation: "verify AppleDouble metadata removal"
        )
        guard verification.stdout.isEmpty else {
            throw ManagedWorktreeError.invalidConfiguration(
                "worktree changed during metadata cleanup"
            )
        }
    }

    private func isAppleDoubleMetadataPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0.hasPrefix("._")
        }
    }

    private func beginOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func endOperation() {
        if operationWaiters.isEmpty {
            operationActive = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}
