import Foundation

/// Shared hard quota across every stdout/stderr artifact in one terminal
/// session. A model cannot bypass the per-stream limit by starting many noisy
/// processes.
final class OutputCaptureBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingBytes: Int

    init(byteLimit: Int) {
        remainingBytes = max(128 * 1_024, byteLimit)
    }

    func reserve(upTo requestedBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let reserved = max(0, min(requestedBytes, remainingBytes))
        remainingBytes -= reserved
        return reserved
    }
}

/// Thread-safe output capture used by Foundation.Process readability callbacks.
/// The complete stream is written directly to repository-local storage while a
/// small head/tail window is retained for model context.
final class OutputSpool: @unchecked Sendable {
    private static let maximumPendingLineBytes = 256 * 1_024

    private let lock = NSLock()
    private let artifactURL: URL
    private let handle: FileHandle
    private let retainedByteLimit: Int
    private let artifactByteLimit: Int
    private let configuredSecrets: [String]
    private let captureBudget: OutputCaptureBudget?
    private var retained = Data()
    private var tail = Data()
    private var pending = Data()
    private var byteCount = 0
    private var writeErrorDescription: String?
    private var isInsidePrivateKey = false
    private var isDiscardingOversizedLine = false
    private var didReachArtifactLimit = false

    init(
        prefix: String,
        retainedByteLimit: Int,
        artifactByteLimit: Int = 32 * 1_024 * 1_024,
        configuredSecrets: [String] = [],
        captureBudget: OutputCaptureBudget? = nil
    ) throws {
        self.retainedByteLimit = max(1_024, retainedByteLimit)
        self.artifactByteLimit = max(64 * 1_024, artifactByteLimit)
        var expandedSecrets: [String] = []
        for secret in configuredSecrets {
            expandedSecrets.append(secret)
            expandedSecrets.append(contentsOf: secret.split(whereSeparator: \Character.isNewline).map(String.init))
        }
        let minSecretBytes = 4
        let maxSecretBytes = 64 * 1_024
        let filteredSecrets = expandedSecrets.filter { $0.utf8.count >= minSecretBytes && $0.utf8.count <= maxSecretBytes }
        self.configuredSecrets = Array(Set(filteredSecrets))
        .sorted { $0.utf8.count > $1.utf8.count }
        self.captureBudget = captureBudget
        artifactURL = try AgentTemporaryStorage.makeArtifactURL(prefix: prefix)
        guard FileManager.default.createFile(atPath: artifactURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: artifactURL)
    }

    deinit {
        try? handle.close()
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        consume(data)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !isDiscardingOversizedLine, !pending.isEmpty {
            appendRedactedLine(pending)
        }
        pending.removeAll(keepingCapacity: false)
        isDiscardingOversizedLine = false
        try? handle.synchronize()
    }

    func summary() -> OutputSummary {
        lock.lock()
        defer { lock.unlock() }

        let isTruncated = byteCount > retainedByteLimit || didReachArtifactLimit
        let data: Data
        if isTruncated {
            let headLimit = retainedByteLimit / 2
            var combined = Data(retained.prefix(headLimit))
            combined.append(Data("\n… output truncated; tail follows …\n".utf8))
            combined.append(tail)
            data = combined
        } else {
            data = retained
        }
        return OutputSummary(
            text: String(decoding: data, as: UTF8.self),
            byteCount: byteCount,
            truncated: isTruncated,
            artifactPath: isTruncated ? artifactURL.path : nil,
            writeErrorDescription: writeErrorDescription
        )
    }

    func read(offset: Int64, maxBytes: Int) throws -> ProcessOutputChunk {
        lock.lock()
        defer { lock.unlock() }
        try handle.synchronize()

        let clampedOffset = max(0, min(offset, Int64(byteCount)))
        let reader = try FileHandle(forReadingFrom: artifactURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(clampedOffset))
        let data = try reader.read(upToCount: max(1, min(maxBytes, 1_048_576))) ?? Data()
        let nextOffset = clampedOffset + Int64(data.count)
        return ProcessOutputChunk(
            text: String(decoding: data, as: UTF8.self),
            offset: clampedOffset,
            nextOffset: nextOffset,
            hasMore: nextOffset < Int64(byteCount),
            totalBytes: byteCount,
            artifactPath: artifactURL.path
        )
    }

    /// Buffers one logical line so secret prefixes and values split across
    /// readability callbacks are redacted before a single byte reaches disk.
    private func consume(_ incoming: Data) {
        guard !didReachArtifactLimit else { return }
        var data = incoming

        if isDiscardingOversizedLine {
            guard let newline = data.firstIndex(of: 0x0A) else { return }
            data.removeSubrange(data.startIndex...newline)
            isDiscardingOversizedLine = false
        }
        pending.append(data)

        while let newline = pending.firstIndex(of: 0x0A) {
            let end = pending.index(after: newline)
            let line = Data(pending[..<end])
            pending.removeSubrange(..<end)
            if line.count > Self.maximumPendingLineBytes {
                appendSanitized(Data("[… oversized terminal line omitted …]\n".utf8))
            } else {
                appendRedactedLine(line)
            }
            if didReachArtifactLimit {
                pending.removeAll(keepingCapacity: false)
                return
            }
        }

        if pending.count > Self.maximumPendingLineBytes {
            pending.removeAll(keepingCapacity: false)
            isDiscardingOversizedLine = true
            appendSanitized(Data("[… oversized terminal line omitted …]\n".utf8))
        }
    }

    private func appendRedactedLine(_ data: Data) {
        var text = String(decoding: data, as: UTF8.self)
        let uppercase = text.uppercased()
        if isInsidePrivateKey {
            if uppercase.contains("-----END ") && uppercase.contains("PRIVATE KEY-----") {
                isInsidePrivateKey = false
            }
            return
        }
        if uppercase.contains("-----BEGIN ") && uppercase.contains("PRIVATE KEY-----") {
            isInsidePrivateKey = !(
                uppercase.contains("-----END ") && uppercase.contains("PRIVATE KEY-----")
            )
            appendSanitized(Data("[REDACTED PRIVATE KEY]\n".utf8))
            return
        }

        for secret in configuredSecrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        text = SecretRedactor().redact(text)
        appendSanitized(Data(text.utf8))
    }

    /// The only artifact write site. Input has already passed through the
    /// streaming redactor and is clipped to a hard per-stream disk quota.
    private func appendSanitized(_ data: Data) {
        guard !data.isEmpty, !didReachArtifactLimit else { return }
        let remaining = max(0, artifactByteLimit - byteCount)
        guard remaining > 0 else {
            didReachArtifactLimit = true
            return
        }
        let reserved = captureBudget?.reserve(upTo: min(data.count, remaining))
            ?? min(data.count, remaining)
        guard reserved > 0 else {
            didReachArtifactLimit = true
            return
        }
        let stored = Data(data.prefix(reserved))
        do {
            try handle.write(contentsOf: stored)
        } catch {
            writeErrorDescription = error.localizedDescription
        }
        byteCount += stored.count

        let tailLimit = retainedByteLimit - retainedByteLimit / 2
        if retained.count < retainedByteLimit {
            retained.append(stored.prefix(retainedByteLimit - retained.count))
        }
        tail.append(stored)
        if tail.count > tailLimit {
            tail.removeFirst(tail.count - tailLimit)
        }
        if stored.count < data.count || byteCount >= artifactByteLimit {
            didReachArtifactLimit = true
        }
    }
}

struct OutputSummary: Sendable {
    var text: String
    var byteCount: Int
    var truncated: Bool
    var artifactPath: String?
    var writeErrorDescription: String?
}

struct ProcessOutputChunk: Codable, Sendable, Equatable {
    var text: String
    var offset: Int64
    var nextOffset: Int64
    var hasMore: Bool
    var totalBytes: Int
    var artifactPath: String
}
