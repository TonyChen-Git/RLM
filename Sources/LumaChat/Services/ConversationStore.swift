import Foundation

/// Serializes all conversation disk access so saves and deletes cannot race each other.
actor ConversationStore {
    private let fileManager: FileManager
    private var deletedConversationIDs: Set<UUID> = []
    private var isDeletingAll = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Loads all valid conversations, newest first. Startup cleanup is performed first.
    func loadConversations() throws -> [Conversation] {
        try AppPaths.ensureDirectories()
        try cleanupOrphansImpl()

        let directoryURLs = try fileManager.contentsOfDirectory(
            at: AppPaths.conversations,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        var conversations: [Conversation] = []
        conversations.reserveCapacity(directoryURLs.count)

        for directoryURL in directoryURLs {
            guard
                let directoryID = UUID(uuidString: directoryURL.lastPathComponent),
                (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                continue
            }

            let fileURL = directoryURL.appendingPathComponent("conversation.json", isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }

            // One damaged conversation must not prevent the rest of the sidebar from loading.
            guard
                let conversation = try? decodeConversation(at: fileURL),
                conversation.id == directoryID
            else {
                continue
            }
            conversations.append(conversation)
        }

        return conversations.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func loadConversation(id: UUID) throws -> Conversation? {
        let fileURL = conversationFileURL(for: id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decodeConversation(at: fileURL)
    }

    /// Atomically writes `Conversations/<UUID>/conversation.json`.
    func save(_ conversation: Conversation) throws {
        guard !isDeletingAll, !deletedConversationIDs.contains(conversation.id) else { return }
        try AppPaths.ensureDirectories()

        let directoryURL = AppPaths.conversationDirectory(conversation.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(conversation)
        try AtomicFileWriter.write(data, to: conversationFileURL(for: conversation.id))
    }

    /// Permanently removes the JSON and every attachment for this conversation.
    func delete(id: UUID) throws {
        deletedConversationIDs.insert(id)
        let directoryURL = AppPaths.conversationDirectory(id)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        do {
            try fileManager.removeItem(at: directoryURL)
            guard !fileManager.fileExists(atPath: directoryURL.path) else {
                throw ChatError.server("刪除後對話資料夾仍然存在。")
            }
        } catch {
            deletedConversationIDs.remove(id)
            throw error
        }
    }

    func delete(_ conversation: Conversation) throws {
        try delete(id: conversation.id)
    }

    /// Permanently removes every conversation entry, including a directory whose
    /// JSON is damaged and therefore cannot appear in the sidebar.
    func deleteAll() throws {
        isDeletingAll = true
        defer { isDeletingAll = false }
        try AppPaths.ensureDirectories()
        let root = AppPaths.conversations.standardizedFileURL
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        var failures: [String] = []
        for entry in entries {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == root else { continue }
            let id = UUID(uuidString: candidate.lastPathComponent)
            if let id { deletedConversationIDs.insert(id) }
            do {
                try removeIfPresent(candidate)
            } catch {
                if let id { deletedConversationIDs.remove(id) }
                failures.append("\(candidate.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw ChatError.server("無法完整刪除 \(failures.count) 個資料項目：\(failures.joined(separator: "；"))")
        }
    }

    /// Intended to run at launch. Removes interrupted temp artifacts, orphan
    /// conversation directories and files no longer referenced by persisted messages.
    func cleanupOrphans() throws {
        try AppPaths.ensureDirectories()
        try cleanupOrphansImpl()
    }

    private func conversationFileURL(for id: UUID) -> URL {
        AppPaths.conversationDirectory(id)
            .appendingPathComponent("conversation.json", isDirectory: false)
    }

    private func decodeConversation(at url: URL) throws -> Conversation {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Conversation.self, from: data)
    }

    private func cleanupOrphansImpl() throws {
        let rootItems = try fileManager.contentsOfDirectory(
            at: AppPaths.conversations,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        for itemURL in rootItems {
            let name = itemURL.lastPathComponent

            if isTemporaryArtifact(name) {
                try removeIfPresent(itemURL)
                continue
            }

            guard let conversationID = UUID(uuidString: name) else {
                // AppPaths reserves this directory exclusively for UUID conversations.
                try removeIfPresent(itemURL)
                continue
            }

            let isDirectory = try itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else {
                try removeIfPresent(itemURL)
                continue
            }

            let jsonURL = itemURL.appendingPathComponent("conversation.json", isDirectory: false)
            guard fileManager.fileExists(atPath: jsonURL.path) else {
                // A directory without its canonical JSON is an interrupted draft/import.
                try removeIfPresent(itemURL)
                continue
            }

            removeTemporaryArtifacts(in: itemURL)

            // Do not delete anything from a conversation whose JSON cannot be decoded;
            // retaining recoverable user data is preferable to treating corruption as trash.
            guard
                let conversation = try? decodeConversation(at: jsonURL),
                conversation.id == conversationID
            else {
                continue
            }
            try removeUnreferencedAttachments(for: conversation)
        }
    }

    private func removeUnreferencedAttachments(for conversation: Conversation) throws {
        let directoryURL = AppPaths.attachmentsDirectory(conversation.id)
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
        }

        let referencedNames = Set(
            conversation.messages
                .flatMap(\.attachments)
                .compactMap(\.relativePath)
                .compactMap { relativePath -> String? in
                    let pathURL = URL(fileURLWithPath: relativePath)
                    guard
                        !pathURL.isFileURL || !relativePath.hasPrefix("/"),
                        !relativePath.split(separator: "/").contains(".."),
                        pathURL.deletingLastPathComponent().lastPathComponent == "Attachments"
                    else {
                        return nil
                    }
                    return pathURL.lastPathComponent
                }
        )

        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        )

        for fileURL in files {
            if isTemporaryArtifact(fileURL.lastPathComponent) || !referencedNames.contains(fileURL.lastPathComponent) {
                try removeIfPresent(fileURL)
            }
        }

        if (try? fileManager.contentsOfDirectory(atPath: directoryURL.path).isEmpty) == true {
            try removeIfPresent(directoryURL)
        }
    }

    private func removeTemporaryArtifacts(in directoryURL: URL) {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else {
            return
        }

        let candidates = enumerator.compactMap { $0 as? URL }
            .filter { isTemporaryArtifact($0.lastPathComponent) }
            .sorted { $0.path.count > $1.path.count }

        for candidate in candidates {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func isTemporaryArtifact(_ name: String) -> Bool {
        let lowercaseName = name.lowercased()
        return lowercaseName == ".ds_store"
            || lowercaseName.hasPrefix("._")
            || lowercaseName.hasPrefix(".lumachat-tmp-")
            || lowercaseName.hasPrefix(".tmp-")
            || lowercaseName.hasPrefix(".temporary-")
    }

    private func removeIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
