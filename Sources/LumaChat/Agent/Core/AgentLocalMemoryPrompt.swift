import Foundation

/// A bounded, transient projection of user-approved local memory. The runtime
/// passes this to the selected model only for the current run; it never becomes
/// a durable Session message or a source of tool authority.
enum AgentLocalMemoryPrompt {
    static let maximumBytes = 7 * 1_024

    static func render(_ entries: [AgentLocalMemoryEntry]) -> String? {
        let redactor = SecretRedactor()
        var selected: [String] = []
        for entry in entries.reversed() where entry.status == .approved {
            let text = redactor.redact(entry.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let candidate = [text] + selected
            guard let data = try? JSONEncoder().encode(candidate),
                  data.count <= maximumBytes else { continue }
            selected = candidate
        }
        guard !selected.isEmpty,
              let data = try? JSONEncoder().encode(selected) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
