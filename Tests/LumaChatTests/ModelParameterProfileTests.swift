import Foundation
import XCTest
@testable import LumaChat

private final class ModelParameterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequestBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestBody = request.httpBody ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ModelParameterProfileTests: XCTestCase {
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

    func testUnsupportedOpenAICompatibleFieldsAreOmittedFromChatRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelParameterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let settings = AppSettings(
            provider: .openAICompatible,
            backend: .openAICompatible,
            endpoint: "http://unit.test/v1",
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
