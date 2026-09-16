import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import LumaChat

private final class AgentImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func reset() {
        lock.withLock { bodies = [] }
    }

    static func capturedBodies() -> [Data] {
        lock.withLock { bodies }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        Self.lock.withLock { Self.bodies.append(body) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            output.append(buffer, count: count)
        }
        return output
    }
}

private actor AgentImageProbeProvider: AgentModelProvider {
    nonisolated let id = "image-probe"
    private let supportsVision: Bool
    private let firstToolCall: AgentToolCall?
    private var captured: [AgentModelRequest] = []

    init(supportsVision: Bool, firstToolCall: AgentToolCall? = nil) {
        self.supportsVision = supportsVision
        self.firstToolCall = firstToolCall
    }

    func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: supportsVision,
            supportsStreaming: false,
            supportsParallelTools: true,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 16_384,
            maxOutputTokens: 512
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        captured.append(request)
        if captured.count == 1, let firstToolCall {
            return AgentModelResponse(
                content: "",
                reasoningSummary: nil,
                toolCalls: [firstToolCall],
                finishReason: "tool_calls",
                usage: nil
            )
        }
        return AgentModelResponse(
            content: "done",
            reasoningSummary: nil,
            toolCalls: [],
            finishReason: "stop",
            usage: nil
        )
    }

    func requests() -> [AgentModelRequest] { captured }
}

private struct AgentImageResultTool: AgentTool {
    let reference: AgentImageAttachmentReference
    let id = "test.image_result"
    let name = "image_result"
    let displayName = "Image Result"
    let description = "Return a prepared image reference."
    let inputSchema: JSONValue = .objectSchema(properties: [:])
    let category = AgentToolCategory.image
    let permissionLevel = AgentPermissionLevel.read
    let supportsParallelExecution = true

    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult {
        try AgentToolResult(
            content: "Loaded image metadata only.",
            imageAttachments: [reference]
        )
    }
}

final class AgentImageBackendTests: XCTestCase {
    func testOldMessageAndToolResultJSONDecodeWithoutImageFields() throws {
        let message = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data(#"{"role":"user","content":"legacy"}"#.utf8)
        )
        XCTAssertEqual(message.content, "legacy")
        XCTAssertEqual(message.imageAttachments, [])

        let result = try JSONDecoder().decode(
            AgentToolResult.self,
            from: Data(#"{"content":"legacy result"}"#.utf8)
        )
        XCTAssertEqual(result.content, "legacy result")
        XCTAssertEqual(result.imageAttachments, [])
    }

    func testReferenceAndPayloadBoundsFailClosed() throws {
        let png = try makePNG()
        let references = try (0...AgentImageAttachmentLimits.maximumAttachmentsPerMessage).map { _ in
            try makeReference(data: png)
        }
        XCTAssertThrowsError(
            try AgentMessage(role: .user, imageAttachments: references)
        )

        struct UntrustedPayload: Encodable {
            let attachmentID = UUID()
            let mimeType = "text/plain"
            let data = Data([0x00])
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentImagePayload.self,
                from: JSONEncoder().encode(UntrustedPayload())
            )
        )
    }

    func testViewImageToolPersistsAndReloadsValidatedPNG() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("sample.png"))

        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)
        let environment = BuiltinToolEnvironment(imageAttachmentStore: store)
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let registeredTool = await registry.tool(named: "view_image")
        let tool = try XCTUnwrap(registeredTool)
        XCTAssertEqual(tool.category, .image)
        XCTAssertEqual(tool.permissionLevel, .read)
        XCTAssertTrue(tool.supportsParallelExecution)
        XCTAssertFalse(tool.requiresNetwork)
        XCTAssertEqual(tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue), ["path"])

        let sessionID = UUID()
        let result = try await tool.execute(
            arguments: .object(["path": .string("sample.png")]),
            context: makeContext(sessionID: sessionID, root: fixture.workspaceRoot)
        )
        let reference = try XCTUnwrap(result.imageAttachments.first)
        XCTAssertEqual(result.imageAttachments.count, 1)
        XCTAssertEqual(reference.mimeType, "image/png")
        XCTAssertEqual(reference.pixelWidth, 2)
        XCTAssertEqual(reference.pixelHeight, 2)
        XCTAssertEqual(reference.byteCount, png.count)
        XCTAssertFalse(result.content.contains(png.base64EncodedString()))

        let stored = fixture.sessionsRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(reference.relativePath)
        XCTAssertEqual(try Data(contentsOf: stored), png)
        XCTAssertEqual(try store.loadPayload(for: reference, sessionID: sessionID).data, png)
        try store.remove(reference, sessionID: sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertThrowsError(try store.loadPayload(for: reference, sessionID: sessionID))
        await environment.stopAllProcesses()
    }

    func testWorkspaceEscapeSourceSymlinkAndDestinationSymlinkAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        let outside = fixture.scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try png.write(to: outside.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(
            at: fixture.workspaceRoot.appendingPathComponent("linked"),
            withDestinationURL: outside
        )
        let validator = try makeValidator(root: fixture.workspaceRoot)
        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)

        XCTAssertThrowsError(
            try store.importWorkspaceImage(
                path: "../outside/outside.png",
                sessionID: UUID(),
                validator: validator
            )
        )
        XCTAssertThrowsError(
            try store.importWorkspaceImage(
                path: "linked/outside.png",
                sessionID: UUID(),
                validator: validator
            )
        )

        let attackedSession = UUID()
        let attackedDirectory = fixture.sessionsRoot
            .appendingPathComponent(attackedSession.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: attackedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: attackedDirectory.appendingPathComponent("Attachments"),
            withDestinationURL: outside
        )
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("safe.png"))
        XCTAssertThrowsError(
            try store.importWorkspaceImage(
                path: "safe.png",
                sessionID: attackedSession,
                validator: validator
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(),
            ["outside.png"]
        )
    }

    func testAttachmentStorageFailureDoesNotExposeAbsoluteHostPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("safe.png"))
        let blockedRoot = fixture.scratch.appendingPathComponent(
            "blocked-session-storage",
            isDirectory: false
        )
        try Data("not a directory".utf8).write(to: blockedRoot)
        let store = AgentImageAttachmentStore(sessionsRoot: blockedRoot)

        XCTAssertThrowsError(
            try store.importWorkspaceImage(
                path: "safe.png",
                sessionID: UUID(),
                validator: makeValidator(root: fixture.workspaceRoot)
            )
        ) { error in
            XCTAssertFalse(error.localizedDescription.contains(fixture.scratch.path))
            XCTAssertFalse(error.localizedDescription.contains(blockedRoot.path))
            XCTAssertTrue(error.localizedDescription.contains("Agent session attachment storage"))
        }
    }

    func testImageSignatureSingleFileAndSessionQuotasAreEnforced() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try Data("not an image".utf8).write(
            to: fixture.workspaceRoot.appendingPathComponent("fake.png")
        )
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("one.png"))
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("two.png"))
        let validator = try makeValidator(root: fixture.workspaceRoot)

        let normalStore = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)
        XCTAssertThrowsError(
            try normalStore.importWorkspaceImage(
                path: "fake.png",
                sessionID: UUID(),
                validator: validator
            )
        )

        let smallStore = AgentImageAttachmentStore(
            sessionsRoot: fixture.scratch.appendingPathComponent("small-sessions"),
            maximumFileBytes: png.count - 1
        )
        XCTAssertThrowsError(
            try smallStore.importWorkspaceImage(
                path: "one.png",
                sessionID: UUID(),
                validator: validator
            )
        )

        let countStore = AgentImageAttachmentStore(
            sessionsRoot: fixture.scratch.appendingPathComponent("count-sessions"),
            maximumSessionAttachments: 1
        )
        let countSession = UUID()
        _ = try countStore.importWorkspaceImage(
            path: "one.png",
            sessionID: countSession,
            validator: validator
        )
        XCTAssertThrowsError(
            try countStore.importWorkspaceImage(
                path: "two.png",
                sessionID: countSession,
                validator: validator
            )
        )

        let totalStore = AgentImageAttachmentStore(
            sessionsRoot: fixture.scratch.appendingPathComponent("total-sessions"),
            maximumSessionAttachments: 4,
            maximumSessionBytes: png.count + 1
        )
        let totalSession = UUID()
        _ = try totalStore.importWorkspaceImage(
            path: "one.png",
            sessionID: totalSession,
            validator: validator
        )
        XCTAssertThrowsError(
            try totalStore.importWorkspaceImage(
                path: "two.png",
                sessionID: totalSession,
                validator: validator
            )
        )
    }

    func testStoredTamperIsRejectedAndSessionDeleteRemovesAttachmentsPermanently() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("sample.png"))
        let sessionID = UUID()
        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)
        let reference = try store.importWorkspaceImage(
            path: "sample.png",
            sessionID: sessionID,
            validator: makeValidator(root: fixture.workspaceRoot)
        )
        let stored = fixture.sessionsRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(reference.relativePath)
        try Data(repeating: 0x41, count: png.count).write(to: stored)
        XCTAssertThrowsError(try store.loadPayload(for: reference, sessionID: sessionID))

        let sessionStore = AgentSessionStore(sessionsRoot: fixture.sessionsRoot)
        try await sessionStore.delete(id: sessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        var lateSession = AgentSession(mode: .agent)
        lateSession.id = sessionID
        await assertAsyncThrows {
            try await sessionStore.save(lateSession)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.sessionsRoot.appendingPathComponent(sessionID.uuidString).path
            )
        )
    }

    func testProviderAdaptersEncodeExactImageShapes() throws {
        let png = try makePNG()
        let image = ProviderWireImage(
            attachmentID: UUID(),
            mimeType: "image/png",
            data: png
        )
        let messages = [
            ProviderWireMessage(
                role: .assistant,
                toolCalls: [.init(id: "call-1", name: "view_image", arguments: .emptyObject)]
            ),
            ProviderWireMessage(
                role: .tool,
                toolResult: .init(
                    callID: "call-1",
                    toolName: "view_image",
                    content: "Loaded image metadata",
                    isError: false
                )
            ),
            ProviderWireMessage(role: .user, images: [image])
        ]
        let wire = ProviderWireRequest(
            model: "vision-model",
            messages: messages,
            tools: [],
            contextLength: 8_192,
            maxOutputTokens: 512,
            temperature: 0.2
        )
        let base64 = png.base64EncodedString()

        let ollama = try jsonObject(
            OllamaAgentWireAdapter.makeChatRequest(
                wire,
                settings: settings(provider: .ollama, endpoint: "http://127.0.0.1:11434"),
                apiKey: nil
            )
        )
        let ollamaMessages = try XCTUnwrap(ollama["messages"] as? [[String: Any]])
        XCTAssertEqual(ollamaMessages.last?["role"] as? String, "user")
        XCTAssertEqual(ollamaMessages.last?["images"] as? [String], [base64])

        let openAI = try jsonObject(
            OpenAICompatibleAgentWireAdapter.makeChatRequest(
                wire,
                settings: settings(provider: .openAICompatible, endpoint: "https://example.com/v1"),
                apiKey: "test-key"
            )
        )
        let openAIMessages = try XCTUnwrap(openAI["messages"] as? [[String: Any]])
        let openAIBlocks = try XCTUnwrap(openAIMessages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(openAIBlocks.last?["type"] as? String, "image_url")
        XCTAssertEqual(
            (openAIBlocks.last?["image_url"] as? [String: Any])?["url"] as? String,
            "data:image/png;base64,\(base64)"
        )

        let anthropic = try jsonObject(
            AnthropicAgentWireAdapter.makeMessagesRequest(
                wire,
                settings: settings(provider: .anthropic, endpoint: "https://api.anthropic.com/v1"),
                apiKey: "test-key"
            )
        )
        let anthropicMessages = try XCTUnwrap(anthropic["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(
            anthropicMessages.first { $0["role"] as? String == "user" }?["content"] as? [[String: Any]]
        )
        XCTAssertEqual(userContent.first?["type"] as? String, "tool_result")
        let imageBlock = try XCTUnwrap(userContent.first { $0["type"] as? String == "image" })
        let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, base64)
    }

    func testProviderUsesOnlyExplicitPayloadBytesAndRejectsUnreferencedPayload() async throws {
        AgentImageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentImageURLProtocol.self]
        let provider = AgentModelProviderFactory.make(
            settings: settings(provider: .ollama, endpoint: "http://127.0.0.1:11434"),
            apiKey: nil,
            session: URLSession(configuration: configuration)
        )
        let png = try makePNG()
        let reference = try makeReference(data: png)
        let metadataOnly = try AgentMessage(
            role: .user,
            content: "metadata only",
            imageAttachments: [reference]
        )
        _ = try await provider.generate(
            request: AgentModelRequest(
                model: "vision-model",
                messages: [metadataOnly],
                tools: [],
                stream: false,
                temperature: 0.2,
                maxOutputTokens: 128
            )
        )
        let firstBody = try XCTUnwrap(AgentImageURLProtocol.capturedBodies().first)
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstBody) as? [String: Any]
        )
        let firstMessages = try XCTUnwrap(firstJSON["messages"] as? [[String: Any]])
        XCTAssertNil(firstMessages.first?["images"])

        AgentImageURLProtocol.reset()
        let payload = try AgentImagePayload(reference: reference, data: png)
        await assertAsyncThrows {
            _ = try await provider.generate(
                request: try AgentModelRequest(
                    model: "vision-model",
                    messages: [AgentMessage(role: .user, content: "no reference")],
                    tools: [],
                    stream: false,
                    temperature: 0.2,
                    maxOutputTokens: 128,
                    imagePayloads: [payload]
                )
            )
        }
        XCTAssertEqual(AgentImageURLProtocol.capturedBodies().count, 0)

        let toolMessage = try AgentMessage(
            role: .tool,
            content: "Loaded image metadata",
            toolCallID: "call-1",
            name: "view_image",
            imageAttachments: [reference]
        )
        let request = try AgentModelRequest(
            model: "vision-model",
            messages: [
                AgentMessage(
                    role: .assistant,
                    toolCalls: [AgentToolCall(id: "call-1", name: "view_image")]
                ),
                toolMessage
            ],
            tools: [],
            stream: false,
            temperature: 0.2,
            maxOutputTokens: 128,
            imagePayloads: [payload]
        )
        _ = try await provider.generate(request: request)
        let body = try XCTUnwrap(AgentImageURLProtocol.capturedBodies().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "user"])
        XCTAssertNil(messages[1]["images"])
        XCTAssertEqual(messages[2]["images"] as? [String], [png.base64EncodedString()])
    }

    func testProviderEmitsRepeatedReferenceOnlyBesideNewestMessage() async throws {
        AgentImageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentImageURLProtocol.self]
        let provider = AgentModelProviderFactory.make(
            settings: settings(provider: .ollama, endpoint: "http://127.0.0.1:11434"),
            apiKey: nil,
            session: URLSession(configuration: configuration)
        )
        let png = try makePNG()
        let reference = try makeReference(data: png)
        let payload = try AgentImagePayload(reference: reference, data: png)
        let older = try AgentMessage(
            role: .user,
            content: "Earlier attachment metadata",
            imageAttachments: [reference]
        )
        let newest = try AgentMessage(
            role: .user,
            content: "Inspect the re-attached image now",
            imageAttachments: [reference]
        )

        _ = try await provider.generate(
            request: try AgentModelRequest(
                model: "vision-model",
                messages: [older, newest],
                tools: [],
                stream: false,
                temperature: 0.2,
                maxOutputTokens: 128,
                imagePayloads: [payload]
            )
        )

        let body = try XCTUnwrap(AgentImageURLProtocol.capturedBodies().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertNil(messages[0]["images"])
        XCTAssertEqual(messages[1]["images"] as? [String], [png.base64EncodedString()])
        let serializedBody = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(serializedBody.contains(reference.relativePath))
        XCTAssertFalse(serializedBody.contains(reference.sha256))
    }

    func testParallelToolImagesFollowEveryToolResultAsOneUserTurn() async throws {
        AgentImageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentImageURLProtocol.self]
        let provider = AgentModelProviderFactory.make(
            settings: settings(provider: .ollama, endpoint: "http://127.0.0.1:11434"),
            apiKey: nil,
            session: URLSession(configuration: configuration)
        )
        let png = try makePNG()
        let firstReference = try makeReference(data: png)
        let secondReference = try makeReference(data: png)
        let assistant = AgentMessage(
            role: .assistant,
            toolCalls: [
                AgentToolCall(id: "call-1", name: "view_image"),
                AgentToolCall(id: "call-2", name: "view_image")
            ]
        )
        let firstResult = try AgentMessage(
            role: .tool,
            content: "First image metadata",
            toolCallID: "call-1",
            name: "view_image",
            imageAttachments: [firstReference]
        )
        let secondResult = try AgentMessage(
            role: .tool,
            content: "Second image metadata",
            toolCallID: "call-2",
            name: "view_image",
            imageAttachments: [secondReference]
        )

        _ = try await provider.generate(
            request: try AgentModelRequest(
                model: "vision-model",
                messages: [assistant, firstResult, secondResult],
                tools: [],
                stream: false,
                temperature: 0.2,
                maxOutputTokens: 128,
                imagePayloads: [
                    try AgentImagePayload(reference: firstReference, data: png),
                    try AgentImagePayload(reference: secondReference, data: png)
                ]
            )
        )

        let body = try XCTUnwrap(AgentImageURLProtocol.capturedBodies().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(
            messages.compactMap { $0["role"] as? String },
            ["assistant", "tool", "tool", "user"]
        )
        XCTAssertNil(messages[1]["images"])
        XCTAssertNil(messages[2]["images"])
        XCTAssertEqual(
            messages[3]["images"] as? [String],
            [png.base64EncodedString(), png.base64EncodedString()]
        )
    }

    func testCompatibleProvidersFailClosedUntilVisionIsExplicitlyEnabled() async {
        let automaticProvider = AgentModelProviderFactory.make(
            settings: settings(provider: .openAICompatible, endpoint: "https://example.com/v1"),
            apiKey: nil
        )
        let automatic = await automaticProvider.capabilities(
            for: "arbitrary-compatible-model"
        )
        XCTAssertFalse(automatic.supportsVision)

        let enabledProvider = AgentModelProviderFactory.make(
            settings: settings(provider: .openAICompatible, endpoint: "https://example.com/v1"),
            apiKey: nil,
            visionCapabilityOverride: true
        )
        let enabled = await enabledProvider.capabilities(for: "known-vision-model")
        XCTAssertTrue(enabled.supportsVision)

        let anthropicAutomatic = AgentModelProviderFactory.make(
            settings: settings(provider: .anthropic, endpoint: "https://api.anthropic.com/v1"),
            apiKey: nil
        )
        let anthropic = await anthropicAutomatic.capabilities(for: "unknown-model")
        XCTAssertFalse(anthropic.supportsVision)
    }

    func testRuntimeHydratesUserAttachmentsOnlyForVisionModels() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("user.png"))
        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)

        let visionSession = makeSession(root: fixture.workspaceRoot)
        let visionReference = try store.importWorkspaceImage(
            path: "user.png",
            sessionID: visionSession.id,
            validator: makeValidator(root: fixture.workspaceRoot)
        )
        let visionProvider = AgentImageProbeProvider(supportsVision: true)
        let visionRuntime = try await makeRuntime(imageStore: store)
        let visionResult = await visionRuntime.run(
            session: visionSession,
            userRequest: "Inspect this image",
            userImageAttachments: [visionReference],
            provider: visionProvider,
            settings: imageRuntimeSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(visionResult.state, .completed)
        let visionRequests = await visionProvider.requests()
        let visionRequest = try XCTUnwrap(visionRequests.first)
        XCTAssertEqual(visionRequest.imagePayloads.count, 1)
        XCTAssertEqual(visionRequest.imagePayloads.first?.data, png)
        XCTAssertEqual(
            visionRequest.messages.last(where: { $0.role == .user })?.imageAttachments,
            [visionReference]
        )

        let metadataSession = makeSession(root: fixture.workspaceRoot)
        let metadataReference = try store.importWorkspaceImage(
            path: "user.png",
            sessionID: metadataSession.id,
            validator: makeValidator(root: fixture.workspaceRoot)
        )
        try store.remove(metadataReference, sessionID: metadataSession.id)
        let metadataProvider = AgentImageProbeProvider(supportsVision: false)
        let metadataRuntime = try await makeRuntime(imageStore: store)
        let metadataResult = await metadataRuntime.run(
            session: metadataSession,
            userRequest: "Inspect without vision",
            userImageAttachments: [metadataReference],
            provider: metadataProvider,
            settings: imageRuntimeSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(metadataResult.state, .completed)
        let metadataRequests = await metadataProvider.requests()
        let metadataRequest = try XCTUnwrap(metadataRequests.first)
        XCTAssertEqual(metadataRequest.imagePayloads, [])
        XCTAssertTrue(
            metadataRequest.messages.last(where: { $0.role == .user })?.content
                .contains("Attached image") == true
        )
    }

    func testRuntimePreservesToolImageReferenceAndGatesItsBytesByVisionCapability() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        try png.write(to: fixture.workspaceRoot.appendingPathComponent("tool.png"))
        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)

        let session = makeSession(root: fixture.workspaceRoot)
        let reference = try store.importWorkspaceImage(
            path: "tool.png",
            sessionID: session.id,
            validator: makeValidator(root: fixture.workspaceRoot)
        )
        let call = AgentToolCall(id: "image-call", name: "image_result")
        let provider = AgentImageProbeProvider(supportsVision: true, firstToolCall: call)
        let registry = ToolRegistry()
        try await registry.register(AgentImageResultTool(reference: reference))
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry),
            imageAttachmentStore: store
        )
        let result = await runtime.run(
            session: session,
            userRequest: "Use the image tool",
            provider: provider,
            settings: imageRuntimeSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(result.state, .completed)
        let toolMessage = try XCTUnwrap(result.messages.first { $0.role == .tool })
        XCTAssertEqual(toolMessage.imageAttachments, [reference])
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].imagePayloads.first?.data, png)
        XCTAssertEqual(
            requests[1].messages.first(where: { $0.role == .tool })?.imageAttachments,
            [reference]
        )

        let metadataSession = makeSession(root: fixture.workspaceRoot)
        let metadataReference = try store.importWorkspaceImage(
            path: "tool.png",
            sessionID: metadataSession.id,
            validator: makeValidator(root: fixture.workspaceRoot)
        )
        try store.remove(metadataReference, sessionID: metadataSession.id)
        let metadataProvider = AgentImageProbeProvider(
            supportsVision: false,
            firstToolCall: call
        )
        let metadataRegistry = ToolRegistry()
        try await metadataRegistry.register(AgentImageResultTool(reference: metadataReference))
        let metadataRuntime = AgentRuntime(
            registry: metadataRegistry,
            executor: ToolExecutor(registry: metadataRegistry),
            imageAttachmentStore: store
        )
        let metadataResult = await metadataRuntime.run(
            session: metadataSession,
            userRequest: "Use metadata only",
            provider: metadataProvider,
            settings: imageRuntimeSettings(),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(metadataResult.state, .completed)
        let metadataRequests = await metadataProvider.requests()
        XCTAssertEqual(metadataRequests.count, 2)
        XCTAssertEqual(metadataRequests[1].imagePayloads, [])
        XCTAssertEqual(
            metadataRequests[1].messages.first(where: { $0.role == .tool })?.content,
            "Loaded image metadata only."
        )
    }

    private struct Fixture {
        var scratch: URL
        var workspaceRoot: URL
        var sessionsRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let scratch = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-image-backend-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
        let sessions = scratch.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return Fixture(scratch: scratch, workspaceRoot: workspace, sessionsRoot: sessions)
    }

    private func makeContext(sessionID: UUID, root: URL) -> AgentToolContext {
        AgentToolContext(
            sessionID: sessionID,
            mode: .agent,
            workspace: makeWorkspace(root: root)
        )
    }

    private func makeValidator(root: URL) throws -> WorkspaceSecurityValidator {
        try WorkspaceSecurityValidator(workspace: makeWorkspace(root: root))
    }

    private func makeWorkspace(root: URL) -> AgentWorkspace {
        AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
    }

    private func makeSession(root: URL) -> AgentSession {
        var session = AgentSession(mode: .agent)
        session.workspace = makeWorkspace(root: root)
        session.model = "vision-model"
        return session
    }

    private func makeRuntime(imageStore: AgentImageAttachmentStore) async throws -> AgentRuntime {
        let registry = ToolRegistry()
        return AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry),
            imageAttachmentStore: imageStore
        )
    }

    private func imageRuntimeSettings() -> AgentSettings {
        var settings = AgentSettings()
        settings.maxSteps = 6
        settings.autoRunTests = false
        return settings
    }

    private func makePNG() throws -> Data {
        let pixels = Data([
            0x00, 0x7A, 0xFF, 0xFF, 0xFF, 0x3B, 0x30, 0xFF,
            0x34, 0xC7, 0x59, 0xFF, 0xAF, 0x52, 0xDE, 0xFF
        ])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: 2,
                  height: 2,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 8,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw AgentImageAttachmentError.invalidImage("無法建立測試影像")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw AgentImageAttachmentError.invalidImage("無法編碼測試 PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentImageAttachmentError.invalidImage("無法完成測試 PNG")
        }
        return output as Data
    }

    private func makeReference(data: Data) throws -> AgentImageAttachmentReference {
        let id = UUID()
        return try AgentImageAttachmentReference(
            id: id,
            name: "fixture.png",
            relativePath: "Attachments/\(id.uuidString.lowercased()).png",
            mimeType: "image/png",
            byteCount: data.count,
            pixelWidth: 2,
            pixelHeight: 2,
            sha256: AgentImageAttachmentLimits.digestHex(data)
        )
    }

    private func settings(provider: ProviderKind, endpoint: String) -> AppSettings {
        AppSettings(
            provider: provider,
            endpoint: endpoint,
            selectedModel: "vision-model",
            contextLength: 8_192,
            temperature: 0.2
        )
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        let data = request.httpBody ?? Data()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertAsyncThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
