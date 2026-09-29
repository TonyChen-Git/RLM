import Foundation
import XCTest
@testable import LumaChat

private actor LocalMemoryCaptureProvider: AgentModelProvider {
    nonisolated let id = "local-memory-capture"
    private var captured: [AgentModelRequest] = []

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 8_192,
            maxOutputTokens: 1_024
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        captured.append(request)
        return AgentModelResponse(
            content: "done", reasoningSummary: nil, toolCalls: [],
            finishReason: "stop", usage: nil
        )
    }

    func requests() -> [AgentModelRequest] { captured }
}

final class AgentLocalMemoryIntegrationTests: XCTestCase {
    func testProjectionOnlyIncludesApprovedRedactedEntriesWithinBudget() throws {
        let now = Date()
        let entries = [
            AgentLocalMemoryEntry(
                id: UUID(), text: "token=super-secret-value", status: .approved,
                createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: "draft is private", status: .proposed,
                createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: String(repeating: "x", count: 3_900),
                status: .approved, createdAt: now, updatedAt: now
            ),
            AgentLocalMemoryEntry(
                id: UUID(), text: "Prefer concise output", status: .approved,
                createdAt: now, updatedAt: now
            )
        ]
        let projection = try XCTUnwrap(AgentLocalMemoryPrompt.render(entries))
        XCTAssertLessThanOrEqual(projection.utf8.count, AgentLocalMemoryPrompt.maximumBytes)
        XCTAssertFalse(projection.contains("super-secret-value"))
        XCTAssertFalse(projection.contains("draft is private"))
        XCTAssertTrue(projection.contains("Prefer concise output"))
        XCTAssertNil(AgentLocalMemoryPrompt.render([entries[1]]))
    }

    func testRuntimeSendsMemoryOnlyAsTransientProviderContext() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "memory-runtime-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = AgentSession(mode: .agent)
        session.model = "capture-model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent, rootPath: root.path,
            allowedPaths: [], bookmarkData: nil, gitRepository: false
        )
        let registry = ToolRegistry()
        let provider = LocalMemoryCaptureProvider()
        let runtime = AgentRuntime(
            registry: registry, executor: ToolExecutor(registry: registry)
        )
        let completed = await runtime.run(
            session: session,
            userRequest: "summarize",
            provider: provider,
            approvedMemoryContext: "[\"Prefer short answers\"]",
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(completed.state, .completed, completed.lastError ?? "")
        let requests = await provider.requests()
        let memory = try XCTUnwrap(requests.first?.messages.first(where: {
            $0.name == "luma-approved-local-memory"
        }))
        XCTAssertTrue(memory.content.contains("Prefer short answers"))
        XCTAssertFalse(completed.messages.contains(where: {
            $0.name == "luma-approved-local-memory"
        }))

        let nextProvider = LocalMemoryCaptureProvider()
        let nextRuntime = AgentRuntime(
            registry: registry, executor: ToolExecutor(registry: registry)
        )
        let next = await nextRuntime.run(
            session: completed,
            userRequest: "again",
            provider: nextProvider,
            settings: AgentSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(next.state, .completed, next.lastError ?? "")
        let nextRequests = await nextProvider.requests()
        XCTAssertFalse(nextRequests.first?.messages.contains(where: {
            $0.name == "luma-approved-local-memory"
        }) ?? true)
    }
}
