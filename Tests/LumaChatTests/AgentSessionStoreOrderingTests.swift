import Foundation
import XCTest
@testable import LumaChat

final class AgentSessionStoreOrderingTests: XCTestCase {
    func testOlderSnapshotCannotOverwriteNewerDurableSession() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "session-store-ordering-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSessionStore(sessionsRoot: root)
        let id = UUID()
        var older = AgentSession(id: id, title: "older", mode: .agent)
        older.updatedAt = Date(timeIntervalSince1970: 10)
        var newer = older
        newer.title = "reconciled"
        newer.changes = [
            AgentChangeRecord(
                relativePath: "Sources/Recovered.swift",
                kind: .modify,
                unifiedDiff: "recovered"
            )
        ]
        newer.updatedAt = Date(timeIntervalSince1970: 20)

        try await store.save(newer)
        do {
            try await store.save(older)
            XCTFail("A late stale save must not roll durable session state backward")
        } catch let error as AgentSessionStoreError {
            XCTAssertEqual(error, .staleSnapshot(id))
        }

        let loaded = try await store.loadSessions()
        XCTAssertEqual(loaded, [newer])
    }

    func testEqualTimestampCanAdvanceStreamingSnapshot() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "session-store-equal-timestamp-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSessionStore(sessionsRoot: root)
        var first = AgentSession(mode: .agent)
        first.updatedAt = Date(timeIntervalSince1970: 30)
        var streamed = first
        streamed.messages = [AgentMessage(role: .assistant, content: "new delta")]

        try await store.save(first)
        try await store.save(streamed)

        let loaded = try await store.loadSessions()
        XCTAssertEqual(loaded, [streamed])
    }

    func testPresenceDistinguishesAbsentFoundAndCorruptBeforeDeletionTombstone() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "session-store-presence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSessionStore(sessionsRoot: root)
        let session = AgentSession(mode: .agent)

        let initially = await store.presence(id: session.id)
        XCTAssertEqual(initially, .absent)
        try await store.save(session)
        let found = await store.presence(id: session.id)
        XCTAssertEqual(found, .found)

        let file = root
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("session.json")
        try Data("not-json".utf8).write(to: file)
        let corrupt = await store.presence(id: session.id)
        XCTAssertEqual(corrupt, .corrupt)

        try await store.delete(id: session.id)
        let absentAfterDelete = await store.presence(id: session.id)
        XCTAssertEqual(absentAfterDelete, .absent)
        do {
            try await store.save(session)
            XCTFail("A durably deleted Session must reject delayed saves.")
        } catch let error as AgentSessionStoreError {
            XCTAssertEqual(error, .sessionDeleted(session.id))
        }
    }

    func testLastAgentTurnPendingBaselineAndFrozenSnapshotSurviveDurableRoundTrip() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "session-store-last-turn-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSessionStore(sessionsRoot: root)
        var session = AgentSession(mode: .agent)
        let workspaceID = UUID()
        session.pendingAgentTurnReviewBaseline = AgentTurnReviewBaseline(
            version: AgentTurnReviewBaseline.currentVersion,
            runID: UUID(),
            sessionID: session.id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            workspaceID: workspaceID,
            canonicalRootPath: "/tmp/repository",
            rootDevice: 42,
            rootInode: 84,
            startRevision: String(repeating: "a", count: 40),
            files: [AgentTurnReviewFileBaseline(
                path: "Dirty.txt",
                existed: true,
                byteCount: 7,
                permissions: 0o644,
                sha256: String(repeating: "b", count: 64),
                data: Data("before\n".utf8)
            )]
        )
        session.lastAgentTurnReviewSnapshot = AgentTurnReviewSnapshot(
            version: AgentTurnReviewSnapshot.currentVersion,
            runID: UUID(),
            sessionID: session.id,
            finalizedAt: Date(timeIntervalSince1970: 1_700_000_100),
            workspaceID: workspaceID,
            canonicalRootPath: "/tmp/repository",
            rootDevice: 42,
            rootInode: 84,
            source: "diff --git a/Dirty.txt b/Dirty.txt\n",
            sourceSHA256: String(repeating: "c", count: 64),
            truncated: false
        )

        try await store.save(session)

        let loaded = try await store.loadSessions()
        XCTAssertEqual(loaded, [session])
        XCTAssertEqual(
            loaded.first?.pendingAgentTurnReviewBaseline,
            session.pendingAgentTurnReviewBaseline
        )
        XCTAssertEqual(
            loaded.first?.lastAgentTurnReviewSnapshot,
            session.lastAgentTurnReviewSnapshot
        )
        let presence = await store.presence(id: session.id)
        XCTAssertEqual(presence, .found)
    }
}
