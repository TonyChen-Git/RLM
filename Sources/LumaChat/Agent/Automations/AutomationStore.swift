import Darwin
import Foundation

protocol AutomationPersisting: Sendable {
    func loadSnapshot() async throws -> AutomationSnapshot
    func saveSnapshot(_ snapshot: AutomationSnapshot) async throws
}

enum AutomationStoreError: LocalizedError, Equatable, Sendable {
    case invalidLocation
    case unsafeFile
    case oversized(Int)
    case unsupportedVersion(Int)
    case invalidSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            "Automation persistence 路徑無效。"
        case .unsafeFile:
            "Automation persistence 不是安全的 regular file。"
        case .oversized(let maximum):
            "Automation persistence 超過 \(maximum) bytes。"
        case .unsupportedVersion(let version):
            "不支援 Automation schema version \(version)。"
        case .invalidSnapshot(let detail):
            "Automation persistence 內容無效：\(detail)"
        }
    }
}

/// One versioned snapshot is atomically replaced after each scheduler state
/// transition. Version 1 and the early unversioned snapshot shape remain
/// readable; every successful save upgrades them to version 2.
actor AutomationStore: AutomationPersisting {
    private struct VersionProbe: Decodable { var version: Int? }

    private struct EnvelopeV2: Codable {
        var version: Int
        var automations: [AutomationDefinition]
        var runs: [AutomationRunRecord]
        var schedulerState: AutomationSchedulerState
    }

    private struct EnvelopeV1: Decodable {
        var automations: [AutomationDefinition]
        var runs: [AutomationRunRecord]
        var schedulerState: AutomationSchedulerState?
        var lastEvaluationAt: Date?

        private enum CodingKeys: String, CodingKey {
            case automations, runs, schedulerState, lastEvaluationAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            automations = try container.decodeIfPresent(
                [AutomationDefinition].self,
                forKey: .automations
            ) ?? []
            runs = try container.decodeIfPresent([AutomationRunRecord].self, forKey: .runs) ?? []
            schedulerState = try container.decodeIfPresent(
                AutomationSchedulerState.self,
                forKey: .schedulerState
            )
            lastEvaluationAt = try container.decodeIfPresent(Date.self, forKey: .lastEvaluationAt)
        }
    }

    static let currentVersion = 2

    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = AppPaths.appSupport
            .appendingPathComponent("AgentAutomations", isDirectory: true)
            .appendingPathComponent("automations.json", isDirectory: false)
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL.standardizedFileURL
    }

    func loadSnapshot() throws -> AutomationSnapshot {
        try validateLocation()
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: fileURL.path) else { return AutomationSnapshot() }

        let data = try Self.readRegularFile(fileURL)
        let decoder = JSONDecoder()
        let probe = try? decoder.decode(VersionProbe.self, from: data)
        let version = probe?.version
        let snapshot: AutomationSnapshot
        switch version {
        case .some(Self.currentVersion):
            let envelope = try decoder.decode(EnvelopeV2.self, from: data)
            snapshot = AutomationSnapshot(
                automations: envelope.automations,
                runs: envelope.runs,
                schedulerState: envelope.schedulerState
            )
        case .some(1), .none:
            let legacy = try decoder.decode(EnvelopeV1.self, from: data)
            var state = legacy.schedulerState ?? AutomationSchedulerState()
            if state.lastEvaluationAt == nil { state.lastEvaluationAt = legacy.lastEvaluationAt }
            snapshot = AutomationSnapshot(
                automations: legacy.automations,
                runs: legacy.runs,
                schedulerState: state
            )
        case .some(let unsupported):
            throw AutomationStoreError.unsupportedVersion(unsupported)
        }
        try AutomationValidation.validate(snapshot)
        return snapshot
    }

    func saveSnapshot(_ snapshot: AutomationSnapshot) throws {
        try validateLocation()
        try AutomationValidation.validate(snapshot)
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let envelope = EnvelopeV2(
            version: Self.currentVersion,
            automations: snapshot.automations.sorted(by: Self.definitionSort),
            runs: snapshot.runs.sorted(by: Self.runSort),
            schedulerState: snapshot.schedulerState
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= AutomationLimits.maximumFileBytes else {
            throw AutomationStoreError.oversized(AutomationLimits.maximumFileBytes)
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private func validateLocation() throws {
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              fileURL.path != "/",
              !name.isEmpty,
              name != ".",
              name != "..",
              !name.hasPrefix("._") else {
            throw AutomationStoreError.invalidLocation
        }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AutomationStoreError.unsafeFile }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0 else {
            throw AutomationStoreError.unsafeFile
        }
        guard info.st_size <= off_t(AutomationLimits.maximumFileBytes) else {
            throw AutomationStoreError.oversized(AutomationLimits.maximumFileBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.EIO) }
            if count == 0 { break }
            guard data.count <= AutomationLimits.maximumFileBytes - count else {
                throw AutomationStoreError.oversized(AutomationLimits.maximumFileBytes)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func definitionSort(
        _ lhs: AutomationDefinition,
        _ rhs: AutomationDefinition
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.createdAt < rhs.createdAt
    }

    private static func runSort(_ lhs: AutomationRunRecord, _ rhs: AutomationRunRecord) -> Bool {
        if lhs.scheduledAt == rhs.scheduledAt { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.scheduledAt < rhs.scheduledAt
    }
}

enum AutomationValidation {
    static func validatedDefinition(_ input: AutomationDefinition) throws -> AutomationDefinition {
        var definition = input
        definition.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.task.prompt = definition.task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        definition.task.goal = definition.task.goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        if var skill = definition.task.skill {
            skill.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.task.skill = skill
        }
        if var command = definition.task.command {
            command.executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.task.command = command
        }
        if var review = definition.task.review {
            review.instructions = review.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            definition.task.review = review
        }
        try validate(definition)
        return definition
    }

    static func validatedEvent(_ input: AutomationEvent, now: Date) throws -> AutomationEvent {
        var event = input
        event.id = event.id.trimmingCharacters(in: .whitespacesAndNewlines)
        event.name = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.id.isEmpty,
              event.id.utf8.count <= AutomationLimits.maximumEventIDBytes,
              !event.name.isEmpty,
              event.name.utf8.count <= AutomationLimits.maximumEventNameBytes,
              event.occurredAt.timeIntervalSince1970.isFinite,
              event.occurredAt <= now.addingTimeInterval(300),
              event.payload.count <= AutomationLimits.maximumEventPayloadEntries else {
            throw AutomationError.invalidEvent("欄位為空、過長、過多或 occurredAt 位於未來。")
        }
        try validateMetadata(event.payload, label: "event payload")
        return event
    }

    static func validate(_ snapshot: AutomationSnapshot) throws {
        guard snapshot.automations.count <= AutomationLimits.maximumAutomations else {
            throw AutomationStoreError.invalidSnapshot("Automation 數量超過上限。")
        }
        guard snapshot.runs.count <= AutomationLimits.maximumRuns else {
            throw AutomationStoreError.invalidSnapshot("Run history 超過上限。")
        }
        guard snapshot.schedulerState.occurrenceClaims.count
                <= AutomationLimits.maximumOccurrenceClaims else {
            throw AutomationStoreError.invalidSnapshot("Occurrence claim 超過上限。")
        }

        var definitionIDs = Set<UUID>()
        for definition in snapshot.automations {
            guard definitionIDs.insert(definition.id).inserted else {
                throw AutomationStoreError.invalidSnapshot("Automation ID 重複。")
            }
            do { try validate(definition) } catch {
                throw AutomationStoreError.invalidSnapshot(error.localizedDescription)
            }
        }

        var runIDs = Set<UUID>()
        var occurrenceIDs = Set<String>()
        var queuedCount = 0
        for run in snapshot.runs {
            guard runIDs.insert(run.id).inserted else {
                throw AutomationStoreError.invalidSnapshot("Run ID 重複。")
            }
            let occurrenceID = run.automationID.uuidString + "\u{0}" + run.occurrenceKey
            guard occurrenceIDs.insert(occurrenceID).inserted else {
                throw AutomationStoreError.invalidSnapshot("Run occurrence 重複。")
            }
            if run.status == .queued { queuedCount += 1 }
            do { try validate(run) } catch {
                throw AutomationStoreError.invalidSnapshot(error.localizedDescription)
            }
        }
        guard queuedCount <= AutomationLimits.maximumQueuedRuns else {
            throw AutomationStoreError.invalidSnapshot("Queued run 超過上限。")
        }

        var claimKeys = Set<String>()
        for claim in snapshot.schedulerState.occurrenceClaims {
            guard !claim.key.isEmpty,
                  claim.key.utf8.count <= 1_024,
                  claim.claimedAt.timeIntervalSince1970.isFinite,
                  claimKeys.insert(claim.key).inserted else {
                throw AutomationStoreError.invalidSnapshot("Occurrence claim 無效或重複。")
            }
        }
        if let date = snapshot.schedulerState.lastEvaluationAt,
           !date.timeIntervalSince1970.isFinite {
            throw AutomationStoreError.invalidSnapshot("lastEvaluationAt 無效。")
        }
        guard snapshot.schedulerState.lastScheduledAtByAutomation.values.allSatisfy({
            $0.timeIntervalSince1970.isFinite
        }) else {
            throw AutomationStoreError.invalidSnapshot("lastScheduledAt 無效。")
        }
    }

    static func validate(_ definition: AutomationDefinition) throws {
        guard !definition.name.isEmpty,
              definition.name.utf8.count <= AutomationLimits.maximumNameBytes,
              !definition.task.prompt.isEmpty,
              definition.task.prompt.utf8.count <= AutomationLimits.maximumPromptBytes,
              definition.createdAt.timeIntervalSince1970.isFinite,
              definition.updatedAt.timeIntervalSince1970.isFinite,
              definition.updatedAt >= definition.createdAt else {
            throw AutomationError.invalidDefinition("名稱、prompt 或時間欄位不合法。")
        }
        try validateMetadata(definition.task.metadata, label: "task metadata")
        try validateAction(definition.task)
        switch definition.missedRunPolicy {
        case .skip, .runOnce:
            break
        case .catchUp(let maximum):
            guard (1...AutomationLimits.maximumCatchUpRuns).contains(maximum) else {
                throw AutomationError.invalidDefinition("catch-up 必須介於 1...32。")
            }
        }
        switch definition.schedule {
        case .oneTime(let date):
            guard date.timeIntervalSince1970.isFinite else {
                throw AutomationError.invalidSchedule("one-time 日期無效。")
            }
        case .interval(let seconds, let anchor):
            guard seconds.isFinite,
                  seconds >= 1,
                  seconds <= Double(AutomationLimits.maximumIntervalSeconds),
                  anchor.timeIntervalSince1970.isFinite else {
                throw AutomationError.invalidSchedule("interval 必須介於 1 秒與 366 天。")
            }
        case .cron(let cron):
            try cron.validate()
        case .event(let trigger):
            guard !trigger.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  trigger.name.utf8.count <= AutomationLimits.maximumEventNameBytes else {
                throw AutomationError.invalidSchedule("event name 為空或過長。")
            }
            try validateMetadata(trigger.matchingPayload, label: "event filter")
        }
        switch definition.schedule {
        case .oneTime:
            break
        case .interval, .cron, .event:
            guard !definition.task.actionKind.isMutationCapable
                    || definition.task.worktreeMode == .dedicated else {
                throw AutomationError.invalidDefinition(
                    "recurring/event mutation action 必須使用 dedicated worktree。"
                )
            }
        }
    }

    static func validate(_ run: AutomationRunRecord) throws {
        guard !run.occurrenceKey.isEmpty,
              run.occurrenceKey.utf8.count <= 1_024,
              run.scheduledAt.timeIntervalSince1970.isFinite,
              run.startedAt?.timeIntervalSince1970.isFinite ?? true,
              run.endedAt?.timeIntervalSince1970.isFinite ?? true,
              run.log.count <= AutomationLimits.maximumLogEntriesPerRun,
              run.changes.count <= AutomationLimits.maximumChangesPerRun else {
            throw AutomationError.invalidRun("基本欄位或 collection 超過上限。")
        }
        switch run.status {
        case .queued:
            guard run.startedAt == nil, run.endedAt == nil else {
                throw AutomationError.invalidRun("queued run 不可有 start/end。")
            }
        case .running:
            guard run.startedAt != nil, run.endedAt == nil else {
                throw AutomationError.invalidRun("running run 必須有 start 且不可有 end。")
            }
        case .succeeded, .failed, .cancelled, .interrupted, .skipped:
            guard let end = run.endedAt,
                  run.startedAt.map({ end >= $0 }) ?? true else {
                throw AutomationError.invalidRun("terminal run 必須有合法 end。")
            }
        }
        for entry in run.log {
            guard entry.timestamp.timeIntervalSince1970.isFinite,
                  !entry.message.isEmpty,
                  entry.message.utf8.count <= AutomationLimits.maximumLogMessageBytes else {
                throw AutomationError.invalidRun("log entry 無效。")
            }
        }
        if let result = run.result {
            guard result.summary.utf8.count <= AutomationLimits.maximumResultBytes,
                  result.artifacts.count <= AutomationLimits.maximumArtifactsPerRun else {
                throw AutomationError.invalidRun("result 超過上限。")
            }
            try validateMetadata(result.metadata, label: "result metadata")
            for artifact in result.artifacts { try validateRelativePath(artifact) }
        }
        for change in run.changes {
            try validateRelativePath(change.path)
            if let summary = change.summary,
               summary.utf8.count > AutomationLimits.maximumLogMessageBytes {
                throw AutomationError.invalidRun("change summary 過長。")
            }
        }
        if let path = run.worktree.path {
            guard path.utf8.count <= AutomationLimits.maximumPathBytes,
                  !path.contains("\u{0}"),
                  path.hasPrefix("/") else {
                throw AutomationError.invalidRun("worktree path 必須是 bounded absolute path。")
            }
        }
        for value in [
            run.worktree.branch,
            run.worktree.startingRevision,
            run.worktree.endingRevision,
            run.errorMessage
        ].compactMap({ $0 }) where value.utf8.count > AutomationLimits.maximumLogMessageBytes {
            throw AutomationError.invalidRun("worktree/error 欄位過長。")
        }
    }

    static func validateCompletion(_ outcome: AutomationExecutionOutcome) throws {
        guard [.succeeded, .failed, .cancelled].contains(outcome.status) else {
            throw AutomationError.invalidRun("executor 只能回傳 succeeded/failed/cancelled。")
        }
        let now = Date()
        let placeholder = AutomationRunRecord(
            automationID: UUID(),
            occurrenceKey: "validation",
            scheduledAt: now,
            startedAt: now,
            endedAt: now,
            status: outcome.status,
            log: outcome.log,
            result: outcome.result,
            changes: outcome.changes,
            worktree: outcome.worktree ?? AutomationRunWorktree(requestedMode: .none),
            errorMessage: outcome.errorMessage
        )
        try validate(placeholder)
    }

    static func validateLog(level: AutomationLogLevel, message: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= AutomationLimits.maximumLogMessageBytes else {
            throw AutomationError.invalidRun("log message 為空或過長。")
        }
        _ = level
        return trimmed
    }

    private static func validateMetadata(_ metadata: [String: String], label: String) throws {
        guard metadata.count <= AutomationLimits.maximumMetadataEntries else {
            throw AutomationError.invalidDefinition("\(label) 筆數超過上限。")
        }
        for (key, value) in metadata {
            guard !key.isEmpty,
                  key.utf8.count <= AutomationLimits.maximumMetadataKeyBytes,
                  value.utf8.count <= AutomationLimits.maximumMetadataValueBytes,
                  !key.contains("\u{0}"),
                  !value.contains("\u{0}") else {
                throw AutomationError.invalidDefinition("\(label) key/value 無效。")
            }
        }
    }

    private static func validateAction(_ task: AutomationTaskSpec) throws {
        let hasGoal = task.goal != nil
        let hasSkill = task.skill != nil
        let hasCommand = task.command != nil
        let hasReview = task.review != nil
        switch task.actionKind {
        case .agentTask:
            guard !hasGoal, !hasSkill, !hasCommand, !hasReview else {
                throw AutomationError.invalidDefinition("agent_task 含不相容的 action payload。")
            }
        case .goal:
            guard let goal = task.goal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !goal.isEmpty,
                  goal.utf8.count <= AutomationLimits.maximumPromptBytes,
                  !hasSkill, !hasCommand, !hasReview else {
                throw AutomationError.invalidDefinition("goal action 缺少合法 goal payload。")
            }
        case .skill:
            guard let skill = task.skill,
                  !skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.name.utf8.count <= AutomationLimits.maximumNameBytes,
                  !skill.name.contains("\u{0}"),
                  !hasGoal, !hasCommand, !hasReview else {
                throw AutomationError.invalidDefinition("skill action 缺少合法 skill payload。")
            }
            try validateMetadata(skill.arguments, label: "skill arguments")
        case .projectJob:
            guard task.projectID != nil,
                  !hasGoal, !hasSkill, !hasCommand, !hasReview else {
                throw AutomationError.invalidDefinition(
                    "project_job 必須指定 projectID 且不可混用其他 payload。"
                )
            }
        case .tests, .repositoryCheck:
            guard let command = task.command,
                  !command.executable.isEmpty,
                  command.executable.utf8.count <= AutomationLimits.maximumNameBytes,
                  !command.executable.contains("/"),
                  !command.executable.contains("\\"),
                  !command.executable.contains("\u{0}"),
                  command.arguments.count <= 128,
                  command.arguments.allSatisfy({
                      $0.utf8.count <= AutomationLimits.maximumMetadataValueBytes
                          && !$0.contains("\u{0}")
                  }),
                  !hasGoal, !hasSkill, !hasReview else {
                throw AutomationError.invalidDefinition(
                    "tests/repository_check 必須使用 bounded argv command payload。"
                )
            }
            if command.workingDirectory != "." {
                do { try validateRelativePath(command.workingDirectory) } catch {
                    throw AutomationError.invalidDefinition("command workingDirectory 不安全。")
                }
            }
        case .reviewChanges:
            guard let review = task.review,
                  !review.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  review.instructions.utf8.count <= AutomationLimits.maximumPromptBytes,
                  task.worktreeMode != .dedicated,
                  !hasGoal, !hasSkill, !hasCommand else {
                throw AutomationError.invalidDefinition("review_changes 缺少合法 review payload。")
            }
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              path.utf8.count <= AutomationLimits.maximumPathBytes,
              !path.hasPrefix("/"),
              !path.contains("\u{0}"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AutomationError.invalidRun("artifact/change path 必須是安全的相對路徑。")
        }
    }
}
