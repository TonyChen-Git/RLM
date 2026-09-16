import Darwin
import Foundation

private struct PluginRegistryDocument: Decodable {
    struct Entry: Decodable {
        var id: String
        var source: PluginSource
    }

    var plugins: [Entry]
}

private final class PluginTraversalStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

actor PluginManager {
    static let maximumManifestBytes = 4 * 1_024 * 1_024
    static let maximumPackageBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumPackageEntries = 4_096
    static let maximumInstalledPlugins = 256

    private let recordsFile: URL
    private let installRoot: URL
    private let scratchRoot: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let currentLumaChatVersion: String
    private let bundledPluginCatalog: BundledPluginCatalog
    private var records: [InstalledPlugin] = []

    init(
        recordsFile: URL = AppPaths.pluginRecordsFile,
        installRoot: URL = AppPaths.plugins,
        scratchRoot: URL = AppPaths.extensionScratch,
        fileManager: FileManager = .default,
        session: URLSession? = nil,
        currentLumaChatVersion: String? = nil,
        bundledPluginRoot: URL? = nil
    ) {
        self.recordsFile = recordsFile
        self.installRoot = installRoot
        self.scratchRoot = scratchRoot
        self.fileManager = fileManager
        self.currentLumaChatVersion = currentLumaChatVersion
            ?? Self.detectedLumaChatVersion
        bundledPluginCatalog = BundledPluginCatalog(root: bundledPluginRoot)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func load() throws -> [InstalledPlugin] {
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: recordsFile.path) else {
            records = []
            return []
        }
        let data = try Data(contentsOf: recordsFile, options: [.mappedIfSafe])
        guard data.count <= Self.maximumManifestBytes else {
            throw ExtensionSubsystemError.sizeLimit("plugins.json 超過 4 MiB")
        }
        let decoded = try JSONDecoder().decode([InstalledPlugin].self, from: data)
        guard decoded.count <= Self.maximumInstalledPlugins else {
            throw ExtensionSubsystemError.sizeLimit("已安裝 Plugin 超過 256 組")
        }
        var seen: Set<String> = []
        records = decoded.compactMap { plugin in
            let installedRoot = URL(fileURLWithPath: plugin.installPath, isDirectory: true)
            let expectedRoot = installRoot.appendingPathComponent(plugin.id, isDirectory: true)
            guard seen.insert(plugin.id).inserted,
                  (try? Self.validateManifest(plugin.manifest)) != nil,
                  (try? validateCompatibility(plugin.manifest)) != nil,
                  installedRoot.standardizedFileURL.path == expectedRoot.standardizedFileURL.path,
                  Self.isDirectChild(installedRoot, of: installRoot),
                  fileManager.fileExists(atPath: plugin.installPath),
                  (try? Self.validatePackage(at: installedRoot, fileManager: fileManager)) != nil,
                  (try? Self.validateDeclaredFiles(
                    manifest: plugin.manifest,
                    packageRoot: installedRoot,
                    fileManager: fileManager
                  )) != nil else { return nil }
            var sanitized = plugin
            let granted = Set(plugin.grantedPermissions)
            sanitized.grantedPermissions = plugin.manifest.permissions.filter {
                granted.contains($0)
            }
            return sanitized
        }
        return records.sorted(by: Self.pluginSort)
    }

    func installed() -> [InstalledPlugin] {
        records.sorted(by: Self.pluginSort)
    }

    func inspect(source: PluginSource) async throws -> PluginCandidate {
        try await inspect(source: source, registryTrail: [], depth: 0)
    }

    /// Stages the signed, LumaChat-owned artifact workflow pack through the
    /// exact same validation path as every other local plugin. Installation is
    /// intentionally separate so the Extensions UI still presents and records
    /// the complete permission decision.
    func inspectBundledArtifactWorkflows() async throws -> PluginCandidate {
        let package = try bundledPluginCatalog.packageURL(
            for: BundledPluginCatalog.artifactWorkflowsID
        )
        let candidate = try await inspect(source: .localDirectory(path: package.path))
        guard candidate.manifest.id == BundledPluginCatalog.artifactWorkflowsID else {
            throw ExtensionSubsystemError.invalidManifest(
                "內建 Artifact Workflow Pack 的 manifest ID 不符"
            )
        }
        return candidate
    }

    private func inspect(
        source: PluginSource,
        registryTrail: Set<String>,
        depth: Int
    ) async throws -> PluginCandidate {
        guard depth <= 8 else {
            throw ExtensionSubsystemError.invalidManifest("Registry source 遞迴超過 8 層")
        }
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let staged: URL
        let ownsStagedPath: Bool
        switch source {
        case .localDirectory(let path):
            staged = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            ownsStagedPath = false
        case .git(let repository, let revision):
            staged = scratchRoot.appendingPathComponent(
                "plugin-git-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            ownsStagedPath = true
            do {
                try await clone(repository: repository, revision: revision, destination: staged)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        case .manifest(let url):
            staged = try await stageRemoteManifest(url)
            ownsStagedPath = true
        case .registry(let index, let pluginID):
            guard pluginID.utf8.count <= 128,
                  pluginID.range(
                    of: #"^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$"#,
                    options: .regularExpression
                  ) != nil else {
                throw ExtensionSubsystemError.invalidManifest("Registry plugin ID 無效")
            }
            let registryKey = "\(index.absoluteString)|\(pluginID)"
            guard !registryTrail.contains(registryKey) else {
                throw ExtensionSubsystemError.invalidManifest("Registry source 形成循環")
            }
            let data = try await fetch(index)
            let document = try JSONDecoder().decode(PluginRegistryDocument.self, from: data)
            guard document.plugins.count <= Self.maximumPackageEntries else {
                throw ExtensionSubsystemError.sizeLimit("Registry 超過 4,096 筆")
            }
            let matches = document.plugins.filter { $0.id == pluginID }
            guard let entry = matches.first else {
                throw ExtensionSubsystemError.pluginNotFound(pluginID)
            }
            guard matches.count == 1 else {
                throw ExtensionSubsystemError.invalidManifest("Registry plugin ID 重複")
            }
            if case .localDirectory = entry.source {
                throw ExtensionSubsystemError.unsupportedSource(
                    "Remote registry 不可指向本機目錄"
                )
            }
            guard entry.source != source else {
                throw ExtensionSubsystemError.invalidManifest("Registry source 遞迴指向自己")
            }
            var nextTrail = registryTrail
            nextTrail.insert(registryKey)
            let resolved = try await inspect(
                source: entry.source,
                registryTrail: nextTrail,
                depth: depth + 1
            )
            guard resolved.manifest.id == pluginID else {
                let resolvedRoot = URL(
                    fileURLWithPath: resolved.stagedPath,
                    isDirectory: true
                )
                if Self.isDirectChild(resolvedRoot, of: scratchRoot) {
                    try? fileManager.removeItem(at: resolvedRoot)
                }
                throw ExtensionSubsystemError.invalidManifest("Registry ID 與 manifest 不一致")
            }
            return PluginCandidate(
                manifest: resolved.manifest,
                source: source,
                stagedPath: resolved.stagedPath
            )
        }

        do {
            try Self.validatePackage(at: staged, fileManager: fileManager)
            let manifest = try Self.readManifest(at: staged, fileManager: fileManager)
            try Self.validateManifest(manifest)
            try validateCompatibility(manifest)
            try Self.validateDeclaredFiles(
                manifest: manifest,
                packageRoot: staged,
                fileManager: fileManager
            )
            return PluginCandidate(
                manifest: manifest,
                source: source,
                stagedPath: staged.path
            )
        } catch {
            if ownsStagedPath { try? fileManager.removeItem(at: staged) }
            throw error
        }
    }

    func install(
        _ candidate: PluginCandidate,
        grantedPermissions: Set<ExtensionPermission>
    ) throws -> [InstalledPlugin] {
        try Self.validateManifest(candidate.manifest)
        try validateCompatibility(candidate.manifest)
        let required = Set(candidate.manifest.permissions)
        guard required.isSubset(of: grantedPermissions) else {
            let missing = required.subtracting(grantedPermissions).map(\.title).sorted()
            throw ExtensionSubsystemError.permissionNotGranted(missing.joined(separator: ", "))
        }
        guard records.contains(where: { $0.id == candidate.manifest.id })
                || records.count < Self.maximumInstalledPlugins else {
            throw ExtensionSubsystemError.sizeLimit("已安裝 Plugin 超過 256 組")
        }
        let sourceRoot = URL(fileURLWithPath: candidate.stagedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try Self.validatePackage(at: sourceRoot, fileManager: fileManager)
        try Self.validateDeclaredFiles(
            manifest: candidate.manifest,
            packageRoot: sourceRoot,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

        let target = installRoot.appendingPathComponent(candidate.manifest.id, isDirectory: true)
        guard Self.isDirectChild(target, of: installRoot) else {
            throw ExtensionSubsystemError.unsafePath(candidate.manifest.id)
        }
        let stagedCopy = scratchRoot.appendingPathComponent(
            "plugin-install-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let backup = scratchRoot.appendingPathComponent(
            "plugin-backup-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let previousRecords = records
        var didMoveOld = false
        var didMoveNew = false
        do {
            try fileManager.copyItem(at: sourceRoot, to: stagedCopy)
            try Self.validatePackage(at: stagedCopy, fileManager: fileManager)
            let copiedManifest = try Self.readManifest(at: stagedCopy, fileManager: fileManager)
            guard copiedManifest == candidate.manifest else {
                throw ExtensionSubsystemError.invalidManifest(
                    "Plugin package 在檢查後已變更，請重新檢查"
                )
            }
            try Self.validateDeclaredFiles(
                manifest: copiedManifest,
                packageRoot: stagedCopy,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: target, to: backup)
                didMoveOld = true
            }
            try fileManager.moveItem(at: stagedCopy, to: target)
            didMoveNew = true
            let now = Date()
            let existing = records.first(where: { $0.id == candidate.manifest.id })
            let record = InstalledPlugin(
                manifest: candidate.manifest,
                source: candidate.source,
                installPath: target.path,
                enabled: existing?.enabled ?? true,
                grantedPermissions: candidate.manifest.permissions.filter {
                    grantedPermissions.contains($0)
                },
                installedAt: existing?.installedAt ?? now,
                updatedAt: now,
                lastError: nil
            )
            records.removeAll { $0.id == record.id }
            records.append(record)
            try persist()
            if didMoveOld { try? fileManager.removeItem(at: backup) }
            if Self.shouldDiscardCandidateSource(candidate.source),
               Self.isDirectChild(sourceRoot, of: scratchRoot),
               fileManager.fileExists(atPath: sourceRoot.path) {
                try? fileManager.removeItem(at: sourceRoot)
            }
        } catch {
            records = previousRecords
            // Only remove `target` when this transaction actually installed
            // the staged copy. Validation/copy failures happen before the old
            // package is moved and must leave that existing package intact.
            if didMoveNew, fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: target)
            }
            if didMoveOld { try? fileManager.moveItem(at: backup, to: target) }
            if fileManager.fileExists(atPath: stagedCopy.path) {
                try? fileManager.removeItem(at: stagedCopy)
            }
            throw error
        }
        return records.sorted(by: Self.pluginSort)
    }

    /// Removes an owned inspection staging directory after the review UI is
    /// cancelled. Local directories are user-owned and are never removed.
    func discard(_ candidate: PluginCandidate) throws {
        guard Self.shouldDiscardCandidateSource(candidate.source) else { return }
        let staged = URL(fileURLWithPath: candidate.stagedPath, isDirectory: true)
            .standardizedFileURL
        guard Self.isDirectChild(staged, of: scratchRoot) else {
            throw ExtensionSubsystemError.unsafePath(candidate.stagedPath)
        }
        if fileManager.fileExists(atPath: staged.path) {
            try fileManager.removeItem(at: staged)
        }
    }

    func setEnabled(_ enabled: Bool, pluginID: String) throws -> [InstalledPlugin] {
        guard let index = records.firstIndex(where: { $0.id == pluginID }) else {
            throw ExtensionSubsystemError.pluginNotFound(pluginID)
        }
        let previous = records
        records[index].enabled = enabled
        records[index].lastError = nil
        records[index].updatedAt = Date()
        do { try persist() } catch {
            records = previous
            throw error
        }
        return records.sorted(by: Self.pluginSort)
    }

    func recordFailure(_ message: String, pluginID: String) throws -> [InstalledPlugin] {
        guard let index = records.firstIndex(where: { $0.id == pluginID }) else {
            throw ExtensionSubsystemError.pluginNotFound(pluginID)
        }
        let previous = records
        records[index].lastError = String(SecretRedactor().redact(message).prefix(2_000))
        records[index].updatedAt = Date()
        do { try persist() } catch {
            records = previous
            throw error
        }
        return records.sorted(by: Self.pluginSort)
    }

    func uninstall(pluginID: String) throws -> [InstalledPlugin] {
        guard let record = records.first(where: { $0.id == pluginID }) else {
            throw ExtensionSubsystemError.pluginNotFound(pluginID)
        }
        let target = URL(fileURLWithPath: record.installPath, isDirectory: true)
        guard Self.isDirectChild(target, of: installRoot) else {
            throw ExtensionSubsystemError.unsafePath(record.installPath)
        }
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let quarantine = scratchRoot.appendingPathComponent(
            "plugin-uninstall-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let previous = records
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: target, to: quarantine)
        }
        records.removeAll { $0.id == pluginID }
        do {
            try persist()
            try? fileManager.removeItem(at: quarantine)
        } catch {
            records = previous
            if fileManager.fileExists(atPath: quarantine.path) {
                try? fileManager.moveItem(at: quarantine, to: target)
            }
            throw error
        }
        return records.sorted(by: Self.pluginSort)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(records.sorted(by: Self.pluginSort))
        guard data.count <= Self.maximumManifestBytes else {
            throw ExtensionSubsystemError.sizeLimit("plugins.json 超過 4 MiB")
        }
        try AtomicFileWriter.write(data, to: recordsFile)
    }

    private func stageRemoteManifest(_ url: URL) async throws -> URL {
        let data = try await fetch(url)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        let directory = scratchRoot.appendingPathComponent(
            "plugin-manifest-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(
            try encoder.encode(manifest),
            to: directory.appendingPathComponent("plugin.json")
        )
        return directory
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https",
              !(url.host ?? "").isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= 4_096 else {
            throw ExtensionSubsystemError.unsupportedSource("Remote plugin source 必須使用 HTTPS")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              (200..<300).contains(http.statusCode) else {
            throw ExtensionSubsystemError.unsupportedSource("Remote plugin source 回應失敗")
        }
        guard data.count <= Self.maximumManifestBytes else {
            throw ExtensionSubsystemError.sizeLimit("Remote manifest/registry 超過 4 MiB")
        }
        return data
    }

    private func clone(repository: URL, revision: String?, destination: URL) async throws {
        let scheme = repository.scheme?.lowercased()
        guard (scheme == "https" || scheme == "ssh"),
              !(repository.host ?? "").isEmpty,
              repository.password == nil,
              scheme == "ssh" || repository.user == nil,
              repository.query == nil,
              repository.fragment == nil,
              repository.absoluteString.utf8.count <= 4_096 else {
            throw ExtensionSubsystemError.unsupportedSource("Git plugin 僅接受 HTTPS 或 SSH URL")
        }
        var arguments = ["clone", "--depth", "1", "--", repository.absoluteString, destination.path]
        try await Self.runGit(arguments, timeout: 60)
        if let revision = revision?.trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            guard !revision.hasPrefix("-") && revision.utf8.count <= 256 else {
                throw ExtensionSubsystemError.invalidManifest("Git revision 無效")
            }
            arguments = ["-C", destination.path, "checkout", "--detach", revision]
            try await Self.runGit(arguments, timeout: 30)
        }
        let gitDirectory = destination.appendingPathComponent(".git", isDirectory: true)
        if fileManager.fileExists(atPath: gitDirectory.path) {
            try fileManager.removeItem(at: gitDirectory)
        }
    }

    private static func runGit(_ arguments: [String], timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_LFS_SKIP_SMUDGE": "1",
            "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes",
            "LC_ALL": "C"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try? output.fileHandleForWriting.close()
        let reader = Task.detached(priority: .utility) {
            var collected = Data()
            while true {
                let chunk: Data
                do {
                    guard let next = try output.fileHandleForReading.read(upToCount: 8_192),
                          !next.isEmpty else { break }
                    chunk = next
                } catch {
                    break
                }
                if collected.count < 4_096 {
                    collected.append(chunk.prefix(4_096 - collected.count))
                }
            }
            try? output.fileHandleForReading.close()
            return collected
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning, ContinuousClock.now < deadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            terminate(process)
            _ = await reader.value
            throw error
        }
        if process.isRunning {
            terminate(process)
            _ = await reader.value
            throw ExtensionSubsystemError.unsupportedSource("Git plugin clone 逾時")
        }
        let data = await reader.value
        guard process.terminationStatus == 0 else {
            let detail = safeDiagnostic(
                SecretRedactor().redact(
                    String(decoding: data.prefix(4_096), as: UTF8.self)
                )
            )
            throw ExtensionSubsystemError.unsupportedSource("Git clone 失敗：\(detail)")
        }
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private static func readManifest(
        at packageRoot: URL,
        fileManager: FileManager
    ) throws -> PluginManifest {
        let candidates = [
            packageRoot.appendingPathComponent("plugin.json"),
            packageRoot.appendingPathComponent(".lumachat-plugin/plugin.json")
        ]
        guard let file = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw ExtensionSubsystemError.invalidManifest("缺少 plugin.json")
        }
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumManifestBytes else {
            throw ExtensionSubsystemError.invalidManifest("plugin.json 不是安全的一般檔案")
        }
        return try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: file, options: [.mappedIfSafe])
        )
    }

    private static func validateManifest(_ manifest: PluginManifest) throws {
        let idPattern = #"^[a-z0-9](?:[a-z0-9.-]{0,126}[a-z0-9])?$"#
        guard manifest.id.range(of: idPattern, options: .regularExpression) != nil,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.id.utf8.count <= 128,
              manifest.name.utf8.count <= 256,
              manifest.version.utf8.count <= 64,
              manifest.description.utf8.count <= 8_192,
              manifest.author.utf8.count <= 1_024,
              (manifest.minimumLumaChatVersion?.utf8.count ?? 0) <= 128,
              manifest.skills.count <= 64,
              manifest.tools.count <= 64,
              manifest.commands.count <= 128,
              manifest.hooks.count <= 128,
              manifest.mcpServers.count <= 32,
              manifest.assets.count <= 256 else {
            throw ExtensionSubsystemError.invalidManifest("欄位、數量或 ID 超出限制")
        }
        guard Set(manifest.permissions).count == manifest.permissions.count else {
            throw ExtensionSubsystemError.invalidManifest("permissions 重複")
        }
        guard !manifest.permissions.contains(.filesystemWrite)
                || manifest.permissions.contains(.filesystemRead) else {
            throw ExtensionSubsystemError.invalidManifest(
                "filesystem_write 必須同時宣告 filesystem_read"
            )
        }
        var names: Set<String> = []
        for tool in manifest.tools {
            guard names.insert(tool.name).inserted,
                  tool.name.range(
                    of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#,
                    options: .regularExpression
                  ) != nil,
                  tool.permission != .read,
                  (tool.displayName?.utf8.count ?? 0) <= 256,
                  tool.description.utf8.count <= 4_096,
                  !tool.executable.isEmpty,
                  tool.executable.utf8.count <= 4_096,
                  !tool.executable.contains("\0"),
                  tool.inputSchema.objectValue?["type"]?.stringValue == "object",
                  tool.fixedArguments.count <= 64,
                  tool.fixedArguments.allSatisfy({
                      $0.utf8.count <= 8_192 && !$0.contains("\0")
                  }),
                  tool.timeoutSeconds.map({ $0.isFinite && (1...300).contains($0) }) ?? true else {
                throw ExtensionSubsystemError.invalidManifest("Plugin tool 宣告不安全")
            }
        }
        for hook in manifest.hooks {
            guard hook.permission == .execute || hook.permission == .network,
                  !hook.executable.isEmpty,
                  hook.executable.utf8.count <= 4_096,
                  !hook.executable.contains("\0"),
                  hook.timeoutSeconds.isFinite,
                  (1...60).contains(hook.timeoutSeconds),
                  hook.arguments.count <= 64,
                  hook.arguments.allSatisfy({
                      $0.utf8.count <= 8_192 && !$0.contains("\0")
                  }) else {
                throw ExtensionSubsystemError.invalidManifest("Hook 權限、逾時或參數無效")
            }
        }
        var commandNames: Set<String> = []
        for command in manifest.commands {
            guard commandNames.insert(command.name).inserted,
                  command.name.range(
                    of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#,
                    options: .regularExpression
                  ) != nil,
                  command.description.utf8.count <= 4_096,
                  command.tool.map({ names.contains($0) }) ?? true else {
                throw ExtensionSubsystemError.invalidManifest("Plugin command 宣告不安全")
            }
        }
        let skillPaths = manifest.skills.map(\.path)
        guard Set(skillPaths).count == skillPaths.count,
              Set(manifest.assets).count == manifest.assets.count,
              (skillPaths + manifest.assets).allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0")
        }) else {
            throw ExtensionSubsystemError.invalidManifest("Skill 或 asset 路徑無效")
        }
        let needsProcess = !manifest.tools.isEmpty || !manifest.hooks.isEmpty
            || manifest.mcpServers.contains {
                if case .stdio = $0.transport { return true }
                return false
            }
        guard !needsProcess || manifest.permissions.contains(.process) else {
            throw ExtensionSubsystemError.invalidManifest("Tools/Hooks 必須宣告 process 權限")
        }
        guard manifest.mcpServers.isEmpty || manifest.permissions.contains(.mcp) else {
            throw ExtensionSubsystemError.invalidManifest("MCP server 必須宣告 mcp 權限")
        }
        let needsNetwork = manifest.tools.contains(where: \.requiresNetwork)
            || manifest.hooks.contains(where: \.requiresNetwork)
            || manifest.mcpServers.contains {
                if case .streamableHTTP = $0.transport { return true }
                return false
            }
        guard !needsNetwork || manifest.permissions.contains(.network) else {
            throw ExtensionSubsystemError.invalidManifest("網路 extension 必須宣告 network 權限")
        }
        var serverNames: Set<String> = []
        for server in manifest.mcpServers {
            guard !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  server.name.utf8.count <= 256,
                  serverNames.insert(server.name.lowercased()).inserted else {
                throw ExtensionSubsystemError.invalidManifest("MCP server 名稱無效")
            }
            do {
                switch server.transport {
                case .stdio(let configuration):
                    guard configuration.command.utf8.count <= 4_096,
                          !configuration.command.hasPrefix("/"),
                          configuration.arguments.count <= 64,
                          configuration.arguments.allSatisfy({
                            $0.utf8.count <= 8_192 && !$0.contains("\0")
                          }),
                          configuration.environment.count <= 128,
                          configuration.environment.allSatisfy({ key, value in
                            !key.isEmpty && key.utf8.count <= 256
                                && value.utf8.count <= 16_384
                                && !key.contains("\0") && !value.contains("\0")
                          }),
                          (configuration.workingDirectory?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                        throw ExtensionSubsystemError.invalidManifest("MCP stdio 欄位超出限制")
                    }
                    try MCPStdioPolicy.validate(configuration)
                case .streamableHTTP(let configuration):
                    guard configuration.headers.count <= 128,
                          configuration.headers.allSatisfy({ key, value in
                            !key.isEmpty && key.utf8.count <= 256
                                && value.utf8.count <= 16_384
                                && !key.contains("\r") && !key.contains("\n")
                                && !value.contains("\r") && !value.contains("\n")
                          }) else {
                        throw ExtensionSubsystemError.invalidManifest("MCP HTTP header 超出限制")
                    }
                    try MCPHTTPPolicy.validate(configuration.endpoint)
                }
            } catch {
                throw ExtensionSubsystemError.invalidManifest("MCP transport 無效")
            }
        }
    }

    private func validateCompatibility(_ manifest: PluginManifest) throws {
        guard let minimum = manifest.minimumLumaChatVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !minimum.isEmpty else { return }
        guard let required = Self.versionComponents(minimum),
              let current = Self.versionComponents(currentLumaChatVersion) else {
            throw ExtensionSubsystemError.invalidManifest(
                "minimumLumaChatVersion 必須是有效版本"
            )
        }
        let width = max(required.count, current.count)
        let paddedRequired = required + Array(repeating: 0, count: width - required.count)
        let paddedCurrent = current + Array(repeating: 0, count: width - current.count)
        guard paddedCurrent.lexicographicallyPrecedes(paddedRequired) == false else {
            throw ExtensionSubsystemError.unsupportedSource(
                "需要 LumaChat \(minimum)+；目前版本為 \(currentLumaChatVersion)"
            )
        }
    }

    private static func versionComponents(_ raw: String) -> [Int]? {
        let core = raw.split(separator: "+", maxSplits: 1).first?
            .split(separator: "-", maxSplits: 1).first ?? Substring(raw)
        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var result: [Int] = []
        for field in fields {
            guard !field.isEmpty,
                  field.allSatisfy(\.isNumber),
                  field.count <= 9,
                  let value = Int(field) else { return nil }
            result.append(value)
        }
        return result
    }

    private nonisolated static var detectedLumaChatVersion: String {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "1.4.0" : normalized
    }

    private static func validatePackage(at root: URL, fileManager: FileManager) throws {
        var rootMetadata = stat()
        guard lstat(root.path, &rootMetadata) == 0,
              rootMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExtensionSubsystemError.unsafePath(root.path)
        }
        let traversalStatus = PluginTraversalStatus()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: { _, _ in
                traversalStatus.markFailed()
                return false
            }
        ) else { throw ExtensionSubsystemError.unsafePath(root.path) }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            count += 1
            guard count <= maximumPackageEntries else {
                throw ExtensionSubsystemError.sizeLimit("Plugin 超過 4,096 個項目")
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT == S_IFREG
                    || metadata.st_mode & S_IFMT == S_IFDIR) else {
                throw ExtensionSubsystemError.unsafePath(url.path)
            }
            if metadata.st_mode & S_IFMT == S_IFREG {
                bytes += metadata.st_size
                guard bytes <= maximumPackageBytes else {
                    throw ExtensionSubsystemError.sizeLimit("Plugin 超過 64 MiB")
                }
            }
        }
        guard !traversalStatus.didFail else {
            throw ExtensionSubsystemError.unsafePath(root.path)
        }
    }

    private static func validateDeclaredFiles(
        manifest: PluginManifest,
        packageRoot: URL,
        fileManager: FileManager
    ) throws {
        for skill in manifest.skills {
            let directory = try contained(
                relativePath: skill.path,
                root: packageRoot,
                fileManager: fileManager
            )
            try requireFileType(directory, directory: true)
            let instructions = directory.appendingPathComponent("SKILL.md")
            guard instructions.path.hasPrefix(directory.path + "/") else {
                throw ExtensionSubsystemError.unsafePath(skill.path)
            }
            try requireFileType(instructions, directory: false)
        }
        let mcpExecutables = manifest.mcpServers.compactMap { server -> String? in
            guard case .stdio(let configuration) = server.transport else { return nil }
            return configuration.command
        }
        for relative in manifest.tools.map(\.executable)
            + manifest.hooks.map(\.executable)
            + mcpExecutables {
            let file = try contained(
                relativePath: relative,
                root: packageRoot,
                fileManager: fileManager
            )
            try requireFileType(file, directory: false)
            guard access(file.path, X_OK) == 0 else {
                throw ExtensionSubsystemError.invalidManifest(
                    "Plugin executable 沒有執行權限：\(relative)"
                )
            }
        }
        for relative in manifest.assets {
            _ = try contained(relativePath: relative, root: packageRoot, fileManager: fileManager)
        }
    }

    private static func requireFileType(_ url: URL, directory: Bool) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw ExtensionSubsystemError.unsafePath(url.path)
        }
        let actualType = metadata.st_mode & S_IFMT
        guard (directory ? actualType == S_IFDIR : actualType == S_IFREG) else {
            throw ExtensionSubsystemError.unsafePath(url.path)
        }
    }

    static func contained(
        relativePath: String,
        root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/"),
              fileManager.fileExists(atPath: candidate.path) else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        return candidate
    }

    private static func isDirectChild(_ child: URL, of root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedChild = child.standardizedFileURL
        let canonicalParent = standardizedChild.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        return canonicalParent.path == canonicalRoot.path
            && standardizedChild.lastPathComponent != "."
            && standardizedChild.lastPathComponent != ".."
    }

    private static func shouldDiscardCandidateSource(_ source: PluginSource) -> Bool {
        if case .localDirectory = source { return false }
        return true
    }

    private static func safeDiagnostic(_ value: String) -> String {
        String(value.prefix(4_096)).unicodeScalars.map { scalar in
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                return String(scalar)
            }
            return CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined()
    }

    private static func pluginSort(_ lhs: InstalledPlugin, _ rhs: InstalledPlugin) -> Bool {
        lhs.manifest.name.localizedStandardCompare(rhs.manifest.name) == .orderedAscending
    }
}
