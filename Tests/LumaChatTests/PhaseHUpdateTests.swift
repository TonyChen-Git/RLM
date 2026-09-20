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

final class PhaseHUpdateTests: XCTestCase {
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

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
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
}
