import Foundation
import XCTest
@testable import LumaChat

private actor ExternalImportSettingsStore: AgentSettingsPersisting {
    private var settings = AgentSettings()
    func load() -> AgentSettings { settings }
    func save(_ value: AgentSettings) { settings = value }
}

final class ExternalAssistantChatImportIntegrationTests: XCTestCase {
    @MainActor
    func testImportPersistsCompletedTaskAndRejectsDuplicateAfterRestart() async throws {
        let base = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "external-import-\(UUID().uuidString)", isDirectory: true
        )
        let workspaceRoot = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("chat.jsonl")
        try Data("""
        {"type":"user","message":{"role":"user","content":"Review foo.swift"}}
        {"type":"assistant","message":{"role":"assistant","content":"Looks good"}}
        """.utf8).write(to: source)
        let preview = try ExternalAssistantChatImporter().preview(
            source: .claudeCodeJSONL, url: source
        )
        let workspace = AgentWorkspace(
            name: "workspace", rootPath: workspaceRoot.path,
            allowedPaths: [], bookmarkData: nil, gitRepository: false
        )
        let project = AgentProject(name: "Import Project", primaryWorkspace: workspace)
        let sessions = AgentSessionStore(sessionsRoot: base.appendingPathComponent("sessions"))
        let catalog = AgentProjectCatalogStore(catalogFile: base.appendingPathComponent("catalog.json"))
        try await catalog.saveProjects([project])
        let preferences = ExternalImportSettingsStore()
        let route = AppSettings(selectedModel: "test-model")
        let first = AgentViewModel(
            sessionStore: sessions, projectCatalogStore: catalog,
            settingsStore: preferences,
            mcpSettingsStore: MCPSettingsStore(fileURL: base.appendingPathComponent("mcp.json"))
        )
        await first.start()
        first.selectProject(project.id)
        do {
            _ = try await first.importExternalChat(
                preview, route: route, expectedProjectID: UUID()
            )
            XCTFail("A changed preview target must be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalAssistantChatImportError, .targetChanged)
        }
        let beforeImport = try await sessions.loadSessions()
        XCTAssertTrue(beforeImport.isEmpty)
        let importedID = try await first.importExternalChat(preview, route: route)
        let loaded = try await sessions.loadSessions()
        let durable = try XCTUnwrap(loaded.first {
            $0.id == importedID
        })
        XCTAssertEqual(durable.state, .completed)
        XCTAssertEqual(durable.projectID, project.id)
        XCTAssertEqual(durable.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(durable.importSourceDigest, preview.sourceDigest)
        do {
            _ = try await first.importExternalChat(preview, route: route)
            XCTFail("Repeated import must be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalAssistantChatImportError, .duplicateImport)
        }

        let restarted = AgentViewModel(
            sessionStore: sessions, projectCatalogStore: catalog,
            settingsStore: preferences,
            mcpSettingsStore: MCPSettingsStore(fileURL: base.appendingPathComponent("mcp.json"))
        )
        await restarted.start()
        restarted.selectProject(project.id)
        do {
            _ = try await restarted.importExternalChat(preview, route: route)
            XCTFail("Repeated import after restart must be rejected")
        } catch {
            XCTAssertEqual(error as? ExternalAssistantChatImportError, .duplicateImport)
        }
    }
}
