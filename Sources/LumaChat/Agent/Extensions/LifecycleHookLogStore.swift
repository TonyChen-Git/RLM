import Foundation

actor LifecycleHookLogStore {
    static let maximumRecords = 1_000
    static let maximumFileBytes = 4 * 1_024 * 1_024

    private let fileURL: URL
    private var records: [LifecycleHookResult] = []

    init(
        fileURL: URL = AppPaths.hookLogs.appendingPathComponent("history.json")
    ) {
        self.fileURL = fileURL
    }

    func load() throws -> [LifecycleHookResult] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return []
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumFileBytes else {
            throw ExtensionSubsystemError.sizeLimit("Hook history 超過 4 MiB")
        }
        records = Array(
            try JSONDecoder().decode([LifecycleHookResult].self, from: data)
                .suffix(Self.maximumRecords)
        ).map(Self.sanitized)
        return records
    }

    func append(_ result: LifecycleHookResult) throws -> [LifecycleHookResult] {
        let previous = records
        records.append(Self.sanitized(result))
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(records)
            while data.count > Self.maximumFileBytes, records.count > 1 {
                records.removeFirst(max(1, records.count / 4))
                data = try encoder.encode(records)
            }
            guard data.count <= Self.maximumFileBytes else {
                throw ExtensionSubsystemError.sizeLimit("Hook history 無法縮減至 4 MiB")
            }
            try AtomicFileWriter.write(data, to: fileURL)
            return records
        } catch {
            records = previous
            throw error
        }
    }

    private static func sanitized(_ original: LifecycleHookResult) -> LifecycleHookResult {
        var result = original
        let redacted = SecretRedactor().redact(original.output)
        let inert = redacted.unicodeScalars.map { scalar in
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                return String(scalar)
            }
            return CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined()
        result.output = String(
            decoding: Data(inert.utf8).prefix(16_384),
            as: UTF8.self
        )
        return result
    }
}
