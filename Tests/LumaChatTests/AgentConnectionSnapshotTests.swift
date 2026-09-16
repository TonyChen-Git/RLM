import XCTest
@testable import LumaChat

final class AgentConnectionSnapshotTests: XCTestCase {
    func testConnectionSnapshotIsStableWhenGlobalSettingsChangeAndRoundTrips() throws {
        let profileID = UUID()
        let original = AppSettings(
            provider: .ollama,
            endpoint: "http://192.168.1.22:11434",
            selectedModel: "qwen-coder",
            contextLength: 65_536,
            temperature: 0.15,
            requestTimeout: 900,
            activeProfileID: profileID
        )
        var session = AgentSession(
            mode: .agent,
            model: original.selectedModel,
            provider: original.provider,
            profileID: profileID
        )
        session.connection = AgentConnectionSnapshot(settings: original)

        let encoded = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: encoded)
        let route = try XCTUnwrap(restored.connection?.providerSettings(model: restored.model))

        XCTAssertEqual(route.provider, .ollama)
        XCTAssertEqual(route.endpoint, "http://192.168.1.22:11434")
        XCTAssertEqual(route.selectedModel, "qwen-coder")
        XCTAssertEqual(route.contextLength, 65_536)
        XCTAssertEqual(route.temperature, 0.15)
        XCTAssertEqual(route.requestTimeout, 900)
        XCTAssertEqual(route.activeProfileID, profileID)
    }

    func testLegacySessionWithoutConnectionSnapshotStillDecodes() throws {
        var legacy = AgentSession(mode: .agent)
        legacy.model = "legacy"
        legacy.provider = .ollama
        legacy.connection = nil
        let data = try JSONEncoder().encode(legacy)
        let session = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertNil(session.connection)
        XCTAssertEqual(session.model, "legacy")
    }
}
