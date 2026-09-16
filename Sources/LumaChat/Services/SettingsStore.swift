import Combine
import Foundation

/// Stores non-secret preferences only. API keys intentionally live outside this type
/// and must be handled by the Keychain service.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var loadError: String?

    init() {
        do {
            settings = try Self.readSettings()
            loadError = nil
        } catch {
            settings = AppSettings()
            loadError = error.localizedDescription
        }
    }

    /// Reloads settings from disk. A missing file resolves to defaults.
    func load() throws {
        settings = try Self.readSettings()
        loadError = nil
    }

    /// Atomically persists the current non-secret settings as JSON.
    func save() throws {
        try Self.writeSettings(settings)
        loadError = nil
    }

    /// Applies and atomically persists a group of changes as one operation.
    func update(_ changes: (inout AppSettings) -> Void) throws {
        var updatedSettings = settings
        changes(&updatedSettings)
        try Self.writeSettings(updatedSettings)
        settings = updatedSettings
        loadError = nil
    }

    /// Restores defaults and optionally removes the persisted settings file.
    func resetToDefaults(removePersistedFile: Bool = false) throws {
        let defaults = AppSettings()

        if removePersistedFile {
            if FileManager.default.fileExists(atPath: AppPaths.settingsFile.path) {
                try FileManager.default.removeItem(at: AppPaths.settingsFile)
            }
        } else {
            try Self.writeSettings(defaults)
        }

        settings = defaults
        loadError = nil
    }

    private static func readSettings() throws -> AppSettings {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: AppPaths.settingsFile.path) else {
            return AppSettings()
        }

        let data = try Data(contentsOf: AppPaths.settingsFile)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    private static func writeSettings(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: AppPaths.appSupport,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try AtomicFileWriter.write(data, to: AppPaths.settingsFile)
    }
}
