import Foundation

struct LumaCLIParser: Sendable {
    static let commandNames = [
        "chat", "agent", "exec", "resume", "tasks", "projects",
        "skills", "mcp", "plugins", "help", "version"
    ]

    func parse(arguments rawArguments: [String]) throws -> LumaCLIInvocation {
        guard rawArguments.count <= 4_096,
              rawArguments.allSatisfy({ $0.utf8.count <= 262_144 }) else {
            throw LumaCLIError.usage("Command arguments exceed the safety limit.")
        }
        var cursor = ArgumentCursor(rawArguments)
        var global = GlobalOptions()
        var commandName: String?
        var commandArguments: [String] = []

        while let argument = cursor.next() {
            if commandName == nil, argument == "--" {
                commandName = "help"
                commandArguments.append(contentsOf: cursor.remaining())
                break
            }
            if commandName == nil, argument.hasPrefix("-") {
                try parseGlobal(argument, cursor: &cursor, options: &global)
                continue
            }
            if commandName == nil {
                commandName = argument.lowercased()
            } else {
                commandArguments.append(argument)
            }
        }

        guard let commandName else {
            return LumaCLIInvocation(
                command: global.versionRequested ? .version : .help(topic: nil),
                outputFormat: global.outputFormat,
                interactionMode: global.interactionMode,
                backend: global.backendSelection
            )
        }

        var local = try parseCommandOptions(commandArguments, inheriting: global)
        let command = try makeCommand(named: commandName, options: &local)
        return LumaCLIInvocation(
            command: command,
            outputFormat: local.global.outputFormat,
            interactionMode: local.resolvedInteractionMode(commandName: commandName),
            backend: local.global.backendSelection
        )
    }

    private func parseGlobal(
        _ argument: String,
        cursor: inout ArgumentCursor,
        options: inout GlobalOptions
    ) throws {
        switch argument {
        case "-h", "--help":
            options.helpRequested = true
        case "--version":
            options.versionRequested = true
        case "--json":
            try options.setOutputFormat(.json, flag: argument)
        case "--jsonl":
            try options.setOutputFormat(.jsonLines, flag: argument)
        case "--non-interactive":
            options.interactionMode = .nonInteractive
        case "--backend", "--backend-id":
            guard options.backendID == nil else {
                throw LumaCLIError.usage("--backend may only be supplied once.")
            }
            options.backendID = try boundedText(
                requiredValue(after: argument, cursor: &cursor),
                flag: argument,
                maximumBytes: 512
            )
        case "--model", "--model-id":
            guard options.modelID == nil else {
                throw LumaCLIError.usage("--model may only be supplied once.")
            }
            options.modelID = try boundedText(
                requiredValue(after: argument, cursor: &cursor),
                flag: argument,
                maximumBytes: 512
            )
        default:
            throw LumaCLIError.usage("Unknown global option: \(argument)")
        }
    }

    private func parseCommandOptions(
        _ arguments: [String],
        inheriting inherited: GlobalOptions
    ) throws -> CommandOptions {
        var cursor = ArgumentCursor(arguments)
        var result = CommandOptions(global: inherited)
        var parsingOptions = true
        while let argument = cursor.next() {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            guard parsingOptions, argument.hasPrefix("-") else {
                result.positionals.append(argument)
                continue
            }
            switch argument {
            case "-h", "--help":
                result.global.helpRequested = true
            case "--json":
                try result.global.setOutputFormat(.json, flag: argument)
            case "--jsonl":
                try result.global.setOutputFormat(.jsonLines, flag: argument)
            case "--non-interactive":
                result.global.interactionMode = .nonInteractive
            case "--backend", "--backend-id":
                guard result.global.backendID == nil else {
                    throw LumaCLIError.usage("--backend may only be supplied once.")
                }
                result.global.backendID = try boundedText(
                    requiredValue(after: argument, cursor: &cursor),
                    flag: argument,
                    maximumBytes: 512
                )
            case "--model", "--model-id":
                guard result.global.modelID == nil else {
                    throw LumaCLIError.usage("--model may only be supplied once.")
                }
                result.global.modelID = try boundedText(
                    requiredValue(after: argument, cursor: &cursor),
                    flag: argument,
                    maximumBytes: 512
                )
            case "--task-id", "--task":
                guard result.taskID == nil else {
                    throw LumaCLIError.usage("--task-id may only be supplied once.")
                }
                let value = try requiredValue(after: argument, cursor: &cursor)
                guard let id = UUID(uuidString: value) else {
                    throw LumaCLIError.usage("\(argument) requires a UUID task ID.")
                }
                result.taskID = id
            case "--mode":
                guard result.mode == nil else {
                    throw LumaCLIError.usage("--mode may only be supplied once.")
                }
                let value = try requiredValue(after: argument, cursor: &cursor).lowercased()
                guard let mode = AppMode(rawValue: value), mode.usesAgentRuntime else {
                    throw LumaCLIError.usage("--mode must be plan or agent.")
                }
                result.mode = mode
            case "--title":
                guard result.title == nil else {
                    throw LumaCLIError.usage("--title may only be supplied once.")
                }
                result.title = try boundedText(
                    requiredValue(after: argument, cursor: &cursor),
                    flag: argument,
                    maximumBytes: 512
                )
            case "--workspace", "--workspace-path":
                guard result.workspacePath == nil else {
                    throw LumaCLIError.usage("--workspace may only be supplied once.")
                }
                result.workspacePath = try workspacePath(
                    requiredValue(after: argument, cursor: &cursor)
                )
            case "--timeout":
                guard result.timeoutSeconds == nil else {
                    throw LumaCLIError.usage("--timeout may only be supplied once.")
                }
                let value = try requiredValue(after: argument, cursor: &cursor)
                guard let seconds = Double(value), seconds.isFinite, seconds > 0, seconds <= 86_400 else {
                    throw LumaCLIError.usage("--timeout must be greater than 0 and at most 86400 seconds.")
                }
                result.timeoutSeconds = seconds
            case "--all", "--archived":
                result.includeArchived = true
            default:
                throw LumaCLIError.usage("Unknown option: \(argument)")
            }
        }
        return result
    }

    private func makeCommand(
        named name: String,
        options: inout CommandOptions
    ) throws -> LumaCLICommand {
        if options.global.versionRequested { return .version }
        if options.global.helpRequested, name != "help" { return .help(topic: name) }

        switch name {
        case "help":
            guard options.positionals.count <= 1 else {
                throw LumaCLIError.usage("help accepts at most one command name.")
            }
            return .help(topic: options.positionals.first)
        case "version":
            try options.requireNoTaskOptions(command: name, permitBackend: false)
            guard options.positionals.isEmpty else {
                throw LumaCLIError.usage("version does not accept arguments.")
            }
            return .version
        case "chat":
            try options.requireNoTaskOptions(command: name, permitBackend: true)
            let prompt = try prompt(from: options.positionals)
            if options.global.interactionMode == .nonInteractive, prompt == nil {
                throw LumaCLIError.usage("chat --non-interactive requires a prompt.")
            }
            return .chat(prompt: prompt, timeoutSeconds: options.timeoutSeconds)
        case "agent", "exec":
            let prompt = try prompt(from: options.positionals)
            if options.taskID != nil,
               (options.mode != nil || options.title != nil || options.workspacePath != nil) {
                throw LumaCLIError.usage(
                    "--task-id cannot be combined with --mode, --title, or --workspace."
                )
            }
            let mode = options.mode ?? .agent
            let taskOptions = LumaCLITaskOptions(
                taskID: options.taskID,
                mode: mode,
                title: options.title,
                workspacePath: options.workspacePath,
                backendID: options.global.backendID,
                modelID: options.global.modelID,
                timeoutSeconds: options.timeoutSeconds
            )
            if name == "exec" {
                guard let prompt else {
                    throw LumaCLIError.usage("exec requires a prompt.")
                }
                return .exec(prompt: prompt, options: taskOptions)
            }
            if options.global.interactionMode == .nonInteractive, prompt == nil {
                throw LumaCLIError.usage("agent --non-interactive requires a prompt.")
            }
            return .agent(prompt: prompt, options: taskOptions)
        case "resume":
            guard let taskID = options.taskID else {
                throw LumaCLIError.usage("resume requires --task-id <UUID>.")
            }
            guard options.title == nil, options.workspacePath == nil, options.mode == nil,
                  options.global.backendID == nil, options.global.modelID == nil,
                  !options.includeArchived else {
                throw LumaCLIError.usage("resume accepts only --task-id, --timeout and output options.")
            }
            return .resume(LumaCLIResumeOptions(
                taskID: taskID,
                prompt: try prompt(from: options.positionals),
                timeoutSeconds: options.timeoutSeconds
            ))
        case "tasks", "projects", "skills", "mcp", "plugins":
            try options.requireNoTaskOptions(
                command: name,
                permitBackend: false,
                permitArchive: true
            )
            guard options.timeoutSeconds == nil else {
                throw LumaCLIError.usage("\(name) does not accept --timeout.")
            }
            return try resourceCommand(named: name, options: options)
        default:
            throw LumaCLIError.usage(
                "Unknown command: \(name). Expected one of: \(Self.commandNames.joined(separator: ", "))."
            )
        }
    }

    private func resourceCommand(
        named name: String,
        options: CommandOptions
    ) throws -> LumaCLICommand {
        var positionals = options.positionals
        let verb: String
        if let first = positionals.first, first == "list" || first == "show" {
            verb = first
            positionals.removeFirst()
        } else {
            verb = positionals.isEmpty ? "list" : "show"
        }

        let action: LumaCLIResourceAction
        switch verb {
        case "list":
            guard positionals.isEmpty else {
                throw LumaCLIError.usage("\(name) list does not accept positional arguments.")
            }
            action = .list(includeArchived: options.includeArchived)
        case "show":
            guard !options.includeArchived else {
                throw LumaCLIError.usage("\(name) show does not accept --all.")
            }
            guard positionals.count == 1 else {
                throw LumaCLIError.usage("\(name) show requires exactly one ID.")
            }
            let identifier = try boundedText(
                positionals[0],
                flag: "\(name) show",
                maximumBytes: 512
            )
            if name == "tasks" || name == "projects" {
                guard let uuid = UUID(uuidString: identifier) else {
                    throw LumaCLIError.usage("\(name) show requires a UUID ID.")
                }
                action = .show(id: uuid.uuidString.lowercased())
            } else {
                action = .show(id: identifier)
            }
        default:
            throw LumaCLIError.usage("Unsupported \(name) action: \(verb).")
        }

        switch name {
        case "tasks": return .tasks(action)
        case "projects": return .projects(action)
        case "skills": return .skills(action)
        case "mcp": return .mcp(action)
        case "plugins": return .plugins(action)
        default: throw LumaCLIError.usage("Unsupported resource command: \(name).")
        }
    }

    private func prompt(from positionals: [String]) throws -> String? {
        let text = positionals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.utf8.count <= 262_144,
              !text.unicodeScalars.contains(where: { scalar in
                  guard CharacterSet.controlCharacters.contains(scalar) else { return false }
                  return scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D
              }) else {
            throw LumaCLIError.usage(
                "Prompt is oversized or contains unsupported control data."
            )
        }
        return text
    }

    private func requiredValue(
        after flag: String,
        cursor: inout ArgumentCursor
    ) throws -> String {
        guard let value = cursor.next(), !value.isEmpty else {
            throw LumaCLIError.usage("\(flag) requires a value.")
        }
        return value
    }

    private func workspacePath(_ raw: String) throws -> String {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LumaCLIError.usage("--workspace contains control characters.")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        guard url.path != "/", url.path.utf8.count <= 4_096 else {
            throw LumaCLIError.usage("--workspace must be a bounded path other than filesystem root.")
        }
        return url.path
    }

    private func boundedText(
        _ raw: String,
        flag: String,
        maximumBytes: Int
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LumaCLIError.usage("\(flag) contains an empty, oversized, or control-character value.")
        }
        return value
    }
}

private struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func remaining() -> [String] {
        guard index < arguments.count else { return [] }
        defer { index = arguments.count }
        return Array(arguments[index...])
    }
}

private struct GlobalOptions {
    var outputFormat: LumaCLIOutputFormat = .text
    var interactionMode: LumaCLIInteractionMode = .interactive
    var backendID: String?
    var modelID: String?
    var helpRequested = false
    var versionRequested = false
    private var didSetOutputFormat = false

    var backendSelection: LumaCLIBackendSelection {
        LumaCLIBackendSelection(backendID: backendID, modelID: modelID)
    }

    mutating func setOutputFormat(_ format: LumaCLIOutputFormat, flag: String) throws {
        if didSetOutputFormat, outputFormat != format {
            throw LumaCLIError.usage("\(flag) conflicts with the selected output format.")
        }
        outputFormat = format
        didSetOutputFormat = true
    }
}

private struct CommandOptions {
    var global: GlobalOptions
    var taskID: UUID?
    var mode: AppMode?
    var title: String?
    var workspacePath: String?
    var timeoutSeconds: Double?
    var includeArchived = false
    var positionals: [String] = []

    func resolvedInteractionMode(commandName: String) -> LumaCLIInteractionMode {
        commandName == "exec" ? .nonInteractive : global.interactionMode
    }

    func requireNoTaskOptions(
        command: String,
        permitBackend: Bool,
        permitArchive: Bool = false
    ) throws {
        guard taskID == nil, mode == nil, title == nil, workspacePath == nil,
              permitArchive || !includeArchived else {
            throw LumaCLIError.usage("\(command) does not accept task creation options.")
        }
        if !permitBackend, global.backendSelection.isExplicit {
            throw LumaCLIError.usage("\(command) does not accept backend selection options.")
        }
    }
}
