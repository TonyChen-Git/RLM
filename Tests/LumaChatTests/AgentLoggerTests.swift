import Foundation
import XCTest
@testable import LumaChat

final class AgentLoggerTests: XCTestCase {
    func testLogRedactsSecretsAndRecordsOperationalMetrics() async throws {
        let directory = testDirectory("redaction")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AgentLogger(directory: directory)
        let sessionID = UUID()

        try await logger.record(
            sessionID: sessionID,
            kind: .model,
            name: "ollama",
            succeeded: true,
            duration: 0.125,
            usage: .init(inputTokens: 12, outputTokens: 7, totalTokens: 19),
            detail: "Authorization: Bearer super-secret-token"
        )

        let records = try await logger.records(sessionID: sessionID)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .model)
        XCTAssertEqual(records[0].totalTokens, 19)
        XCTAssertFalse(records[0].detail?.contains("super-secret-token") == true)

        let raw = try String(
            contentsOf: directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl"),
            encoding: .utf8
        )
        XCTAssertFalse(raw.contains("super-secret-token"))
        XCTAssertTrue(raw.contains("[REDACTED]"))
    }

    func testLogRotatesWithinBoundAndKeepsCompleteJSONLines() async throws {
        let directory = testDirectory("rotation")
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = AgentLogger(
            directory: directory,
            maximumFileBytes: 16 * 1_024,
            maximumDetailCharacters: 1_000
        )
        let sessionID = UUID()

        for index in 0..<100 {
            try await logger.record(
                sessionID: sessionID,
                kind: .tool,
                name: "tool-\(index)",
                succeeded: index.isMultiple(of: 2),
                duration: 0.01,
                detail: String(repeating: "x", count: 900)
            )
        }

        let file = directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertLessThanOrEqual(attributes[.size] as? Int ?? .max, 16 * 1_024)
        let records = try await logger.records(sessionID: sessionID, limit: 500)
        XCTAssertFalse(records.isEmpty)
        XCTAssertEqual(records.last?.name, "tool-99")
    }

    func testLoggerRefusesDirectoryOutsideProjectTemporaryRoot() async {
        let outside = AppPaths.projectTemporaryRoot
            .deletingLastPathComponent()
            .appendingPathComponent("agent-logs-forbidden-" + UUID().uuidString, isDirectory: true)
        let logger = AgentLogger(directory: outside)
        do {
            try await logger.record(sessionID: UUID(), kind: .session, name: "start")
            XCTFail("Expected project tmp boundary rejection")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    private func testDirectory(_ name: String) -> URL {
        AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-logger-tests", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
    }
}
