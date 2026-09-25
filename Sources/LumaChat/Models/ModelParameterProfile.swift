import Foundation

/// The concrete inference server behind a provider protocol.  ProviderKind
/// describes the wire format; this value lets recommendation and capability
/// rules distinguish implementations that share the OpenAI-compatible API.
enum ModelBackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama
    case mlx
    case lmStudio
    case openAI
    case openAICompatible
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .mlx: "MLX-LM"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .openAICompatible: "OpenAI 相容"
        case .anthropic: "Anthropic"
        }
    }

    var provider: ProviderKind {
        switch self {
        case .ollama: .ollama
        case .mlx, .lmStudio, .openAI, .openAICompatible: .openAICompatible
        case .anthropic: .anthropic
        }
    }

    static func choices(for provider: ProviderKind) -> [Self] {
        allCases.filter { $0.provider == provider }
    }

    static func inferred(provider: ProviderKind, endpoint: String) -> Self {
        switch provider {
        case .ollama:
            return .ollama
        case .anthropic:
            return .anthropic
        case .openAICompatible:
            let normalized = endpoint.lowercased()
            if normalized.contains("api.openai.com") { return .openAI }
            if normalized.contains("lmstudio") || normalized.contains(":1234") {
                return .lmStudio
            }
            if normalized.contains("mlx") { return .mlx }
            return .openAICompatible
        }
    }
}

enum ModelParameterUseCase: String, Codable, Sendable {
    case chat
    case agent
}

enum ModelParameterMode: String, Codable, Sendable {
    case auto
    case custom
}

enum ModelReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .xhigh: "XHigh"
        }
    }
}

/// A profile identity deliberately includes both the provider protocol and the
/// concrete backend.  The normalized endpoint is an additional namespace so
/// two separately hosted servers exposing the same model ID cannot overwrite
/// one another.
struct ModelParameterKey: Codable, Hashable, Sendable {
    var provider: ProviderKind
    var backend: ModelBackendKind
    var endpointIdentity: String
    var modelID: String

    init(
        provider: ProviderKind,
        backend: ModelBackendKind,
        endpoint: String,
        modelID: String
    ) {
        self.provider = provider
        self.backend = backend.provider == provider
            ? backend
            : ModelBackendKind.inferred(provider: provider, endpoint: endpoint)
        endpointIdentity = Self.normalizedEndpointIdentity(endpoint)
        self.modelID = Self.normalizedModelID(modelID)
    }

    var storageKey: String {
        [provider.rawValue, backend.rawValue, endpointIdentity, modelID]
            .joined(separator: "|")
    }

    private static func normalizedEndpointIdentity(_ endpoint: String) -> String {
        let normalized = EndpointNormalizer.normalized(endpoint)
            ?? endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        // EndpointNormalizer already canonicalizes the case-insensitive URL
        // components (scheme and host). Keep the path's original case: URL
        // paths may be case-sensitive and can identify different API tenants.
        return normalized
    }

    private static func normalizedModelID(_ modelID: String) -> String {
        // A provider is allowed to expose case-sensitive model identifiers.
        // Trimming accidental surrounding whitespace is safe; lowercasing here
        // would merge two otherwise distinct backend/provider + model routes.
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ModelParameterRoute: Equatable, Sendable {
    var provider: ProviderKind
    var backend: ModelBackendKind
    var endpoint: String
    var modelID: String
    var useCase: ModelParameterUseCase

    init(
        provider: ProviderKind,
        backend: ModelBackendKind,
        endpoint: String,
        modelID: String,
        useCase: ModelParameterUseCase
    ) {
        self.provider = provider
        self.backend = backend.provider == provider
            ? backend
            : ModelBackendKind.inferred(provider: provider, endpoint: endpoint)
        self.endpoint = endpoint
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.useCase = useCase
    }

    init(
        settings: AppSettings,
        useCase: ModelParameterUseCase,
        modelID: String? = nil
    ) {
        self.init(
            provider: settings.provider,
            backend: settings.resolvedBackend,
            endpoint: settings.endpoint,
            modelID: modelID ?? settings.selectedModel,
            useCase: useCase
        )
    }

    var key: ModelParameterKey {
        ModelParameterKey(
            provider: provider,
            backend: backend,
            endpoint: endpoint,
            modelID: modelID
        )
    }
}

struct ModelParameterValues: Codable, Equatable, Sendable {
    var contextWindowTokens: Int
    var maxOutputTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repetitionPenalty: Double
    var presencePenalty: Double
    var thinkingEnabled: Bool
    var reasoningEffort: ModelReasoningEffort
    var preserveThinking: Bool
}

/// Only Custom profiles are persisted.  The absence of a matching record is
/// the durable representation of Auto and causes the latest recommendation
/// rules to be evaluated whenever the model is used.
struct ModelParameterProfile: Codable, Equatable, Identifiable, Sendable {
    var key: ModelParameterKey
    var values: ModelParameterValues
    var updatedAt: Date

    var id: String { key.storageKey }

    init(key: ModelParameterKey, values: ModelParameterValues, updatedAt: Date = Date()) {
        self.key = key
        self.values = values
        self.updatedAt = updatedAt
    }
}

struct ModelParameterCapabilities: Equatable, Sendable {
    var backendMaximumContextTokens: Int
    var modelMaximumContextTokens: Int
    var maximumOutputTokens: Int
    var supportsTemperature: Bool
    var supportsTopP: Bool
    var supportsTopK: Bool
    var supportsMinP: Bool
    var supportsRepetitionPenalty: Bool
    var supportsPresencePenalty: Bool
    var supportsThinking: Bool
    var supportedReasoningEfforts: [ModelReasoningEffort]
    var supportsPreserveThinking: Bool

    var maximumContextTokens: Int {
        min(backendMaximumContextTokens, modelMaximumContextTokens)
    }

    var supportsReasoningEffort: Bool { !supportedReasoningEfforts.isEmpty }
}

/// Backend-reported limits and feature flags for one concrete model. These
/// values are intentionally ephemeral: Custom values remain durable, while
/// capabilities are rediscovered from the currently selected backend and can
/// tighten both Auto and Custom profiles at every request boundary.
struct DiscoveredModelParameterCapabilities: Equatable, Sendable {
    var modelMaximumContextTokens: Int?
    var maximumOutputTokens: Int?
    var supportsThinking: Bool?

    init(
        modelMaximumContextTokens: Int? = nil,
        maximumOutputTokens: Int? = nil,
        supportsThinking: Bool? = nil
    ) {
        self.modelMaximumContextTokens = modelMaximumContextTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.supportsThinking = supportsThinking
    }
}

struct EffectiveModelParameterProfile: Equatable, Sendable {
    var key: ModelParameterKey
    var mode: ModelParameterMode
    var values: ModelParameterValues
    var capabilities: ModelParameterCapabilities
    var recommendationRule: String

    var effectiveContextTokens: Int { values.contextWindowTokens }
}

enum ModelParameterField: Sendable {
    case contextWindowTokens
    case maxOutputTokens
    case temperature
    case topP
    case topK
    case minP
    case repetitionPenalty
    case presencePenalty
    case thinkingEnabled
    case reasoningEffort
    case preserveThinking
}

enum ModelParameterValidation {
    static let absoluteMaximumContextTokens = 2_000_000
    static let absoluteMaximumOutputTokens = 262_144

    static func normalized(
        _ input: ModelParameterValues,
        capabilities: ModelParameterCapabilities
    ) -> ModelParameterValues {
        var value = input
        let contextMaximum = min(
            absoluteMaximumContextTokens,
            max(1, capabilities.maximumContextTokens)
        )
        value.contextWindowTokens = min(contextMaximum, max(1, value.contextWindowTokens))
        let outputMaximum = min(
            min(
                absoluteMaximumOutputTokens,
                max(1, capabilities.maximumOutputTokens)
            ),
            value.contextWindowTokens
        )
        value.maxOutputTokens = min(outputMaximum, max(1, value.maxOutputTokens))
        value.temperature = finiteClamped(value.temperature, fallback: 0.7, range: 0...2)
        value.topP = finiteClamped(value.topP, fallback: 1, range: 0...1)
        value.topK = min(100_000, max(0, value.topK))
        value.minP = finiteClamped(value.minP, fallback: 0, range: 0...1)
        value.repetitionPenalty = finiteClamped(
            value.repetitionPenalty,
            fallback: 1,
            range: 0...2
        )
        value.presencePenalty = finiteClamped(
            value.presencePenalty,
            fallback: 0,
            range: -2...2
        )
        if !capabilities.supportsThinking { value.thinkingEnabled = false }
        if !capabilities.supportedReasoningEfforts.contains(value.reasoningEffort) {
            value.reasoningEffort = capabilities.supportedReasoningEfforts.contains(.medium)
                ? .medium
                : (capabilities.supportedReasoningEfforts.first ?? .medium)
        }
        if !capabilities.supportsPreserveThinking { value.preserveThinking = false }
        return value
    }

    static func isRequestSafe(
        _ value: ModelParameterValues,
        capabilities: ModelParameterCapabilities
    ) -> Bool {
        normalized(value, capabilities: capabilities) == value
    }

    private static func finiteClamped(
        _ value: Double,
        fallback: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Central recommendation pipeline.  Resolution is intentionally kept out of
/// SwiftUI and request adapters: exact model -> family -> backend -> generic.
enum ModelParameterRecommendationEngine {
    static func effectiveProfile(
        for route: ModelParameterRoute,
        profiles: [ModelParameterProfile],
        discoveredCapabilities: DiscoveredModelParameterCapabilities? = nil
    ) -> EffectiveModelParameterProfile {
        var capabilities = capabilities(for: route)
        if let discoveredContextMaximum = discoveredCapabilities?.modelMaximumContextTokens,
           (1...ModelParameterValidation.absoluteMaximumContextTokens)
            .contains(discoveredContextMaximum) {
            capabilities.modelMaximumContextTokens = min(
                capabilities.modelMaximumContextTokens,
                discoveredContextMaximum
            )
        }
        if let discoveredOutputMaximum = discoveredCapabilities?.maximumOutputTokens,
           (1...ModelParameterValidation.absoluteMaximumOutputTokens)
            .contains(discoveredOutputMaximum) {
            capabilities.maximumOutputTokens = min(
                capabilities.maximumOutputTokens,
                discoveredOutputMaximum
            )
        }
        if let supportsThinking = discoveredCapabilities?.supportsThinking {
            capabilities.supportsThinking = supportsThinking
        }

        let key = route.key
        if let custom = profiles.last(where: { $0.key == key }) {
            return EffectiveModelParameterProfile(
                key: key,
                mode: .custom,
                values: ModelParameterValidation.normalized(
                    custom.values,
                    capabilities: capabilities
                ),
                capabilities: capabilities,
                recommendationRule: "custom"
            )
        }

        let recommendation = recommendation(for: route, capabilities: capabilities)
        return EffectiveModelParameterProfile(
            key: key,
            mode: .auto,
            values: ModelParameterValidation.normalized(
                recommendation.values,
                capabilities: capabilities
            ),
            capabilities: capabilities,
            recommendationRule: recommendation.rule
        )
    }

    static func replacingCustomProfile(
        in profiles: [ModelParameterProfile],
        route: ModelParameterRoute,
        values: ModelParameterValues,
        now: Date = Date()
    ) -> [ModelParameterProfile] {
        let capabilities = capabilities(for: route)
        let profile = ModelParameterProfile(
            key: route.key,
            values: ModelParameterValidation.normalized(values, capabilities: capabilities),
            updatedAt: now
        )
        var result = profiles.filter { $0.key != route.key }
        result.append(profile)
        return deduplicated(result)
    }

    static func resettingToAuto(
        in profiles: [ModelParameterProfile],
        route: ModelParameterRoute
    ) -> [ModelParameterProfile] {
        profiles.filter { $0.key != route.key }
    }

    static func deduplicated(_ profiles: [ModelParameterProfile]) -> [ModelParameterProfile] {
        var latest: [ModelParameterKey: ModelParameterProfile] = [:]
        for profile in profiles {
            guard !profile.key.modelID.isEmpty else { continue }
            if let existing = latest[profile.key], existing.updatedAt > profile.updatedAt {
                continue
            }
            latest[profile.key] = profile
        }
        return latest.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
    }

    static func capabilities(for route: ModelParameterRoute) -> ModelParameterCapabilities {
        let family = ModelFamily(modelID: route.modelID)
        let backendMaximum: Int
        let backendOutputMaximum: Int
        switch route.backend {
        case .ollama:
            backendMaximum = 262_144
            backendOutputMaximum = 65_536
        case .mlx, .lmStudio, .openAICompatible:
            backendMaximum = 262_144
            backendOutputMaximum = 65_536
        case .openAI:
            backendMaximum = 1_000_000
            backendOutputMaximum = 128_000
        case .anthropic:
            backendMaximum = 1_000_000
            backendOutputMaximum = 128_000
        }

        let modelMaximum: Int
        let modelOutputMaximum: Int
        switch family {
        case .qwen3:
            modelMaximum = 131_072
            modelOutputMaximum = 32_768
        case .openAIReasoning:
            modelMaximum = 400_000
            modelOutputMaximum = 100_000
        case .claude:
            modelMaximum = 200_000
            modelOutputMaximum = 64_000
        case .gemini:
            modelMaximum = 1_000_000
            modelOutputMaximum = 65_536
        case .llama, .deepSeek, .mistral:
            modelMaximum = 131_072
            modelOutputMaximum = 32_768
        case .generic:
            modelMaximum = 131_072
            modelOutputMaximum = 16_384
        }

        let isReasoningFamily = family == .qwen3
            || family == .openAIReasoning
            || family == .deepSeek
        let supportsThinking: Bool
        let reasoningEfforts: [ModelReasoningEffort]
        switch route.backend {
        case .ollama:
            supportsThinking = isReasoningFamily
            // Ollama's portable contract exposes a boolean thinking switch;
            // model-specific effort strings are not sent automatically.
            reasoningEfforts = []
        case .mlx:
            supportsThinking = family == .qwen3 || family == .deepSeek
            reasoningEfforts = []
        case .lmStudio:
            supportsThinking = family == .qwen3 || family == .deepSeek
            reasoningEfforts = isReasoningFamily ? [.low, .medium, .xhigh] : []
        case .openAI:
            supportsThinking = false
            reasoningEfforts = family == .openAIReasoning ? [.low, .medium, .xhigh] : []
        case .openAICompatible:
            supportsThinking = false
            reasoningEfforts = []
        case .anthropic:
            // Anthropic thinking uses a separate budget-bearing contract.  It
            // stays disabled until that exact contract is selected explicitly.
            supportsThinking = false
            reasoningEfforts = []
        }

        let supportsSamplerExtensions = route.backend == .ollama || route.backend == .mlx
        let supportsStandardOpenAISampling = route.provider == .openAICompatible
        // OpenAI reasoning-family Chat Completions endpoints reject sampling
        // controls such as temperature/top_p. Fail closed so both Classic Chat
        // and Agent omit them instead of relying on a provider error.
        let supportsSamplingControls = !(
            route.backend == .openAI && family == .openAIReasoning
        )
        return ModelParameterCapabilities(
            backendMaximumContextTokens: backendMaximum,
            modelMaximumContextTokens: modelMaximum,
            maximumOutputTokens: min(backendOutputMaximum, modelOutputMaximum),
            supportsTemperature: supportsSamplingControls,
            supportsTopP: supportsSamplingControls,
            supportsTopK: route.backend == .anthropic || supportsSamplerExtensions,
            supportsMinP: supportsSamplerExtensions,
            supportsRepetitionPenalty: supportsSamplerExtensions,
            supportsPresencePenalty: supportsStandardOpenAISampling
                && supportsSamplingControls,
            supportsThinking: supportsThinking,
            supportedReasoningEfforts: reasoningEfforts,
            // None of the currently supported portable request contracts can
            // safely replay raw hidden thinking across every turn.
            supportsPreserveThinking: false
        )
    }

    private static func recommendation(
        for route: ModelParameterRoute,
        capabilities: ModelParameterCapabilities
    ) -> (values: ModelParameterValues, rule: String) {
        let normalized = route.modelID.lowercased()
        let family = ModelFamily(modelID: route.modelID)

        // Exact rule: Qwen 3 8B variants (qwen3:8b, qwen3-8b, qwen3.8b).
        if family == .qwen3,
           normalized.contains("8b") || normalized.contains("3.8") {
            return (
                ModelParameterValues(
                    contextWindowTokens: 65_536,
                    maxOutputTokens: 16_384,
                    temperature: 1,
                    topP: 0.95,
                    topK: 20,
                    minP: 0,
                    repetitionPenalty: 1,
                    presencePenalty: 0,
                    thinkingEnabled: true,
                    reasoningEffort: .medium,
                    preserveThinking: route.useCase == .chat
                ),
                "exact:qwen3-8b"
            )
        }

        // Family rules.
        switch family {
        case .qwen3:
            return (
                ModelParameterValues(
                    contextWindowTokens: min(65_536, capabilities.maximumContextTokens),
                    maxOutputTokens: min(16_384, capabilities.maximumOutputTokens),
                    temperature: 1,
                    topP: 0.95,
                    topK: 20,
                    minP: 0,
                    repetitionPenalty: 1,
                    presencePenalty: 0,
                    thinkingEnabled: true,
                    reasoningEffort: .medium,
                    preserveThinking: route.useCase == .chat
                ),
                "family:qwen3"
            )
        case .openAIReasoning:
            return (
                baseValues(
                    context: 128_000,
                    output: 32_768,
                    temperature: 1,
                    thinking: false,
                    effort: .medium
                ),
                "family:openai-reasoning"
            )
        case .deepSeek:
            return (
                baseValues(
                    context: 65_536,
                    output: 16_384,
                    temperature: 0.6,
                    thinking: true,
                    effort: .medium
                ),
                "family:deepseek"
            )
        case .claude:
            return (
                baseValues(context: 128_000, output: 16_384, temperature: 0.7),
                "family:claude"
            )
        case .gemini:
            return (
                baseValues(context: 128_000, output: 16_384, temperature: 0.7),
                "family:gemini"
            )
        case .llama, .mistral:
            return (
                baseValues(context: 32_768, output: 8_192, temperature: 0.7),
                "family:\(family.rawValue)"
            )
        case .generic:
            break
        }

        // Backend rules.
        switch route.backend {
        case .ollama, .mlx, .lmStudio:
            return (
                baseValues(context: 32_768, output: 8_192, temperature: 0.7),
                "backend:\(route.backend.rawValue)"
            )
        case .openAI, .openAICompatible, .anthropic:
            return (
                baseValues(context: 32_768, output: 4_096, temperature: 0.7),
                "backend:\(route.backend.rawValue)"
            )
        }
    }

    private static func baseValues(
        context: Int,
        output: Int,
        temperature: Double,
        thinking: Bool = false,
        effort: ModelReasoningEffort = .medium
    ) -> ModelParameterValues {
        ModelParameterValues(
            contextWindowTokens: context,
            maxOutputTokens: output,
            temperature: temperature,
            topP: 1,
            topK: 40,
            minP: 0,
            repetitionPenalty: 1,
            presencePenalty: 0,
            thinkingEnabled: thinking,
            reasoningEffort: effort,
            preserveThinking: false
        )
    }
}

private enum ModelFamily: String {
    case qwen3
    case openAIReasoning
    case claude
    case gemini
    case llama
    case deepSeek
    case mistral
    case generic

    init(modelID: String) {
        let value = modelID.lowercased()
        if value.contains("qwen3") || value.contains("qwen-3") {
            self = .qwen3
        } else if value.hasPrefix("o1")
                    || value.hasPrefix("o3")
                    || value.hasPrefix("o4")
                    || value.contains("gpt-5")
                    || value.contains("gpt-6") {
            self = .openAIReasoning
        } else if value.contains("claude") {
            self = .claude
        } else if value.contains("gemini") {
            self = .gemini
        } else if value.contains("llama") {
            self = .llama
        } else if value.contains("deepseek") {
            self = .deepSeek
        } else if value.contains("mistral") || value.contains("mixtral") {
            self = .mistral
        } else {
            self = .generic
        }
    }
}
