import Foundation
import XCTest
@testable import LumaChat

final class WorktreeStateRecoveryStoreTests: XCTestCase {
    func testRoundTripAndExactRemoval() async throws {
        let root = try makeRoot("round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeStateRecoveryStore(root: root)
        let transactionID = UUID()
        let snapshot = makeSnapshot(sourceRoot: "/tmp/lumachat-source")

        let reference = try await store.save(
            snapshot: snapshot,
            transactionID: transactionID
        )

        XCTAssertEqual(reference.transactionID, transactionID)
        XCTAssertEqual(
            reference.relativePath,
            transactionID.uuidString.lowercased() + ".snapshot"
        )
        XCTAssertEqual(reference.snapshotFingerprint, snapshot.fingerprint)
        XCTAssertEqual(reference.sha256.count, 64)
        let loaded = try await store.load(reference)
        XCTAssertEqual(loaded, snapshot)

        try await store.remove(reference)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(reference.relativePath).path
            )
        )
        // Crash recovery cleanup is intentionally idempotent.
        try await store.remove(reference)
    }

    func testLoadRejectsTamperedPayloadBeforeDecoding() async throws {
        let root = try makeRoot("tamper")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeStateRecoveryStore(root: root)
        let reference = try await store.save(
            snapshot: makeSnapshot(sourceRoot: "/tmp/lumachat-source"),
            transactionID: UUID()
        )
        let file = root.appendingPathComponent(reference.relativePath)
        var data = try Data(contentsOf: file)
        XCTAssertFalse(data.isEmpty)
        data[data.startIndex] ^= 0xff
        try data.write(to: file, options: .atomic)

        do {
            _ = try await store.load(reference)
            XCTFail("A payload with a different digest must not decode.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .integrityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await store.remove(reference)
            XCTFail("Removal must not unlink content that no longer matches the reference.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .integrityMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testLoadRejectsSymlinkAtTransactionFilename() async throws {
        let root = try makeRoot("file-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeStateRecoveryStore(root: root)
        let reference = try await store.save(
            snapshot: makeSnapshot(sourceRoot: "/tmp/lumachat-source"),
            transactionID: UUID()
        )
        let file = root.appendingPathComponent(reference.relativePath)
        let unrelated = root.appendingPathComponent("unrelated")
        try Data("unrelated".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: unrelated
        )

        do {
            _ = try await store.load(reference)
            XCTFail("Recovery reads must not follow a transaction-file symlink.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .invalidStorage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSaveRejectsSymlinkInStorageRoot() async throws {
        let container = try makeRoot("root-symlink")
        defer { try? FileManager.default.removeItem(at: container) }
        let actual = container.appendingPathComponent("actual", isDirectory: true)
        let linked = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        let store = WorktreeStateRecoveryStore(root: linked)

        do {
            _ = try await store.save(
                snapshot: makeSnapshot(sourceRoot: "/tmp/lumachat-source"),
                transactionID: UUID()
            )
            XCTFail("A linked recovery root must be rejected.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .invalidStorage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSaveEnforcesConfiguredEncodedByteBound() async throws {
        let root = try makeRoot("oversized")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeStateRecoveryStore(root: root, maximumEncodedBytes: 256)

        do {
            _ = try await store.save(
                snapshot: makeSnapshot(sourceRoot: "/tmp/lumachat-source"),
                transactionID: UUID()
            )
            XCTFail("The encoded recovery payload must remain bounded.")
        } catch let error as WorktreeStateRecoveryStoreError {
            XCTAssertEqual(error, .oversized(256))
        }
    }

    func testSaveRejectsUnsafeManifestAndReferenceTraversal() async throws {
        let root = try makeRoot("unsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorktreeStateRecoveryStore(root: root)
        let unsafeData = Data("escape".utf8)
        let unsafe = WorktreeStateSnapshot(
            sourceRootPath: "/tmp/lumachat-source",
            headObjectID: String(repeating: "a", count: 40),
            workingTreePatch: Data(),
            stagedPatch: Data(),
            supplementalFiles: [
                WorktreeSupplementalFile(
                    relativePath: "../escape",
                    data: unsafeData,
                    permissions: 0o600
                )
            ],
            supplementalManifest: [
                WorktreeSupplementalPath(
                    relativePath: "../escape",
                    kind: .regularFile,
                    data: unsafeData,
                    permissions: 0o600
                )
            ],
            supplementalRoots: ["../escape"]
        )

        do {
            _ = try await store.save(snapshot: unsafe, transactionID: UUID())
            XCTFail("Traversal in a supplemental manifest must be rejected.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .invalidSnapshot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let validReference = try await store.save(
            snapshot: makeSnapshot(sourceRoot: "/tmp/lumachat-source"),
            transactionID: UUID()
        )
        var traversingReference = validReference
        traversingReference.relativePath = "../" + validReference.relativePath
        do {
            _ = try await store.load(traversingReference)
            XCTFail("A journal reference must not select an arbitrary path.")
        } catch let error as WorktreeStateRecoveryStoreError {
            guard case .invalidReference = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "recovery-store-\(label)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSnapshot(sourceRoot: String) -> WorktreeStateSnapshot {
        let payload = Data([0x00, 0x7f, 0xff, 0x42])
        return WorktreeStateSnapshot(
            sourceRootPath: sourceRoot,
            headObjectID: String(repeating: "a", count: 40),
            symbolicReference: "refs/heads/luma/recovery-test",
            workingTreePatch: Data("working patch".utf8),
            stagedPatch: Data("staged patch".utf8),
            supplementalFiles: [
                WorktreeSupplementalFile(
                    relativePath: "cache/value.bin",
                    data: payload,
                    permissions: 0o640
                )
            ],
            supplementalManifest: [
                WorktreeSupplementalPath(
                    relativePath: "cache",
                    kind: .directory,
                    data: nil,
                    permissions: 0o750
                ),
                WorktreeSupplementalPath(
                    relativePath: "cache/value.bin",
                    kind: .regularFile,
                    data: payload,
                    permissions: 0o640
                ),
                WorktreeSupplementalPath(
                    relativePath: "missing.txt",
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            ],
            supplementalRoots: ["cache", "missing.txt"]
        )
    }
}
