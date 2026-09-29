import Darwin
import Foundation
import LumaChatSDK

/// A completed entry replays the exact acceptance response. A pending entry is
/// deliberately never retried: the host may have applied its side effect just
/// before a crash or failed journal write.
enum LumaChatHeadlessMutationResponse: Codable, Equatable {
    case task(LumaChatTaskSnapshot)
    case operation(LumaChatAcceptedOperation)
}

struct LumaChatHeadlessMutationJournal {
    private struct Entry: Codable {
        let id: UUID
        let signature: Data
        var response: LumaChatHeadlessMutationResponse?
    }

    private struct Document: Codable {
        let version: Int
        var entries: [Entry]
    }

    static let maximumEntries = 1_024
    private static let maximumFileBytes = 16 * 1_024 * 1_024

    private let fileURL: URL
    private let writeData: (Data, URL) throws -> Void
    private var entries: [Entry] = []
    private var isLoaded = false
    private var isPoisoned = false

    init(
        fileURL: URL,
        writeData: @escaping (Data, URL) throws -> Void = AtomicFileWriter.write
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.writeData = writeData
    }

    mutating func load() throws {
        guard !isLoaded else { return }
        if let stored = try readEntries() {
            entries = stored
        } else {
            // Ensure a durable predecessor exists before any mutation. If a
            // later directory fsync fails after rename, recovery can see the
            // old pending entry or the new completed entry, never no journal.
            try persist([])
        }
        isLoaded = true
    }

    private func readEntries() throws -> [Entry]? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
            return nil
        }
        defer { _ = Darwin.close(descriptor) }
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              info.st_size <= Self.maximumFileBytes else {
            throw LumaChatHeadlessMutationJournalError.invalidJournal
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw LumaChatHeadlessMutationJournalError.invalidJournal
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LumaChatHeadlessMutationJournalError.invalidJournal }
                offset += count
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        guard document.version == 1,
              document.entries.count <= Self.maximumEntries else {
            throw LumaChatHeadlessMutationJournalError.invalidJournal
        }
        var seen = Set<UUID>()
        for entry in document.entries {
            guard seen.insert(entry.id).inserted,
                  entry.signature.count == 32,
                  Self.validResponse(entry.response, for: entry.id) else {
                throw LumaChatHeadlessMutationJournalError.invalidJournal
            }
        }
        return document.entries
    }

    func replay(id: UUID, signature: Data) throws -> LumaChatHeadlessMutationResponse? {
        guard isLoaded, !isPoisoned, signature.count == 32 else {
            throw LumaChatHeadlessMutationJournalError.invalidJournal
        }
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        guard entry.signature == signature else {
            throw LumaChatHeadlessRuntimeFailure.conflict(
                "The request ID was reused with a different payload."
            )
        }
        guard let response = entry.response else {
            throw LumaChatHeadlessRuntimeFailure.conflict(
                "The request outcome is uncertain after interruption; inspect the task before submitting a new request."
            )
        }
        return response
    }

    /// Persist the uncertain state before the caller may execute a mutation.
    /// Existing completed entries can be replayed after an asynchronous probe.
    mutating func reserve(id: UUID, signature: Data) throws -> LumaChatHeadlessMutationResponse? {
        if let response = try replay(id: id, signature: signature) { return response }
        var candidate = entries
        if candidate.count >= Self.maximumEntries {
            guard let oldestCompleted = candidate.firstIndex(where: { $0.response != nil }) else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The App Server request journal is full of uncertain operations."
                )
            }
            candidate.remove(at: oldestCompleted)
        }
        candidate.append(Entry(id: id, signature: signature, response: nil))
        try persistAndPublish(candidate)
        return nil
    }

    mutating func complete(
        id: UUID,
        signature: Data,
        response: LumaChatHeadlessMutationResponse
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].signature == signature,
              entries[index].response == nil,
              Self.validResponse(response, for: id) else {
            throw LumaChatHeadlessMutationJournalError.invalidJournal
        }
        var candidate = entries
        candidate[index].response = response
        try persistAndPublish(candidate)
    }

    private mutating func persistAndPublish(_ candidate: [Entry]) throws {
        do {
            try persist(candidate)
            entries = candidate
        } catch {
            // AtomicFileWriter can fail after rename but before its directory
            // fsync. Re-read the actual file so an in-process retry cannot
            // overwrite a committed reservation or completion from stale RAM.
            if let recovered = try? readEntries() {
                entries = recovered
            } else {
                isPoisoned = true
            }
            throw error
        }
    }

    private func persist(_ candidate: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(version: 1, entries: candidate))
        guard data.count <= Self.maximumFileBytes else {
            throw LumaChatHeadlessMutationJournalError.invalidJournal
        }
        try writeData(data, fileURL)
    }

    private static func validResponse(_ response: LumaChatHeadlessMutationResponse?, for id: UUID) -> Bool {
        switch response {
        case .none, .task:
            true
        case .operation(let operation):
            operation.requestID == id
        }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum LumaChatHeadlessMutationJournalError: Error {
    case invalidJournal
}
