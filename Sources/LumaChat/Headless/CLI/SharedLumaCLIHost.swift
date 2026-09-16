import Foundation
import LumaChatSDK

/// Production CLI adapter. All task commands delegate to the same
/// `SharedAgentHeadlessRuntime` used by the versioned App Server; no command
/// selects a desktop tab or creates a second Agent loop.
@MainActor
final class SharedLumaCLIHost: LumaCLIHost {
    nonisolated private static let maximumSummaryBytes = 8_192

    private let runtime: SharedAgentHeadlessRuntime
    private let redactor = SecretRedactor()

    init(runtime: SharedAgentHeadlessRuntime) {
        self.runtime = runtime
    }

    func resolveBackend(
        selection: LumaCLIBackendSelection
    ) async throws -> LumaCLIBackendSelection {
        do {
            return try await runtime.resolveCLIBackendSelection(selection)
        } catch {
            throw cliError(error)
        }
    }

    func chat(
        request: LumaCLIChatRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        do {
            return try await runtime.runCLIChat(
                request: request,
                eventHandler: eventHandler
            )
        } catch {
            throw cliError(error)
        }
    }

    func createTask(request: LumaCLICreateTaskRequest) async throws -> LumaCLIHostResult {
        let mode: LumaChatTaskMode
        switch request.mode {
        case .plan: mode = .plan
        case .agent: mode = .agent
        case .chat:
            throw LumaCLIError.usage("Task creation supports plan or agent mode.")
        }
        do {
            let snapshot = try await runtime.createTask(LumaChatTaskCreateRequest(
                title: request.title,
                mode: mode,
                workspacePath: request.workspacePath,
                backendID: request.backendID,
                modelID: request.modelID
            ))
            return Self.hostResult(snapshot, summary: "Created task \(snapshot.id.uuidString.lowercased()).")
        } catch {
            throw cliError(error)
        }
    }

    func task(id: UUID) async throws -> LumaCLIHostResult {
        do {
            let snapshot = try await runtime.task(id: id)
            return Self.hostResult(
                snapshot,
                summary: "\(snapshot.id.uuidString.lowercased())  \(snapshot.status.rawValue)  \(snapshot.title)"
            )
        } catch {
            throw cliError(error)
        }
    }

    func sendMessage(
        taskID: UUID,
        request: LumaCLITaskMessageRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        do {
            let cursor = try await runtime.cliEventCursor(taskID: taskID)
            _ = try await runtime.sendMessage(
                taskID: taskID,
                request: LumaChatMessageRequest(content: request.prompt)
            )
            return try await waitForTask(
                taskID: taskID,
                afterSequence: cursor,
                approvalPolicy: request.approvalPolicy,
                timeoutSeconds: request.timeoutSeconds,
                eventHandler: eventHandler
            )
        } catch {
            throw cliError(error)
        }
    }

    func resume(
        taskID: UUID,
        request: LumaCLIResumeRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        do {
            let cursor = try await runtime.cliEventCursor(taskID: taskID)
            _ = try await runtime.resume(
                taskID: taskID,
                request: LumaChatResumeRequest(content: request.prompt)
            )
            return try await waitForTask(
                taskID: taskID,
                afterSequence: cursor,
                approvalPolicy: request.approvalPolicy,
                timeoutSeconds: request.timeoutSeconds,
                eventHandler: eventHandler
            )
        } catch {
            throw cliError(error)
        }
    }

    func tasks(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        do {
            switch action {
            case .list(let includeArchived):
                let archivedIDs = Set(runtime.agentViewModel
                    .headlessSessions(includeArchived: true)
                    .filter { $0.archivedAt != nil }
                    .map(\.id))
                let snapshots = try await runtime.listTasks()
                    .filter { includeArchived || !archivedIDs.contains($0.id) }
                let payloads = snapshots.map(Self.taskPayload)
                let summary = snapshots.isEmpty
                    ? "No tasks."
                    : snapshots.map {
                        "\($0.id.uuidString.lowercased())  \($0.status.rawValue)  \($0.title)"
                    }.joined(separator: "\n")
                return LumaCLIHostResult(
                    summary: summary,
                    payload: .object([
                        "kind": .string("tasks"),
                        "items": .array(payloads)
                    ])
                )
            case .show(let rawID):
                guard let id = UUID(uuidString: rawID) else {
                    throw LumaCLIError.usage("Task ID must be a UUID.")
                }
                return try await task(id: id)
            }
        } catch {
            throw cliError(error)
        }
    }

    func projects(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        let all = runtime.agentViewModel.projects
        switch action {
        case .list(let includeArchived):
            let values = all.filter { includeArchived || !$0.isArchived }
            return Self.collectionResult(
                kind: "projects",
                values: values.map(Self.projectPayload),
                lines: values.map {
                    "\($0.id.uuidString.lowercased())  \($0.isArchived ? "archived" : "active")  \($0.name)"
                }
            )
        case .show(let rawID):
            guard let id = UUID(uuidString: rawID),
                  let value = all.first(where: { $0.id == id }) else {
                throw LumaCLIError.notFound("Project not found.")
            }
            return Self.itemResult(kind: "project", value: Self.projectPayload(value), name: value.name)
        }
    }

    func skills(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        let values = runtime.agentViewModel.availableSkills.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        switch action {
        case .list:
            return Self.collectionResult(
                kind: "skills",
                values: values.map(Self.skillPayload),
                lines: values.map { "\($0.id)  \($0.name)" }
            )
        case .show(let id):
            guard let value = values.first(where: { $0.id == id || $0.name == id }) else {
                throw LumaCLIError.notFound("Skill not found.")
            }
            return Self.itemResult(kind: "skill", value: Self.skillPayload(value), name: value.name)
        }
    }

    func mcp(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        let configurations = runtime.agentViewModel.mcpServers.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let snapshots = Dictionary(uniqueKeysWithValues:
            runtime.agentViewModel.mcpSnapshots.map { ($0.id, $0) }
        )
        switch action {
        case .list:
            return Self.collectionResult(
                kind: "mcp",
                values: configurations.map { Self.mcpPayload($0, snapshot: snapshots[$0.id]) },
                lines: configurations.map {
                    let state = snapshots[$0.id]?.state.rawValue ?? "disconnected"
                    return "\($0.id.uuidString.lowercased())  \(state)  \($0.name)"
                }
            )
        case .show(let rawID):
            guard let id = UUID(uuidString: rawID),
                  let value = configurations.first(where: { $0.id == id }) else {
                throw LumaCLIError.notFound("MCP server not found.")
            }
            return Self.itemResult(
                kind: "mcp",
                value: Self.mcpPayload(value, snapshot: snapshots[value.id]),
                name: value.name
            )
        }
    }

    func plugins(action: LumaCLIResourceAction) async throws -> LumaCLIHostResult {
        let values = runtime.agentViewModel.installedPlugins.sorted {
            $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
        switch action {
        case .list:
            return Self.collectionResult(
                kind: "plugins",
                values: values.map(Self.pluginPayload),
                lines: values.map {
                    "\($0.id)  \($0.enabled ? "enabled" : "disabled")  \($0.manifest.name) \($0.manifest.version)"
                }
            )
        case .show(let id):
            guard let value = values.first(where: { $0.id == id }) else {
                throw LumaCLIError.notFound("Plugin not found.")
            }
            return Self.itemResult(
                kind: "plugin",
                value: Self.pluginPayload(value),
                name: value.manifest.name
            )
        }
    }

    private func waitForTask(
        taskID: UUID,
        afterSequence: UInt64,
        approvalPolicy: LumaCLIApprovalPolicy,
        timeoutSeconds: Double?,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        let stream = try await runtime.events(
            taskID: taskID,
            afterSequence: afterSequence
        )
        let runtime = runtime
        do {
            return try await withThrowingTaskGroup(of: LumaCLIHostResult.self) { group in
                group.addTask {
                    var emittedContent = false
                    for try await event in stream {
                        if let projected = Self.cliEvent(event) {
                            if projected.kind == .content { emittedContent = true }
                            await eventHandler(projected)
                        }
                        if event.kind == .approvalRequired {
                            if approvalPolicy == .deny {
                                // The approval event and durable snapshot can race.
                                // Always request stop even if the pending approval
                                // is no longer visible by the time we inspect it.
                                if let snapshot = try? await runtime.task(id: taskID),
                                   let approval = snapshot.pendingApproval {
                                    _ = try? await runtime.approve(
                                        taskID: taskID,
                                        request: LumaChatApprovalDecisionRequest(
                                            approvalID: approval.id,
                                            decision: .deny
                                        )
                                    )
                                }
                                _ = try? await runtime.stop(
                                    taskID: taskID,
                                    request: LumaChatControlRequest()
                                )
                            }
                            throw LumaCLIError.approvalRequired(
                                approvalPolicy == .deny
                                    ? "Execution stopped because a tool approval was required."
                                    : "Task is awaiting approval; approve it in LumaChat or through the App Server."
                            )
                        }
                    }
                    let snapshot = try await runtime.task(id: taskID)
                    if !emittedContent, let final = snapshot.result?.content, !final.isEmpty {
                        await eventHandler(LumaCLIEvent(
                            kind: .content,
                            message: final,
                            taskID: taskID
                        ))
                    }
                    return try Self.terminalResult(snapshot)
                }
                if let timeoutSeconds {
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        _ = try? await runtime.stop(
                            taskID: taskID,
                            request: LumaChatControlRequest()
                        )
                        throw LumaCLIError.timedOut(
                            "Task timed out after \(timeoutSeconds) seconds and was stopped."
                        )
                    }
                }
                guard let result = try await group.next() else {
                    throw LumaCLIError.executionFailed("Task event stream ended without a result.")
                }
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            _ = try? await runtime.stop(taskID: taskID, request: LumaChatControlRequest())
            throw LumaCLIError.cancelled
        }
    }

    private func cliError(_ error: Error) -> LumaCLIError {
        if let value = error as? LumaCLIError { return value }
        if error is CancellationError { return .cancelled }
        if let value = error as? LumaChatHeadlessRuntimeFailure {
            switch value.code {
            case .backendUnavailable:
                return .backendUnavailable(value.message)
            case .notFound:
                return .notFound(value.message)
            case .approvalNotFound:
                return .approvalRequired(value.message)
            case .unauthorized, .forbidden:
                return .permissionDenied(value.message)
            case .invalidRequest, .unsupportedMediaType, .payloadTooLarge,
                 .methodNotAllowed:
                return .usage(value.message)
            case .conflict, .invalidState, .eventCursorExpired, .internalError:
                return .executionFailed(value.message)
            }
        }
        return .executionFailed(redactor.redact(error.localizedDescription))
    }

    nonisolated private static func terminalResult(
        _ snapshot: LumaChatTaskSnapshot
    ) throws -> LumaCLIHostResult {
        switch snapshot.status {
        case .completed:
            return hostResult(
                snapshot,
                summary: snapshot.result?.content.isEmpty == false
                    ? ""
                    : "Task completed without text output."
            )
        case .cancelled:
            throw LumaCLIError.cancelled
        case .failed, .stepLimit:
            throw LumaCLIError.executionFailed(
                bounded(snapshot.lastError ?? "Task ended with status \(snapshot.status.rawValue).")
            )
        case .paused:
            throw LumaCLIError.executionFailed("Task paused before completion.")
        case .awaitingApproval:
            throw LumaCLIError.approvalRequired("Task is awaiting approval.")
        case .idle, .running:
            throw LumaCLIError.executionFailed(
                "Task event stream ended while status was \(snapshot.status.rawValue)."
            )
        }
    }

    nonisolated private static func cliEvent(_ event: LumaChatTaskEvent) -> LumaCLIEvent? {
        let object: [String: LumaChatJSONValue]
        if case .object(let value) = event.payload { object = value } else { object = [:] }
        switch event.kind {
        case .messageDelta:
            return LumaCLIEvent(
                kind: .content,
                message: object["delta"]?.stringValue ?? "",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .reasoningDelta:
            return LumaCLIEvent(
                kind: .reasoning,
                message: object["delta"]?.stringValue ?? "",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .step, .diffChanged:
            return LumaCLIEvent(
                kind: .tool,
                message: object["phase"]?.stringValue ?? "Task progress updated.",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .approvalRequired:
            return LumaCLIEvent(
                kind: .approvalRequired,
                message: "Task requires tool approval.",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .warning:
            return LumaCLIEvent(
                kind: .warning,
                message: object["message"]?.stringValue ?? "Task warning.",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .error:
            return LumaCLIEvent(
                kind: .warning,
                message: object["message"]?.stringValue ?? "Task error.",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .snapshot, .stateChanged:
            return LumaCLIEvent(
                kind: .status,
                message: object["status"]?.stringValue
                    ?? object["phase"]?.stringValue
                    ?? "Task state updated.",
                taskID: event.taskID,
                sequence: event.sequence,
                payload: convert(event.payload)
            )
        case .heartbeat:
            return nil
        }
    }

    nonisolated private static func hostResult(
        _ snapshot: LumaChatTaskSnapshot,
        summary: String
    ) -> LumaCLIHostResult {
        LumaCLIHostResult(
            summary: bounded(summary),
            taskID: snapshot.id,
            backendID: snapshot.backendID,
            modelID: snapshot.modelID,
            payload: taskPayload(snapshot)
        )
    }

    nonisolated private static func taskPayload(_ value: LumaChatTaskSnapshot) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(value.id.uuidString.lowercased()),
            "title": .string(value.title),
            "mode": .string(value.mode.rawValue),
            "status": .string(value.status.rawValue),
            "backendID": .string(value.backendID),
            "modelID": .string(value.modelID),
            "workspacePath": .string(value.workspacePath),
            "executionKind": .string(value.executionKind.rawValue),
            "createdAt": .string(ISO8601DateFormatter().string(from: value.createdAt)),
            "updatedAt": .string(ISO8601DateFormatter().string(from: value.updatedAt))
        ]
        if let result = value.result {
            var projected: [String: JSONValue] = ["content": .string(result.content)]
            if let reasoning = result.reasoningSummary {
                projected["reasoningSummary"] = .string(reasoning)
            }
            object["result"] = .object(projected)
        }
        if let approval = value.pendingApproval {
            object["pendingApproval"] = .object([
                "id": .string(approval.id.uuidString.lowercased()),
                "toolName": .string(approval.toolName),
                "displayName": .string(approval.displayName),
                "permissionLevel": .string(approval.permissionLevel),
                "riskReasons": .array(approval.riskReasons.map(JSONValue.string))
            ])
        }
        if let error = value.lastError { object["lastError"] = .string(bounded(error)) }
        return .object(object)
    }

    nonisolated private static func projectPayload(_ value: AgentProject) -> JSONValue {
        .object([
            "id": .string(value.id.uuidString.lowercased()),
            "name": .string(value.name),
            "archived": .bool(value.isArchived),
            "pinned": .bool(value.isPinned),
            "folders": .array(value.folders.map { folder in
                .object([
                    "id": .string(folder.id.uuidString.lowercased()),
                    "name": .string(folder.name),
                    "path": .string(folder.workspace.rootPath),
                    "gitRepository": .bool(folder.workspace.gitRepository)
                ])
            })
        ])
    }

    nonisolated private static func skillPayload(_ value: SkillDescriptor) -> JSONValue {
        .object([
            "id": .string(value.id),
            "name": .string(value.name),
            "description": .string(value.description),
            "invocation": .string(value.invocation),
            "source": .string(value.source.rawValue),
            "pluginID": value.pluginID.map(JSONValue.string) ?? .null,
            "permissions": .array(value.permissions.map { .string($0.rawValue) }),
            "hasReferences": .bool(value.hasReferences),
            "hasScripts": .bool(value.hasScripts),
            "hasTemplates": .bool(value.hasTemplates),
            "hasAssets": .bool(value.hasAssets)
        ])
    }

    nonisolated private static func mcpPayload(
        _ value: MCPServerConfiguration,
        snapshot: MCPServerSnapshot?
    ) -> JSONValue {
        .object([
            "id": .string(value.id.uuidString.lowercased()),
            "name": .string(value.name),
            "enabled": .bool(value.enabled),
            "scope": .string(value.scope.rawValue),
            "transport": .string(value.transport.kind.rawValue),
            "state": .string(snapshot?.state.rawValue ?? "disconnected"),
            "toolCount": .number(Double(snapshot?.tools.count ?? 0)),
            "resourceCount": .number(Double(snapshot?.resources.count ?? 0)),
            "promptCount": .number(Double(snapshot?.prompts.count ?? 0)),
            "ownerPluginID": value.ownerPluginID.map(JSONValue.string) ?? .null
        ])
    }

    nonisolated private static func pluginPayload(_ value: InstalledPlugin) -> JSONValue {
        .object([
            "id": .string(value.id),
            "name": .string(value.manifest.name),
            "version": .string(value.manifest.version),
            "author": .string(value.manifest.author),
            "description": .string(value.manifest.description),
            "enabled": .bool(value.enabled),
            "permissions": .array(value.manifest.permissions.map { .string($0.rawValue) }),
            "grantedPermissions": .array(value.grantedPermissions.map { .string($0.rawValue) }),
            "lastError": value.lastError.map { .string(bounded($0)) } ?? .null
        ])
    }

    nonisolated private static func collectionResult(
        kind: String,
        values: [JSONValue],
        lines: [String]
    ) -> LumaCLIHostResult {
        LumaCLIHostResult(
            summary: lines.isEmpty
                ? "No \(kind)."
                : boundedLines(lines),
            payload: .object(["kind": .string(kind), "items": .array(values)])
        )
    }

    nonisolated private static func itemResult(
        kind: String,
        value: JSONValue,
        name: String
    ) -> LumaCLIHostResult {
        LumaCLIHostResult(
            summary: bounded(name),
            payload: .object(["kind": .string(kind), "item": value])
        )
    }

    nonisolated private static func convert(_ value: LumaChatJSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.mapValues(convert))
        case .array(let array):
            return .array(array.map(convert))
        case .string(let string):
            return .string(string)
        case .number(let number):
            return .number(number)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        }
    }

    nonisolated private static func bounded(_ value: String) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumSummaryBytes else { return value }
        var length = maximumSummaryBytes
        while length > 0 {
            if let result = String(data: data.prefix(length), encoding: .utf8) {
                return result
            }
            length -= 1
        }
        return ""
    }

    nonisolated private static func boundedLines(_ lines: [String]) -> String {
        var result = ""
        var remaining = maximumSummaryBytes
        for line in lines {
            guard remaining > 0 else { break }
            if !result.isEmpty {
                guard remaining > 1 else { break }
                result.append("\n")
                remaining -= 1
            }
            let retained = boundedToBytes(line, maximumBytes: remaining)
            result += retained
            remaining -= retained.utf8.count
            if retained.utf8.count < line.utf8.count { break }
        }
        return result
    }

    nonisolated private static func boundedToBytes(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        var length = max(0, maximumBytes)
        while length > 0 {
            if let result = String(data: data.prefix(length), encoding: .utf8) {
                return result
            }
            length -= 1
        }
        return ""
    }
}

private extension LumaChatJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
