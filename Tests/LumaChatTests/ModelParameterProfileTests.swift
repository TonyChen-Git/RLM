import Foundation
import XCTest
@testable import LumaChat

private final class ModelParameterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody = Data()
    nonisolated(unsafe) static var requestedPaths: [String] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> (String, Data))?
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = Self.bodyData(from: request)
        Self.requestedPaths.append(request.url?.path ?? "")
        let result = Self.responder?(request)
            ?? ("text/event-stream", Data("data: [DONE]\n\n".utf8))
        let response = HTTPURLResponse(
            url: Self.responseURL ?? request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": result.0]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

final class ModelParameterProfileTests: XCTestCase {
    override func tearDown() {
        ModelParameterURLProtocol.responder = nil
        ModelParameterURLProtocol.statusCode = 200
        ModelParameterURLProtocol.responseURL = nil
        ModelParameterURLProtocol.requestedPaths = []
        ModelParameterURLProtocol.lastRequestBody = Data()
        super.tearDown()
    }

    func testFirstSelectionIsAutoAndQwen38UsesSafeRecommendation() {
        let route = route(backend: .ollama, model: "qwen3:8b", useCase: .agent)
        let profile = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: []
        )

        XCTAssertEqual(profile.mode, .auto)
        XCTAssertEqual(profile.recommendationRule, "exact:qwen3-8b")
        XCTAssertEqual(profile.values.contextWindowTokens, 65_536)
        XCTAssertEqual(profile.values.maxOutputTokens, 16_384)
        XCTAssertEqual(profile.values.temperature, 1)
        XCTAssertEqual(profile.values.topP, 0.95)
        XCTAssertEqual(profile.values.topK, 20)
        XCTAssertTrue(profile.values.thinkingEnabled)
        XCTAssertEqual(profile.values.reasoningEffort, .medium)
        XCTAssertFalse(profile.values.preserveThinking)
    }

    func testManualEditMaterializesFullCustomAndSurvivesSettingsRoundTrip() throws {
        let route = route(backend: .ollama, model: "qwen3:8b")
        var values = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: []
        ).values
        values.temperature = 0.42
        let profiles = ModelParameterRecommendationEngine.replacingCustomProfile(
            in: [],
            route: route,
            values: values
        )
        let encoded = try JSONEncoder().encode(AppSettings(modelParameterProfiles: profiles))
        let relaunched = try JSONDecoder().decode(AppSettings.self, from: encoded)
        let restored = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: relaunched.modelParameterProfiles
        )

        XCTAssertEqual(restored.mode, .custom)
        XCTAssertEqual(restored.values.temperature, 0.42)
        XCTAssertEqual(restored.values.contextWindowTokens, 65_536)
        XCTAssertEqual(restored.values.maxOutputTokens, 16_384)
    }

    func testSwitchingModelsRestoresCustomAndResetReturnsOnlyTargetToAuto() {
        let first = route(backend: .ollama, model: "model-a")
        let second = route(backend: .ollama, model: "model-b")
        var firstValues = ModelParameterRecommendationEngine.effectiveProfile(
            for: first,
            profiles: []
        ).values
        firstValues.topP = 0.33
        var profiles = ModelParameterRecommendationEngine.replacingCustomProfile(
            in: [],
            route: first,
            values: firstValues
        )

        XCTAssertEqual(
            ModelParameterRecommendationEngine.effectiveProfile(
                for: second,
                profiles: profiles
            ).mode,
            .auto
        )
        XCTAssertEqual(
            ModelParameterRecommendationEngine.effectiveProfile(
                for: first,
                profiles: profiles
            ).values.topP,
            0.33
        )

        profiles = ModelParameterRecommendationEngine.resettingToAuto(
            in: profiles,
            route: first
        )
        XCTAssertEqual(
            ModelParameterRecommendationEngine.effectiveProfile(
                for: first,
                profiles: profiles
            ).mode,
            .auto
        )
    }

    func testSameModelIDOnDifferentBackendsNeverCollides() {
        let ollama = route(backend: .ollama, model: "shared-name")
        let lmStudio = route(backend: .lmStudio, model: "shared-name")
        var values = ModelParameterRecommendationEngine.effectiveProfile(
            for: ollama,
            profiles: []
        ).values
        values.temperature = 0.11
        let profiles = ModelParameterRecommendationEngine.replacingCustomProfile(
            in: [],
            route: ollama,
            values: values
        )

        XCTAssertNotEqual(ollama.key, lmStudio.key)
        XCTAssertEqual(
            ModelParameterRecommendationEngine.effectiveProfile(
                for: ollama,
                profiles: profiles
            ).mode,
            .custom
        )
        XCTAssertEqual(
            ModelParameterRecommendationEngine.effectiveProfile(
                for: lmStudio,
                profiles: profiles
            ).mode,
            .auto
        )
    }

    func testCaseSensitiveModelAndEndpointPathIdentitiesNeverCollide() {
        let upperModel = ModelParameterRoute(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "https://example.test/Tenant/v1",
            modelID: "Org/Model",
            useCase: .chat
        )
        let lowerModel = ModelParameterRoute(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "https://example.test/Tenant/v1",
            modelID: "org/model",
            useCase: .chat
        )
        let lowerPath = ModelParameterRoute(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "https://example.test/tenant/v1",
            modelID: "Org/Model",
            useCase: .chat
        )

        XCTAssertNotEqual(upperModel.key, lowerModel.key)
        XCTAssertNotEqual(upperModel.key, lowerPath.key)
    }

    func testOpenAIReasoningSamplingFieldsAreCapabilityDisabled() {
        let route = ModelParameterRoute(
            provider: .openAICompatible,
            backend: .openAI,
            endpoint: "https://api.openai.com/v1",
            modelID: "o3",
            useCase: .agent
        )
        let capabilities = ModelParameterRecommendationEngine.capabilities(for: route)

        XCTAssertFalse(capabilities.supportsTemperature)
        XCTAssertFalse(capabilities.supportsTopP)
        XCTAssertFalse(capabilities.supportsPresencePenalty)
        XCTAssertTrue(capabilities.supportsReasoningEffort)
    }

    func testAgentCapabilityDoesNotUseLegacyContextPreferenceAsModelCeiling() async {
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .lmStudio,
            endpoint: "http://localhost:1234/v1",
            selectedModel: "qwen3:8b",
            contextLength: 2_048
        )
        let provider = AgentModelProviderFactory.make(settings: settings, apiKey: nil)

        let capabilities = await provider.capabilities(for: settings.selectedModel)

        XCTAssertEqual(capabilities.contextWindow, 131_072)
    }

    func testOllamaModelInfoStillClampsAgentWhenCapabilityArrayIsAbsent() throws {
        let data = Data(
            #"{"model_info":{"architecture.context_length":4096}}"#.utf8
        )

        let capabilities = try XCTUnwrap(OllamaAgentWireAdapter.parseCapabilities(data))

        XCTAssertEqual(capabilities.contextWindow, 4_096)
        XCTAssertTrue(capabilities.supportsTools)
        XCTAssertFalse(capabilities.supportsReasoning)
    }

    func testValidationClampsIllegalNumbersAndEffectiveContextToMaximum() {
        let route = route(backend: .openAICompatible, model: "unknown")
        let capabilities = ModelParameterRecommendationEngine.capabilities(for: route)
        let invalid = ModelParameterValues(
            contextWindowTokens: Int.max,
            maxOutputTokens: Int.max,
            temperature: .infinity,
            topP: -4,
            topK: -1,
            minP: 4,
            repetitionPenalty: .nan,
            presencePenalty: 8,
            thinkingEnabled: true,
            reasoningEffort: .xhigh,
            preserveThinking: true
        )
        let value = ModelParameterValidation.normalized(invalid, capabilities: capabilities)

        XCTAssertEqual(value.contextWindowTokens, capabilities.maximumContextTokens)
        XCTAssertLessThanOrEqual(value.maxOutputTokens, value.contextWindowTokens)
        XCTAssertEqual(value.temperature, 0.7)
        XCTAssertEqual(value.topP, 0)
        XCTAssertEqual(value.topK, 0)
        XCTAssertEqual(value.minP, 1)
        XCTAssertEqual(value.repetitionPenalty, 1)
        XCTAssertEqual(value.presencePenalty, 2)
        XCTAssertFalse(value.thinkingEnabled)
        XCTAssertFalse(value.preserveThinking)
    }

    func testDiscoveredCapabilitiesClampAutoAndCustomWithoutReplacingCustomMode() {
        let route = route(backend: .ollama, model: "qwen3:8b")
        var customValues = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: []
        ).values
        customValues.contextWindowTokens = 65_536
        customValues.maxOutputTokens = 16_384
        customValues.thinkingEnabled = true
        let profiles = ModelParameterRecommendationEngine.replacingCustomProfile(
            in: [],
            route: route,
            values: customValues
        )
        let discovered = DiscoveredModelParameterCapabilities(
            modelMaximumContextTokens: 4_096,
            maximumOutputTokens: 2_048,
            supportsThinking: false
        )

        let automatic = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: [],
            discoveredCapabilities: discovered
        )
        let custom = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: profiles,
            discoveredCapabilities: discovered
        )

        XCTAssertEqual(automatic.mode, .auto)
        XCTAssertEqual(custom.mode, .custom)
        XCTAssertEqual(custom.values.contextWindowTokens, 4_096)
        XCTAssertEqual(custom.values.maxOutputTokens, 2_048)
        XCTAssertFalse(custom.values.thinkingEnabled)
        XCTAssertFalse(custom.capabilities.supportsThinking)
    }

    func testOllamaChatUsesDiscoveredLimitsAndOmitsUnsupportedThinking() async throws {
        ModelParameterURLProtocol.requestedPaths = []
        ModelParameterURLProtocol.responder = { request in
            if request.url?.path == "/api/show" {
                return (
                    "application/json",
                    Data(#"{"capabilities":["completion"],"model_info":{"qwen3.context_length":4096}}"#.utf8)
                )
            }
            return (
                "application/x-ndjson",
                Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
                    + Data("\n".utf8)
            )
        }
        defer { ModelParameterURLProtocol.responder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://unit.test",
            selectedModel: "qwen3:8b"
        )
        let parameters = ModelParameterRecommendationEngine.effectiveProfile(
            for: ModelParameterRoute(settings: settings, useCase: .chat),
            profiles: []
        )

        for try await _ in client.stream(
            messages: [ChatMessage(role: .user, content: "hello")],
            settings: settings,
            parameters: parameters,
            apiKey: nil,
            attachmentLoader: { _ in nil }
        ) {}

        XCTAssertEqual(ModelParameterURLProtocol.requestedPaths, ["/api/show", "/api/chat"])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertNil(json["think"])
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 4_096)
        XCTAssertEqual(options["num_predict"] as? Int, 4_096)
    }

    func testOllamaAgentBoundaryUsesDiscoveredLimitsAndOmitsUnsupportedThinking() async throws {
        ModelParameterURLProtocol.requestedPaths = []
        ModelParameterURLProtocol.responder = { request in
            if request.url?.path == "/api/show" {
                return (
                    "application/json",
                    Data(#"{"capabilities":["completion","tools"],"model_info":{"qwen3.context_length":4096}}"#.utf8)
                )
            }
            return (
                "application/x-ndjson",
                Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
                    + Data("\n".utf8)
            )
        }
        defer { ModelParameterURLProtocol.responder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://unit.test",
            selectedModel: "qwen3:8b"
        )
        let provider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: nil,
            session: session
        )
        let request = AgentModelRequest(
            model: settings.selectedModel,
            messages: [AgentMessage(role: .user, content: "hello")],
            tools: [],
            stream: true,
            temperature: 1,
            maxOutputTokens: 16_384,
            contextWindowTokens: 65_536,
            thinkingEnabled: true
        )

        for try await _ in provider.stream(request: request) {}

        XCTAssertEqual(ModelParameterURLProtocol.requestedPaths, ["/api/show", "/api/chat"])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertNil(json["think"])
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 4_096)
        XCTAssertEqual(options["num_predict"] as? Int, 4_096)
    }

    func testOllamaAgentContextOnlyMetadataDoesNotDisableFamilyThinking() async throws {
        ModelParameterURLProtocol.requestedPaths = []
        ModelParameterURLProtocol.responder = { request in
            if request.url?.path == "/api/show" {
                return (
                    "application/json",
                    Data(#"{"model_info":{"qwen3.context_length":4096}}"#.utf8)
                )
            }
            return (
                "application/x-ndjson",
                Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
                    + Data("\n".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://unit.test",
            selectedModel: "qwen3:8b"
        )
        let provider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: nil,
            session: session
        )
        let request = AgentModelRequest(
            model: settings.selectedModel,
            messages: [AgentMessage(role: .user, content: "hello")],
            tools: [],
            stream: true,
            temperature: 1,
            maxOutputTokens: 16_384,
            contextWindowTokens: 65_536,
            thinkingEnabled: true
        )

        for try await _ in provider.stream(request: request) {}

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertEqual(json["think"] as? Bool, true)
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 4_096)
    }

    func testOllamaAgentRetriesNonAuthoritativeCapabilityDiscovery() async throws {
        ModelParameterURLProtocol.requestedPaths = []
        var showAttempts = 0
        ModelParameterURLProtocol.responder = { request in
            if request.url?.path == "/api/show" {
                showAttempts += 1
                if showAttempts == 1 {
                    return ("application/json", Data(#"{}"#.utf8))
                }
                return (
                    "application/json",
                    Data(#"{"capabilities":["completion","thinking"]}"#.utf8)
                )
            }
            return (
                "application/x-ndjson",
                Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
                    + Data("\n".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://unit.test",
            selectedModel: "qwen3:8b"
        )
        let provider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: nil,
            session: session
        )
        let request = AgentModelRequest(
            model: settings.selectedModel,
            messages: [AgentMessage(role: .user, content: "hello")],
            tools: [],
            stream: true,
            temperature: 1,
            maxOutputTokens: 16_384,
            contextWindowTokens: 65_536,
            thinkingEnabled: true
        )

        for try await _ in provider.stream(request: request) {}
        for try await _ in provider.stream(request: request) {}

        XCTAssertEqual(
            ModelParameterURLProtocol.requestedPaths,
            ["/api/show", "/api/chat", "/api/show", "/api/chat"]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertEqual(json["think"] as? Bool, true)
    }

    func testUnsupportedOpenAICompatibleFieldsAreOmittedFromChatRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://localhost:1234/v1",
            selectedModel: "generic-model"
        )
        let route = ModelParameterRoute(settings: settings, useCase: .chat)
        let parameters = ModelParameterRecommendationEngine.effectiveProfile(
            for: route,
            profiles: []
        )

        for try await _ in client.stream(
            messages: [ChatMessage(role: .user, content: "hello")],
            settings: settings,
            parameters: parameters,
            apiKey: nil,
            attachmentLoader: { _ in nil }
        ) {}

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertNotNil(json["temperature"])
        XCTAssertNotNil(json["top_p"])
        XCTAssertNotNil(json["presence_penalty"])
        XCTAssertNil(json["top_k"])
        XCTAssertNil(json["min_p"])
        XCTAssertNil(json["repetition_penalty"])
        XCTAssertNil(json["reasoning_effort"])
        XCTAssertNil(json["chat_template_kwargs"])
    }

    func testOpenAIReasoningRequestOmitsUnsupportedSamplingFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAI,
            endpoint: "https://api.openai.com/v1",
            selectedModel: "o3"
        )
        let parameters = ModelParameterRecommendationEngine.effectiveProfile(
            for: ModelParameterRoute(settings: settings, useCase: .chat),
            profiles: []
        )

        for try await _ in client.stream(
            messages: [ChatMessage(role: .user, content: "hello")],
            settings: settings,
            parameters: parameters,
            apiKey: "unit-test-key",
            attachmentLoader: { _ in nil }
        ) {}

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["presence_penalty"])
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")
        XCTAssertNil(json["max_tokens"])
        XCTAssertNotNil(json["max_completion_tokens"])
    }

    func testAgentProviderBoundaryAlsoOmitsUnsupportedSamplingFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAI,
            endpoint: "https://api.openai.com/v1",
            selectedModel: "o3"
        )
        let provider = AgentModelProviderFactory.make(
            settings: settings,
            apiKey: "unit-test-key",
            session: session
        )
        let request = AgentModelRequest(
            model: "o3",
            messages: [AgentMessage(role: .user, content: "hello")],
            tools: [],
            stream: true,
            temperature: 0.42,
            maxOutputTokens: 1_024,
            topP: 0.55,
            presencePenalty: 0.75,
            reasoningEffort: .medium
        )

        for try await _ in provider.stream(request: request) {}

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ModelParameterURLProtocol.lastRequestBody)
                as? [String: Any]
        )
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["presence_penalty"])
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")
    }

    func testClassicChatRejectsCleartextRemoteCredentialRoutesBeforeTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)

        for provider in [ProviderKind.openAICompatible, .anthropic] {
            let settings = AppSettings(
                provider: provider,
                backend: .openAICompatible,
                endpoint: "http://remote.example.test/v1",
                selectedModel: "model"
            )
            do {
                _ = try await client.fetchModels(settings: settings, apiKey: "sk-unit-test-secret")
                XCTFail("Remote cleartext provider endpoint must be rejected.")
            } catch let error as ChatError {
                guard case .invalidEndpoint = error else {
                    return XCTFail("Expected invalidEndpoint, got \(error)")
                }
            }
        }

        let remoteOllama = AppSettings(
            provider: .ollama,
            backend: .ollama,
            endpoint: "http://remote.example.test",
            selectedModel: "model"
        )
        do {
            _ = try await client.fetchModels(
                settings: remoteOllama,
                apiKey: "credential-must-not-cross-cleartext"
            )
            XCTFail("A credentialed remote Ollama endpoint must require TLS.")
        } catch let error as ChatError {
            guard case .invalidEndpoint = error else {
                return XCTFail("Expected invalidEndpoint, got \(error)")
            }
        }
        XCTAssertTrue(ModelParameterURLProtocol.requestedPaths.isEmpty)
    }

    func testClassicChatRejectsCredentialedOrAmbiguousEndpointURLs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)

        for endpoint in [
            "https://user:password@example.test/v1",
            "https://example.test/v1?tenant=other",
            "https://example.test/v1#fragment"
        ] {
            let settings = AppSettings(
                provider: .openAICompatible,
                backend: .openAICompatible,
                endpoint: endpoint,
                selectedModel: "model"
            )
            do {
                _ = try await client.fetchModels(settings: settings, apiKey: "safe")
                XCTFail("Ambiguous or URL-credential endpoint must be rejected: \(endpoint)")
            } catch let error as ChatError {
                guard case .invalidEndpoint = error else {
                    return XCTFail("Expected invalidEndpoint, got \(error)")
                }
            }
        }
        XCTAssertTrue(ModelParameterURLProtocol.requestedPaths.isEmpty)
    }

    func testClassicChatRedactsSecretsEchoedByHTTPErrorBody() async throws {
        ModelParameterURLProtocol.statusCode = 401
        ModelParameterURLProtocol.responder = { _ in
            (
                "application/json",
                Data(#"{"error":"Authorization: Bearer sk-super-secret-token"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://localhost:1234/v1",
            selectedModel: "model"
        )

        do {
            for try await _ in client.stream(
                messages: [ChatMessage(role: .user, content: "hello")],
                settings: settings,
                apiKey: "safe-local-key",
                attachmentLoader: { _ in nil }
            ) {}
            XCTFail("HTTP 401 must fail the stream.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sk-super-secret-token"))
            XCTAssertTrue(error.localizedDescription.contains("[REDACTED]"))
        }
    }

    func testClassicChatPreciselyRedactsArbitraryAPIKeyFromStreamingErrors() async throws {
        let opaqueKey = "ordinary-local-credential-42"
        ModelParameterURLProtocol.responder = { _ in
            (
                "text/event-stream",
                Data("data: {\"error\":\"backend echoed \(opaqueKey)\"}\n\n".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://localhost:1234/v1",
            selectedModel: "model"
        )

        do {
            for try await _ in client.stream(
                messages: [ChatMessage(role: .user, content: "hello")],
                settings: settings,
                apiKey: opaqueKey,
                attachmentLoader: { _ in nil }
            ) {}
            XCTFail("A streaming provider error must fail the request.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(opaqueKey))
            XCTAssertTrue(error.localizedDescription.contains("[REDACTED]"))
        }
    }

    func testClassicChatBoundsMetadataAndSSEEventResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://localhost:1234/v1",
            selectedModel: "model"
        )

        ModelParameterURLProtocol.responder = { _ in
            ("application/json", Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1))
        }
        do {
            _ = try await client.fetchModels(settings: settings, apiKey: nil)
            XCTFail("Oversized model metadata must be rejected before decode.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("安全上限"))
        }

        ModelParameterURLProtocol.responder = { _ in
            let prefix = Data("data: ".utf8)
            let payload = Data(repeating: 0x61, count: 4 * 1_024 * 1_024 + 1)
            return ("text/event-stream", prefix + payload + Data("\n\n".utf8))
        }
        do {
            for try await _ in client.stream(
                messages: [ChatMessage(role: .user, content: "hello")],
                settings: settings,
                apiKey: nil,
                attachmentLoader: { _ in nil }
            ) {}
            XCTFail("Oversized SSE events must be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("安全上限"))
        }
    }

    func testClassicChatRejectsMismatchedResponseOriginWithInjectedSession() async throws {
        ModelParameterURLProtocol.responseURL = URL(string: "https://redirected.example.test/v1/models")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "https://source.example.test/v1",
            selectedModel: "model"
        )

        do {
            _ = try await client.fetchModels(settings: settings, apiKey: "unit-test-key")
            XCTFail("A response from another origin must be rejected.")
        } catch let error as ChatError {
            guard case .malformedResponse = error else {
                return XCTFail("Expected malformedResponse, got \(error)")
            }
        }
    }

    func testLegacySettingsWithoutProfilesOrBackendStillDecode() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"""
        {"provider":"ollama","endpoint":"http://localhost:11434","selectedModel":"old"}
        """#.utf8))

        XCTAssertTrue(settings.modelParameterProfiles.isEmpty)
        XCTAssertEqual(settings.resolvedBackend, .ollama)
    }

    private func route(
        backend: ModelBackendKind,
        model: String,
        useCase: ModelParameterUseCase = .chat
    ) -> ModelParameterRoute {
        ModelParameterRoute(
            provider: backend.provider,
            backend: backend,
            endpoint: "http://\(backend.rawValue).unit.test/v1",
            modelID: model,
            useCase: useCase
        )
    }
}
