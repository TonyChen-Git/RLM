import Darwin
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
    private let stateWriter: (@Sendable (LumaUpdatePersistentState, URL) throws -> Void)?
    private let confirmationWriter: (@Sendable (Data, URL) throws -> Void)?

    init(
        preferencesURL: URL = AppPaths.updatePreferencesFile,
        stateURL: URL = AppPaths.updateStateFile,
        journalURL: URL = AppPaths.updateJournalFile,
        stateWriter: (@Sendable (LumaUpdatePersistentState, URL) throws -> Void)? = nil,
        confirmationWriter: (@Sendable (Data, URL) throws -> Void)? = nil
    ) {
        self.preferencesURL = preferencesURL.standardizedFileURL
        self.stateURL = stateURL.standardizedFileURL
        self.journalURL = journalURL.standardizedFileURL
        self.stateWriter = stateWriter
        self.confirmationWriter = confirmationWriter
    }

    func loadPreferences() throws -> LumaUpdatePreferences {
        guard try documentExists(at: preferencesURL) else {
            return LumaUpdatePreferences()
        }
        let value = try decode(LumaUpdatePreferences.self, from: preferencesURL)
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        return value
    }

    func savePreferences(_ value: LumaUpdatePreferences) throws {
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        try LumaUpdateFileSecurity.writeJSONAtomically(value, to: preferencesURL)
    }

    func loadState() throws -> LumaUpdatePersistentState {
        guard try documentExists(at: stateURL) else {
            return LumaUpdatePersistentState()
        }
        let value = try decode(LumaUpdatePersistentState.self, from: stateURL)
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        return value
    }

    func saveState(_ value: LumaUpdatePersistentState) throws {
        guard value.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        if let stateWriter {
            try stateWriter(value, stateURL)
        } else {
            try LumaUpdateFileSecurity.writeJSONAtomically(value, to: stateURL)
        }
    }

    func loadJournal() throws -> LumaUpdateJournal? {
        guard try documentExists(at: journalURL) else { return nil }
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
        let previousState = try loadState()
        var confirmedState = previousState
        confirmedState.lastKnownGood = LumaLastKnownGoodApplication(
            version: journal.fromVersion,
            build: journal.fromBuild,
            bundleIdentifier: journal.expectedBundleIdentifier,
            teamIdentifier: journal.expectedTeamIdentifier,
            applicationPath: journal.backupApplicationPath,
            capturedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        )
        confirmedState.preparedUpdate = nil
        confirmedState.availableRelease = nil
        confirmedState.availableEnvelopeBase64 = nil

        // The durable state transition must precede the externally observed
        // receipt. Once the helper sees that receipt it is allowed to discard
        // rollback responsibility, so publishing it first could acknowledge a
        // launch whose Last Known Good state was never recorded.
        try saveState(confirmedState)

        let confirmationURL = URL(fileURLWithPath: journal.confirmationPath, isDirectory: false)
        let confirmationData = Data((installationID.uuidString + "\n").utf8)
        do {
            try FileManager.default.createDirectory(
                at: confirmationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let confirmationWriter {
                try confirmationWriter(confirmationData, confirmationURL)
            } else {
                try AtomicFileWriter.write(confirmationData, to: confirmationURL)
            }
        } catch {
            let receiptError = error
            switch confirmationReceiptState(at: confirmationURL, expected: confirmationData) {
            case .committed:
                // Atomic replacement happened, but the writer could not prove
                // its directory entry durable. Preserve the matching state and
                // surface the ambiguity instead of rolling one side back.
                throw LumaUpdateError.persistenceFailure(
                    "launch confirmation was written but its durability is uncertain: "
                        + receiptError.localizedDescription
                )
            case .uncertain:
                // A third-party or unreadable receipt must never be overwritten
                // or paired with a guessed state rollback.
                throw LumaUpdateError.persistenceFailure(
                    "launch confirmation outcome is uncertain: "
                        + receiptError.localizedDescription
                )
            case .absent:
                try compensateFailedConfirmation(
                    previousState: previousState,
                    confirmedState: confirmedState,
                    receiptError: receiptError
                )
            }
        }

        // The helper owns the final confirmed transition after seeing the
        // confirmation receipt. Keeping launchRequested here prevents two
        // processes from racing journal ownership.
    }

    private enum ConfirmationReceiptState {
        case committed
        case absent
        case uncertain
    }

    private func confirmationReceiptState(at url: URL, expected: Data) -> ConfirmationReceiptState {
        do {
            let data = try LumaUpdateFileSecurity.readRegularFile(url, maximumBytes: 256)
            return data == expected ? .committed : .uncertain
        } catch {
            var information = Darwin.stat()
            if Darwin.lstat(url.path, &information) == 0 { return .uncertain }
            return errno == ENOENT ? .absent : .uncertain
        }
    }

    private func compensateFailedConfirmation(
        previousState: LumaUpdatePersistentState,
        confirmedState: LumaUpdatePersistentState,
        receiptError: Error
    ) throws {
        // Avoid clobbering a concurrent state mutation. Compensation is safe
        // only while the currently visible state is exactly the transition
        // this call wrote.
        guard (try? loadState()) == confirmedState else {
            throw LumaUpdateError.persistenceFailure(
                "launch confirmation failed and update state changed before compensation: "
                    + receiptError.localizedDescription
            )
        }

        do {
            try saveState(previousState)
        } catch {
            let compensationError = error
            // A writer can fail after rename (for example, directory fsync).
            // Exact readback distinguishes a completed compensation from a
            // state that is still unsafe or was modified by another process.
            guard (try? loadState()) == previousState else {
                throw LumaUpdateError.persistenceFailure(
                    "launch confirmation failed and state compensation is uncertain: "
                        + compensationError.localizedDescription
                )
            }
        }

        throw LumaUpdateError.persistenceFailure(
            "launch confirmation could not be persisted: " + receiptError.localizedDescription
        )
    }

    private func documentExists(at url: URL) throws -> Bool {
        var information = Darwin.stat()
        if Darwin.lstat(url.path, &information) == 0 { return true }
        let errorCode = errno
        if errorCode == ENOENT { return false }
        throw LumaUpdateError.persistenceFailure(
            "update document presence could not be determined: "
                + String(cString: strerror(errorCode))
        )
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
