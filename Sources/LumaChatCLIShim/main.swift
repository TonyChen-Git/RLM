import Darwin
import Foundation

/// A dependency-free launcher for the `lumachat` command. It never invokes a
/// shell, never searches PATH, and never substitutes another model/runtime. It
/// only execs an explicitly configured or locally installed LumaChat binary.
private enum LumaChatCLIShim {
    private static let applicationBinaryEnvironment = "LUMACHAT_APP_BINARY"

    static func run() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let applicationBinary: URL
        do {
            applicationBinary = try resolveApplicationBinary()
        } catch {
            writeStandardError("lumachat: \(error.localizedDescription)\n")
            Darwin.exit(EX_UNAVAILABLE)
        }

        let forwarded: [String]
        if arguments.first == "server" {
            forwarded = ["--server"] + Array(arguments.dropFirst())
        } else {
            forwarded = ["--cli"] + arguments
        }
        exec(applicationBinary: applicationBinary, arguments: forwarded)
    }

    private static func resolveApplicationBinary() throws -> URL {
        let fileManager = FileManager.default
        let shim = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment[applicationBinaryEnvironment] {
            guard configured.hasPrefix("/") else {
                throw LauncherError.invalidConfiguredPath
            }
            let configuredURL = URL(fileURLWithPath: configured)
            guard executableCandidate(configuredURL, excluding: shim, fileManager: fileManager) != nil else {
                throw LauncherError.invalidConfiguredPath
            }
            return configuredURL.standardizedFileURL.resolvingSymlinksInPath()
        }

        // SwiftPM/developer layout. The release app keeps its executable at the
        // standard bundle path, covered by the following install candidates.
        candidates.append(shim.deletingLastPathComponent().appendingPathComponent("LumaChatDesktop"))
        candidates.append(
            shim.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("MacOS/LumaChat")
        )
        candidates.append(URL(fileURLWithPath: "/Applications/LumaChat.app/Contents/MacOS/LumaChat"))
        candidates.append(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LumaChat.app/Contents/MacOS/LumaChat")
        )

        for candidate in candidates {
            if let resolved = executableCandidate(candidate, excluding: shim, fileManager: fileManager) {
                return resolved
            }
        }
        throw LauncherError.applicationNotFound
    }

    private static func executableCandidate(
        _ candidate: URL,
        excluding shim: URL,
        fileManager: FileManager
    ) -> URL? {
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved != shim else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolved.path) else { return nil }
        return resolved
    }

    private static func exec(applicationBinary: URL, arguments: [String]) -> Never {
        let completeArguments = [applicationBinary.path] + arguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = completeArguments.map { strdup($0) }
        guard cArguments.allSatisfy({ $0 != nil }) else {
            for case let argument? in cArguments { free(argument) }
            writeStandardError("lumachat: failed to allocate launcher arguments.\n")
            Darwin.exit(EX_OSERR)
        }
        cArguments.append(nil)
        defer {
            for case let argument? in cArguments { free(argument) }
        }

        let result = applicationBinary.path.withCString { executable in
            cArguments.withUnsafeMutableBufferPointer { buffer in
                Darwin.execv(executable, buffer.baseAddress!)
            }
        }
        let reason = String(cString: strerror(errno))
        writeStandardError("lumachat: failed to launch LumaChat (\(reason)).\n")
        Darwin.exit(result == -1 ? EX_OSERR : EX_SOFTWARE)
    }

    private static func writeStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private enum LauncherError: LocalizedError {
        case invalidConfiguredPath
        case applicationNotFound

        var errorDescription: String? {
            switch self {
            case .invalidConfiguredPath:
                "\(applicationBinaryEnvironment) must be an absolute executable path."
            case .applicationNotFound:
                "LumaChat is not installed. Set \(applicationBinaryEnvironment) to its executable path."
            }
        }
    }
}

LumaChatCLIShim.run()
