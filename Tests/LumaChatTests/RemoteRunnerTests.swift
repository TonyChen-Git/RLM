import Darwin
import Foundation
import XCTest

@testable import LumaChat

final class RemoteRunnerTests: XCTestCase {
    func testConfigurationPathsAndAppleDoubleMutationsFailClosed() throws {
        let normalized = try makeRunner(
            name: "  Build Host  ",
            host: "BUILDER.EXAMPLE.TEST",
            workspaceRoot: "/srv//luma/"
        ).validated()

        XCTAssertEqual(normalized.name, "Build Host")
        XCTAssertEqual(normalized.host, "builder.example.test")
        XCTAssertEqual(normalized.workspaceRoot, "/srv/luma")
        XCTAssertEqual(try RemotePathPolicy.relative("."), ".")
        XCTAssertEqual(try RemotePathPolicy.relative("Sources/Luma Chat"), "Sources/Luma Chat")

        for path in ["../outside", "Sources//File.swift", "/absolute", "Sources/./File.swift"] {
            XCTAssertThrowsError(try RemotePathPolicy.relative(path), path) { error in
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }
        }
        for path in ["._metadata", "artifacts/._result", "._cache/entry"] {
            XCTAssertThrowsError(try RemotePathPolicy.refusesAppleDoubleMutation(path), path) {
                error in
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }
        }
        XCTAssertNoThrow(try RemotePathPolicy.refusesAppleDoubleMutation("artifacts/result"))
        for path in [".git", ".git/config", "nested/.git/objects"] {
            XCTAssertThrowsError(try RemotePathPolicy.refusesGitAdministrativePath(path), path) {
                error in
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }
        }
        XCTAssertNoThrow(try RemotePathPolicy.refusesGitAdministrativePath("Sources/git.swift"))
    }

    func testRunnerStorePersistsOnlyMetadataAndUsesDedicatedCredentialAccount() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-runner-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = root.appendingPathComponent("runners.json", isDirectory: false)
        defer { cleanupTestRoot(root, knownFiles: [fileURL]) }
        let secrets = InMemoryRemoteRunnerSecretStore()
        let store = RemoteRunnerStore(fileURL: fileURL, secretStore: secrets)
        let runner = makeRunner(name: "Primary")
        let credential = makeCredential()

        let stored = try await store.upsert(runner, credential: .replace(credential))

        XCTAssertEqual(stored, [runner])
        let account = RemoteRunnerStore.credentialAccount(runner.id)
        XCTAssertEqual(account, "remote-runner|ssh|\(runner.id.uuidString.lowercased())")
        XCTAssertEqual(try secrets.load(account: account), credential.privateKey)
        let document = String(
            decoding: try Data(contentsOf: fileURL),
            as: UTF8.self
        )
        XCTAssertTrue(document.contains(runner.id.uuidString))
        XCTAssertTrue(document.contains("\"version\" : 1"))
        XCTAssertFalse(document.contains(credential.privateKey))
        XCTAssertFalse(document.contains("PRIVATE KEY"))

        let hasCredential = try await store.hasCredential(for: runner.id)
        XCTAssertTrue(hasCredential)
        let remaining = try await store.delete(id: runner.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(try secrets.load(account: account))
    }

    func testSSHFramingQuotesEveryValueAndInvocationPinsSecurityOptions() throws {
        let runner = makeRunner()
        let request = SSHCommandRequest(
            executable: "printf",
            arguments: ["%s", "$(touch /tmp/not-executed)", "single'quote"],
            workingDirectory: "/srv/luma",
            environment: ["Z_LAST": "two words", "A_FIRST": "left'right"],
            timeout: 10,
            outputLimit: 8_192,
            operationLabel: "quoting"
        )

        let framed = try SSHRemoteCommandFramer.frame(request)

        XCTAssertTrue(framed.hasPrefix("cd -- '/srv/luma' && exec /usr/bin/env "))
        XCTAssertTrue(framed.contains("'A_FIRST=left'\\''right'"))
        XCTAssertTrue(framed.contains("'Z_LAST=two words'"))
        XCTAssertTrue(framed.contains("'$(touch /tmp/not-executed)'"))
        XCTAssertTrue(framed.hasSuffix("'single'\\''quote'"))
        XCTAssertLessThan(framed.range(of: "A_FIRST")!.lowerBound, framed.range(of: "Z_LAST")!.lowerBound)

        let knownHosts = URL(fileURLWithPath: "/tmp/luma-known-hosts")
        let identity = URL(fileURLWithPath: "/tmp/luma-identity")
        let invocation = try SSHInvocationBuilder.invocation(
            configuration: runner,
            request: request,
            knownHostsFile: knownHosts,
            identityFile: identity
        )
        let arguments = invocation.arguments

        XCTAssertEqual(invocation.executableURL.path, "/usr/bin/ssh")
        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=\(knownHosts.path)"))
        XCTAssertTrue(arguments.contains("GlobalKnownHostsFile=/dev/null"))
        XCTAssertTrue(arguments.contains("ForwardAgent=no"))
        XCTAssertTrue(arguments.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(arguments.contains("PermitLocalCommand=no"))
        XCTAssertTrue(arguments.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(arguments.contains("IdentityAgent=none"))
        XCTAssertTrue(arguments.contains("-T"))
        XCTAssertEqual(arguments.suffix(2).first, runner.host)
        XCTAssertEqual(arguments.last, framed)
        XCTAssertNil(invocation.environment["HOME"])
    }

    func testBackendVerifiesHostThenReusesReceiptForGitRequest() async throws {
        let runner = makeRunner()
        let credential = makeCredential()
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON()),
            "git_diff": makeCommandResult(stdout: "diff --git a/A b/A\n")
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: runner,
            credentialProvider: StaticRemoteCredentialProvider(credential: credential),
            transport: transport
        )
        let earliestVerification = Date()

        let host = try await backend.verifyConnection()
        let result = try await backend.executeGit(.diff(
            staged: true,
            paths: ["Sources/A.swift"]
        ))

        XCTAssertEqual(host.runnerID, runner.id)
        XCTAssertEqual(host.configuredHost, runner.host)
        XCTAssertEqual(host.configuredPort, runner.port)
        XCTAssertEqual(host.configuredUser, runner.username)
        XCTAssertEqual(host.serverReportedHostname, "builder-01")
        XCTAssertEqual(host.effectiveUser, "runner")
        XCTAssertEqual(host.effectiveUserID, 501)
        XCTAssertEqual(host.configuredWorkspaceRoot, "/srv/luma")
        XCTAssertEqual(host.canonicalWorkspaceRoot, "/srv/luma-real")
        XCTAssertGreaterThanOrEqual(host.verifiedAt, earliestVerification)
        XCTAssertEqual(result.stdout, "diff --git a/A b/A\n")
        XCTAssertEqual(result.receipt.host, host)
        XCTAssertEqual(result.receipt.operation, "git_diff")
        XCTAssertEqual(result.receipt.requestedPath, ".")
        XCTAssertEqual(result.receipt.canonicalPath, "/srv/luma-real")

        let invocations = await transport.snapshot()
        XCTAssertEqual(invocations.count, 2, "A valid 30-second receipt should avoid a second probe.")
        XCTAssertEqual(invocations[0].request.executable, "/usr/bin/python3")
        XCTAssertEqual(invocations[0].request.operationLabel, "verify_connection")
        XCTAssertEqual(invocations[0].request.arguments.last, "/srv/luma")
        XCTAssertEqual(invocations[0].credential, credential)
        XCTAssertEqual(invocations[1].request.executable, "/usr/bin/python3")
        XCTAssertNil(invocations[1].request.workingDirectory)
        XCTAssertTrue(invocations[1].request.environment.isEmpty)
        XCTAssertEqual(invocations[1].request.arguments[0], "-I")
        XCTAssertEqual(invocations[1].request.arguments[5], "/srv/luma-real")
        XCTAssertEqual(invocations[1].request.arguments[7], "/usr/bin/python3")
        XCTAssertEqual(
            Array(invocations[1].request.arguments.suffix(7)),
            [
                "--literal-pathspecs", "-C", "/srv/luma-real", "diff", "--cached", "--",
                "Sources/A.swift"
            ]
        )
    }

    func testBackendMapsAtomicWriteAndReturnsStructuredReceipt() async throws {
        let runner = makeRunner()
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON()),
            "write_file": makeCommandResult(stdout: metadataJSON(
                canonicalPath: "/srv/luma-real/Sources/New.swift",
                byteCount: 5
            ))
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: runner,
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )

        let result = try await backend.executeFilesystem(.write(
            path: "Sources/New.swift",
            data: Data("hello".utf8),
            createParents: true
        ))

        guard case .mutation(let metadata?) = result.payload else {
            return XCTFail("Expected mutation metadata.")
        }
        XCTAssertEqual(metadata.path, "Sources/New.swift")
        XCTAssertEqual(metadata.canonicalPath, "/srv/luma-real/Sources/New.swift")
        XCTAssertEqual(metadata.kind, .file)
        XCTAssertEqual(metadata.byteCount, 5)
        XCTAssertEqual(metadata.permissions, 0o600)
        XCTAssertEqual(result.receipt.operation, "write_file")
        XCTAssertEqual(result.receipt.requestedPath, "Sources/New.swift")
        XCTAssertEqual(result.receipt.canonicalPath, metadata.canonicalPath)

        let invocations = await transport.snapshot()
        let request = try XCTUnwrap(invocations.last?.request)
        XCTAssertEqual(request.executable, "/usr/bin/python3")
        XCTAssertEqual(request.operationLabel, "write_file")
        XCTAssertEqual(Array(request.arguments.suffix(5)), [
            "write", "/srv/luma-real", "Sources/New.swift", "1", "5"
        ])
        XCTAssertEqual(request.standardInput, Data("hello".utf8))
        XCTAssertFalse(request.allocatePTY)
    }

    func testBackendRejectsAppleDoubleMutationBeforeSendingMutationCommand() async throws {
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON())
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: makeRunner(),
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )

        do {
            _ = try await backend.executeFilesystem(.remove(path: "artifacts/._keep"))
            XCTFail("AppleDouble mutation was accepted.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }

        let requests = await transport.snapshot().map(\.request)
        XCTAssertEqual(requests.map(\.operationLabel), ["verify_connection"])
        XCTAssertFalse(requests.contains { $0.operationLabel == "remove" })
    }

    func testBackendRejectsGitAdministrativePathsForEveryGenericFilesystemOperation() async throws {
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON())
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: makeRunner(),
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )
        let requests: [RemoteFilesystemRequest] = [
            .metadata(path: ".git"),
            .list(path: "nested/.git", maximumEntries: 10),
            .read(path: ".git/config", maximumBytes: 1_024),
            .write(path: "nested/.git/config", data: Data("blocked".utf8), createParents: true),
            .createDirectory(path: ".git/hooks", recursive: true),
            .remove(path: "nested/.git/index"),
            .move(source: ".git/config", destination: "config-copy"),
            .move(source: "config-copy", destination: "nested/.git/config")
        ]

        for request in requests {
            do {
                _ = try await backend.executeFilesystem(request)
                XCTFail("Generic filesystem operation accepted a Git administrative path.")
            } catch {
                XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
            }
        }

        let transmitted = await transport.snapshot().map(\.request)
        XCTAssertEqual(transmitted.map(\.operationLabel), ["verify_connection"])
    }

    func testBackendCarriesOneTransactionIDAcrossSSHApplyAndRollbackWireRequests() async throws {
        let head = String(repeating: "a", count: 40)
        let roots = ["notes.txt"]
        let baseline = RemoteWorkspaceStateSnapshot(
            sourceRootPath: "/srv/luma-real",
            headObjectID: head,
            symbolicReference: "refs/heads/main",
            workingTreePatch: Data(),
            stagedPatch: Data(),
            supplementalManifest: [
                RemoteWorkspaceStateNode(
                    relativePath: "notes.txt",
                    kind: .absent,
                    data: nil,
                    permissions: nil
                )
            ],
            supplementalRoots: roots
        )
        let desired = RemoteWorkspaceStateSnapshot(
            sourceRootPath: "/local/source",
            headObjectID: head,
            symbolicReference: "refs/heads/main",
            workingTreePatch: Data("diff --git a/A b/A\n".utf8),
            stagedPatch: Data(),
            supplementalManifest: [
                RemoteWorkspaceStateNode(
                    relativePath: "notes.txt",
                    kind: .regularFile,
                    data: Data("note\n".utf8),
                    permissions: 0o600
                )
            ],
            supplementalRoots: roots
        )
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON()),
            "workspace_state_apply": makeCommandResult(
                stdout: "{\"status\":\"applied\",\"headObjectID\":\"\(head)\"}"
            ),
            "workspace_state_rollback": makeCommandResult(
                stdout: "{\"status\":\"already_clean\",\"headObjectID\":\"\(head)\"}"
            )
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: makeRunner(),
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )
        let transactionID = UUID()

        let applied = try await backend.applyWorkspaceState(
            desired,
            expectedBaseline: baseline,
            transactionID: transactionID
        )
        let rolledBack = try await backend.rollbackWorkspaceState(
            expectedApplied: desired,
            restoring: baseline,
            transactionID: transactionID
        )

        XCTAssertEqual(applied.direction, .localToRemote)
        XCTAssertEqual(applied.snapshotFingerprint, desired.fingerprint)
        XCTAssertEqual(applied.operation.operation, "workspace_state_apply")
        XCTAssertEqual(rolledBack.direction, .rollbackRemote)
        XCTAssertEqual(rolledBack.snapshotFingerprint, desired.fingerprint)
        XCTAssertEqual(rolledBack.operation.operation, "workspace_state_rollback")

        let invocations = await transport.snapshot()
        XCTAssertEqual(invocations.map(\.request.operationLabel), [
            "verify_connection", "workspace_state_apply", "workspace_state_rollback"
        ])
        let transactions = try invocations.dropFirst().map { invocation in
            let request = invocation.request
            XCTAssertEqual(request.executable, "/usr/bin/python3")
            XCTAssertEqual(request.arguments[3], "/srv/luma-real")
            XCTAssertEqual(request.arguments[7], "/usr/bin/python3")
            XCTAssertEqual(request.arguments[8], "-I")
            XCTAssertEqual(request.arguments[9], "-c")
            XCTAssertEqual(request.arguments.last, "/srv/luma-real")
            XCTAssertNil(request.workingDirectory)
            XCTAssertTrue(request.environment.isEmpty)
            XCTAssertFalse(request.allocatePTY)
            let data = try XCTUnwrap(request.standardInput)
            XCTAssertLessThanOrEqual(
                data.count,
                RemoteWorkspaceStateSnapshot.maximumTransactionWireBytes
            )
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), ["transactionID", "desired", "baseline"])
            return try JSONDecoder().decode(DecodedRemoteWorkspaceTransaction.self, from: data)
        }
        XCTAssertEqual(Array(invocations[1].request.arguments.suffix(2)), [
            "apply", "/srv/luma-real"
        ])
        XCTAssertEqual(Array(invocations[2].request.arguments.suffix(2)), [
            "rollback", "/srv/luma-real"
        ])
        XCTAssertEqual(transactions.map(\.transactionID), [
            transactionID.uuidString.lowercased(), transactionID.uuidString.lowercased()
        ])
        XCTAssertEqual(transactions.map(\.desired), [desired, desired])
        XCTAssertEqual(transactions.map(\.baseline), [baseline, baseline])

        var wrongRootBaseline = baseline
        wrongRootBaseline.sourceRootPath = "/srv/a-different-checkout"
        do {
            _ = try await backend.applyWorkspaceState(
                desired,
                expectedBaseline: wrongRootBaseline,
                transactionID: UUID()
            )
            XCTFail("A baseline captured from another canonical root was accepted.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }
        let invocationsAfterRejectedBaseline = await transport.snapshot()
        XCTAssertEqual(invocationsAfterRejectedBaseline.count, 3)
    }

    func testBackendMapsValidationShellAndOneShotPTYWithoutClaimingInteractivePTY() async throws {
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON()),
            "build": makeCommandResult(stdout: "Build complete"),
            "test": makeCommandResult(stdout: "Tests complete"),
            "shell": makeCommandResult(stdout: "shell output"),
            "pty_run": makeCommandResult(stdout: "pty output")
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: makeRunner(),
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )

        _ = try await backend.executeBuild(RemoteValidationRequest(
            kind: .build,
            configuration: .release,
            timeout: 90
        ))
        _ = try await backend.executeTest(RemoteValidationRequest(
            kind: .test,
            toolchain: .xcode(scheme: "Luma Chat"),
            configuration: .debug
        ))
        _ = try await backend.executeShell(RemoteShellRequest(
            script: "printf ok",
            shell: .bash,
            environment: ["CI": "1"],
            timeout: 30
        ))
        _ = try await backend.executeShell(RemoteShellRequest(
            script: "tty",
            shell: .zsh,
            allocatePTY: true
        ))

        let requests = await transport.snapshot().map(\.request)
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[1].executable, "/usr/bin/python3")
        XCTAssertEqual(
            Array(requests[1].arguments.suffix(4)),
            ["swift", "build", "--configuration", "release"]
        )
        XCTAssertEqual(requests[1].timeout, 90)
        XCTAssertEqual(Array(requests[2].arguments.suffix(6)), [
            "xcodebuild", "-scheme", "Luma Chat", "-configuration", "Debug", "test"
        ])
        XCTAssertEqual(requests[3].executable, "/usr/bin/python3")
        XCTAssertEqual(Array(requests[3].arguments.suffix(1)), ["-s"])
        XCTAssertTrue(requests[3].environment.isEmpty)
        XCTAssertEqual(requests[3].arguments[5], "/srv/luma-real")
        XCTAssertEqual(requests[3].arguments[6], "1")
        XCTAssertEqual(requests[3].arguments[7], "CI")
        XCTAssertEqual(requests[3].arguments[8], "1")
        XCTAssertEqual(requests[3].arguments[9], "/bin/bash")
        XCTAssertEqual(requests[3].standardInput, Data("printf ok".utf8))
        XCTAssertFalse(requests[3].allocatePTY)
        XCTAssertTrue(requests[4].allocatePTY)
        XCTAssertEqual(requests[4].operationLabel, "pty_run")

        try AppPaths.ensureAgentDirectories()
        let workspaceRoot = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-pty-backend-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspace = AgentWorkspace(
            name: "remote",
            rootPath: workspaceRoot.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let validator = try WorkspaceSecurityValidator(workspace: workspace)
        XCTAssertThrowsError(try backend.makePTYBackend().makeSession(
            validator: validator,
            cwd: ".",
            environment: [:]
        )) { error in
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .unsupported)
        }
    }

    func testBackendRejectsMalformedProbeAsProtocolViolation() async throws {
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: "{\"hostname\":true}")
        ])
        let backend = try SSHRemoteExecutionBackend(
            configuration: makeRunner(),
            credentialProvider: StaticRemoteCredentialProvider(credential: makeCredential()),
            transport: transport
        )

        do {
            _ = try await backend.verifyConnection()
            XCTFail("Malformed probe response was accepted.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .protocolViolation)
        }
    }

    func testRunnerServiceResolvesOpaqueEnabledRunnerAndNeverNeedsModelHostInput() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-runner-service-\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = root.appendingPathComponent("runners.json")
        let knownHostsURL = root.appendingPathComponent("known_hosts")
        defer { cleanupTestRoot(root, knownFiles: [fileURL, knownHostsURL]) }
        let secrets = InMemoryRemoteRunnerSecretStore()
        let store = RemoteRunnerStore(
            fileURL: fileURL,
            secretStore: secrets
        )
        let runner = makeRunner(knownHostsFile: knownHostsURL.path)
        let credential = makeCredential()
        _ = try await store.upsert(runner, credential: .replace(credential))
        try Data("builder.example.test ssh-ed25519 AAAAtest\n".utf8)
            .write(to: knownHostsURL)
        let service = RemoteRunnerService(
            store: store,
            credentialProvider: StaticRemoteCredentialProvider(credential: credential),
            transport: RecordingSSHTransport(responses: [
                "verify_connection": makeCommandResult(stdout: probeJSON())
            ])
        )

        let summaries = try await service.summaries()
        let identity = try await service.executionIdentity(for: runner.id)
        let backend = try await service.backend(for: runner.id)

        XCTAssertEqual(summaries, [RemoteRunnerSummary(configuration: runner, hasCredential: true)])
        XCTAssertEqual(identity.runnerID, runner.id)
        XCTAssertEqual(identity.backendLabel, "SSH · system OpenSSH")
        XCTAssertEqual(identity.host, runner.host)
        XCTAssertEqual(identity.port, runner.port)
        XCTAssertEqual(identity.user, runner.username)
        XCTAssertEqual(identity.workspaceRoot, runner.workspaceRoot)
        XCTAssertEqual(backend.runnerID, runner.id)

        _ = try await service.setEnabled(false, id: runner.id)
        do {
            _ = try await service.backend(for: runner.id)
            XCTFail("Disabled runner produced a backend.")
        } catch {
            XCTAssertEqual(error as? RemoteExecutionError, .runnerDisabled(runner.id))
        }
    }

    func testRunnerServiceFailsBeforeBackendCreationWhenCredentialIsMissing() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-runner-missing-key-\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = root.appendingPathComponent("runners.json")
        defer { cleanupTestRoot(root, knownFiles: [fileURL]) }
        let store = RemoteRunnerStore(
            fileURL: fileURL,
            secretStore: InMemoryRemoteRunnerSecretStore()
        )
        let runner = makeRunner()
        _ = try await store.upsert(runner)
        let service = RemoteRunnerService(
            store: store,
            credentialProvider: StaticRemoteCredentialProvider(credential: nil),
            transport: RecordingSSHTransport(responses: [:])
        )

        do {
            _ = try await service.backend(for: runner.id)
            XCTFail("A key-backed runner without a key produced a backend.")
        } catch {
            XCTAssertEqual(error as? RemoteExecutionError, .credentialUnavailable(runner.id))
        }
    }

    func testRunnerServicePinsBackendToExactExecutionConfiguration() async throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "remote-runner-pinned-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        let fileURL = root.appendingPathComponent("runners.json")
        let knownHostsURL = root.appendingPathComponent("known_hosts")
        defer { cleanupTestRoot(root, knownFiles: [fileURL, knownHostsURL]) }
        let credential = makeCredential()
        let storeSecrets = InMemoryRemoteRunnerSecretStore()
        let store = RemoteRunnerStore(
            fileURL: fileURL,
            secretStore: storeSecrets
        )
        let original = makeRunner(knownHostsFile: knownHostsURL.path)
        _ = try await store.upsert(original, credential: .replace(credential))
        try Data("builder.example.test ssh-ed25519 AAAAoriginal\n".utf8)
            .write(to: knownHostsURL)
        let transport = RecordingSSHTransport(responses: [
            "verify_connection": makeCommandResult(stdout: probeJSON())
        ])
        let service = RemoteRunnerService(
            store: store,
            credentialProvider: KeychainRemoteRunnerCredentialProvider(secretStore: storeSecrets),
            transport: transport
        )

        let pinned = try await service.executionIdentity(for: original.id)
        let exactBackend = try await service.backend(for: original.id, matching: pinned)
        XCTAssertEqual(pinned.configurationFingerprint.count, 64)
        XCTAssertEqual(exactBackend.runnerID, original.id)

        let rotatedCredential = RemoteRunnerCredential(
            privateKey: credential.privateKey.replacingOccurrences(
                of: "abcdefghijklmnopqrstuvwxyz",
                with: "zyxwvutsrqponmlkjihgfedcba"
            )
        )
        _ = try await service.upsert(original, credential: .replace(rotatedCredential))
        do {
            _ = try await service.backend(for: original.id, matching: pinned)
            XCTFail("A stale run identity accepted a rotated credential.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }
        let credentialPinned = try await service.executionIdentity(for: original.id)

        var redirected = original
        redirected.host = "redirected.example.test"
        _ = try await service.upsert(redirected, credential: .unchanged)

        do {
            _ = try await service.backend(for: original.id, matching: credentialPinned)
            XCTFail("A stale run identity resolved the edited runner configuration.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }

        // A backend already authorized by the old identity retains the exact
        // config, key, and host-key trust bytes it captured at construction.
        _ = try await exactBackend.verifyConnection()
        let invocations = await transport.snapshot()
        let invocation = try XCTUnwrap(invocations.last)
        XCTAssertEqual(invocation.configuration, original)
        XCTAssertEqual(invocation.credential, credential)
        XCTAssertEqual(
            invocation.knownHostsData,
            Data("builder.example.test ssh-ed25519 AAAAoriginal\n".utf8)
        )

        _ = try await service.upsert(original, credential: .unchanged)
        let trustPinned = try await service.executionIdentity(for: original.id)
        try Data("builder.example.test ssh-ed25519 AAAAreplaced\n".utf8)
            .write(to: knownHostsURL)
        do {
            _ = try await service.backend(for: original.id, matching: trustPinned)
            XCTFail("A stale run identity accepted replaced known-host authority.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }
    }

    func testRemoteToolsExposeClosedHostBoundSchemasAndExpectedPermissions() async throws {
        let runnerID = UUID()
        let backend = RemoteBackendProbe(runnerID: runnerID)
        let tools = RemoteToolFactory.makeTools(resolver: RemoteExecutionBackendResolver { id in
            guard id == runnerID else { throw RemoteExecutionError.runnerNotFound(id) }
            return backend
        })
        let registry = ToolRegistry()
        try await registry.register(tools)

        let expected: [String: (AgentToolCategory, AgentPermissionLevel, Bool)] = [
            "remote_file_info": (.filesystem, .read, true),
            "remote_list_directory": (.filesystem, .read, true),
            "remote_read_file": (.filesystem, .read, true),
            "remote_write_file": (.filesystem, .write, false),
            "remote_create_directory": (.filesystem, .write, false),
            "remote_remove": (.filesystem, .dangerous, false),
            "remote_move": (.filesystem, .write, false),
            "remote_git_status": (.git, .read, true),
            "remote_git_diff": (.git, .read, true),
            "remote_git_log": (.git, .read, true),
            "remote_git_add": (.git, .write, false),
            "remote_git_commit": (.git, .write, false),
            "remote_build": (.terminal, .execute, false),
            "remote_test": (.terminal, .execute, false),
            "remote_run_shell": (.terminal, .dangerous, false),
            "remote_pty_run": (.terminal, .dangerous, false)
        ]
        let remoteContext = makeRemoteContext(runnerID: runnerID)
        let localContext = makeRemoteContext(runnerID: runnerID, location: .local)
        let mismatchedContext = makeRemoteContext(
            runnerID: runnerID,
            identityRunnerID: UUID()
        )

        XCTAssertEqual(Set(tools.map(\.name)), RemoteToolFactory.names)
        XCTAssertEqual(Set(expected.keys), RemoteToolFactory.names)
        for tool in tools {
            let metadata = try XCTUnwrap(expected[tool.name])
            XCTAssertEqual(tool.id, "remote.\(tool.name)")
            XCTAssertEqual(tool.category, metadata.0)
            XCTAssertEqual(tool.permissionLevel, metadata.1)
            XCTAssertEqual(tool.supportsParallelExecution, metadata.2)
            XCTAssertTrue(tool.requiresNetwork)
            XCTAssertEqual(tool.inputSchema["type"]?.stringValue, "object")
            XCTAssertEqual(tool.inputSchema["additionalProperties"]?.boolValue, false)
            let properties = tool.inputSchema["properties"]?.objectValue ?? [:]
            for forbidden in [
                "runner_id", "host", "port", "username", "workspace_root",
                "known_hosts_file", "private_key"
            ] {
                XCTAssertNil(properties[forbidden], "\(tool.name) exposes host authority as input.")
            }
            XCTAssertTrue(tool.isAvailable(in: remoteContext))
            XCTAssertFalse(tool.isAvailable(in: localContext))
            XCTAssertFalse(tool.isAvailable(in: mismatchedContext))
            let registered = await registry.tool(named: tool.name)
            XCTAssertNotNil(registered)
        }
    }

    func testRemoteToolsRouteGitAndPTYToContextRunnerAndMarkRemoteEffects() async throws {
        let runnerID = UUID()
        let backend = RemoteBackendProbe(runnerID: runnerID)
        let tools = RemoteToolFactory.makeTools(resolver: RemoteExecutionBackendResolver { id in
            guard id == runnerID else { throw RemoteExecutionError.runnerNotFound(id) }
            return backend
        })
        let context = makeRemoteContext(runnerID: runnerID)

        let diff = try await tool("remote_git_diff", in: tools).execute(
            arguments: .object([
                "staged": .bool(true),
                "paths": .array([.string("Sources/A.swift")])
            ]),
            context: context
        )
        let pty = try await tool("remote_pty_run", in: tools).execute(
            arguments: .object([
                "script": .string("printf ok"),
                "shell": .string("/bin/bash"),
                "environment": .object(["CI": .string("1")]),
                "timeout_seconds": .number(45)
            ]),
            context: context
        )

        let gitRequests = await backend.gitRequests()
        let shellRequests = await backend.shellRequests()
        XCTAssertEqual(gitRequests, [
            .diff(staged: true, paths: ["Sources/A.swift"])
        ])
        XCTAssertEqual(shellRequests, [RemoteShellRequest(
            script: "printf ok",
            shell: .bash,
            environment: ["CI": "1"],
            timeout: 45,
            allocatePTY: true
        )])
        XCTAssertFalse(diff.isError)
        XCTAssertFalse(diff.mayHaveChangedWorkspace)
        XCTAssertTrue(pty.mayHaveChangedWorkspace)
        XCTAssertTrue(pty.content.contains("pty output"))
        XCTAssertEqual(pty.data?["receipt"]?["runnerID"]?.stringValue, runnerID.uuidString)
    }

    func testRemoteToolExecutionRejectsStaleWorkspaceIdentityBeforeResolution() async throws {
        let runnerID = UUID()
        let counter = RemoteResolverCounter()
        let backend = RemoteBackendProbe(runnerID: runnerID)
        let tools = RemoteToolFactory.makeTools(resolver: RemoteExecutionBackendResolver { id in
            await counter.record(id)
            return backend
        })
        var context = makeRemoteContext(runnerID: runnerID)
        context.workspace.rootPath = "/srv/a-different-workspace"

        do {
            _ = try await tool("remote_file_info", in: tools).execute(
                arguments: .object(["path": .string("README.md")]),
                context: context
            )
            XCTFail("A stale workspace identity reached the resolver.")
        } catch {
            XCTAssertEqual((error as? RemoteExecutionError)?.code, .invalidRequest)
        }
        let resolvedIDs = await counter.ids()
        XCTAssertEqual(resolvedIDs, [])
    }
}

private struct RecordedSSHInvocation: Sendable {
    var configuration: RemoteRunnerConfiguration
    var credential: RemoteRunnerCredential?
    var knownHostsData: Data?
    var request: SSHCommandRequest
}

private struct DecodedRemoteWorkspaceTransaction: Decodable {
    var transactionID: String
    var desired: RemoteWorkspaceStateSnapshot
    var baseline: RemoteWorkspaceStateSnapshot
}

private actor RecordingSSHTransport: SSHCommandTransporting {
    private let responses: [String: SSHCommandResult]
    private var invocations: [RecordedSSHInvocation] = []

    init(responses: [String: SSHCommandResult]) {
        self.responses = responses
    }

    func run(
        configuration: RemoteRunnerConfiguration,
        credential: RemoteRunnerCredential?,
        knownHostsData: Data?,
        request: SSHCommandRequest
    ) async throws -> SSHCommandResult {
        invocations.append(RecordedSSHInvocation(
            configuration: configuration,
            credential: credential,
            knownHostsData: knownHostsData,
            request: request
        ))
        guard let response = responses[request.operationLabel] else {
            throw RemoteExecutionError.protocolViolation(
                "Unexpected test transport operation: \(request.operationLabel)"
            )
        }
        return response
    }

    func snapshot() -> [RecordedSSHInvocation] {
        invocations
    }
}

private struct StaticRemoteCredentialProvider: RemoteRunnerCredentialProviding {
    var credential: RemoteRunnerCredential?

    func credential(for runnerID: UUID) throws -> RemoteRunnerCredential? {
        credential
    }
}

private final class InMemoryRemoteRunnerSecretStore: RemoteRunnerSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        lock.lock()
        values[account] = value
        lock.unlock()
    }

    func load(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func delete(account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}

private actor RemoteResolverCounter {
    private var runnerIDs: [UUID] = []

    func record(_ runnerID: UUID) {
        runnerIDs.append(runnerID)
    }

    func ids() -> [UUID] {
        runnerIDs
    }
}

private actor RemoteBackendProbe: RemoteExecutionBackend {
    nonisolated let runnerID: UUID
    private var recordedFilesystemRequests: [RemoteFilesystemRequest] = []
    private var recordedGitRequests: [RemoteGitRequest] = []
    private var recordedBuildRequests: [RemoteValidationRequest] = []
    private var recordedTestRequests: [RemoteValidationRequest] = []
    private var recordedShellRequests: [RemoteShellRequest] = []

    init(runnerID: UUID) {
        self.runnerID = runnerID
    }

    func verifyConnection() async throws -> RemoteHostReceipt {
        makeHostReceipt(runnerID: runnerID)
    }

    func executeFilesystem(
        _ request: RemoteFilesystemRequest
    ) async throws -> RemoteFilesystemResult {
        recordedFilesystemRequests.append(request)
        let path: String
        let payload: RemoteFilesystemPayload
        switch request {
        case .metadata(let requested):
            path = requested
            payload = .metadata(makeMetadata(path: requested))
        case .list(let requested, _):
            path = requested
            payload = .listing([
                RemoteDirectoryEntry(
                    name: "README.md",
                    kind: .file,
                    byteCount: 7,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        case .read(let requested, _):
            path = requested
            payload = .file(
                Data("contents".utf8),
                metadata: makeMetadata(path: requested),
                truncated: false
            )
        case .write(let requested, _, _), .createDirectory(let requested, _):
            path = requested
            payload = .mutation(makeMetadata(path: requested))
        case .remove(let requested):
            path = requested
            payload = .mutation(nil)
        case .move(let source, let destination):
            path = source
            payload = .mutation(makeMetadata(path: destination))
        }
        return RemoteFilesystemResult(
            payload: payload,
            receipt: makeOperationReceipt(
                runnerID: runnerID,
                operation: "filesystem",
                requestedPath: path
            )
        )
    }

    func executeGit(_ request: RemoteGitRequest) async throws -> RemoteGitResult {
        recordedGitRequests.append(request)
        return RemoteGitResult(
            stdout: "git output",
            stderr: "",
            receipt: makeOperationReceipt(runnerID: runnerID, operation: "git")
        )
    }

    func executeBuild(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        recordedBuildRequests.append(request)
        return RemoteValidationResult(
            kind: .build,
            stdout: "build output",
            stderr: "",
            receipt: makeOperationReceipt(runnerID: runnerID, operation: "build")
        )
    }

    func executeTest(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        recordedTestRequests.append(request)
        return RemoteValidationResult(
            kind: .test,
            stdout: "test output",
            stderr: "",
            receipt: makeOperationReceipt(runnerID: runnerID, operation: "test")
        )
    }

    func executeShell(_ request: RemoteShellRequest) async throws -> RemoteShellResult {
        recordedShellRequests.append(request)
        return RemoteShellResult(
            stdout: request.allocatePTY ? "pty output" : "shell output",
            stderr: "",
            receipt: makeOperationReceipt(
                runnerID: runnerID,
                operation: request.allocatePTY ? "pty_run" : "shell"
            )
        )
    }

    nonisolated func makePTYBackend() -> any PTYBackend {
        RemotePTYBackendProbe()
    }

    func filesystemRequests() -> [RemoteFilesystemRequest] {
        recordedFilesystemRequests
    }

    func gitRequests() -> [RemoteGitRequest] {
        recordedGitRequests
    }

    func shellRequests() -> [RemoteShellRequest] {
        recordedShellRequests
    }
}

private struct RemotePTYBackendProbe: PTYBackend {
    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        throw RemoteExecutionError.unsupported("Test PTY backend has no session transport.")
    }
}

private func makeRunner(
    id: UUID = UUID(),
    name: String = "Builder",
    enabled: Bool = true,
    host: String = "builder.example.test",
    workspaceRoot: String = "/srv/luma",
    knownHostsFile: String = AppPaths.projectTemporaryRoot
        .appendingPathComponent("remote-runner-test-known-hosts").path,
    authentication: RemoteSSHAuthentication = .keychainPrivateKey
) -> RemoteRunnerConfiguration {
    RemoteRunnerConfiguration(
        id: id,
        name: name,
        enabled: enabled,
        host: host,
        port: 2222,
        username: "runner",
        workspaceRoot: workspaceRoot,
        knownHostsFile: knownHostsFile,
        authentication: authentication,
        connectTimeout: 15,
        commandTimeout: 120,
        maximumOutputBytes: 1 * 1_024 * 1_024
    )
}

private func makeCredential() -> RemoteRunnerCredential {
    let privateKey = [
        ["-----BEGIN", "OPENSSH PRIVATE KEY-----"].joined(separator: " "),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh",
        "-----END OPENSSH PRIVATE KEY-----"
    ].joined(separator: "\n")
    return RemoteRunnerCredential(privateKey: privateKey)
}

private func makeCommandResult(
    stdout: String,
    stderr: String = "",
    exitCode: Int32 = 0,
    truncated: Bool = false
) -> SSHCommandResult {
    SSHCommandResult(
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001),
        timedOut: false,
        outputTruncated: truncated
    )
}

private func probeJSON() -> String {
    """
    {"hostname":"builder-01","effective_user":"runner","user_id":501,"canonical_workspace_root":"/srv/luma-real"}
    """
}

private func metadataJSON(canonicalPath: String, byteCount: Int64) -> String {
    """
    {"metadata":{"canonical_path":"\(canonicalPath)","kind":"file","byte_count":\(byteCount),"permissions":384,"modified_at":1700000000}}
    """
}

private func makeHostReceipt(runnerID: UUID) -> RemoteHostReceipt {
    RemoteHostReceipt(
        runnerID: runnerID,
        transport: .ssh,
        configuredHost: "builder.example.test",
        configuredPort: 2222,
        configuredUser: "runner",
        serverReportedHostname: "builder-01",
        effectiveUser: "runner",
        effectiveUserID: 501,
        configuredWorkspaceRoot: "/srv/luma",
        canonicalWorkspaceRoot: "/srv/luma-real",
        verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeOperationReceipt(
    runnerID: UUID,
    operation: String,
    requestedPath: String? = "."
) -> RemoteOperationReceipt {
    RemoteOperationReceipt(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        runnerID: runnerID,
        operation: operation,
        host: makeHostReceipt(runnerID: runnerID),
        requestedPath: requestedPath,
        canonicalPath: "/srv/luma-real",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001),
        exitCode: 0,
        timedOut: false,
        outputTruncated: false
    )
}

private func makeMetadata(path: String) -> RemoteFileMetadata {
    RemoteFileMetadata(
        path: path,
        canonicalPath: "/srv/luma-real/\(path)",
        kind: .file,
        byteCount: 8,
        permissions: 0o600,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeRemoteContext(
    runnerID: UUID,
    location: AgentExecutionLocation? = nil,
    identityRunnerID: UUID? = nil
) -> AgentToolContext {
    let workspace = AgentWorkspace(
        name: "remote",
        rootPath: "/srv/luma-real",
        allowedPaths: [],
        bookmarkData: nil,
        gitRepository: true,
        branch: "main"
    )
    return AgentToolContext(
        sessionID: UUID(),
        mode: .agent,
        workspace: workspace,
        executionLocation: location ?? .ssh(runnerID: runnerID, label: "Builder"),
        remoteExecutionIdentity: AgentRemoteExecutionIdentity(
            runnerID: identityRunnerID ?? runnerID,
            backendLabel: "SSH · system OpenSSH",
            host: "builder.example.test",
            port: 2222,
            user: "runner",
            workspaceRoot: workspace.rootPath
        ),
        networkAccess: true
    )
}

private func tool(_ name: String, in tools: [any AgentTool]) throws -> any AgentTool {
    try XCTUnwrap(tools.first { $0.name == name }, "Missing remote tool \(name)")
}

/// Cleanup names only files created by this fixture. `rmdir` succeeds only when
/// the directory is empty, so an unexpected `._*` entry is always preserved.
private func cleanupTestRoot(_ root: URL, knownFiles: [URL]) {
    for file in knownFiles {
        _ = Darwin.unlink(file.path)
    }
    _ = Darwin.rmdir(root.path)
}
