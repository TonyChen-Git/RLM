import Foundation
import LumaUpdateCore

struct LumaUpdatePreferences: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var automaticallyChecksForUpdates: Bool
    var lastCheckedAt: Date?

    init(
        schemaVersion: Int = 1,
        automaticallyChecksForUpdates: Bool = true,
        lastCheckedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.lastCheckedAt = lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        automaticallyChecksForUpdates = try values.decodeIfPresent(
            Bool.self,
            forKey: .automaticallyChecksForUpdates
        ) ?? true
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }
}

struct LumaPreparedUpdate: Codable, Equatable, Sendable {
    var installationID: UUID
    var release: LumaUpdateRelease
    var envelopeBase64: String
    var archivePath: String
    var candidateApplicationPath: String
    var createdAt: Date
}

struct LumaLastKnownGoodApplication: Codable, Equatable, Sendable {
    var version: String
    var build: Int
    var bundleIdentifier: String
    var teamIdentifier: String
    var applicationPath: String
    var capturedAt: Date
}

struct LumaUpdatePersistentState: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var availableRelease: LumaUpdateRelease?
    var availableEnvelopeBase64: String?
    var preparedUpdate: LumaPreparedUpdate?
    var lastKnownGood: LumaLastKnownGoodApplication?

    init(
        schemaVersion: Int = 1,
        availableRelease: LumaUpdateRelease? = nil,
        availableEnvelopeBase64: String? = nil,
        preparedUpdate: LumaPreparedUpdate? = nil,
        lastKnownGood: LumaLastKnownGoodApplication? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.availableRelease = availableRelease
        self.availableEnvelopeBase64 = availableEnvelopeBase64
        self.preparedUpdate = preparedUpdate
        self.lastKnownGood = lastKnownGood
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        availableRelease = try values.decodeIfPresent(
            LumaUpdateRelease.self,
            forKey: .availableRelease
        )
        availableEnvelopeBase64 = try values.decodeIfPresent(
            String.self,
            forKey: .availableEnvelopeBase64
        )
        preparedUpdate = try values.decodeIfPresent(
            LumaPreparedUpdate.self,
            forKey: .preparedUpdate
        )
        lastKnownGood = try values.decodeIfPresent(
            LumaLastKnownGoodApplication.self,
            forKey: .lastKnownGood
        )
    }
}

struct LumaUpdateStateStore: Sendable {
    private let preferencesURL: URL
    private let stateURL: URL
    private let journalURL: URL

    init(
        preferencesURL: URL = AppPaths.updatePreferencesFile,
        stateURL: URL = AppPaths.updateStateFile,
        journalURL: URL = AppPaths.updateJournalFile
    ) {
        self.preferencesURL = preferencesURL.standardizedFileURL
        self.stateURL = stateURL.standardizedFileURL
        self.journalURL = journalURL.standardizedFileURL
    }

    func loadPreferences() throws -> LumaUpdatePreferences {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return LumaUpdatePreferences()
        }
        return try decode(LumaUpdatePreferences.self, from: preferencesURL)
    }

    func savePreferences(_ value: LumaUpdatePreferences) throws {
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        try LumaUpdateFileSecurity.writeJSONAtomically(value, to: preferencesURL)
    }

    func loadState() throws -> LumaUpdatePersistentState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return LumaUpdatePersistentState()
        }
        return try decode(LumaUpdatePersistentState.self, from: stateURL)
    }

    func saveState(_ value: LumaUpdatePersistentState) throws {
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        try LumaUpdateFileSecurity.writeJSONAtomically(value, to: stateURL)
    }

    func loadJournal() throws -> LumaUpdateJournal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let value = try decode(LumaUpdateJournal.self, from: journalURL)
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        return value
    }

    func saveJournal(_ value: LumaUpdateJournal) throws {
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        try LumaUpdateFileSecurity.writeJSONAtomically(value, to: journalURL)
    }

    func confirmLaunch(installationID: UUID, runningBundle: Bundle = .main) throws {
        guard let journal = try loadJournal(),
              journal.installationID == installationID,
              journal.stage == .launchRequested || journal.stage == .swapped,
              let runningVersion = runningBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let rawBuild = runningBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let runningBuild = Int(rawBuild),
              runningVersion == journal.toVersion,
              runningBuild == journal.toBuild,
              runningBundle.bundleIdentifier == journal.expectedBundleIdentifier else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let confirmationURL = URL(fileURLWithPath: journal.confirmationPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: confirmationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try AtomicFileWriter.write(Data((installationID.uuidString + "\n").utf8), to: confirmationURL)

        var state = try loadState()
        state.lastKnownGood = LumaLastKnownGoodApplication(
            version: journal.fromVersion,
            build: journal.fromBuild,
            bundleIdentifier: journal.expectedBundleIdentifier,
            teamIdentifier: journal.expectedTeamIdentifier,
            applicationPath: journal.backupApplicationPath,
            capturedAt: Date()
        )
        state.preparedUpdate = nil
        state.availableRelease = nil
        state.availableEnvelopeBase64 = nil
        try saveState(state)

        // The helper owns the final confirmed transition after seeing the
        // confirmation receipt. Keeping launchRequested here prevents two
        // processes from racing journal ownership.
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try LumaUpdateFileSecurity.readRegularFile(
            url,
            maximumBytes: LumaUpdateFileSecurity.maximumJournalBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) }
        catch { throw LumaUpdateError.persistenceFailure(error.localizedDescription) }
    }
}
