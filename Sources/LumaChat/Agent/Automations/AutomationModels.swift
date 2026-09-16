import Foundation

enum AutomationLimits {
    static let maximumAutomations = 256
    static let maximumRuns = 4_096
    static let maximumQueuedRuns = 512
    static let maximumOccurrenceClaims = 8_192
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumNameBytes = 256
    static let maximumPromptBytes = 128 * 1_024
    static let maximumMetadataEntries = 64
    static let maximumMetadataKeyBytes = 128
    static let maximumMetadataValueBytes = 8 * 1_024
    static let maximumEventPayloadEntries = 64
    static let maximumEventIDBytes = 512
    static let maximumEventNameBytes = 256
    static let maximumLogEntriesPerRun = 512
    static let maximumLogMessageBytes = 16 * 1_024
    static let maximumChangesPerRun = 2_048
    static let maximumArtifactsPerRun = 512
    static let maximumResultBytes = 256 * 1_024
    static let maximumPathBytes = 4 * 1_024
    static let maximumIntervalSeconds = 366 * 24 * 60 * 60
    static let maximumCatchUpRuns = 32
}

enum AutomationError: LocalizedError, Equatable, Sendable {
    case invalidDefinition(String)
    case invalidSchedule(String)
    case invalidEvent(String)
    case invalidRun(String)
    case automationNotFound(UUID)
    case runNotFound(UUID)
    case duplicateAutomation(UUID)
    case duplicateOccurrence(String)
    case activeRuns(UUID)
    case invalidTransition(AutomationRunStatus)
    case unavailable
    case capacityExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidDefinition(let detail):
            "Automation 定義無效：\(detail)"
        case .invalidSchedule(let detail):
            "Automation 排程無效：\(detail)"
        case .invalidEvent(let detail):
            "Automation event 無效：\(detail)"
        case .invalidRun(let detail):
            "Automation run 無效：\(detail)"
        case .automationNotFound(let id):
            "找不到 Automation \(id.uuidString)。"
        case .runNotFound(let id):
            "找不到 Automation run \(id.uuidString)。"
        case .duplicateAutomation(let id):
            "Automation \(id.uuidString) 已存在。"
        case .duplicateOccurrence(let key):
            "Automation occurrence 已處理：\(key)。"
        case .activeRuns(let id):
            "Automation \(id.uuidString) 仍有執行中的 run。"
        case .invalidTransition(let status):
            "Automation run 狀態 \(status.rawValue) 不允許這個操作。"
        case .unavailable:
            "Automation scheduler 尚未啟動。"
        case .capacityExceeded(let detail):
            "Automation 容量已達安全上限：\(detail)"
        }
    }
}

enum AutomationWorktreeMode: String, Codable, CaseIterable, Sendable {
    case none
    case reuseProject = "reuse_project"
    case dedicated
}

enum AutomationActionKind: String, Codable, CaseIterable, Sendable {
    case agentTask = "agent_task"
    case goal
    case skill
    case projectJob = "project_job"
    case tests
    case repositoryCheck = "repository_check"
    case reviewChanges = "review_changes"

    /// These action classes can legitimately write source state. Recurring or
    /// event-driven instances are therefore never allowed to reuse a main
    /// checkout, even if imported persistence asks for it.
    var isMutationCapable: Bool {
        switch self {
        case .agentTask, .goal, .skill, .projectJob, .tests, .repositoryCheck:
            // A repository check may carry a user-authored executable argv.
            // Its intent can be read-only, but the process itself cannot be
            // proven non-mutating, so recurring runs receive full isolation.
            true
        case .reviewChanges:
            false
        }
    }
}

struct AutomationSkillInvocation: Codable, Equatable, Sendable {
    var name: String
    var arguments: [String: String]

    init(name: String, arguments: [String: String] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

struct AutomationCommandInvocation: Codable, Equatable, Sendable {
    /// A basename such as `swift` or `git`, never a shell command line/path.
    var executable: String
    var arguments: [String]
    var workingDirectory: String

    init(executable: String, arguments: [String] = [], workingDirectory: String = ".") {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

struct AutomationReviewRequest: Codable, Equatable, Sendable {
    var sourceSessionID: UUID
    var instructions: String

    init(sourceSessionID: UUID, instructions: String) {
        self.sourceSessionID = sourceSessionID
        self.instructions = instructions
    }
}

struct AutomationTaskSpec: Codable, Equatable, Sendable {
    var actionKind: AutomationActionKind
    var prompt: String
    var projectID: UUID?
    var parentSessionID: UUID?
    var worktreeMode: AutomationWorktreeMode
    var goal: String?
    var skill: AutomationSkillInvocation?
    var command: AutomationCommandInvocation?
    var review: AutomationReviewRequest?
    var metadata: [String: String]

    init(
        actionKind: AutomationActionKind = .agentTask,
        prompt: String,
        projectID: UUID? = nil,
        parentSessionID: UUID? = nil,
        worktreeMode: AutomationWorktreeMode = .dedicated,
        goal: String? = nil,
        skill: AutomationSkillInvocation? = nil,
        command: AutomationCommandInvocation? = nil,
        review: AutomationReviewRequest? = nil,
        metadata: [String: String] = [:]
    ) {
        self.actionKind = actionKind
        self.prompt = prompt
        self.projectID = projectID
        self.parentSessionID = parentSessionID
        self.worktreeMode = worktreeMode
        self.goal = goal
        self.skill = skill
        self.command = command
        self.review = review
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case actionKind, kind, prompt, projectID, parentSessionID, worktreeMode
        case goal, skill, command, review, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionKind = try container.decodeIfPresent(AutomationActionKind.self, forKey: .actionKind)
            ?? container.decodeIfPresent(AutomationActionKind.self, forKey: .kind)
            ?? .agentTask
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
        worktreeMode = try container.decodeIfPresent(
            AutomationWorktreeMode.self,
            forKey: .worktreeMode
        ) ?? .dedicated
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        skill = try container.decodeIfPresent(AutomationSkillInvocation.self, forKey: .skill)
        command = try container.decodeIfPresent(AutomationCommandInvocation.self, forKey: .command)
        review = try container.decodeIfPresent(AutomationReviewRequest.self, forKey: .review)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

struct AutomationEventTrigger: Codable, Equatable, Sendable {
    var name: String
    /// Every listed key/value must be present in the emitted event. An empty
    /// filter matches every event with the same name.
    var matchingPayload: [String: String]

    init(name: String, matchingPayload: [String: String] = [:]) {
        self.name = name
        self.matchingPayload = matchingPayload
    }

    func matches(_ event: AutomationEvent) -> Bool {
        name == event.name && matchingPayload.allSatisfy { event.payload[$0.key] == $0.value }
    }
}

struct AutomationEvent: Codable, Equatable, Sendable {
    /// Stable producer-supplied idempotency key. Re-emitting this ID does not
    /// create a second run for the same Automation.
    var id: String
    var name: String
    var occurredAt: Date
    var payload: [String: String]

    init(
        id: String,
        name: String,
        occurredAt: Date = Date(),
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

enum AutomationSchedule: Equatable, Sendable {
    case oneTime(at: Date)
    case interval(every: TimeInterval, anchor: Date)
    case cron(AutomationCronSchedule)
    case event(AutomationEventTrigger)
}

extension AutomationSchedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, runAt, at, everySeconds, intervalSeconds, anchor
        case cron, expression, timeZoneIdentifier
        case event, eventName, matchingPayload
    }

    private enum Kind: String, Codable {
        case oneTime = "one_time"
        case interval
        case cron
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .type)
        switch rawKind {
        case Kind.oneTime.rawValue, "oneTime", "once":
            guard let date = try container.decodeIfPresent(Date.self, forKey: .runAt)
                    ?? container.decodeIfPresent(Date.self, forKey: .at) else {
                throw AutomationError.invalidSchedule("one-time 缺少 runAt。")
            }
            self = .oneTime(at: date)
        case Kind.interval.rawValue:
            guard let seconds = try container.decodeIfPresent(Double.self, forKey: .everySeconds)
                    ?? container.decodeIfPresent(Double.self, forKey: .intervalSeconds) else {
                throw AutomationError.invalidSchedule("interval 缺少 everySeconds。")
            }
            let anchor = try container.decodeIfPresent(Date.self, forKey: .anchor)
                ?? Date(timeIntervalSince1970: 0)
            self = .interval(every: seconds, anchor: anchor)
        case Kind.cron.rawValue:
            if let cron = try container.decodeIfPresent(AutomationCronSchedule.self, forKey: .cron) {
                self = .cron(cron)
            } else {
                let expression = try container.decode(String.self, forKey: .expression)
                let zone = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
                    ?? "UTC"
                self = .cron(AutomationCronSchedule(
                    expression: expression,
                    timeZoneIdentifier: zone
                ))
            }
        case Kind.event.rawValue, "event_triggered":
            if let event = try container.decodeIfPresent(AutomationEventTrigger.self, forKey: .event) {
                self = .event(event)
            } else {
                self = .event(AutomationEventTrigger(
                    name: try container.decode(String.self, forKey: .eventName),
                    matchingPayload: try container.decodeIfPresent(
                        [String: String].self,
                        forKey: .matchingPayload
                    ) ?? [:]
                ))
            }
        default:
            throw AutomationError.invalidSchedule("不支援的 type：\(rawKind)。")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oneTime(let date):
            try container.encode(Kind.oneTime.rawValue, forKey: .type)
            try container.encode(date, forKey: .runAt)
        case .interval(let seconds, let anchor):
            try container.encode(Kind.interval.rawValue, forKey: .type)
            try container.encode(seconds, forKey: .everySeconds)
            try container.encode(anchor, forKey: .anchor)
        case .cron(let cron):
            try container.encode(Kind.cron.rawValue, forKey: .type)
            try container.encode(cron, forKey: .cron)
        case .event(let event):
            try container.encode(Kind.event.rawValue, forKey: .type)
            try container.encode(event, forKey: .event)
        }
    }
}

enum AutomationMissedRunPolicy: Equatable, Sendable {
    case skip
    case runOnce
    case catchUp(maxRuns: Int)
}

extension AutomationMissedRunPolicy: Codable {
    private enum CodingKeys: String, CodingKey { case type, maxRuns }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            switch value {
            case "skip": self = .skip
            case "run_once", "runOnce": self = .runOnce
            case "catch_up", "catchUp": self = .catchUp(maxRuns: 1)
            default: throw AutomationError.invalidDefinition("未知 missed-run policy。")
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "skip": self = .skip
        case "run_once", "runOnce": self = .runOnce
        case "catch_up", "catchUp":
            self = .catchUp(maxRuns: try container.decodeIfPresent(Int.self, forKey: .maxRuns) ?? 1)
        default: throw AutomationError.invalidDefinition("未知 missed-run policy。")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skip:
            try container.encode("skip", forKey: .type)
        case .runOnce:
            try container.encode("run_once", forKey: .type)
        case .catchUp(let maximum):
            try container.encode("catch_up", forKey: .type)
            try container.encode(maximum, forKey: .maxRuns)
        }
    }
}

struct AutomationDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var schedule: AutomationSchedule
    var task: AutomationTaskSpec
    var missedRunPolicy: AutomationMissedRunPolicy
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        schedule: AutomationSchedule,
        task: AutomationTaskSpec,
        missedRunPolicy: AutomationMissedRunPolicy = .runOnce,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.task = task
        self.missedRunPolicy = missedRunPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, enabled, schedule, task, prompt
        case missedRunPolicy, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? true
        schedule = try container.decode(AutomationSchedule.self, forKey: .schedule)
        task = try container.decodeIfPresent(AutomationTaskSpec.self, forKey: .task)
            ?? AutomationTaskSpec(prompt: container.decodeIfPresent(String.self, forKey: .prompt) ?? "")
        missedRunPolicy = try container.decodeIfPresent(
            AutomationMissedRunPolicy.self,
            forKey: .missedRunPolicy
        ) ?? .runOnce
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            ?? Date(timeIntervalSince1970: 0)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

enum AutomationRunStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case interrupted
    case skipped

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted, .skipped: true
        case .queued, .running: false
        }
    }
}

enum AutomationLogLevel: String, Codable, CaseIterable, Sendable {
    case debug, info, warning, error
}

struct AutomationLogEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: AutomationLogLevel
    var message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: AutomationLogLevel = .info,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

enum AutomationChangeKind: String, Codable, CaseIterable, Sendable {
    case created, modified, deleted, renamed
}

struct AutomationChangeRecord: Codable, Equatable, Sendable {
    /// Workspace-relative path. Absolute paths and traversal are rejected.
    var path: String
    var kind: AutomationChangeKind
    var summary: String?

    init(path: String, kind: AutomationChangeKind, summary: String? = nil) {
        self.path = path
        self.kind = kind
        self.summary = summary
    }
}

struct AutomationRunResult: Codable, Equatable, Sendable {
    var summary: String
    /// Paths relative to this run's repo-local artifact directory.
    var artifacts: [String]
    var metadata: [String: String]

    init(
        summary: String,
        artifacts: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.summary = summary
        self.artifacts = artifacts
        self.metadata = metadata
    }
}

struct AutomationRunWorktree: Codable, Equatable, Sendable {
    var requestedMode: AutomationWorktreeMode
    var path: String?
    var branch: String?
    var startingRevision: String?
    var endingRevision: String?
    var retained: Bool

    init(
        requestedMode: AutomationWorktreeMode,
        path: String? = nil,
        branch: String? = nil,
        startingRevision: String? = nil,
        endingRevision: String? = nil,
        retained: Bool = true
    ) {
        self.requestedMode = requestedMode
        self.path = path
        self.branch = branch
        self.startingRevision = startingRevision
        self.endingRevision = endingRevision
        self.retained = retained
    }
}

struct AutomationRunRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var automationID: UUID
    var occurrenceKey: String
    var scheduledAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var status: AutomationRunStatus
    var log: [AutomationLogEntry]
    var result: AutomationRunResult?
    var changes: [AutomationChangeRecord]
    var worktree: AutomationRunWorktree
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        automationID: UUID,
        occurrenceKey: String,
        scheduledAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        status: AutomationRunStatus = .queued,
        log: [AutomationLogEntry] = [],
        result: AutomationRunResult? = nil,
        changes: [AutomationChangeRecord] = [],
        worktree: AutomationRunWorktree,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.occurrenceKey = occurrenceKey
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.log = log
        self.result = result
        self.changes = changes
        self.worktree = worktree
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, automationID, occurrenceKey, scheduledAt, startedAt, endedAt
        case status, log, logs, result, changes, worktree, errorMessage, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        automationID = try container.decode(UUID.self, forKey: .automationID)
        occurrenceKey = try container.decodeIfPresent(String.self, forKey: .occurrenceKey)
            ?? "legacy:\(id.uuidString.lowercased())"
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
            ?? container.decodeIfPresent(Date.self, forKey: .startedAt)
            ?? Date(timeIntervalSince1970: 0)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        if let decoded = try? container.decode(AutomationRunStatus.self, forKey: .status) {
            status = decoded
        } else {
            let legacy = try container.decode(String.self, forKey: .status)
            status = legacy == "completed" ? .succeeded : .failed
        }
        log = try container.decodeIfPresent([AutomationLogEntry].self, forKey: .log)
            ?? container.decodeIfPresent([AutomationLogEntry].self, forKey: .logs)
            ?? []
        result = try container.decodeIfPresent(AutomationRunResult.self, forKey: .result)
        changes = try container.decodeIfPresent([AutomationChangeRecord].self, forKey: .changes) ?? []
        worktree = try container.decodeIfPresent(AutomationRunWorktree.self, forKey: .worktree)
            ?? AutomationRunWorktree(requestedMode: .none)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            ?? container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct AutomationExecutionRequest: Sendable {
    var definition: AutomationDefinition
    var run: AutomationRunRecord
    /// A unique directory beneath `tmp/automation-runs`. Executors may create
    /// artifacts here but must return artifact paths relative to this URL.
    var artifactDirectory: URL
}

struct AutomationExecutionOutcome: Sendable {
    var status: AutomationRunStatus
    var log: [AutomationLogEntry]
    var result: AutomationRunResult?
    var changes: [AutomationChangeRecord]
    var worktree: AutomationRunWorktree?
    var errorMessage: String?

    init(
        status: AutomationRunStatus,
        log: [AutomationLogEntry] = [],
        result: AutomationRunResult? = nil,
        changes: [AutomationChangeRecord] = [],
        worktree: AutomationRunWorktree? = nil,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.log = log
        self.result = result
        self.changes = changes
        self.worktree = worktree
        self.errorMessage = errorMessage
    }
}

typealias AutomationExecutionHandler = @Sendable (
    AutomationExecutionRequest
) async -> AutomationExecutionOutcome

struct AutomationOccurrenceClaim: Codable, Equatable, Sendable {
    var key: String
    var claimedAt: Date
    var runID: UUID
}

struct AutomationSchedulerState: Codable, Equatable, Sendable {
    var lastEvaluationAt: Date?
    var lastScheduledAtByAutomation: [UUID: Date]
    var occurrenceClaims: [AutomationOccurrenceClaim]

    init(
        lastEvaluationAt: Date? = nil,
        lastScheduledAtByAutomation: [UUID: Date] = [:],
        occurrenceClaims: [AutomationOccurrenceClaim] = []
    ) {
        self.lastEvaluationAt = lastEvaluationAt
        self.lastScheduledAtByAutomation = lastScheduledAtByAutomation
        self.occurrenceClaims = occurrenceClaims
    }

    private enum CodingKeys: String, CodingKey {
        case lastEvaluationAt, lastScheduledAtByAutomation, occurrenceClaims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastEvaluationAt = try container.decodeIfPresent(Date.self, forKey: .lastEvaluationAt)
        lastScheduledAtByAutomation = try container.decodeIfPresent(
            [UUID: Date].self,
            forKey: .lastScheduledAtByAutomation
        ) ?? [:]
        occurrenceClaims = try container.decodeIfPresent(
            [AutomationOccurrenceClaim].self,
            forKey: .occurrenceClaims
        ) ?? []
    }
}

struct AutomationSnapshot: Codable, Equatable, Sendable {
    var automations: [AutomationDefinition]
    var runs: [AutomationRunRecord]
    var schedulerState: AutomationSchedulerState

    init(
        automations: [AutomationDefinition] = [],
        runs: [AutomationRunRecord] = [],
        schedulerState: AutomationSchedulerState = AutomationSchedulerState()
    ) {
        self.automations = automations
        self.runs = runs
        self.schedulerState = schedulerState
    }
}
