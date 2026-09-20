import Darwin
import Foundation

public enum LumaUpdateInstaller {
    public static let confirmationTimeoutSeconds: TimeInterval = 120
    public static let maximumRequestAgeSeconds: TimeInterval = 15 * 60

    public static func perform(requestURL: URL) throws {
        let requestData = try LumaUpdateFileSecurity.readRegularFile(
            requestURL,
            maximumBytes: LumaUpdateFileSecurity.maximumJournalBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request: LumaUpdateInstallRequest
        do { request = try decoder.decode(LumaUpdateInstallRequest.self, from: requestData) }
        catch { throw LumaUpdateError.invalidInstallRequest }
        try validateRequest(request, requestURL: requestURL)
        try waitForExit(processIdentifier: request.parentProcessIdentifier, timeout: 90)

        var journal = try loadJournal(for: request)
        guard journal.stage == .prepared || journal.stage == .helperLaunched else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let currentURL = URL(fileURLWithPath: request.currentApplicationPath, isDirectory: true)
        let candidateURL = URL(fileURLWithPath: request.candidateApplicationPath, isDirectory: true)
        let backupURL = URL(fileURLWithPath: request.backupApplicationPath, isDirectory: true)
        let journalURL = URL(fileURLWithPath: request.journalPath, isDirectory: false)

        let currentIdentity = try LumaUpdateFileSecurity.applicationIdentity(
            at: currentURL,
            requireNotarization: true
        )
        let candidateIdentity = try LumaUpdateFileSecurity.applicationIdentity(
            at: candidateURL,
            requireNotarization: true
        )
        guard currentIdentity.bundleIdentifier == request.expectedBundleIdentifier,
              currentIdentity.teamIdentifier == request.expectedTeamIdentifier,
              candidateIdentity.bundleIdentifier == request.expectedBundleIdentifier,
              candidateIdentity.teamIdentifier == request.expectedTeamIdentifier,
              candidateIdentity.version == request.expectedVersion,
              candidateIdentity.build == request.expectedBuild else {
            throw LumaUpdateError.untrustedApplication("request and application identities differ")
        }

        if request.operation == .install {
            let verified = try verifySignedInstallRequest(
                request,
                currentApplicationURL: currentURL
            )
            guard try LumaUpdateFileSecurity.applicationTreeSHA256(at: candidateURL)
                == verified.release.applicationSHA256 else {
                throw LumaUpdateError.untrustedApplication(
                    "candidate tree differs from the signed feed"
                )
            }
        }

        let backupParent = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: backupParent, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: backupURL.path) else {
            throw LumaUpdateError.unsafePath("backup already exists")
        }
        try FileManager.default.copyItem(at: currentURL, to: backupURL)
        let copiedBackup = try LumaUpdateFileSecurity.applicationIdentity(
            at: backupURL,
            requireNotarization: true
        )
        guard copiedBackup == currentIdentity else {
            throw LumaUpdateError.untrustedApplication("backup identity changed during copy")
        }
        journal.stage = .backupCreated
        journal.updatedAt = Date()
        try LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)

        let targetParent = currentURL.deletingLastPathComponent().standardizedFileURL
        let swapURL = targetParent.appendingPathComponent(
            ".lumachat-update-\(request.installationID.uuidString).app",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: swapURL.path) else {
            throw LumaUpdateError.unsafePath("install swap path already exists")
        }
        try FileManager.default.copyItem(at: candidateURL, to: swapURL)
        let swapIdentity = try LumaUpdateFileSecurity.applicationIdentity(
            at: swapURL,
            requireNotarization: true
        )
        guard swapIdentity == candidateIdentity else {
            throw LumaUpdateError.untrustedApplication("same-volume candidate changed during copy")
        }

        try performAtomicSwapAndPersist(
            currentURL: currentURL,
            replacedApplicationURL: swapURL,
            journal: &journal,
            journalURL: journalURL,
            swapApplications: atomicSwap,
            persistJournal: LumaUpdateFileSecurity.writeJSONAtomically
        )

        do {
            try launch(applicationURL: currentURL, installationID: request.installationID)
            journal.stage = .launchRequested
            journal.updatedAt = Date()
            try LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)
            try waitForConfirmation(
                at: URL(fileURLWithPath: request.confirmationPath),
                installationID: request.installationID
            )
            journal.stage = .confirmed
            journal.updatedAt = Date()
            try LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)
            // The replaced app now resides at swapURL. Preserve it if this
            // filesystem materialized AppleDouble metadata.
            try? LumaUpdateFileSecurity.removeOwnedTreeIfSafe(swapURL, requiredParent: targetParent)
        } catch {
            try rollbackAtomicSwap(
                currentURL: currentURL,
                replacedApplicationURL: swapURL,
                journal: &journal,
                journalURL: journalURL
            )
            try? launch(applicationURL: currentURL, installationID: nil)
            throw error
        }
    }

    private static func validateRequest(
        _ request: LumaUpdateInstallRequest,
        requestURL: URL
    ) throws {
        guard request.schemaVersion == 1,
              request.parentProcessIdentifier > 1,
              abs(request.createdAt.timeIntervalSinceNow) <= maximumRequestAgeSeconds,
              request.expectedBuild > 0,
              request.expectedBundleIdentifier == "com.lumachat.desktop",
              !request.expectedTeamIdentifier.isEmpty,
              requestURL.path.hasSuffix("\(request.installationID.uuidString)/install-request.json") else {
            throw LumaUpdateError.invalidInstallRequest
        }
        _ = try LumaSemanticVersion(request.expectedVersion)
        let paths = [
            request.currentApplicationPath,
            request.candidateApplicationPath,
            request.backupApplicationPath,
            request.journalPath,
            request.confirmationPath
        ]
        guard paths.allSatisfy({ value in
            value.hasPrefix("/")
                && value == URL(fileURLWithPath: value).standardizedFileURL.path
                && !value.contains("\0")
        }), Set(paths).count == paths.count,
        request.currentApplicationPath.hasSuffix(".app"),
        request.candidateApplicationPath.hasSuffix(".app"),
        request.backupApplicationPath.hasSuffix(".app") else {
            throw LumaUpdateError.invalidInstallRequest
        }
    }

    private static func loadJournal(for request: LumaUpdateInstallRequest) throws -> LumaUpdateJournal {
        let data = try LumaUpdateFileSecurity.readRegularFile(
            URL(fileURLWithPath: request.journalPath),
            maximumBytes: LumaUpdateFileSecurity.maximumJournalBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal: LumaUpdateJournal
        do { journal = try decoder.decode(LumaUpdateJournal.self, from: data) }
        catch { throw LumaUpdateError.invalidInstallRequest }
        guard journal.schemaVersion == 1,
              journal.installationID == request.installationID,
              journal.operation == request.operation,
              journal.currentApplicationPath == request.currentApplicationPath,
              journal.candidateApplicationPath == request.candidateApplicationPath,
              journal.backupApplicationPath == request.backupApplicationPath,
              journal.confirmationPath == request.confirmationPath,
              journal.expectedBundleIdentifier == request.expectedBundleIdentifier,
              journal.expectedTeamIdentifier == request.expectedTeamIdentifier else {
            throw LumaUpdateError.invalidInstallRequest
        }
        return journal
    }

    private static func verifySignedInstallRequest(
        _ request: LumaUpdateInstallRequest,
        currentApplicationURL: URL
    ) throws -> LumaVerifiedUpdate {
        guard let encodedEnvelope = request.manifestEnvelopeBase64,
              let envelope = Data(base64Encoded: encodedEnvelope) else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let plistURL = currentApplicationURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try LumaUpdateFileSecurity.readRegularFile(plistURL, maximumBytes: 1_048_576)
        let value = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        guard let plist = value as? [String: Any],
              let key = plist["LumaChatUpdatePublicKey"] as? String,
              !key.isEmpty else {
            throw LumaUpdateError.invalidPublicKey
        }
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "unsupported"
#endif
        let verified = try LumaUpdateManifestVerifier.verify(
            envelopeData: envelope,
            publicKeyBase64: key,
            expectedBundleIdentifier: request.expectedBundleIdentifier,
            currentArchitecture: architecture
        )
        guard verified.release.version == request.expectedVersion,
              verified.release.build == request.expectedBuild,
              verified.release.teamIdentifier == request.expectedTeamIdentifier else {
            throw LumaUpdateError.invalidInstallRequest
        }
        return verified
    }

    private static func waitForExit(processIdentifier: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return }
            usleep(100_000)
        }
        throw LumaUpdateError.processFailure("the running application did not exit")
    }

    private static func waitForConfirmation(at url: URL, installationID: UUID) throws {
        let deadline = Date().addingTimeInterval(confirmationTimeoutSeconds)
        while Date() < deadline {
            if let data = try? LumaUpdateFileSecurity.readRegularFile(url, maximumBytes: 256),
               String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == installationID.uuidString {
                return
            }
            usleep(250_000)
        }
        throw LumaUpdateError.processFailure("the replacement application did not confirm launch")
    }

    private static func launch(applicationURL: URL, installationID: UUID?) throws {
        var arguments = ["-n", applicationURL.path]
        if let installationID {
            arguments += ["--args", "--update-install-id", installationID.uuidString]
        }
        try LumaUpdateFileSecurity.run("/usr/bin/open", arguments)
    }

    /// Closes the transaction window between the physical application swap and
    /// the durable `.swapped` journal record. If persistence fails after the
    /// swap, the previous application is restored before the I/O error escapes.
    /// The injected operations are internal so tests can exercise the exact
    /// production state machine without replacing files in /Applications.
    static func performAtomicSwapAndPersist(
        currentURL: URL,
        replacedApplicationURL: URL,
        journal: inout LumaUpdateJournal,
        journalURL: URL,
        swapApplications: (URL, URL) throws -> Void,
        persistJournal: (LumaUpdateJournal, URL) throws -> Void
    ) throws {
        try swapApplications(replacedApplicationURL, currentURL)
        journal.stage = .swapped
        journal.updatedAt = Date()
        do {
            try persistJournal(journal, journalURL)
        } catch {
            let persistenceError = error
            do {
                try swapApplications(replacedApplicationURL, currentURL)
            } catch {
                journal.stage = .failed
                journal.failure = "automatic rollback could not restore the previous application"
                journal.updatedAt = Date()
                try? persistJournal(journal, journalURL)
                throw LumaUpdateError.processFailure("automatic rollback failed")
            }
            journal.stage = .rolledBack
            journal.failure = nil
            journal.updatedAt = Date()
            // The original persistence failure may be persistent (for example,
            // ENOSPC). Physical rollback is the safety boundary, so recording
            // the recovered state is deliberately best effort.
            try? persistJournal(journal, journalURL)
            throw persistenceError
        }
    }

    private static func atomicSwap(_ firstURL: URL, _ secondURL: URL) throws {
        guard Darwin.renameatx_np(
            AT_FDCWD,
            firstURL.path,
            AT_FDCWD,
            secondURL.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw LumaUpdateError.processFailure(
                "atomic application swap failed: \(String(cString: strerror(errno)))"
            )
        }
    }

    private static func rollbackAtomicSwap(
        currentURL: URL,
        replacedApplicationURL: URL,
        journal: inout LumaUpdateJournal,
        journalURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: replacedApplicationURL.path) else {
            journal.stage = .failed
            journal.failure = "automatic rollback could not restore the previous application"
            journal.updatedAt = Date()
            try? LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)
            throw LumaUpdateError.processFailure("automatic rollback failed")
        }
        do {
            try atomicSwap(replacedApplicationURL, currentURL)
        } catch {
            journal.stage = .failed
            journal.failure = "automatic rollback could not restore the previous application"
            journal.updatedAt = Date()
            try? LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)
            throw LumaUpdateError.processFailure("automatic rollback failed")
        }
        journal.stage = .rolledBack
        journal.updatedAt = Date()
        journal.failure = nil
        try LumaUpdateFileSecurity.writeJSONAtomically(journal, to: journalURL)
    }
}
