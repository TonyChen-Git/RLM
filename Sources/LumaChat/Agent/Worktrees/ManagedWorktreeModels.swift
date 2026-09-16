import Foundation

enum ManagedWorktreeLimits {
    static let maximumRecords = 512
    static let maximumRegistryBytes = 4 * 1_024 * 1_024
    static let maximumPathBytes = 4_096
    static let maximumBranchBytes = 1_024
    static let maximumReferenceBytes = 1_024
    static let maximumObjectIDBytes = 128
    static let maximumMaintenanceItems = 2_048
    static let maximumFailureDetailBytes = 1_024
    static let maximumCommandOutputBytes = 1 * 1_024 * 1_024
    static let defaultCleanupAge: TimeInterval = 7 * 24 * 60 * 60
}

enum ManagedWorktreeState: String, Codable, CaseIterable, Sendable {
    case ready
    case missing
    case invalid
    case orphaned
    case removalPending
}

/// A durable capability binding exactly one Task to one managed checkout.
/// `id` is a random token, not a presentation identifier; lifecycle mutations
/// compare its immutable capability coordinates so a Task ID alone cannot
/// release another lease. `renewedAt` is freshness metadata and deliberately
/// does not invalidate an already issued copy of the same capability token.
struct WorktreeLease: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var worktreeID: UUID
    var taskID: UUID
    var acquiredAt: Date
    var renewedAt: Date

    init(
        id: UUID = UUID(),
        worktreeID: UUID,
        taskID: UUID,
        acquiredAt: Date = Date(),
        renewedAt: Date? = nil
    ) {
        self.id = id
        self.worktreeID = worktreeID
        self.taskID = taskID
        self.acquiredAt = acquiredAt
        self.renewedAt = renewedAt ?? acquiredAt
    }

    func identifiesSameCapability(as other: WorktreeLease) -> Bool {
        id == other.id
            && worktreeID == other.worktreeID
            && taskID == other.taskID
            && acquiredAt == other.acquiredAt
    }
}

/// Registry data deliberately contains only repository/worktree identity and
/// lifecycle state. It never stores command output, environment, credentials,
/// bookmarks, patches, prompts, or model-controlled metadata.
struct ManagedWorktreeRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// The primary checkout reported by `git worktree list`. This remains the
    /// repository identity even when creation was requested from a linked tree.
    var repositoryRootPath: String
    /// The checkout whose HEAD/base reference was used for creation.
    var sourceCheckoutPath: String
    /// Always the UUID-derived child owned by the app's managed root.
    var worktreePath: String
    var baseObjectID: String
    var headObjectID: String
    var branchName: String?
    var createdBranch: Bool
    var state: ManagedWorktreeState
    var lease: WorktreeLease?
    var createdAt: Date
    var updatedAt: Date
    var lastInspectedAt: Date?

    init(
        id: UUID = UUID(),
        repositoryRootPath: String,
        sourceCheckoutPath: String,
        worktreePath: String,
        baseObjectID: String,
        headObjectID: String,
        branchName: String? = nil,
        createdBranch: Bool = false,
        state: ManagedWorktreeState = .ready,
        lease: WorktreeLease? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lastInspectedAt: Date? = nil
    ) {
        self.id = id
        self.repositoryRootPath = repositoryRootPath
        self.sourceCheckoutPath = sourceCheckoutPath
        self.worktreePath = worktreePath
        self.baseObjectID = baseObjectID
        self.headObjectID = headObjectID
        self.branchName = branchName
        self.createdBranch = createdBranch
        self.state = state
        self.lease = lease
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastInspectedAt = lastInspectedAt
    }
}

struct ManagedWorktreeCreateOptions: Codable, Equatable, Sendable {
    var baseReference: String
    var preferredBranchName: String?
    var detached: Bool
    /// Optional transaction-owned identity persisted before Git mutation. It
    /// closes the crash window between `worktree add` and registry journaling.
    var plannedWorktreeID: UUID?

    init(
        baseReference: String = "HEAD",
        preferredBranchName: String? = nil,
        detached: Bool = false,
        plannedWorktreeID: UUID? = nil
    ) {
        self.baseReference = baseReference
        self.preferredBranchName = preferredBranchName
        self.detached = detached
        self.plannedWorktreeID = plannedWorktreeID
    }
}

enum ManagedWorktreeInspectionIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case checkoutMissing
    case checkoutIsSymbolicLink
    case checkoutIsNotDirectory
    case notGitWorktree
    case topLevelMismatch
    case notRegistered
    case headMismatch
    case branchMismatch
    case commandFailed
}

struct ManagedWorktreeInspection: Codable, Equatable, Sendable {
    var worktreeID: UUID
    var state: ManagedWorktreeState
    var worktreePath: String
    var exists: Bool
    var isRegistered: Bool
    var isClean: Bool?
    var headObjectID: String?
    var branchName: String?
    var issues: [ManagedWorktreeInspectionIssue]
    var inspectedAt: Date
}

struct ManagedWorktreeMaintenanceFailure: Codable, Equatable, Sendable {
    var worktreeID: UUID?
    var operation: String
    var detail: String
}

struct WorktreeMaintenanceReport: Codable, Equatable, Sendable {
    var removedIDs: [UUID] = []
    var repairedIDs: [UUID] = []
    var adoptedIDs: [UUID] = []
    var missingIDs: [UUID] = []
    var invalidIDs: [UUID] = []
    var skippedIDs: [UUID] = []
    var failures: [ManagedWorktreeMaintenanceFailure] = []

    mutating func appendFailure(
        worktreeID: UUID?,
        operation: String,
        error: Error
    ) {
        guard failures.count < ManagedWorktreeLimits.maximumMaintenanceItems else { return }
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failures.append(ManagedWorktreeMaintenanceFailure(
            worktreeID: worktreeID,
            operation: String(operation.prefix(128)),
            detail: Self.bounded(raw)
        ))
    }

    private static func bounded(_ value: String) -> String {
        let data = Data(value.utf8.prefix(ManagedWorktreeLimits.maximumFailureDetailBytes))
        return String(decoding: data, as: UTF8.self)
    }
}

enum ManagedWorktreeError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case unsafeManagedRoot(String)
    case invalidRegistry(String)
    case registryTooLarge(Int)
    case recordNotFound(UUID)
    case notRepository(String)
    case leaseConflict(worktreeID: UUID, taskID: UUID)
    case invalidLease(UUID)
    case dirtyWorktree(UUID)
    case unavailableWorktree(UUID, ManagedWorktreeState)
    case gitCommandFailed(operation: String, status: Int32, detail: String)
    case commandOutputTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Managed Worktree 設定無效：\(detail)"
        case .unsafeManagedRoot(let detail):
            return "Managed Worktree 儲存位置不安全：\(detail)"
        case .invalidRegistry(let detail):
            return "Managed Worktree registry 無效：\(detail)"
        case .registryTooLarge(let limit):
            return "Managed Worktree registry 超過 \(limit) bytes 上限。"
        case .recordNotFound(let id):
            return "找不到 Managed Worktree \(id.uuidString)。"
        case .notRepository(let path):
            return "指定位置不是可用的 Git checkout：\(path)"
        case .leaseConflict(let worktreeID, _):
            return "Managed Worktree \(worktreeID.uuidString) 已由另一個 Task 租用。"
        case .invalidLease(let id):
            return "Managed Worktree \(id.uuidString) 的 lease token 無效。"
        case .dirtyWorktree(let id):
            return "Managed Worktree \(id.uuidString) 有尚未提交的變更。"
        case .unavailableWorktree(let id, let state):
            return "Managed Worktree \(id.uuidString) 目前不可用（\(state.rawValue)）。"
        case .gitCommandFailed(let operation, let status, let detail):
            let suffix = detail.isEmpty ? "" : "：\(detail)"
            return "Git \(operation) 失敗（exit \(status)）\(suffix)"
        case .commandOutputTooLarge(let limit):
            return "Git 指令輸出超過 \(limit) bytes 上限。"
        }
    }
}

enum ManagedWorktreeValidation {
    static func validate(
        records: [ManagedWorktreeRecord],
        managedRoot: URL
    ) throws {
        guard records.count <= ManagedWorktreeLimits.maximumRecords else {
            throw ManagedWorktreeError.invalidRegistry("record 數量超過安全上限。")
        }
        var recordIDs = Set<UUID>()
        var paths = Set<String>()
        var leaseIDs = Set<UUID>()
        var leasedTaskIDs = Set<UUID>()
        for record in records {
            guard recordIDs.insert(record.id).inserted else {
                throw ManagedWorktreeError.invalidRegistry("包含重複的 record ID。")
            }
            try validate(record: record, managedRoot: managedRoot)
            guard paths.insert(record.worktreePath).inserted else {
                throw ManagedWorktreeError.invalidRegistry("包含重複的 checkout path。")
            }
            if let lease = record.lease {
                guard leaseIDs.insert(lease.id).inserted,
                      leasedTaskIDs.insert(lease.taskID).inserted else {
                    throw ManagedWorktreeError.invalidRegistry("包含重複的 lease 或 Task binding。")
                }
            }
        }
    }

    static func validate(
        record: ManagedWorktreeRecord,
        managedRoot: URL
    ) throws {
        try validateAbsolutePath(record.repositoryRootPath, label: "repositoryRootPath")
        try validateAbsolutePath(record.sourceCheckoutPath, label: "sourceCheckoutPath")
        try validateAbsolutePath(record.worktreePath, label: "worktreePath")
        let expected = ownedURL(id: record.id, managedRoot: managedRoot).path
        guard record.worktreePath == expected else {
            throw ManagedWorktreeError.invalidRegistry("checkout path 不是 registry-owned UUID path。")
        }
        try validateObjectID(record.baseObjectID, label: "baseObjectID")
        try validateObjectID(record.headObjectID, label: "headObjectID")
        if let branch = record.branchName { try validateBranch(branch) }
        guard !record.createdBranch || record.branchName != nil else {
            throw ManagedWorktreeError.invalidRegistry("createdBranch 缺少 branchName。")
        }
        try validateDate(record.createdAt, label: "createdAt")
        try validateDate(record.updatedAt, label: "updatedAt")
        if let lastInspectedAt = record.lastInspectedAt {
            try validateDate(lastInspectedAt, label: "lastInspectedAt")
        }
        guard record.updatedAt >= record.createdAt else {
            throw ManagedWorktreeError.invalidRegistry("updatedAt 早於 createdAt。")
        }
        if let lease = record.lease {
            try validate(lease: lease, expectedWorktreeID: record.id)
            guard record.state != .orphaned else {
                throw ManagedWorktreeError.invalidRegistry("orphaned checkout 不得帶有 lease。")
            }
        }
    }

    static func validate(
        lease: WorktreeLease,
        expectedWorktreeID: UUID? = nil
    ) throws {
        if let expectedWorktreeID, lease.worktreeID != expectedWorktreeID {
            throw ManagedWorktreeError.invalidRegistry("lease worktree ID 不相符。")
        }
        try validateDate(lease.acquiredAt, label: "lease.acquiredAt")
        try validateDate(lease.renewedAt, label: "lease.renewedAt")
        guard lease.renewedAt >= lease.acquiredAt else {
            throw ManagedWorktreeError.invalidRegistry("lease renewedAt 早於 acquiredAt。")
        }
    }

    static func validate(options: ManagedWorktreeCreateOptions) throws {
        let reference = options.baseReference
        guard !reference.isEmpty,
              !reference.hasPrefix("-"),
              reference.utf8.count <= ManagedWorktreeLimits.maximumReferenceBytes,
              !containsControlCharacters(reference),
              !reference.contains(where: \.isWhitespace) else {
            throw ManagedWorktreeError.invalidConfiguration("base reference 無效或過長。")
        }
        if let preferred = options.preferredBranchName {
            guard !preferred.isEmpty,
                  preferred.utf8.count <= ManagedWorktreeLimits.maximumBranchBytes,
                  !containsControlCharacters(preferred) else {
                throw ManagedWorktreeError.invalidConfiguration("preferred branch 無效或過長。")
            }
        }
    }

    static func validateBranch(_ branch: String) throws {
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
        guard !branch.isEmpty,
              !branch.hasPrefix("-"),
              !branch.hasPrefix("/"),
              !branch.hasSuffix("/"),
              !branch.hasSuffix("."),
              !branch.hasSuffix(".lock"),
              branch.utf8.count <= ManagedWorktreeLimits.maximumBranchBytes,
              !containsControlCharacters(branch),
              branch.rangeOfCharacter(from: forbidden) == nil,
              !branch.contains(".."),
              !branch.contains("@{"),
              !branch.contains("//") else {
            throw ManagedWorktreeError.invalidConfiguration("branch name 無效或過長。")
        }
    }

    static func validateObjectID(_ objectID: String, label: String) throws {
        guard (40...ManagedWorktreeLimits.maximumObjectIDBytes).contains(objectID.utf8.count),
              objectID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte) || (65...70).contains(byte)
              }) else {
            throw ManagedWorktreeError.invalidRegistry("\(label) 不是 bounded Git object ID。")
        }
    }

    static func validateAbsolutePath(_ path: String, label: String) throws {
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.count <= ManagedWorktreeLimits.maximumPathBytes,
              !containsControlCharacters(path) else {
            throw ManagedWorktreeError.invalidRegistry("\(label) 不是安全的絕對路徑。")
        }
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard standardized == path else {
            throw ManagedWorktreeError.invalidRegistry("\(label) 未 canonicalize。")
        }
    }

    static func ownedURL(id: UUID, managedRoot: URL) -> URL {
        managedRoot.standardizedFileURL
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    private static func validateDate(_ date: Date, label: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw ManagedWorktreeError.invalidRegistry("\(label) 不是有限日期。")
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
