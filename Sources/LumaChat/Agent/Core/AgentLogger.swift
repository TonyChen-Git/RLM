import Darwin
import Foundation

enum AgentLogKind: String, Codable, Sendable {
    case session
    case model
    case tool
    case error
}

struct AgentLogRecord: Codable, Equatable, Sendable {
    var timestamp: Date
    var sessionID: UUID
    var kind: AgentLogKind
    var name: String
    var succeeded: Bool?
    var duration: TimeInterval?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var detail: String?
}

/// Bounded, redacted operational telemetry for Agent debugging. Raw prompts,
/// model payloads, tool arguments and tool results are deliberately excluded.
actor AgentLogger {
    static let shared = AgentLogger()

    private let directory: URL
    private let redactor: SecretRedactor
    private let encoder: JSONEncoder
    private let maximumFileBytes: Int
    private let maximumDetailCharacters: Int

    init(
        directory: URL = AppPaths.agentLogs,
        redactor: SecretRedactor = SecretRedactor(),
        maximumFileBytes: Int = 2 * 1_024 * 1_024,
        maximumDetailCharacters: Int = 2_000
    ) {
        self.directory = directory.standardizedFileURL
        self.redactor = redactor
        self.maximumFileBytes = max(16 * 1_024, maximumFileBytes)
        self.maximumDetailCharacters = max(128, maximumDetailCharacters)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func record(
        sessionID: UUID,
        kind: AgentLogKind,
        name: String,
        succeeded: Bool? = nil,
        duration: TimeInterval? = nil,
        usage: AgentTokenUsage? = nil,
        detail: String? = nil
    ) throws {
        let record = AgentLogRecord(
            timestamp: Date(),
            sessionID: sessionID,
            kind: kind,
            name: bounded(redactor.redact(name), maximum: 256),
            succeeded: succeeded,
            duration: duration.map { max(0, $0) },
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            totalTokens: usage?.totalTokens,
            detail: detail.map { bounded(redactor.redact($0), maximum: maximumDetailCharacters) }
        )
        try append(record)
    }

    func records(sessionID: UUID, limit: Int = 500) throws -> [AgentLogRecord] {
        let url = fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try secureRead(url, maximumBytes: maximumFileBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A)
            .suffix(max(1, min(limit, 5_000)))
            .compactMap { try? decoder.decode(AgentLogRecord.self, from: Data($0)) }
    }

    private func append(_ record: AgentLogRecord) throws {
        try ensureSecureDirectory()
        let url = fileURL(for: record.sessionID)
        var existing = FileManager.default.fileExists(atPath: url.path)
            ? try secureRead(url, maximumBytes: maximumFileBytes)
            : Data()
        var line = try encoder.encode(record)
        line.append(0x0A)

        if line.count >= maximumFileBytes {
            line = Data(line.suffix(maximumFileBytes))
            if let newline = line.firstIndex(of: 0x0A), newline < line.index(before: line.endIndex) {
                line.removeSubrange(line.startIndex ... newline)
            }
            existing.removeAll(keepingCapacity: false)
        } else if existing.count > maximumFileBytes - line.count {
            existing = Data(existing.suffix(maximumFileBytes - line.count))
            if let newline = existing.firstIndex(of: 0x0A) {
                existing.removeSubrange(existing.startIndex ... newline)
            } else {
                existing.removeAll(keepingCapacity: false)
            }
        }
        existing.append(line)
        try AtomicFileWriter.write(existing, to: url)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func ensureSecureDirectory() throws {
        let root = AppPaths.projectTemporaryRoot.standardizedFileURL.path
        guard directory.path == root || directory.path.hasPrefix(root + "/") else {
            throw AgentRuntimeError.invalidArguments("Agent logs must remain under project tmp")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentRuntimeError.invalidArguments("Agent log directory is not a real directory")
        }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func secureRead(_ url: URL, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw AgentRuntimeError.invalidArguments("Agent log file is unsafe or exceeds its size limit")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl")
    }

    private func bounded(_ value: String, maximum: Int) -> String {
        guard value.count > maximum else { return value }
        return String(value.prefix(maximum)) + "…"
    }
}
