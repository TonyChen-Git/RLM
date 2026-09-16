import Darwin
import Foundation

/// One process entrypoint keeps Desktop, CLI, and App Server on the same
/// persistence and AgentRuntime implementation. The external `lumachat`
/// executable only forwards arguments here; it does not contain a second
/// runtime or a provider fallback.
@main
enum LumaChatMain {
    @MainActor
    static func main() async {
        let processArguments = ProcessInfo.processInfo.arguments
        let arguments = Array(processArguments.dropFirst())

        if arguments.first == "--cli" {
            let status = await runCLI(
                executable: processArguments.first ?? "LumaChat",
                arguments: Array(arguments.dropFirst())
            )
            Darwin.exit(status)
        }

        if arguments.first == "--server" {
            let status = await runServer(arguments: Array(arguments.dropFirst()))
            Darwin.exit(status)
        }

        LumaChatApp.main()
    }

    @MainActor
    private static func runCLI(executable: String, arguments: [String]) async -> Int32 {
        // Help, version, and parser errors are frontend-only. They must remain
        // available even when a provider is offline or durable settings need
        // repair, and therefore do not even construct the live Agent host.
        let needsRuntime: Bool
        do {
            switch try LumaCLIParser().parse(arguments: arguments).command {
            case .help, .version:
                needsRuntime = false
            default:
                needsRuntime = true
            }
        } catch {
            needsRuntime = false
        }
        guard needsRuntime else {
            return await LumaCLIEntrypoint.run(
                processArguments: [executable] + arguments
            )
        }

        let runtime = SharedAgentHeadlessRuntime.live()
        let host = SharedLumaCLIHost(runtime: runtime)
        do {
            try await runtime.start()
        } catch {
            await runtime.shutdown()
            writeStandardError("Error: LumaChat runtime could not start (\(error.localizedDescription)).\n")
            return LumaCLIExitCode.configuration.rawValue
        }

        let result = await LumaCLIEntrypoint.run(
            processArguments: [executable] + arguments,
            host: host
        )
        await runtime.shutdown()
        return result
    }

    @MainActor
    private static func runServer(arguments: [String]) async -> Int32 {
        let parsed: HeadlessServerOptions.ParseResult
        do {
            parsed = try HeadlessServerOptions.parse(arguments)
        } catch {
            writeStandardError("Error: \(error.localizedDescription)\n\n")
            writeStandardError(HeadlessServerOptions.help)
            return EX_USAGE
        }
        if case .help = parsed {
            writeStandardOutput(HeadlessServerOptions.help)
            return 0
        }
        guard case .options(let options) = parsed else { return EX_SOFTWARE }

        let configuration: LumaChatHeadlessServerConfiguration
        do {
            configuration = try LumaChatHeadlessServerConfiguration(
                bindHost: options.bindHost,
                port: options.port,
                bearerToken: options.bearerToken,
                allowNonLoopback: false
            )
        } catch {
            writeStandardError("Error: invalid App Server configuration (\(error.localizedDescription)).\n")
            return EX_CONFIG
        }

        let runtime = SharedAgentHeadlessRuntime.live()
        do {
            try await runtime.start()
        } catch {
            await runtime.shutdown()
            writeStandardError("Error: LumaChat runtime could not start (\(error.localizedDescription)).\n")
            return EX_CONFIG
        }

        let server = LumaChatHeadlessHTTPServer(runtime: runtime, configuration: configuration)
        do {
            let effectivePort = try await server.start()
            let displayHost = configuration.bindHost == "::1"
                ? "[::1]"
                : configuration.bindHost
            writeStandardOutput(
                "LumaChat App Server v1 listening at http://\(displayHost):\(effectivePort)\n"
            )
            if options.generatedToken {
                writeStandardError(
                    "Generated bearer token (store it securely; shown once): \(configuration.bearerToken)\n"
                )
            }
            writeStandardError("Press Control-C to stop the App Server.\n")
            await LumaChatTerminationSignal.wait()
            server.stop()
            await runtime.shutdown()
            return 0
        } catch {
            server.stop()
            await runtime.shutdown()
            writeStandardError("Error: App Server failed (\(error.localizedDescription)).\n")
            return EX_UNAVAILABLE
        }
    }

    private static func writeStandardOutput(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func writeStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private struct HeadlessServerOptions {
    enum ParseResult {
        case help
        case options(HeadlessServerOptions)
    }

    static let help = """
    Usage: lumachat server [options]

      --host HOST    Loopback address: 127.0.0.1, ::1, or localhost
      --port PORT    TCP port (default: 32189; use 0 for an ephemeral port)
      --token TOKEN  Bearer token with at least 32 UTF-8 bytes
      -h, --help     Show this help

    If --token is omitted, LUMACHAT_SERVER_TOKEN is used. If neither is set,
    a cryptographically random token is generated and printed once to stderr.
    The built-in server intentionally refuses non-loopback binding.
    """ + "\n"

    let bindHost: String
    let port: UInt16
    let bearerToken: String
    let generatedToken: Bool

    static func parse(_ arguments: [String]) throws -> ParseResult {
        var bindHost = "127.0.0.1"
        var port: UInt16 = 32_189
        var explicitToken: String?
        var seenOptions = Set<String>()
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            if option == "--help" || option == "-h" {
                guard arguments.count == 1 else {
                    throw ParseError.helpMustBeUsedAlone
                }
                return .help
            }
            guard option == "--host" || option == "--port" || option == "--token" else {
                throw ParseError.unknownOption(option)
            }
            guard seenOptions.insert(option).inserted else {
                throw ParseError.duplicateOption(option)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw ParseError.missingValue(option)
            }
            let value = arguments[valueIndex]
            guard !value.isEmpty else { throw ParseError.missingValue(option) }

            switch option {
            case "--host":
                let normalized = value.lowercased()
                guard ["127.0.0.1", "::1", "localhost"].contains(normalized) else {
                    throw ParseError.nonLoopbackHost
                }
                bindHost = normalized
            case "--port":
                guard let parsed = UInt16(value) else { throw ParseError.invalidPort }
                port = parsed
            case "--token":
                explicitToken = value
            default:
                break
            }
            index += 2
        }

        let environmentToken = ProcessInfo.processInfo.environment["LUMACHAT_SERVER_TOKEN"]
        let generatedToken = explicitToken == nil && environmentToken == nil
        let token = explicitToken
            ?? environmentToken
            ?? LumaChatHeadlessServerConfiguration.generateBearerToken()
        return .options(HeadlessServerOptions(
            bindHost: bindHost,
            port: port,
            bearerToken: token,
            generatedToken: generatedToken
        ))
    }

    enum ParseError: LocalizedError {
        case unknownOption(String)
        case duplicateOption(String)
        case missingValue(String)
        case invalidPort
        case nonLoopbackHost
        case helpMustBeUsedAlone

        var errorDescription: String? {
            switch self {
            case .unknownOption(let option): "Unknown App Server option '\(option)'."
            case .duplicateOption(let option): "App Server option '\(option)' was supplied twice."
            case .missingValue(let option): "App Server option '\(option)' requires a value."
            case .invalidPort: "App Server port must be an integer from 0 through 65535."
            case .nonLoopbackHost: "The built-in App Server accepts loopback hosts only."
            case .helpMustBeUsedAlone: "--help must be used without other App Server options."
            }
        }
    }
}

/// Dispatch signal sources are retained until one signal completes the single
/// continuation. SIGKILL remains intentionally unhandled.
private final class LumaChatTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [any DispatchSourceSignal] = []

    private init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    static func wait() async {
        await withCheckedContinuation { continuation in
            let waiter = LumaChatTerminationSignal(continuation: continuation)
            waiter.start()
        }
    }

    private func start() {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        let installed = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [self] in finish() }
            source.resume()
            return source
        }
        lock.lock()
        sources = installed
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let installed = sources
        sources.removeAll()
        lock.unlock()
        guard let pending else { return }
        installed.forEach { $0.cancel() }
        pending.resume()
    }
}
