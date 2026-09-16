import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ollama
    case openAICompatible
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI 相容"
        case .anthropic: "Anthropic"
        }
    }

    var subtitle: String {
        switch self {
        case .ollama: "Ollama 原生 API"
        case .openAICompatible: "OpenAI、LM Studio、llama.cpp、vLLM 等"
        case .anthropic: "Claude Messages API"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:1234/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        }
    }

    var requiresAPIKey: Bool { self == .anthropic }
}

struct ServerPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: ProviderKind
    let backend: ModelBackendKind
    let endpoint: String

    static let builtIns: [ServerPreset] = [
        .init(id: "ollama-local", name: "Ollama", provider: .ollama, backend: .ollama, endpoint: "http://localhost:11434"),
        .init(id: "mlx-lm", name: "MLX-LM", provider: .openAICompatible, backend: .mlx, endpoint: "http://localhost:8080/v1"),
        .init(id: "lm-studio", name: "LM Studio", provider: .openAICompatible, backend: .lmStudio, endpoint: "http://localhost:1234/v1"),
        .init(id: "llama-cpp", name: "llama.cpp", provider: .openAICompatible, backend: .openAICompatible, endpoint: "http://localhost:8080/v1"),
        .init(id: "vllm", name: "vLLM", provider: .openAICompatible, backend: .openAICompatible, endpoint: "http://localhost:8000/v1"),
        .init(id: "local-ai", name: "LocalAI", provider: .openAICompatible, backend: .openAICompatible, endpoint: "http://localhost:8080/v1"),
        .init(id: "openai", name: "OpenAI", provider: .openAICompatible, backend: .openAI, endpoint: "https://api.openai.com/v1"),
        .init(id: "openrouter", name: "OpenRouter", provider: .openAICompatible, backend: .openAICompatible, endpoint: "https://openrouter.ai/api/v1"),
        .init(id: "anthropic", name: "Anthropic", provider: .anthropic, backend: .anthropic, endpoint: "https://api.anthropic.com/v1")
    ]
}

struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: ProviderKind
    var backend: ModelBackendKind?
    var endpoint: String
    var selectedModel: String

    init(
        id: UUID = UUID(),
        name: String,
        provider: ProviderKind,
        backend: ModelBackendKind? = nil,
        endpoint: String,
        selectedModel: String
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.backend = backend
        self.endpoint = endpoint
        self.selectedModel = selectedModel
    }

    var resolvedBackend: ModelBackendKind {
        if let backend, backend.provider == provider { return backend }
        return ModelBackendKind.inferred(provider: provider, endpoint: endpoint)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.title : trimmed
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var provider: ProviderKind = .ollama
    var backend: ModelBackendKind?
    var endpoint = "http://localhost:11434"
    var selectedModel = ""
    var contextLength = 8_192
    var temperature = 0.7
    var systemPrompt = "你是一位準確、友善且重視隱私的 AI 助理。"
    var requestTimeout = 300.0
    var connectionProfiles: [ConnectionProfile] = []
    var activeProfileID: UUID?
    var modelParameterProfiles: [ModelParameterProfile] = []

    var resolvedBackend: ModelBackendKind {
        if let backend, backend.provider == provider { return backend }
        return ModelBackendKind.inferred(provider: provider, endpoint: endpoint)
    }

    static let contextOptions = [2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072]

    init(
        provider: ProviderKind = .ollama,
        backend: ModelBackendKind? = nil,
        endpoint: String = "http://localhost:11434",
        selectedModel: String = "",
        contextLength: Int = 8_192,
        temperature: Double = 0.7,
        systemPrompt: String = "你是一位準確、友善且重視隱私的 AI 助理。",
        requestTimeout: Double = 300.0,
        connectionProfiles: [ConnectionProfile] = [],
        activeProfileID: UUID? = nil,
        modelParameterProfiles: [ModelParameterProfile] = []
    ) {
        self.provider = provider
        self.backend = backend
        self.endpoint = endpoint
        self.selectedModel = selectedModel
        self.contextLength = contextLength
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.requestTimeout = requestTimeout
        self.connectionProfiles = connectionProfiles
        self.activeProfileID = activeProfileID
        self.modelParameterProfiles = ModelParameterRecommendationEngine.deduplicated(
            modelParameterProfiles
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider, backend, endpoint, selectedModel, contextLength, temperature
        case systemPrompt, requestTimeout, connectionProfiles, activeProfileID
        case modelParameterProfiles
    }

    /// Every key is decoded with a fallback so settings written by older LumaChat
    /// versions remain usable as new preferences are added.
    init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? defaults.provider
        backend = try? container.decodeIfPresent(ModelBackendKind.self, forKey: .backend)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? defaults.endpoint
        selectedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? defaults.selectedModel
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? defaults.contextLength
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? defaults.systemPrompt
        requestTimeout = try container.decodeIfPresent(Double.self, forKey: .requestTimeout) ?? defaults.requestTimeout
        connectionProfiles = (try? container.decodeIfPresent(
            [ConnectionProfile].self,
            forKey: .connectionProfiles
        )) ?? []
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        let decodedProfiles = (try? container.decodeIfPresent(
            [ModelParameterProfile].self,
            forKey: .modelParameterProfiles
        )) ?? []
        modelParameterProfiles = ModelParameterRecommendationEngine.deduplicated(decodedProfiles)
    }
}

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum AttachmentKind: String, Codable, Sendable {
    case image
    case text
    case pdf
    case file
    case capturedContext
}

struct ChatAttachment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var relativePath: String?
    var mimeType: String
    var kind: AttachmentKind
    var byteCount: Int64
    var extractedText: String?
    var sourceLabel: String?
}

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: MessageRole
    var content: String
    var reasoning: String?
    var attachments: [ChatAttachment] = []
    var createdAt: Date = Date()
    var isError = false
}

enum LLMStreamDelta: Sendable, Equatable {
    case content(String)
    case reasoning(String)
}

struct ProjectReference: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var bookmarkData: Data?
    var lastIndexedAt: Date?
}

struct Conversation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title = "新對話"
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    var model = ""
    var provider: ProviderKind = .ollama
    var profileID: UUID?
    var project: ProjectReference?
    /// Nil only for conversations created by an older app version. Treating it
    /// as unbound prevents local context from silently moving to a new server.
    var endpoint: String?
}

struct PreparedAttachment: Sendable {
    var attachment: ChatAttachment
    var data: Data?
}

enum ChatError: LocalizedError, Sendable {
    case invalidEndpoint
    case noModel
    case server(String)
    case malformedResponse
    case fileTooLarge(String)
    case unsupportedFile(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "伺服器網址格式不正確。"
        case .noModel: "請先選擇或輸入模型名稱。"
        case .server(let message): message
        case .malformedResponse: "伺服器回傳了無法解析的內容。"
        case .fileTooLarge(let name): "\(name) 太大，請選擇較小的檔案。"
        case .unsupportedFile(let name): "\(name) 不是可讀取的一般檔案，或檔案內容已損壞。"
        case .permissionDenied(let message): message
        }
    }
}
