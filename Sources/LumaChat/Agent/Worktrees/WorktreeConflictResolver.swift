import Foundation

struct WorktreeConflictResolver: Sendable {
    func branchName(
        preferredName: String?,
        taskID: UUID,
        worktreeID: UUID,
        existingBranches: Set<String>
    ) throws -> String {
        let preferred = preferredName.map(Self.sanitizeBranchBase)
        let base = preferred.flatMap { $0.isEmpty ? nil : $0 }
            ?? "lumachat/task-\(Self.shortID(taskID))"
        let uniqueSuffix = "-\(Self.shortID(worktreeID))"
        let clippedBase = Self.clippedBranchBase(
            base,
            reservingBytes: uniqueSuffix.utf8.count + 8
        )
        var candidate = clippedBase + uniqueSuffix
        try ManagedWorktreeValidation.validateBranch(candidate)
        if !existingBranches.contains(candidate) { return candidate }

        for index in 2...999 {
            let suffix = "\(uniqueSuffix)-\(index)"
            candidate = Self.clippedBranchBase(
                base,
                reservingBytes: suffix.utf8.count
            ) + suffix
            try ManagedWorktreeValidation.validateBranch(candidate)
            if !existingBranches.contains(candidate) { return candidate }
        }
        throw ManagedWorktreeError.invalidConfiguration(
            "無法為 Managed Worktree 配置不衝突的 branch。"
        )
    }

    func lease(
        existing: WorktreeLease?,
        worktreeID: UUID,
        taskID: UUID,
        now: Date
    ) throws -> WorktreeLease {
        if var existing {
            guard existing.worktreeID == worktreeID else {
                throw ManagedWorktreeError.invalidLease(worktreeID)
            }
            guard existing.taskID == taskID else {
                throw ManagedWorktreeError.leaseConflict(
                    worktreeID: worktreeID,
                    taskID: existing.taskID
                )
            }
            existing.renewedAt = max(existing.acquiredAt, now)
            return existing
        }
        return WorktreeLease(
            worktreeID: worktreeID,
            taskID: taskID,
            acquiredAt: now
        )
    }

    func validateRemovalLease(
        record: ManagedWorktreeRecord,
        provided: WorktreeLease?
    ) throws {
        switch (record.lease, provided) {
        case (nil, nil):
            return
        case (nil, .some), (.some, nil):
            throw ManagedWorktreeError.invalidLease(record.id)
        case let (.some(expected), .some(candidate)):
            guard expected.identifiesSameCapability(as: candidate),
                  expected.worktreeID == record.id else {
                throw ManagedWorktreeError.invalidLease(record.id)
            }
        }
    }

    private static func sanitizeBranchBase(_ value: String) -> String {
        var result = ""
        var previousWasSeparator = false
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            let codePoint = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(codePoint)
                || (65...90).contains(codePoint)
                || (97...122).contains(codePoint)
            if isASCIIAlphaNumeric || scalar == "_" || scalar == "-" {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if scalar == "/" {
                if !result.isEmpty, !result.hasSuffix("/") {
                    result.append("/")
                }
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        let components = trimmed.split(separator: "/").map { component -> String in
            var safe = String(component).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if safe.isEmpty { safe = "branch" }
            return safe
        }
        return components.joined(separator: "/")
    }

    private static func clippedBranchBase(_ value: String, reservingBytes: Int) -> String {
        let maximum = max(1, ManagedWorktreeLimits.maximumBranchBytes - reservingBytes)
        if value.utf8.count <= maximum { return value }
        let data = Data(value.utf8.prefix(maximum))
        var clipped = String(decoding: data, as: UTF8.self)
        while clipped.utf8.count > maximum { clipped.removeLast() }
        clipped = clipped.trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
        return clipped.isEmpty ? "lumachat/task" : clipped
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}
