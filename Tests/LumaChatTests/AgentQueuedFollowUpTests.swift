import Foundation
import Darwin
import ImageIO
import XCTest
@testable import LumaChat

@MainActor
final class AgentQueuedFollowUpTests: XCTestCase {
    func testEditorReceivesDurableSaveResultAndClaimedEditFailure() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentQueuedFollowUpStore(sessionsRoot: root)
        let entry = AgentQueuedFollowUp(text: "Original queued text")
        _ = try await store.enqueue(entry, sessionID: sessionID)
        let model = AgentViewModel(queuedFollowUpStore: store)
        let saved = await model.updateQueuedFollowUp(id: entry.id, sessionID: sessionID, text: "Saved edit")
        XCTAssertTrue(saved)
        _ = try await store.claimNext(sessionID: sessionID)
        let rejected = await model.updateQueuedFollowUp(id: entry.id, sessionID: sessionID, text: "Stale edit")
        XCTAssertFalse(rejected)
        XCTAssertNotNil(model.errorMessage)
        let restored = try await store.load(sessionID: sessionID)
        XCTAssertEqual(restored.first?.text, "Saved edit")
        XCTAssertNotNil(restored.first?.claimID)
        _ = try await store.release(id: entry.id, claimID: XCTUnwrap(restored.first?.claimID), sessionID: sessionID)
        let retried = await model.updateQueuedFollowUp(id: entry.id, sessionID: sessionID, text: "Retry edit")
        XCTAssertTrue(retried)
        XCTAssertNil(model.errorMessage, "A successful retry must not leave the stale failure banner")
    }

    func testQueueRedactsEnqueueEditAndMigratesLegacyClaimWithoutReplaying() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentQueuedFollowUpStore(sessionsRoot: root)
        let entry = AgentQueuedFollowUp(text: "Use token=queue-secret-123456")
        let initial = try await store.enqueue(entry, sessionID: sessionID)
        XCTAssertFalse(initial[0].text.contains("queue-secret-123456"))
        let updated = try await store.updateQueued(
            id: entry.id, text: "Use password=edited-secret-123456", sessionID: sessionID
        )
        XCTAssertFalse(updated[0].text.contains("edited-secret-123456"))
        let file = root.appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent("queued-followups.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("edited-secret-123456"))

        var legacy = entry
        legacy.claimID = UUID()
        try JSONEncoder().encode([legacy]).write(to: file)
        let restored = try await AgentQueuedFollowUpStore(sessionsRoot: root).load(sessionID: sessionID)
        XCTAssertEqual(restored[0].claimID, legacy.claimID)
        XCTAssertFalse(restored[0].text.contains("queue-secret-123456"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("queue-secret-123456"))
        let next = try await store.claimNext(sessionID: sessionID)
        XCTAssertNil(next)
    }

    func testQueueAndSteerRejectSymlinkedTaskDirectoryAndFIFO() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(sessionID.uuidString)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: outside)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let queue = AgentQueuedFollowUpStore(sessionsRoot: root)
        let steer = AgentSteerReceiptStore(sessionsRoot: root)
        do {
            _ = try await queue.enqueue(AgentQueuedFollowUp(text: "queued"), sessionID: sessionID)
            XCTFail("Expected substituted Task directory rejection")
        } catch AgentQueuedFollowUpError.corruptQueue {}
        XCTAssertThrowsError(try steer.accept("steer", sessionID: sessionID))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: outside, to: directory)
        for name in ["queued-followups.json", "steer-receipts.json"] {
            XCTAssertEqual(Darwin.mkfifo(directory.appendingPathComponent(name).path, mode_t(0o600)), 0)
        }
        do {
            _ = try await queue.load(sessionID: sessionID)
            XCTFail("Expected FIFO rejection without waiting for a writer")
        } catch AgentQueuedFollowUpError.corruptQueue {}
        XCTAssertThrowsError(try steer.unresolved(sessionID: sessionID))
    }

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

    func testQueueRejectsMissingImagePayloadDuringRunningTurn() async throws {
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
        XCTAssertTrue(viewModel.canQueueFollowUp)
        let queued = await viewModel.queueFollowUp(
            route: AppSettings(selectedModel: "fixture-model"),
            apiKey: ""
        )
        XCTAssertFalse(queued)
        let persisted = try await queueStore.load(sessionID: sessionID)
        XCTAssertEqual(persisted.count, 0)
        XCTAssertEqual(viewModel.pendingImageAttachments.map(\.id), [imageID])
    }

    func testRunningTaskQueuesAndRestoresValidImageOnlyFollowUp() async throws {
        let (root, sessionID) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = AgentImageAttachmentStore(sessionsRoot: root)
        let queueStore = AgentQueuedFollowUpStore(sessionsRoot: root)
        let viewModel = AgentViewModel(
            sessionStore: AgentSessionStore(sessionsRoot: root),
            imageAttachmentStore: imageStore,
            queuedFollowUpStore: queueStore
        )
        var session = AgentSession(id: sessionID, mode: .agent)
        session.state = .running
        session.model = "fixture-model"
        session.workspace = AgentWorkspace(
            name: "Fixture", rootPath: root.path, allowedPaths: [],
            bookmarkData: nil, gitRepository: false, branch: nil
        )
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: session, userRequest: "First turn")
        await viewModel.handle(.sessionUpdated(session), runID: runID)
        viewModel.selectedSessionID = sessionID
        viewModel.activeMode = .agent
        let image = try imageStore.importGeneratedPNG(
            makePNG(), name: "queued.png", sessionID: sessionID
        )
        try viewModel.recordPendingImageAttachment(image, for: sessionID)
        XCTAssertTrue(viewModel.canQueueFollowUp)
        let queued = await viewModel.queueFollowUp(
            route: AppSettings(selectedModel: "fixture-model"), apiKey: ""
        )
        XCTAssertTrue(queued)
        let restored = try await AgentQueuedFollowUpStore(sessionsRoot: root).load(
            sessionID: sessionID
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.text, "")
        XCTAssertEqual(restored.first?.imageAttachments.map(\.id), [image.id])
        XCTAssertTrue(viewModel.pendingImageAttachments.isEmpty)
        XCTAssertEqual(try imageStore.loadPayload(for: image, sessionID: sessionID).data.count,
                       image.byteCount)
    }

    private func makePNG() throws -> Data {
        let pixels = Data([255, 0, 0, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw AgentImageAttachmentError.invalidImage("test PNG") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else { throw AgentImageAttachmentError.invalidImage("test PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentImageAttachmentError.invalidImage("test PNG")
        }
        return output as Data
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
