import Darwin
import Foundation
import LumaUpdateCore

enum LumaUpdateCheckResult: Equatable, Sendable {
    case current
    case available(LumaUpdateRelease)
}

actor LumaUpdateService {
    static let maximumArchiveMembers = 4_096
    static let maximumMemberPathBytes = 1_024

    private let configuration: LumaUpdateTrustConfiguration
    private let stateStore: LumaUpdateStateStore
    private let session: URLSession
    private let stagingRoot: URL
    private let backupRoot: URL
    private let currentBundle: Bundle

    init(
        configuration: LumaUpdateTrustConfiguration,
        stateStore: LumaUpdateStateStore = LumaUpdateStateStore(),
        session: URLSession? = nil,
        stagingRoot: URL = AppPaths.updateStaging,
        backupRoot: URL = AppPaths.updateBackups,
        currentBundle: Bundle = .main
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.stagingRoot = stagingRoot.standardizedFileURL
        self.backupRoot = backupRoot.standardizedFileURL
        self.currentBundle = currentBundle
        if let session {
            self.session = session
        } else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 30
            settings.timeoutIntervalForResource = 60
            settings.urlCache = nil
            settings.httpCookieStorage = nil
            settings.httpShouldSetCookies = false
            self.session = URLSession(
                configuration: settings,
                delegate: RejectingRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
    }

    func check() async throws -> LumaUpdateCheckResult {
        var request = URLRequest(url: configuration.feedURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.lumachat.update.v1+json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let envelopeData = try await boundedResponse(
            request: request,
            maximumBytes: LumaUpdateManifestVerifier.maximumEnvelopeBytes,
            acceptedMediaTypes: ["application/vnd.lumachat.update.v1+json", "application/json"]
        )
        let verified = try LumaUpdateManifestVerifier.verify(
            envelopeData: envelopeData,
            publicKeyBase64: configuration.publicKeyBase64,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            currentArchitecture: Self.currentArchitecture
        )
        guard verified.release.teamIdentifier == configuration.teamIdentifier else {
            throw LumaUpdateError.invalidTeamIdentifier
        }
        var state = try stateStore.loadState()
        let comparison = try compareWithCurrent(verified.release)
        if comparison == .orderedDescending {
            state.availableRelease = verified.release
            state.availableEnvelopeBase64 = envelopeData.base64EncodedString()
            try stateStore.saveState(state)
            return .available(verified.release)
        }
        state.availableRelease = nil
        state.availableEnvelopeBase64 = nil
        try stateStore.saveState(state)
        return .current
    }

    func downloadAndPrepare() async throws -> LumaPreparedUpdate {
        var state = try stateStore.loadState()
        guard let release = state.availableRelease,
              let encodedEnvelope = state.availableEnvelopeBase64,
              let envelopeData = Data(base64Encoded: encodedEnvelope) else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let verified = try LumaUpdateManifestVerifier.verify(
            envelopeData: envelopeData,
            publicKeyBase64: configuration.publicKeyBase64,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            currentArchitecture: Self.currentArchitecture
        )
        guard verified.release == release,
              release.teamIdentifier == configuration.teamIdentifier,
              try compareWithCurrent(release) == .orderedDescending else {
            throw LumaUpdateError.invalidInstallRequest
        }

        let installationID = UUID()
        let transactionRoot = stagingRoot
            .appendingPathComponent(installationID.uuidString, isDirectory: true)
        guard transactionRoot.deletingLastPathComponent() == stagingRoot,
              !FileManager.default.fileExists(atPath: transactionRoot.path) else {
            throw LumaUpdateError.unsafePath(transactionRoot.path)
        }
        try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        let archiveURL = transactionRoot.appendingPathComponent("release.zip", isDirectory: false)
        let extractRoot = transactionRoot.appendingPathComponent("extracted", isDirectory: true)
        do {
            try await downloadArchive(release: release, to: archiveURL)
            try validateArchiveMembers(archiveURL)
            try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: false)
            try LumaUpdateFileSecurity.run(
                "/usr/bin/unzip",
                ["-q", archiveURL.path, "-d", extractRoot.path]
            )
            let candidate = extractRoot.appendingPathComponent("LumaChat.app", isDirectory: true)
            let topLevel = try FileManager.default.contentsOfDirectory(
                at: extractRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            guard topLevel.count == 1,
                  topLevel[0].standardizedFileURL == candidate.standardizedFileURL,
                  !LumaUpdateFileSecurity.containsAppleDouble(at: candidate),
                  !LumaUpdateFileSecurity.containsSymlink(at: candidate) else {
                throw LumaUpdateError.untrustedApplication("archive layout is unsafe")
            }
            let identity = try LumaUpdateFileSecurity.applicationIdentity(
                at: candidate,
                requireNotarization: true
            )
            guard identity.bundleIdentifier == release.bundleIdentifier,
                  identity.teamIdentifier == release.teamIdentifier,
                  identity.version == release.version,
                  identity.build == release.build else {
                throw LumaUpdateError.untrustedApplication("signed archive identity differs from feed")
            }
            guard try LumaUpdateFileSecurity.applicationTreeSHA256(at: candidate)
                == release.applicationSHA256 else {
                throw LumaUpdateError.untrustedApplication(
                    "extracted application differs from the signed feed"
                )
            }
            let prepared = LumaPreparedUpdate(
                installationID: installationID,
                release: release,
                envelopeBase64: encodedEnvelope,
                archivePath: archiveURL.path,
                candidateApplicationPath: candidate.path,
                createdAt: Date()
            )
            state.preparedUpdate = prepared
            try stateStore.saveState(state)
            return prepared
        } catch {
            // Preserve any AppleDouble-bearing transaction exactly as found.
            try? LumaUpdateFileSecurity.removeOwnedTreeIfSafe(
                transactionRoot,
                requiredParent: stagingRoot
            )
            throw error
        }
    }

    func launchPreparedInstall() throws -> UUID {
        let state = try stateStore.loadState()
        guard let prepared = state.preparedUpdate,
              prepared.release.teamIdentifier == configuration.teamIdentifier,
              prepared.release.bundleIdentifier == configuration.bundleIdentifier,
              Date().timeIntervalSince(prepared.createdAt) <= 24 * 60 * 60 else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let currentApplication = currentBundle.bundleURL.standardizedFileURL
        guard currentApplication.pathExtension == "app" else {
            throw LumaUpdateError.unsafePath("updates require a packaged .app")
        }
        let backup = backupRoot
            .appendingPathComponent(prepared.installationID.uuidString, isDirectory: true)
            .appendingPathComponent("LumaChat.app", isDirectory: true)
        let transactionRoot = stagingRoot.appendingPathComponent(
            prepared.installationID.uuidString,
            isDirectory: true
        )
        let requestURL = transactionRoot.appendingPathComponent("install-request.json")
        let confirmationURL = transactionRoot.appendingPathComponent("launch-confirmation.txt")
        let currentVersion = Self.bundleVersion(currentBundle)
        let currentBuild = Self.bundleBuild(currentBundle)
        let journal = LumaUpdateJournal(
            operation: .install,
            installationID: prepared.installationID,
            stage: .prepared,
            fromVersion: currentVersion,
            fromBuild: currentBuild,
            toVersion: prepared.release.version,
            toBuild: prepared.release.build,
            currentApplicationPath: currentApplication.path,
            candidateApplicationPath: prepared.candidateApplicationPath,
            backupApplicationPath: backup.path,
            confirmationPath: confirmationURL.path,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            expectedTeamIdentifier: configuration.teamIdentifier
        )
        try stateStore.saveJournal(journal)
        let request = LumaUpdateInstallRequest(
            operation: .install,
            installationID: prepared.installationID,
            parentProcessIdentifier: getpid(),
            currentApplicationPath: currentApplication.path,
            candidateApplicationPath: prepared.candidateApplicationPath,
            backupApplicationPath: backup.path,
            journalPath: AppPaths.updateJournalFile.path,
            confirmationPath: confirmationURL.path,
            manifestEnvelopeBase64: prepared.envelopeBase64,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            expectedTeamIdentifier: configuration.teamIdentifier,
            expectedVersion: prepared.release.version,
            expectedBuild: prepared.release.build
        )
        try LumaUpdateFileSecurity.writeJSONAtomically(request, to: requestURL)
        var launched = journal
        launched.stage = .helperLaunched
        launched.updatedAt = Date()
        try stateStore.saveJournal(launched)
        try launchHelper(requestURL: requestURL)
        return prepared.installationID
    }

    func launchRollback() throws -> UUID {
        let state = try stateStore.loadState()
        guard let knownGood = state.lastKnownGood else {
            throw LumaUpdateError.invalidInstallRequest
        }
        let knownGoodURL = URL(fileURLWithPath: knownGood.applicationPath, isDirectory: true)
        let identity = try LumaUpdateFileSecurity.applicationIdentity(
            at: knownGoodURL,
            requireNotarization: true
        )
        guard identity.bundleIdentifier == configuration.bundleIdentifier,
              identity.teamIdentifier == configuration.teamIdentifier,
              identity.version == knownGood.version,
              identity.build == knownGood.build else {
            throw LumaUpdateError.untrustedApplication("last-known-good backup changed")
        }
        let installationID = UUID()
        let transactionRoot = stagingRoot.appendingPathComponent(
            installationID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        let safetyBackup = backupRoot
            .appendingPathComponent(installationID.uuidString, isDirectory: true)
            .appendingPathComponent("LumaChat.app", isDirectory: true)
        let confirmationURL = transactionRoot.appendingPathComponent("launch-confirmation.txt")
        let currentApplication = currentBundle.bundleURL.standardizedFileURL
        let journal = LumaUpdateJournal(
            operation: .rollback,
            installationID: installationID,
            stage: .prepared,
            fromVersion: Self.bundleVersion(currentBundle),
            fromBuild: Self.bundleBuild(currentBundle),
            toVersion: knownGood.version,
            toBuild: knownGood.build,
            currentApplicationPath: currentApplication.path,
            candidateApplicationPath: knownGoodURL.path,
            backupApplicationPath: safetyBackup.path,
            confirmationPath: confirmationURL.path,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            expectedTeamIdentifier: configuration.teamIdentifier
        )
        try stateStore.saveJournal(journal)
        let requestURL = transactionRoot.appendingPathComponent("install-request.json")
        let request = LumaUpdateInstallRequest(
            operation: .rollback,
            installationID: installationID,
            parentProcessIdentifier: getpid(),
            currentApplicationPath: currentApplication.path,
            candidateApplicationPath: knownGoodURL.path,
            backupApplicationPath: safetyBackup.path,
            journalPath: AppPaths.updateJournalFile.path,
            confirmationPath: confirmationURL.path,
            manifestEnvelopeBase64: nil,
            expectedBundleIdentifier: configuration.bundleIdentifier,
            expectedTeamIdentifier: configuration.teamIdentifier,
            expectedVersion: knownGood.version,
            expectedBuild: knownGood.build
        )
        try LumaUpdateFileSecurity.writeJSONAtomically(request, to: requestURL)
        var launched = journal
        launched.stage = .helperLaunched
        launched.updatedAt = Date()
        try stateStore.saveJournal(launched)
        try launchHelper(requestURL: requestURL)
        return installationID
    }

    private func boundedResponse(
        request: URLRequest,
        maximumBytes: Int,
        acceptedMediaTypes: Set<String>
    ) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              AgentHTTPOrigin.isSameOrigin(request.url, http.url) else {
            throw LumaUpdateError.invalidURL
        }
        let mediaType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard acceptedMediaTypes.contains(mediaType) else { throw LumaUpdateError.invalidEnvelope }
        if let value = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(value), length > maximumBytes {
            throw LumaUpdateError.invalidEnvelope
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 16 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw LumaUpdateError.invalidEnvelope }
            data.append(byte)
        }
        guard !data.isEmpty else { throw LumaUpdateError.invalidEnvelope }
        return data
    }

    private func downloadArchive(release: LumaUpdateRelease, to destination: URL) async throws {
        let archiveURL = try LumaUpdateManifestVerifier.secureURL(release.archiveURL)
        var request = URLRequest(url: archiveURL)
        request.httpMethod = "GET"
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              AgentHTTPOrigin.isSameOrigin(archiveURL, http.url) else {
            throw LumaUpdateError.invalidURL
        }
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           Int64(contentLength) != release.archiveSize {
            throw LumaUpdateError.invalidArchiveSize
        }
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw LumaUpdateError.unsafePath(destination.path) }
        var count: Int64 = 0
        do {
            for try await byte in bytes {
                guard count < release.archiveSize else { throw LumaUpdateError.invalidArchiveSize }
                var value = byte
                var didWrite = false
                repeat {
                    let written = withUnsafePointer(to: &value) {
                        Darwin.write(descriptor, $0, 1)
                    }
                    if written < 0, errno == EINTR { continue }
                    guard written == 1 else {
                        throw LumaUpdateError.processFailure("archive write failed")
                    }
                    didWrite = true
                } while !didWrite
                count += 1
            }
            guard count == release.archiveSize, Darwin.fsync(descriptor) == 0 else {
                throw LumaUpdateError.invalidArchiveSize
            }
            _ = Darwin.close(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            // Single known regular file only; never a recursive metadata cleanup.
            _ = Darwin.unlink(destination.path)
            throw error
        }
        guard try LumaUpdateManifestVerifier.sha256Hex(ofFile: destination)
            == release.archiveSHA256 else {
            _ = Darwin.unlink(destination.path)
            throw LumaUpdateError.invalidArchiveHash
        }
    }

    private func validateArchiveMembers(_ archiveURL: URL) throws {
        let output = try LumaUpdateFileSecurity.run(
            "/usr/bin/unzip",
            ["-Z1", archiveURL.path],
            captureOutput: true
        )
        let members = output.split(whereSeparator: \Character.isNewline).map(String.init)
        guard !members.isEmpty,
              members.count <= Self.maximumArchiveMembers,
              members.allSatisfy({ member in
                  !member.isEmpty
                      && member.utf8.count <= Self.maximumMemberPathBytes
                      && member.hasPrefix("LumaChat.app/")
                      && !member.hasPrefix("/")
                      && !member.contains("\\")
                      && !member.contains("\0")
                      && !member.split(separator: "/", omittingEmptySubsequences: false)
                        .contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix("._") })
                      && !member.contains("/__MACOSX/")
              }) else {
            throw LumaUpdateError.untrustedApplication("archive member list is unsafe")
        }
    }

    private func launchHelper(requestURL: URL) throws {
        let packaged = currentBundle.bundleURL
            .appendingPathComponent("Contents/Resources/bin/lumachat-updater", isDirectory: false)
        let adjacent = currentBundle.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("lumachat-updater", isDirectory: false)
        let helper = FileManager.default.isExecutableFile(atPath: packaged.path)
            ? packaged
            : adjacent
        guard let helper,
              helper.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw LumaUpdateError.processFailure("the packaged update helper is unavailable")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--request", requestURL.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw LumaUpdateError.processFailure(error.localizedDescription) }
    }

    private func compareWithCurrent(_ release: LumaUpdateRelease) throws -> ComparisonResult {
        let currentVersion = try LumaSemanticVersion(Self.bundleVersion(currentBundle))
        let proposedVersion = try LumaSemanticVersion(release.version)
        if proposedVersion != currentVersion {
            return proposedVersion > currentVersion ? .orderedDescending : .orderedAscending
        }
        let currentBuild = Self.bundleBuild(currentBundle)
        if release.build == currentBuild { return .orderedSame }
        return release.build > currentBuild ? .orderedDescending : .orderedAscending
    }

    private static func bundleVersion(_ bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    private static func bundleBuild(_ bundle: Bundle) -> Int {
        Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unsupported"
#endif
    }
}
