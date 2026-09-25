import Foundation
import XCTest
@testable import LumaChat

private enum InjectedSessionPersistenceError: LocalizedError {
    case saveFailed

    var errorDescription: String? { "injected session save failure" }
}

private actor ScriptedAgentSessionStore: AgentSessionPersisting {
    private var remainingSaveFailures: Int
    private var saveAttempts = 0
    private var savedSessions: [AgentSession] = []

    init(saveFailures: Int) {
        remainingSaveFailures = saveFailures
    }

    func loadSessions() async throws -> [AgentSession] { [] }

    func save(_ session: AgentSession) async throws {
        _ = session
        saveAttempts += 1
        if remainingSaveFailures > 0 {
            remainingSaveFailures -= 1
            throw InjectedSessionPersistenceError.saveFailed
        }
        savedSessions.append(session)
    }

    func delete(id: UUID) async throws { _ = id }

    func attempts() -> Int { saveAttempts }
    func saved() -> [AgentSession] { savedSessions }
    func failNextSaves(_ count: Int) { remainingSaveFailures = max(0, count) }
}

private actor BlockingAgentSessionStore: AgentSessionPersisting {
    private var didStartSave = false
    private var didReleaseSave = false
    private var savedSessions: [AgentSession] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func loadSessions() async throws -> [AgentSession] { [] }

    func save(_ session: AgentSession) async throws {
        didStartSave = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !didReleaseSave {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        savedSessions.append(session)
    }

    func delete(id: UUID) async throws { _ = id }

    func waitUntilSaveStarts() async {
        if didStartSave { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSave() {
        didReleaseSave = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func saved() -> [AgentSession] { savedSessions }
}

final class AgentViewModelPersistenceTests: XCTestCase {
    @MainActor
    func testDraftAndPendingImageClearOnlyAfterUserMessageSaveSucceeds() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 1)
        let viewModel = AgentViewModel(sessionStore: store)
        let session = AgentSession(mode: .agent)
        let attachment = try makeAttachment()
        let runID = UUID()

        viewModel.selectedSessionID = session.id
        viewModel.draft = "Persist this request"
        viewModel.beginRunTracking(
            runID: runID,
            session: session,
            userRequest: "Persist this request"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: session.id)
        let updated = try sessionAppendingUserMessage(
            to: session,
            text: "Persist this request",
            attachment: attachment
        )

        await viewModel.handle(.sessionUpdated(updated), runID: runID)

        XCTAssertEqual(viewModel.draft, "Persist this request")
        XCTAssertEqual(viewModel.pendingImageAttachments, [attachment])
        XCTAssertTrue(viewModel.sessions.isEmpty, "A failed snapshot must not replace durable UI state")
        XCTAssertTrue(viewModel.errorMessage?.contains("injected session save failure") == true)

        await viewModel.handle(.finished(updated), runID: runID)

        XCTAssertEqual(viewModel.draft, "")
        XCTAssertTrue(viewModel.pendingImageAttachments.isEmpty)
        XCTAssertEqual(viewModel.sessions.first, updated)

        // Runtime emits sessionUpdated + finished and then returns the same
        // snapshot to finish(_:runID:). A known-persisted snapshot must not be
        // written a third time or re-run submitted-input disposition.
        await viewModel.finish(updated, runID: runID)
        let attempts = await store.attempts()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(viewModel.isRunning)
    }

    @MainActor
    func testFinalSaveFailureEndsRunButRetainsResendableDraftAndAttachment() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 10)
        let viewModel = AgentViewModel(sessionStore: store)
        let session = AgentSession(mode: .agent)
        let attachment = try makeAttachment()
        let runID = UUID()

        viewModel.selectedSessionID = session.id
        viewModel.draft = "Do not lose me"
        viewModel.beginRunTracking(
            runID: runID,
            session: session,
            userRequest: "Do not lose me"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: session.id)
        let completed = try sessionAppendingUserMessage(
            to: session,
            text: "Do not lose me",
            attachment: attachment
        )

        await viewModel.finish(completed, runID: runID)

        XCTAssertEqual(viewModel.draft, "Do not lose me")
        XCTAssertEqual(viewModel.pendingImageAttachments, [attachment])
        XCTAssertTrue(viewModel.errorMessage?.contains("injected session save failure") == true)
        XCTAssertFalse(viewModel.isRunning)
    }

    @MainActor
    func testStaleSaveCompletionCannotConsumeNewRunInput() async throws {
        let store = BlockingAgentSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        let session = AgentSession(mode: .agent)
        let attachment = try makeAttachment()
        let staleRunID = UUID()

        viewModel.selectedSessionID = session.id
        viewModel.draft = "old request"
        viewModel.beginRunTracking(
            runID: staleRunID,
            session: session,
            userRequest: "old request"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: session.id)
        let staleUpdate = try sessionAppendingUserMessage(
            to: session,
            text: "old request",
            attachment: attachment
        )

        let staleEvent = Task { @MainActor in
            await viewModel.handle(.sessionUpdated(staleUpdate), runID: staleRunID)
        }
        await store.waitUntilSaveStarts()

        let newRunID = UUID()
        viewModel.draft = "new request"
        viewModel.beginRunTracking(
            runID: newRunID,
            session: session,
            userRequest: "new request"
        )
        await store.releaseSave()
        await staleEvent.value

        XCTAssertEqual(viewModel.draft, "new request")
        XCTAssertEqual(viewModel.pendingImageAttachments, [attachment])
        XCTAssertTrue(viewModel.sessions.isEmpty, "A stale completion must not apply an old snapshot")
        XCTAssertTrue(viewModel.isRunning)
    }

    @MainActor
    func testControlledPauseConsumesDraftAndImageOnlyAfterSnapshotIsDurable() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 0)
        let viewModel = AgentViewModel(sessionStore: store)
        let session = AgentSession(mode: .agent)
        let attachment = try makeAttachment()
        let runID = UUID()

        viewModel.selectedSessionID = session.id
        viewModel.draft = "pause after persistence"
        viewModel.beginRunTracking(
            runID: runID,
            session: session,
            userRequest: "pause after persistence"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: session.id)
        let paused = try sessionAppendingUserMessage(
            to: session,
            text: "pause after persistence",
            attachment: attachment,
            state: .paused
        )

        let didPersist = await viewModel.persistControlledTermination(paused, runID: runID)

        XCTAssertTrue(didPersist)
        XCTAssertEqual(viewModel.draft, "")
        XCTAssertTrue(viewModel.pendingImageAttachments.isEmpty)
        XCTAssertEqual(viewModel.sessions.first, paused)
        XCTAssertNil(viewModel.errorMessage)
        let successAttempts = await store.attempts()
        XCTAssertEqual(successAttempts, 1)
    }

    @MainActor
    func testControlledStopSaveFailureRetainsResendableDraftAndImage() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 1)
        let viewModel = AgentViewModel(sessionStore: store)
        let session = AgentSession(mode: .agent)
        let attachment = try makeAttachment()
        let runID = UUID()

        viewModel.selectedSessionID = session.id
        viewModel.draft = "retry after failed stop save"
        viewModel.beginRunTracking(
            runID: runID,
            session: session,
            userRequest: "retry after failed stop save"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: session.id)
        let cancelled = try sessionAppendingUserMessage(
            to: session,
            text: "retry after failed stop save",
            attachment: attachment,
            state: .cancelled
        )

        let didPersist = await viewModel.persistControlledTermination(cancelled, runID: runID)

        XCTAssertFalse(didPersist)
        XCTAssertEqual(viewModel.draft, "retry after failed stop save")
        XCTAssertEqual(viewModel.pendingImageAttachments, [attachment])
        XCTAssertEqual(viewModel.sessions.first, cancelled)
        XCTAssertTrue(viewModel.errorMessage?.contains("injected session save failure") == true)
        let failureAttempts = await store.attempts()
        XCTAssertEqual(failureAttempts, 1)
    }

    @MainActor
    func testShutdownPersistsActiveSessionAsCancelled() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 0)
        let viewModel = AgentViewModel(sessionStore: store)
        var running = AgentSession(mode: .agent)
        running.state = .running
        let runID = UUID()

        viewModel.selectedSessionID = running.id
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runID)

        let didPersist = await viewModel.shutdown()

        XCTAssertTrue(didPersist)
        let saved = await store.saved()
        XCTAssertEqual(
            saved.count,
            2,
            "Unexpected snapshots: \(saved.map { "state=\($0.state.rawValue), steps=\($0.steps.count)" })"
        )
        XCTAssertEqual(saved.last?.id, running.id)
        XCTAssertEqual(saved.last?.state, .cancelled)
        XCTAssertEqual(saved.last?.steps.last?.status, .cancelled)
        XCTAssertFalse(viewModel.isRunning)
    }

    @MainActor
    func testShutdownRefusesTerminationWhenControlledSessionCannotPersist() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 0)
        let viewModel = AgentViewModel(sessionStore: store)
        var running = AgentSession(mode: .agent)
        running.state = .running
        let attachment = try makeAttachment()
        let runID = UUID()

        viewModel.selectedSessionID = running.id
        viewModel.draft = "retain after failed shutdown"
        viewModel.beginRunTracking(
            runID: runID,
            session: running,
            userRequest: "retain after failed shutdown"
        )
        try viewModel.recordPendingImageAttachment(attachment, for: running.id)
        await viewModel.handle(.sessionUpdated(running), runID: runID)
        await store.failNextSaves(1)

        let canTerminate = await viewModel.shutdown()

        XCTAssertFalse(canTerminate)
        XCTAssertEqual(viewModel.draft, "retain after failed shutdown")
        XCTAssertEqual(viewModel.pendingImageAttachments, [attachment])
        XCTAssertTrue(viewModel.errorMessage?.contains("injected session save failure") == true)
    }

    @MainActor
    func testStopCannotPreemptNaturalTerminalPersistenceAlreadyInFlight() async {
        let store = BlockingAgentSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var completed = AgentSession(mode: .agent)
        completed.state = .completed
        let runID = UUID()

        viewModel.beginRunTracking(runID: runID, session: completed, userRequest: nil)
        let finishing = Task { @MainActor in
            await viewModel.finish(completed, runID: runID)
        }
        await store.waitUntilSaveStarts()

        // Natural completion already owns the terminal transaction. A stop in
        // this suspension window must not revoke persistence or replace the
        // authoritative completed result with a cancellation.
        viewModel.stop(sessionID: completed.id)
        await store.releaseSave()
        await finishing.value

        let saved = await store.saved()
        XCTAssertEqual(saved.last?.state, .completed)
        XCTAssertFalse(saved.contains(where: { $0.state == .cancelled }))
        XCTAssertFalse(viewModel.isRunning)
    }

    @MainActor
    func testStopConsumesRuntimeTerminalValueDeliveredAfterStopBegins() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 0)
        let viewModel = AgentViewModel(sessionStore: store)
        var running = AgentSession(mode: .agent)
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)

        // Reproduce the boundary where AgentRuntime has cleared activeTask but
        // its outer generation task has not called `finish` yet.
        viewModel.stop(sessionID: running.id)
        var completed = running
        completed.state = .completed
        completed.updatedAt = Date()
        await viewModel.finish(completed, runID: runID)

        try await waitUntil(timeout: .seconds(3)) { !viewModel.isRunning }
        let saved = await store.saved()
        XCTAssertEqual(saved.last?.state, .completed)
        XCTAssertFalse(saved.contains(where: { $0.state == .cancelled }))
    }

    @MainActor
    func testPauseConsumesRuntimeTerminalValueDeliveredAfterPauseBegins() async throws {
        let store = ScriptedAgentSessionStore(saveFailures: 0)
        let viewModel = AgentViewModel(sessionStore: store)
        var running = AgentSession(mode: .agent)
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)

        viewModel.pause(sessionID: running.id)
        var completed = running
        completed.state = .completed
        completed.updatedAt = Date()
        await viewModel.finish(completed, runID: runID)

        try await waitUntil(timeout: .seconds(3)) { !viewModel.isRunning }
        let saved = await store.saved()
        XCTAssertEqual(saved.last?.state, .completed)
        XCTAssertFalse(saved.contains(where: { $0.state == .paused }))
    }

    @MainActor
    func testShutdownWaitsForNaturalTerminalPersistenceOwner() async {
        let store = BlockingAgentSessionStore()
        let viewModel = AgentViewModel(sessionStore: store)
        var completed = AgentSession(mode: .agent)
        completed.state = .completed
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: completed, userRequest: nil)

        let finishing = Task { @MainActor in
            await viewModel.finish(completed, runID: runID)
        }
        await store.waitUntilSaveStarts()
        let shutdown = Task { @MainActor in
            await viewModel.shutdown()
        }
        await Task.yield()
        XCTAssertTrue(viewModel.isRunning)

        await store.releaseSave()
        await finishing.value
        _ = await shutdown.value

        let saved = await store.saved()
        XCTAssertEqual(saved.last?.state, .completed)
        XCTAssertFalse(saved.contains(where: { $0.state == .cancelled }))
        XCTAssertFalse(viewModel.isRunning)
    }

    private func makeAttachment() throws -> AgentImageAttachmentReference {
        let id = UUID()
        return try AgentImageAttachmentReference(
            id: id,
            name: "fixture.png",
            relativePath: "Attachments/\(id.uuidString.lowercased()).png",
            mimeType: "image/png",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func sessionAppendingUserMessage(
        to session: AgentSession,
        text: String,
        attachment: AgentImageAttachmentReference,
        state: AgentRunState = .completed
    ) throws -> AgentSession {
        var updated = session
        updated.state = state
        updated.messages.append(
            try AgentMessage(
                role: .user,
                content: text,
                imageAttachments: [attachment]
            )
        )
        updated.updatedAt = Date()
        return updated
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for AgentViewModel terminal transition.")
    }
}
