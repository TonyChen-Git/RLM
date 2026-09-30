import Foundation

@MainActor
protocol LumaCLIIO: AnyObject {
    func writeStandardOutput(_ text: String)
    func writeStandardError(_ text: String)
    func readLine(prompt: String) -> String?
}

@MainActor
final class LumaCLIStandardIO: LumaCLIIO {
    func writeStandardOutput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    func writeStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    func readLine(prompt: String) -> String? {
        writeStandardError(prompt)
        return Swift.readLine(strippingNewline: true)
    }
}

@MainActor
struct LumaCLIRunner {
    static let currentVersion = "1.4.5"

    private let host: (any LumaCLIHost)?
    private let io: any LumaCLIIO
    private let parser: LumaCLIParser
    private let workingDirectory: String
    private let version: String

    init(
        host: (any LumaCLIHost)? = nil,
        io: any LumaCLIIO = LumaCLIStandardIO(),
        parser: LumaCLIParser = LumaCLIParser(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        version: String = Self.currentVersion
    ) {
        self.host = host
        self.io = io
        self.parser = parser
        self.workingDirectory = workingDirectory
        self.version = version
    }

    @discardableResult
    func run(arguments: [String]) async -> Int32 {
        let invocation: LumaCLIInvocation
        do {
            invocation = try parser.parse(arguments: arguments)
        } catch {
            let format = Self.requestedOutputFormat(in: arguments)
            return report(error: error, format: format).rawValue
        }

        let output = LumaCLIOutputSession(format: invocation.outputFormat, io: io)
        do {
            if case .help(let topic) = invocation.command {
                output.finish(result: LumaCLIHostResult(summary: Self.help(topic: topic)))
                return LumaCLIExitCode.success.rawValue
            }
            if case .version = invocation.command {
                output.finish(result: LumaCLIHostResult(summary: "LumaChat \(version)"))
                return LumaCLIExitCode.success.rawValue
            }

            let result = try await dispatch(invocation, output: output)
            if invocation.interactionMode == .nonInteractive, output.sawApprovalRequest {
                throw LumaCLIError.approvalRequired(
                    "Non-interactive execution stopped because an approval was required."
                )
            }
            try Self.validateSelectedRoute(invocation.backend, result: result)
            output.finish(result: result)
            return LumaCLIExitCode.success.rawValue
        } catch is CancellationError {
            return output.fail(error: LumaCLIError.cancelled).rawValue
        } catch {
            return output.fail(error: Self.normalized(error)).rawValue
        }
    }

    private func dispatch(
        _ invocation: LumaCLIInvocation,
        output: LumaCLIOutputSession
    ) async throws -> LumaCLIHostResult {
        guard let host else {
            throw LumaCLIError.configuration(
                "The shared LumaChat runtime is unavailable for this command."
            )
        }
        let eventHandler: LumaCLIEventHandler = { event in
            output.consume(event)
        }

        switch invocation.command {
        case .chat(let suppliedPrompt, let timeoutSeconds):
            let prompt = try resolvedPrompt(
                suppliedPrompt,
                invocation: invocation,
                promptLabel: "chat> "
            )
            let route = try await resolvedBackend(
                for: invocation.backend,
                host: host
            )
            let result = try await host.chat(
                request: LumaCLIChatRequest(
                    prompt: prompt,
                    backendID: route.backendID,
                    modelID: route.modelID,
                    timeoutSeconds: timeoutSeconds
                ),
                eventHandler: eventHandler
            )
            try Self.validateSelectedRoute(
                LumaCLIBackendSelection(
                    backendID: route.backendID,
                    modelID: route.modelID
                ),
                result: result
            )
            return result

        case .agent(let suppliedPrompt, let options):
            let prompt = try resolvedPrompt(
                suppliedPrompt,
                invocation: invocation,
                promptLabel: "agent> "
            )
            return try await executeTask(
                prompt: prompt,
                options: options,
                invocation: invocation,
                output: output,
                eventHandler: eventHandler,
                host: host
            )

        case .exec(let prompt, let options):
            guard invocation.interactionMode == .nonInteractive,
                  invocation.approvalPolicy == .deny else {
                throw LumaCLIError.configuration(
                    "exec must use non-interactive mode with fail-closed approvals."
                )
            }
            return try await executeTask(
                prompt: prompt,
                options: options,
                invocation: invocation,
                output: output,
                eventHandler: eventHandler,
                host: host
            )

        case .resume(let options):
            let snapshot = try await host.task(id: options.taskID)
            try Self.validateTaskIdentity(options.taskID, result: snapshot)
            let expectedRoute = try Self.requiredRoute(from: snapshot)
            try Self.validateSelectedRoute(invocation.backend, result: snapshot)
            let result = try await host.resume(
                taskID: options.taskID,
                request: LumaCLIResumeRequest(
                    prompt: options.prompt,
                    interactionMode: invocation.interactionMode,
                    approvalPolicy: invocation.approvalPolicy,
                    timeoutSeconds: options.timeoutSeconds
                ),
                eventHandler: eventHandler
            )
            try Self.validateTaskIdentity(options.taskID, result: result)
            try Self.validateSelectedRoute(expectedRoute, result: result)
            return result

        case .tasks(let action):
            return try await host.tasks(action: action)
        case .projects(let action):
            return try await host.projects(action: action)
        case .skills(let action):
            return try await host.skills(action: action)
        case .mcp(let action):
            return try await host.mcp(action: action)
        case .plugins(let action):
            return try await host.plugins(action: action)
        case .help, .version:
            throw LumaCLIError.executionFailed("Internal command dispatch error.")
        }
    }

    private func executeTask(
        prompt: String,
        options: LumaCLITaskOptions,
        invocation: LumaCLIInvocation,
        output: LumaCLIOutputSession,
        eventHandler: @escaping LumaCLIEventHandler,
        host: any LumaCLIHost
    ) async throws -> LumaCLIHostResult {
        let taskID: UUID
        var expectedRoute = invocation.backend
        if let existingTaskID = options.taskID {
            guard options.title == nil, options.workspacePath == nil else {
                throw LumaCLIError.usage(
                    "--title and --workspace create a new task and cannot be combined with --task-id."
                )
            }
            taskID = existingTaskID
            let snapshot = try await host.task(id: existingTaskID)
            try Self.validateTaskIdentity(existingTaskID, result: snapshot)
            try Self.validateSelectedRoute(invocation.backend, result: snapshot)
            expectedRoute = try Self.requiredRoute(from: snapshot)
        } else {
            let workspacePath: String
            if let requestedWorkspacePath = options.workspacePath {
                workspacePath = requestedWorkspacePath
            } else {
                workspacePath = try validatedWorkingDirectory()
            }
            let route = try await resolvedBackend(
                for: invocation.backend,
                host: host
            )
            let created = try await host.createTask(request: LumaCLICreateTaskRequest(
                mode: options.mode,
                title: options.title,
                workspacePath: workspacePath,
                backendID: route.backendID,
                modelID: route.modelID
            ))
            expectedRoute = LumaCLIBackendSelection(
                backendID: route.backendID,
                modelID: route.modelID
            )
            try Self.validateSelectedRoute(expectedRoute, result: created)
            guard let createdTaskID = created.taskID else {
                throw LumaCLIError.executionFailed(
                    "The headless runtime created a task without returning its task ID."
                )
            }
            taskID = createdTaskID
            output.consume(LumaCLIEvent(
                kind: .status,
                message: "Created task \(createdTaskID.uuidString.lowercased()).",
                taskID: createdTaskID
            ))
        }

        let result = try await host.sendMessage(
            taskID: taskID,
            request: LumaCLITaskMessageRequest(
                prompt: prompt,
                interactionMode: invocation.interactionMode,
                approvalPolicy: invocation.approvalPolicy,
                timeoutSeconds: options.timeoutSeconds
            ),
            eventHandler: eventHandler
        )
        try Self.validateTaskIdentity(taskID, result: result)
        try Self.validateSelectedRoute(expectedRoute, result: result)
        return result
    }

    private func resolvedPrompt(
        _ supplied: String?,
        invocation: LumaCLIInvocation,
        promptLabel: String
    ) throws -> String {
        if let supplied { return supplied }
        guard invocation.interactionMode == .interactive else {
            throw LumaCLIError.usage("A prompt is required in non-interactive mode.")
        }
        guard let value = io.readLine(prompt: promptLabel)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw LumaCLIError.cancelled
        }
        guard value.utf8.count <= 262_144,
              !value.unicodeScalars.contains(where: { scalar in
                  guard CharacterSet.controlCharacters.contains(scalar) else { return false }
                  return scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D
              }) else {
            throw LumaCLIError.usage(
                "Prompt is oversized or contains unsupported control data."
            )
        }
        return value
    }

    private func validatedWorkingDirectory() throws -> String {
        let candidate = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard candidate.path != "/",
              candidate.path.utf8.count <= 4_096,
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LumaCLIError.configuration(
                "The current directory is not a safe task workspace; pass --workspace explicitly."
            )
        }
        return candidate.path
    }

    private func resolvedBackend(
        for selection: LumaCLIBackendSelection,
        host: any LumaCLIHost
    ) async throws -> (backendID: String, modelID: String) {
        let resolved = try await host.resolveBackend(selection: selection)
        guard let backendID = resolved.backendID, let modelID = resolved.modelID,
              Self.validRouteID(backendID), Self.validRouteID(modelID) else {
            throw LumaCLIError.configuration(
                "No complete backendID/modelID route is configured."
            )
        }
        if let requestedBackend = selection.backendID, requestedBackend != backendID {
            throw LumaCLIError.backendUnavailable(
                "Selected backend '\(requestedBackend)' is unavailable; fallback is disabled."
            )
        }
        if let requestedModel = selection.modelID, requestedModel != modelID {
            throw LumaCLIError.backendUnavailable(
                "Selected model '\(requestedModel)' is unavailable; fallback is disabled."
            )
        }
        return (backendID, modelID)
    }

    private static func validRouteID(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private func report(error: Error, format: LumaCLIOutputFormat) -> LumaCLIExitCode {
        let normalized = Self.normalized(error)
        let output = LumaCLIOutputSession(format: format, io: io)
        return output.fail(error: normalized)
    }

    private static func normalized(_ error: Error) -> LumaCLIError {
        if let error = error as? LumaCLIError { return error }
        return .executionFailed(SecretRedactor().redact(error.localizedDescription))
    }

    private static func validateTaskIdentity(
        _ requestedTaskID: UUID,
        result: LumaCLIHostResult
    ) throws {
        guard let resultTaskID = result.taskID else {
            throw LumaCLIError.executionFailed(
                "The headless runtime omitted the task ID from its result."
            )
        }
        guard resultTaskID == requestedTaskID else {
            throw LumaCLIError.executionFailed(
                "The headless runtime returned a result for a different task."
            )
        }
    }

    private static func validateSelectedRoute(
        _ selection: LumaCLIBackendSelection,
        result: LumaCLIHostResult
    ) throws {
        if let requestedBackend = selection.backendID {
            guard result.backendID == requestedBackend else {
                throw LumaCLIError.backendUnavailable(
                    "Selected backend '\(requestedBackend)' was not used; fallback is disabled."
                )
            }
        }
        if let requestedModel = selection.modelID {
            guard result.modelID == requestedModel else {
                throw LumaCLIError.backendUnavailable(
                    "Selected model '\(requestedModel)' was not used; fallback is disabled."
                )
            }
        }
    }

    private static func requiredRoute(
        from result: LumaCLIHostResult
    ) throws -> LumaCLIBackendSelection {
        guard let backendID = result.backendID, let modelID = result.modelID,
              validRouteID(backendID), validRouteID(modelID) else {
            throw LumaCLIError.configuration(
                "The task does not contain a complete backendID/modelID route."
            )
        }
        return LumaCLIBackendSelection(backendID: backendID, modelID: modelID)
    }

    private static func requestedOutputFormat(in arguments: [String]) -> LumaCLIOutputFormat {
        if arguments.contains("--jsonl") { return .jsonLines }
        if arguments.contains("--json") { return .json }
        return .text
    }

    private static func help(topic: String?) -> String {
        switch topic?.lowercased() {
        case "chat":
            "Usage: lumachat chat [--backend-id ID] [--model-id ID] [--timeout SECONDS] [PROMPT]"
        case "agent":
            "Usage: lumachat agent [--task-id UUID | --workspace PATH] [--mode plan|agent] [--title TITLE] [PROMPT]"
        case "exec":
            "Usage: lumachat exec [--task-id UUID | --workspace-path PATH] [--backend-id ID] [--model-id ID] [--timeout SECONDS] PROMPT"
        case "resume":
            "Usage: lumachat resume --task-id UUID [--timeout SECONDS] [PROMPT]"
        case "tasks", "projects", "skills", "mcp", "plugins":
            "Usage: lumachat \(topic!.lowercased()) [list [--all] | show ID] [--json|--jsonl]"
        case .some(let unknown):
            "Unknown help topic '\(unknown)'.\n\n\(help(topic: nil))"
        case .none:
            """
            Usage: lumachat [GLOBAL OPTIONS] COMMAND [OPTIONS]

            Commands:
              chat       Send a classic chat prompt
              agent      Create or explicitly target an Agent task
              exec       Run an Agent task non-interactively
              resume     Resume one explicit task ID
              tasks      List or inspect tasks
              projects   List or inspect projects
              skills     List or inspect discovered skills
              mcp        List or inspect MCP servers
              plugins    List or inspect installed plugins

            Global options:
              --backend-id ID      Require this backend; fallback is disabled
              --model-id ID        Require this model; fallback is disabled
              --non-interactive    Never prompt and deny approval requests
              --json | --jsonl     Machine-readable output
              --help | --version
            """
        }
    }
}

/// Thin process boundary for a future `lumachat` executable target. Keeping
/// process termination outside the reusable runner makes parser/exit behavior
/// testable and lets the package entrypoint call `exit(status)` exactly once.
@MainActor
enum LumaCLIEntrypoint {
    static func run(
        processArguments: [String] = ProcessInfo.processInfo.arguments,
        host: (any LumaCLIHost)? = nil,
        io: any LumaCLIIO = LumaCLIStandardIO(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        version: String = LumaCLIRunner.currentVersion
    ) async -> Int32 {
        let arguments = processArguments.isEmpty
            ? []
            : Array(processArguments.dropFirst())
        return await LumaCLIRunner(
            host: host,
            io: io,
            workingDirectory: workingDirectory,
            version: version
        ).run(arguments: arguments)
    }
}

@MainActor
private final class LumaCLIOutputSession {
    private static let maximumStoredEvents = 4_096
    private static let maximumStoredEventBytes = 16 * 1_024 * 1_024
    private static let maximumSingleEventBytes = 512 * 1_024
    private static let maximumResultBytes = 16 * 1_024 * 1_024
    private static let maximumSummaryBytes = 8_192

    let format: LumaCLIOutputFormat
    private let io: any LumaCLIIO
    private(set) var events: [LumaCLIEvent] = []
    private(set) var sawApprovalRequest = false
    private var storedEventBytes = 0
    private var droppedEventCount = 0

    init(format: LumaCLIOutputFormat, io: any LumaCLIIO) {
        self.format = format
        self.io = io
    }

    func consume(_ event: LumaCLIEvent) {
        let event = Self.bounded(event)
        if event.kind == .approvalRequired { sawApprovalRequest = true }
        switch format {
        case .text:
            switch event.kind {
            case .content, .reasoning:
                io.writeStandardOutput(event.message)
            case .warning, .approvalRequired:
                io.writeStandardError(Self.line(event.message))
            case .status, .tool:
                io.writeStandardError(Self.line(event.message))
            }
        case .json:
            let bytes = (try? JSONEncoder().encode(event).count)
                ?? Self.maximumSingleEventBytes + 1
            if events.count < Self.maximumStoredEvents,
               bytes <= Self.maximumSingleEventBytes,
               storedEventBytes + bytes <= Self.maximumStoredEventBytes {
                events.append(event)
                storedEventBytes += bytes
            } else {
                droppedEventCount += 1
            }
        case .jsonLines:
            writeJSON(
                LumaCLIWireRecord(type: "event", success: nil, event: event),
                toStandardError: false,
                pretty: false
            )
        }
    }

    func finish(result: LumaCLIHostResult) {
        let boundedResult = Self.bounded(result)
        switch format {
        case .text:
            if !boundedResult.value.summary.isEmpty {
                io.writeStandardOutput(Self.line(boundedResult.value.summary))
            }
        case .json:
            writeJSON(
                LumaCLIWireRecord(
                    type: "result",
                    success: true,
                    events: events,
                    eventsTruncated: droppedEventCount > 0,
                    droppedEventCount: droppedEventCount > 0 ? droppedEventCount : nil,
                    resultTruncated: boundedResult.truncated ? true : nil,
                    result: boundedResult.value
                ),
                toStandardError: false,
                pretty: true
            )
        case .jsonLines:
            writeJSON(
                LumaCLIWireRecord(
                    type: "result",
                    success: true,
                    resultTruncated: boundedResult.truncated ? true : nil,
                    result: boundedResult.value
                ),
                toStandardError: false,
                pretty: false
            )
        }
    }

    func fail(error: LumaCLIError) -> LumaCLIExitCode {
        let message = Self.boundedUTF8(
            error.localizedDescription,
            maximumBytes: Self.maximumSummaryBytes
        )
        switch format {
        case .text:
            io.writeStandardError(Self.line("Error: \(message)"))
        case .json, .jsonLines:
            writeJSON(
                LumaCLIWireRecord(
                    type: "error",
                    success: false,
                    error: LumaCLIWireError(
                        code: error.exitCode.rawValue,
                        message: message
                    )
                ),
                toStandardError: true,
                pretty: format == .json
            )
        }
        return error.exitCode
    }

    private func writeJSON<T: Encodable>(
        _ value: T,
        toStandardError: Bool,
        pretty: Bool
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            io.writeStandardError("{\"type\":\"error\",\"success\":false}\n")
            return
        }
        let text = String(decoding: data, as: UTF8.self) + "\n"
        if toStandardError {
            io.writeStandardError(text)
        } else {
            io.writeStandardOutput(text)
        }
    }

    private static func line(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    private static func bounded(_ event: LumaCLIEvent) -> LumaCLIEvent {
        guard ((try? JSONEncoder().encode(event).count) ?? Int.max)
                <= maximumSingleEventBytes else {
            return LumaCLIEvent(
                kind: event.kind,
                message: boundedUTF8(event.message, maximumBytes: 8_192),
                taskID: event.taskID,
                sequence: event.sequence,
                payload: nil
            )
        }
        return event
    }

    private static func bounded(
        _ result: LumaCLIHostResult
    ) -> (value: LumaCLIHostResult, truncated: Bool) {
        var candidate = result
        candidate.summary = boundedUTF8(
            candidate.summary,
            maximumBytes: maximumSummaryBytes
        )
        let summaryWasTruncated = candidate.summary.utf8.count < result.summary.utf8.count
        if let size = try? JSONEncoder().encode(candidate).count,
           size <= maximumResultBytes {
            return (candidate, summaryWasTruncated)
        }
        candidate.payload = nil
        return (candidate, true)
    }

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        var length = max(0, min(maximumBytes, data.count))
        while length > 0 {
            if let result = String(data: data.prefix(length), encoding: .utf8) {
                return result
            }
            length -= 1
        }
        return ""
    }
}

private struct LumaCLIWireError: Encodable {
    var code: Int32
    var message: String
}

private struct LumaCLIWireRecord: Encodable {
    var type: String
    var success: Bool?
    var event: LumaCLIEvent?
    var events: [LumaCLIEvent]?
    var eventsTruncated: Bool?
    var droppedEventCount: Int?
    var resultTruncated: Bool?
    var result: LumaCLIHostResult?
    var error: LumaCLIWireError?

    init(
        type: String,
        success: Bool?,
        event: LumaCLIEvent? = nil,
        events: [LumaCLIEvent]? = nil,
        eventsTruncated: Bool? = nil,
        droppedEventCount: Int? = nil,
        resultTruncated: Bool? = nil,
        result: LumaCLIHostResult? = nil,
        error: LumaCLIWireError? = nil
    ) {
        self.type = type
        self.success = success
        self.event = event
        self.events = events
        self.eventsTruncated = eventsTruncated
        self.droppedEventCount = droppedEventCount
        self.resultTruncated = resultTruncated
        self.result = result
        self.error = error
    }
}
