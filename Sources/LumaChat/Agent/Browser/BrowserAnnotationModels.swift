import Foundation

enum BrowserAnnotationLimits {
    static let maximumOpaqueIdentifierBytes = 256
    static let maximumURLBytes = 4 * 1_024
    static let maximumPageTitleBytes = 2 * 1_024
    static let maximumPageExcerptBytes = 16 * 1_024
    static let maximumLabelBytes = 512
    static let maximumNoteBytes = 8 * 1_024
    static let maximumViewportDimension = 32_768
    static let maximumDeviceScaleFactor = 8.0
    static let maximumEncodedContextBytes = 64 * 1_024
    static let maximumContextsPerSession = 128
    static let maximumSessionFileBytes = 8 * 1_024 * 1_024
    static let maximumStoredSessions = 128
    static let maximumStoredBytes = 64 * 1_024 * 1_024
}

enum BrowserAnnotationValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case invalidViewport
    case invalidRegion
    case invalidURL
    case invalidTimestamp
    case invalidText(String)
    case oversized(field: String, maximumBytes: Int)
    case imagePayloadNotAllowed(String)
    case nonCanonicalPersistedContext

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Unsupported browser annotation schema version \(version)."
        case .invalidIdentifier(let field):
            "Browser annotation \(field) is not a bounded opaque identifier."
        case .invalidViewport:
            "Browser annotation viewport is invalid."
        case .invalidRegion:
            "Browser annotation region must be finite, non-empty, and inside the viewport."
        case .invalidURL:
            "Browser annotation page URL must be a credential-free HTTP(S) URL."
        case .invalidTimestamp:
            "Browser annotation timestamp is invalid."
        case .invalidText(let field):
            "Browser annotation \(field) is invalid."
        case .oversized(let field, let maximumBytes):
            "Browser annotation \(field) exceeds \(maximumBytes) bytes."
        case .imagePayloadNotAllowed(let field):
            "Browser annotation \(field) must not contain an embedded image payload."
        case .nonCanonicalPersistedContext:
            "Persisted browser annotation context was not canonical."
        }
    }
}

/// Browser text has no authority, even when it looks like an instruction.
/// Keeping the trust marker in the Codable shape prevents callers from losing
/// provenance while moving annotations into model context.
enum BrowserContextTrust: String, Codable, Equatable, Sendable {
    case untrusted
}

enum BrowserUntrustedTextSource: String, Codable, Equatable, Sendable {
    case webPageURL
    case webPageTitle
    case webPageExcerpt
    case userAnnotation
}

struct BrowserUntrustedText: Codable, Equatable, Sendable {
    let value: String
    let source: BrowserUntrustedTextSource
    let trust: BrowserContextTrust

    init(value: String, source: BrowserUntrustedTextSource) {
        self.value = value
        self.source = source
        trust = .untrusted
    }
}

struct BrowserViewport: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let deviceScaleFactor: Double

    init(width: Int, height: Int, deviceScaleFactor: Double = 1) throws {
        guard (1...BrowserAnnotationLimits.maximumViewportDimension).contains(width),
              (1...BrowserAnnotationLimits.maximumViewportDimension).contains(height),
              deviceScaleFactor.isFinite,
              (0...BrowserAnnotationLimits.maximumDeviceScaleFactor).contains(
                  deviceScaleFactor
              ),
              deviceScaleFactor > 0 else {
            throw BrowserAnnotationValidationError.invalidViewport
        }
        self.width = width
        self.height = height
        self.deviceScaleFactor = deviceScaleFactor
    }
}

/// Coordinates are fractions of the captured viewport, not document or screen
/// pixels. This keeps an annotation bounded when the backing screenshot is no
/// longer retained.
struct BrowserNormalizedRegion: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x <= 1, y <= 1,
              x + width <= 1,
              y + height <= 1 else {
            throw BrowserAnnotationValidationError.invalidRegion
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(
        pixelX: Double,
        pixelY: Double,
        pixelWidth: Double,
        pixelHeight: Double,
        viewport: BrowserViewport
    ) throws {
        let viewportWidth = Double(viewport.width)
        let viewportHeight = Double(viewport.height)
        guard pixelX.isFinite, pixelY.isFinite,
              pixelWidth.isFinite, pixelHeight.isFinite,
              pixelX >= 0, pixelY >= 0,
              pixelWidth > 0, pixelHeight > 0,
              pixelX + pixelWidth <= viewportWidth,
              pixelY + pixelHeight <= viewportHeight else {
            throw BrowserAnnotationValidationError.invalidRegion
        }
        let normalizedX = pixelX / viewportWidth
        let normalizedY = pixelY / viewportHeight
        try self.init(
            x: normalizedX,
            y: normalizedY,
            width: min(pixelWidth / viewportWidth, 1 - normalizedX),
            height: min(pixelHeight / viewportHeight, 1 - normalizedY)
        )
    }
}

enum BrowserAnnotationSurface: String, Codable, Equatable, Sendable {
    case screenshot
    case page
}

struct BrowserAnnotationTarget: Codable, Equatable, Sendable {
    let id: String
    let surface: BrowserAnnotationSurface
    let region: BrowserNormalizedRegion
}

struct BrowserAnnotationPage: Codable, Equatable, Sendable {
    let url: BrowserUntrustedText
    let title: BrowserUntrustedText?
    let selectedText: BrowserUntrustedText?
}

/// The complete, bounded context for one user-marked browser region. It stores
/// only semantic metadata: screenshot bytes and filesystem paths are
/// intentionally absent from this persistence contract.
struct BrowserAnnotationContext: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    /// `BrowserSession.id`; Task ownership is a separate host routing concern.
    let sessionID: UUID
    /// Immutable owning `AgentSession.id`. Keeping both UUIDs prevents a
    /// Browser session from being confused with Task authorization.
    let ownerTaskID: UUID
    let pageID: String
    let target: BrowserAnnotationTarget
    let viewport: BrowserViewport
    let page: BrowserAnnotationPage
    let label: BrowserUntrustedText
    let note: BrowserUntrustedText?
    let createdAt: Date
    let trust: BrowserContextTrust
}

/// Raw UI/CDP input. The validator is the sole conversion boundary from pixel
/// geometry and arbitrary strings into `BrowserAnnotationContext`.
struct BrowserAnnotationDraft: Equatable, Sendable {
    var id: UUID
    /// `BrowserSession.id`, not the owning `AgentSession.id`.
    var sessionID: UUID
    var ownerTaskID: UUID
    var pageID: String
    var targetID: String
    var surface: BrowserAnnotationSurface
    var pixelX: Double
    var pixelY: Double
    var pixelWidth: Double
    var pixelHeight: Double
    var viewportWidth: Int
    var viewportHeight: Int
    var deviceScaleFactor: Double
    var pageURL: String
    var pageTitle: String?
    var selectedPageText: String?
    var label: String
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        ownerTaskID: UUID,
        pageID: String,
        targetID: String,
        surface: BrowserAnnotationSurface,
        pixelX: Double,
        pixelY: Double,
        pixelWidth: Double,
        pixelHeight: Double,
        viewportWidth: Int,
        viewportHeight: Int,
        deviceScaleFactor: Double = 1,
        pageURL: String,
        pageTitle: String? = nil,
        selectedPageText: String? = nil,
        label: String,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ownerTaskID = ownerTaskID
        self.pageID = pageID
        self.targetID = targetID
        self.surface = surface
        self.pixelX = pixelX
        self.pixelY = pixelY
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.deviceScaleFactor = deviceScaleFactor
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.selectedPageText = selectedPageText
        self.label = label
        self.note = note
        self.createdAt = createdAt
    }
}

enum BrowserAnnotationHandling: String, Codable, Equatable, Sendable {
    /// Text may describe an instruction, but it is data to analyze and never a
    /// command that can override host/user policy.
    case dataOnly
}

struct BrowserAnnotationModelContext: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let handling: BrowserAnnotationHandling
    let trust: BrowserContextTrust
    let annotation: BrowserAnnotationContext
}

struct BrowserAnnotationContextValidator: Sendable {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"
    private let redactor = SecretRedactor()

    init() {}

    func validated(_ draft: BrowserAnnotationDraft) throws -> BrowserAnnotationContext {
        try validateUUID(draft.id, field: "ID")
        try validateUUID(draft.sessionID, field: "session ID")
        try validateUUID(draft.ownerTaskID, field: "owner Task ID")
        let pageID = try validatedIdentifier(draft.pageID, field: "page ID")
        let targetID = try validatedIdentifier(draft.targetID, field: "target ID")
        let viewport = try BrowserViewport(
            width: draft.viewportWidth,
            height: draft.viewportHeight,
            deviceScaleFactor: draft.deviceScaleFactor
        )
        let region = try BrowserNormalizedRegion(
            pixelX: draft.pixelX,
            pixelY: draft.pixelY,
            pixelWidth: draft.pixelWidth,
            pixelHeight: draft.pixelHeight,
            viewport: viewport
        )
        let url = try validatedURL(draft.pageURL)
        let title = try validatedOptionalText(
            draft.pageTitle,
            field: "page title",
            maximumBytes: BrowserAnnotationLimits.maximumPageTitleBytes,
            source: .webPageTitle
        )
        let selectedText = try validatedOptionalText(
            draft.selectedPageText,
            field: "selected page text",
            maximumBytes: BrowserAnnotationLimits.maximumPageExcerptBytes,
            source: .webPageExcerpt
        )
        let label = try validatedText(
            draft.label,
            field: "label",
            maximumBytes: BrowserAnnotationLimits.maximumLabelBytes,
            source: .userAnnotation,
            allowEmpty: false
        )
        let note = try validatedOptionalText(
            draft.note,
            field: "note",
            maximumBytes: BrowserAnnotationLimits.maximumNoteBytes,
            source: .userAnnotation
        )
        try validateTimestamp(draft.createdAt)

        let context = BrowserAnnotationContext(
            schemaVersion: BrowserAnnotationContext.currentSchemaVersion,
            id: draft.id,
            sessionID: draft.sessionID,
            ownerTaskID: draft.ownerTaskID,
            pageID: pageID,
            target: BrowserAnnotationTarget(
                id: targetID,
                surface: draft.surface,
                region: region
            ),
            viewport: viewport,
            page: BrowserAnnotationPage(
                url: BrowserUntrustedText(value: url, source: .webPageURL),
                title: title,
                selectedText: selectedText
            ),
            label: label,
            note: note,
            createdAt: draft.createdAt,
            trust: .untrusted
        )
        try validateEncodedSize(context)
        return context
    }

    /// Revalidates decoded/persisted input and returns its canonical form.
    func validated(_ context: BrowserAnnotationContext) throws -> BrowserAnnotationContext {
        guard context.schemaVersion == BrowserAnnotationContext.currentSchemaVersion else {
            throw BrowserAnnotationValidationError.unsupportedSchema(context.schemaVersion)
        }
        try validateUUID(context.id, field: "ID")
        try validateUUID(context.sessionID, field: "session ID")
        try validateUUID(context.ownerTaskID, field: "owner Task ID")
        let pageID = try validatedIdentifier(context.pageID, field: "page ID")
        let targetID = try validatedIdentifier(context.target.id, field: "target ID")
        let viewport = try BrowserViewport(
            width: context.viewport.width,
            height: context.viewport.height,
            deviceScaleFactor: context.viewport.deviceScaleFactor
        )
        let region = try BrowserNormalizedRegion(
            x: context.target.region.x,
            y: context.target.region.y,
            width: context.target.region.width,
            height: context.target.region.height
        )
        let url = try validatedURL(context.page.url.value)
        guard context.page.url.source == .webPageURL,
              context.page.url.trust == .untrusted,
              context.trust == .untrusted else {
            throw BrowserAnnotationValidationError.invalidText("trust metadata")
        }
        let title = try validatedPersistedOptionalText(
            context.page.title,
            field: "page title",
            maximumBytes: BrowserAnnotationLimits.maximumPageTitleBytes,
            source: .webPageTitle
        )
        let selectedText = try validatedPersistedOptionalText(
            context.page.selectedText,
            field: "selected page text",
            maximumBytes: BrowserAnnotationLimits.maximumPageExcerptBytes,
            source: .webPageExcerpt
        )
        guard context.label.source == .userAnnotation,
              context.label.trust == .untrusted else {
            throw BrowserAnnotationValidationError.invalidText("label trust metadata")
        }
        let label = try validatedText(
            context.label.value,
            field: "label",
            maximumBytes: BrowserAnnotationLimits.maximumLabelBytes,
            source: .userAnnotation,
            allowEmpty: false
        )
        let note = try validatedPersistedOptionalText(
            context.note,
            field: "note",
            maximumBytes: BrowserAnnotationLimits.maximumNoteBytes,
            source: .userAnnotation
        )
        try validateTimestamp(context.createdAt)

        let copy = BrowserAnnotationContext(
            schemaVersion: BrowserAnnotationContext.currentSchemaVersion,
            id: context.id,
            sessionID: context.sessionID,
            ownerTaskID: context.ownerTaskID,
            pageID: pageID,
            target: BrowserAnnotationTarget(
                id: targetID,
                surface: context.target.surface,
                region: region
            ),
            viewport: viewport,
            page: BrowserAnnotationPage(
                url: BrowserUntrustedText(value: url, source: .webPageURL),
                title: title,
                selectedText: selectedText
            ),
            label: label,
            note: note,
            createdAt: context.createdAt,
            trust: .untrusted
        )
        try validateEncodedSize(copy)
        return copy
    }

    func modelContext(
        for context: BrowserAnnotationContext
    ) throws -> BrowserAnnotationModelContext {
        let validatedContext = try validated(context)
        return BrowserAnnotationModelContext(
            schemaVersion: BrowserAnnotationContext.currentSchemaVersion,
            handling: .dataOnly,
            trust: .untrusted,
            annotation: validatedContext
        )
    }

    private func validatedIdentifier(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= BrowserAnnotationLimits.maximumOpaqueIdentifierBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7E
                      && scalar.value != 0x2F // /
                      && scalar.value != 0x5C // backslash
              }),
              redactor.redact(value) == value else {
            throw BrowserAnnotationValidationError.invalidIdentifier(field)
        }
        return value
    }

    private func validatedURL(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= BrowserAnnotationLimits.maximumURLBytes,
              !containsDisallowedControl(value),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              host.utf8.count <= 253,
              components.user == nil,
              components.password == nil,
              redactor.redact(host) == host,
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              !containsDisallowedControl(decodedPath),
              redactor.redact(decodedPath) == decodedPath else {
            throw BrowserAnnotationValidationError.invalidURL
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = try queryItems.map { item in
                guard !containsDisallowedControl(item.name),
                      item.value.map({ !containsDisallowedControl($0) }) ?? true else {
                    throw BrowserAnnotationValidationError.invalidURL
                }
                let normalizedName = item.name.lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                let sensitive = [
                    "token", "password", "passwd", "secret", "authorization",
                    "credential", "cookie", "api_key", "apikey", "access_key",
                    "private_key", "client_secret", "session", "oauth_code"
                ].contains(where: normalizedName.contains)
                let safeName = redactor.redact(item.name)
                let safeValue = item.value.map { candidate in
                    sensitive ? "[REDACTED]" : redactor.redact(candidate)
                }
                return URLQueryItem(name: safeName, value: safeValue)
            }
        }
        guard let normalized = components.url?.absoluteString,
              normalized.utf8.count <= BrowserAnnotationLimits.maximumURLBytes else {
            throw BrowserAnnotationValidationError.invalidURL
        }
        return normalized
    }

    private func validatedOptionalText(
        _ value: String?,
        field: String,
        maximumBytes: Int,
        source: BrowserUntrustedTextSource
    ) throws -> BrowserUntrustedText? {
        guard let value else { return nil }
        let normalized = try normalizedText(value, field: field, maximumBytes: maximumBytes)
        guard !normalized.isEmpty else { return nil }
        return BrowserUntrustedText(value: normalized, source: source)
    }

    private func validatedPersistedOptionalText(
        _ value: BrowserUntrustedText?,
        field: String,
        maximumBytes: Int,
        source: BrowserUntrustedTextSource
    ) throws -> BrowserUntrustedText? {
        guard let value else { return nil }
        guard value.source == source, value.trust == .untrusted else {
            throw BrowserAnnotationValidationError.invalidText("\(field) trust metadata")
        }
        return try validatedOptionalText(
            value.value,
            field: field,
            maximumBytes: maximumBytes,
            source: source
        )
    }

    private func validatedText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        source: BrowserUntrustedTextSource,
        allowEmpty: Bool
    ) throws -> BrowserUntrustedText {
        let normalized = try normalizedText(value, field: field, maximumBytes: maximumBytes)
        guard allowEmpty || !normalized.isEmpty else {
            throw BrowserAnnotationValidationError.invalidText(field)
        }
        return BrowserUntrustedText(value: normalized, source: source)
    }

    private func normalizedText(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        guard value.utf8.count <= maximumBytes else {
            throw BrowserAnnotationValidationError.oversized(
                field: field,
                maximumBytes: maximumBytes
            )
        }
        guard !containsEmbeddedImagePayload(value) else {
            throw BrowserAnnotationValidationError.imagePayloadNotAllowed(field)
        }
        var normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        normalized.removeAll { character in
            character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    && scalar.value != 0x09
                    && scalar.value != 0x0A
            }
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = redactor.redact(normalized)
        guard normalized.utf8.count <= maximumBytes else {
            throw BrowserAnnotationValidationError.oversized(
                field: field,
                maximumBytes: maximumBytes
            )
        }
        return normalized
    }

    private func validateUUID(_ value: UUID, field: String) throws {
        guard value.uuidString != Self.zeroUUID else {
            throw BrowserAnnotationValidationError.invalidIdentifier(field)
        }
    }

    private func validateTimestamp(_ value: Date) throws {
        let timestamp = value.timeIntervalSince1970
        // Broad enough for clock skew and archival fixtures, while excluding
        // infinities and corrupt dates from persisted input.
        guard timestamp.isFinite, (0...32_503_680_000).contains(timestamp) else {
            throw BrowserAnnotationValidationError.invalidTimestamp
        }
    }

    private func validateEncodedSize(_ context: BrowserAnnotationContext) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(context)
        guard data.count <= BrowserAnnotationLimits.maximumEncodedContextBytes else {
            throw BrowserAnnotationValidationError.oversized(
                field: "encoded context",
                maximumBytes: BrowserAnnotationLimits.maximumEncodedContextBytes
            )
        }
    }

    private func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private func containsEmbeddedImagePayload(_ value: String) -> Bool {
        let folded = value.lowercased().filter { !$0.isWhitespace }
        return folded.contains("data:image/") && folded.contains(";base64,")
    }
}
