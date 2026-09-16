import Foundation
import XCTest

@testable import LumaChat

private struct RuntimeStreamingProvider: AgentModelProvider {
  let id = "runtime-streaming"

  func capabilities(for model: String) async -> ModelCapabilities {
    ModelCapabilities(
      supportsTools: true,
      supportsVision: false,
      supportsStreaming: true,
      supportsParallelTools: true,
      supportsReasoning: true,
      supportsSystemPrompt: true,
      contextWindow: 8_192,
      maxOutputTokens: 1_024
    )
  }

  func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
    throw ProviderWireError.invalidRequest("runtime should use stream(request:)")
  }

  func stream(
    request: AgentModelRequest
  ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
      continuation.yield(.contentDelta("live "))
      continuation.yield(.reasoningDelta("private reasoning"))
      continuation.yield(.contentDelta("answer"))
      continuation.yield(
        .completed(
          AgentModelResponse(
            content: "live answer",
            reasoningSummary: "private reasoning",
            toolCalls: [],
            finishReason: "stop",
            usage: AgentTokenUsage(
              inputTokens: 3,
              outputTokens: 2,
              totalTokens: 5
            )
          )
        )
      )
      continuation.finish()
    }
  }
}

private actor RuntimeEventRecorder {
  private(set) var assistantSnapshots: [String] = []
  private(set) var finalState: AgentRunState?
  private(set) var usage: AgentTokenUsage?
  private(set) var latency: TimeInterval?

  func record(_ event: AgentEvent) {
    switch event {
    case .sessionUpdated(let session), .finished(let session):
      if let content = session.messages.last(where: { $0.role == .assistant })?.content {
        assistantSnapshots.append(content)
      }
      finalState = session.state
    case .modelFinished(let value, let duration):
      usage = value
      latency = duration
    case .toolProgress, .approvalRequired, .modelStarted, .failed:
      break
    }
  }
}

private actor RuntimePauseProbe {
  private var started = false

  func markStarted() { started = true }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }
}

private struct RuntimePausingProvider: AgentModelProvider {
  let id = "runtime-pausing"
  let probe: RuntimePauseProbe

  func capabilities(for model: String) async -> ModelCapabilities {
    ModelCapabilities(
      supportsTools: true,
      supportsVision: false,
      supportsStreaming: true,
      supportsParallelTools: false,
      supportsReasoning: false,
      supportsSystemPrompt: true,
      contextWindow: 8_192,
      maxOutputTokens: 1_024
    )
  }

  func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
    throw ProviderWireError.invalidRequest("runtime should use stream(request:)")
  }

  func stream(
    request: AgentModelRequest
  ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let producer = Task {
        await probe.markStarted()
        do {
          try await Task.sleep(for: .seconds(60))
          continuation.finish(
            throwing: ProviderWireError.invalidRequest("unexpected wakeup")
          )
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in producer.cancel() }
    }
  }
}

final class AgentRuntimeStreamingTests: XCTestCase {
  func testRuntimeUsesStreamingPublishesLiveDraftAndEmitsUsageLatency() async throws {
    let root = try makeWorkspaceRoot("streaming")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = ToolRegistry()
    let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))
    let recorder = RuntimeEventRecorder()

    let result = await runtime.run(
      session: makeSession(root: root),
      userRequest: "Answer",
      provider: RuntimeStreamingProvider(),
      settings: AgentSettings(),
      approvalHandler: nil,
      eventHandler: { event in await recorder.record(event) }
    )

    XCTAssertEqual(result.state, .completed)
    XCTAssertEqual(result.messages.last(where: { $0.role == .assistant })?.content, "live answer")
    XCTAssertNil(result.messages.last(where: { $0.role == .assistant })?.reasoningSummary)
    let snapshots = await recorder.assistantSnapshots
    XCTAssertTrue(snapshots.contains("live "))
    XCTAssertEqual(snapshots.last, "live answer")
    let usage = await recorder.usage
    XCTAssertEqual(
      usage,
      AgentTokenUsage(inputTokens: 3, outputTokens: 2, totalTokens: 5)
    )
    let latency = await recorder.latency
    XCTAssertNotNil(latency)
    XCTAssertGreaterThanOrEqual(latency ?? -1, 0)
  }

  func testPauseReturnsPausedWhileStopRemainsCancelled() async throws {
    let root = try makeWorkspaceRoot("pause")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = ToolRegistry()
    let runtime = AgentRuntime(registry: registry, executor: ToolExecutor(registry: registry))

    let pauseProbe = RuntimePauseProbe()
    let pauseSession = makeSession(root: root)
    let pausedRun = Task {
      await runtime.run(
        session: pauseSession,
        userRequest: "Wait",
        provider: RuntimePausingProvider(probe: pauseProbe),
        settings: AgentSettings(),
        approvalHandler: nil,
        eventHandler: { _ in }
      )
    }
    await pauseProbe.waitUntilStarted()
    let pauseResult = await runtime.pause()
    let pausedSession = await pausedRun.value
    XCTAssertEqual(pauseResult?.state, .paused, pauseResult?.lastError ?? "")
    XCTAssertEqual(pausedSession.state, .paused, pausedSession.lastError ?? "")
    XCTAssertFalse(pausedSession.steps.contains { $0.title == "已停止" })
    XCTAssertEqual(pausedSession.steps.last?.status, .cancelled)

    let stopProbe = RuntimePauseProbe()
    let stopSession = makeSession(root: root)
    let stoppedRun = Task {
      await runtime.run(
        session: stopSession,
        userRequest: "Wait again",
        provider: RuntimePausingProvider(probe: stopProbe),
        settings: AgentSettings(),
        approvalHandler: nil,
        eventHandler: { _ in }
      )
    }
    await stopProbe.waitUntilStarted()
    await runtime.stop()
    let stoppedSession = await stoppedRun.value
    XCTAssertEqual(stoppedSession.state, .cancelled, stoppedSession.lastError ?? "")
    XCTAssertEqual(stoppedSession.steps.last?.title, "已停止")
    XCTAssertEqual(stoppedSession.steps.last?.status, .cancelled)
  }

  private func makeWorkspaceRoot(_ label: String) throws -> URL {
    let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
      "agent-runtime-\(label)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeSession(root: URL) -> AgentSession {
    var session = AgentSession(mode: .agent)
    session.model = "stream-model"
    session.workspace = AgentWorkspace(
      name: root.lastPathComponent,
      rootPath: root.path,
      allowedPaths: [],
      bookmarkData: nil,
      gitRepository: false,
      branch: nil
    )
    return session
  }
}
