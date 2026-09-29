import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AgentQueuedFollowUpTests: XCTestCase {
    func testQueueClaimSurvivesRestartWithoutAutomaticReplay() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentQueuedFollowUpStore(sessionsRoot: root)
        let first = AgentQueuedFollowUp(text: "First change")
        let second = AgentQueuedFollowUp(text: "Second change")
        _ = try await store.enqueue(first, sessionID: sessionID)
        _ = try await store.enqueue(second, sessionID: sessionID)

        let reordered = try await store.moveQueued(id: second.id, by: -1, sessionID: sessionID)
        XCTAssertEqual(reordered.map(\.id), [second.id, first.id])
        let restoredOrder = try await store.moveQueued(id: second.id, by: 1, sessionID: sessionID)
        XCTAssertEqual(restoredOrder.map(\.id), [first.id, second.id])
        let edited = try await store.updateQueued(
            id: second.id,
            text: "  Updated second change  ",
            sessionID: sessionID
        )
        XCTAssertEqual(edited[1].text, "Updated second change")

        let firstClaim = try await store.claimNext(sessionID: sessionID)
        let claim = try XCTUnwrap(firstClaim)
        let claimID = try XCTUnwrap(claim.claimID)
        let reopened = AgentQueuedFollowUpStore(sessionsRoot: root)
        let reopenedEntries = try await reopened.load(sessionID: sessionID)
        XCTAssertEqual(reopenedEntries.count, 2)
        let blockedClaim = try await reopened.claimNext(sessionID: sessionID)
        XCTAssertNil(blockedClaim,
                     "An uncertain first send must block FIFO replay after relaunch")

        _ = try await reopened.acknowledge(id: first.id, claimID: claimID, sessionID: sessionID)
        let nextClaim = try await reopened.claimNext(sessionID: sessionID)
        let next = try XCTUnwrap(nextClaim)
        XCTAssertEqual(next.id, second.id)
    }

    func testQueueRejectsCorruptOrSymlinkedFileAndBoundsEntries() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentQueuedFollowUpStore(sessionsRoot: root)
        for index in 0..<AgentQueuedFollowUpStore.maximumEntries {
            _ = try await store.enqueue(
                AgentQueuedFollowUp(text: "Queued \(index)"),
                sessionID: sessionID
            )
        }
        do {
            _ = try await store.enqueue(
                AgentQueuedFollowUp(text: "Too many"),
                sessionID: sessionID
            )
            XCTFail("Expected queue capacity failure")
        } catch AgentQueuedFollowUpError.capacityExceeded {}

        let queueFile = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("queued-followups.json")
        try FileManager.default.removeItem(at: queueFile)
        try FileManager.default.createSymbolicLink(at: queueFile, withDestinationURL: root)
        do {
            _ = try await store.load(sessionID: sessionID)
            XCTFail("Expected symlink refusal")
        } catch AgentQueuedFollowUpError.corruptQueue {}
    }

    func testRunningTaskQueuesDraftDurablyWithoutChangingCurrentTurn() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queueStore = AgentQueuedFollowUpStore(sessionsRoot: root)
        let viewModel = AgentViewModel(
            sessionStore: AgentSessionStore(sessionsRoot: root),
            queuedFollowUpStore: queueStore
        )
        var session = AgentSession(id: sessionID, mode: .agent)
        session.state = .running
        session.model = "fixture-model"
        session.workspace = AgentWorkspace(
            name: "Fixture",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: session, userRequest: nil)
        await viewModel.handle(.sessionUpdated(session), runID: runID)
        viewModel.selectedSessionID = sessionID
        viewModel.activeMode = .agent
        viewModel.draft = "Please check the second case"
        XCTAssertTrue(viewModel.canQueueFollowUp)

        let queued = await viewModel.queueFollowUp(
            route: AppSettings(selectedModel: "fixture-model"),
            apiKey: ""
        )
        XCTAssertTrue(queued)
        XCTAssertEqual(viewModel.draft, "")
        XCTAssertEqual(viewModel.selectedQueuedFollowUps.map(\.text), ["Please check the second case"])
        let persisted = try await queueStore.load(sessionID: sessionID)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertTrue(viewModel.isRunning(sessionID: sessionID))
    }

    func testQueueDoesNotCaptureImageStillOwnedByRunningTurn() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queueStore = AgentQueuedFollowUpStore(sessionsRoot: root)
        let viewModel = AgentViewModel(
            sessionStore: AgentSessionStore(sessionsRoot: root),
            queuedFollowUpStore: queueStore
        )
        var session = AgentSession(id: sessionID, mode: .agent)
        session.state = .running
        session.model = "fixture-model"
        session.workspace = AgentWorkspace(
            name: "Fixture",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: session, userRequest: "First turn")
        await viewModel.handle(.sessionUpdated(session), runID: runID)
        viewModel.selectedSessionID = sessionID
        viewModel.activeMode = .agent
        viewModel.draft = "Next turn"

        let imageID = UUID()
        let reference = try AgentImageAttachmentReference(
            id: imageID,
            name: "image.png",
            relativePath: "Attachments/\(imageID.uuidString.lowercased()).png",
            mimeType: "image/png",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            sha256: String(repeating: "a", count: 64)
        )
        try viewModel.recordPendingImageAttachment(reference, for: sessionID)
        XCTAssertFalse(viewModel.canQueueFollowUp)
        let queued = await viewModel.queueFollowUp(
            route: AppSettings(selectedModel: "fixture-model"),
            apiKey: ""
        )
        XCTAssertFalse(queued)
        let persisted = try await queueStore.load(sessionID: sessionID)
        XCTAssertEqual(persisted.count, 0)
        XCTAssertEqual(viewModel.pendingImageAttachments.map(\.id), [imageID])
    }

    func testDeliveredQueuedPromptMatchesRedactedPersistedUserMessage() {
        let viewModel = AgentViewModel()
        let entry = AgentQueuedFollowUp(text: "Use token=super-secret-value for this check")
        let persisted = AgentMessage(
            role: .user,
            content: SecretRedactor().redact(entry.text)
        )

        XCTAssertNotEqual(persisted.content, entry.text)
        XCTAssertTrue(viewModel.queuedFollowUpMatchesUserMessage(entry, message: persisted))
        XCTAssertFalse(viewModel.queuedFollowUpMatchesUserMessage(
            entry,
            message: AgentMessage(role: .user, content: "Different request")
        ))
    }

    private func makeRoot() throws -> (URL, UUID) {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("queued-followups-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(sessionID.uuidString, isDirectory: true),
            withIntermediateDirectories: true
        )
        return (root, sessionID)
    }
}
