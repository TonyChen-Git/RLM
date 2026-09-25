import Darwin
import CryptoKit
import Foundation
import XCTest

@testable import LumaChat
@testable import LumaUpdateCore

private final class InMemorySecureStorageBackend: SecureStorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var injectedError: Error?

    func save(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let injectedError { throw injectedError }
        values["\(service)|\(account)"] = data
    }

    func load(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(service)|\(account)"]
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let injectedError { throw injectedError }
        values.removeValue(forKey: "\(service)|\(account)")
    }
}

private final class PhaseHUpdateOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var requestCount = 0

    static func reset() {
        requestLock.withLock { requestCount = 0 }
    }

    static func capturedRequestCount() -> Int {
        requestLock.withLock { requestCount }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLock.withLock { Self.requestCount += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private final class PhaseHPostCommitStateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writeCount = 0

    func write(_ value: LumaUpdatePersistentState, to url: URL) throws {
        lock.lock()
        writeCount += 1
        let currentWrite = writeCount
        lock.unlock()

        try LumaUpdateFileSecurity.writeJSONAtomically(value, to: url)
        if currentWrite == 2 {
            throw LumaUpdateError.persistenceFailure(
                "injected post-commit compensation ambiguity"
            )
        }
    }
}

final class PhaseHUpdateTests: XCTestCase {
    override func tearDown() {
        PhaseHUpdateOfflineURLProtocol.reset()
        super.tearDown()
    }

    func testUnresolvedJournalBlocksEveryNewUpdateOperationWithoutBeingOverwritten() async throws {
        let root = fixtureRoot("active-journal-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json")
        )
        var journal = sampleJournal(
            currentURL: root.appendingPathComponent("LumaChat.app", isDirectory: true),
            candidateURL: root.appendingPathComponent("candidate.app", isDirectory: true),
            journalURL: root.appendingPathComponent("journal.json")
        )
        journal.stage = .failed
        journal.failure = "injected unresolved transaction"
        try store.saveJournal(journal)
        let durableJournal = try store.loadJournal()
        let service = LumaUpdateService(
            configuration: updateConfiguration,
            stateStore: store,
            session: offlineSession(),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            backupRoot: root.appendingPathComponent("backups", isDirectory: true)
        )

        for operation in [
            { _ = try await service.check(); return () },
            { _ = try await service.downloadAndPrepare(); return () }
        ] {
            do {
                try await operation()
                XCTFail("An unresolved journal must block update work.")
            } catch let error as LumaUpdateError {
                XCTAssertEqual(error, .transactionInProgress)
            }
        }
        do {
            _ = try await service.launchPreparedInstall()
            XCTFail("An unresolved journal must block install launch.")
        } catch let error as LumaUpdateError {
            XCTAssertEqual(error, .transactionInProgress)
        }
        do {
            _ = try await service.launchRollback()
            XCTFail("An unresolved journal must block rollback launch.")
        } catch let error as LumaUpdateError {
            XCTAssertEqual(error, .transactionInProgress)
        }
        XCTAssertEqual(try store.loadJournal(), durableJournal)
    }

    func testCorruptStateAndJournalFailBeforeAnyNetworkFallback() async throws {
        for damagedName in ["state.json", "journal.json"] {
            let root = fixtureRoot("corrupt-\(damagedName)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LumaUpdateStateStore(
                preferencesURL: root.appendingPathComponent("preferences.json"),
                stateURL: root.appendingPathComponent("state.json"),
                journalURL: root.appendingPathComponent("journal.json")
            )
            try AtomicFileWriter.write(
                Data("{ damaged".utf8),
                to: root.appendingPathComponent(damagedName)
            )
            let service = LumaUpdateService(
                configuration: updateConfiguration,
                stateStore: store,
                session: offlineSession(),
                stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
                backupRoot: root.appendingPathComponent("backups", isDirectory: true)
            )

            do {
                _ = try await service.check()
                XCTFail("Damaged \(damagedName) must fail closed.")
            } catch let error as LumaUpdateError {
                guard case .persistenceFailure = error else {
                    return XCTFail("Expected persistence failure, got \(error)")
                }
            }
        }
    }

    func testFuturePreferencesAndStateSchemasFailClosedBeforeNetwork() async throws {
        for damagedName in ["preferences.json", "state.json"] {
            let root = fixtureRoot("future-schema-\(damagedName)")
            defer { try? FileManager.default.removeItem(at: root) }
            let preferencesURL = root.appendingPathComponent("preferences.json")
            let stateURL = root.appendingPathComponent("state.json")
            let store = LumaUpdateStateStore(
                preferencesURL: preferencesURL,
                stateURL: stateURL,
                journalURL: root.appendingPathComponent("journal.json")
            )
            let target = damagedName == "preferences.json" ? preferencesURL : stateURL
            try AtomicFileWriter.write(Data(#"{"schemaVersion":2}"#.utf8), to: target)

            XCTAssertThrowsError(try {
                if damagedName == "preferences.json" {
                    _ = try store.loadPreferences()
                } else {
                    _ = try store.loadState()
                }
            }()) { error in
                XCTAssertEqual(error as? LumaUpdateError, .unsupportedSchema)
            }

            if damagedName == "state.json" {
                PhaseHUpdateOfflineURLProtocol.reset()
                let service = LumaUpdateService(
                    configuration: updateConfiguration,
                    stateStore: store,
                    session: offlineSession(),
                    stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
                    backupRoot: root.appendingPathComponent("backups", isDirectory: true)
                )
                do {
                    _ = try await service.check()
                    XCTFail("A future update state schema must block checks.")
                } catch let error as LumaUpdateError {
                    XCTAssertEqual(error, .unsupportedSchema)
                }
                XCTAssertEqual(PhaseHUpdateOfflineURLProtocol.capturedRequestCount(), 0)
            }

            let controllerConfiguration = updateConfiguration
            await MainActor.run {
                let controller = LumaUpdateController(
                    store: store,
                    configuration: controllerConfiguration
                )
                XCTAssertEqual(controller.activity, .failed)
                XCTAssertFalse(controller.canCheck)
                XCTAssertFalse(controller.canPrepare)
                XCTAssertFalse(controller.canInstall)
                XCTAssertFalse(controller.canRollback)
            }
        }
    }

    func testPreparedUpdateCannotDowngradeAnewerCurrentBundle() async throws {
        let root = fixtureRoot("stale-prepared-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json")
        )
        let release = sampleRelease()
        let prepared = LumaPreparedUpdate(
            installationID: UUID(),
            release: release,
            envelopeBase64: Data("signed-envelope-placeholder".utf8).base64EncodedString(),
            archivePath: root.appendingPathComponent("release.zip").path,
            candidateApplicationPath: root.appendingPathComponent("candidate.app").path,
            createdAt: Date()
        )
        try store.saveState(LumaUpdatePersistentState(preparedUpdate: prepared))
        let currentBundle = try makeBundle(
            root: root,
            name: "Current.app",
            version: "1.6.0",
            build: 1
        )
        let service = LumaUpdateService(
            configuration: updateConfiguration,
            stateStore: store,
            session: offlineSession(),
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            backupRoot: root.appendingPathComponent("backups", isDirectory: true),
            currentBundle: currentBundle
        )

        do {
            _ = try await service.launchPreparedInstall()
            XCTFail("A stale prepared update must not downgrade the current bundle.")
        } catch let error as LumaUpdateError {
            XCTAssertEqual(error, .invalidInstallRequest)
        }
        XCTAssertNil(try store.loadJournal())

        let currentIdentity = LumaUpdateApplicationIdentity(
            bundleIdentifier: "com.lumachat.desktop",
            version: "1.6.0",
            build: 1,
            teamIdentifier: "ABCDE12345"
        )
        let staleIdentity = LumaUpdateApplicationIdentity(
            bundleIdentifier: "com.lumachat.desktop",
            version: release.version,
            build: release.build,
            teamIdentifier: "ABCDE12345"
        )
        XCTAssertFalse(try LumaUpdateInstaller.isStrictlyNewer(
            candidate: staleIdentity,
            than: currentIdentity
        ))
    }

    @MainActor
    func testControllerSurfacesCorruptPreferencesAndStateAndDisablesActions() {
        for damagedName in ["preferences.json", "state.json"] {
            let root = fixtureRoot("controller-corrupt-\(damagedName)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LumaUpdateStateStore(
                preferencesURL: root.appendingPathComponent("preferences.json"),
                stateURL: root.appendingPathComponent("state.json"),
                journalURL: root.appendingPathComponent("journal.json")
            )
            try? AtomicFileWriter.write(
                Data("{ damaged".utf8),
                to: root.appendingPathComponent(damagedName)
            )

            let controller = LumaUpdateController(
                store: store,
                configuration: updateConfiguration
            )
            XCTAssertEqual(controller.activity, .failed)
            XCTAssertTrue(controller.statusMessage.contains("更新資料損壞"))
            XCTAssertFalse(controller.canCheck)
            XCTAssertFalse(controller.canPrepare)
            XCTAssertFalse(controller.canInstall)
            XCTAssertFalse(controller.canRollback)
            if damagedName == "preferences.json" {
                XCTAssertFalse(controller.automaticallyChecksForUpdates)
            }
        }
    }

    @MainActor
    func testControllerKeepsCorruptOrUnresolvedJournalWarningVisible() async throws {
        for journalData in [Data("{ damaged".utf8), try encodedFailedJournal()] {
            let root = fixtureRoot("controller-journal")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = LumaUpdateStateStore(
                preferencesURL: root.appendingPathComponent("preferences.json"),
                stateURL: root.appendingPathComponent("state.json"),
                journalURL: root.appendingPathComponent("journal.json")
            )
            try AtomicFileWriter.write(journalData, to: root.appendingPathComponent("journal.json"))
            let controller = LumaUpdateController(
                store: store,
                configuration: updateConfiguration
            )

            await controller.start()
            let warning = controller.statusMessage
            XCTAssertEqual(controller.activity, .failed)
            XCTAssertFalse(controller.canCheck)
            await controller.checkForUpdates()
            await controller.downloadAndPrepare()
            let didLaunch = await controller.launchInstall()
            XCTAssertFalse(didLaunch)
            XCTAssertEqual(controller.statusMessage, warning)
        }
    }

    func testAtomicJSONWriterFailsBeforeRenameWhenParentCannotBeOpened() throws {
        let root = fixtureRoot("atomic-parent-open")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("state.json")
        let operations = LumaUpdateFileSecurity.AtomicJSONWriteOperations(
            openParentDirectory: { _ in -1 },
            syncFile: { Darwin.fsync($0) },
            syncParentDirectory: { Darwin.fsync($0) }
        )

        XCTAssertThrowsError(try LumaUpdateFileSecurity.writeJSONAtomically(
            LumaUpdatePersistentState(),
            to: destination,
            operations: operations
        )) { error in
            guard case LumaUpdateError.persistenceFailure = error else {
                return XCTFail("Expected a persistence failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAtomicJSONWriterReportsPostRenameDirectorySyncAmbiguity() throws {
        let root = fixtureRoot("atomic-parent-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("state.json")
        let store = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: stateURL,
            journalURL: root.appendingPathComponent("journal.json")
        )
        let replacement = LumaUpdatePersistentState(availableRelease: sampleRelease())
        let operations = LumaUpdateFileSecurity.AtomicJSONWriteOperations(
            openParentDirectory: { path in
                Darwin.open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW_ANY)
            },
            syncFile: { Darwin.fsync($0) },
            syncParentDirectory: { _ in -1 }
        )

        XCTAssertThrowsError(try LumaUpdateFileSecurity.writeJSONAtomically(
            replacement,
            to: stateURL,
            operations: operations
        )) { error in
            guard case LumaUpdateError.persistenceFailure(let detail) = error else {
                return XCTFail("Expected a persistence failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("parent directory"), detail)
        }
        XCTAssertEqual(
            try store.loadState(),
            replacement,
            "A post-rename fsync error is ambiguous: the visible replacement must not be hidden."
        )
    }

    func testBrokenUpdateDocumentSymlinksAreNotTreatedAsMissing() throws {
        for documentName in ["preferences.json", "state.json", "journal.json"] {
            let root = fixtureRoot("broken-\(documentName)-symlink")
            defer { try? FileManager.default.removeItem(at: root) }
            let preferencesURL = root.appendingPathComponent("preferences.json")
            let stateURL = root.appendingPathComponent("state.json")
            let journalURL = root.appendingPathComponent("journal.json")
            let documentURL = root.appendingPathComponent(documentName)
            guard Darwin.symlink("missing-update-document-target", documentURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let store = LumaUpdateStateStore(
                preferencesURL: preferencesURL,
                stateURL: stateURL,
                journalURL: journalURL
            )

            XCTAssertThrowsError(try {
                switch documentName {
                case "preferences.json": _ = try store.loadPreferences()
                case "state.json": _ = try store.loadState()
                default: _ = try store.loadJournal()
                }
            }()) { error in
                guard case LumaUpdateError.unsafePath = error else {
                    return XCTFail("Expected \(documentName) to fail as unsafe, got \(error)")
                }
            }
        }
    }

    func testConfirmLaunchNeverPublishesReceiptBeforeStatePersistence() throws {
        let root = fixtureRoot("confirm-state-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            stateWriter: { _, _ in
                throw LumaUpdateError.persistenceFailure("injected state write failure")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.confirmationURL.path))
        XCTAssertEqual(try fixture.store.loadState(), fixture.previousState)
    }

    func testConfirmLaunchDoesNotPublishReceiptAfterAmbiguousStateCommit() throws {
        let root = fixtureRoot("confirm-state-post-commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            stateWriter: { value, url in
                try LumaUpdateFileSecurity.writeJSONAtomically(value, to: url)
                throw LumaUpdateError.persistenceFailure("injected state sync ambiguity")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.confirmationURL.path))
        let visibleState = try fixture.store.loadState()
        XCTAssertNil(visibleState.availableRelease)
        XCTAssertEqual(visibleState.lastKnownGood?.version, fixture.journal.fromVersion)
    }

    func testConfirmLaunchCompensatesStateWhenReceiptWriteFailsBeforeCommit() throws {
        let root = fixtureRoot("confirm-receipt-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            confirmationWriter: { _, _ in
                throw LumaUpdateError.persistenceFailure("injected receipt write failure")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.confirmationURL.path))
        XCTAssertEqual(try fixture.store.loadState(), fixture.previousState)
    }

    func testConfirmLaunchPreservesMatchingStateWhenReceiptWriterFailsAfterCommit() throws {
        let root = fixtureRoot("confirm-receipt-post-commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            confirmationWriter: { data, url in
                try AtomicFileWriter.write(data, to: url)
                throw LumaUpdateError.persistenceFailure("injected receipt sync ambiguity")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        ))
        XCTAssertEqual(
            try LumaUpdateFileSecurity.readRegularFile(
                fixture.confirmationURL,
                maximumBytes: 256
            ),
            Data((fixture.journal.installationID.uuidString + "\n").utf8)
        )
        let durableState = try fixture.store.loadState()
        XCTAssertNil(durableState.availableRelease)
        XCTAssertEqual(durableState.lastKnownGood?.version, fixture.journal.fromVersion)
    }

    func testConfirmLaunchTreatsBrokenReceiptSymlinkAsUncertain() throws {
        let root = fixtureRoot("confirm-receipt-broken-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            confirmationWriter: { _, url in
                guard Darwin.symlink("missing-confirmation-target", url.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                throw LumaUpdateError.persistenceFailure("injected unsafe receipt")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        )) { error in
            guard case LumaUpdateError.persistenceFailure(let detail) = error else {
                return XCTFail("Expected a persistence failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("outcome is uncertain"), detail)
        }
        var information = Darwin.stat()
        XCTAssertEqual(Darwin.lstat(fixture.confirmationURL.path, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFLNK)
        let durableState = try fixture.store.loadState()
        XCTAssertNil(durableState.availableRelease)
        XCTAssertEqual(durableState.lastKnownGood?.version, fixture.journal.fromVersion)
    }

    func testConfirmLaunchAcceptsVerifiedPostCommitCompensation() throws {
        let root = fixtureRoot("confirm-compensation-post-commit")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepareLaunchConfirmationFixture(root: root)
        let stateWriter = PhaseHPostCommitStateWriter()
        let failingStore = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json"),
            stateWriter: { value, url in try stateWriter.write(value, to: url) },
            confirmationWriter: { _, _ in
                throw LumaUpdateError.persistenceFailure("injected receipt write failure")
            }
        )

        XCTAssertThrowsError(try failingStore.confirmLaunch(
            installationID: fixture.journal.installationID,
            runningBundle: fixture.runningBundle
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.confirmationURL.path))
        XCTAssertEqual(try fixture.store.loadState(), fixture.previousState)
    }

    func testDiskFullAfterAtomicSwapRestoresPreviousApplication() throws {
        let root = fixtureRoot("swap-journal-disk-full")
        let currentURL = root.appendingPathComponent("LumaChat.app", isDirectory: true)
        let replacedURL = root.appendingPathComponent(".replacement.app", isDirectory: true)
        let journalURL = root.appendingPathComponent("journal.json", isDirectory: false)
        var installedVersion = "old"
        var replacementVersion = "new"
        var swapCount = 0
        var persistedStages: [LumaUpdateJournalStage] = []
        var journal = sampleJournal(
            currentURL: currentURL,
            candidateURL: replacedURL,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try LumaUpdateInstaller.performAtomicSwapAndPersist(
            currentURL: currentURL,
            replacedApplicationURL: replacedURL,
            journal: &journal,
            journalURL: journalURL,
            swapApplications: { first, second in
                XCTAssertEqual(first, replacedURL)
                XCTAssertEqual(second, currentURL)
                swap(&installedVersion, &replacementVersion)
                swapCount += 1
            },
            persistJournal: { value, url in
                XCTAssertEqual(url, journalURL)
                persistedStages.append(value.stage)
                if value.stage == .swapped {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
            }
        )) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(ENOSPC))
        }

        XCTAssertEqual(swapCount, 2)
        XCTAssertEqual(installedVersion, "old")
        XCTAssertEqual(replacementVersion, "new")
        XCTAssertEqual(journal.stage, .rolledBack)
        XCTAssertEqual(persistedStages, [.swapped, .rolledBack])
    }

    func testJournalAndReverseSwapFailureRecordsFailedTransaction() throws {
        let root = fixtureRoot("swap-and-rollback-failure")
        let currentURL = root.appendingPathComponent("LumaChat.app", isDirectory: true)
        let replacedURL = root.appendingPathComponent(".replacement.app", isDirectory: true)
        let journalURL = root.appendingPathComponent("journal.json", isDirectory: false)
        var swapCount = 0
        var persistedStages: [LumaUpdateJournalStage] = []
        var journal = sampleJournal(
            currentURL: currentURL,
            candidateURL: replacedURL,
            journalURL: journalURL
        )

        XCTAssertThrowsError(try LumaUpdateInstaller.performAtomicSwapAndPersist(
            currentURL: currentURL,
            replacedApplicationURL: replacedURL,
            journal: &journal,
            journalURL: journalURL,
            swapApplications: { _, _ in
                swapCount += 1
                if swapCount == 2 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
            },
            persistJournal: { value, _ in
                persistedStages.append(value.stage)
                if value.stage == .swapped {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
            }
        )) { error in
            XCTAssertEqual(
                error as? LumaUpdateError,
                .processFailure("automatic rollback failed")
            )
        }

        XCTAssertEqual(swapCount, 2)
        XCTAssertEqual(journal.stage, .failed)
        XCTAssertEqual(
            journal.failure,
            "automatic rollback could not restore the previous application"
        )
        XCTAssertEqual(persistedStages, [.swapped, .failed])
    }

    func testSignedEnvelopeVerifiesExactPayloadAndRejectsTamperingAndUnknownFields() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let release = sampleRelease()
        let payload = try encoded(release)
        let signature = try privateKey.signature(for: payload)
        let envelope = LumaUpdateManifestEnvelope(
            payload: payload.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        let envelopeData = try encoded(envelope)
        let verified = try LumaUpdateManifestVerifier.verify(
            envelopeData: envelopeData,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedBundleIdentifier: "com.lumachat.desktop",
            currentArchitecture: "arm64",
            currentSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 6,
                patchVersion: 0
            )
        )
        XCTAssertEqual(verified.release, release)
        XCTAssertEqual(verified.payloadData, payload)

        var tamperedEnvelope = envelope
        var tamperedPayload = payload
        tamperedPayload[tamperedPayload.startIndex] ^= 0x01
        tamperedEnvelope.payload = tamperedPayload.base64EncodedString()
        XCTAssertThrowsError(try LumaUpdateManifestVerifier.verify(
            envelopeData: encoded(tamperedEnvelope),
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedBundleIdentifier: "com.lumachat.desktop",
            currentArchitecture: "arm64"
        )) { error in
            XCTAssertEqual(error as? LumaUpdateError, .invalidSignature)
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        )
        object["fallbackURL"] = "https://attacker.invalid/update"
        let unknownFieldEnvelope = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try LumaUpdateManifestVerifier.verify(
            envelopeData: unknownFieldEnvelope,
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedBundleIdentifier: "com.lumachat.desktop",
            currentArchitecture: "arm64"
        ))
    }

    func testManifestRejectsDowngradeShapeWrongArchitectureHTTPAndNotarizationOptOut() throws {
        let key = Curve25519.Signing.PrivateKey()
        for mutation in 0..<4 {
            var release = sampleRelease()
            switch mutation {
            case 0: release.architectures = ["x86_64"]
            case 1: release.archiveURL = "http://updates.example.test/LumaChat.zip"
            case 2: release.notarized = false
            default: release.version = "01.4.1"
            }
            let payload = try encoded(release)
            let signature = try key.signature(for: payload)
            let envelope = LumaUpdateManifestEnvelope(
                payload: payload.base64EncodedString(),
                signature: signature.base64EncodedString()
            )
            XCTAssertThrowsError(try LumaUpdateManifestVerifier.verify(
                envelopeData: encoded(envelope),
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                expectedBundleIdentifier: "com.lumachat.desktop",
                currentArchitecture: "arm64"
            ))
        }
        XCTAssertLessThan(try LumaSemanticVersion("1.4.0"), try LumaSemanticVersion("1.4.1"))
        XCTAssertEqual(try LumaSemanticVersion("1.4"), try LumaSemanticVersion("1.4.0"))
    }

    func testCanonicalApplicationTreeDigestChangesWithContentAndMode() throws {
        let root = fixtureRoot("tree-digest")
        let first = root.appendingPathComponent("A.app", isDirectory: true)
        let second = root.appendingPathComponent("B.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let firstFile = first.appendingPathComponent("Contents/MacOS/LumaChat")
        let secondFile = second.appendingPathComponent("Contents/MacOS/LumaChat")
        XCTAssertTrue(FileManager.default.createFile(atPath: firstFile.path, contents: Data("same".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: secondFile.path, contents: Data("same".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: firstFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secondFile.path)
        XCTAssertEqual(
            try LumaUpdateFileSecurity.applicationTreeSHA256(at: first),
            try LumaUpdateFileSecurity.applicationTreeSHA256(at: second)
        )
        try Data("changed".utf8).write(to: secondFile)
        XCTAssertNotEqual(
            try LumaUpdateFileSecurity.applicationTreeSHA256(at: first),
            try LumaUpdateFileSecurity.applicationTreeSHA256(at: second)
        )
    }

    func testAppleDoubleCleanupRefusesAndPreservesEntireOwnedTree() throws {
        let root = fixtureRoot("appledouble")
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let metadata = owned.appendingPathComponent("._must-remain")
        XCTAssertTrue(FileManager.default.createFile(atPath: metadata.path, contents: Data("keep".utf8)))
        XCTAssertThrowsError(try LumaUpdateFileSecurity.removeOwnedTreeIfSafe(
            owned,
            requiredParent: root
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testExistingSettingsDecodeDefaultsAndSecureStorageIsInjectable() throws {
        let root = fixtureRoot("state")
        let preferencesURL = root.appendingPathComponent("preferences.json")
        let stateURL = root.appendingPathComponent("state.json")
        let journalURL = root.appendingPathComponent("journal.json")
        try AtomicFileWriter.write(
            Data(#"{"automaticallyChecksForUpdates":false}"#.utf8),
            to: preferencesURL
        )
        try AtomicFileWriter.write(Data(#"{}"#.utf8), to: stateURL)
        let store = LumaUpdateStateStore(
            preferencesURL: preferencesURL,
            stateURL: stateURL,
            journalURL: journalURL
        )
        XCTAssertFalse(try store.loadPreferences().automaticallyChecksForUpdates)
        XCTAssertNil(try store.loadState().preparedUpdate)

        let backend = InMemorySecureStorageBackend()
        let keychain = KeychainStore(service: "PhaseH.Tests", backend: backend)
        try keychain.save("secret", account: "model")
        XCTAssertEqual(try keychain.load(account: "model"), "secret")
        try keychain.delete(account: "model")
        XCTAssertNil(try keychain.load(account: "model"))
    }

    func testUnavailableSandboxFailsClosedBeforeProcessCreation() throws {
        let root = fixtureRoot("sandbox")
        let workspace = AgentWorkspace(
            name: "Phase H",
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let backend = UnavailableSandboxBackend(identifier: "linux-unconfigured")
        XCTAssertThrowsError(try backend.makeWorkspacePolicy(
            validator: WorkspaceSecurityValidator(workspace: workspace),
            additionalReadOnlyRoots: []
        )) { error in
            guard case TerminalSessionError.sandboxUnavailable = error else {
                return XCTFail("Expected fail-closed unavailable sandbox, got \(error)")
            }
        }
    }

    private func sampleRelease() -> LumaUpdateRelease {
        LumaUpdateRelease(
            releaseID: UUID(uuidString: "5A702EDA-9C61-47CF-A8AA-5B3C39005865")!,
            version: "1.5.0",
            build: 8,
            publishedAt: "2026-09-14T00:00:00Z",
            minimumSystemVersion: "14.0",
            archiveURL: "https://updates.example.test/LumaChat-1.5.0-arm64.zip",
            archiveSHA256: String(repeating: "a", count: 64),
            archiveSize: 1_024,
            applicationSHA256: String(repeating: "b", count: 64),
            bundleIdentifier: "com.lumachat.desktop",
            teamIdentifier: "ABCDE12345",
            architectures: ["arm64"],
            notarized: true,
            releaseNotesURL: "https://updates.example.test/releases/1.5.0"
        )
    }

    private var updateConfiguration: LumaUpdateTrustConfiguration {
        LumaUpdateTrustConfiguration(
            feedURL: URL(string: "https://updates.example.test/feed.json")!,
            publicKeyBase64: Data(repeating: 7, count: 32).base64EncodedString(),
            teamIdentifier: "ABCDE12345",
            bundleIdentifier: "com.lumachat.desktop"
        )
    }

    private func offlineSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhaseHUpdateOfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func encodedFailedJournal() throws -> Data {
        let root = fixtureRoot("encoded-failed-journal")
        var journal = sampleJournal(
            currentURL: root.appendingPathComponent("current.app"),
            candidateURL: root.appendingPathComponent("candidate.app"),
            journalURL: root.appendingPathComponent("journal.json")
        )
        journal.stage = .failed
        journal.failure = "injected failure"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(journal)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func prepareLaunchConfirmationFixture(root: URL) throws -> (
        store: LumaUpdateStateStore,
        previousState: LumaUpdatePersistentState,
        journal: LumaUpdateJournal,
        runningBundle: Bundle,
        confirmationURL: URL
    ) {
        let store = LumaUpdateStateStore(
            preferencesURL: root.appendingPathComponent("preferences.json"),
            stateURL: root.appendingPathComponent("state.json"),
            journalURL: root.appendingPathComponent("journal.json")
        )
        let previousState = LumaUpdatePersistentState(
            availableRelease: sampleRelease(),
            availableEnvelopeBase64: Data("signed envelope".utf8).base64EncodedString()
        )
        try store.saveState(previousState)
        let runningBundle = try makeBundle(
            root: root,
            name: "LumaChat.app",
            version: "1.5.0",
            build: 8
        )
        var journal = sampleJournal(
            currentURL: runningBundle.bundleURL,
            candidateURL: root.appendingPathComponent("candidate.app", isDirectory: true),
            journalURL: root.appendingPathComponent("journal.json")
        )
        journal.stage = .launchRequested
        try store.saveJournal(journal)
        return (
            store,
            previousState,
            journal,
            runningBundle,
            URL(fileURLWithPath: journal.confirmationPath, isDirectory: false)
        )
    }

    private func sampleJournal(
        currentURL: URL,
        candidateURL: URL,
        journalURL: URL
    ) -> LumaUpdateJournal {
        LumaUpdateJournal(
            operation: .install,
            installationID: UUID(),
            stage: .backupCreated,
            fromVersion: "1.4.0",
            fromBuild: 7,
            toVersion: "1.5.0",
            toBuild: 8,
            currentApplicationPath: currentURL.path,
            candidateApplicationPath: candidateURL.path,
            backupApplicationPath: currentURL
                .deletingLastPathComponent()
                .appendingPathComponent("LumaChat-backup.app", isDirectory: true).path,
            confirmationPath: journalURL
                .deletingLastPathComponent()
                .appendingPathComponent("confirmed.txt", isDirectory: false).path,
            expectedBundleIdentifier: "com.lumachat.desktop",
            expectedTeamIdentifier: "ABCDE12345"
        )
    }

    private func fixtureRoot(_ name: String) -> URL {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("phase-h-update-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBundle(
        root: URL,
        name: String,
        version: String,
        build: Int
    ) throws -> Bundle {
        let application = root.appendingPathComponent(name, isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.lumachat.desktop",
            "CFBundleName": "LumaChat",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build)
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try AtomicFileWriter.write(data, to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: application))
    }
}
