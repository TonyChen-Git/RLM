import Foundation

enum AppPaths {
    static let uiSmokeProfileEnvironmentKey = "LUMACHAT_UI_SMOKE_PROFILE"
    static let uiSmokeProfileMarker = ".lumachat-ui-smoke-profile"
    static let uiSmokeProfileMarkerContents = "LumaChat UI smoke profile v1\n"

    static let appSupport: URL = {
        // Packaged UI smoke runs the release executable, where the debug/test
        // override below is unavailable. An explicitly marked, temporary QA
        // profile keeps that run out of the user's real Project catalog.
        if let profilePath = ProcessInfo.processInfo.environment[uiSmokeProfileEnvironmentKey] {
            guard let profile = validatedUISmokeProfile(at: profilePath) else {
                fatalError("Invalid \(uiSmokeProfileEnvironmentKey); refusing to use the normal Application Support directory")
            }
            return profile.appendingPathComponent("app-support", isDirectory: true)
        }
#if LUMACHAT_TESTING
        if let override = ProcessInfo.processInfo.environment["LUMACHAT_APP_SUPPORT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
#endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LumaChat", isDirectory: true)
    }()

    static func validatedUISmokeProfile(at path: String) -> URL? {
        guard path.hasPrefix("/"),
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.contains("\0") else { return nil }
        let profile = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard profile.lastPathComponent.hasPrefix("ui-smoke-profile."),
              profile.deletingLastPathComponent().lastPathComponent == "tmp",
              let profileValues = try? profile.resourceValues(forKeys: [
                  .isDirectoryKey, .isSymbolicLinkKey
              ]),
              profileValues.isDirectory == true,
              profileValues.isSymbolicLink != true else { return nil }
        let marker = profile.appendingPathComponent(uiSmokeProfileMarker)
        guard let markerValues = try? marker.resourceValues(forKeys: [
                  .isRegularFileKey, .isSymbolicLinkKey
              ]),
              markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true,
              (try? String(contentsOf: marker, encoding: .utf8))
                  == uiSmokeProfileMarkerContents else { return nil }
        return profile
    }

    static let conversations = appSupport.appendingPathComponent("Conversations", isDirectory: true)
    static let settingsFile = appSupport.appendingPathComponent("settings.json")
    static let agentSessions = appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
    static let agentProjects = appSupport.appendingPathComponent("AgentProjects", isDirectory: true)
    static let agentProjectCatalogFile = agentProjects.appendingPathComponent("catalog.json")
    static let agentSettingsFile = appSupport.appendingPathComponent("agent-settings.json")
    static let agentSubagents = appSupport.appendingPathComponent("AgentSubagents", isDirectory: true)
    static let agentSubagentRecordsFile = agentSubagents.appendingPathComponent("records.json")
    static let extensions = appSupport.appendingPathComponent("Extensions", isDirectory: true)
    static let globalSkills = extensions.appendingPathComponent("Skills", isDirectory: true)
    static let plugins = extensions.appendingPathComponent("Plugins", isDirectory: true)
    static let pluginRecordsFile = extensions.appendingPathComponent("plugins.json")
    static let oauthConnectorsFile = extensions.appendingPathComponent("oauth-connectors.json")
    static let agentWorktrees = appSupport.appendingPathComponent("AgentWorktrees", isDirectory: true)
    static let managedWorktrees = agentWorktrees.appendingPathComponent("Checkouts", isDirectory: true)
    static let managedWorktreeRegistryFile = agentWorktrees.appendingPathComponent("registry.json")

    /// Runtime artifacts use an explicit override during tests and release QA.
    /// Debug source builds default to this checkout's `tmp`; a packaged release
    /// must never embed or write back to the developer's `#filePath`, so it uses
    /// an Application Support runtime root when no override is supplied.
    static let projectTemporaryRoot: URL = {
#if LUMACHAT_TESTING
        if let override = ProcessInfo.processInfo.environment["LUMACHAT_RUNTIME_TMP_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           override.hasPrefix("/"),
           !override.contains("\0") {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let sourceFile = URL(fileURLWithPath: #filePath, isDirectory: false)
        return sourceFile
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // LumaChat
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // project root
            .appendingPathComponent("tmp", isDirectory: true)
            .standardizedFileURL
#else
        return appSupport
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
#endif
    }()

    static let updates = appSupport.appendingPathComponent("Updates", isDirectory: true)
    static let updatePreferencesFile = updates.appendingPathComponent("preferences.json")
    static let updateStateFile = updates.appendingPathComponent("state.json")
    static let updateJournalFile = updates.appendingPathComponent("install-journal.json")
    static let updateStaging = projectTemporaryRoot.appendingPathComponent("updates", isDirectory: true)
    static let updateBackups = updateStaging.appendingPathComponent("backups", isDirectory: true)

    static let agentArtifacts = projectTemporaryRoot
        .appendingPathComponent("agent-artifacts", isDirectory: true)
    static let agentSnapshots = projectTemporaryRoot
        .appendingPathComponent("agent-snapshots", isDirectory: true)
    static let agentProcesses = projectTemporaryRoot
        .appendingPathComponent("agent-processes", isDirectory: true)
    static let agentLogs = projectTemporaryRoot
        .appendingPathComponent("agent-logs", isDirectory: true)
    static let agentWorktreeScratch = projectTemporaryRoot
        .appendingPathComponent("agent-worktrees", isDirectory: true)
    static let extensionScratch = projectTemporaryRoot
        .appendingPathComponent("extensions", isDirectory: true)
    static let hookLogs = projectTemporaryRoot
        .appendingPathComponent("hook-logs", isDirectory: true)
    static let browserAnnotations = projectTemporaryRoot
        .appendingPathComponent("browser-annotations", isDirectory: true)
    /// Chromium user-data directories, including explicitly persistent browser
    /// profiles. This tree is host-only because it can contain credentials.
    static let browserRuntime = projectTemporaryRoot
        .appendingPathComponent("browser", isDirectory: true)

    static func conversationDirectory(_ id: UUID) -> URL {
        conversations.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func attachmentsDirectory(_ id: UUID) -> URL {
        conversationDirectory(id).appendingPathComponent("Attachments", isDirectory: true)
    }

    static func agentSessionDirectory(_ id: UUID) -> URL {
        agentSessions.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func agentAttachmentsDirectory(_ id: UUID) -> URL {
        agentSessionDirectory(id).appendingPathComponent("Attachments", isDirectory: true)
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    }

    static func ensureAgentDirectories() throws {
        for directory in [
            agentSessions,
            agentProjects,
            agentSubagents,
            extensions,
            globalSkills,
            plugins,
            agentWorktrees,
            managedWorktrees,
            agentArtifacts,
            agentSnapshots,
            agentProcesses,
            agentLogs,
            agentWorktreeScratch,
            extensionScratch,
            hookLogs,
            browserAnnotations,
            browserRuntime,
            updates,
            updateStaging,
            updateBackups
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func safeAttachmentURL(relativePath: String, conversationID: UUID) -> URL? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "Attachments",
              !components[1].isEmpty,
              components[1] != ".",
              components[1] != ".." else { return nil }

        let attachments = attachmentsDirectory(conversationID).standardizedFileURL
        let candidate = conversationDirectory(conversationID)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let resolvedRoot = attachments.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return candidate
    }
}
