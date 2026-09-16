import Darwin
import Foundation
import XCTest

@testable import LumaChat

final class RemoteWorkspaceMigrationTests: XCTestCase {
    func testWireSnapshotCarriesOnlyBoundedWorkspaceStateAndRunnerIdentityStaysInBinding() throws {
        let runnerID = UUID()
        let snapshot = makeRemoteSnapshot(
            nodes: [
                RemoteWorkspaceStateNode(
                    relativePath: "notes.txt",
                    kind: .regularFile,
                    data: Data("note\n".utf8),
                    permissions: 0o600
                )
            ],
            roots: ["notes.txt"]
        )

        let data = try JSONEncoder().encode(snapshot.validated())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "headObjectID",
            "sourceRootPath",
            "stagedPatch",
            "supplementalManifest",
            "supplementalRoots",
            "symbolicReference",
            "workingTreePatch"
        ])
        for forbidden in [
            "runnerID", "host", "port", "username", "credential",
            "backend", "provider", "model", "modelID", "destinationRoot"
        ] {
            XCTAssertNil(object[forbidden], "Migration wire leaked authority field \(forbidden).")
        }

        let location = AgentExecutionLocation.ssh(
            runnerID: runnerID,
            label: "Builder display label"
        )
        let decoded = try JSONDecoder().decode(
            AgentExecutionLocation.self,
            from: JSONEncoder().encode(location)
        )
        XCTAssertEqual(decoded.kind, .ssh)
        XCTAssertEqual(decoded.remoteRunnerID, runnerID)
        XCTAssertNil(decoded.managedWorktreeID)
        XCTAssertEqual(decoded.label, "Builder display label")
    }

    func testSnapshotValidationRejectsAppleDoubleAndGitAdministrativePaths() throws {
        for path in ["._metadata", "cache/._entry", ".git", ".git/config", "a/.git/b"] {
            var asRoot = makeRemoteSnapshot(roots: [path])
            XCTAssertThrowsError(try asRoot.validated(), path) { error in
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }

            asRoot.supplementalRoots = []
            asRoot.supplementalManifest = [
                RemoteWorkspaceStateNode(
                    relativePath: path,
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            ]
            XCTAssertThrowsError(try asRoot.validated(), path) { error in
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }
        }
    }

    func testSnapshotValidationRejectsDuplicatePathsAndEncodedPayloadBeyondFourMiB() throws {
        let duplicateRoots = makeRemoteSnapshot(
            roots: ["artifacts/result.json", "artifacts/result.json"]
        )
        XCTAssertThrowsError(try duplicateRoots.validated()) { error in
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            XCTAssertTrue(error.localizedDescription.contains("duplicate supplemental roots"))
        }

        let duplicateNodes = makeRemoteSnapshot(
            nodes: [
                RemoteWorkspaceStateNode(
                    relativePath: "output.txt",
                    kind: .absent,
                    data: nil,
                    permissions: nil
                ),
                RemoteWorkspaceStateNode(
                    relativePath: "output.txt",
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            ]
        )
        XCTAssertThrowsError(try duplicateNodes.validated()) { error in
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            XCTAssertTrue(error.localizedDescription.contains("duplicate manifest paths"))
        }

        // Three MiB is within the logical content ceiling, but base64 plus the
        // JSON envelope is larger than the independent four-MiB wire ceiling.
        let oversizedWire = makeRemoteSnapshot(
            workingPatch: Data(
                repeating: 0x5A,
                count: RemoteWorkspaceStateSnapshot.maximumContentBytes
            )
        )
        XCTAssertThrowsError(try oversizedWire.validated()) { error in
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            XCTAssertTrue(error.localizedDescription.contains("4 MiB"))
        }
    }

    func testPreparationRequiresCleanSameHEADAndBackendRollbackUsesExactAppliedState() async throws {
        let fixture = try makeRepository("service-contract")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("dirty tracked\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )
        try Data("untracked\n".utf8).write(
            to: fixture.repository.appendingPathComponent("notes.txt")
        )

        let service = RemoteWorkspaceMigrationService(
            localMigrator: WorktreeStateMigrator(
                temporaryRoot: fixture.root.appendingPathComponent("scratch")
            )
        )
        let runnerID = UUID()
        let dirtyBackend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(
                head: fixture.head,
                workingPatch: Data("not clean".utf8)
            )
        )
        do {
            _ = try await service.prepareLocalToRemote(
                sourceRoot: fixture.repository,
                supplementalPaths: ["notes.txt"],
                backend: dirtyBackend
            )
            XCTFail("A dirty remote destination was accepted.")
        } catch WorktreeStateMigrationError.targetNotClean(let path) {
            XCTAssertEqual(path, "/srv/luma")
        }

        let mismatchedBackend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: String(repeating: "b", count: 40))
        )
        do {
            _ = try await service.prepareLocalToRemote(
                sourceRoot: fixture.repository,
                supplementalPaths: ["notes.txt"],
                backend: mismatchedBackend
            )
            XCTFail("A different remote HEAD was accepted.")
        } catch WorktreeStateMigrationError.revisionMismatch(let source, let target) {
            XCTAssertEqual(source, fixture.head)
            XCTAssertEqual(target, String(repeating: "b", count: 40))
        }

        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: fixture.head)
        )
        let preparation = try await service.prepareLocalToRemote(
            sourceRoot: fixture.repository,
            supplementalPaths: ["notes.txt"],
            backend: backend
        )
        XCTAssertTrue(preparation.remoteBaseline.isClean)
        XCTAssertEqual(preparation.desired.headObjectID, preparation.remoteBaseline.headObjectID)
        XCTAssertEqual(preparation.remoteCaptureReceipt.runnerID, runnerID)
        XCTAssertTrue(preparation.desired.supplementalRoots.contains("notes.txt"))

        let transactionID = UUID()
        let applied = try await backend.applyWorkspaceState(
            preparation.desired,
            expectedBaseline: preparation.remoteBaseline,
            transactionID: transactionID
        )
        XCTAssertEqual(applied.direction, .localToRemote)
        XCTAssertEqual(applied.snapshotFingerprint, preparation.desired.fingerprint)
        XCTAssertEqual(applied.operation.runnerID, runnerID)
        let stateAfterApply = await backend.currentSnapshot()
        XCTAssertFalse(stateAfterApply.isClean)

        let rolledBack = try await backend.rollbackWorkspaceState(
            expectedApplied: preparation.desired,
            restoring: preparation.remoteBaseline,
            transactionID: transactionID
        )
        XCTAssertEqual(rolledBack.direction, .rollbackRemote)
        XCTAssertEqual(rolledBack.snapshotFingerprint, preparation.desired.fingerprint)
        let stateAfterRollback = await backend.currentSnapshot()
        XCTAssertTrue(stateAfterRollback.isClean)

        let repeatedRollback = try await backend.rollbackWorkspaceState(
            expectedApplied: preparation.desired,
            restoring: preparation.remoteBaseline,
            transactionID: transactionID
        )
        XCTAssertEqual(repeatedRollback.direction, .rollbackRemote)
        XCTAssertEqual(repeatedRollback.snapshotFingerprint, preparation.desired.fingerprint)
        let stateAfterRepeatedRollback = await backend.currentSnapshot()
        XCTAssertEqual(stateAfterRepeatedRollback.fingerprint, preparation.remoteBaseline.fingerprint)

        let rollbackOperations = await backend.operations()
        XCTAssertEqual(rollbackOperations, ["capture", "apply", "rollback", "rollback"])
        let transactions = await backend.transactions()
        XCTAssertEqual(transactions, [
            RemoteWorkspaceBackendTransaction(
                operation: .apply,
                transactionID: transactionID,
                desiredFingerprint: preparation.desired.fingerprint,
                baselineFingerprint: preparation.remoteBaseline.fingerprint
            ),
            RemoteWorkspaceBackendTransaction(
                operation: .rollback,
                transactionID: transactionID,
                desiredFingerprint: preparation.desired.fingerprint,
                baselineFingerprint: preparation.remoteBaseline.fingerprint
            ),
            RemoteWorkspaceBackendTransaction(
                operation: .rollback,
                transactionID: transactionID,
                desiredFingerprint: preparation.desired.fingerprint,
                baselineFingerprint: preparation.remoteBaseline.fingerprint
            )
        ])
    }

    func testRollbackRefusesAThirdRemoteState() async throws {
        let runnerID = UUID()
        let head = String(repeating: "a", count: 40)
        let baseline = makeRemoteSnapshot(head: head)
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: baseline
        )
        let applied = makeRemoteSnapshot(
            head: head,
            workingPatch: Data("first state".utf8)
        )
        let transactionID = UUID()
        _ = try await backend.applyWorkspaceState(
            applied,
            expectedBaseline: baseline,
            transactionID: transactionID
        )
        await backend.replaceCurrentForTest(
            makeRemoteSnapshot(
                root: "/srv/luma",
                head: head,
                workingPatch: Data("third state".utf8)
            )
        )

        do {
            _ = try await backend.rollbackWorkspaceState(
                expectedApplied: applied,
                restoring: baseline,
                transactionID: transactionID
            )
            XCTFail("Rollback overwrote an unrecognized third state.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .protocolViolation)
        }
        let retainedThirdState = await backend.currentSnapshot()
        XCTAssertEqual(retainedThirdState.workingTreePatch, Data("third state".utf8))
    }

    func testRemoteJournalTransitionsRoundTripAllOrderedStages() async throws {
        let root = makeTestRoot("journal-remote-stages")
        defer { cleanupPreservingAppleDouble(root) }
        let journal = AgentTaskHandoffJournal(root: root)
        let runnerID = UUID()
        let desiredFingerprint = String(repeating: "d", count: 64)
        let baseline = makeRemoteSnapshot(
            root: "/srv/luma",
            head: String(repeating: "a", count: 40)
        )
        let baselineFingerprint = baseline.fingerprint
        let configuration = makeRemoteConfiguration(id: runnerID)
        let identity = AgentRemoteExecutionIdentity(
            runnerID: runnerID,
            backendLabel: "SSH · fake test backend",
            host: configuration.host,
            port: configuration.port,
            user: configuration.username,
            workspaceRoot: configuration.workspaceRoot,
            configurationFingerprint: try configuration.executionConfigurationFingerprint()
        )

        var local = AgentSession(mode: .agent)
        local.workspace = makeWorkspace("local", root: "/repo/local")
        local.executionLocation = .local
        local.projectFolderID = UUID()
        let toRemoteID = UUID()
        let desiredReference = makeRecoveryReference(
            transactionID: toRemoteID,
            snapshotFingerprint: desiredFingerprint
        )
        var toRemote = try await journal.beginHandoffToRemote(
            session: local,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            desiredSnapshot: desiredReference,
            remoteBaselineFingerprint: baselineFingerprint,
            remoteBaselineSnapshot: baseline,
            remoteExecutionIdentity: identity,
            id: toRemoteID,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(toRemote.resolvedTransitionKind, .handoffToRemote)
        XCTAssertEqual(toRemote.stage, .prepared)
        XCTAssertEqual(toRemote.recoverySnapshot, desiredReference)
        XCTAssertEqual(toRemote.remoteBaselineSnapshot, baseline)
        XCTAssertEqual(toRemote.remoteExecutionIdentity, identity)

        let remoteWorkspace = makeWorkspace("builder", root: "/srv/luma")
        toRemote = try await journal.markDestinationAllocated(
            toRemote,
            binding: makeBinding(
                workspace: remoteWorkspace,
                location: .ssh(runnerID: runnerID, label: "Builder"),
                localWorkspace: local.workspace,
                localProjectFolderID: local.projectFolderID
            ),
            createdWorktreeID: nil,
            now: Date(timeIntervalSince1970: 11)
        )
        XCTAssertEqual(toRemote.stage, .destinationAllocated)
        XCTAssertEqual(toRemote.to?.location.remoteRunnerID, runnerID)
        toRemote = try await journal.markDestinationReady(
            toRemote,
            now: Date(timeIntervalSince1970: 12)
        )
        XCTAssertEqual(toRemote.stage, .destinationReady)
        toRemote = try await journal.markSessionCommitted(
            toRemote,
            now: Date(timeIntervalSince1970: 13)
        )
        XCTAssertEqual(toRemote.stage, .sessionCommitted)

        var remote = local
        remote.workspace = remoteWorkspace
        remote.executionLocation = .ssh(runnerID: runnerID, label: "Builder")
        remote.projectFolderID = nil
        remote.localWorkspace = local.workspace
        remote.localProjectFolderID = local.projectFolderID
        let fromRemoteID = UUID()
        let rollbackReference = makeRecoveryReference(
            transactionID: fromRemoteID,
            snapshotFingerprint: baselineFingerprint
        )
        var fromRemote = try await journal.beginHandoffFromRemote(
            session: remote,
            localRecoverySnapshot: rollbackReference,
            desiredDestinationFingerprint: desiredFingerprint,
            id: fromRemoteID,
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(fromRemote.resolvedTransitionKind, .handoffFromRemote)
        XCTAssertEqual(fromRemote.stage, .prepared)
        fromRemote = try await journal.markDestinationAllocated(
            fromRemote,
            binding: makeBinding(
                workspace: local.workspace!,
                location: .local,
                projectFolderID: local.projectFolderID
            ),
            createdWorktreeID: nil,
            now: Date(timeIntervalSince1970: 21)
        )
        fromRemote = try await journal.markDestinationReady(
            fromRemote,
            now: Date(timeIntervalSince1970: 22)
        )
        fromRemote = try await journal.markSessionCommitted(
            fromRemote,
            now: Date(timeIntervalSince1970: 23)
        )

        let pending = try await journal.pendingEntries()
        XCTAssertEqual(pending, [toRemote, fromRemote])
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentTaskHandoffJournalEntry.self,
                from: JSONEncoder().encode(toRemote)
            ),
            toRemote
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentTaskHandoffJournalEntry.self,
                from: JSONEncoder().encode(fromRemote)
            ),
            fromRemote
        )
    }

    func testRemoteJournalRejectsWrongDestinationKindsAndLegacyEntryStillDecodes() async throws {
        let root = makeTestRoot("journal-compatibility")
        defer { cleanupPreservingAppleDouble(root) }
        let journal = AgentTaskHandoffJournal(root: root)
        var session = AgentSession(mode: .agent)
        session.workspace = makeWorkspace("local", root: "/repo/local")
        session.executionLocation = .local
        let transactionID = UUID()
        let runnerID = UUID()
        let baseline = makeRemoteSnapshot(
            root: "/srv/luma",
            head: String(repeating: "a", count: 40)
        )
        let configuration = makeRemoteConfiguration(id: runnerID)
        let identity = AgentRemoteExecutionIdentity(
            runnerID: runnerID,
            backendLabel: "SSH · fake test backend",
            host: configuration.host,
            port: configuration.port,
            user: configuration.username,
            workspaceRoot: configuration.workspaceRoot,
            configurationFingerprint: try configuration.executionConfigurationFingerprint()
        )
        var toRemote = try await journal.beginHandoffToRemote(
            session: session,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            desiredSnapshot: makeRecoveryReference(
                transactionID: transactionID,
                snapshotFingerprint: String(repeating: "d", count: 64)
            ),
            remoteBaselineFingerprint: baseline.fingerprint,
            remoteBaselineSnapshot: baseline,
            remoteExecutionIdentity: identity,
            id: transactionID
        )
        do {
            toRemote = try await journal.markDestinationAllocated(
                toRemote,
                binding: makeBinding(
                    workspace: makeWorkspace("wrong", root: "/repo/wrong"),
                    location: .local
                ),
                createdWorktreeID: nil
            )
            XCTFail("A Local binding was accepted as a Remote destination: \(toRemote)")
        } catch AgentTaskHandoffJournalError.invalidEntry {
            // Expected.
        }

        let legacy = AgentTaskHandoffJournalEntry(
            id: UUID(),
            transitionKind: .handoff,
            sourceSessionID: nil,
            sessionID: session.id,
            from: makeBinding(workspace: session.workspace!, location: .local),
            to: nil,
            plannedWorktreeID: nil,
            createdWorktreeID: nil,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            recoverySnapshot: nil,
            expectedDestinationFingerprint: nil,
            desiredDestinationFingerprint: nil,
            stage: .prepared,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacy)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "transitionKind")
        legacyObject.removeValue(forKey: "sourceSessionID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(
            AgentTaskHandoffJournalEntry.self,
            from: legacyData
        )

        XCTAssertNil(decoded.transitionKind)
        XCTAssertNil(decoded.sourceSessionID)
        XCTAssertNil(decoded.remoteBaselineSnapshot)
        XCTAssertNil(decoded.remoteExecutionIdentity)
        XCTAssertEqual(decoded.resolvedTransitionKind, .handoff)
        XCTAssertEqual(decoded.stage, .prepared)
        XCTAssertEqual(decoded.from.location, .local)
    }

    @MainActor
    func testRestartRecoveryRollsBackDestinationReadyRemoteHandoff() async throws {
        let fixture = try makeRepository("restart-destination-ready-rollback")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("applied before restart\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )
        let staged = try await stageDestinationReadyRemoteHandoff(
            root: fixture.root,
            repository: fixture.repository
        )
        XCTAssertEqual(staged.entry.stage, .destinationReady)
        let sessionStore = RemoteHandoffSessionStore([staged.sourceSession])
        let reopenedHandoffs = AgentTaskHandoffJournal(root: staged.journalRoot)
        let reopenedRecovery = WorktreeStateRecoveryStore(root: staged.recoveryRoot)
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: RemoteMigrationRunnerService(
                configuration: staged.configuration,
                backend: staged.backend
            ),
            handoffs: reopenedHandoffs,
            recovery: reopenedRecovery
        )

        try await harness.viewModel.restoreProjectCatalogState()

        let operations = await staged.backend.operations()
        let transactions = await staged.backend.transactions()
        let remoteState = await staged.backend.currentSnapshot()
        let pending = try await reopenedHandoffs.pendingEntries()
        let persisted = await sessionStore.session(id: staged.sourceSession.id)
        XCTAssertEqual(operations, ["apply", "rollback"])
        XCTAssertEqual(transactions, [
            RemoteWorkspaceBackendTransaction(
                operation: .apply,
                transactionID: staged.entry.id,
                desiredFingerprint: staged.desired.fingerprint,
                baselineFingerprint: staged.baseline.fingerprint
            ),
            RemoteWorkspaceBackendTransaction(
                operation: .rollback,
                transactionID: staged.entry.id,
                desiredFingerprint: staged.desired.fingerprint,
                baselineFingerprint: staged.baseline.fingerprint
            )
        ])
        XCTAssertTrue(remoteState.isClean)
        XCTAssertEqual(remoteState.fingerprint, staged.baseline.fingerprint)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(persisted?.resolvedExecutionLocation, .local)
        XCTAssertFalse(
            harness.viewModel.recoveryBlockedSessionIDs.contains(staged.sourceSession.id)
        )
        XCTAssertFalse(
            harness.viewModel.recoveryBlockedRemoteRunnerIDs.contains(
                staged.configuration.id
            )
        )
        do {
            _ = try await reopenedRecovery.load(staged.reference)
            XCTFail("Completed restart rollback retained its recovery snapshot.")
        } catch {
            XCTAssertTrue(error is WorktreeStateRecoveryStoreError)
        }
    }

    @MainActor
    func testUnreadableHandoffJournalFailsClosedForEveryRemoteRunner() async throws {
        let fixture = try makeRepository("restart-unreadable-handoff-journal")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        let runnerID = UUID()
        let configuration = makeRemoteConfiguration(id: runnerID)
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: configuration.workspaceRoot,
            initial: makeRemoteSnapshot()
        )
        let journalRoot = fixture.root.appendingPathComponent(
            "handoffs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalRoot,
            withIntermediateDirectories: true
        )
        try Data("{".utf8).write(
            to: journalRoot.appendingPathComponent(
                UUID().uuidString.lowercased() + ".json"
            )
        )
        let journal = AgentTaskHandoffJournal(root: journalRoot)
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: RemoteHandoffSessionStore([]),
            remoteService: RemoteMigrationRunnerService(
                configuration: configuration,
                backend: backend
            ),
            handoffs: journal
        )

        try await harness.viewModel.restoreProjectCatalogState()

        XCTAssertTrue(harness.viewModel.remoteHandoffRecoveryUnavailable)
        XCTAssertTrue(harness.viewModel.remoteRunnerIsInUse(runnerID))
        XCTAssertTrue(harness.viewModel.recoveryBlockedRemoteRunnerIDs.isEmpty)
        XCTAssertTrue(
            harness.viewModel.statusMessage?.contains("Handoff journal") == true
        )
        let operations = await backend.operations()
        XCTAssertTrue(operations.isEmpty)
    }

    @MainActor
    func testRestartRecoveryRefusesRunnerUUIDReboundToDifferentAuthority() async throws {
        let fixture = try makeRepository("restart-stale-runner-authority")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("must remain at original endpoint\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )
        let staged = try await stageDestinationReadyRemoteHandoff(
            root: fixture.root,
            repository: fixture.repository
        )
        let pinnedIdentity = try XCTUnwrap(staged.entry.remoteExecutionIdentity)
        var reboundConfiguration = staged.configuration
        reboundConfiguration.host = "replacement.example.test"
        reboundConfiguration.workspaceRoot = "/srv/replacement"
        let reboundFingerprint = try reboundConfiguration
            .executionConfigurationFingerprint()
        XCTAssertEqual(reboundConfiguration.id, pinnedIdentity.runnerID)
        XCTAssertNotEqual(
            reboundFingerprint,
            pinnedIdentity.configurationFingerprint
        )
        let reboundBackend = RemoteWorkspaceBackendProbe(
            runnerID: reboundConfiguration.id,
            remoteRoot: reboundConfiguration.workspaceRoot,
            initial: staged.desired
        )

        let sessionStore = RemoteHandoffSessionStore([staged.sourceSession])
        let reopenedHandoffs = AgentTaskHandoffJournal(root: staged.journalRoot)
        let reopenedRecovery = WorktreeStateRecoveryStore(root: staged.recoveryRoot)
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: RemoteMigrationRunnerService(
                configuration: reboundConfiguration,
                backend: reboundBackend
            ),
            handoffs: reopenedHandoffs,
            recovery: reopenedRecovery
        )

        try await harness.viewModel.restoreProjectCatalogState()

        let originalOperations = await staged.backend.operations()
        let originalTransactions = await staged.backend.transactions()
        let retainedRemote = await staged.backend.currentSnapshot()
        let reboundOperations = await reboundBackend.operations()
        let reboundTransactions = await reboundBackend.transactions()
        let untouchedRebound = await reboundBackend.currentSnapshot()
        let pending = try await reopenedHandoffs.pendingEntries()
        let retainedRecovery = try await reopenedRecovery.load(staged.reference)
        let persisted = await sessionStore.session(id: staged.sourceSession.id)
        XCTAssertEqual(originalOperations, ["apply"])
        XCTAssertEqual(originalTransactions.map(\.operation), [.apply])
        XCTAssertTrue(reboundOperations.isEmpty)
        XCTAssertTrue(reboundTransactions.isEmpty)
        XCTAssertEqual(retainedRemote.fingerprint, staged.desired.fingerprint)
        XCTAssertEqual(untouchedRebound.fingerprint, staged.desired.fingerprint)
        XCTAssertEqual(
            retainedRemote.sourceRootPath,
            staged.configuration.workspaceRoot
        )
        XCTAssertEqual(
            untouchedRebound.sourceRootPath,
            reboundConfiguration.workspaceRoot
        )
        XCTAssertEqual(retainedRecovery.fingerprint, staged.desired.fingerprint)
        XCTAssertEqual(pending, [staged.entry])
        XCTAssertEqual(persisted?.resolvedExecutionLocation, .local)
        XCTAssertTrue(
            harness.viewModel.recoveryBlockedSessionIDs.contains(staged.sourceSession.id)
        )
        XCTAssertTrue(
            harness.viewModel.recoveryBlockedRemoteRunnerIDs.contains(
                staged.configuration.id
            )
        )
        XCTAssertTrue(
            harness.viewModel.statusMessage?.contains(
                "Remote runner configuration changed"
            ) == true
        )
    }

    @MainActor
    func testLegacyDestinationReadyRemoteRecoveryMissingCapabilityFailsClosed() async throws {
        let fixture = try makeRepository("restart-legacy-missing-capability")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("legacy remote state must be retained\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )

        for missingBaselineSnapshot in [true, false] {
            let capability = missingBaselineSnapshot
                ? "remoteBaselineSnapshot"
                : "remoteExecutionIdentity"
            let caseRoot = fixture.root.appendingPathComponent(
                "missing-\(capability)",
                isDirectory: true
            )
            let staged = try await stageDestinationReadyRemoteHandoff(
                root: caseRoot,
                repository: fixture.repository
            )
            var legacyEntry = staged.entry
            if missingBaselineSnapshot {
                legacyEntry.remoteBaselineSnapshot = nil
            } else {
                legacyEntry.remoteExecutionIdentity = nil
            }
            let entryFile = staged.journalRoot.appendingPathComponent(
                legacyEntry.id.uuidString.lowercased() + ".json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(legacyEntry).write(to: entryFile, options: .atomic)

            let sessionStore = RemoteHandoffSessionStore([staged.sourceSession])
            let reopenedHandoffs = AgentTaskHandoffJournal(root: staged.journalRoot)
            let reopenedRecovery = WorktreeStateRecoveryStore(root: staged.recoveryRoot)
            let harness = makeViewModelHarness(
                root: caseRoot,
                sessionStore: sessionStore,
                remoteService: RemoteMigrationRunnerService(
                    configuration: staged.configuration,
                    backend: staged.backend
                ),
                handoffs: reopenedHandoffs,
                recovery: reopenedRecovery
            )

            try await harness.viewModel.restoreProjectCatalogState()

            let operations = await staged.backend.operations()
            let transactions = await staged.backend.transactions()
            let retainedRemote = await staged.backend.currentSnapshot()
            let pending = try await reopenedHandoffs.pendingEntries()
            let retainedRecovery = try await reopenedRecovery.load(staged.reference)
            let persisted = await sessionStore.session(id: staged.sourceSession.id)
            XCTAssertEqual(operations, ["apply"], capability)
            XCTAssertEqual(transactions.map(\.operation), [.apply], capability)
            XCTAssertEqual(
                retainedRemote.fingerprint,
                staged.desired.fingerprint,
                capability
            )
            XCTAssertEqual(
                retainedRecovery.fingerprint,
                staged.desired.fingerprint,
                capability
            )
            XCTAssertEqual(pending, [legacyEntry], capability)
            XCTAssertEqual(persisted?.resolvedExecutionLocation, .local, capability)
            XCTAssertEqual(
                pending.first?.remoteBaselineSnapshot == nil,
                missingBaselineSnapshot,
                capability
            )
            XCTAssertEqual(
                pending.first?.remoteExecutionIdentity == nil,
                !missingBaselineSnapshot,
                capability
            )
            XCTAssertTrue(
                harness.viewModel.recoveryBlockedSessionIDs.contains(
                    staged.sourceSession.id
                ),
                capability
            )
            XCTAssertTrue(
                harness.viewModel.recoveryBlockedRemoteRunnerIDs.contains(
                    staged.configuration.id
                ),
                capability
            )
            XCTAssertTrue(
                harness.viewModel.statusMessage?.contains(
                    "缺少 recovery capability"
                ) == true,
                capability
            )
        }
    }

    @MainActor
    func testCommittedRemoteRecoveryRecapturesFingerprintBeforeRemovingEvidence() async throws {
        let fixture = try makeRepository("committed-recovery-fingerprint")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("committed dirty state\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )
        try Data("committed supplemental state\n".utf8).write(
            to: fixture.repository.appendingPathComponent("notes.txt")
        )

        let migrator = WorktreeStateMigrator(
            temporaryRoot: fixture.root.appendingPathComponent("capture-scratch")
        )
        let localDesired = try await migrator.capture(
            sourceRoot: fixture.repository,
            supplementalPaths: ["notes.txt"]
        )
        let desired = try RemoteWorkspaceStateSnapshot(localDesired).validated()
        let runnerID = UUID()
        let transactionID = UUID()
        let handoffs = AgentTaskHandoffJournal(
            root: fixture.root.appendingPathComponent("handoffs", isDirectory: true)
        )
        let recovery = WorktreeStateRecoveryStore(
            root: fixture.root.appendingPathComponent("recovery", isDirectory: true)
        )
        let reference = try await recovery.save(
            snapshot: localDesired,
            transactionID: transactionID
        )
        let baseline = makeRemoteSnapshot(
            head: desired.headObjectID,
            nodes: desired.supplementalRoots.map {
                RemoteWorkspaceStateNode(
                    relativePath: $0,
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            },
            roots: desired.supplementalRoots
        )
        let configuration = makeRemoteConfiguration(id: runnerID)
        let identity = AgentRemoteExecutionIdentity(
            runnerID: runnerID,
            backendLabel: "SSH · fake test backend",
            host: configuration.host,
            port: configuration.port,
            user: configuration.username,
            workspaceRoot: configuration.workspaceRoot,
            configurationFingerprint: try configuration.executionConfigurationFingerprint()
        )

        var localSession = AgentSession(mode: .agent)
        localSession.workspace = makeWorkspace("local", root: fixture.repository.path)
        localSession.executionLocation = .local
        var entry = try await handoffs.beginHandoffToRemote(
            session: localSession,
            sourceWorktreeID: nil,
            sourceWorktreeLease: nil,
            desiredSnapshot: reference,
            remoteBaselineFingerprint: baseline.fingerprint,
            remoteBaselineSnapshot: baseline,
            remoteExecutionIdentity: identity,
            id: transactionID
        )
        let remoteWorkspace = makeWorkspace("builder", root: "/srv/luma")
        let destination = makeBinding(
            workspace: remoteWorkspace,
            location: .ssh(runnerID: runnerID, label: "Builder"),
            localWorkspace: localSession.workspace
        )
        entry = try await handoffs.markDestinationAllocated(
            entry,
            binding: destination,
            createdWorktreeID: nil
        )
        entry = try await handoffs.markDestinationReady(entry)
        entry = try await handoffs.markSessionCommitted(entry)

        var committedSession = localSession
        committedSession.workspace = remoteWorkspace
        committedSession.executionLocation = destination.location
        committedSession.projectFolderID = nil
        committedSession.localWorkspace = localSession.workspace
        committedSession.localProjectFolderID = nil
        let sessionStore = RemoteHandoffSessionStore([committedSession])

        var changedRemote = desired
        changedRemote.sourceRootPath = "/srv/luma"
        changedRemote.workingTreePatch.append(Data("out-of-band edit".utf8))
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: changedRemote
        )
        let remoteService = RemoteMigrationRunnerService(
            configuration: configuration,
            backend: backend
        )
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: remoteService,
            handoffs: handoffs,
            recovery: recovery
        )

        try await harness.viewModel.restoreProjectCatalogState()

        let preservedEntries = try await handoffs.pendingEntries()
        let operationsAfterMismatch = await backend.operations()
        XCTAssertEqual(preservedEntries, [entry])
        XCTAssertTrue(harness.viewModel.recoveryBlockedSessionIDs.contains(localSession.id))
        XCTAssertTrue(
            harness.viewModel.statusMessage?.contains("committed SSH state 已變更") == true
        )
        XCTAssertEqual(operationsAfterMismatch, ["capture"])
        let preservedRecovery = try await recovery.load(reference)
        XCTAssertEqual(preservedRecovery.fingerprint, desired.fingerprint)

        var matchingRemote = desired
        matchingRemote.sourceRootPath = "/srv/luma"
        await backend.replaceCurrentForTest(matchingRemote)
        try await harness.viewModel.restoreProjectCatalogState()

        let entriesAfterMatch = try await handoffs.pendingEntries()
        let operationsAfterMatch = await backend.operations()
        XCTAssertTrue(entriesAfterMatch.isEmpty)
        XCTAssertFalse(harness.viewModel.recoveryBlockedSessionIDs.contains(localSession.id))
        XCTAssertEqual(operationsAfterMatch, ["capture", "capture"])
        do {
            _ = try await recovery.load(reference)
            XCTFail("Verified committed recovery evidence was not removed.")
        } catch {
            XCTAssertTrue(error is WorktreeStateRecoveryStoreError)
        }
    }

    @MainActor
    func testViewModelPersistsLocalToSSHToLocalBindingsAgainstFakeBackend() async throws {
        let fixture = try makeRepository("view-model-roundtrip")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("local dirty\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )
        try Data("task note\n".utf8).write(
            to: fixture.repository.appendingPathComponent("notes.txt")
        )

        let runnerID = UUID()
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: fixture.head)
        )
        let remoteService = RemoteMigrationRunnerService(
            configuration: makeRemoteConfiguration(id: runnerID),
            backend: backend
        )
        var session = AgentSession(mode: .agent)
        session.title = "Remote handoff integration"
        session.workspace = makeWorkspace(
            "local",
            root: fixture.repository.path
        )
        session.executionLocation = .local
        let sessionStore = RemoteHandoffSessionStore([session])
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: remoteService
        )

        try await harness.viewModel.restoreProjectCatalogState()
        await harness.viewModel.handoffSessionToRemote(
            id: session.id,
            runnerID: runnerID
        )

        let remoteSession = try XCTUnwrap(
            harness.viewModel.sessions.first(where: { $0.id == session.id })
        )
        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(remoteSession.resolvedExecutionLocation.kind, .ssh)
        XCTAssertEqual(remoteSession.resolvedExecutionLocation.remoteRunnerID, runnerID)
        XCTAssertEqual(remoteSession.workspace?.rootPath, "/srv/luma")
        XCTAssertEqual(remoteSession.localWorkspace?.rootPath, fixture.repository.path)
        XCTAssertNotNil(remoteSession.localCheckoutBaselineFingerprint)
        XCTAssertTrue(
            remoteSession.localCheckoutBaselineSupplementalPaths?.contains("notes.txt") == true
        )
        XCTAssertNil(remoteSession.permissionAllowances)
        let persistedRemoteSession = await sessionStore.session(id: session.id)
        XCTAssertEqual(
            persistedRemoteSession?.resolvedExecutionLocation,
            remoteSession.resolvedExecutionLocation
        )
        let outboundOperations = await backend.operations()
        let outboundRemoteState = await backend.currentSnapshot()
        let outboundJournal = try await harness.handoffs.pendingEntries()
        XCTAssertEqual(outboundOperations, ["capture", "apply"])
        XCTAssertFalse(outboundRemoteState.isClean)
        XCTAssertTrue(outboundJournal.isEmpty)

        // Model an atomic Session write that reaches storage but reports an
        // error to its caller. SSH-to-Local must read the Local destination
        // binding back and finish the committed path, never undo that Local
        // checkout beneath its now-durable Task.
        await sessionStore.failNextSaveAfterPersisting()
        await harness.viewModel.handoffSessionFromRemoteToLocal(id: session.id)

        let localSession = try XCTUnwrap(
            harness.viewModel.sessions.first(where: { $0.id == session.id })
        )
        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(localSession.resolvedExecutionLocation, .local)
        XCTAssertEqual(localSession.workspace?.rootPath, fixture.repository.path)
        XCTAssertNil(localSession.localWorkspace)
        XCTAssertNil(localSession.localProjectFolderID)
        XCTAssertNil(localSession.localCheckoutBaselineFingerprint)
        XCTAssertNil(localSession.localCheckoutBaselineSupplementalPaths)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.repository.appendingPathComponent("tracked.txt"),
                encoding: .utf8
            ),
            "local dirty\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: fixture.repository.appendingPathComponent("notes.txt"),
                encoding: .utf8
            ),
            "task note\n"
        )
        let roundTripOperations = await backend.operations()
        let retainedRemoteState = await backend.currentSnapshot()
        let roundTripJournal = try await harness.handoffs.pendingEntries()
        XCTAssertEqual(roundTripOperations, ["capture", "apply", "capture"])
        XCTAssertFalse(
            retainedRemoteState.isClean,
            "SSH-to-Local is a handoff, not a destructive remote cleanup or sync."
        )
        let persistedLocalSession = await sessionStore.session(id: session.id)
        XCTAssertEqual(
            persistedLocalSession?.resolvedExecutionLocation,
            .local
        )
        XCTAssertTrue(roundTripJournal.isEmpty)
    }

    @MainActor
    func testViewModelFinishesRemoteCommitWhenSaveWritesThenThrows() async throws {
        let fixture = try makeRepository("view-model-outbound-write-then-throw")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("outbound committed state\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )

        let runnerID = UUID()
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: fixture.head)
        )
        let remoteService = RemoteMigrationRunnerService(
            configuration: makeRemoteConfiguration(id: runnerID),
            backend: backend
        )
        var session = AgentSession(mode: .agent)
        session.workspace = makeWorkspace("local", root: fixture.repository.path)
        session.executionLocation = .local
        let sessionStore = RemoteHandoffSessionStore([session])
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: remoteService
        )
        try await harness.viewModel.restoreProjectCatalogState()
        await sessionStore.failNextSaveAfterPersisting()

        await harness.viewModel.handoffSessionToRemote(
            id: session.id,
            runnerID: runnerID
        )

        let inMemory = try XCTUnwrap(
            harness.viewModel.sessions.first(where: { $0.id == session.id })
        )
        let persisted = await sessionStore.session(id: session.id)
        let operations = await backend.operations()
        let pending = try await harness.handoffs.pendingEntries()
        XCTAssertNil(harness.viewModel.errorMessage)
        XCTAssertEqual(inMemory.resolvedExecutionLocation.remoteRunnerID, runnerID)
        XCTAssertEqual(persisted?.resolvedExecutionLocation.remoteRunnerID, runnerID)
        XCTAssertEqual(operations, ["capture", "apply"])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(harness.viewModel.recoveryBlockedSessionIDs.contains(session.id))
    }

    @MainActor
    func testViewModelPreservesEvidenceWhenSaveReadbackFindsThirdBinding() async throws {
        let fixture = try makeRepository("view-model-outbound-third-binding")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("remote state must be retained\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )

        let runnerID = UUID()
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: fixture.head)
        )
        let remoteService = RemoteMigrationRunnerService(
            configuration: makeRemoteConfiguration(id: runnerID),
            backend: backend
        )
        var session = AgentSession(mode: .agent)
        session.workspace = makeWorkspace("local", root: fixture.repository.path)
        session.executionLocation = .local
        let sessionStore = RemoteHandoffSessionStore([session])
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: remoteService
        )
        try await harness.viewModel.restoreProjectCatalogState()
        let durableSource = try XCTUnwrap(
            harness.viewModel.sessions.first(where: { $0.id == session.id })
        )
        let thirdRunnerID = UUID()
        var third = durableSource
        third.workspace = makeWorkspace("third", root: "/srv/third-state")
        third.executionLocation = .ssh(runnerID: thirdRunnerID, label: "Third")
        third.projectFolderID = nil
        third.localWorkspace = durableSource.workspace
        third.localProjectFolderID = durableSource.projectFolderID
        third.updatedAt = Date()
        await sessionStore.failNextSaveReplacingWithThirdBinding(third)

        await harness.viewModel.handoffSessionToRemote(
            id: session.id,
            runnerID: runnerID
        )

        let persisted = await sessionStore.session(id: session.id)
        let operations = await backend.operations()
        let retainedRemote = await backend.currentSnapshot()
        let pending = try await harness.handoffs.pendingEntries()
        XCTAssertEqual(
            harness.viewModel.sessions.first(where: { $0.id == session.id })?
                .resolvedExecutionLocation,
            durableSource.resolvedExecutionLocation,
            "An indeterminate durable result must not fabricate an in-memory destination."
        )
        XCTAssertEqual(persisted?.resolvedExecutionLocation.remoteRunnerID, thirdRunnerID)
        XCTAssertEqual(operations, ["capture", "apply"])
        XCTAssertFalse(retainedRemote.isClean, "The uncertain branch must not roll SSH back.")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.stage, .destinationReady)
        XCTAssertEqual(pending.first?.resolvedTransitionKind, .handoffToRemote)
        XCTAssertTrue(harness.viewModel.recoveryBlockedSessionIDs.contains(session.id))
        XCTAssertTrue(
            harness.viewModel.errorMessage?.contains("commit 結果不確定") == true
        )
    }

    @MainActor
    func testViewModelRollsBackRemoteWhenDurableBindingSaveFails() async throws {
        let fixture = try makeRepository("view-model-rollback")
        defer { cleanupPreservingAppleDouble(fixture.root) }
        try Data("dirty before handoff\n".utf8).write(
            to: fixture.repository.appendingPathComponent("tracked.txt")
        )

        let runnerID = UUID()
        let backend = RemoteWorkspaceBackendProbe(
            runnerID: runnerID,
            remoteRoot: "/srv/luma",
            initial: makeRemoteSnapshot(head: fixture.head)
        )
        let remoteService = RemoteMigrationRunnerService(
            configuration: makeRemoteConfiguration(id: runnerID),
            backend: backend
        )
        var session = AgentSession(mode: .agent)
        session.workspace = makeWorkspace("local", root: fixture.repository.path)
        session.executionLocation = .local
        let sessionStore = RemoteHandoffSessionStore([session])
        let harness = makeViewModelHarness(
            root: fixture.root,
            sessionStore: sessionStore,
            remoteService: remoteService
        )
        try await harness.viewModel.restoreProjectCatalogState()
        await sessionStore.failNextSave()

        await harness.viewModel.handoffSessionToRemote(
            id: session.id,
            runnerID: runnerID
        )

        XCTAssertEqual(
            harness.viewModel.sessions.first(where: { $0.id == session.id })?
                .resolvedExecutionLocation,
            .local
        )
        XCTAssertTrue(harness.viewModel.errorMessage?.contains("已 rollback") == true)
        let rollbackOperations = await backend.operations()
        let rolledBackState = await backend.currentSnapshot()
        let rollbackJournal = try await harness.handoffs.pendingEntries()
        let persistedAfterRollback = await sessionStore.session(id: session.id)
        XCTAssertEqual(rollbackOperations, ["capture", "apply", "rollback"])
        XCTAssertTrue(rolledBackState.isClean)
        XCTAssertEqual(
            persistedAfterRollback?.resolvedExecutionLocation,
            .local
        )
        XCTAssertTrue(rollbackJournal.isEmpty)
    }
}

private struct RemoteMigrationRepositoryFixture {
    var root: URL
    var repository: URL
    var head: String
}

@MainActor
private struct RemoteMigrationViewModelHarness {
    var viewModel: AgentViewModel
    var handoffs: AgentTaskHandoffJournal
}

private struct StagedDestinationReadyRemoteHandoff: Sendable {
    var sourceSession: AgentSession
    var entry: AgentTaskHandoffJournalEntry
    var reference: WorktreeStateRecoveryReference
    var desired: RemoteWorkspaceStateSnapshot
    var baseline: RemoteWorkspaceStateSnapshot
    var configuration: RemoteRunnerConfiguration
    var backend: RemoteWorkspaceBackendProbe
    var journalRoot: URL
    var recoveryRoot: URL
}

private func stageDestinationReadyRemoteHandoff(
    root: URL,
    repository: URL
) async throws -> StagedDestinationReadyRemoteHandoff {
    let journalRoot = root.appendingPathComponent("handoffs", isDirectory: true)
    let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
    let localState = try await WorktreeStateMigrator(
        temporaryRoot: root.appendingPathComponent("capture-scratch", isDirectory: true)
    ).capture(sourceRoot: repository, supplementalPaths: [])
    let desired = try RemoteWorkspaceStateSnapshot(localState).validated()
    let baseline = makeRemoteSnapshot(
        head: desired.headObjectID,
        symbolicReference: desired.symbolicReference,
        nodes: desired.supplementalRoots.map {
            RemoteWorkspaceStateNode(
                relativePath: $0,
                kind: .absent,
                data: nil,
                permissions: nil
            )
        },
        roots: desired.supplementalRoots
    )
    let runnerID = UUID()
    let transactionID = UUID()
    let configuration = makeRemoteConfiguration(id: runnerID)
    let identity = AgentRemoteExecutionIdentity(
        runnerID: runnerID,
        backendLabel: "SSH · fake test backend",
        host: configuration.host,
        port: configuration.port,
        user: configuration.username,
        workspaceRoot: configuration.workspaceRoot,
        configurationFingerprint: try configuration.executionConfigurationFingerprint()
    )
    let recovery = WorktreeStateRecoveryStore(root: recoveryRoot)
    let reference = try await recovery.save(
        snapshot: localState,
        transactionID: transactionID
    )
    var sourceSession = AgentSession(mode: .agent)
    sourceSession.workspace = makeWorkspace("local", root: repository.path)
    sourceSession.executionLocation = .local
    let journal = AgentTaskHandoffJournal(root: journalRoot)
    var entry = try await journal.beginHandoffToRemote(
        session: sourceSession,
        sourceWorktreeID: nil,
        sourceWorktreeLease: nil,
        desiredSnapshot: reference,
        remoteBaselineFingerprint: baseline.fingerprint,
        remoteBaselineSnapshot: baseline,
        remoteExecutionIdentity: identity,
        id: transactionID
    )
    entry = try await journal.markDestinationAllocated(
        entry,
        binding: makeBinding(
            workspace: makeWorkspace(
                "builder",
                root: configuration.workspaceRoot
            ),
            location: .ssh(runnerID: runnerID, label: "Builder"),
            localWorkspace: sourceSession.workspace
        ),
        createdWorktreeID: nil
    )
    let backend = RemoteWorkspaceBackendProbe(
        runnerID: runnerID,
        remoteRoot: configuration.workspaceRoot,
        initial: baseline
    )
    _ = try await backend.applyWorkspaceState(
        desired,
        expectedBaseline: baseline,
        transactionID: transactionID
    )
    entry = try await journal.markDestinationReady(entry)
    return StagedDestinationReadyRemoteHandoff(
        sourceSession: sourceSession,
        entry: entry,
        reference: reference,
        desired: desired,
        baseline: baseline,
        configuration: configuration,
        backend: backend,
        journalRoot: journalRoot,
        recoveryRoot: recoveryRoot
    )
}

private enum RemoteHandoffSessionStoreError: LocalizedError, Sendable {
    case injectedSaveFailure

    var errorDescription: String? { "Injected durable session save failure." }
}

private enum RemoteHandoffSaveFault: Sendable {
    case beforeWrite
    case afterWrite
    case replaceWithThirdBinding(AgentSession)
}

private actor RemoteHandoffSessionStore: AgentSessionPersisting {
    private var values: [AgentSession]
    private var nextSaveFault: RemoteHandoffSaveFault?

    init(_ values: [AgentSession]) {
        self.values = values
    }

    func loadSessions() async throws -> [AgentSession] { values }

    func save(_ session: AgentSession) async throws {
        let fault = nextSaveFault
        nextSaveFault = nil
        if case .beforeWrite? = fault {
            throw RemoteHandoffSessionStoreError.injectedSaveFailure
        }
        if case .replaceWithThirdBinding(let third)? = fault {
            persist(third)
            throw RemoteHandoffSessionStoreError.injectedSaveFailure
        }
        persist(session)
        if case .afterWrite? = fault {
            throw RemoteHandoffSessionStoreError.injectedSaveFailure
        }
    }

    private func persist(_ session: AgentSession) {
        if let index = values.firstIndex(where: { $0.id == session.id }) {
            values[index] = session
        } else {
            values.append(session)
        }
    }

    func delete(id: UUID) async throws {
        values.removeAll { $0.id == id }
    }

    func presence(id: UUID) async -> AgentSessionPresence {
        values.contains(where: { $0.id == id }) ? .found : .absent
    }

    func session(id: UUID) -> AgentSession? {
        values.first(where: { $0.id == id })
    }

    func failNextSave() {
        nextSaveFault = .beforeWrite
    }

    func failNextSaveAfterPersisting() {
        nextSaveFault = .afterWrite
    }

    func failNextSaveReplacingWithThirdBinding(_ session: AgentSession) {
        nextSaveFault = .replaceWithThirdBinding(session)
    }
}

private actor RemoteHandoffProjectStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject] = []

    func loadProjects() async throws -> [AgentProject] { values }

    func saveProjects(_ projects: [AgentProject]) async throws {
        try AgentProjectCatalogValidation.validate(projects)
        values = projects
    }

    func touchProject(id: UUID, openedAt: Date) async throws {
        guard let index = values.firstIndex(where: { $0.id == id }),
              openedAt > values[index].lastOpenedAt else { return }
        values[index].lastOpenedAt = openedAt
    }

    func refreshFolder(
        projectID: UUID,
        folderID: UUID,
        workspace: AgentWorkspace,
        openedAt: Date
    ) async throws {
        guard let projectIndex = values.firstIndex(where: { $0.id == projectID }),
              let folderIndex = values[projectIndex].folders.firstIndex(
                where: { $0.id == folderID }
              ) else { return }
        var rebound = workspace
        rebound.id = values[projectIndex].folders[folderIndex].workspace.id
        rebound.allowedPaths = []
        values[projectIndex].folders[folderIndex].workspace = rebound
        values[projectIndex].folders[folderIndex].lastOpenedAt = openedAt
        values[projectIndex].lastOpenedAt = openedAt
    }
}

private actor RemoteMigrationRunnerService: RemoteRunnerServicing {
    private var configurationValue: RemoteRunnerConfiguration
    private let backendValue: RemoteWorkspaceBackendProbe

    init(
        configuration: RemoteRunnerConfiguration,
        backend: RemoteWorkspaceBackendProbe
    ) {
        configurationValue = configuration
        backendValue = backend
    }

    func list() async throws -> [RemoteRunnerConfiguration] {
        [configurationValue]
    }

    func summaries() async throws -> [RemoteRunnerSummary] {
        [RemoteRunnerSummary(configuration: configurationValue, hasCredential: true)]
    }

    func configuration(id: UUID) async throws -> RemoteRunnerConfiguration {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        return configurationValue
    }

    func upsert(
        _ configuration: RemoteRunnerConfiguration,
        credential _: RemoteRunnerCredentialUpdate
    ) async throws -> [RemoteRunnerConfiguration] {
        configurationValue = try configuration.validated()
        return [configurationValue]
    }

    func setEnabled(
        _ enabled: Bool,
        id: UUID
    ) async throws -> [RemoteRunnerConfiguration] {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        configurationValue.enabled = enabled
        return [configurationValue]
    }

    func delete(id: UUID) async throws -> [RemoteRunnerConfiguration] {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        return []
    }

    func executionIdentity(for id: UUID) async throws -> AgentRemoteExecutionIdentity {
        let configuration = try await configuration(id: id)
        guard configuration.enabled else {
            throw RemoteExecutionError.runnerDisabled(id)
        }
        return AgentRemoteExecutionIdentity(
            runnerID: id,
            backendLabel: "SSH · fake test backend",
            host: configuration.host,
            port: configuration.port,
            user: configuration.username,
            workspaceRoot: configuration.workspaceRoot,
            configurationFingerprint: try configuration.executionConfigurationFingerprint()
        )
    }

    func verifyConnection(id: UUID) async throws -> RemoteHostReceipt {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        return try await backendValue.verifyConnection()
    }

    func backend(for id: UUID) async throws -> any RemoteExecutionBackend {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        guard configurationValue.enabled else {
            throw RemoteExecutionError.runnerDisabled(id)
        }
        return backendValue
    }

    func backend(
        for id: UUID,
        matching expectedIdentity: AgentRemoteExecutionIdentity
    ) async throws -> any RemoteExecutionBackend {
        guard id == configurationValue.id else {
            throw RemoteExecutionError.runnerNotFound(id)
        }
        guard configurationValue.enabled else {
            throw RemoteExecutionError.runnerDisabled(id)
        }
        let current = AgentRemoteExecutionIdentity(
            runnerID: id,
            backendLabel: "SSH · fake test backend",
            host: configurationValue.host,
            port: configurationValue.port,
            user: configurationValue.username,
            workspaceRoot: configurationValue.workspaceRoot,
            configurationFingerprint: try configurationValue.executionConfigurationFingerprint()
        )
        guard current == expectedIdentity else {
            throw RemoteExecutionError.invalidRequest(
                "Remote runner configuration changed after this run started."
            )
        }
        return backendValue
    }
}

private struct RemoteWorkspaceBackendTransaction: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case apply
        case rollback
    }

    var operation: Operation
    var transactionID: UUID
    var desiredFingerprint: String
    var baselineFingerprint: String
}

private actor RemoteWorkspaceBackendProbe: RemoteExecutionBackend, RemoteWorkspaceStateBackend {
    nonisolated let runnerID: UUID
    private let remoteRoot: String
    private var current: RemoteWorkspaceStateSnapshot
    private var operationNames: [String] = []
    private var transactionRecords: [RemoteWorkspaceBackendTransaction] = []

    init(
        runnerID: UUID,
        remoteRoot: String,
        initial: RemoteWorkspaceStateSnapshot
    ) {
        self.runnerID = runnerID
        self.remoteRoot = remoteRoot
        var remote = initial
        remote.sourceRootPath = remoteRoot
        current = remote
    }

    func verifyConnection() async throws -> RemoteHostReceipt {
        makeRemoteHostReceipt(runnerID: runnerID, remoteRoot: remoteRoot)
    }

    func captureWorkspaceState(
        supplementalPaths: [String]
    ) async throws -> RemoteWorkspaceStateCapture {
        let paths = try supplementalPaths.map(
            RemoteWorkspaceStateSnapshot.validatedMigrationPath
        )
        guard Set(paths).count == paths.count else {
            throw RemoteExecutionError.invalidRequest("duplicate supplemental roots")
        }
        operationNames.append("capture")
        var result = current
        if current.isClean {
            result.supplementalRoots = paths
            result.supplementalManifest = paths.map {
                RemoteWorkspaceStateNode(
                    relativePath: $0,
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            }
            // Capturing different supplemental roots changes only the bounded
            // representation of an otherwise-clean checkout. Retain that
            // representation so the following exact-baseline apply models the
            // production backend's recapture-and-compare contract.
            current = result
        } else {
            guard Set(current.supplementalRoots).isSubset(of: Set(paths)) else {
                throw RemoteExecutionError.protocolViolation(
                    "Capture omitted applied supplemental roots."
                )
            }
        }
        result.sourceRootPath = remoteRoot
        result = try result.validated()
        return RemoteWorkspaceStateCapture(
            snapshot: result,
            receipt: makeRemoteOperationReceipt(
                runnerID: runnerID,
                remoteRoot: remoteRoot,
                operation: "workspace_capture"
            )
        )
    }

    func applyWorkspaceState(
        _ snapshot: RemoteWorkspaceStateSnapshot,
        expectedBaseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt {
        let desired = try snapshot.validated()
        let baseline = try expectedBaseline.validated()
        guard baseline.isClean,
              baseline.headObjectID == desired.headObjectID,
              baseline.supplementalRoots == desired.supplementalRoots else {
            throw RemoteExecutionError.invalidRequest(
                "Remote workspace baseline does not match the transfer contract."
            )
        }
        var installedBaseline = baseline
        installedBaseline.sourceRootPath = remoteRoot
        guard current == installedBaseline else {
            throw WorktreeStateMigrationError.targetNotClean(remoteRoot)
        }
        guard current.headObjectID == desired.headObjectID else {
            throw WorktreeStateMigrationError.revisionMismatch(
                source: desired.headObjectID,
                target: current.headObjectID
            )
        }
        operationNames.append("apply")
        transactionRecords.append(RemoteWorkspaceBackendTransaction(
            operation: .apply,
            transactionID: transactionID,
            desiredFingerprint: desired.fingerprint,
            baselineFingerprint: baseline.fingerprint
        ))
        var installed = desired
        installed.sourceRootPath = remoteRoot
        current = installed
        return RemoteWorkspaceTransferReceipt(
            direction: .localToRemote,
            snapshotFingerprint: desired.fingerprint,
            operation: makeRemoteOperationReceipt(
                runnerID: runnerID,
                remoteRoot: remoteRoot,
                operation: "workspace_apply"
            )
        )
    }

    func rollbackWorkspaceState(
        expectedApplied: RemoteWorkspaceStateSnapshot,
        restoring baseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt {
        let expected = try expectedApplied.validated()
        let baseline = try baseline.validated()
        guard baseline.isClean,
              baseline.headObjectID == expected.headObjectID,
              baseline.supplementalRoots == expected.supplementalRoots else {
            throw RemoteExecutionError.invalidRequest(
                "Remote rollback baseline does not match the transfer contract."
            )
        }
        var installedExpected = expected
        installedExpected.sourceRootPath = remoteRoot
        var installedBaseline = baseline
        installedBaseline.sourceRootPath = remoteRoot
        guard current == installedExpected || current == installedBaseline else {
            throw RemoteExecutionError.protocolViolation(
                "Remote state changed after handoff; rollback refused."
            )
        }
        operationNames.append("rollback")
        transactionRecords.append(RemoteWorkspaceBackendTransaction(
            operation: .rollback,
            transactionID: transactionID,
            desiredFingerprint: expected.fingerprint,
            baselineFingerprint: baseline.fingerprint
        ))
        current = installedBaseline
        return RemoteWorkspaceTransferReceipt(
            direction: .rollbackRemote,
            snapshotFingerprint: expected.fingerprint,
            operation: makeRemoteOperationReceipt(
                runnerID: runnerID,
                remoteRoot: remoteRoot,
                operation: "workspace_rollback"
            )
        )
    }

    func executeFilesystem(
        _: RemoteFilesystemRequest
    ) async throws -> RemoteFilesystemResult {
        throw RemoteExecutionError.unsupported("Not used by migration tests.")
    }

    func executeGit(_: RemoteGitRequest) async throws -> RemoteGitResult {
        throw RemoteExecutionError.unsupported("Not used by migration tests.")
    }

    func executeBuild(
        _: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        throw RemoteExecutionError.unsupported("Not used by migration tests.")
    }

    func executeTest(
        _: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        throw RemoteExecutionError.unsupported("Not used by migration tests.")
    }

    func executeShell(_: RemoteShellRequest) async throws -> RemoteShellResult {
        throw RemoteExecutionError.unsupported("Not used by migration tests.")
    }

    nonisolated func makePTYBackend() -> any PTYBackend {
        RemoteMigrationPTYProbe()
    }

    func currentSnapshot() -> RemoteWorkspaceStateSnapshot { current }

    func operations() -> [String] { operationNames }

    func transactions() -> [RemoteWorkspaceBackendTransaction] { transactionRecords }

    func replaceCurrentForTest(_ snapshot: RemoteWorkspaceStateSnapshot) {
        current = snapshot
    }
}

private struct RemoteMigrationPTYProbe: PTYBackend {
    func makeSession(
        validator _: WorkspaceSecurityValidator,
        cwd _: String?,
        environment _: [String: String]
    ) throws -> any PTYSessionTransport {
        throw RemoteExecutionError.unsupported("No interactive PTY in migration tests.")
    }
}

@MainActor
private func makeViewModelHarness(
    root: URL,
    sessionStore: RemoteHandoffSessionStore,
    remoteService: RemoteMigrationRunnerService,
    handoffs suppliedHandoffs: AgentTaskHandoffJournal? = nil,
    recovery suppliedRecovery: WorktreeStateRecoveryStore? = nil
) -> RemoteMigrationViewModelHarness {
    let managedRoot = root.appendingPathComponent("managed", isDirectory: true)
    let checkouts = managedRoot.appendingPathComponent("checkouts", isDirectory: true)
    let registry = WorktreeRegistry(
        registryFile: managedRoot.appendingPathComponent("registry.json"),
        managedRoot: checkouts
    )
    let handoffs = suppliedHandoffs ?? AgentTaskHandoffJournal(
        root: root.appendingPathComponent("handoffs", isDirectory: true)
    )
    let recovery = suppliedRecovery ?? WorktreeStateRecoveryStore(
        root: root.appendingPathComponent("recovery", isDirectory: true)
    )
    let viewModel = AgentViewModel(
        sessionStore: sessionStore,
        projectCatalogStore: RemoteHandoffProjectStore(),
        worktreeService: ManagedWorktreeService(
            registry: registry,
            managedRoot: checkouts
        ),
        handoffJournal: handoffs,
        deletionJournal: AgentTaskDeletionJournal(
            root: root.appendingPathComponent("deletions", isDirectory: true)
        ),
        worktreeRecoveryStore: recovery,
        worktreeStateMigrator: WorktreeStateMigrator(
            temporaryRoot: root.appendingPathComponent("scratch", isDirectory: true)
        ),
        remoteRunnerService: remoteService
    )
    return RemoteMigrationViewModelHarness(viewModel: viewModel, handoffs: handoffs)
}

private func makeRemoteSnapshot(
    root: String = "/srv/luma",
    head: String = String(repeating: "a", count: 40),
    symbolicReference: String? = "refs/heads/main",
    workingPatch: Data = Data(),
    stagedPatch: Data = Data(),
    nodes: [RemoteWorkspaceStateNode] = [],
    roots: [String] = []
) -> RemoteWorkspaceStateSnapshot {
    RemoteWorkspaceStateSnapshot(
        sourceRootPath: root,
        headObjectID: head,
        symbolicReference: symbolicReference,
        workingTreePatch: workingPatch,
        stagedPatch: stagedPatch,
        supplementalManifest: nodes,
        supplementalRoots: roots
    )
}

private func makeRemoteConfiguration(id: UUID) -> RemoteRunnerConfiguration {
    RemoteRunnerConfiguration(
        id: id,
        name: "Test Builder",
        enabled: true,
        host: "builder.example.test",
        port: 2222,
        username: "runner",
        workspaceRoot: "/srv/luma",
        knownHostsFile: AppPaths.projectTemporaryRoot
            .appendingPathComponent("lumachat-test-known-hosts")
            .path,
        authentication: .systemAgent
    )
}

private func makeRemoteHostReceipt(
    runnerID: UUID,
    remoteRoot: String
) -> RemoteHostReceipt {
    RemoteHostReceipt(
        runnerID: runnerID,
        transport: .ssh,
        configuredHost: "builder.example.test",
        configuredPort: 2222,
        configuredUser: "runner",
        serverReportedHostname: "builder-test",
        effectiveUser: "runner",
        effectiveUserID: 501,
        configuredWorkspaceRoot: remoteRoot,
        canonicalWorkspaceRoot: remoteRoot,
        verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeRemoteOperationReceipt(
    runnerID: UUID,
    remoteRoot: String,
    operation: String
) -> RemoteOperationReceipt {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    return RemoteOperationReceipt(
        id: UUID(),
        runnerID: runnerID,
        operation: operation,
        host: makeRemoteHostReceipt(runnerID: runnerID, remoteRoot: remoteRoot),
        requestedPath: ".",
        canonicalPath: remoteRoot,
        startedAt: startedAt,
        completedAt: startedAt.addingTimeInterval(1),
        exitCode: 0,
        timedOut: false,
        outputTruncated: false
    )
}

private func makeWorkspace(
    _ name: String,
    root: String
) -> AgentWorkspace {
    AgentWorkspace(
        name: name,
        rootPath: root,
        allowedPaths: [],
        bookmarkData: nil,
        gitRepository: true,
        branch: "main"
    )
}

private func makeBinding(
    workspace: AgentWorkspace,
    location: AgentExecutionLocation,
    projectFolderID: UUID? = nil,
    localWorkspace: AgentWorkspace? = nil,
    localProjectFolderID: UUID? = nil
) -> AgentTaskBindingSnapshot {
    AgentTaskBindingSnapshot(
        workspace: workspace,
        location: location,
        projectFolderID: projectFolderID,
        localWorkspace: localWorkspace,
        localProjectFolderID: localProjectFolderID
    )
}

private func makeRecoveryReference(
    transactionID: UUID,
    snapshotFingerprint: String
) -> WorktreeStateRecoveryReference {
    WorktreeStateRecoveryReference(
        transactionID: transactionID,
        relativePath: transactionID.uuidString.lowercased() + ".snapshot",
        byteCount: 128,
        sha256: String(repeating: "c", count: 64),
        snapshotFingerprint: snapshotFingerprint
    )
}

private func makeRepository(_ label: String) throws -> RemoteMigrationRepositoryFixture {
    let root = makeTestRoot(label)
    let repository = root.appendingPathComponent("repository", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true
    )
    try runMigrationGit(repository, ["init"])
    try runMigrationGit(repository, ["config", "user.name", "Luma Tests"])
    try runMigrationGit(repository, ["config", "user.email", "luma@example.invalid"])
    try Data("base\n".utf8).write(
        to: repository.appendingPathComponent("tracked.txt")
    )
    try runMigrationGit(repository, ["add", "tracked.txt"])
    try runMigrationGit(repository, ["commit", "--no-gpg-sign", "-m", "initial"])
    let head = try runMigrationGit(repository, ["rev-parse", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return RemoteMigrationRepositoryFixture(
        root: root,
        repository: repository,
        head: head
    )
}

private func makeTestRoot(_ label: String) -> URL {
    AppPaths.projectTemporaryRoot
        .appendingPathComponent("remote-workspace-migration-tests", isDirectory: true)
        .appendingPathComponent(label, isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
}

@discardableResult
private func runMigrationGit(_ root: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "credential.helper=",
        "-C", root.path
    ] + arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "TMPDIR": AppPaths.projectTemporaryRoot.path
    ]
    try process.run()
    process.waitUntilExit()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "RemoteWorkspaceMigrationTests",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)
            ]
        )
    }
    return String(decoding: output, as: UTF8.self)
}

/// Test cleanup is deliberately conservative: if Finder/SMB created an
/// AppleDouble entry, leave the whole fixture untouched for manual inspection
/// instead of ever deleting a `._*` file.
private func cleanupPreservingAppleDouble(_ root: URL) {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { _, _ in false }
    ) else { return }
    for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("._") {
        return
    }
    try? FileManager.default.removeItem(at: root)
}
