import Foundation

struct WorktreeCommand: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var outputLimit: Int
}

struct WorktreeCommandResult: Equatable, Sendable {
    var terminationStatus: Int32
    var stdout: String
    var stderr: String
    var outputTruncated: Bool
}

protocol WorktreeCommandRunning: Sendable {
    func run(_ command: WorktreeCommand) async throws -> WorktreeCommandResult
}

final class ProcessWorktreeCommandRunner: WorktreeCommandRunning, @unchecked Sendable {
    func run(_ command: WorktreeCommand) async throws -> WorktreeCommandResult {
        guard command.executableURL.path == "/usr/bin/git" else {
            throw ManagedWorktreeError.invalidConfiguration(
                "worktree runner 只允許固定 /usr/bin/git。"
            )
        }
        guard (1...ManagedWorktreeLimits.maximumCommandOutputBytes).contains(
            command.outputLimit
        ) else {
            throw ManagedWorktreeError.invalidConfiguration("command output limit 無效。")
        }

        return try await Task.detached(priority: .utility) {
            let stdout = BoundedWorktreeOutput(limit: command.outputLimit)
            let stderr = BoundedWorktreeOutput(limit: command.outputLimit)
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }

            let process = Process()
            process.executableURL = command.executableURL
            process.arguments = command.arguments
            process.environment = command.environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
                throw error
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()

            let stdoutSnapshot = stdout.snapshot()
            let stderrSnapshot = stderr.snapshot()
            return WorktreeCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
                stderr: String(decoding: stderrSnapshot.data, as: UTF8.self),
                outputTruncated: stdoutSnapshot.truncated || stderrSnapshot.truncated
            )
        }.value
    }
}

private final class BoundedWorktreeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var retained = Data()
    private var totalBytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        totalBytes += data.count
        let remaining = max(0, limit - retained.count)
        if remaining > 0 { retained.append(data.prefix(remaining)) }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (retained, totalBytes > retained.count)
    }
}
