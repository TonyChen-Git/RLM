import Darwin
import Foundation
import LumaUpdateCore

@main
enum LumaChatUpdaterMain {
    static func main() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard arguments.count == 2,
              arguments[0] == "--request",
              arguments[1].hasPrefix("/") else {
            writeError("Usage: lumachat-updater --request /absolute/path/install-request.json\n")
            Darwin.exit(EX_USAGE)
        }
        do {
            try LumaUpdateInstaller.perform(
                requestURL: URL(fileURLWithPath: arguments[1], isDirectory: false)
            )
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            writeError("LumaChat update failed: \(error.localizedDescription)\n")
            Darwin.exit(EX_SOFTWARE)
        }
    }

    private static func writeError(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
