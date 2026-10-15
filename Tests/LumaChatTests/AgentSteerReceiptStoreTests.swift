import CryptoKit
import Foundation
import XCTest
@testable import LumaChat

final class AgentSteerReceiptStoreTests: XCTestCase {
    func testAcceptedSteerSurvivesRestartAndReconcilesOnlyMatchingTranscript() throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("steer-receipts-\(UUID().uuidString)", isDirectory: true)
        let session = AgentSession(mode: .agent)
        let directory = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let prompt = "Keep going with token=super-secret-123456"
        let receipt = try store.accept(prompt, sessionID: session.id)
        let persisted = try String(contentsOf: directory.appendingPathComponent("steer-receipts.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains(prompt))
        XCTAssertFalse(persisted.contains("super-secret-123456"))
        let reopened = AgentSteerReceiptStore(sessionsRoot: root)
        XCTAssertEqual(try reopened.unresolved(sessionID: session.id).count, 1)
        XCTAssertEqual(try reopened.reconcile(session: session).count, 1)
        var delivered = session
        delivered.messages.append(AgentMessage(
            role: .user, content: SecretRedactor().redact(prompt),
            name: "luma-agent-steer"
        ))
        XCTAssertEqual(try reopened.reconcile(session: delivered), [receipt],
                       "Matching content with a different identity is not delivery evidence")
        delivered.messages.append(try XCTUnwrap(receipt.message))
        XCTAssertTrue(try reopened.reconcile(session: delivered).isEmpty)
        XCTAssertTrue(try reopened.unresolved(sessionID: session.id).isEmpty)
    }

    func testIdenticalSteersReconcileIndependentlyAndDismissOnlyInspectedRecord() throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let first = try store.accept("Check the same case", sessionID: session.id)
        var delivered = session
        delivered.messages.append(try XCTUnwrap(first.message))
        XCTAssertTrue(try store.reconcile(session: delivered).isEmpty)
        let second = try store.accept("Check the same case", sessionID: session.id)
        let third = try store.accept("A later instruction", sessionID: session.id)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try store.reconcile(session: delivered), [second, third])
        XCTAssertEqual(try store.dismissUncertain(id: second.id, sessionID: session.id), [third])
        XCTAssertThrowsError(try store.dismissUncertain(id: second.id, sessionID: session.id))
        XCTAssertEqual(try store.unresolved(sessionID: session.id), [third])
    }

    func testReconciliationRequiresOriginatingTaskAndExactUserSteerContent() throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let receipt = try store.accept("This instruction belongs to one Task", sessionID: session.id)
        let accepted = try XCTUnwrap(receipt.message)

        var other = AgentSession(mode: .agent)
        other.messages.append(accepted)
        XCTAssertTrue(try store.reconcile(session: other).isEmpty)
        XCTAssertEqual(try store.unresolved(sessionID: session.id), [receipt])
        XCTAssertThrowsError(try store.dismissUncertain(id: receipt.id, sessionID: other.id))

        for impostor in [
            AgentMessage(id: receipt.id, role: .assistant, content: accepted.content,
                         name: "luma-agent-steer", createdAt: receipt.acceptedAt),
            AgentMessage(id: receipt.id, role: .user, content: accepted.content,
                         createdAt: receipt.acceptedAt),
            AgentMessage(id: receipt.id, role: .user, content: "Different instruction",
                         name: "luma-agent-steer", createdAt: receipt.acceptedAt)
        ] {
            var unconfirmed = session
            unconfirmed.messages = [impostor]
            XCTAssertEqual(try store.reconcile(session: unconfirmed), [receipt])
        }
        var confirmed = session
        confirmed.messages.append(accepted)
        XCTAssertTrue(try store.reconcile(session: confirmed).isEmpty)
    }

    func testLegacyDigestOnlyReceiptRemainsUnknownEvenWhenTranscriptMatches() throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let accepted = try store.accept("Old instruction", sessionID: session.id)
        let legacy = AgentSteerReceipt(
            id: accepted.id, acceptedAt: accepted.acceptedAt,
            redactedDigest: accepted.redactedDigest
        )
        let file = root.appendingPathComponent(session.id.uuidString)
            .appendingPathComponent("steer-receipts.json")
        try JSONEncoder().encode([legacy]).write(to: file)
        var delivered = session
        delivered.messages.append(try XCTUnwrap(accepted.message))
        let reopened = AgentSteerReceiptStore(sessionsRoot: root)
        let unresolved = try reopened.reconcile(session: delivered)
        XCTAssertEqual(unresolved, [legacy])
        XCTAssertNil(unresolved.first?.redactedText)
        XCTAssertNil(unresolved.first?.message)
        XCTAssertTrue(try reopened.dismissUncertain(id: legacy.id, sessionID: session.id).isEmpty)
    }

    func testReceiptRejectsUnredactedTamperedDuplicateAndOversizedRecords() throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let accepted = try store.accept("Safe instruction", sessionID: session.id)
        let file = root.appendingPathComponent(session.id.uuidString)
            .appendingPathComponent("steer-receipts.json")
        var wrongDigest = accepted
        wrongDigest.redactedText = "Different content"
        let rawSecret = "Use token=not-redacted-123456"
        let unsafe = AgentSteerReceipt(
            id: UUID(), acceptedAt: Date(),
            redactedDigest: SHA256.hash(data: Data(rawSecret.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            redactedText: rawSecret
        )
        let oversized = String(repeating: "a", count: AgentSteerMailbox.maximumPromptBytes + 1)
        let tooLong = AgentSteerReceipt(
            id: UUID(), acceptedAt: Date(),
            redactedDigest: SHA256.hash(data: Data(oversized.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            redactedText: oversized
        )
        for records in [[wrongDigest], [unsafe], [tooLong], [accepted, accepted]] {
            try JSONEncoder().encode(records).write(to: file)
            XCTAssertThrowsError(try store.unresolved(sessionID: session.id))
            XCTAssertThrowsError(try store.accept("New instruction", sessionID: session.id))
            XCTAssertEqual(try JSONDecoder().decode([AgentSteerReceipt].self,
                                                    from: Data(contentsOf: file)), records)
        }
    }

    func testAcceptanceBoundsTextAndRecordsWithoutDiscardingUncertainSends() throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        XCTAssertThrowsError(try store.accept(" \n ", sessionID: session.id))
        XCTAssertThrowsError(try store.accept(
            String(repeating: "a", count: AgentSteerMailbox.maximumPromptBytes + 1),
            sessionID: session.id
        ))
        for _ in 0..<AgentSteerMailbox.maximumEntries {
            // JSON escaping exercises the total on-disk bound as well as the
            // prompt bound. Every accepted receipt must remain readable.
            _ = try store.accept(String(repeating: "\u{0001}", count: AgentSteerMailbox.maximumPromptBytes),
                                 sessionID: session.id)
        }
        XCTAssertThrowsError(try store.accept("Overflow", sessionID: session.id))
        XCTAssertEqual(try store.unresolved(sessionID: session.id).count, AgentSteerMailbox.maximumEntries)
    }

    func testMailboxAcceptanceIsDurableAndRestartNeverReplaysUncertainText() async throws {
        let (root, session) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSteerReceiptStore(sessionsRoot: root)
        let mailbox = AgentSteerMailbox(sessionID: session.id, receiptStore: store)
        let accepted = await mailbox.enqueue("Use password=mailbox-secret-123456")
        XCTAssertTrue(accepted)
        let receipt = try XCTUnwrap(store.unresolved(sessionID: session.id).first)
        XCTAssertFalse(try XCTUnwrap(receipt.redactedText).contains("mailbox-secret-123456"))
        let pending = await mailbox.drain()
        XCTAssertEqual(pending, [try XCTUnwrap(receipt.message)])
        let restartedStore = AgentSteerReceiptStore(sessionsRoot: root)
        let restartedMailbox = AgentSteerMailbox(sessionID: session.id, receiptStore: restartedStore)
        let replay = await restartedMailbox.drain()
        XCTAssertTrue(replay.isEmpty)
        XCTAssertEqual(try restartedStore.unresolved(sessionID: session.id), [receipt])

        let unavailable = AgentSteerMailbox(sessionID: UUID(), receiptStore: store)
        let failedAcceptance = await unavailable.enqueue("Cannot persist this")
        XCTAssertFalse(failedAcceptance)
        let failedPending = await unavailable.drain()
        XCTAssertTrue(failedPending.isEmpty)
    }

    @MainActor
    func testRecoveryCopiesOnlyToOriginatingIdleTaskAndRequiresExplicitPerRecordDismissal() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("steer-recovery-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = AgentSessionStore(sessionsRoot: root)
        let receipts = AgentSteerReceiptStore(sessionsRoot: root)
        let model = AgentViewModel(sessionStore: sessions, steerReceiptStore: receipts)
        let id = model.createSession(mode: .agent, route: AppSettings())
        let session = try XCTUnwrap(model.selectedSession)
        try await sessions.save(session)
        let first = try receipts.accept("Recovered token=private-secret-123456", sessionID: id)
        let second = try receipts.accept("Do not discard this one", sessionID: id)
        XCTAssertTrue(model.refreshUncertainSteers(sessionID: id))
        model.draft = "Existing draft"
        XCTAssertTrue(model.copyUncertainSteerToDraft(id: first.id, sessionID: id))
        XCTAssertEqual(model.draft, "Existing draft\n\n" + (try XCTUnwrap(first.redactedText)))
        XCTAssertFalse(model.draft.contains("private-secret-123456"))
        XCTAssertEqual(try receipts.unresolved(sessionID: id), [first, second])
        XCTAssertEqual(model.selectedSession?.messages, [])
        XCTAssertFalse(model.isRunning(sessionID: id), "Recovery must never send or start a run")

        model.selectedSessionID = UUID()
        XCTAssertFalse(model.copyUncertainSteerToDraft(id: first.id, sessionID: id))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.dismissUncertainSteer(id: first.id, sessionID: id))
        XCTAssertEqual(try receipts.unresolved(sessionID: id), [first, second])
        model.selectedSessionID = id
        model.draft = String(repeating: "a", count: AgentSteerMailbox.maximumPromptBytes)
        XCTAssertFalse(model.copyUncertainSteerToDraft(id: first.id, sessionID: id))
        XCTAssertEqual(model.draft.utf8.count, AgentSteerMailbox.maximumPromptBytes)
        XCTAssertTrue(model.dismissUncertainSteer(id: first.id, sessionID: id))
        XCTAssertEqual(try receipts.unresolved(sessionID: id), [second])
        XCTAssertFalse(model.dismissUncertainSteer(id: first.id, sessionID: id))
        XCTAssertEqual(try receipts.unresolved(sessionID: id), [second])

        model.beginRunTracking(runID: UUID(), session: session, userRequest: nil)
        XCTAssertFalse(model.copyUncertainSteerToDraft(id: second.id, sessionID: id))
        XCTAssertFalse(model.dismissUncertainSteer(id: second.id, sessionID: id))
        XCTAssertEqual(try receipts.unresolved(sessionID: id), [second])
    }

    @MainActor
    func testRecoveryReadFailureIsVisibleAndDoesNotChangeDraftOrStoredEvidence() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("steer-recovery-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = AgentSessionStore(sessionsRoot: root)
        let receipts = AgentSteerReceiptStore(sessionsRoot: root)
        let model = AgentViewModel(sessionStore: sessions, steerReceiptStore: receipts)
        let id = model.createSession(mode: .agent, route: AppSettings())
        try await sessions.save(try XCTUnwrap(model.selectedSession))
        let receipt = try receipts.accept("Unconfirmed text", sessionID: id)
        XCTAssertTrue(model.refreshUncertainSteers(sessionID: id))
        let file = root.appendingPathComponent(id.uuidString).appendingPathComponent("steer-receipts.json")
        let corrupt = Data("incomplete record".utf8)
        try corrupt.write(to: file)
        model.draft = "Keep my draft"

        XCTAssertFalse(model.refreshUncertainSteers(sessionID: id))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.copyUncertainSteerToDraft(id: receipt.id, sessionID: id))
        XCTAssertFalse(model.dismissUncertainSteer(id: receipt.id, sessionID: id))
        XCTAssertEqual(model.draft, "Keep my draft")
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(model.selectedSession?.messages.isEmpty == true)
    }

    private func makeSession() throws -> (URL, AgentSession) {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("steer-receipts-\(UUID().uuidString)", isDirectory: true)
        let session = AgentSession(mode: .agent)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(session.id.uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )
        return (root, session)
    }
}
