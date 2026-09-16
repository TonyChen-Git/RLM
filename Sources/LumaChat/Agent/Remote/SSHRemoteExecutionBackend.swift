import Foundation

/// Concrete SSH v1 backend. Every operation is bound to one validated runner
/// configuration supplied by the host. Model input can select only an
/// operation and workspace-relative paths; it can never select a host, user,
/// credential, or absolute remote directory.
actor SSHRemoteExecutionBackend: RemoteExecutionBackend, RemoteWorkspaceStateBackend {
    nonisolated let runnerID: UUID

    private let configuration: RemoteRunnerConfiguration
    private let credential: RemoteRunnerCredential?
    private let knownHostsData: Data?
    private let transport: any SSHCommandTransporting
    private var cachedHostReceipt: RemoteHostReceipt?
    private var cachedHostReceiptExpiresAt: Date?

    init(
        configuration rawConfiguration: RemoteRunnerConfiguration,
        credentialProvider: any RemoteRunnerCredentialProviding,
        transport: any SSHCommandTransporting = ProcessSSHCommandTransport()
    ) throws {
        let configuration = try rawConfiguration.validated()
        let supplied = try credentialProvider.credential(for: configuration.id)
        self.configuration = configuration
        runnerID = configuration.id
        credential = configuration.authentication == .systemAgent
            ? nil
            : try supplied?.validated()
        if configuration.authentication == .keychainPrivateKey, credential == nil {
            throw RemoteExecutionError.credentialUnavailable(configuration.id)
        }
        // This initializer is retained as a controlled seam for transport
        // tests. Production construction uses the authority-capturing overload.
        knownHostsData = nil
        self.transport = transport
    }

    init(
        configuration rawConfiguration: RemoteRunnerConfiguration,
        capturedCredential: RemoteRunnerCredential?,
        capturedKnownHostsData: Data,
        transport: any SSHCommandTransporting = ProcessSSHCommandTransport()
    ) throws {
        let configuration = try rawConfiguration.validated()
        self.configuration = configuration
        runnerID = configuration.id
        credential = configuration.authentication == .systemAgent
            ? nil
            : try capturedCredential?.validated()
        if configuration.authentication == .keychainPrivateKey, credential == nil {
            throw RemoteExecutionError.credentialUnavailable(configuration.id)
        }
        guard !capturedKnownHostsData.isEmpty,
              capturedKnownHostsData.count <= RemoteRunnerLimits.maximumKnownHostsBytes else {
            throw RemoteExecutionError.hostVerificationFailed
        }
        knownHostsData = capturedKnownHostsData
        self.transport = transport
    }

    func verifyConnection() async throws -> RemoteHostReceipt {
        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: ["-I", "-c", Self.probeScript, configuration.workspaceRoot],
            timeout: configuration.connectTimeout + 5,
            outputLimit: 64 * 1_024,
            operation: "verify_connection"
        )
        try requireSuccess(result)
        let response: ProbeResponse = try decodeJSON(result.stdout, operation: "probe")
        let canonicalRoot = try RemotePathPolicy.absoluteWorkspaceRoot(
            response.canonicalWorkspaceRoot
        )
        guard response.effectiveUser.utf8.count <= RemoteRunnerLimits.maximumUsernameBytes,
              RemoteTextPolicy.isDisplayText(response.effectiveUser),
              response.hostname.utf8.count <= 255,
              RemoteTextPolicy.isDisplayText(response.hostname),
              let userID = UInt32(exactly: response.userID) else {
            throw RemoteExecutionError.protocolViolation("SSH probe identity is invalid.")
        }
        let receipt = RemoteHostReceipt(
            runnerID: runnerID,
            transport: configuration.transport,
            configuredHost: configuration.host,
            configuredPort: configuration.port,
            configuredUser: configuration.username,
            serverReportedHostname: response.hostname,
            effectiveUser: response.effectiveUser,
            effectiveUserID: userID,
            configuredWorkspaceRoot: configuration.workspaceRoot,
            canonicalWorkspaceRoot: canonicalRoot,
            verifiedAt: Date()
        )
        cachedHostReceipt = receipt
        cachedHostReceiptExpiresAt = Date().addingTimeInterval(30)
        return receipt
    }

    func executeFilesystem(
        _ request: RemoteFilesystemRequest
    ) async throws -> RemoteFilesystemResult {
        let host = try await verifiedHost()
        let operation: String
        let requestedPath: String
        var arguments = ["-I", "-c", Self.filesystemScript]
        var standardInput: Data?
        var outputLimit = min(configuration.maximumOutputBytes, 256 * 1_024)

        switch request {
        case .metadata(let path):
            operation = "file_metadata"
            requestedPath = try RemotePathPolicy.relative(path)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            arguments += ["metadata", host.canonicalWorkspaceRoot, requestedPath]
        case .list(let path, let maximumEntries):
            guard (1...RemoteRunnerLimits.maximumDirectoryEntries).contains(maximumEntries) else {
                throw RemoteExecutionError.invalidRequest("Directory entry limit is invalid.")
            }
            operation = "list_directory"
            requestedPath = try RemotePathPolicy.relative(path)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            let responseBoundedMaximum = max(
                1,
                (configuration.maximumOutputBytes - 2_048) / 2_048
            )
            let effectiveMaximum = min(maximumEntries, responseBoundedMaximum)
            arguments += [
                "list", host.canonicalWorkspaceRoot, requestedPath, String(effectiveMaximum)
            ]
            outputLimit = configuration.maximumOutputBytes
        case .read(let path, let maximumBytes):
            guard (1...RemoteRunnerLimits.maximumFileTransferBytes).contains(maximumBytes) else {
                throw RemoteExecutionError.invalidRequest("Remote file read limit is invalid.")
            }
            operation = "read_file"
            requestedPath = try RemotePathPolicy.relative(path, allowRoot: false)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            // Base64 expands by 4/3. Lower the effective maximum when a
            // runner has intentionally selected a smaller result ceiling and
            // let the payload's `truncated` bit tell the caller more exists.
            let safelyEncodableBytes = max(
                1,
                ((configuration.maximumOutputBytes - 2_048) / 4) * 3
            )
            let effectiveMaximum = min(maximumBytes, safelyEncodableBytes)
            arguments += [
                "read", host.canonicalWorkspaceRoot, requestedPath,
                String(effectiveMaximum)
            ]
            outputLimit = min(
                configuration.maximumOutputBytes,
                max(4_096, ((effectiveMaximum + 2) / 3) * 4 + 2_048)
            )
        case .write(let path, let data, let createParents):
            guard data.count <= RemoteRunnerLimits.maximumFileTransferBytes else {
                throw RemoteExecutionError.invalidRequest("Remote file write exceeds 4 MiB.")
            }
            operation = "write_file"
            requestedPath = try RemotePathPolicy.relative(path, allowRoot: false)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            try RemotePathPolicy.refusesAppleDoubleMutation(requestedPath)
            arguments += [
                "write", host.canonicalWorkspaceRoot, requestedPath,
                createParents ? "1" : "0", String(data.count)
            ]
            standardInput = data
        case .createDirectory(let path, let recursive):
            operation = "create_directory"
            requestedPath = try RemotePathPolicy.relative(path, allowRoot: false)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            try RemotePathPolicy.refusesAppleDoubleMutation(requestedPath)
            arguments += [
                "mkdir", host.canonicalWorkspaceRoot, requestedPath, recursive ? "1" : "0"
            ]
        case .remove(let path):
            operation = "remove"
            requestedPath = try RemotePathPolicy.relative(path, allowRoot: false)
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            try RemotePathPolicy.refusesAppleDoubleMutation(requestedPath)
            arguments += ["remove", host.canonicalWorkspaceRoot, requestedPath]
        case .move(let source, let destination):
            operation = "move"
            requestedPath = try RemotePathPolicy.relative(source, allowRoot: false)
            let normalizedDestination = try RemotePathPolicy.relative(
                destination,
                allowRoot: false
            )
            try RemotePathPolicy.refusesGitAdministrativePath(requestedPath)
            try RemotePathPolicy.refusesGitAdministrativePath(normalizedDestination)
            try RemotePathPolicy.refusesAppleDoubleMutation(requestedPath)
            try RemotePathPolicy.refusesAppleDoubleMutation(normalizedDestination)
            arguments += [
                "move", host.canonicalWorkspaceRoot, requestedPath, normalizedDestination
            ]
        }

        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: arguments,
            standardInput: standardInput,
            timeout: configuration.commandTimeout,
            outputLimit: outputLimit,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: operation
        )
        try requireSuccess(result)
        let response: FilesystemResponse = try decodeJSON(result.stdout, operation: operation)
        let canonicalPath = response.metadata?.canonicalPath ?? response.canonicalPath
        if let canonicalPath {
            try requireCanonicalPath(canonicalPath, inside: host.canonicalWorkspaceRoot)
        }
        var receipt = makeReceipt(
            operation: operation,
            host: host,
            result: result,
            requestedPath: requestedPath,
            canonicalPath: canonicalPath
        )
        if case .list = request, response.truncated == true {
            receipt.outputTruncated = true
        }
        let payload: RemoteFilesystemPayload
        switch request {
        case .metadata:
            payload = .metadata(try response.requiredMetadata(path: requestedPath))
        case .list:
            guard let entries = response.entries,
                  entries.count <= RemoteRunnerLimits.maximumDirectoryEntries else {
                throw RemoteExecutionError.protocolViolation(
                    "Directory listing is missing or exceeds its bound."
                )
            }
            payload = .listing(try entries.map { try $0.model() })
        case .read:
            guard let encoded = response.dataBase64,
                  let data = Data(base64Encoded: encoded),
                  data.count <= RemoteRunnerLimits.maximumFileTransferBytes else {
                throw RemoteExecutionError.protocolViolation("Remote file payload is invalid.")
            }
            payload = .file(
                data,
                metadata: try response.requiredMetadata(path: requestedPath),
                truncated: response.truncated ?? false
            )
        case .write, .createDirectory:
            payload = .mutation(try response.requiredMetadata(path: requestedPath))
        case .move(_, let destination):
            payload = .mutation(try response.requiredMetadata(
                path: RemotePathPolicy.relative(destination, allowRoot: false)
            ))
        case .remove:
            payload = .mutation(nil)
        }
        return RemoteFilesystemResult(payload: payload, receipt: receipt)
    }

    func executeGit(_ request: RemoteGitRequest) async throws -> RemoteGitResult {
        let host = try await verifiedHost()
        var arguments = ["--literal-pathspecs", "-C", host.canonicalWorkspaceRoot]
        let operation: String
        switch request {
        case .status:
            operation = "git_status"
            arguments += ["status", "--short", "--branch"]
        case .diff(let staged, let paths):
            operation = "git_diff"
            arguments.append("diff")
            if staged { arguments.append("--cached") }
            arguments.append("--")
            arguments += try normalizedGitPaths(paths, allowEmpty: true, mutation: false)
        case .log(let maximumCount):
            guard (1...1_000).contains(maximumCount) else {
                throw RemoteExecutionError.invalidRequest("Git log count is outside 1...1000.")
            }
            operation = "git_log"
            arguments += [
                "log", "--date=iso-strict",
                "--pretty=format:%H%x09%an%x09%ad%x09%s", "-n", String(maximumCount)
            ]
        case .add(let paths):
            operation = "git_add"
            arguments += ["add", "--"]
            arguments += try normalizedGitPaths(paths, allowEmpty: false, mutation: true)
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= 64 * 1_024,
                  !message.contains("\0"), RemoteTextPolicy.isDisplayText(message) else {
                throw RemoteExecutionError.invalidRequest("Git commit message is invalid.")
            }
            operation = "git_commit"
            arguments += ["commit", "-m", message]
        }

        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", "-c", Self.gitWorkspaceScript,
                host.canonicalWorkspaceRoot
            ] + arguments,
            workingDirectory: host.canonicalWorkspaceRoot,
            timeout: configuration.commandTimeout,
            outputLimit: configuration.maximumOutputBytes,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: operation
        )
        return RemoteGitResult(
            stdout: result.stdout,
            stderr: result.stderr,
            receipt: makeReceipt(
                operation: operation,
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    func executeBuild(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        guard request.kind == .build else {
            throw RemoteExecutionError.invalidRequest("Build backend received a test request.")
        }
        return try await executeValidation(request)
    }

    func executeTest(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        guard request.kind == .test else {
            throw RemoteExecutionError.invalidRequest("Test backend received a build request.")
        }
        return try await executeValidation(request)
    }

    func executeShell(_ request: RemoteShellRequest) async throws -> RemoteShellResult {
        guard !request.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.script.utf8.count <= RemoteRunnerLimits.maximumShellScriptBytes,
              !request.script.contains("\0") else {
            throw RemoteExecutionError.invalidRequest("Remote shell script is invalid.")
        }
        let timeout = try validatedTimeout(request.timeout)
        let host = try await verifiedHost()
        let result = try await run(
            executable: request.shell.rawValue,
            arguments: ["-s"],
            workingDirectory: host.canonicalWorkspaceRoot,
            environment: request.environment,
            standardInput: Data(request.script.utf8),
            timeout: timeout,
            outputLimit: configuration.maximumOutputBytes,
            allocatePTY: request.allocatePTY,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: request.allocatePTY ? "pty_run" : "shell"
        )
        return RemoteShellResult(
            stdout: result.stdout,
            stderr: result.stderr,
            receipt: makeReceipt(
                operation: request.allocatePTY ? "pty_run" : "shell",
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    func captureWorkspaceState(
        supplementalPaths: [String]
    ) async throws -> RemoteWorkspaceStateCapture {
        guard supplementalPaths.count <= RemoteWorkspaceStateSnapshot.maximumFiles else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration contains too many supplemental roots."
            )
        }
        let paths = try supplementalPaths.map(
            RemoteWorkspaceStateSnapshot.validatedMigrationPath
        )
        guard Set(paths).count == paths.count else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration contains duplicate supplemental roots."
            )
        }
        let host = try await verifiedHost()
        let input = try JSONEncoder().encode(
            RemoteWorkspaceMigrationWire.CaptureRequest(supplementalPaths: paths)
        )
        guard input.count <= RemoteWorkspaceStateSnapshot.maximumWireBytes else {
            throw RemoteExecutionError.invalidRequest(
                "Remote migration capture request exceeds 4 MiB."
            )
        }
        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", "-c", RemoteWorkspaceMigrationWire.program,
                "capture", host.canonicalWorkspaceRoot
            ],
            standardInput: input,
            timeout: configuration.commandTimeout,
            outputLimit: RemoteWorkspaceStateSnapshot.maximumWireBytes,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: "workspace_state_capture"
        )
        try requireSuccess(result)
        guard !result.timedOut, !result.outputTruncated else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace snapshot transport was incomplete."
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              data.count <= RemoteWorkspaceStateSnapshot.maximumWireBytes else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace snapshot is not bounded UTF-8 JSON."
            )
        }
        let decoded: RemoteWorkspaceStateSnapshot
        do {
            decoded = try JSONDecoder().decode(RemoteWorkspaceStateSnapshot.self, from: data)
        } catch {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace snapshot could not be decoded."
            )
        }
        let snapshot = try decoded.validated()
        guard snapshot.sourceRootPath == host.canonicalWorkspaceRoot else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace snapshot came from an unexpected root."
            )
        }
        return RemoteWorkspaceStateCapture(
            snapshot: snapshot,
            receipt: makeReceipt(
                operation: "workspace_state_capture",
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    func applyWorkspaceState(
        _ proposed: RemoteWorkspaceStateSnapshot,
        expectedBaseline proposedBaseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt {
        let snapshot = try proposed.validated()
        let baseline = try proposedBaseline.validated()
        guard baseline.isClean,
              baseline.headObjectID == snapshot.headObjectID,
              baseline.supplementalRoots == snapshot.supplementalRoots else {
            throw RemoteExecutionError.invalidRequest(
                "Remote workspace baseline does not match the transfer contract."
            )
        }
        let host = try await verifiedHost()
        guard baseline.sourceRootPath == host.canonicalWorkspaceRoot else {
            throw RemoteExecutionError.invalidRequest(
                "Remote workspace baseline came from a different canonical root."
            )
        }
        let input = try JSONEncoder().encode(
            RemoteWorkspaceMigrationWire.TransactionRequest(
                transactionID: transactionID.uuidString.lowercased(),
                desired: snapshot,
                baseline: baseline
            )
        )
        guard input.count <= RemoteWorkspaceStateSnapshot.maximumTransactionWireBytes else {
            throw RemoteExecutionError.invalidRequest(
                "Remote workspace transaction exceeds 8 MiB."
            )
        }
        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", "-c", RemoteWorkspaceMigrationWire.program,
                "apply", host.canonicalWorkspaceRoot
            ],
            standardInput: input,
            timeout: configuration.commandTimeout,
            outputLimit: 64 * 1_024,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: "workspace_state_apply"
        )
        try requireSuccess(result)
        guard !result.timedOut, !result.outputTruncated else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace apply acknowledgement was incomplete."
            )
        }
        let acknowledgement: RemoteWorkspaceMigrationWire.Acknowledgement = try decodeJSON(
            result.stdout,
            operation: "workspace state apply"
        )
        guard acknowledgement.status == "applied",
              acknowledgement.headObjectID == snapshot.headObjectID else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace apply acknowledgement is invalid."
            )
        }
        return RemoteWorkspaceTransferReceipt(
            direction: .localToRemote,
            snapshotFingerprint: snapshot.fingerprint,
            operation: makeReceipt(
                operation: "workspace_state_apply",
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    func rollbackWorkspaceState(
        expectedApplied proposed: RemoteWorkspaceStateSnapshot,
        restoring proposedBaseline: RemoteWorkspaceStateSnapshot,
        transactionID: UUID
    ) async throws -> RemoteWorkspaceTransferReceipt {
        let snapshot = try proposed.validated()
        let baseline = try proposedBaseline.validated()
        guard baseline.isClean,
              baseline.headObjectID == snapshot.headObjectID,
              baseline.supplementalRoots == snapshot.supplementalRoots else {
            throw RemoteExecutionError.invalidRequest(
                "Remote rollback baseline does not match the transfer contract."
            )
        }
        let host = try await verifiedHost()
        guard baseline.sourceRootPath == host.canonicalWorkspaceRoot else {
            throw RemoteExecutionError.invalidRequest(
                "Remote rollback baseline came from a different canonical root."
            )
        }
        let input = try JSONEncoder().encode(
            RemoteWorkspaceMigrationWire.TransactionRequest(
                transactionID: transactionID.uuidString.lowercased(),
                desired: snapshot,
                baseline: baseline
            )
        )
        guard input.count <= RemoteWorkspaceStateSnapshot.maximumTransactionWireBytes else {
            throw RemoteExecutionError.invalidRequest(
                "Remote rollback transaction exceeds 8 MiB."
            )
        }
        let result = try await run(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", "-c", RemoteWorkspaceMigrationWire.program,
                "rollback", host.canonicalWorkspaceRoot
            ],
            standardInput: input,
            timeout: configuration.commandTimeout,
            outputLimit: 64 * 1_024,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: "workspace_state_rollback"
        )
        try requireSuccess(result)
        guard !result.timedOut, !result.outputTruncated else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace rollback acknowledgement was incomplete."
            )
        }
        let acknowledgement: RemoteWorkspaceMigrationWire.Acknowledgement = try decodeJSON(
            result.stdout,
            operation: "workspace state rollback"
        )
        guard ["rolled_back", "already_clean"].contains(acknowledgement.status),
              acknowledgement.headObjectID == snapshot.headObjectID else {
            throw RemoteExecutionError.protocolViolation(
                "Remote workspace rollback acknowledgement is invalid."
            )
        }
        return RemoteWorkspaceTransferReceipt(
            direction: .rollbackRemote,
            snapshotFingerprint: snapshot.fingerprint,
            operation: makeReceipt(
                operation: "workspace_state_rollback",
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    /// The v1 SSH transport supports a bounded one-shot PTY (`remote_pty_run`)
    /// but does not pretend it can satisfy Task Terminal's reconnect, resize,
    /// and streaming-input contract.
    nonisolated func makePTYBackend() -> any PTYBackend {
        UnsupportedSSHInteractivePTYBackend()
    }

    private func executeValidation(
        _ request: RemoteValidationRequest
    ) async throws -> RemoteValidationResult {
        let timeout = try validatedTimeout(request.timeout)
        let host = try await verifiedHost()
        let executable = "/usr/bin/env"
        let arguments: [String]
        switch request.toolchain {
        case .swiftPackage:
            arguments = [
                "swift", request.kind == .build ? "build" : "test",
                "--configuration", request.configuration.rawValue
            ]
        case .xcode(let scheme):
            guard !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  scheme.utf8.count <= 512,
                  !scheme.contains("\0"), RemoteTextPolicy.isDisplayText(scheme) else {
                throw RemoteExecutionError.invalidRequest("Xcode scheme is invalid.")
            }
            arguments = [
                "xcodebuild", "-scheme", scheme, "-configuration",
                request.configuration == .debug ? "Debug" : "Release",
                request.kind == .build ? "build" : "test"
            ]
        }
        let result = try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: host.canonicalWorkspaceRoot,
            timeout: timeout,
            outputLimit: configuration.maximumOutputBytes,
            workspaceLeaseRoot: host.canonicalWorkspaceRoot,
            operation: request.kind.rawValue
        )
        return RemoteValidationResult(
            kind: request.kind,
            stdout: result.stdout,
            stderr: result.stderr,
            receipt: makeReceipt(
                operation: request.kind.rawValue,
                host: host,
                result: result,
                requestedPath: ".",
                canonicalPath: host.canonicalWorkspaceRoot
            )
        )
    }

    private func verifiedHost() async throws -> RemoteHostReceipt {
        if let cachedHostReceipt, let expiresAt = cachedHostReceiptExpiresAt,
           expiresAt > Date() {
            return cachedHostReceipt
        }
        return try await verifyConnection()
    }

    private func run(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval,
        outputLimit: Int,
        allocatePTY: Bool = false,
        workspaceLeaseRoot: String? = nil,
        operation: String
    ) async throws -> SSHCommandResult {
        let child = try SSHCommandRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout,
            outputLimit: outputLimit,
            allocatePTY: allocatePTY,
            operationLabel: operation,
            redactionSecrets: []
        ).validated()
        // Every LumaChat operation for one canonical workspace takes the same
        // host-owned lease before exec. This serializes filesystem, Git,
        // migration, build/test and shell operations instead of leaving a
        // check/use window between otherwise independent SSH processes.
        let leaseWait = min(5, max(0.5, timeout / 4))
        var wrapperArguments = [
            "-I", "-c", Self.exclusiveWorkspaceLeaseScript,
            workspaceLeaseRoot ?? configuration.workspaceRoot,
            String(leaseWait),
            child.workingDirectory ?? "",
            String(child.environment.count)
        ]
        for (name, value) in child.environment.sorted(by: { $0.key < $1.key }) {
            wrapperArguments.append(name)
            wrapperArguments.append(value)
        }
        wrapperArguments.append(child.executable)
        wrapperArguments.append(contentsOf: child.arguments)
        return try await transport.run(
            configuration: configuration,
            credential: credential,
            knownHostsData: knownHostsData,
            request: SSHCommandRequest(
                executable: "/usr/bin/python3",
                arguments: wrapperArguments,
                workingDirectory: nil,
                environment: [:],
                standardInput: child.standardInput,
                timeout: child.timeout,
                outputLimit: child.outputLimit,
                allocatePTY: child.allocatePTY,
                operationLabel: child.operationLabel,
                redactionSecrets: child.redactionSecrets + Array(child.environment.values)
            )
        )
    }

    private func requireSuccess(_ result: SSHCommandResult) throws {
        guard result.exitCode == 0 else {
            throw RemoteExecutionError.remoteCommandFailed(
                exitCode: result.exitCode,
                detail: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
    }

    private func validatedTimeout(_ proposed: TimeInterval?) throws -> TimeInterval {
        let value = proposed ?? configuration.commandTimeout
        guard value.isFinite, (0.5...3_600).contains(value) else {
            throw RemoteExecutionError.invalidRequest(
                "Remote timeout is outside 0.5...3600 seconds."
            )
        }
        return value
    }

    private func normalizedGitPaths(
        _ paths: [String],
        allowEmpty: Bool,
        mutation: Bool
    ) throws -> [String] {
        guard paths.count <= RemoteRunnerLimits.maximumArguments,
              allowEmpty || !paths.isEmpty else {
            throw RemoteExecutionError.invalidRequest("Git paths are missing or exceed the limit.")
        }
        return try paths.map { path in
            let normalized = try RemotePathPolicy.relative(path, allowRoot: false)
            if mutation { try RemotePathPolicy.refusesAppleDoubleMutation(normalized) }
            return normalized
        }
    }

    private func requireCanonicalPath(_ path: String, inside root: String) throws {
        let normalizedPath = try RemotePathPolicy.absoluteLocalFile(path)
        let normalizedRoot = try RemotePathPolicy.absoluteWorkspaceRoot(root)
        guard normalizedPath == normalizedRoot
                || normalizedPath.hasPrefix(normalizedRoot + "/") else {
            throw RemoteExecutionError.protocolViolation(
                "Remote canonical path escapes the configured workspace."
            )
        }
    }

    private func makeReceipt(
        operation: String,
        host: RemoteHostReceipt,
        result: SSHCommandResult,
        requestedPath: String?,
        canonicalPath: String?
    ) -> RemoteOperationReceipt {
        RemoteOperationReceipt(
            id: UUID(),
            runnerID: runnerID,
            operation: operation,
            host: host,
            requestedPath: requestedPath,
            canonicalPath: canonicalPath,
            startedAt: result.startedAt,
            completedAt: result.completedAt,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            outputTruncated: result.outputTruncated
        )
    }

    private func decodeJSON<T: Decodable>(
        _ value: String,
        operation: String
    ) throws -> T {
        guard let data = value.data(using: .utf8), data.count <= configuration.maximumOutputBytes else {
            throw RemoteExecutionError.protocolViolation(
                "The \(operation) response is not bounded UTF-8 JSON."
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteExecutionError.protocolViolation(
                "The \(operation) response could not be decoded."
            )
        }
    }

    private struct ProbeResponse: Decodable {
        var hostname: String
        var effectiveUser: String
        var userID: Int64
        var canonicalWorkspaceRoot: String

        private enum CodingKeys: String, CodingKey {
            case hostname
            case effectiveUser = "effective_user"
            case userID = "user_id"
            case canonicalWorkspaceRoot = "canonical_workspace_root"
        }
    }

    private struct FilesystemResponse: Decodable {
        var metadata: WireMetadata?
        var entries: [WireDirectoryEntry]?
        var dataBase64: String?
        var truncated: Bool?
        var canonicalPath: String?

        private enum CodingKeys: String, CodingKey {
            case metadata, entries, truncated
            case dataBase64 = "data_base64"
            case canonicalPath = "canonical_path"
        }

        func requiredMetadata(path: String) throws -> RemoteFileMetadata {
            guard let metadata else {
                throw RemoteExecutionError.protocolViolation("File metadata is missing.")
            }
            return try metadata.model(path: path)
        }
    }

    private struct WireMetadata: Decodable {
        var canonicalPath: String
        var kind: String
        var byteCount: Int64
        var permissions: UInt16
        var modifiedAt: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case kind, permissions
            case canonicalPath = "canonical_path"
            case byteCount = "byte_count"
            case modifiedAt = "modified_at"
        }

        func model(path: String) throws -> RemoteFileMetadata {
            guard let kind = RemoteFileKind(rawValue: kind), byteCount >= 0,
                  modifiedAt.isFinite else {
                throw RemoteExecutionError.protocolViolation("File metadata values are invalid.")
            }
            return RemoteFileMetadata(
                path: path,
                canonicalPath: try RemotePathPolicy.absoluteLocalFile(canonicalPath),
                kind: kind,
                byteCount: byteCount,
                permissions: permissions,
                modifiedAt: Date(timeIntervalSince1970: modifiedAt)
            )
        }
    }

    private struct WireDirectoryEntry: Decodable {
        var name: String
        var kind: String
        var byteCount: Int64
        var modifiedAt: TimeInterval

        private enum CodingKeys: String, CodingKey {
            case name, kind
            case byteCount = "byte_count"
            case modifiedAt = "modified_at"
        }

        func model() throws -> RemoteDirectoryEntry {
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0"),
                  name.utf8.count <= 255, RemoteTextPolicy.isDisplayText(name),
                  let kind = RemoteFileKind(rawValue: kind), byteCount >= 0,
                  modifiedAt.isFinite else {
                throw RemoteExecutionError.protocolViolation(
                    "Directory entry metadata is invalid."
                )
            }
            return RemoteDirectoryEntry(
                name: name,
                kind: kind,
                byteCount: byteCount,
                modifiedAt: Date(timeIntervalSince1970: modifiedAt)
            )
        }
    }

    private static let probeScript = #"""
import json,os,pwd,socket,sys
root=sys.argv[1]
canonical=os.path.realpath(root)
if not os.path.isabs(root) or canonical == "/" or not os.path.isdir(canonical):
    print("workspace root is unavailable",file=sys.stderr);sys.exit(64)
uid=os.geteuid()
print(json.dumps({"hostname":socket.gethostname(),"effective_user":pwd.getpwuid(uid).pw_name,"user_id":uid,"canonical_workspace_root":canonical},separators=(",",":")))
    """#

    /// Git discovers repositories above its `-C` directory. Refuse that
    /// implicit authority expansion before executing any dedicated Git tool.
    private static let gitWorkspaceScript = #"""
import os,stat,subprocess,sys
root=os.path.realpath(sys.argv[1]);arguments=sys.argv[2:]
git="/usr/bin/git" if os.path.isfile("/usr/bin/git") else "/bin/git"
if root=="/" or not os.path.isfile(git):
    print("remote Git workspace is unavailable",file=sys.stderr);sys.exit(64)
try:descriptor=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
except OSError:
    print("remote Git workspace is unsafe",file=sys.stderr);sys.exit(64)
info=os.fstat(descriptor)
environment={"PATH":"/usr/bin:/bin","LC_ALL":"C","LANG":"C","GIT_CONFIG_NOSYSTEM":"1","GIT_TERMINAL_PROMPT":"0"}
if "HOME" in os.environ:environment["HOME"]=os.environ["HOME"]
probe=subprocess.run([git,"--literal-pathspecs","-C",root,"rev-parse","--show-toplevel"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=environment)
if probe.returncode!=0 or len(probe.stdout)>4096:
    print("remote workspace is not a Git repository",file=sys.stderr);sys.exit(64)
try:top=os.path.realpath(probe.stdout.decode("utf-8","strict").strip());current=os.stat(root,follow_symlinks=False)
except (OSError,UnicodeError):
    print("remote Git workspace identity is invalid",file=sys.stderr);sys.exit(75)
if top!=root or current.st_dev!=info.st_dev or current.st_ino!=info.st_ino or not stat.S_ISDIR(current.st_mode):
    print("remote workspace must be the Git repository top-level",file=sys.stderr);sys.exit(75)
os.execve(git,[git]+arguments,environment)
"""#

    /// The isolated wrapper remains the parent and owns the flock until its
    /// child exits. Child cwd/environment are applied only after the lease is
    /// held, so a model-supplied PATH or workspace Python module cannot replace
    /// the lock program itself.
    private static let exclusiveWorkspaceLeaseScript = #"""
import fcntl,os,signal,stat,subprocess,sys,time
root=os.path.realpath(sys.argv[1]);wait=float(sys.argv[2]);requested_cwd=sys.argv[3] or None
try:environment_count=int(sys.argv[4])
except ValueError:
    print("remote workspace lease request is invalid",file=sys.stderr);sys.exit(64)
if root=="/" or not os.path.isdir(root) or wait<0.5 or wait>5.0:
    print("remote workspace lease request is invalid",file=sys.stderr);sys.exit(64)
if environment_count<0 or environment_count>64:
    print("remote child environment is invalid",file=sys.stderr);sys.exit(64)
cursor=5;environment={}
for _ in range(environment_count):
    if cursor+1>=len(sys.argv):
        print("remote child environment is incomplete",file=sys.stderr);sys.exit(64)
    environment[sys.argv[cursor]]=sys.argv[cursor+1];cursor+=2
if cursor>=len(sys.argv):
    print("remote child executable is missing",file=sys.stderr);sys.exit(64)
executable=sys.argv[cursor];arguments=sys.argv[cursor+1:];cwd_components=None
if requested_cwd is not None:
    cwd=os.path.normpath(requested_cwd)
    try:
        if not os.path.isabs(cwd) or os.path.commonpath([root,cwd])!=root:raise ValueError()
    except ValueError:
        print("remote child working directory escaped workspace",file=sys.stderr);sys.exit(64)
    relative=os.path.relpath(cwd,root)
    cwd_components=[] if relative=="." else relative.split(os.sep)
    if any(not value or value in (".","..") for value in cwd_components):
        print("remote child working directory is invalid",file=sys.stderr);sys.exit(64)
try:descriptor=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
except OSError:
    print("remote workspace lease is unsafe",file=sys.stderr);sys.exit(64)
info=os.fstat(descriptor)
if not stat.S_ISDIR(info.st_mode):
    print("remote workspace lease target is invalid",file=sys.stderr);sys.exit(64)
current=os.stat(root,follow_symlinks=False)
if current.st_dev!=info.st_dev or current.st_ino!=info.st_ino:
    print("remote workspace changed while acquiring its lease",file=sys.stderr);sys.exit(75)
deadline=time.monotonic()+wait
while True:
    try:fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB);break
    except BlockingIOError:
        if time.monotonic()>=deadline:
            print("remote workspace is busy",file=sys.stderr);sys.exit(75)
        time.sleep(0.05)
try:current=os.stat(root,follow_symlinks=False)
except OSError:
    print("remote workspace moved while acquiring its lease",file=sys.stderr);sys.exit(75)
if current.st_dev!=info.st_dev or current.st_ino!=info.st_ino:
    print("remote workspace changed while acquiring its lease",file=sys.stderr);sys.exit(75)
if cwd_components is not None:
    cwd_descriptor=os.dup(descriptor)
    try:
        for value in cwd_components:
            next_descriptor=os.open(value,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=cwd_descriptor)
            os.close(cwd_descriptor);cwd_descriptor=next_descriptor
        os.fchdir(cwd_descriptor)
    except OSError:
        print("remote child working directory is unsafe",file=sys.stderr);sys.exit(75)
    finally:
        try:os.close(cwd_descriptor)
        except OSError:pass
child_environment=os.environ.copy();child_environment.update(environment)
child=None
def forward(signum,_frame):
    if child is not None and child.poll() is None:
        try:os.killpg(child.pid,signum)
        except ProcessLookupError:pass
for value in (signal.SIGHUP,signal.SIGINT,signal.SIGTERM):signal.signal(value,forward)
try:
    child=subprocess.Popen([executable]+arguments,cwd=None,env=child_environment,close_fds=True,start_new_session=True)
    status=child.wait()
except OSError as error:
    print("remote child launch failed: %s"%error,file=sys.stderr);sys.exit(71)
# A one-shot command may not leave background descendants mutating the
# workspace after its lease is released. Terminate the private process group
# and keep the directory flock until the group is gone.
try:os.killpg(child.pid,signal.SIGTERM)
except ProcessLookupError:pass
cleanup_deadline=time.monotonic()+1.0
while time.monotonic()<cleanup_deadline:
    try:os.killpg(child.pid,0)
    except ProcessLookupError:break
    time.sleep(0.02)
else:
    try:os.killpg(child.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    kill_deadline=time.monotonic()+1.0
    while time.monotonic()<kill_deadline:
        try:os.killpg(child.pid,0)
        except ProcessLookupError:break
        time.sleep(0.02)
    else:
        print("remote child process group did not terminate",file=sys.stderr);status=75
sys.exit(status if status>=0 else 128-status)
"""#

    private static let filesystemScript = #"""
import base64,ctypes,errno,json,os,secrets,stat,sys
op,root,rel=sys.argv[1],os.path.realpath(sys.argv[2]),sys.argv[3]
def die(message):
    print(message,file=sys.stderr);sys.exit(64)
def components(value):
    if value == ".":return []
    parts=value.split("/")
    if not parts or any(not p or p in (".","..") for p in parts):die("invalid relative path")
    return parts
def apple(parts):
    if any(p.startswith("._") for p in parts):die("AppleDouble paths cannot be mutated")
def open_directory(parts,create=False):
    descriptor=os.dup(root_fd)
    try:
        for part in parts:
            try:next_descriptor=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            except FileNotFoundError:
                if not create:die("parent directory does not exist")
                os.mkdir(part,0o700,dir_fd=descriptor)
                next_descriptor=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor);descriptor=next_descriptor
        return descriptor
    except BaseException:
        try:os.close(descriptor)
        except OSError:pass
        raise
def parent_and_name(parts,create=False):
    if not parts:die("workspace root cannot be mutated")
    return open_directory(parts[:-1],create),parts[-1]
def open_target(parts):
    if not parts:return os.dup(root_fd)
    parent,name=parent_and_name(parts)
    try:return os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent)
    finally:os.close(parent)
def signature(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_uid,info.st_gid,info.st_nlink)
def relocated_signature(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_uid,info.st_gid,info.st_nlink)
def rename_noreplace(source_parent,source_name,destination_parent,destination_name):
    library=ctypes.CDLL(None,use_errno=True)
    source=os.fsencode(source_name);destination=os.fsencode(destination_name)
    if hasattr(library,"renameat2"):
        function=library.renameat2
        function.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
        function.restype=ctypes.c_int
        result=function(source_parent,source,destination_parent,destination,1)
    elif hasattr(library,"renameatx_np"):
        function=library.renameatx_np
        function.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
        function.restype=ctypes.c_int
        result=function(source_parent,source,destination_parent,destination,4)
    else:die("atomic no-replace move is unsupported on this host")
    if result!=0:
        code=ctypes.get_errno()
        if code in (errno.EEXIST,errno.ENOTEMPTY):die("move destination already exists")
        raise OSError(code,os.strerror(code))
def canonical(parts):
    return root if not parts else os.path.join(root,*parts)
def kind(mode):
    if stat.S_ISREG(mode):return "file"
    if stat.S_ISDIR(mode):return "directory"
    if stat.S_ISLNK(mode):return "symbolic_link"
    return "other"
def metadata(info,parts):
    return {"canonical_path":canonical(parts),"kind":kind(info.st_mode),"byte_count":int(info.st_size),"permissions":stat.S_IMODE(info.st_mode),"modified_at":float(info.st_mtime)}
if root=="/" or not os.path.isdir(root):die("invalid workspace root")
try:root_fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
except OSError:die("workspace root cannot be opened safely")
parts=components(rel)
if op=="metadata":
    descriptor=open_target(parts)
    try:result=metadata(os.fstat(descriptor),parts)
    finally:os.close(descriptor)
    print(json.dumps({"metadata":result},separators=(",",":")))
elif op=="list":
    limit=int(sys.argv[4]);descriptor=open_target(parts)
    try:
        info=os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode):die("path is not a directory")
        names=sorted(os.listdir(descriptor));selected=names[:limit];entries=[]
        for name in selected:
            entry=os.stat(name,dir_fd=descriptor,follow_symlinks=False)
            entries.append({"name":name,"kind":kind(entry.st_mode),"byte_count":int(entry.st_size),"modified_at":float(entry.st_mtime)})
    finally:os.close(descriptor)
    print(json.dumps({"entries":entries,"truncated":len(names)>limit,"canonical_path":canonical(parts)},separators=(",",":")))
elif op=="read":
    limit=int(sys.argv[4]);descriptor=open_target(parts)
    try:
        before=os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):die("path is not a regular file")
        chunks=[];remaining=limit+1
        while remaining:
            chunk=os.read(descriptor,min(65536,remaining))
            if not chunk:break
            chunks.append(chunk);remaining-=len(chunk)
        after=os.fstat(descriptor)
        if signature(before)!=signature(after):die("file changed while it was read")
    finally:os.close(descriptor)
    data=b"".join(chunks);truncated=len(data)>limit;data=data[:limit]
    print(json.dumps({"metadata":metadata(after,parts),"data_base64":base64.b64encode(data).decode("ascii"),"truncated":truncated},separators=(",",":")))
elif op=="write":
    apple(parts);create=sys.argv[4]=="1";expected=int(sys.argv[5]);parent,name=parent_and_name(parts,create)
    try:
        try:before=os.stat(name,dir_fd=parent,follow_symlinks=False)
        except FileNotFoundError:before=None
        if before is not None and not stat.S_ISREG(before.st_mode):die("write target is not a regular file")
        mode=stat.S_IMODE(before.st_mode) if before is not None else 0o600
        data=sys.stdin.buffer.read(expected+1)
        if len(data)!=expected:die("write payload length mismatch")
        temporary=None
        try:
            temporary=".lumachat-write-"+secrets.token_hex(16)
            temporary_descriptor=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=parent)
            try:
                offset=0
                while offset<len(data):
                    written=os.write(temporary_descriptor,data[offset:])
                    if written<=0:die("remote write made no progress")
                    offset+=written
                os.fchmod(temporary_descriptor,mode);os.fsync(temporary_descriptor)
            finally:os.close(temporary_descriptor)
            try:current=os.stat(name,dir_fd=parent,follow_symlinks=False)
            except FileNotFoundError:current=None
            if (before is None)!=(current is None) or (before is not None and signature(before)!=signature(current)):die("write target changed during operation")
            os.replace(temporary,name,src_dir_fd=parent,dst_dir_fd=parent);temporary=None;os.fsync(parent)
            installed=os.stat(name,dir_fd=parent,follow_symlinks=False)
        finally:
            if temporary is not None:
                try:os.unlink(temporary,dir_fd=parent)
                except OSError:pass
    finally:os.close(parent)
    print(json.dumps({"metadata":metadata(installed,parts)},separators=(",",":")))
elif op=="mkdir":
    apple(parts);recursive=sys.argv[4]=="1"
    if recursive:
        descriptor=open_directory(parts,True)
        try:installed=os.fstat(descriptor)
        finally:os.close(descriptor)
    else:
        parent,name=parent_and_name(parts)
        try:os.mkdir(name,0o700,dir_fd=parent);installed=os.stat(name,dir_fd=parent,follow_symlinks=False);os.fsync(parent)
        finally:os.close(parent)
    print(json.dumps({"metadata":metadata(installed,parts)},separators=(",",":")))
elif op=="remove":
    apple(parts);parent,name=parent_and_name(parts)
    try:
        before=os.stat(name,dir_fd=parent,follow_symlinks=False)
        if not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode)):die("only regular files and empty directories can be removed")
        current=os.stat(name,dir_fd=parent,follow_symlinks=False)
        if signature(before)!=signature(current):die("remove target changed during operation")
        os.rmdir(name,dir_fd=parent) if stat.S_ISDIR(before.st_mode) else os.unlink(name,dir_fd=parent)
        os.fsync(parent)
    finally:os.close(parent)
    print(json.dumps({"canonical_path":canonical(parts)},separators=(",",":")))
elif op=="move":
    apple(parts);destination_parts=components(sys.argv[4]);apple(destination_parts)
    source_parent,source_name=parent_and_name(parts);destination_parent,destination_name=parent_and_name(destination_parts)
    try:
        source=os.stat(source_name,dir_fd=source_parent,follow_symlinks=False)
        if not (stat.S_ISREG(source.st_mode) or stat.S_ISDIR(source.st_mode)):die("move source type is unsupported")
        try:os.stat(destination_name,dir_fd=destination_parent,follow_symlinks=False);die("move destination already exists")
        except FileNotFoundError:pass
        if signature(source)!=signature(os.stat(source_name,dir_fd=source_parent,follow_symlinks=False)):die("move source changed during operation")
        rename_noreplace(source_parent,source_name,destination_parent,destination_name)
        os.fsync(source_parent);os.fsync(destination_parent)
        installed=os.stat(destination_name,dir_fd=destination_parent,follow_symlinks=False)
        if relocated_signature(source)!=relocated_signature(installed):die("move source changed during operation")
    finally:os.close(source_parent);os.close(destination_parent)
    print(json.dumps({"metadata":metadata(installed,destination_parts)},separators=(",",":")))
else:die("unsupported filesystem operation")
"""#
}

private struct UnsupportedSSHInteractivePTYBackend: PTYBackend {
    func makeSession(
        validator: WorkspaceSecurityValidator,
        cwd: String?,
        environment: [String: String]
    ) throws -> any PTYSessionTransport {
        throw RemoteExecutionError.unsupported(
            "SSH v1 exposes remote_pty_run, but persistent Task Terminal reconnect/input is not available."
        )
    }
}
