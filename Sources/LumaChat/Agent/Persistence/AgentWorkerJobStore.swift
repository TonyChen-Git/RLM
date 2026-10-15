import Foundation

struct AgentWorkerJobBinding: Codable, Equatable, Sendable {
    let sessionID: UUID
    let jobID: UUID
    let identity: AgentRemoteExecutionIdentity
    let submittedAt: Date
    var workspaceID: UUID? = nil
    var permissionFingerprint: String? = nil
}

/// One durable, Task-scoped remote job pointer. Persist before the outbound
/// start call so an uncertain SSH result can always be reconciled by job ID.
struct AgentWorkerJobStore: Sendable {
    let sessionsRoot: URL

    init(sessionsRoot: URL = AppPaths.agentSessions) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
    }

    func load(sessionID: UUID) throws -> AgentWorkerJobBinding? {
        let data: Data
        do {
            guard let stored = try AgentInteractionFileIO.read(
                sessionsRoot: sessionsRoot, sessionID: sessionID,
                name: "remote-worker-job.json", maximumBytes: 16 * 1_024
            ) else { return nil }
            data = stored
        } catch { throw SelfManagedWorkerError.protocolViolation }
        guard let binding = try? JSONDecoder().decode(AgentWorkerJobBinding.self, from: data),
              binding.sessionID == sessionID else {
            throw SelfManagedWorkerError.protocolViolation
        }
        return binding
    }

    func save(_ binding: AgentWorkerJobBinding) throws {
        let data = try JSONEncoder().encode(binding)
        guard data.count <= 16 * 1_024 else { throw SelfManagedWorkerError.protocolViolation }
        do {
            try AgentInteractionFileIO.write(
                data, sessionsRoot: sessionsRoot, sessionID: binding.sessionID,
                name: "remote-worker-job.json"
            )
        } catch { throw SelfManagedWorkerError.protocolViolation }
    }
}
