import Foundation
import XCTest

@testable import LumaChat

final class TaskTerminalToolTests: XCTestCase {
    private static let toolNames = [
        "terminal_create",
        "terminal_write",
        "terminal_resize",
        "terminal_read",
        "terminal_signal",
        "terminal_close",
    ]

    func testSixTaskTerminalToolsRegisterWithExactMetadataAndClosedSchemas() async throws {
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(in: registry, todoManager: TodoManager())
        let expectedPermissions: [String: AgentPermissionLevel] = [
            "terminal_create": .execute,
            "terminal_write": .execute,
            "terminal_resize": .execute,
            "terminal_read": .read,
            "terminal_signal": .execute,
            "terminal_close": .execute,
        ]
        let expectedRequired: [String: Set<String>] = [
            "terminal_create": [],
            "terminal_write": ["terminal_id"],
            "terminal_resize": ["terminal_id", "rows", "columns"],
            "terminal_read": ["terminal_id"],
            "terminal_signal": ["terminal_id", "signal"],
            "terminal_close": ["terminal_id"],
        ]

        for name in Self.toolNames {
            let registered = await registry.tool(named: name)
            let tool = try XCTUnwrap(registered, "missing \(name)")
            let expectedPermission = try XCTUnwrap(expectedPermissions[name])
            let requiredArguments = try XCTUnwrap(expectedRequired[name])
            XCTAssertEqual(tool.id, "builtin.\(name)")
            XCTAssertEqual(tool.category, .terminal)
            XCTAssertEqual(tool.permissionLevel, expectedPermission)
            XCTAssertFalse(tool.requiresNetwork)
            XCTAssertEqual(tool.supportsParallelExecution, name == "terminal_read")
            XCTAssertEqual(tool.inputSchema["additionalProperties"]?.boolValue, false)
            XCTAssertEqual(
                Set(tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                requiredArguments
            )
        }
    }

    func testPermissionManagerAllowsReadButGatesEveryTaskTerminalMutation() async throws {
        let fixture = try makeFixture("permissions")
        defer { fixture.remove() }
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(in: registry, todoManager: TodoManager())
        let manager = PermissionManager()
        let context = fixture.context(sessionID: UUID(), mode: .agent)

        for name in Self.toolNames {
            let registered = await registry.metadata(named: name)
            let metadata = try XCTUnwrap(registered)
            let call = AgentToolCall(name: name, arguments: permissionArguments(for: name))
            let authorization = await manager.authorize(
                metadata: metadata,
                call: call,
                context: context,
                permissionMode: .askEveryTime,
                networkAccess: false
            )
            if name == "terminal_read" {
                XCTAssertEqual(authorization, .allow)
            } else {
                guard case .requireApproval(let level, _) = authorization else {
                    XCTFail("\(name) bypassed execute approval: \(authorization)")
                    continue
                }
                XCTAssertEqual(level, .execute)
            }
        }

        let planContext = fixture.context(sessionID: UUID(), mode: .plan)
        let registeredRead = await registry.metadata(named: "terminal_read")
        let readMetadata = try XCTUnwrap(registeredRead)
        let planReadAuthorization = await manager.authorize(
            metadata: readMetadata,
            call: AgentToolCall(
                name: "terminal_read",
                arguments: permissionArguments(for: "terminal_read")
            ),
            context: planContext,
            permissionMode: .fullAccess,
            networkAccess: false
        )
        XCTAssertEqual(planReadAuthorization, .allow)
        for name in Self.toolNames where name != "terminal_read" {
            let registered = await registry.metadata(named: name)
            let metadata = try XCTUnwrap(registered)
            let authorization = await manager.authorize(
                metadata: metadata,
                call: AgentToolCall(name: name, arguments: permissionArguments(for: name)),
                context: planContext,
                permissionMode: .fullAccess,
                networkAccess: true
            )
            guard case .deny(let reason) = authorization else {
                XCTFail("Plan mode allowed \(name): \(authorization)")
                continue
            }
            XCTAssertTrue(reason.contains("Plan"))
        }

        // Exercise the same decisions through the production registry,
        // permission manager and executor pipeline, before any PTY service is
        // allowed to resolve the supplied terminal ID.
        let executor = ToolExecutor(registry: registry)
        let mutationCall = AgentToolCall(
            name: "terminal_write",
            arguments: permissionArguments(for: "terminal_write")
        )
        let planResult = try await executor.execute(
            mutationCall,
            context: planContext,
            permissionMode: .fullAccess,
            networkAccess: true,
            approvalHandler: nil
        )
        XCTAssertTrue(planResult.isError)
        XCTAssertTrue(planResult.content.contains("Plan"))

        let planRead = try await executor.execute(
            AgentToolCall(
                name: "terminal_read",
                arguments: permissionArguments(for: "terminal_read")
            ),
            context: planContext,
            permissionMode: .fullAccess,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(planRead.isError)
        XCTAssertTrue(planRead.content.contains("does not belong to this Task"))
        XCTAssertFalse(planRead.content.contains("Plan 模式只允許"))

        let unapproved = try await executor.execute(
            mutationCall,
            context: context,
            permissionMode: .autoApproveSafe,
            networkAccess: false,
            approvalHandler: nil
        )
        XCTAssertTrue(unapproved.isError)
        XCTAssertTrue(unapproved.content.contains("未獲得使用者核准"))

        let denied = try await executor.execute(
            mutationCall,
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false,
            approvalHandler: { request in
                XCTAssertEqual(request.toolName, "terminal_write")
                XCTAssertEqual(request.permissionLevel, .execute)
                return .deny
            }
        )
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.content.contains("使用者拒絕"))
    }

    func testTaskTerminalArgumentValidationRejectsUnknownTypesRangesUUIDsAnd64KiBLimits() async throws {
        let fixture = try makeFixture("validation")
        defer { fixture.remove() }
        let environment = BuiltinToolEnvironment()
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let executor = ToolExecutor(registry: registry)
        let taskID = UUID()
        defer { fixture.removeTaskData(taskID) }
        let context = fixture.context(sessionID: taskID)
        let validID = UUID().uuidString
        let oversized = String(repeating: "x", count: 64 * 1_024 + 1)
        let environmentLimit = String(repeating: "e", count: 32 * 1_024)
        let cases: [(name: String, arguments: JSONValue, expected: String)] = [
            (
                "terminal_create",
                .object(["rows": .string("24")]),
                "rows must be an integer"
            ),
            (
                "terminal_create",
                .object(["columns": .number(0)]),
                "columns must be an integer in 1...1000"
            ),
            (
                "terminal_create",
                .object([
                    "environment": .object([
                        "A": .string(environmentLimit),
                        "B": .string(environmentLimit),
                    ])
                ]),
                "65536-byte aggregate limit"
            ),
            (
                "terminal_write",
                .object(["terminal_id": .string(validID), "input": .string(oversized)]),
                "at most 65536 UTF-8 bytes"
            ),
            (
                "terminal_write",
                .object(["terminal_id": .string(validID), "eof": .string("true")]),
                "eof must be a boolean"
            ),
            (
                "terminal_resize",
                .object([
                    "terminal_id": .string(validID),
                    "rows": .number(24.5),
                    "columns": .number(80),
                ]),
                "rows must be an integer"
            ),
            (
                "terminal_resize",
                .object([
                    "terminal_id": .string(validID),
                    "rows": .number(24),
                    "columns": .number(1_001),
                ]),
                "columns must be an integer in 1...1000"
            ),
            (
                "terminal_read",
                .object(["terminal_id": .string(validID), "offset": .number(-1)]),
                "offset must be an integer in 0"
            ),
            (
                "terminal_read",
                .object(["terminal_id": .string(validID), "max_bytes": .number(65_537)]),
                "max_bytes must be an integer in 1...65536"
            ),
            (
                "terminal_signal",
                .object([
                    "terminal_id": .string(validID),
                    "signal": .string("SIGUSR1"),
                ]),
                "signal is not supported"
            ),
            (
                "terminal_close",
                .object(["terminal_id": .number(42)]),
                "terminal_id must be a UUID"
            ),
        ]

        for item in cases {
            let result = try await execute(
                item.name,
                arguments: item.arguments,
                executor: executor,
                context: context
            )
            XCTAssertTrue(result.isError, "\(item.name) unexpectedly accepted \(item.arguments)")
            XCTAssertTrue(
                result.content.contains(item.expected),
                "\(item.name) returned unexpected validation text: \(result.content)"
            )
        }

        for name in Self.toolNames {
            var arguments = try XCTUnwrap(permissionArguments(for: name).objectValue)
            arguments["unexpected"] = .bool(true)
            let result = try await execute(
                name,
                arguments: .object(arguments),
                executor: executor,
                context: context
            )
            XCTAssertTrue(result.isError, "\(name) accepted an unknown key")
            XCTAssertTrue(result.content.contains("unsupported argument field"))
        }

        for name in Self.toolNames where name != "terminal_create" {
            var arguments = try XCTUnwrap(permissionArguments(for: name).objectValue)
            arguments["terminal_id"] = .string("not-a-uuid")
            let result = try await execute(
                name,
                arguments: .object(arguments),
                executor: executor,
                context: context
            )
            XCTAssertTrue(result.isError, "\(name) accepted a malformed terminal UUID")
            XCTAssertTrue(result.content.contains("terminal_id must be a UUID"))
        }

        let exactBoundary = try await execute(
            "terminal_write",
            arguments: .object([
                "terminal_id": .string(validID),
                "input": .string(String(repeating: "b", count: 64 * 1_024)),
            ]),
            executor: executor,
            context: context
        )
        XCTAssertTrue(exactBoundary.isError)
        XCTAssertTrue(exactBoundary.content.contains("does not belong to this Task"))
        XCTAssertFalse(exactBoundary.content.contains("at most 65536 UTF-8 bytes"))

        await environment.stopAllProcesses()
    }

    func testExecutorEnforcesTaskIsolationDynamicNetworkCapabilityAndSafeDescriptors() async throws {
        let fixture = try makeFixture("isolation-network")
        defer { fixture.remove() }
        let environment = BuiltinToolEnvironment()
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let executor = ToolExecutor(registry: registry)
        let sharedSession = UUID()
        let firstTask = UUID()
        let secondTask = UUID()
        let networkTask = UUID()
        defer { fixture.removeTaskData([firstTask, secondTask, networkTask]) }
        // Deliberately disagree with the executor argument. ToolExecutor must
        // replace this base value with the globally authorized capability.
        var firstContext = fixture.context(sessionID: sharedSession, taskID: firstTask)
        firstContext.networkAccess = true
        var secondContext = fixture.context(sessionID: sharedSession, taskID: secondTask)
        secondContext.networkAccess = true

        do {
            let created = try await execute(
                "terminal_create",
                arguments: .object([
                    "title": .string("token=ghp_abcdefghijklmnop"),
                    "shell": .string("/bin/sh"),
                ]),
                executor: executor,
                context: firstContext,
                networkAccess: false
            )
            XCTAssertFalse(created.isError, created.content)
            let terminalID = try XCTUnwrap(
                created.data?["terminal_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            assertDescriptorDataIsModelSafe(created.data, fixture: fixture)
            XCTAssertFalse(created.content.contains("ghp_abcdefghijklmnop"))
            XCTAssertEqual(created.data?["title"]?.stringValue, "token=[REDACTED]")

            let firstDescriptors = try await environment.taskTerminalDescriptors(
                context: firstContext
            )
            let firstDescriptor = try XCTUnwrap(firstDescriptors.first { $0.id == terminalID })
            XCTAssertEqual(firstDescriptor.metadata.taskID, firstTask)
            XCTAssertEqual(firstDescriptor.metadata.capabilities?.network, false)
            XCTAssertNotNil(firstDescriptor.processIdentifier)

            let crossTaskRead = try await execute(
                "terminal_read",
                arguments: .object(["terminal_id": .string(terminalID.uuidString)]),
                executor: executor,
                context: secondContext,
                networkAccess: false
            )
            XCTAssertTrue(crossTaskRead.isError)
            XCTAssertTrue(crossTaskRead.content.contains("does not belong to this Task"))

            let unknownClose = try await execute(
                "terminal_close",
                arguments: .object(["terminal_id": .string(UUID().uuidString)]),
                executor: executor,
                context: firstContext,
                networkAccess: false
            )
            XCTAssertTrue(unknownClose.isError)
            XCTAssertTrue(unknownClose.content.contains("does not belong to this Task"))

            var networkContext = fixture.context(sessionID: networkTask)
            networkContext.networkAccess = false
            let networkCreated = try await execute(
                "terminal_create",
                arguments: .object(["shell": .string("/bin/sh")]),
                executor: executor,
                context: networkContext,
                networkAccess: true
            )
            XCTAssertFalse(networkCreated.isError, networkCreated.content)
            let networkID = try XCTUnwrap(
                networkCreated.data?["terminal_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )
            let networkDescriptors = try await environment.taskTerminalDescriptors(
                context: networkContext
            )
            XCTAssertEqual(
                networkDescriptors.first(where: { $0.id == networkID })?.metadata.capabilities?.network,
                true
            )
            assertDescriptorDataIsModelSafe(networkCreated.data, fixture: fixture)

            _ = try await execute(
                "terminal_close",
                arguments: .object(["terminal_id": .string(networkID.uuidString)]),
                executor: executor,
                context: networkContext,
                networkAccess: true
            )
            _ = try await execute(
                "terminal_close",
                arguments: .object(["terminal_id": .string(terminalID.uuidString)]),
                executor: executor,
                context: firstContext,
                networkAccess: false
            )
        } catch {
            await environment.stopAllProcesses()
            throw error
        }
        await environment.stopAllProcesses()
    }

    func testTerminalReadIsBoundedAndRendersANSIOSCSecretsPathsAndControlsAsInertText() async throws {
        let fixture = try makeFixture("inert-read")
        defer { fixture.remove() }
        let environment = BuiltinToolEnvironment()
        let registry = ToolRegistry()
        try await BuiltinToolFactory.register(
            in: registry,
            environment: environment,
            todoManager: TodoManager()
        )
        let executor = ToolExecutor(registry: registry)
        let taskID = UUID()
        defer { fixture.removeTaskData(taskID) }
        let context = fixture.context(sessionID: taskID)
        let secret = "terminal-secret-987654321"

        do {
            let created = try await execute(
                "terminal_create",
                arguments: .object([
                    "shell": .string("/bin/sh"),
                    "environment": .object([
                        "ROOT_PATH": .string(fixture.workspaceRoot.path),
                        "ALLOWED_PATH": .string(fixture.allowedRoot.path),
                        "TEST_SECRET": .string(secret),
                    ]),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(created.isError, created.content)
            let terminalID = try XCTUnwrap(
                created.data?["terminal_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            )

            let resized = try await execute(
                "terminal_resize",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "rows": .number(30),
                    "columns": .number(100),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(resized.isError, resized.content)
            XCTAssertEqual(resized.data?["rows"]?.intValue, 30)
            XCTAssertEqual(resized.data?["columns"]?.intValue, 100)
            assertDescriptorDataIsModelSafe(resized.data, fixture: fixture)

            let resumed = try await execute(
                "terminal_signal",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "signal": .string(TaskTerminalSignal.resume.rawValue),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(resumed.isError, resumed.content)
            assertDescriptorDataIsModelSafe(resumed.data, fixture: fixture)

            let echoDisabled = try await execute(
                "terminal_write",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "input": .string("stty -echo\n"),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(echoDisabled.isError, echoDisabled.content)
            XCTAssertNil(echoDisabled.data?["input"])
            assertDescriptorDataIsModelSafe(echoDisabled.data, fixture: fixture)
            try await Task.sleep(for: .milliseconds(100))
            let sanitizationOffset = try await outputEnd(
                environment: environment,
                context: context,
                terminalID: terminalID
            )
            let hostileCommand = #"/usr/bin/perl -CS -e '$|=1; print qq{\e[31mVISIBLE\e[0m\n}; print qq{\e]52;c;OSC_PAYLOAD\aAFTER_OSC\n}; print qq{\x{202E}BIDI\x01CONTROL\n}; print qq{password=$ENV{TEST_SECRET}\n}; print qq{$ENV{ROOT_PATH}\n}; print qq{$ENV{ALLOWED_PATH}\n}; print qq{SANITIZE_END\n};'"# + "\n"
            let writeResult = try await execute(
                "terminal_write",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "input": .string(hostileCommand),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(writeResult.isError, writeResult.content)
            XCTAssertFalse(writeResult.content.contains(hostileCommand))
            XCTAssertFalse(encode(writeResult.data).contains("OSC_PAYLOAD"))
            XCTAssertNil(writeResult.data?["input"])
            assertDescriptorDataIsModelSafe(writeResult.data, fixture: fixture)

            let sanitized = try await waitForToolRead(
                executor: executor,
                context: context,
                terminalID: terminalID,
                offset: sanitizationOffset,
                containing: "SANITIZE_END"
            )
            let rendered = try XCTUnwrap(sanitized.data?["text"]?.stringValue)
            XCTAssertTrue(sanitized.content.contains("UNTRUSTED TERMINAL OUTPUT"))
            XCTAssertTrue(rendered.contains("VISIBLE"))
            XCTAssertTrue(rendered.contains("AFTER_OSC"))
            XCTAssertTrue(rendered.contains("BIDICONTROL"))
            XCTAssertFalse(rendered.contains("OSC_PAYLOAD"))
            XCTAssertFalse(rendered.contains("\u{001B}"))
            XCTAssertFalse(rendered.contains("\u{202E}"))
            XCTAssertFalse(rendered.contains("\u{0001}"))
            XCTAssertFalse(rendered.contains(secret))
            XCTAssertTrue(rendered.contains("password=[REDACTED]"))
            XCTAssertFalse(rendered.contains(fixture.workspaceRoot.path))
            XCTAssertFalse(rendered.contains(fixture.allowedRoot.path))
            XCTAssertFalse(sanitized.content.contains(secret))
            XCTAssertFalse(sanitized.content.contains("OSC_PAYLOAD"))
            XCTAssertFalse(sanitized.content.contains(fixture.workspaceRoot.path))
            XCTAssertFalse(sanitized.content.contains(fixture.allowedRoot.path))
            assertReadDataIsModelSafe(sanitized.data, fixture: fixture)

            let largeOffset = try await outputEnd(
                environment: environment,
                context: context,
                terminalID: terminalID
            )
            let largeCommand = #"/usr/bin/perl -e 'print q{Z} x 70000; print qq{LARGE_END\n};'"# + "\n"
            _ = try await execute(
                "terminal_write",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "input": .string(largeCommand),
                ]),
                executor: executor,
                context: context
            )
            try await waitForOutputEnd(
                atLeast: largeOffset + 70_010,
                environment: environment,
                context: context,
                terminalID: terminalID
            )
            let bounded = try await execute(
                "terminal_read",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "offset": .number(Double(largeOffset)),
                    "max_bytes": .number(64 * 1_024),
                ]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(bounded.isError, bounded.content)
            XCTAssertEqual(bounded.data?["raw_byte_count"]?.intValue, 64 * 1_024)
            XCTAssertEqual(bounded.data?["has_more"]?.boolValue, true)
            XCTAssertEqual(bounded.data?["rendered_text_truncated"]?.boolValue, true)
            XCTAssertLessThanOrEqual(
                bounded.data?["text"]?.stringValue?.utf8.count ?? Int.max,
                18 * 1_024
            )
            XCTAssertTrue(bounded.truncated)
            assertReadDataIsModelSafe(bounded.data, fixture: fixture)

            let closed = try await execute(
                "terminal_close",
                arguments: .object(["terminal_id": .string(terminalID.uuidString)]),
                executor: executor,
                context: context
            )
            XCTAssertFalse(closed.isError, closed.content)
            XCTAssertEqual(closed.data?["closed"]?.boolValue, true)
            assertDescriptorDataIsModelSafe(closed.data, fixture: fixture)
        } catch {
            await environment.stopAllProcesses()
            throw error
        }
        await environment.stopAllProcesses()
    }

    private struct Fixture {
        var scratch: URL
        var workspaceRoot: URL
        var allowedRoot: URL
        var workspace: AgentWorkspace

        func context(
            sessionID: UUID,
            taskID: UUID? = nil,
            mode: AppMode = .agent
        ) -> AgentToolContext {
            AgentToolContext(
                sessionID: sessionID,
                taskID: taskID ?? sessionID,
                mode: mode,
                workspace: workspace,
                temporaryRoot: scratch.appendingPathComponent("temporary", isDirectory: true),
                commandTimeout: 10
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }

        func removeTaskData(_ taskID: UUID) {
            removeTaskData([taskID])
        }

        func removeTaskData(_ taskIDs: [UUID]) {
            for taskID in taskIDs {
                try? FileManager.default.removeItem(
                    at: AppPaths.agentSessionDirectory(taskID)
                )
            }
        }
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let scratch = AppPaths.projectTemporaryRoot
            .appendingPathComponent("task-terminal-tool-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = scratch.appendingPathComponent("workspace", isDirectory: true)
        let allowedRoot = scratch.appendingPathComponent("external-allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        let workspace = AgentWorkspace(
            name: workspaceRoot.lastPathComponent,
            rootPath: workspaceRoot.path,
            allowedPaths: [allowedRoot.path],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        return Fixture(
            scratch: scratch,
            workspaceRoot: workspaceRoot,
            allowedRoot: allowedRoot,
            workspace: workspace
        )
    }

    private func permissionArguments(for name: String) -> JSONValue {
        let id = UUID().uuidString
        switch name {
        case "terminal_create":
            return .emptyObject
        case "terminal_write":
            return .object(["terminal_id": .string(id), "input": .string("x")])
        case "terminal_resize":
            return .object([
                "terminal_id": .string(id),
                "rows": .number(24),
                "columns": .number(80),
            ])
        case "terminal_read", "terminal_close":
            return .object(["terminal_id": .string(id)])
        case "terminal_signal":
            return .object([
                "terminal_id": .string(id),
                "signal": .string(TaskTerminalSignal.interrupt.rawValue),
            ])
        default:
            return .emptyObject
        }
    }

    private func execute(
        _ name: String,
        arguments: JSONValue,
        executor: ToolExecutor,
        context: AgentToolContext,
        networkAccess: Bool = false
    ) async throws -> AgentToolResult {
        try await executor.execute(
            AgentToolCall(name: name, arguments: arguments),
            context: context,
            permissionMode: .fullAccess,
            networkAccess: networkAccess,
            approvalHandler: nil
        )
    }

    private func outputEnd(
        environment: BuiltinToolEnvironment,
        context: AgentToolContext,
        terminalID: UUID
    ) async throws -> Int64 {
        let descriptors = try await environment.taskTerminalDescriptors(context: context)
        return try XCTUnwrap(descriptors.first(where: { $0.id == terminalID }))
            .nextOffset
    }

    private func waitForOutputEnd(
        atLeast expected: Int64,
        environment: BuiltinToolEnvironment,
        context: AgentToolContext,
        terminalID: UUID,
        timeout: Duration = .seconds(5)
    ) async throws {
        let started = ContinuousClock.now
        while started.duration(to: .now) < timeout {
            if try await outputEnd(
                environment: environment,
                context: context,
                terminalID: terminalID
            ) >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Task terminal output to reach \(expected)")
    }

    private func waitForToolRead(
        executor: ToolExecutor,
        context: AgentToolContext,
        terminalID: UUID,
        offset: Int64,
        containing expected: String,
        timeout: Duration = .seconds(5)
    ) async throws -> AgentToolResult {
        let started = ContinuousClock.now
        var last = AgentToolResult(content: "")
        while started.duration(to: .now) < timeout {
            last = try await execute(
                "terminal_read",
                arguments: .object([
                    "terminal_id": .string(terminalID.uuidString),
                    "offset": .number(Double(offset)),
                    "max_bytes": .number(64 * 1_024),
                ]),
                executor: executor,
                context: context
            )
            if last.data?["text"]?.stringValue?.contains(expected) == true {
                return last
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for sanitized terminal output: \(expected). Last: \(last.content)")
        return last
    }

    private func assertDescriptorDataIsModelSafe(
        _ data: JSONValue?,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keys = collectKeys(data)
        for forbidden in ["pid", "fd", "process_identifier", "workspace_root", "root_path"] {
            XCTAssertFalse(keys.contains(forbidden), "leaked key \(forbidden)", file: file, line: line)
        }
        let encoded = encode(data)
        XCTAssertFalse(encoded.contains(fixture.workspaceRoot.path), file: file, line: line)
        XCTAssertFalse(encoded.contains(fixture.allowedRoot.path), file: file, line: line)
    }

    private func assertReadDataIsModelSafe(
        _ data: JSONValue?,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let keys = collectKeys(data)
        for forbidden in [
            "data", "raw", "raw_data", "bytes", "pid", "fd", "process_identifier",
            "workspace_root", "root_path",
        ] {
            XCTAssertFalse(keys.contains(forbidden), "leaked key \(forbidden)", file: file, line: line)
        }
        let encoded = encode(data)
        XCTAssertFalse(encoded.contains(fixture.workspaceRoot.path), file: file, line: line)
        XCTAssertFalse(encoded.contains(fixture.allowedRoot.path), file: file, line: line)
        XCTAssertFalse(encoded.lowercased().contains("\\u001b"), file: file, line: line)
    }

    private func collectKeys(_ value: JSONValue?) -> Set<String> {
        guard let value else { return [] }
        switch value {
        case .object(let object):
            var result = Set(object.keys)
            for nested in object.values { result.formUnion(collectKeys(nested)) }
            return result
        case .array(let array):
            var result = Set<String>()
            for nested in array { result.formUnion(collectKeys(nested)) }
            return result
        case .string, .number, .bool, .null:
            return []
        }
    }

    private func encode(_ value: JSONValue?) -> String {
        guard let value,
              let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
