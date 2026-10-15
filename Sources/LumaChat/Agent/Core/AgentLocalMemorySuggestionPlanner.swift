import Foundation

/// Local-only candidate extraction. It recognizes explicit user preferences or
/// requests to remember a fact; it never sends a transcript to a model.
enum AgentLocalMemorySuggestionPlanner {
    struct Candidate: Sendable {
        var text: String
        var category: AgentLocalMemoryCategory
        var source: AgentLocalMemorySource
    }

    static func candidates(
        in session: AgentSession,
        excludingProcessedSourceIDs: Set<UUID> = []
    ) -> [Candidate] {
        guard session.state == .completed,
              session.projectID != nil,
              session.memoryContributionEnabled == true else { return [] }
        let redactor = SecretRedactor()
        return session.messages.suffix(64).compactMap { message in
            guard message.role == .user,
                  !excludingProcessedSourceIDs.contains(message.id),
                  message.content.utf8.count <= 8 * 1_024,
                  !message.content.contains("\0") else { return nil }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = content.lowercased()
            let prefixes: [(String, AgentLocalMemoryCategory)] = [
                ("請記住：", .projectFact), ("請記住:", .projectFact),
                ("記住：", .projectFact), ("記住:", .projectFact),
                ("remember: ", .projectFact), ("please remember: ", .projectFact),
                ("我偏好", .preference), ("i prefer ", .preference),
                ("我們的流程是", .workflow), ("our workflow is ", .workflow)
            ]
            guard let (prefix, category) = prefixes.first(where: {
                lowered.hasPrefix($0.0)
            }) else { return nil }
            let tail = content.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty, tail.utf8.count <= 1_024,
                  !tail.contains("\n"), redactor.redact(tail) == tail,
                  !containsCredentialHint(tail) else { return nil }
            let safeTitle = redactor.redact(String(session.title.prefix(128)))
            let safeExcerpt = redactor.redact(String(content.prefix(512)))
            guard safeTitle.utf8.count <= 256,
                  safeExcerpt.utf8.count <= 1_024 else { return nil }
            return Candidate(
                text: tail, category: category,
                source: AgentLocalMemorySource(
                    taskID: session.id, messageID: message.id,
                    taskTitle: safeTitle, excerpt: safeExcerpt
                )
            )
        }.prefix(16).map { $0 }
    }

    private static func containsCredentialHint(_ text: String) -> Bool {
        let value = text.lowercased()
        let sensitiveWords = [
            "password", "passwd", "token", "secret", "credential", "api key",
            "api_key", "private key", "private_key", "bearer", "cookie",
            "密碼", "憑證", "私鑰", "金鑰", "密鑰", "令牌"
        ]
        if sensitiveWords.contains(where: value.contains) { return true }
        // Opaque values without a label are especially hard to redact safely.
        // A local suggestion may simply omit them and leave the conversation
        // untouched for the user to decide what is safe to save manually.
        return value.range(of: #"[a-z0-9]{32,}"#, options: .regularExpression) != nil
    }
}
