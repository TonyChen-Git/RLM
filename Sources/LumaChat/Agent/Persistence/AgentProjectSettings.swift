import CryptoKit
import Darwin
import Foundation

enum AgentProjectSettingsError: LocalizedError, Equatable, Sendable {
    case invalidWorkspace
    case invalidConfiguration(String)
    case invalidDocument
    case identityMismatch
    case unsafeStorage(String)
    case settingsTooLarge(Int)
    case importConflict
    case importRollbackUnavailable
    case storageBusy
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace:
            "Project Settings 需要有效的 canonical workspace directory。"
        case .invalidConfiguration(let detail):
            "Project Settings 設定無效：\(detail)"
        case .invalidDocument:
            "Project Settings 檔案損毀或格式不受支援。"
        case .identityMismatch:
            "Project Settings 與目前 canonical workspace identity 不符。"
        case .unsafeStorage(let detail):
            "Project Settings 儲存位置不安全：\(detail)"
        case .settingsTooLarge(let limit):
            "Project Settings 超過 \(limit) bytes 上限。"
        case .importConflict:
            "匯入欄位已變更；請重新預覽。為保留後續編輯，無法套用或還原舊匯入。"
        case .importRollbackUnavailable:
            "這筆匯入已還原或被較新的匯入取代；請重新開啟還原預覽。"
        case .storageBusy:
            "另一個視窗或程序正在儲存 Project Settings；請稍後重試。"
        case .posix(let operation, let code):
            "Project Settings \(operation) 失敗：\(String(cString: strerror(code)))"
        }
    }
}

struct AgentProjectIdentity: Codable, Equatable, Sendable {
    var canonicalRootPath: String
    var storageKey: String

    init(canonicalRootPath: String) {
        let normalized = canonicalRootPath.precomposedStringWithCanonicalMapping
        self.canonicalRootPath = normalized
        storageKey = Self.digest(normalized)
    }

    static func resolve(workspaceRootPath: String) throws -> AgentProjectIdentity {
        guard workspaceRootPath.hasPrefix("/"),
              !workspaceRootPath.contains("\0"),
              workspaceRootPath.utf8.count <= AgentProjectSettingsLimits.maximumWorkspacePathBytes else {
            throw AgentProjectSettingsError.invalidWorkspace
        }
        let canonical = URL(fileURLWithPath: workspaceRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var info = Darwin.stat()
        guard canonical.path != "/",
              Darwin.lstat(canonical.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw AgentProjectSettingsError.invalidWorkspace
        }
        return AgentProjectIdentity(canonicalRootPath: canonical.path)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct AgentProjectSettings: Equatable, Sendable {
    /// A presentation-only alias shared by every task for this canonical
    /// workspace. `nil` falls back to the folder name.
    var displayName: String?
    /// `nil` inherits the active/global model selection.
    var preferredModel: String?
    /// `nil` inherits the global Agent permission mode.
    var agentPermission: AgentPermissionMode?
    var allowedCommands: [String]
    var deniedCommands: [String]
    /// `nil` inherits globally enabled MCP servers; an empty array disables all.
    var mcpServerIDs: [UUID]?
    /// Values are hydrated from Keychain. Persisted JSON contains markers only.
    var environmentVariables: [String: String]
    var systemPrompt: String?
    /// Reviewed Cursor rules retain their activation metadata. Scoped rules
    /// are never flattened into the unconditional Project System Prompt.
    var importedRules: [ProjectInstructionImportComponent]

    init(
        displayName: String? = nil,
        preferredModel: String? = nil,
        agentPermission: AgentPermissionMode? = nil,
        allowedCommands: [String] = [],
        deniedCommands: [String] = [],
        mcpServerIDs: [UUID]? = nil,
        environmentVariables: [String: String] = [:],
        systemPrompt: String? = nil,
        importedRules: [ProjectInstructionImportComponent] = []
    ) {
        self.displayName = displayName
        self.preferredModel = preferredModel
        self.agentPermission = agentPermission
        self.allowedCommands = allowedCommands
        self.deniedCommands = deniedCommands
        self.mcpServerIDs = mcpServerIDs
        self.environmentVariables = environmentVariables
        self.systemPrompt = systemPrompt
        self.importedRules = importedRules
    }

}

enum AgentProjectSettingsLimits {
    static let maximumFileBytes = 1 * 1_024 * 1_024
    static let maximumHydratedBytes = 1 * 1_024 * 1_024
    static let maximumWorkspacePathBytes = 16 * 1_024
    static let maximumModelBytes = 1_024
    static let maximumDisplayNameBytes = 512
    static let maximumCommandsPerList = 256
    static let maximumCommandBytes = 4 * 1_024
    static let maximumMCPServers = 200
    static let maximumEnvironmentVariables = 128
    static let maximumEnvironmentKeyBytes = 128
    static let maximumEnvironmentValueBytes = 256 * 1_024
    static let maximumEnvironmentBytes = 512 * 1_024
    static let maximumSystemPromptBytes = 256 * 1_024
    static let maximumImportRollbackBytes = 512 * 1_024
}

/// Only these inert fields can be changed by external assistant imports.
enum AgentProjectImportField: String, Codable, CaseIterable, Hashable, Sendable {
    case preferredModel, systemPrompt, importedRules
}

struct AgentProjectImportSaveRequest: Sendable {
    let identity: AgentProjectIdentity
    let fields: Set<AgentProjectImportField>
    let baselineFingerprint: String

    init(identity: AgentProjectIdentity, fields: Set<AgentProjectImportField>, baseline: AgentProjectSettings) throws {
        self.identity = identity
        self.fields = fields
        baselineFingerprint = try AgentProjectImportValues(settings: baseline, fields: fields).fingerprint()
    }
}

struct AgentProjectImportRollbackPreview: Identifiable, Sendable {
    let id: UUID
    let identity: AgentProjectIdentity
    let createdAt: Date
    let current: String
    let previous: String
    let canRestore: Bool
}

/// A single import-only undo slot, committed in the same atomic document as
/// the import. It never copies permission, command, MCP or environment state.
private struct AgentProjectImportRollback: Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    let previous: AgentProjectImportValues
    let appliedFingerprint: String

    func validate() throws {
        guard !previous.fields.isEmpty,
              Set(previous.fields).count == previous.fields.count,
              appliedFingerprint.count == 64,
              appliedFingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              try JSONEncoder().encode(self).count <= AgentProjectSettingsLimits.maximumImportRollbackBytes else {
            throw AgentProjectSettingsError.invalidDocument
        }
        var model = AgentProjectSettings()
        previous.apply(to: &model)
        try AgentProjectSettingsValidation.validate(model)
        // Reject hidden fields and unredacted/tampered snapshots before they
        // can reach either the preview or restored model context.
        guard previous == AgentProjectImportValues(
            settings: model, fields: Set(previous.fields), redacting: true
        ) else {
            throw AgentProjectSettingsError.invalidDocument
        }
    }
}

private struct AgentProjectImportValues: Codable, Equatable, Sendable {
    let fields: [AgentProjectImportField]
    let preferredModel: String?
    let systemPrompt: String?
    let importedRules: [ProjectInstructionImportComponent]?

    init(settings: AgentProjectSettings, fields: Set<AgentProjectImportField>, redacting: Bool = false) {
        self.fields = fields.sorted { $0.rawValue < $1.rawValue }
        func text(_ value: String?) -> String? {
            redacting ? value.map(ExternalImportSanitizer.redact) : value
        }
        preferredModel = fields.contains(.preferredModel) ? text(settings.preferredModel) : nil
        systemPrompt = fields.contains(.systemPrompt) ? text(settings.systemPrompt) : nil
        importedRules = fields.contains(.importedRules) ? settings.importedRules.map { rule in
            guard redacting else { return rule }
            let scope: ProjectInstructionImportScope
            switch rule.scope {
            case .agentRequested(let description): scope = .agentRequested(ExternalImportSanitizer.redact(description))
            case .files(let globs): scope = .files(globs.map(ExternalImportSanitizer.redact))
            default: scope = rule.scope
            }
            return ProjectInstructionImportComponent(
                relativePath: ExternalImportSanitizer.redact(rule.relativePath),
                redactedContent: ExternalImportSanitizer.redact(rule.redactedContent),
                sourceByteCount: rule.sourceByteCount, scope: scope, sourceDigest: rule.sourceDigest
            )
        } : nil
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    func apply(to settings: inout AgentProjectSettings) {
        if fields.contains(.preferredModel) { settings.preferredModel = preferredModel }
        if fields.contains(.systemPrompt) { settings.systemPrompt = systemPrompt }
        if fields.contains(.importedRules) { settings.importedRules = importedRules ?? [] }
    }

    func summary() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

enum AgentProjectSettingsValidation {
    static func validate(_ settings: AgentProjectSettings) throws {
        var totalBytes = 0
        try validateDisplayName(settings.displayName)
        totalBytes += settings.displayName?.utf8.count ?? 0
        if let model = settings.preferredModel {
            guard !model.isEmpty,
                  model.utf8.count <= AgentProjectSettingsLimits.maximumModelBytes,
                  !containsControlCharacters(model) else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Preferred Model is empty, invalid, or oversized."
                )
            }
            totalBytes += model.utf8.count
        }

        try validateCommands(settings.allowedCommands, label: "Allowed Commands")
        try validateCommands(settings.deniedCommands, label: "Denied Commands")
        totalBytes += settings.allowedCommands.reduce(0) { $0 + $1.utf8.count }
        totalBytes += settings.deniedCommands.reduce(0) { $0 + $1.utf8.count }

        if let serverIDs = settings.mcpServerIDs {
            guard serverIDs.count <= AgentProjectSettingsLimits.maximumMCPServers,
                  Set(serverIDs).count == serverIDs.count else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "MCP Server IDs are duplicated or exceed the 200-server limit."
                )
            }
            totalBytes += serverIDs.count * 36
        }

        guard settings.environmentVariables.count
            <= AgentProjectSettingsLimits.maximumEnvironmentVariables else {
            throw AgentProjectSettingsError.invalidConfiguration(
                "Environment Variables exceed the 128-entry limit."
            )
        }
        var environmentBytes = 0
        for (key, value) in settings.environmentVariables {
            guard isSafeEnvironmentKey(key) else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Environment Variables contain an unsafe key."
                )
            }
            guard value.utf8.count <= AgentProjectSettingsLimits.maximumEnvironmentValueBytes,
                  !value.contains("\0") else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "An Environment Variable value is invalid or oversized."
                )
            }
            environmentBytes += key.utf8.count + value.utf8.count
            guard environmentBytes <= AgentProjectSettingsLimits.maximumEnvironmentBytes else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Environment Variables exceed the 512 KiB cumulative limit."
                )
            }
        }
        totalBytes += environmentBytes

        if let prompt = settings.systemPrompt {
            guard prompt.utf8.count <= AgentProjectSettingsLimits.maximumSystemPromptBytes,
                  !prompt.contains("\0") else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "System Prompt is invalid or exceeds the 256 KiB limit."
                )
            }
            totalBytes += prompt.utf8.count
        }
        guard settings.importedRules.count <= ProjectInstructionImporter.maximumSources,
              Set(settings.importedRules.map(\.relativePath)).count
                == settings.importedRules.count else {
            throw AgentProjectSettingsError.invalidConfiguration(
                "Imported rule count or source paths are invalid."
            )
        }
        for rule in settings.importedRules {
            guard !rule.relativePath.isEmpty,
                  rule.relativePath.utf8.count <= 4_096,
                  !rule.relativePath.hasPrefix("/"),
                  !rule.relativePath.contains(".."),
                  !rule.relativePath.contains("\0"),
                  !rule.redactedContent.contains("\0"),
                  rule.redactedContent.utf8.count <= ProjectInstructionImporter.maximumSourceBytes,
                  (rule.sourceDigest.isEmpty || (rule.sourceDigest.count == 64
                    && rule.sourceDigest.allSatisfy { $0.isHexDigit && !$0.isUppercase })),
                  rule.sourceByteCount >= 0 else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Imported rule path or content is invalid."
                )
            }
            totalBytes += rule.relativePath.utf8.count + rule.redactedContent.utf8.count
        }
        guard totalBytes <= AgentProjectSettingsLimits.maximumHydratedBytes else {
            throw AgentProjectSettingsError.settingsTooLarge(
                AgentProjectSettingsLimits.maximumHydratedBytes
            )
        }
    }

    static func validateDisplayName(_ displayName: String?) throws {
        guard let displayName else { return }
        guard !displayName.isEmpty,
              displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              displayName.utf8.count <= AgentProjectSettingsLimits.maximumDisplayNameBytes,
              !containsControlCharacters(displayName) else {
            throw AgentProjectSettingsError.invalidConfiguration(
                "專案顯示名稱不得空白、包含控制字元或超過 512 bytes。"
            )
        }
    }

    static func isSafeEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty,
              key.utf8.count <= AgentProjectSettingsLimits.maximumEnvironmentKeyBytes,
              let first = key.utf8.first,
              isASCIIAlpha(first) || first == 95,
              key.utf8.dropFirst().allSatisfy({ isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 95 }) else {
            return false
        }
        let uppercased = key.uppercased()
        let reserved = Set([
            "BASH_ENV", "CDPATH", "ENV", "HOME", "IFS", "LOGNAME", "OLDPWD",
            "PATH", "PWD", "SHELL", "SHLVL", "TEMP", "TMP", "TMPDIR", "USER",
            "ZDOTDIR", "_"
        ])
        guard !reserved.contains(uppercased) else { return false }
        return !["DYLD_", "LD_", "LUMACHAT_"].contains(where: uppercased.hasPrefix)
    }

    static func isValidFixedCommand(_ command: String) -> Bool {
        !command.isEmpty
            && command.utf8.count <= AgentProjectSettingsLimits.maximumCommandBytes
            && !containsControlCharacters(command)
            && command == command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateCommands(_ commands: [String], label: String) throws {
        guard commands.count <= AgentProjectSettingsLimits.maximumCommandsPerList,
              Set(commands).count == commands.count,
              commands.allSatisfy(isValidFixedCommand) else {
            throw AgentProjectSettingsError.invalidConfiguration(
                "\(label) contain duplicates, invalid entries, or exceed the 256-entry limit."
            )
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}

enum AgentProjectCommandPolicyDenial: Equatable, Sendable {
    case invalidCommand
    case invalidDeniedPolicy
    case invalidAllowedPolicy
    case matchedDeniedCommand
}

enum AgentProjectCommandPolicyResult: Equatable, Sendable {
    case denied(AgentProjectCommandPolicyDenial)
    /// Continue through the normal PermissionManager flow.
    case requiresStandardAuthorization
    /// Exact user-configured match that a later integration may consider.
    case automaticApprovalCandidate
}

/// Pure policy signal. It deliberately does not grant tool authorization.
struct AgentProjectCommandPolicyEvaluator: Sendable {
    private let riskAnalyzer: CommandRiskAnalyzer

    init(riskAnalyzer: CommandRiskAnalyzer = CommandRiskAnalyzer()) {
        self.riskAnalyzer = riskAnalyzer
    }

    func evaluate(
        command: String,
        settings: AgentProjectSettings
    ) -> AgentProjectCommandPolicyResult {
        guard AgentProjectSettingsValidation.isValidFixedCommand(command) else {
            return .denied(.invalidCommand)
        }
        guard settings.deniedCommands.count <= AgentProjectSettingsLimits.maximumCommandsPerList,
              Set(settings.deniedCommands).count == settings.deniedCommands.count,
              settings.deniedCommands.allSatisfy(
                  AgentProjectSettingsValidation.isValidFixedCommand
              ) else {
            return .denied(.invalidDeniedPolicy)
        }
        if settings.deniedCommands.contains(command) {
            return .denied(.matchedDeniedCommand)
        }
        guard settings.allowedCommands.count <= AgentProjectSettingsLimits.maximumCommandsPerList,
              Set(settings.allowedCommands).count == settings.allowedCommands.count,
              settings.allowedCommands.allSatisfy(
                  AgentProjectSettingsValidation.isValidFixedCommand
              ) else {
            return .denied(.invalidAllowedPolicy)
        }
        guard settings.allowedCommands.contains(command) else {
            return .requiresStandardAuthorization
        }
        let risk = riskAnalyzer.assess(command)
        guard risk.level == .safe, !risk.usesNetwork else {
            return .requiresStandardAuthorization
        }
        return .automaticApprovalCandidate
    }
}

protocol AgentProjectSecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

struct AgentProjectKeychainSecretStore: AgentProjectSecretStore {
    private let keychain = KeychainStore(service: "LumaChat.AgentProjectEnvironment")

    func save(_ value: String, account: String) throws {
        try keychain.save(value, account: account)
    }

    func load(account: String) throws -> String? {
        try keychain.load(account: account)
    }

    func delete(account: String) throws {
        try keychain.delete(account: account)
    }
}

/// Workspace-scoped Agent preferences. The JSON document is intentionally kept
/// in Application Support instead of the source checkout, so opening a project
/// never modifies it. Environment values are committed to Keychain before the
/// marker-only JSON is atomically replaced.
actor AgentProjectSettingsStore {
    static let defaultStorageRoot = AppPaths.appSupport
        .appendingPathComponent("AgentProjects", isDirectory: true)

    // v2 carries the durable undo record. Older versions must not rewrite a
    // document while silently discarding that record.
    private static let documentVersion = 2
    private static let fileName = "settings.json"
    private static let secretMarker = "${LUMACHAT_PROJECT_KEYCHAIN}"

    nonisolated let identity: AgentProjectIdentity
    nonisolated let settingsFileURL: URL

    private let storageRoot: URL
    private let secretStore: any AgentProjectSecretStore

    init(
        workspaceRootPath: String,
        storageRoot: URL = AgentProjectSettingsStore.defaultStorageRoot,
        secretStore: any AgentProjectSecretStore = AgentProjectKeychainSecretStore()
    ) throws {
        let identity = try AgentProjectIdentity.resolve(workspaceRootPath: workspaceRootPath)
        let standardizedRoot = storageRoot.standardizedFileURL
        guard standardizedRoot.isFileURL, standardizedRoot.path.hasPrefix("/"),
              standardizedRoot.path != "/", !standardizedRoot.path.contains("\0") else {
            throw AgentProjectSettingsError.unsafeStorage("storage root 必須是明確的絕對目錄。")
        }
        self.identity = identity
        self.storageRoot = standardizedRoot
        self.secretStore = secretStore
        settingsFileURL = standardizedRoot
            .appendingPathComponent(identity.storageKey, isDirectory: true)
            .appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func load() throws -> AgentProjectSettings {
        guard let document = try readDocumentIfPresent() else {
            return AgentProjectSettings()
        }
        return try hydrate(document)
    }

    private func hydrate(_ document: PersistedAgentProjectSettingsDocument) throws -> AgentProjectSettings {
        var hydrated = document.settings.hydratedModelWithoutEnvironment
        for key in document.settings.environmentVariables.keys.sorted() {
            guard document.settings.environmentVariables[key] == Self.secretMarker else {
                throw AgentProjectSettingsError.invalidDocument
            }
            let account = secretAccount(environmentKey: key)
            if let value = try secretStore.load(account: account) {
                hydrated.environmentVariables[key] = value
            }
        }
        try AgentProjectSettingsValidation.validate(hydrated)
        return hydrated
    }

    /// Sidebar labels do not need to hydrate project secrets from Keychain.
    /// Reading only the validated alias keeps startup fast and avoids prompting
    /// for unrelated credentials while restoring the task list.
    func loadDisplayName() throws -> String? {
        guard let document = try readDocumentIfPresent() else { return nil }
        let displayName = document.settings.displayName
        try AgentProjectSettingsValidation.validateDisplayName(displayName)
        return displayName
    }

    func save(_ settings: AgentProjectSettings, importRequest: AgentProjectImportSaveRequest? = nil) throws {
        try withExclusiveMutation {
            try saveLocked(settings, importRequest: importRequest)
        }
    }

    private func saveLocked(_ settings: AgentProjectSettings, importRequest: AgentProjectImportSaveRequest?) throws {
        try AgentProjectSettingsValidation.validate(settings)
        let previousDocument = try readDocumentIfPresent()
        let previousSettings = previousDocument?.settings.hydratedModelWithoutEnvironment ?? AgentProjectSettings()
        var importRollback = previousDocument?.importRollback
        if let importRequest {
            let importedValues = AgentProjectImportValues(settings: settings, fields: importRequest.fields)
            guard importedValues == AgentProjectImportValues(
                settings: settings, fields: importRequest.fields, redacting: true
            ) else {
                throw AgentProjectSettingsError.invalidConfiguration("Imported content contains unredacted sensitive data.")
            }
            guard importRequest.identity == identity, !importRequest.fields.isEmpty,
                  try AgentProjectImportValues(settings: previousSettings, fields: importRequest.fields).fingerprint()
                    == importRequest.baselineFingerprint else {
                throw AgentProjectSettingsError.importConflict
            }
            let changedFields = try Set(importRequest.fields.filter { field in
                try AgentProjectImportValues(settings: previousSettings, fields: [field]).fingerprint()
                    != AgentProjectImportValues(settings: settings, fields: [field]).fingerprint()
            })
            // Re-importing identical content cannot consume the user's undo.
            if !changedFields.isEmpty {
                importRollback = AgentProjectImportRollback(
                    previous: AgentProjectImportValues(settings: previousSettings, fields: changedFields, redacting: true),
                    appliedFingerprint: try AgentProjectImportValues(settings: settings, fields: changedFields).fingerprint()
                )
                try importRollback?.validate()
            }
        }
        let previousReferences = try secretReferences(in: previousDocument)
        let nextReferences = Set(settings.environmentVariables.keys.map {
            secretAccount(environmentKey: $0)
        })
        var backups: [String: AgentProjectSecretBackup] = [:]

        do {
            for key in settings.environmentVariables.keys.sorted() {
                let account = secretAccount(environmentKey: key)
                if backups[account] == nil {
                    backups[account] = AgentProjectSecretBackup(
                        value: try secretStore.load(account: account)
                    )
                }
                try secretStore.save(settings.environmentVariables[key] ?? "", account: account)
            }

            let persistedSettings = PersistedAgentProjectSettings(
                model: settings,
                environmentMarker: Self.secretMarker
            )
            let document = PersistedAgentProjectSettingsDocument(
                version: Self.documentVersion,
                identity: identity,
                settings: persistedSettings,
                importRollback: importRollback
            )
            try writeDocumentAtomically(encodedDocument(document))
        } catch {
            restoreSecrets(backups)
            throw error
        }

        // A crash before this best-effort cleanup only leaves an inaccessible
        // Keychain item; it never leaves plaintext or a broken settings file.
        for obsolete in previousReferences.subtracting(nextReferences).sorted() {
            try? secretStore.delete(account: obsolete)
        }
    }

    func loadImportRollback() throws -> AgentProjectImportRollbackPreview? {
        guard let document = try readDocumentIfPresent(), let rollback = document.importRollback else { return nil }
        let settings = document.settings.hydratedModelWithoutEnvironment
        let fields = Set(rollback.previous.fields)
        return AgentProjectImportRollbackPreview(
            id: rollback.id, identity: identity, createdAt: rollback.createdAt,
            current: try AgentProjectImportValues(settings: settings, fields: fields, redacting: true).summary(),
            previous: try rollback.previous.summary(),
            canRestore: try AgentProjectImportValues(settings: settings, fields: fields).fingerprint() == rollback.appliedFingerprint
        )
    }

    func restoreImport(id: UUID) throws -> AgentProjectSettings {
        try withExclusiveMutation { try restoreImportLocked(id: id) }
    }

    private func restoreImportLocked(id: UUID) throws -> AgentProjectSettings {
        guard var document = try readDocumentIfPresent(), let rollback = document.importRollback,
              rollback.id == id else {
            throw AgentProjectSettingsError.importRollbackUnavailable
        }
        var restored = try hydrate(document)
        guard try AgentProjectImportValues(settings: restored, fields: Set(rollback.previous.fields)).fingerprint()
                == rollback.appliedFingerprint else {
            throw AgentProjectSettingsError.importConflict
        }
        rollback.previous.apply(to: &restored)
        try AgentProjectSettingsValidation.validate(restored)
        // Preserve the persisted markers exactly, including references whose
        // Keychain values are temporarily unavailable. Restoration never writes
        // or deletes credentials, nor rewinds permission changes made later.
        var persisted = PersistedAgentProjectSettings(model: restored, environmentMarker: Self.secretMarker)
        persisted.environmentVariables = document.settings.environmentVariables
        document.settings = persisted
        document.importRollback = nil
        document.version = Self.documentVersion
        try writeDocumentAtomically(encodedDocument(document))
        return restored
    }

    private func encodedDocument(_ document: PersistedAgentProjectSettingsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= AgentProjectSettingsLimits.maximumFileBytes else {
            throw AgentProjectSettingsError.settingsTooLarge(AgentProjectSettingsLimits.maximumFileBytes)
        }
        return data
    }

    func delete() throws {
        try withExclusiveMutation { try deleteLocked() }
    }

    private func deleteLocked() throws {
        guard let rootDescriptor = try openStorageRoot(createIfMissing: false) else { return }
        defer { Darwin.close(rootDescriptor) }
        guard let projectDescriptor = try openProjectDirectory(
            rootDescriptor: rootDescriptor,
            createIfMissing: false
        ) else { return }
        defer { Darwin.close(projectDescriptor) }

        let document = try readDocument(projectDescriptor: projectDescriptor)
        let references = try secretReferences(in: document)
        if document != nil {
            try validateExistingDestination(projectDescriptor: projectDescriptor)
            let result = Self.withFileSystemName(Self.fileName) { name in
                Darwin.unlinkat(projectDescriptor, name, 0)
            }
            guard result == 0 || errno == ENOENT else {
                throw Self.posix("unlink", errno)
            }
            _ = Darwin.fsync(projectDescriptor)
        }
        for account in references.sorted() {
            try? secretStore.delete(account: account)
        }
    }

    private func readDocumentIfPresent() throws -> PersistedAgentProjectSettingsDocument? {
        guard let rootDescriptor = try openStorageRoot(createIfMissing: false) else { return nil }
        defer { Darwin.close(rootDescriptor) }
        guard let projectDescriptor = try openProjectDirectory(
            rootDescriptor: rootDescriptor,
            createIfMissing: false
        ) else { return nil }
        defer { Darwin.close(projectDescriptor) }
        return try readDocument(projectDescriptor: projectDescriptor)
    }

    private func readDocument(
        projectDescriptor: Int32
    ) throws -> PersistedAgentProjectSettingsDocument? {
        let descriptor = Self.withFileSystemName(Self.fileName) { name in
            Darwin.openat(
                projectDescriptor,
                name,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw AgentProjectSettingsError.unsafeStorage(
                "settings.json 必須是未經 symlink 的一般檔案。"
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw Self.posix("fstat", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= AgentProjectSettingsLimits.maximumFileBytes else {
            throw AgentProjectSettingsError.unsafeStorage(
                "settings.json 必須是單一連結且不超過 1 MiB 的一般檔案。"
            )
        }

        let expectedCount = Int(metadata.st_size)
        var data = Data(count: expectedCount)
        var offset = 0
        while offset < expectedCount {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    expectedCount - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw AgentProjectSettingsError.invalidDocument
            }
            offset += count
        }
        var trailingByte: UInt8 = 0
        guard Darwin.read(descriptor, &trailingByte, 1) == 0 else {
            throw AgentProjectSettingsError.settingsTooLarge(
                AgentProjectSettingsLimits.maximumFileBytes
            )
        }

        guard let document = try? JSONDecoder().decode(
            PersistedAgentProjectSettingsDocument.self,
            from: data
        ), (document.version == 1 || document.version == Self.documentVersion) else {
            throw AgentProjectSettingsError.invalidDocument
        }
        guard document.identity == identity else {
            throw AgentProjectSettingsError.identityMismatch
        }
        try document.settings.validatePersistedMarkers(Self.secretMarker)
        try document.importRollback?.validate()
        return document
    }

    /// Multiple windows and headless runtimes can create distinct store actors
    /// for the same Project. Keep the baseline check, Keychain transaction and
    /// atomic document commit under one filesystem lock across those actors.
    private func withExclusiveMutation<Result>(_ operation: () throws -> Result) throws -> Result {
        guard let rootDescriptor = try openStorageRoot(createIfMissing: true) else {
            throw AgentProjectSettingsError.unsafeStorage("無法建立 storage root。")
        }
        defer { Darwin.close(rootDescriptor) }
        guard let projectDescriptor = try openProjectDirectory(rootDescriptor: rootDescriptor, createIfMissing: true) else {
            throw AgentProjectSettingsError.unsafeStorage("無法建立 project settings 目錄。")
        }
        defer { Darwin.close(projectDescriptor) }
        let lockDescriptor = Self.withFileSystemName(".settings.lock") {
            Darwin.openat(projectDescriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard lockDescriptor >= 0 else {
            throw AgentProjectSettingsError.unsafeStorage("Project Settings lock 必須是一般檔案。")
        }
        defer { Darwin.close(lockDescriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(lockDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            throw AgentProjectSettingsError.unsafeStorage("Project Settings lock 必須是單一連結一般檔案。")
        }
        while flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw AgentProjectSettingsError.storageBusy }
            guard errno == EINTR else { throw Self.posix("lock settings", errno) }
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try operation()
    }

    private func writeDocumentAtomically(_ data: Data) throws {
        guard let rootDescriptor = try openStorageRoot(createIfMissing: true) else {
            throw AgentProjectSettingsError.unsafeStorage("無法建立 storage root。")
        }
        defer { Darwin.close(rootDescriptor) }
        guard let projectDescriptor = try openProjectDirectory(
            rootDescriptor: rootDescriptor,
            createIfMissing: true
        ) else {
            throw AgentProjectSettingsError.unsafeStorage("無法建立 project settings 目錄。")
        }
        defer { Darwin.close(projectDescriptor) }
        try validateExistingDestination(projectDescriptor: projectDescriptor)

        let temporaryName = ".settings-\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = Self.withFileSystemName(temporaryName) { name in
            Darwin.openat(
                projectDescriptor,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw Self.posix("open temporary", errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldRemoveTemporary {
                _ = Self.withFileSystemName(temporaryName) { name in
                    Darwin.unlinkat(projectDescriptor, name, 0)
                }
            }
        }

        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    temporaryDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Self.posix("write", errno) }
            offset += count
        }
        guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0 else {
            throw Self.posix("fchmod", errno)
        }
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw Self.posix("fsync", errno)
        }

        // Re-check immediately before rename. renameat replaces the directory
        // entry itself and never follows its target, while this check rejects a
        // malicious symlink/non-regular destination instead of silently healing it.
        try validateExistingDestination(projectDescriptor: projectDescriptor)
        let renameResult = Self.withFileSystemNames(temporaryName, Self.fileName) {
            sourceName, destinationName in
            Darwin.renameat(projectDescriptor, sourceName, projectDescriptor, destinationName)
        }
        guard renameResult == 0 else { throw Self.posix("rename", errno) }
        shouldRemoveTemporary = false
        // The rename is already the transaction commit. A volume that does not
        // implement directory fsync must not cause Keychain rollback afterward.
        _ = Darwin.fsync(projectDescriptor)
    }

    private func openStorageRoot(createIfMissing: Bool) throws -> Int32? {
        // Walk every component before creating descendants: checking only the
        // final directory would still write through a substituted parent link.
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posix("open storage root", errno) }
        for component in storageRoot.pathComponents.dropFirst() {
            if createIfMissing {
                let result = Self.withFileSystemName(component) {
                    Darwin.mkdirat(descriptor, $0, mode_t(0o700))
                }
                if result != 0, errno != EEXIST {
                    let code = errno
                    Darwin.close(descriptor)
                    throw Self.posix("mkdir storage root", code)
                }
            }
            let next = Self.withFileSystemName(component) {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            let code = errno
            Darwin.close(descriptor)
            if next < 0 {
                if !createIfMissing, code == ENOENT { return nil }
                throw AgentProjectSettingsError.unsafeStorage(
                    "storage root 的任何父目錄都不得是 symlink 或非目錄項目。"
                )
            }
            descriptor = next
        }
        var openedMetadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.posix("fstat storage root", code)
        }
        return descriptor
    }

    private func openProjectDirectory(
        rootDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32? {
        if createIfMissing {
            let result = Self.withFileSystemName(identity.storageKey) { name in
                Darwin.mkdirat(rootDescriptor, name, mode_t(0o700))
            }
            guard result == 0 || errno == EEXIST else {
                throw Self.posix("mkdir project", errno)
            }
        }
        let descriptor = Self.withFileSystemName(identity.storageKey) { name in
            Darwin.openat(
                rootDescriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor < 0 {
            if errno == ENOENT, !createIfMissing { return nil }
            throw AgentProjectSettingsError.unsafeStorage(
                "project settings 目錄不得是 symlink 或非目錄項目。"
            )
        }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.posix("fstat project", code)
        }
        return descriptor
    }

    private func validateExistingDestination(projectDescriptor: Int32) throws {
        var metadata = Darwin.stat()
        let result = Self.withFileSystemName(Self.fileName) { name in
            Darwin.fstatat(projectDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw Self.posix("fstatat settings", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1 else {
            throw AgentProjectSettingsError.unsafeStorage(
                "既有 settings.json 必須是未經 symlink 的單一連結一般檔案。"
            )
        }
    }

    private func secretReferences(
        in document: PersistedAgentProjectSettingsDocument?
    ) throws -> Set<String> {
        guard let document else { return [] }
        try document.settings.validatePersistedMarkers(Self.secretMarker)
        return Set(document.settings.environmentVariables.keys.map {
            secretAccount(environmentKey: $0)
        })
    }

    private func secretAccount(environmentKey: String) -> String {
        "agent-project|\(identity.storageKey)|environment|\(environmentKey)"
    }

    private func restoreSecrets(_ backups: [String: AgentProjectSecretBackup]) {
        for account in backups.keys.sorted() {
            if let value = backups[account]?.value {
                try? secretStore.save(value, account: account)
            } else {
                try? secretStore.delete(account: account)
            }
        }
    }

    private static func posix(_ operation: String, _ code: Int32) -> AgentProjectSettingsError {
        .posix(operation: operation, code: code)
    }

    private static func withFileSystemName<Result>(
        _ value: String,
        _ body: (UnsafePointer<CChar>) -> Result
    ) -> Result {
        value.withCString(body)
    }

    private static func withFileSystemNames<Result>(
        _ first: String,
        _ second: String,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result
    ) -> Result {
        first.withCString { firstName in
            second.withCString { secondName in
                body(firstName, secondName)
            }
        }
    }
}

private struct PersistedAgentProjectSettingsDocument: Codable, Equatable {
    var version: Int
    var identity: AgentProjectIdentity
    var settings: PersistedAgentProjectSettings
    var importRollback: AgentProjectImportRollback?
}

private struct PersistedAgentProjectSettings: Codable, Equatable {
    var displayName: String?
    var preferredModel: String?
    var agentPermission: AgentPermissionMode?
    var allowedCommands: [String]
    var deniedCommands: [String]
    var mcpServerIDs: [UUID]?
    var environmentVariables: [String: String]
    var systemPrompt: String?
    var importedRules: [ProjectInstructionImportComponent]?

    init(model: AgentProjectSettings, environmentMarker: String) {
        displayName = model.displayName
        preferredModel = model.preferredModel
        agentPermission = model.agentPermission
        allowedCommands = model.allowedCommands
        deniedCommands = model.deniedCommands
        mcpServerIDs = model.mcpServerIDs
        environmentVariables = model.environmentVariables.mapValues { _ in environmentMarker }
        systemPrompt = model.systemPrompt
        importedRules = model.importedRules.isEmpty ? nil : model.importedRules
    }

    var hydratedModelWithoutEnvironment: AgentProjectSettings {
        AgentProjectSettings(
            displayName: displayName,
            preferredModel: preferredModel,
            agentPermission: agentPermission,
            allowedCommands: allowedCommands,
            deniedCommands: deniedCommands,
            mcpServerIDs: mcpServerIDs,
            environmentVariables: [:],
            systemPrompt: systemPrompt,
            importedRules: importedRules ?? []
        )
    }

    func validatePersistedMarkers(_ expectedMarker: String) throws {
        guard environmentVariables.count
                <= AgentProjectSettingsLimits.maximumEnvironmentVariables,
              environmentVariables.allSatisfy({ key, value in
                  AgentProjectSettingsValidation.isSafeEnvironmentKey(key)
                      && value == expectedMarker
              }) else {
            throw AgentProjectSettingsError.invalidDocument
        }
    }
}

private struct AgentProjectSecretBackup {
    var value: String?
}
