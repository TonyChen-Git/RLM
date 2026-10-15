import CryptoKit
import Darwin
import Foundation

struct AgentSteerReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let acceptedAt: Date
    let redactedDigest: String
    /// Missing only in legacy digest-only records. Such records cannot prove
    /// which identical transcript message was delivered and stay uncertain.
    var redactedText: String? = nil

    var message: AgentMessage? {
        redactedText.map {
            AgentMessage(id: id, role: .user, content: $0,
                         name: "luma-agent-steer", createdAt: acceptedAt)
        }
    }
}

/// Atomically records bounded, redacted text before reporting acceptance.
/// Records never replay automatically: after a crash the exact message ID
/// must be present in the durable transcript, or the user resolves the send.
final class AgentSteerReceiptStore: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionsRoot: URL
    // JSON escaping may expand a bounded prompt to six bytes per input byte.
    private let maximumBytes = 1 * 1_024 * 1_024

    init(sessionsRoot: URL = AppPaths.agentSessions) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
    }

    @discardableResult
    func accept(_ text: String, sessionID: UUID) throws -> AgentSteerReceipt {
        lock.lock()
        defer { lock.unlock() }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = SecretRedactor().redact(text)
        guard !text.isEmpty, text.utf8.count <= AgentSteerMailbox.maximumPromptBytes,
              !redacted.isEmpty, redacted.utf8.count <= AgentSteerMailbox.maximumPromptBytes else {
            throw AgentQueuedFollowUpError.invalidPrompt
        }
        var receipts = try loadLocked(sessionID: sessionID)
        guard receipts.count < AgentSteerMailbox.maximumEntries else {
            throw AgentQueuedFollowUpError.capacityExceeded
        }
        let receipt = AgentSteerReceipt(
            id: UUID(), acceptedAt: Date(),
            redactedDigest: Self.digest(redacted), redactedText: redacted
        )
        receipts.append(receipt)
        try saveLocked(receipts, sessionID: sessionID)
        return receipt
    }

    func unresolved(sessionID: UUID) throws -> [AgentSteerReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked(sessionID: sessionID)
    }

    func reconcile(session: AgentSession) throws -> [AgentSteerReceipt] {
        lock.lock()
        defer { lock.unlock() }
        let receipts = try loadLocked(sessionID: session.id)
        guard !receipts.isEmpty else { return [] }
        let messages = session.messages.filter {
            $0.role == .user && $0.name == "luma-agent-steer"
        }
        let remaining = receipts.filter { receipt in
            // Content alone is insufficient: successive identical Steers must
            // not consume the same earlier transcript message after restart.
            guard receipt.redactedText != nil else { return true }
            return !messages.contains {
                $0.id == receipt.id && Self.digest($0.content) == receipt.redactedDigest
            }
        }
        if remaining != receipts { try saveLocked(remaining, sessionID: session.id) }
        return remaining
    }

    /// A stale sheet may dismiss only the record the user inspected.
    func dismissUncertain(id: UUID, sessionID: UUID) throws -> [AgentSteerReceipt] {
        lock.lock()
        defer { lock.unlock() }
        var receipts = try loadLocked(sessionID: sessionID)
        guard receipts.contains(where: { $0.id == id }) else {
            throw AgentQueuedFollowUpError.staleClaim
        }
        receipts.removeAll { $0.id == id }
        try saveLocked(receipts, sessionID: sessionID)
        return receipts
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func loadLocked(sessionID: UUID) throws -> [AgentSteerReceipt] {
        guard let data = try AgentInteractionFileIO.read(
            sessionsRoot: sessionsRoot, sessionID: sessionID,
            name: "steer-receipts.json", maximumBytes: maximumBytes
        ) else { return [] }
        guard let receipts = try? JSONDecoder().decode([AgentSteerReceipt].self, from: data),
              receipts.count <= AgentSteerMailbox.maximumEntries,
              Set(receipts.map(\.id)).count == receipts.count,
              receipts.allSatisfy({ receipt in
                  guard receipt.acceptedAt.timeIntervalSince1970.isFinite,
                        receipt.redactedDigest.utf8.count == 64,
                        receipt.redactedDigest.utf8.allSatisfy({
                            (48...57).contains($0) || (97...102).contains($0)
                        }) else { return false }
                  guard let text = receipt.redactedText else { return true }
                  return !text.isEmpty
                      && text.utf8.count <= AgentSteerMailbox.maximumPromptBytes
                      && SecretRedactor().redact(text) == text
                      && Self.digest(text) == receipt.redactedDigest
              }) else {
            throw AgentQueuedFollowUpError.corruptQueue
        }
        return receipts
    }

    private func saveLocked(_ receipts: [AgentSteerReceipt], sessionID: UUID) throws {
        let data = try JSONEncoder().encode(receipts)
        guard data.count <= maximumBytes else { throw AgentQueuedFollowUpError.capacityExceeded }
        try AgentInteractionFileIO.write(
            data, sessionsRoot: sessionsRoot, sessionID: sessionID, name: "steer-receipts.json"
        )
    }
}
