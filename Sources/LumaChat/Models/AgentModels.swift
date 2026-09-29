import CryptoKit
import Foundation

// MARK: - JSON

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded(.towardZero) == value else { return nil }
        return Int(exactly: value)
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }

    static let emptyObject: JSONValue = .object([:])

    static func objectSchema(
        properties: [String: JSONValue],
        required: [String] = [],
        additionalProperties: Bool = false
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(additionalProperties)
        ])
    }

    static func stringSchema(description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func integerSchema(description: String? = nil, minimum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let description { schema["description"] = .string(description) }
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        return .object(schema)
    }

    static func booleanSchema(description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("boolean")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }
}

// MARK: - Modes and preferences

enum AppMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case plan
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .plan: "Plan"
        case .agent: "Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .plan: "list.bullet.clipboard"
        case .agent: "terminal"
        }
    }

    var usesAgentRuntime: Bool { self != .chat }
    var permitsWorkspaceMutation: Bool { self == .agent }
}

enum AgentPermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case askEveryTime
    case autoApproveSafe
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime: "每次詢問"
        case .autoApproveSafe: "自動允許安全工具"
        case .fullAccess: "完整存取"
        }
    }
}

enum AgentVisionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case disabled
    case enabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自動"
        case .disabled: "停用"
        case .enabled: "啟用"
        }
    }

    /// Nil keeps provider/model metadata authoritative. A non-nil value is an
    /// explicit Agent-only override and never changes Classic Chat routing.
    var capabilityOverride: Bool? {
        switch self {
        case .automatic: nil
        case .disabled: false
        case .enabled: true
        }
    }
}

enum AgentComputerUseSettingsLimits {
    static let maximumAllowedApplications = 32
    static let maximumBundleIdentifierBytes = 255

    /// Treat the allow-list as untrusted persisted input. Oversized values and
    /// values containing controls are rejected rather than truncated, because a
    /// truncated bundle identifier could name a different application.
    static func normalizedBundleIdentifiers(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(min(values.count, maximumAllowedApplications))

        for value in values {
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.utf8.count <= maximumBundleIdentifierBytes,
                  !candidate.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  seen.insert(candidate).inserted else { continue }
            normalized.append(candidate)
            if normalized.count == maximumAllowedApplications { break }
        }
        return normalized
    }
}

enum AgentBrowserProfileMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A fresh Chromium user-data directory under this source checkout's
    /// `tmp` directory. It is the default and carries no login state between
    /// tasks.
    case isolatedTemporary
    /// A user-selected LumaChat-managed profile. Selecting this mode is the
    /// explicit opt-in required before browser credentials may persist.
    case persistent
    /// A separately launched Chromium debugging endpoint. This can expose the
    /// user's existing authenticated session and is therefore never inferred.
    case attachExisting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolatedTemporary: "隔離的暫存 Profile"
        case .persistent: "LumaChat 持久 Profile"
        case .attachExisting: "Attach Existing Browser"
        }
    }
}

enum AgentBrowserSettingsLimits {
    static let defaultPersistentProfileName = "default"
    static let defaultExistingDebugEndpoint = "http://127.0.0.1:9222"
    static let maximumProfileNameBytes = 64

    static func normalizedPersistentProfileName(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(candidate.unicodeScalars)
        guard !candidate.isEmpty,
              candidate != ".",
              candidate != "..",
              candidate.utf8.count <= maximumProfileNameBytes,
              let first = scalars.first,
              (48...57).contains(first.value)
                  || (65...90).contains(first.value)
                  || (97...122).contains(first.value),
              scalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95:
                      true
                  default:
                      false
                  }
              }) else { return nil }
        return candidate
    }

    /// Existing-browser attachment is deliberately loopback-only. Allowing a
    /// model or corrupt settings file to select a remote DevTools endpoint
    /// would turn the browser bridge into a credential-bearing SSRF surface.
    static func normalizedExistingDebugEndpoint(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.utf8.count <= 2_048,
              let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              components.port != nil else { return nil }
        return components.url?.absoluteString
    }
}

enum AgentFollowUpBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case steer
    case queue

    var id: String { rawValue }
    var title: String {
        switch self {
        case .steer: "Steer 目前執行"
        case .queue: "排隊到下一次執行"
        }
    }
}

struct AgentSettings: Codable, Equatable, Sendable {
    var defaultMode: AppMode = .chat
    var followUpBehavior: AgentFollowUpBehavior = .steer
    /// Local project memories are opt-in; old settings remain disabled.
    var memoriesEnabled = false
    var permissionMode: AgentPermissionMode = .autoApproveSafe
    var maxSteps = 100
    var commandTimeout = 120.0
    var autoRunTests = true
    var autoContextCompression = true
    var gitCheckpoint = true
    var networkAccess = false
    var visionMode: AgentVisionMode = .automatic
    var browserEnabled = false
    var browserProfileMode: AgentBrowserProfileMode = .isolatedTemporary
    var browserPersistentProfileName = AgentBrowserSettingsLimits.defaultPersistentProfileName
    var browserExistingDebugEndpoint = AgentBrowserSettingsLimits.defaultExistingDebugEndpoint
    var computerUseEnabled = false
    var computerUseAllowedBundleIdentifiers: [String] = []
    var preferredPlanModel = ""
    var preferredAgentModel = ""
    var maximumToolResultCharacters = 24_000
    var pullRequestProvider: PullRequestProviderConfiguration = .github

    private enum CodingKeys: String, CodingKey {
        case defaultMode, followUpBehavior, memoriesEnabled, permissionMode, maxSteps, commandTimeout, autoRunTests
        case autoContextCompression, gitCheckpoint, networkAccess, visionMode
        case browserEnabled, browserProfileMode, browserPersistentProfileName
        case browserExistingDebugEndpoint
        case computerUseEnabled, computerUseAllowedBundleIdentifiers
        case preferredPlanModel, preferredAgentModel, maximumToolResultCharacters
        case pullRequestProvider
    }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = AgentSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultMode = try container.decodeIfPresent(AppMode.self, forKey: .defaultMode) ?? defaults.defaultMode
        followUpBehavior = (try? container.decodeIfPresent(
            AgentFollowUpBehavior.self, forKey: .followUpBehavior
        )) ?? defaults.followUpBehavior
        memoriesEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoriesEnabled)
            ?? defaults.memoriesEnabled
        permissionMode = try container.decodeIfPresent(AgentPermissionMode.self, forKey: .permissionMode) ?? defaults.permissionMode
        maxSteps = max(1, try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? defaults.maxSteps)
        commandTimeout = max(1, try container.decodeIfPresent(Double.self, forKey: .commandTimeout) ?? defaults.commandTimeout)
        autoRunTests = try container.decodeIfPresent(Bool.self, forKey: .autoRunTests) ?? defaults.autoRunTests
        autoContextCompression = try container.decodeIfPresent(Bool.self, forKey: .autoContextCompression) ?? defaults.autoContextCompression
        gitCheckpoint = try container.decodeIfPresent(Bool.self, forKey: .gitCheckpoint) ?? defaults.gitCheckpoint
        networkAccess = try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? defaults.networkAccess
        visionMode = try container.decodeIfPresent(AgentVisionMode.self, forKey: .visionMode)
            ?? defaults.visionMode
        browserEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserEnabled)
            ?? defaults.browserEnabled
        let decodedBrowserMode = try container.decodeIfPresent(
            AgentBrowserProfileMode.self,
            forKey: .browserProfileMode
        ) ?? defaults.browserProfileMode
        let decodedPersistentProfileName = try container.decodeIfPresent(
            String.self,
            forKey: .browserPersistentProfileName
        ) ?? defaults.browserPersistentProfileName
        let decodedDebugEndpoint = try container.decodeIfPresent(
            String.self,
            forKey: .browserExistingDebugEndpoint
        ) ?? defaults.browserExistingDebugEndpoint
        browserPersistentProfileName = AgentBrowserSettingsLimits
            .normalizedPersistentProfileName(decodedPersistentProfileName)
            ?? defaults.browserPersistentProfileName
        browserExistingDebugEndpoint = AgentBrowserSettingsLimits
            .normalizedExistingDebugEndpoint(decodedDebugEndpoint)
            ?? defaults.browserExistingDebugEndpoint
        switch decodedBrowserMode {
        case .isolatedTemporary:
            browserProfileMode = .isolatedTemporary
        case .persistent:
            browserProfileMode = AgentBrowserSettingsLimits
                .normalizedPersistentProfileName(decodedPersistentProfileName) == nil
                ? .isolatedTemporary : .persistent
        case .attachExisting:
            browserProfileMode = AgentBrowserSettingsLimits
                .normalizedExistingDebugEndpoint(decodedDebugEndpoint) == nil
                ? .isolatedTemporary : .attachExisting
        }
        computerUseEnabled = try container.decodeIfPresent(Bool.self, forKey: .computerUseEnabled)
            ?? defaults.computerUseEnabled
        computerUseAllowedBundleIdentifiers = AgentComputerUseSettingsLimits
            .normalizedBundleIdentifiers(
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .computerUseAllowedBundleIdentifiers
                ) ?? defaults.computerUseAllowedBundleIdentifiers
            )
        preferredPlanModel = try container.decodeIfPresent(String.self, forKey: .preferredPlanModel) ?? defaults.preferredPlanModel
        preferredAgentModel = try container.decodeIfPresent(String.self, forKey: .preferredAgentModel) ?? defaults.preferredAgentModel
        maximumToolResultCharacters = max(
            1_024,
            try container.decodeIfPresent(Int.self, forKey: .maximumToolResultCharacters)
                ?? defaults.maximumToolResultCharacters
        )
        let decodedPullRequestProvider = try container.decodeIfPresent(
            PullRequestProviderConfiguration.self,
            forKey: .pullRequestProvider
        ) ?? defaults.pullRequestProvider
        // Corrupt legacy settings must not redirect credentials or network
        // calls. Fall back to the built-in GitHub origin when validation fails.
        pullRequestProvider = (try? decodedPullRequestProvider.normalized())
            ?? defaults.pullRequestProvider
    }
}

// MARK: - Provider protocol

struct ModelCapabilities: Codable, Equatable, Sendable {
    var supportsTools: Bool
    var supportsVision: Bool
    var supportsStreaming: Bool
    var supportsParallelTools: Bool
    var supportsReasoning: Bool
    var supportsSystemPrompt: Bool
    var contextWindow: Int?
    var maxOutputTokens: Int?

    static let unknown = ModelCapabilities(
        supportsTools: true,
        supportsVision: false,
        supportsStreaming: false,
        supportsParallelTools: false,
        supportsReasoning: false,
        supportsSystemPrompt: true,
        contextWindow: nil,
        maxOutputTokens: nil
    )
}

enum AgentMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct AgentToolCall: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var arguments: JSONValue

    init(id: String = UUID().uuidString, name: String, arguments: JSONValue = .emptyObject) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

enum AgentImageAttachmentLimits {
    static let maximumAttachmentsPerMessage = 4
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumTotalBytes = 20 * 1_024 * 1_024
    static let maximumDimension = 16_384
    static let maximumPixels = 40_000_000
    static let maximumNameBytes = 256
    static let maximumRelativePathBytes = 512
    static let maximumStoredAttachmentsPerSession = 64
    static let maximumStoredBytesPerSession = 256 * 1_024 * 1_024

    static let allowedMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/webp"
    ]

    static func validate(_ references: [AgentImageAttachmentReference]) throws {
        guard references.count <= maximumAttachmentsPerMessage else {
            throw AgentImageAttachmentError.tooManyAttachments(maximumAttachmentsPerMessage)
        }
        var total = 0
        var identifiers = Set<UUID>()
        for reference in references {
            guard identifiers.insert(reference.id).inserted else {
                throw AgentImageAttachmentError.duplicateAttachment(reference.id)
            }
            guard reference.byteCount <= maximumTotalBytes - min(total, maximumTotalBytes) else {
                throw AgentImageAttachmentError.totalSizeExceeded(maximumTotalBytes)
            }
            total += reference.byteCount
        }
    }

    static func validate(_ payloads: [AgentImagePayload]) throws {
        guard payloads.count <= maximumAttachmentsPerMessage else {
            throw AgentImageAttachmentError.tooManyAttachments(maximumAttachmentsPerMessage)
        }
        var total = 0
        var identifiers = Set<UUID>()
        for payload in payloads {
            guard identifiers.insert(payload.attachmentID).inserted else {
                throw AgentImageAttachmentError.duplicateAttachment(payload.attachmentID)
            }
            guard allowedMIMETypes.contains(payload.mimeType),
                  !payload.data.isEmpty,
                  payload.data.count <= maximumFileBytes else {
                throw AgentImageAttachmentError.fileTooLarge(maximumFileBytes)
            }
            guard payload.data.count <= maximumTotalBytes - min(total, maximumTotalBytes) else {
                throw AgentImageAttachmentError.totalSizeExceeded(maximumTotalBytes)
            }
            total += payload.data.count
        }
    }

    static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum AgentImageAttachmentError: LocalizedError, Equatable, Sendable {
    case invalidReference(String)
    case unsupportedType(String)
    case invalidImage(String)
    case fileTooLarge(Int)
    case tooManyAttachments(Int)
    case totalSizeExceeded(Int)
    case duplicateAttachment(UUID)
    case payloadMismatch(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidReference(let detail):
            "影像附件 reference 無效：\(detail)"
        case .unsupportedType(let type):
            "不支援的影像格式：\(type)"
        case .invalidImage(let detail):
            "影像內容無效：\(detail)"
        case .fileTooLarge(let maximum):
            "影像超過 \(maximum) bytes 安全上限。"
        case .tooManyAttachments(let maximum):
            "單一訊息最多可包含 \(maximum) 張影像。"
        case .totalSizeExceeded(let maximum):
            "單一訊息的影像總量超過 \(maximum) bytes 安全上限。"
        case .duplicateAttachment(let id):
            "訊息包含重複影像 reference：\(id.uuidString)"
        case .payloadMismatch(let id):
            "影像 payload 與 reference 不一致：\(id.uuidString)"
        }
    }
}

struct AgentImageAttachmentReference: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let relativePath: String
    let mimeType: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String

    init(
        id: UUID = UUID(),
        name: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        sha256: String
    ) throws {
        let normalizedMIME = mimeType.lowercased()
        guard AgentImageAttachmentLimits.allowedMIMETypes.contains(normalizedMIME) else {
            throw AgentImageAttachmentError.unsupportedType(mimeType)
        }
        guard byteCount > 0, byteCount <= AgentImageAttachmentLimits.maximumFileBytes else {
            throw AgentImageAttachmentError.fileTooLarge(AgentImageAttachmentLimits.maximumFileBytes)
        }
        guard pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= AgentImageAttachmentLimits.maximumDimension,
              pixelHeight <= AgentImageAttachmentLimits.maximumDimension,
              pixelWidth <= AgentImageAttachmentLimits.maximumPixels / pixelHeight else {
            throw AgentImageAttachmentError.invalidImage("影像尺寸超過安全上限")
        }
        guard !name.isEmpty,
              name.utf8.count <= AgentImageAttachmentLimits.maximumNameBytes,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentImageAttachmentError.invalidReference("檔名不安全")
        }
        guard relativePath.utf8.count <= AgentImageAttachmentLimits.maximumRelativePathBytes else {
            throw AgentImageAttachmentError.invalidReference("相對路徑過長")
        }
        let expectedExtension = normalizedMIME == "image/jpeg"
            ? "jpg"
            : String(normalizedMIME.dropFirst("image/".count))
        let expectedFileName = "\(id.uuidString.lowercased()).\(expectedExtension)"
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "Attachments",
              components[1] == Substring(expectedFileName) else {
            throw AgentImageAttachmentError.invalidReference("附件路徑不符合 session attachment 格式")
        }
        let normalizedDigest = sha256.lowercased()
        guard normalizedDigest.utf8.count == 64,
              normalizedDigest.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw AgentImageAttachmentError.invalidReference("SHA-256 格式無效")
        }

        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.mimeType = normalizedMIME
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sha256 = normalizedDigest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            relativePath: values.decode(String.self, forKey: .relativePath),
            mimeType: values.decode(String.self, forKey: .mimeType),
            byteCount: values.decode(Int.self, forKey: .byteCount),
            pixelWidth: values.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: values.decode(Int.self, forKey: .pixelHeight),
            sha256: values.decode(String.self, forKey: .sha256)
        )
    }
}

/// Bytes are intentionally request-scoped. Persisted messages contain only the
/// corresponding `AgentImageAttachmentReference`; providers never open paths.
struct AgentImagePayload: Codable, Equatable, Sendable {
    let attachmentID: UUID
    let mimeType: String
    let data: Data

    init(reference: AgentImageAttachmentReference, data: Data) throws {
        guard data.count == reference.byteCount,
              data.count <= AgentImageAttachmentLimits.maximumFileBytes,
              AgentImageAttachmentLimits.digestHex(data) == reference.sha256 else {
            throw AgentImageAttachmentError.payloadMismatch(reference.id)
        }
        attachmentID = reference.id
        mimeType = reference.mimeType
        self.data = data
    }

    func matches(_ reference: AgentImageAttachmentReference) -> Bool {
        attachmentID == reference.id
            && mimeType == reference.mimeType
            && data.count == reference.byteCount
            && data.count <= AgentImageAttachmentLimits.maximumFileBytes
            && AgentImageAttachmentLimits.digestHex(data) == reference.sha256
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID, mimeType, data
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let attachmentID = try values.decode(UUID.self, forKey: .attachmentID)
        let mimeType = try values.decode(String.self, forKey: .mimeType).lowercased()
        let data = try values.decode(Data.self, forKey: .data)
        guard AgentImageAttachmentLimits.allowedMIMETypes.contains(mimeType),
              !data.isEmpty,
              data.count <= AgentImageAttachmentLimits.maximumFileBytes else {
            throw AgentImageAttachmentError.invalidImage("request image payload 不符合安全上限")
        }
        self.attachmentID = attachmentID
        self.mimeType = mimeType
        self.data = data
    }
}

struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var role: AgentMessageRole
    var content: String
    var reasoningSummary: String?
    var toolCalls: [AgentToolCall]
    var toolCallID: String?
    var name: String?
    var isError: Bool
    var createdAt: Date
    var imageAttachments: [AgentImageAttachmentReference]
    /// Durable, machine-readable Review payload. `content` remains the provider
    /// projection, while this field preserves file/line/range/hunk identity for
    /// reload, audit, and future provider-native structured context.
    var reviewContext: ReviewAgentContext?

    init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        content: String = "",
        reasoningSummary: String? = nil,
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil,
        isError: Bool = false,
        createdAt: Date = Date(),
        reviewContext: ReviewAgentContext? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningSummary = reasoningSummary
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.isError = isError
        self.createdAt = createdAt
        imageAttachments = []
        self.reviewContext = reviewContext
    }

    init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        content: String = "",
        reasoningSummary: String? = nil,
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil,
        isError: Bool = false,
        createdAt: Date = Date(),
        imageAttachments: [AgentImageAttachmentReference],
        reviewContext: ReviewAgentContext? = nil
    ) throws {
        try AgentImageAttachmentLimits.validate(imageAttachments)
        self.id = id
        self.role = role
        self.content = content
        self.reasoningSummary = reasoningSummary
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.isError = isError
        self.createdAt = createdAt
        self.imageAttachments = imageAttachments
        self.reviewContext = reviewContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningSummary, toolCalls, toolCallID, name, isError, createdAt
        case imageAttachments, reviewContext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            role: values.decode(AgentMessageRole.self, forKey: .role),
            content: values.decodeIfPresent(String.self, forKey: .content) ?? "",
            reasoningSummary: values.decodeIfPresent(String.self, forKey: .reasoningSummary),
            toolCalls: values.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? [],
            toolCallID: values.decodeIfPresent(String.self, forKey: .toolCallID),
            name: values.decodeIfPresent(String.self, forKey: .name),
            isError: values.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
            createdAt: values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            imageAttachments: values.decodeIfPresent(
                [AgentImageAttachmentReference].self,
                forKey: .imageAttachments
            ) ?? [],
            reviewContext: values.decodeIfPresent(
                ReviewAgentContext.self,
                forKey: .reviewContext
            )
        )
    }
}

struct InternalToolDefinition: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: JSONValue
}

struct AgentModelRequest: Codable, Equatable, Sendable {
    var model: String
    var messages: [AgentMessage]
    var tools: [InternalToolDefinition]
    var stream: Bool
    var temperature: Double
    var maxOutputTokens: Int
    var contextWindowTokens: Int?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var presencePenalty: Double?
    var thinkingEnabled: Bool?
    var reasoningEffort: ModelReasoningEffort?
    var imagePayloads: [AgentImagePayload]

    init(
        model: String,
        messages: [AgentMessage],
        tools: [InternalToolDefinition],
        stream: Bool,
        temperature: Double,
        maxOutputTokens: Int,
        contextWindowTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        thinkingEnabled: Bool? = nil,
        reasoningEffort: ModelReasoningEffort? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowTokens = contextWindowTokens
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
        imagePayloads = []
    }

    init(
        model: String,
        messages: [AgentMessage],
        tools: [InternalToolDefinition],
        stream: Bool,
        temperature: Double,
        maxOutputTokens: Int,
        contextWindowTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        thinkingEnabled: Bool? = nil,
        reasoningEffort: ModelReasoningEffort? = nil,
        imagePayloads: [AgentImagePayload]
    ) throws {
        try AgentImageAttachmentLimits.validate(imagePayloads)
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowTokens = contextWindowTokens
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.thinkingEnabled = thinkingEnabled
        self.reasoningEffort = reasoningEffort
        self.imagePayloads = imagePayloads
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature, maxOutputTokens
        case contextWindowTokens, topP, topK, minP, repetitionPenalty, presencePenalty
        case thinkingEnabled, reasoningEffort, imagePayloads
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            model: values.decode(String.self, forKey: .model),
            messages: values.decode([AgentMessage].self, forKey: .messages),
            tools: values.decode([InternalToolDefinition].self, forKey: .tools),
            stream: values.decode(Bool.self, forKey: .stream),
            temperature: values.decode(Double.self, forKey: .temperature),
            maxOutputTokens: values.decode(Int.self, forKey: .maxOutputTokens),
            contextWindowTokens: values.decodeIfPresent(Int.self, forKey: .contextWindowTokens),
            topP: values.decodeIfPresent(Double.self, forKey: .topP),
            topK: values.decodeIfPresent(Int.self, forKey: .topK),
            minP: values.decodeIfPresent(Double.self, forKey: .minP),
            repetitionPenalty: values.decodeIfPresent(Double.self, forKey: .repetitionPenalty),
            presencePenalty: values.decodeIfPresent(Double.self, forKey: .presencePenalty),
            thinkingEnabled: values.decodeIfPresent(Bool.self, forKey: .thinkingEnabled),
            reasoningEffort: values.decodeIfPresent(
                ModelReasoningEffort.self,
                forKey: .reasoningEffort
            ),
            imagePayloads: values.decodeIfPresent([AgentImagePayload].self, forKey: .imagePayloads) ?? []
        )
    }
}

struct AgentTokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
}

struct AgentModelResponse: Codable, Equatable, Sendable {
    var content: String
    var reasoningSummary: String?
    var toolCalls: [AgentToolCall]
    var finishReason: String?
    var usage: AgentTokenUsage?
}

enum AgentModelStreamEvent: Equatable, Sendable {
    case contentDelta(String)
    case reasoningDelta(String)
    case completed(AgentModelResponse)
}

protocol AgentModelProvider: Sendable {
    var id: String { get }
    func capabilities(for model: String) async -> ModelCapabilities
    func generate(request: AgentModelRequest) async throws -> AgentModelResponse
    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error>
}

extension AgentModelProvider {
    /// Providers that truthfully report `supportsStreaming == false` retain a
    /// one-result stream fallback. Concrete streaming providers override this
    /// requirement and cancel their HTTP task when the consumer terminates.
    func stream(
        request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    var nonStreamingRequest = request
                    nonStreamingRequest.stream = false
                    let response = try await generate(request: nonStreamingRequest)
                    try Task.checkCancellation()
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Workspace and tools

struct AgentWorkspace: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var rootPath: String
    var allowedPaths: [String]
    var bookmarkData: Data?
    var gitRepository: Bool
    var branch: String?
    var createdAt: Date = Date()
    var lastOpened: Date = Date()
}

enum AgentToolCategory: String, Codable, CaseIterable, Sendable {
    case filesystem
    case search
    case terminal
    case git
    case todo
    case web
    case browser
    case mcp
    case plugin
    case image
    case system
}

enum AgentPermissionLevel: String, Codable, CaseIterable, Sendable {
    case read
    case write
    case execute
    case network
    case dangerous
}

struct AgentToolResult: Codable, Equatable, Sendable {
    var content: String
    var data: JSONValue?
    var isError: Bool
    var truncated: Bool
    var artifactPath: String?
    var change: AgentChangeRecord?
    var duration: TimeInterval?
    /// Persisted conservative signal for tools (notably mutation-capable MCP)
    /// whose side effects cannot be represented by a native file snapshot.
    var mayHaveChangedWorkspace: Bool
    var imageAttachments: [AgentImageAttachmentReference]

    init(
        content: String,
        data: JSONValue? = nil,
        isError: Bool = false,
        truncated: Bool = false,
        artifactPath: String? = nil,
        change: AgentChangeRecord? = nil,
        duration: TimeInterval? = nil,
        mayHaveChangedWorkspace: Bool = false
    ) {
        self.content = content
        self.data = data
        self.isError = isError
        self.truncated = truncated
        self.artifactPath = artifactPath
        self.change = change
        self.duration = duration
        self.mayHaveChangedWorkspace = mayHaveChangedWorkspace
        imageAttachments = []
    }

    init(
        content: String,
        data: JSONValue? = nil,
        isError: Bool = false,
        truncated: Bool = false,
        artifactPath: String? = nil,
        change: AgentChangeRecord? = nil,
        duration: TimeInterval? = nil,
        mayHaveChangedWorkspace: Bool = false,
        imageAttachments: [AgentImageAttachmentReference]
    ) throws {
        try AgentImageAttachmentLimits.validate(imageAttachments)
        self.content = content
        self.data = data
        self.isError = isError
        self.truncated = truncated
        self.artifactPath = artifactPath
        self.change = change
        self.duration = duration
        self.mayHaveChangedWorkspace = mayHaveChangedWorkspace
        self.imageAttachments = imageAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case content, data, isError, truncated, artifactPath, change, duration
        case mayHaveChangedWorkspace, imageAttachments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            content: values.decode(String.self, forKey: .content),
            data: values.decodeIfPresent(JSONValue.self, forKey: .data),
            isError: values.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
            truncated: values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
            artifactPath: values.decodeIfPresent(String.self, forKey: .artifactPath),
            change: values.decodeIfPresent(AgentChangeRecord.self, forKey: .change),
            duration: values.decodeIfPresent(TimeInterval.self, forKey: .duration),
            mayHaveChangedWorkspace: values.decodeIfPresent(
                Bool.self,
                forKey: .mayHaveChangedWorkspace
            ) ?? false,
            imageAttachments: values.decodeIfPresent(
                [AgentImageAttachmentReference].self,
                forKey: .imageAttachments
            ) ?? []
        )
    }
}

/// Sanitized host identity shown on every approval for a remote execution.
/// It contains no credential material and is captured before model output is
/// evaluated, so tool arguments cannot spoof the Host/User/Path card.
struct AgentRemoteExecutionIdentity: Codable, Equatable, Sendable {
    var runnerID: UUID
    var backendLabel: String
    var host: String
    var port: Int
    var user: String
    var workspaceRoot: String
    var configurationFingerprint: String

    init(
        runnerID: UUID,
        backendLabel: String,
        host: String,
        port: Int,
        user: String,
        workspaceRoot: String,
        configurationFingerprint: String = ""
    ) {
        self.runnerID = runnerID
        self.backendLabel = backendLabel
        self.host = host
        self.port = port
        self.user = user
        self.workspaceRoot = workspaceRoot
        self.configurationFingerprint = configurationFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case runnerID, backendLabel, host, port, user, workspaceRoot
        case configurationFingerprint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            runnerID: try values.decode(UUID.self, forKey: .runnerID),
            backendLabel: try values.decode(String.self, forKey: .backendLabel),
            host: try values.decode(String.self, forKey: .host),
            port: try values.decode(Int.self, forKey: .port),
            user: try values.decode(String.self, forKey: .user),
            workspaceRoot: try values.decode(String.self, forKey: .workspaceRoot),
            configurationFingerprint: try values.decodeIfPresent(
                String.self,
                forKey: .configurationFingerprint
            ) ?? ""
        )
    }
}

struct AgentToolContext: Sendable {
    var sessionID: UUID
    var taskID: UUID
    var toolCallID: String?
    var reason: String?
    var mode: AppMode
    var workspace: AgentWorkspace
    /// Host-owned execution binding captured from the durable Task when a run
    /// starts. Remote tools resolve credentials/configuration from the opaque
    /// runner ID; a model argument can never select or change the destination.
    var executionLocation: AgentExecutionLocation
    var remoteRunnerID: UUID? { executionLocation.remoteRunnerID }
    var remoteExecutionIdentity: AgentRemoteExecutionIdentity?
    var temporaryRoot: URL
    var commandTimeout: TimeInterval
    /// The same model-visible tool-result ceiling enforced by ToolExecutor.
    /// Review source paging stays below it so a host receipt can never claim
    /// bytes that the provider message silently omitted.
    var maximumToolResultCharacters: Int
    var environment: [String: String]
    var allowedCommands: [String]
    var deniedCommands: [String]
    /// `nil` inherits all globally enabled MCP servers. A non-nil set is the
    /// project allow-list captured when this run starts.
    var allowedMCPServerIDs: Set<UUID>?
    /// Whether the user has enabled network access for this Agent run. Closed
    /// tools can use this capability to permit network activity that cannot be
    /// identified from a wrapper command alone (for example `npm test`).
    var networkAccess: Bool
    /// True only when Browser was explicitly enabled before this run. Profile
    /// selection is an immutable host snapshot; tool arguments cannot switch
    /// to an existing or credential-bearing profile.
    var browserEnabled: Bool
    var browserProfileMode: AgentBrowserProfileMode
    var browserPersistentProfileName: String
    var browserExistingDebugEndpoint: String
    /// Computer Use is opt-in and fail-closed. An enabled run still cannot
    /// observe or control an application unless its exact bundle identifier is
    /// present in this set.
    var computerUseEnabled: Bool
    var computerUseAllowedBundleIdentifiers: Set<String>
    /// Non-secret provider configuration captured once at run start. PR tools
    /// resolve from this immutable snapshot; credentials remain in Keychain.
    var pullRequestProvider: PullRequestProviderConfiguration
    /// Host-selected Review source captured once at run start. Review tools
    /// must use this typed request instead of accepting a model-selected
    /// revision, branch, or pull request identifier.
    var reviewWorkflow: ReviewWorkflowRequest?
    /// Durable source Task for a dedicated Review Task. This is provenance,
    /// not authorization by itself; workspace/lease validation remains host-owned.
    var reviewSourceSessionID: UUID?
    /// Immutable finalized source copied from the source Task only when a
    /// dedicated Review is locked to Last Agent Turn. The production reader
    /// validates its Task/workspace identity and digest before exposing it.
    var reviewSourceSnapshot: AgentTurnReviewSnapshot?
    /// Host-owned orchestration capability. It is present only for a normal
    /// parent Agent run and never grants a child more authority than the
    /// immutable `subagentAuthority`/`subagentScope` snapshots below.
    var subagentController: (any SubagentControlling)?
    var subagentAuthority: SubagentAuthority?
    /// Non-nil only while a child is running. Registry and executor both apply
    /// this allow-list so a stale schema can never expand child authority.
    var subagentScope: SubagentScope?
    /// Host-only capability used to invoke an installed lifecycle hook. Normal
    /// model tool schemas are built with this nil, so hook executables are not
    /// callable by fabricated model output.
    var lifecycleHookInvocation: LifecycleHookInvocation?
    /// Exact Skill IDs selected by the host for this run. Resource reads must
    /// match this set and are still processed by ToolExecutor.
    var loadedSkillIDs: Set<String>
    /// Ephemeral, UI-only execution progress. Progress is never added to the
    /// provider conversation and does not replace the single final tool result.
    var progressHandler: AgentToolProgressHandler?

    init(
        sessionID: UUID,
        taskID: UUID? = nil,
        toolCallID: String? = nil,
        reason: String? = nil,
        mode: AppMode,
        workspace: AgentWorkspace,
        executionLocation: AgentExecutionLocation = .local,
        remoteExecutionIdentity: AgentRemoteExecutionIdentity? = nil,
        temporaryRoot: URL = AppPaths.projectTemporaryRoot,
        commandTimeout: TimeInterval = 120,
        maximumToolResultCharacters: Int = 24_000,
        environment: [String: String] = [:],
        allowedCommands: [String] = [],
        deniedCommands: [String] = [],
        allowedMCPServerIDs: Set<UUID>? = nil,
        networkAccess: Bool = false,
        browserEnabled: Bool = false,
        browserProfileMode: AgentBrowserProfileMode = .isolatedTemporary,
        browserPersistentProfileName: String = AgentBrowserSettingsLimits.defaultPersistentProfileName,
        browserExistingDebugEndpoint: String = AgentBrowserSettingsLimits.defaultExistingDebugEndpoint,
        computerUseEnabled: Bool = false,
        computerUseAllowedBundleIdentifiers: Set<String> = [],
        pullRequestProvider: PullRequestProviderConfiguration = .github,
        reviewWorkflow: ReviewWorkflowRequest? = nil,
        reviewSourceSessionID: UUID? = nil,
        reviewSourceSnapshot: AgentTurnReviewSnapshot? = nil,
        subagentController: (any SubagentControlling)? = nil,
        subagentAuthority: SubagentAuthority? = nil,
        subagentScope: SubagentScope? = nil,
        lifecycleHookInvocation: LifecycleHookInvocation? = nil,
        loadedSkillIDs: Set<String> = [],
        progressHandler: AgentToolProgressHandler? = nil
    ) {
        self.sessionID = sessionID
        self.taskID = taskID ?? sessionID
        self.toolCallID = toolCallID
        self.reason = reason
        self.mode = mode
        self.workspace = workspace
        self.executionLocation = executionLocation
        self.remoteExecutionIdentity = remoteExecutionIdentity
        self.temporaryRoot = temporaryRoot
        self.commandTimeout = commandTimeout
        self.maximumToolResultCharacters = max(1_024, maximumToolResultCharacters)
        self.environment = environment
        self.allowedCommands = allowedCommands
        self.deniedCommands = deniedCommands
        self.allowedMCPServerIDs = allowedMCPServerIDs
        self.networkAccess = networkAccess
        self.browserEnabled = browserEnabled
        self.browserProfileMode = browserProfileMode
        self.browserPersistentProfileName = browserPersistentProfileName
        self.browserExistingDebugEndpoint = browserExistingDebugEndpoint
        self.computerUseEnabled = computerUseEnabled
        self.computerUseAllowedBundleIdentifiers = computerUseAllowedBundleIdentifiers
        self.pullRequestProvider = pullRequestProvider
        self.reviewWorkflow = reviewWorkflow
        self.reviewSourceSessionID = reviewSourceSessionID
        self.reviewSourceSnapshot = reviewSourceSnapshot
        self.subagentController = subagentController
        self.subagentAuthority = subagentAuthority
        self.subagentScope = subagentScope
        self.lifecycleHookInvocation = lifecycleHookInvocation
        self.loadedSkillIDs = loadedSkillIDs
        self.progressHandler = progressHandler
    }
}

enum AgentToolOutputStream: String, Codable, Equatable, Sendable {
    case stdout
    case stderr
}

/// One small, already-redacted output delta emitted while a tool is still
/// executing. Producers must bound each delta; the Runtime applies a second
/// aggregate bound before exposing a snapshot to the UI.
struct AgentToolProgress: Equatable, Sendable {
    var stream: AgentToolOutputStream
    var delta: String
    var totalBytes: Int
    var truncated: Bool
}

typealias AgentToolProgressHandler = @Sendable (AgentToolProgress) async -> Void

protocol AgentTool: Sendable {
    var id: String { get }
    var name: String { get }
    var displayName: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    var category: AgentToolCategory { get }
    var permissionLevel: AgentPermissionLevel { get }
    /// Network is an orthogonal capability: a destructive remote operation is
    /// both `.dangerous` and network-bearing rather than one replacing the other.
    var requiresNetwork: Bool { get }
    var supportsParallelExecution: Bool { get }

    func isAvailable(in context: AgentToolContext) -> Bool
    func execute(arguments: JSONValue, context: AgentToolContext) async throws -> AgentToolResult
}

extension AgentTool {
    var requiresNetwork: Bool { permissionLevel == .network }

    func isAvailable(in context: AgentToolContext) -> Bool { true }

    var definition: InternalToolDefinition {
        InternalToolDefinition(name: name, description: description, inputSchema: inputSchema)
    }
}

// MARK: - Session, activity, approval, and changes

enum AgentRunState: String, Codable, Sendable {
    case idle
    case running
    case awaitingApproval
    case paused
    case completed
    case cancelled
    case failed
    case stepLimit
}

enum AgentGoalStatus: String, Codable, Sendable {
    case active
    case paused
    case completed
    case needsAttention
}

enum AgentGoalValidationError: LocalizedError, Equatable {
    case emptyObjective
    case objectiveTooLarge(maximumBytes: Int)
    case completionCriteriaTooLarge(maximumBytes: Int)
    case containsControlCharacters

    var errorDescription: String? {
        switch self {
        case .emptyObjective:
            "Goal 目標不能是空白。"
        case .objectiveTooLarge(let maximumBytes):
            "Goal 目標不可超過 \(maximumBytes / 1_024) KiB。"
        case .completionCriteriaTooLarge(let maximumBytes):
            "Goal 完成條件不可超過 \(maximumBytes / 1_024) KiB。"
        case .containsControlCharacters:
            "Goal 只能包含可顯示文字、換行與 Tab。"
        }
    }
}

/// A durable outcome attached to one Coding task. The model receives the
/// generated runtime request, while this bounded record remains the source of
/// truth across pause, app restart, provider failures, and context compaction.
struct AgentGoal: Codable, Equatable, Identifiable, Sendable {
    static let maximumObjectiveBytes = 16 * 1_024
    static let maximumCompletionCriteriaBytes = 16 * 1_024

    var id: UUID = UUID()
    var objective: String
    var completionCriteria: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case objective
        case completionCriteria
        case createdAt
        case updatedAt
        case completedAt
    }

    init(
        id: UUID = UUID(),
        objective: String,
        completionCriteria: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) throws {
        self.id = id
        self.objective = try Self.normalizedObjective(objective)
        self.completionCriteria = try Self.normalizedCompletionCriteria(completionCriteria)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            objective: container.decode(String.self, forKey: .objective),
            completionCriteria: container.decodeIfPresent(String.self, forKey: .completionCriteria),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            completedAt: container.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(objective, forKey: .objective)
        try container.encodeIfPresent(completionCriteria, forKey: .completionCriteria)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }

    mutating func update(objective: String, completionCriteria: String?, at date: Date = Date()) throws {
        self.objective = try Self.normalizedObjective(objective)
        self.completionCriteria = try Self.normalizedCompletionCriteria(completionCriteria)
        updatedAt = date
        completedAt = nil
    }

    var runtimeRequest: String {
        let criteria = completionCriteria ?? "完成目標、執行與變更相稱的驗證，並清楚回報結果。"
        return """
        You are executing a durable Goal for this Coding task.

        Objective:
        \(objective)

        Completion criteria:
        \(criteria)

        Work autonomously across the available tools until the objective and completion criteria are satisfied. Keep the Todo list current, verify the result before finishing, and report concrete evidence. If progress is genuinely blocked, preserve completed work and explain the exact blocker instead of claiming success.
        """
    }

    private static func normalizedObjective(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AgentGoalValidationError.emptyObjective }
        guard normalized.utf8.count <= maximumObjectiveBytes else {
            throw AgentGoalValidationError.objectiveTooLarge(maximumBytes: maximumObjectiveBytes)
        }
        try validateControls(in: normalized)
        return normalized
    }

    private static func normalizedCompletionCriteria(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= maximumCompletionCriteriaBytes else {
            throw AgentGoalValidationError.completionCriteriaTooLarge(
                maximumBytes: maximumCompletionCriteriaBytes
            )
        }
        try validateControls(in: normalized)
        return normalized
    }

    private static func validateControls(in value: String) throws {
        let containsForbiddenControl = value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar.value != 0x09
                && scalar.value != 0x0A
                && scalar.value != 0x0D
        }
        if containsForbiddenControl {
            throw AgentGoalValidationError.containsControlCharacters
        }
    }
}

enum AgentStepKind: String, Codable, Sendable {
    case thinking
    case reading
    case searching
    case editing
    case running
    case testing
    case git
    case mcp
    case approval
    case completed
    case failed
}

enum AgentStepStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case denied
    case cancelled
}

struct AgentStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: AgentStepKind
    var title: String
    var detail: String?
    var status: AgentStepStatus
    var toolCall: AgentToolCall?
    var toolResult: AgentToolResult?
    /// Bounded presentation state only. It is never encoded as a provider tool
    /// message and remains separate from the authoritative final result.
    var terminalProgress: AgentTerminalProgress?
    var startedAt: Date = Date()
    var completedAt: Date?
}

struct AgentTerminalProgress: Codable, Equatable, Sendable {
    var stdout: String = ""
    var stderr: String = ""
    var stdoutTotalBytes: Int = 0
    var stderrTotalBytes: Int = 0
    var truncated: Bool = false
    var updatedAt: Date = Date()
}

enum AgentTodoStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
}

struct AgentTodo: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var detail: String?
    var status: AgentTodoStatus = .pending
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum AgentChangeKind: String, Codable, Sendable {
    case create
    case modify
    case delete
    case move
    case copy
}

enum AgentChangeDisposition: String, Codable, Sendable {
    case kept
    /// The presentation card survived, but its bounded durable Undo snapshot
    /// was already consumed, evicted, or unavailable after recovery.
    case unavailable
}

struct AgentChangeRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var relativePath: String
    var destinationRelativePath: String?
    var kind: AgentChangeKind
    var unifiedDiff: String
    var snapshotPath: String?
    var createdAt: Date = Date()
    /// Nil means the change is still actionable. Optional keeps older session
    /// JSON backward compatible without a migration.
    var disposition: AgentChangeDisposition?
}

/// Immutable connection routing captured when an Agent task is created or the
/// user explicitly selects a model for that task. Credentials stay in Keychain
/// and are looked up by provider + endpoint at execution time.
struct AgentConnectionSnapshot: Codable, Equatable, Sendable {
    var provider: ProviderKind
    var backend: ModelBackendKind?
    var endpoint: String
    var profileID: UUID?
    var contextLength: Int
    var temperature: Double
    var requestTimeout: Double

    init(settings: AppSettings) {
        provider = settings.provider
        backend = settings.resolvedBackend
        endpoint = settings.endpoint
        profileID = settings.activeProfileID
        contextLength = settings.contextLength
        temperature = settings.temperature
        requestTimeout = settings.requestTimeout
    }

    var resolvedBackend: ModelBackendKind {
        if let backend, backend.provider == provider { return backend }
        return ModelBackendKind.inferred(provider: provider, endpoint: endpoint)
    }

    func providerSettings(
        model: String,
        modelParameterProfiles: [ModelParameterProfile] = []
    ) -> AppSettings {
        AppSettings(
            provider: provider,
            backend: resolvedBackend,
            endpoint: endpoint,
            selectedModel: model,
            contextLength: contextLength,
            temperature: temperature,
            requestTimeout: requestTimeout,
            activeProfileID: profileID,
            modelParameterProfiles: modelParameterProfiles
        )
    }
}

// MARK: - Task execution location and migration provenance

/// The durable, user-visible place where a Task is allowed to execute.  The
/// workspace remains the concrete filesystem authorization snapshot; this
/// record prevents a managed checkout or future remote host from being
/// presented as an ordinary local folder after relaunch.
enum AgentExecutionLocationKind: String, Codable, CaseIterable, Sendable {
    case local
    case worktree
    case ssh
    case futureCloud
}

struct AgentExecutionLocation: Codable, Equatable, Sendable {
    static let maximumLabelBytes = 512

    var kind: AgentExecutionLocationKind
    /// Present only for an app-managed worktree. The registry remains the
    /// authority for paths and ownership; a session UUID cannot select a path.
    var managedWorktreeID: UUID?
    /// Reserved for a configured Remote Runner identifier. Credentials and
    /// host secrets are never stored in the Task JSON.
    var remoteRunnerID: UUID?
    var label: String?

    init(
        kind: AgentExecutionLocationKind,
        managedWorktreeID: UUID?,
        remoteRunnerID: UUID?,
        label: String?
    ) {
        self.kind = kind
        self.managedWorktreeID = managedWorktreeID
        self.remoteRunnerID = remoteRunnerID
        self.label = Self.safeLabel(label)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, managedWorktreeID, remoteRunnerID, label
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(AgentExecutionLocationKind.self, forKey: .kind)
        let worktreeID = try values.decodeIfPresent(UUID.self, forKey: .managedWorktreeID)
        let remoteID = try values.decodeIfPresent(UUID.self, forKey: .remoteRunnerID)
        switch kind {
        case .local:
            guard worktreeID == nil, remoteID == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: values,
                    debugDescription: "Local execution cannot carry worktree or remote authority."
                )
            }
        case .worktree:
            guard worktreeID != nil, remoteID == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .managedWorktreeID,
                    in: values,
                    debugDescription: "A worktree location requires exactly one managed worktree ID."
                )
            }
        case .ssh, .futureCloud:
            guard worktreeID == nil, remoteID != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .remoteRunnerID,
                    in: values,
                    debugDescription: "A remote location requires exactly one configured runner ID."
                )
            }
        }
        let decodedLabel = try values.decodeIfPresent(String.self, forKey: .label)
        guard decodedLabel == nil || Self.safeLabel(decodedLabel) == decodedLabel else {
            throw DecodingError.dataCorruptedError(
                forKey: .label,
                in: values,
                debugDescription: "Execution-location label is oversized or contains control data."
            )
        }
        self.init(
            kind: kind,
            managedWorktreeID: worktreeID,
            remoteRunnerID: remoteID,
            label: decodedLabel
        )
    }

    private static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumLabelBytes,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return trimmed
    }

    static let local = AgentExecutionLocation(
        kind: .local,
        managedWorktreeID: nil,
        remoteRunnerID: nil,
        label: nil
    )

    static func worktree(id: UUID, label: String? = nil) -> AgentExecutionLocation {
        AgentExecutionLocation(
            kind: .worktree,
            managedWorktreeID: id,
            remoteRunnerID: nil,
            label: label
        )
    }

    static func ssh(runnerID: UUID, label: String? = nil) -> AgentExecutionLocation {
        AgentExecutionLocation(
            kind: .ssh,
            managedWorktreeID: nil,
            remoteRunnerID: runnerID,
            label: label
        )
    }

    /// Reserved protocol seam only. LumaChat must not present this as a live
    /// cloud backend until a real, authenticated relay implementation exists.
    static func futureCloud(runnerID: UUID, label: String? = nil) -> AgentExecutionLocation {
        AgentExecutionLocation(
            kind: .futureCloud,
            managedWorktreeID: nil,
            remoteRunnerID: runnerID,
            label: label
        )
    }
}

/// A bounded provenance link rather than a shared Runtime. Forked Tasks may
/// inherit durable user context, but never an active process, terminal,
/// approval continuation, or execution actor.
struct AgentTaskForkOrigin: Codable, Equatable, Sendable {
    var sourceSessionID: UUID
    var sourceUpdatedAt: Date
    var forkedAt: Date
}

enum AgentTaskHandoffOutcome: String, Codable, Sendable {
    case completed
    case rolledBack
}

struct AgentTaskHandoffRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var from: AgentExecutionLocation
    var to: AgentExecutionLocation
    var startedAt: Date
    var completedAt: Date
    var outcome: AgentTaskHandoffOutcome
}

/// A bounded, workspace-scoped record of an explicit "Allow for Session"
/// decision. MCP grants are intentionally never persisted because a server can
/// change its implementation independently between app launches.
struct AgentPermissionAllowance: Codable, Equatable, Hashable, Sendable {
    var toolID: String
    var toolName: String
    var category: String
    var effectiveLevel: String
    var workspaceRoot: String
    var argumentScope: Data?
}

/// The durable purpose of a Task. Keeping this distinct from `AppMode` lets
/// coding and Review Tasks share one Runtime while applying different safety
/// and completion contracts.
enum AgentTaskType: Codable, Equatable, Sendable {
    case coding
    case review(sourceSessionID: UUID, request: ReviewWorkflowRequest)
    case subagent(parentSessionID: UUID, subagentID: UUID, depth: Int)

    var reviewSourceSessionID: UUID? {
        guard case .review(let sourceSessionID, _) = self else { return nil }
        return sourceSessionID
    }

    var reviewWorkflowRequest: ReviewWorkflowRequest? {
        guard case .review(_, let request) = self else { return nil }
        return request
    }

    var subagentParentSessionID: UUID? {
        guard case .subagent(let parentSessionID, _, _) = self else { return nil }
        return parentSessionID
    }

    var subagentID: UUID? {
        guard case .subagent(_, let subagentID, _) = self else { return nil }
        return subagentID
    }

    var subagentDepth: Int {
        guard case .subagent(_, _, let depth) = self else { return 0 }
        return depth
    }

    var isWritableCodingTask: Bool {
        switch self {
        case .coding:
            true
        case .subagent:
            true
        case .review:
            false
        }
    }
}

struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String = "新 Agent 任務"
    var mode: AppMode
    var state: AgentRunState = .idle
    var workspace: AgentWorkspace?
    /// Optional keeps pre-Phase-A sessions decodable. A nil value is the
    /// backward-compatible local checkout location.
    var executionLocation: AgentExecutionLocation?
    /// Original user-selected checkout retained while a Task executes in a
    /// managed worktree. It is required for an explicit handoff back to Local.
    var localWorkspace: AgentWorkspace?
    var localProjectFolderID: UUID?
    /// Digest of the Local checkout state at the moment it was handed to a
    /// managed worktree. A reverse handoff must match this baseline before it
    /// may touch the user's original checkout.
    var localCheckoutBaselineFingerprint: String?
    /// Exact bounded supplemental roots used to calculate the baseline. New
    /// Task changes may add paths later; recomputing the old digest with that
    /// expanded set would create a false conflict even when Local is untouched.
    var localCheckoutBaselineSupplementalPaths: [String]?
    /// Symbolic Local branch captured with the baseline. Reverse handoff uses
    /// it with an expected-old update-ref CAS; detached HEAD stores nil.
    var localCheckoutBaselineReference: String?
    var forkOrigin: AgentTaskForkOrigin?
    var lastHandoff: AgentTaskHandoffRecord?
    /// Durable references keep pre-run checkpoints discoverable across an
    /// execution-location change. The referenced manifests remain immutable and
    /// retain their original workspace identity.
    var checkpointReferences: [AgentCheckpointReference]?
    /// Projects 2.0 catalog references. Optional fields keep pre-1.3 session
    /// JSON decodable; launch migration groups legacy workspaces into projects.
    var projectID: UUID?
    var projectFolderID: UUID?
    /// Nil preserves legacy sessions and resolves to "do not use". Changing
    /// either control affects only future runs, never an in-flight model turn.
    var memoryUseEnabled: Bool?
    var memoryContributionEnabled: Bool?
    var messages: [AgentMessage] = []
    var steps: [AgentStep] = []
    var todos: [AgentTodo] = []
    /// Optional keeps sessions written before durable Goals decodable without a
    /// migration. Clearing a Goal removes this record; normal task history stays.
    var goal: AgentGoal?
    var changes: [AgentChangeRecord] = []
    /// Structured Review comments survive pane dismissal and app relaunch.
    /// Optional keeps sessions written before the Review workspace decodable.
    var reviewComments: [ReviewInlineComment]?
    /// Optional keeps Tasks written before dedicated Review workflows
    /// decodable. A missing value is resolved as a normal coding Task.
    var taskType: AgentTaskType?
    /// The structured outcome submitted by a Review Task. Keeping this separate
    /// from transcript prose makes findings durable and renderable after relaunch.
    var reviewResult: ReviewWorkflowResult?
    /// Metadata only. Skill instructions are resolved and injected transiently
    /// for a run; they never become permanent system messages.
    var loadedSkills: [LoadedSkillReference]?
    /// Legacy pre-freeze field retained only so existing session JSON remains
    /// decodable. New runs never use it as a Review source.
    var lastAgentTurnReviewBaseline: AgentTurnReviewBaseline? = nil
    /// Pre-run state for the currently active coding run. A crash may leave it
    /// behind, but it can never replace the previous finalized snapshot.
    var pendingAgentTurnReviewBaseline: AgentTurnReviewBaseline? = nil
    /// Frozen source from the latest successfully finalized coding run.
    var lastAgentTurnReviewSnapshot: AgentTurnReviewSnapshot? = nil
    var model: String = ""
    var provider: ProviderKind = .ollama
    var profileID: UUID?
    /// Optional for backward compatibility with sessions written before route
    /// snapshots were introduced. AgentViewModel backfills it before a run.
    var connection: AgentConnectionSnapshot?
    /// Optional for backward compatibility with sessions written before
    /// restart-safe approval allowances were introduced.
    var permissionAllowances: [AgentPermissionAllowance]?
    /// Pinned and archived task state is independent from project membership.
    /// Optional dates are backward-compatible with sessions written before 1.3.
    var pinnedAt: Date?
    var archivedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastError: String?

    var resolvedExecutionLocation: AgentExecutionLocation {
        executionLocation ?? .local
    }

    var resolvedTaskType: AgentTaskType {
        taskType ?? .coding
    }

    var goalStatus: AgentGoalStatus? {
        guard let goal else { return nil }
        if goal.completedAt != nil || state == .completed {
            return .completed
        }
        switch state {
        case .paused, .cancelled:
            return .paused
        case .failed, .stepLimit:
            return .needsAttention
        case .idle, .running, .awaitingApproval:
            return .active
        case .completed:
            return .completed
        }
    }
}

enum AgentApprovalDecision: String, Codable, Sendable {
    case allowOnce
    case allowForSession
    case deny
}

struct AgentApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var sessionID: UUID
    var toolName: String
    var displayName: String
    var permissionLevel: AgentPermissionLevel
    var arguments: JSONValue
    var reason: String?
    var command: String?
    var workingDirectory: String?
    var riskReasons: [String]
    var diffPreview: String?
    var executionBackend: String? = nil
    var remoteHost: String? = nil
    var remotePort: Int? = nil
    var remoteUser: String? = nil
    var remoteWorkspaceRoot: String? = nil
}

enum AgentEvent: Sendable {
    case sessionUpdated(AgentSession)
    /// A transient update for one already-running step. The ViewModel updates
    /// that card in memory but waits for the final session snapshot to persist.
    case toolProgress(sessionID: UUID, stepID: UUID, AgentTerminalProgress)
    case approvalRequired(AgentApprovalRequest)
    case modelStarted
    case modelFinished(AgentTokenUsage?, latency: TimeInterval)
    case finished(AgentSession)
    case failed(String)
}

typealias AgentApprovalHandler = @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision

enum AgentRuntimeError: LocalizedError, Sendable, Equatable {
    case workspaceRequired
    case modelDoesNotSupportTools(String)
    case unknownTool(String)
    case permissionDenied(String)
    case invalidArguments(String)
    case stepLimit(Int)
    case invalidMode

    var errorDescription: String? {
        switch self {
        case .workspaceRequired: "Plan 或 Agent 模式需要先開啟一個專案。"
        case .modelDoesNotSupportTools(let model): "模型「\(model)」不支援原生 Agent tools。"
        case .unknownTool(let name): "模型要求了未註冊的工具：\(name)。"
        case .permissionDenied(let name): "工具「\(name)」未獲得執行權限。"
        case .invalidArguments(let detail): "工具參數無效：\(detail)"
        case .stepLimit(let limit): "Agent 已達到 \(limit) 步上限。"
        case .invalidMode: "Chat 模式不能啟動 Agent Runtime。"
        }
    }
}
