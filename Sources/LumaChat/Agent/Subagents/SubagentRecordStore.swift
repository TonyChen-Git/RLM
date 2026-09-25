import Darwin
import Foundation

protocol SubagentRecordPersisting: Sendable {
    func loadRecords() async throws -> [SubagentRecord]
    func saveRecords(_ records: [SubagentRecord]) async throws
}

enum SubagentRecordStoreError: LocalizedError, Equatable, Sendable {
    case invalidFile
    case oversized(Int)
    case tooManyRecords(Int)
    case invalidRecord(String)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            "Subagent 記錄檔不是安全的 regular file。"
        case .oversized(let maximum):
            "Subagent 記錄檔超過 \(maximum) bytes。"
        case .tooManyRecords(let maximum):
            "Subagent 記錄超過 \(maximum) 筆。"
        case .invalidRecord(let detail):
            "Subagent 記錄無效：\(detail)"
        }
    }
}

/// One bounded, atomically replaced record set. This deliberately reuses the
/// app's Application Support + AtomicFileWriter persistence boundary rather
/// than introducing a database solely for orchestration state.
actor SubagentRecordStore: SubagentRecordPersisting {
    private struct Envelope: Codable {
        var version: Int
        var records: [SubagentRecord]
    }

    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumRecords = 512

    private let fileManager: FileManager
    private let fileURL: URL

    init(
        fileManager: FileManager = .default,
        fileURL: URL = AppPaths.agentSubagentRecordsFile
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL.standardizedFileURL
    }

    func loadRecords() throws -> [SubagentRecord] {
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        if descriptor < 0, errno == ENOENT { return [] }
        if descriptor < 0, errno == ELOOP {
            throw SubagentRecordStoreError.invalidFile
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0 else {
            throw SubagentRecordStoreError.invalidFile
        }
        guard info.st_size <= off_t(Self.maximumFileBytes) else {
            throw SubagentRecordStoreError.oversized(Self.maximumFileBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            guard data.count <= Self.maximumFileBytes - count else {
                throw SubagentRecordStoreError.oversized(Self.maximumFileBytes)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else {
            throw SubagentRecordStoreError.invalidRecord("不支援的 schema version。")
        }
        try Self.validate(envelope.records)
        return envelope.records
    }

    func saveRecords(_ records: [SubagentRecord]) throws {
        try Self.validate(records)
        let parent = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            version: 1,
            records: records.sorted {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return $0.createdAt < $1.createdAt
            }
        ))
        guard data.count <= Self.maximumFileBytes else {
            throw SubagentRecordStoreError.oversized(Self.maximumFileBytes)
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private static func validate(_ records: [SubagentRecord]) throws {
        guard records.count <= maximumRecords else {
            throw SubagentRecordStoreError.tooManyRecords(maximumRecords)
        }
        var ids = Set<UUID>()
        for record in records {
            guard ids.insert(record.id).inserted,
                  record.id == record.childSessionID,
                  record.parentSessionID != record.childSessionID,
                  (1...SubagentValidation.maximumDepth).contains(record.depth),
                  record.consumedTokens >= 0,
                  record.attempt >= 1,
                  record.goal.utf8.count <= SubagentValidation.maximumGoalBytes,
                  (record.context?.utf8.count ?? 0) <= SubagentValidation.maximumContextBytes,
                  record.pendingMessages.count <= 64,
                  record.pendingMessages.allSatisfy({
                      $0.utf8.count <= SubagentValidation.maximumMessageBytes
                  }),
                  record.startedAt.map({ $0 >= record.createdAt }) ?? true,
                  record.endedAt.map({ $0 >= record.createdAt }) ?? true,
                  record.updatedAt >= record.createdAt else {
                throw SubagentRecordStoreError.invalidRecord(record.id.uuidString)
            }
            if let result = record.result {
                _ = try SubagentValidation.validatedResult(result)
            }
        }
    }
}
