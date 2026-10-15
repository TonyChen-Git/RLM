import Foundation

enum SelfManagedWorkerOperation: String, Codable, Sendable {
    case hello, start, status, cancel, logs, diff
}

struct SelfManagedWorkerRequest: Encodable, Sendable {
    let `protocol`: Int
    let operation: SelfManagedWorkerOperation
    let repo: String
    var jobID: UUID?
    var argv: [String]?
    var ref: String?
    var network: String?
    var offset: Int?

    init(operation: SelfManagedWorkerOperation, repo: String, jobID: UUID? = nil,
         argv: [String]? = nil, ref: String? = nil, network: String? = nil,
         offset: Int? = nil) {
        self.protocol = 1
        self.operation = operation
        self.repo = repo
        self.jobID = jobID
        self.argv = argv
        self.ref = ref
        self.network = network
        self.offset = offset
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`, operation, repo, argv, ref, network, offset
        case jobID = "job_id"
    }
}

struct SelfManagedWorkerHello: Decodable, Sendable {
    let `protocol`: Int
    let worker: String
    let repo: String
    let uid: UInt32
    let platform: String
    let capabilities: [String]
}

struct SelfManagedWorkerJob: Codable, Equatable, Sendable {
    let `protocol`: Int
    let jobID: UUID
    let checkout: String
    let commit: String
    let network: String
    let status: String
    let createdAt: Date
    let heartbeatAt: Date
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case `protocol`, checkout, commit, network, status
        case jobID = "job_id"
        case createdAt = "created_at"
        case heartbeatAt = "heartbeat_at"
        case exitCode = "exit_code"
    }
}

struct SelfManagedWorkerLogs: Decodable, Sendable {
    let offset: Int
    let nextOffset: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case offset, text
        case nextOffset = "next_offset"
    }
}

struct SelfManagedWorkerDiff: Decodable, Sendable {
    let jobID: UUID
    let commit: String
    let diff: String

    enum CodingKeys: String, CodingKey {
        case commit, diff
        case jobID = "job_id"
    }
}

private struct SelfManagedWorkerEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: String?
    let detail: String?
}

enum SelfManagedWorkerError: LocalizedError, Sendable {
    case protocolViolation
    case remote(String)
    case authorityChanged

    var errorDescription: String? {
        switch self {
        case .protocolViolation: "遠端 worker 回覆不符合協定。"
        case .remote(let value): "遠端 worker 無法執行：\(value)"
        case .authorityChanged: "SSH 主機身分、憑證或 Task 執行位置已變更。"
        }
    }
}

/// Every call creates a fresh host-verified outbound SSH connection. The
/// worker is addressed only through the Task's pinned runner authority.
struct SelfManagedRemoteWorkerService: Sendable {
    let runnerService: any RemoteRunnerServicing
    var validateTaskAuthority: @Sendable () async throws -> Void = {}

    func hello(identity: AgentRemoteExecutionIdentity) async throws -> SelfManagedWorkerHello {
        try await validateTaskAuthority()
        let backend = try await runnerService.backend(for: identity.runnerID, matching: identity)
        try await validateTaskAuthority()
        let receipt = try await backend.verifyConnection()
        let response: SelfManagedWorkerHello = try await call(.init(
            operation: .hello, repo: identity.workspaceRoot
        ), identity: identity)
        guard response.protocol == 1,
              response.worker == "lumachat-worker",
              response.repo == identity.workspaceRoot,
              response.uid == receipt.effectiveUserID,
              response.platform == "linux",
              Set(["worktree", "heartbeat", "reconnect", "cancel", "logs", "diff"])
                .isSubset(of: Set(response.capabilities)) else {
            throw SelfManagedWorkerError.protocolViolation
        }
        return response
    }

    func start(identity: AgentRemoteExecutionIdentity, jobID: UUID,
               argv: [String], ref: String = "HEAD", network: String = "deny") async throws -> SelfManagedWorkerJob {
        guard ["allow", "deny"].contains(network) else {
            throw SelfManagedWorkerError.protocolViolation
        }
        let hello = try await hello(identity: identity)
        guard network == "allow" || hello.capabilities.contains("network_deny") else {
            throw SelfManagedWorkerError.remote("遠端主機無法隔離網路；此 job 未啟動。")
        }
        let result: SelfManagedWorkerJob = try await call(.init(
            operation: .start, repo: identity.workspaceRoot,
            jobID: jobID, argv: argv, ref: ref, network: network
        ), identity: identity)
        guard result.network == network else { throw SelfManagedWorkerError.protocolViolation }
        return try validated(result, expected: jobID)
    }

    func status(identity: AgentRemoteExecutionIdentity, jobID: UUID) async throws -> SelfManagedWorkerJob {
        let result: SelfManagedWorkerJob = try await call(.init(
            operation: .status, repo: identity.workspaceRoot, jobID: jobID
        ), identity: identity)
        return try validated(result, expected: jobID)
    }

    func cancel(identity: AgentRemoteExecutionIdentity, jobID: UUID) async throws -> SelfManagedWorkerJob {
        let result: SelfManagedWorkerJob = try await call(.init(
            operation: .cancel, repo: identity.workspaceRoot, jobID: jobID
        ), identity: identity)
        return try validated(result, expected: jobID)
    }

    func logs(identity: AgentRemoteExecutionIdentity, jobID: UUID,
              offset: Int = 0) async throws -> SelfManagedWorkerLogs {
        guard (0...8 * 1_024 * 1_024).contains(offset) else {
            throw SelfManagedWorkerError.protocolViolation
        }
        let result: SelfManagedWorkerLogs = try await call(.init(
            operation: .logs, repo: identity.workspaceRoot, jobID: jobID, offset: offset
        ), identity: identity)
        guard result.offset == offset, result.nextOffset >= offset,
              result.nextOffset <= 8 * 1_024 * 1_024,
              result.nextOffset - offset <= 64 * 1_024,
              result.nextOffset > offset || result.text.isEmpty,
              result.text.utf8.count <= 256 * 1_024 else {
            throw SelfManagedWorkerError.protocolViolation
        }
        return result
    }

    func diff(identity: AgentRemoteExecutionIdentity, jobID: UUID) async throws -> SelfManagedWorkerDiff {
        let result: SelfManagedWorkerDiff = try await call(.init(
            operation: .diff, repo: identity.workspaceRoot, jobID: jobID
        ), identity: identity)
        guard result.jobID == jobID, Self.isCommit(result.commit),
              result.diff.utf8.count <= 768 * 1_024 else {
            throw SelfManagedWorkerError.protocolViolation
        }
        return result
    }

    private func validated(_ result: SelfManagedWorkerJob, expected: UUID) throws -> SelfManagedWorkerJob {
        guard result.protocol == 1, result.jobID == expected,
              ["queued", "running", "completed", "failed", "cancelled", "interrupted"]
                .contains(result.status),
              result.checkout.hasPrefix("/"), result.checkout.utf8.count <= 4_096,
              !result.checkout.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              !result.checkout.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              Self.isCommit(result.commit), ["allow", "deny"].contains(result.network),
              result.createdAt.timeIntervalSince1970.isFinite,
              result.createdAt.timeIntervalSince1970 >= 0,
              result.heartbeatAt.timeIntervalSince1970.isFinite,
              result.heartbeatAt >= result.createdAt else {
            throw SelfManagedWorkerError.protocolViolation
        }
        return result
    }

    private static func isCommit(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func call<T: Decodable>(_ request: SelfManagedWorkerRequest,
                                    identity: AgentRemoteExecutionIdentity) async throws -> T {
        try await validateTaskAuthority()
        let current = try await runnerService.executionIdentity(for: identity.runnerID)
        guard current == identity else { throw SelfManagedWorkerError.authorityChanged }
        let data = try JSONEncoder().encode(request)
        guard data.count <= 64 * 1_024 else { throw SelfManagedWorkerError.protocolViolation }
        try await validateTaskAuthority()
        let reply = try await runnerService.workerCall(
            request: data, runnerID: identity.runnerID, matching: identity
        )
        try await validateTaskAuthority()
        // A suspended SSH request may finish after the user changes or removes
        // its runner. Never publish that old authority's reply into this Task.
        guard try await runnerService.executionIdentity(for: identity.runnerID) == identity else {
            throw SelfManagedWorkerError.authorityChanged
        }
        try await validateTaskAuthority()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard reply.count <= 1 * 1_024 * 1_024,
              let envelope = try? decoder.decode(SelfManagedWorkerEnvelope<T>.self, from: reply) else {
            throw SelfManagedWorkerError.protocolViolation
        }
        guard envelope.ok, let result = envelope.result else {
            throw SelfManagedWorkerError.remote(
                String((envelope.detail ?? envelope.error ?? "unknown error").prefix(500))
            )
        }
        return result
    }
}
