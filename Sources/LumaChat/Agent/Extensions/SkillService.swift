import CryptoKit
import Darwin
import Foundation

actor SkillService {
    static let maximumSkillFileBytes = 512 * 1_024
    static let maximumResourceBytes = 2 * 1_024 * 1_024
    static let maximumDiscoveredFiles = 4_096
    static let maximumSkills = 256
    static let maximumLoadedSkills = 4
    static let maximumInstructionCharacters = 80_000
    static let maximumCachedDescriptors = 2_048

    private let fileManager: FileManager
    private let globalRoot: URL
    private var descriptorsByID: [String: SkillDescriptor] = [:]
    private var descriptorRecency: [String] = []

    init(
        globalRoot: URL = AppPaths.globalSkills,
        fileManager: FileManager = .default
    ) {
        self.globalRoot = globalRoot
        self.fileManager = fileManager
    }

    func discover(
        workspace: AgentWorkspace?,
        plugins: [InstalledPlugin]
    ) throws -> [SkillDescriptor] {
        var candidates: [SkillDescriptor] = []
        candidates.append(contentsOf: try discoverRoot(globalRoot, source: .global))

        if let workspace {
            let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            for (relative, source) in [
                (".lumachat/skills", SkillSourceKind.project),
                (".agents/skills", SkillSourceKind.repository),
                ("skills", SkillSourceKind.repository)
            ] {
                candidates.append(contentsOf: try discoverRoot(
                    root.appendingPathComponent(relative, isDirectory: true),
                    source: source,
                    allowedContainerRoot: root
                ))
            }
            candidates.append(contentsOf: try discoverNestedSkills(in: root))
        }

        for plugin in plugins where plugin.enabled
            && Set(plugin.manifest.permissions).isSubset(of: Set(plugin.grantedPermissions)) {
            let root = URL(fileURLWithPath: plugin.installPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            for declaration in plugin.manifest.skills {
                let skillRoot = try containedDirectory(
                    relativePath: declaration.path,
                    root: root
                )
                if let descriptor = try parseSkill(
                    at: skillRoot,
                    source: .plugin,
                    pluginID: plugin.id
                ) {
                    candidates.append(descriptor)
                }
            }
        }

        // A closer scope shadows the same invocation name. Keep every unique
        // source ID for UI, but automatic invocation resolves by precedence.
        let bounded = Array(candidates.prefix(Self.maximumSkills))
        for descriptor in bounded {
            descriptorsByID[descriptor.id] = descriptor
            descriptorRecency.removeAll { $0 == descriptor.id }
            descriptorRecency.append(descriptor.id)
        }
        if descriptorRecency.count > Self.maximumCachedDescriptors {
            let evicted = descriptorRecency.prefix(
                descriptorRecency.count - Self.maximumCachedDescriptors
            )
            for id in evicted { descriptorsByID.removeValue(forKey: id) }
            descriptorRecency.removeFirst(
                descriptorRecency.count - Self.maximumCachedDescriptors
            )
        }
        return bounded.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return precedence($0.source) > precedence($1.source)
        }
    }

    func resolve(
        request: String,
        available: [SkillDescriptor]
    ) throws -> [ResolvedSkill] {
        let explicitNames = Self.explicitInvocations(in: request)
        var selected: [SkillDescriptor] = []
        let preferredByName = preferredDescriptors(available)

        for name in explicitNames {
            if let descriptor = preferredByName[name.lowercased()] {
                selected.append(descriptor)
            }
        }

        if selected.isEmpty {
            let requestWords = Self.words(request)
            let scored = preferredByName.values.compactMap { descriptor -> (Int, SkillDescriptor)? in
                let descriptionWords = Self.words(
                    descriptor.name + " " + descriptor.description + " " + (descriptor.usage ?? "")
                )
                let overlap = requestWords.intersection(descriptionWords).count
                guard overlap >= 2 else { return nil }
                return (overlap, descriptor)
            }
            .sorted {
                if $0.0 != $1.0 { return $0.0 > $1.0 }
                return $0.1.name < $1.1.name
            }
            selected = scored.prefix(2).map(\.1)
        }

        var seen: Set<String> = []
        return try selected
            .filter { seen.insert($0.id).inserted }
            .prefix(Self.maximumLoadedSkills)
            .map { try load($0) }
    }

    func readResource(
        skillID: String,
        relativePath: String,
        allowedSkillIDs: Set<String>
    ) throws -> String {
        guard allowedSkillIDs.contains(skillID),
              let descriptor = descriptorsByID[skillID] else {
            throw ExtensionSubsystemError.permissionNotGranted(
                "Skill resource 不屬於此 Task 已載入的 Skill"
            )
        }
        let root = URL(fileURLWithPath: descriptor.sourcePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resource = try containedRegularFile(relativePath: relativePath, root: root)
        let values = try resource.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= Self.maximumResourceBytes else {
            throw ExtensionSubsystemError.sizeLimit("Skill resource 超過 2 MiB")
        }
        let data = try Data(contentsOf: resource, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExtensionSubsystemError.invalidManifest("Skill resource 不是 UTF-8 文字")
        }
        return text
    }

    private func load(_ descriptor: SkillDescriptor) throws -> ResolvedSkill {
        let root = URL(fileURLWithPath: descriptor.sourcePath, isDirectory: true)
        let file = try containedRegularFile(relativePath: "SKILL.md", root: root)
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= Self.maximumSkillFileBytes,
              let raw = String(data: data, encoding: .utf8) else {
            throw ExtensionSubsystemError.sizeLimit("SKILL.md 必須是 512 KiB 內的 UTF-8")
        }
        let parsed = Self.parseFrontMatter(raw)
        let resources = [
            descriptor.hasReferences ? "references/" : nil,
            descriptor.hasScripts ? "scripts/" : nil,
            descriptor.hasTemplates ? "templates/" : nil,
            descriptor.hasAssets ? "assets/" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        var instructions = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resources.isEmpty {
            instructions += "\n\nAvailable Skill resources: \(resources). Read text resources only with skill_read_resource. Scripts never execute automatically and still require normal process permission."
        }
        instructions = String(instructions.prefix(Self.maximumInstructionCharacters))
        return ResolvedSkill(descriptor: descriptor, instructions: instructions)
    }

    private func discoverRoot(
        _ root: URL,
        source: SkillSourceKind,
        allowedContainerRoot: URL? = nil
    ) throws -> [SkillDescriptor] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            // A scope root symlink must never turn Skill discovery into an
            // implicit read capability outside the workspace/plugin root.
            return []
        }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        if let allowedContainerRoot {
            let allowed = allowedContainerRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path == allowed.path
                    || canonical.path.hasPrefix(allowed.path + "/") else { return [] }
        }
        let children = try fileManager.contentsOfDirectory(
            at: canonical,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var result: [SkillDescriptor] = []
        for child in children.prefix(Self.maximumSkills) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if let descriptor = try parseSkill(at: child, source: source, pluginID: nil) {
                result.append(descriptor)
            }
        }
        return result
    }

    private func discoverNestedSkills(in root: URL) throws -> [SkillDescriptor] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var result: [SkillDescriptor] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > Self.maximumDiscoveredFiles { break }
            let relativeDepth = url.pathComponents.count - root.pathComponents.count
            if relativeDepth > 8 {
                enumerator.skipDescendants()
                continue
            }
            if [".git", "node_modules", "tmp", ".build"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent == "SKILL.md" else {
                continue
            }
            let skillRoot = url.deletingLastPathComponent()
            let normalized = skillRoot.path
            if normalized.contains("/.lumachat/skills/")
                || normalized.contains("/.agents/skills/")
                || normalized.hasSuffix("/skills") {
                continue
            }
            if let descriptor = try parseSkill(
                at: skillRoot,
                source: .nested,
                pluginID: nil
            ) {
                result.append(descriptor)
            }
            if result.count >= Self.maximumSkills { break }
        }
        return result
    }

    private func parseSkill(
        at root: URL,
        source: SkillSourceKind,
        pluginID: String?
    ) throws -> SkillDescriptor? {
        let file: URL
        do {
            file = try containedRegularFile(relativePath: "SKILL.md", root: root)
        } catch {
            return nil
        }
        let values = try file.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= Self.maximumSkillFileBytes else { return nil }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let parsed = Self.parseFrontMatter(raw)
        let fallbackName = root.lastPathComponent
        let name = (parsed.fields["name"] ?? fallbackName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { return nil }
        let description = (parsed.fields["description"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = parsed.fields["usage"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let permissions = Self.parsePermissions(parsed.fields["permissions"])
        return SkillDescriptor(
            id: Self.stableID(source: source, path: canonical.path, pluginID: pluginID),
            name: name,
            description: String(description.prefix(2_000)),
            usage: usage.map { String($0.prefix(2_000)) },
            permissions: permissions,
            source: source,
            sourcePath: canonical.path,
            pluginID: pluginID,
            hasReferences: isSafeDirectory(canonical.appendingPathComponent("references")),
            hasScripts: isSafeDirectory(canonical.appendingPathComponent("scripts")),
            hasTemplates: isSafeDirectory(canonical.appendingPathComponent("templates")),
            hasAssets: isSafeDirectory(canonical.appendingPathComponent("assets"))
        )
    }

    private func containedDirectory(relativePath: String, root: URL) throws -> URL {
        let candidate = try contained(relativePath: relativePath, root: root)
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        return candidate
    }

    private func containedRegularFile(relativePath: String, root: URL) throws -> URL {
        let candidate = try contained(relativePath: relativePath, root: root)
        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        return candidate
    }

    private func contained(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw ExtensionSubsystemError.unsafePath(relativePath)
        }
        return candidate
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
    }

    private func preferredDescriptors(
        _ descriptors: [SkillDescriptor]
    ) -> [String: SkillDescriptor] {
        var result: [String: SkillDescriptor] = [:]
        for descriptor in descriptors {
            let key = descriptor.name.lowercased()
            if let current = result[key], precedence(current.source) >= precedence(descriptor.source) {
                continue
            }
            result[key] = descriptor
        }
        return result
    }

    private func precedence(_ source: SkillSourceKind) -> Int {
        switch source {
        case .global: 0
        case .plugin: 1
        case .repository: 2
        case .project: 3
        case .nested: 4
        }
    }

    private static func explicitInvocations(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_-])\$([A-Za-z0-9][A-Za-z0-9_-]{0,63})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
    }

    private static func words(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func validName(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func parsePermissions(_ raw: String?) -> [ExtensionPermission] {
        guard let raw else { return [] }
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        var seen: Set<ExtensionPermission> = []
        return cleaned.split(separator: ",").compactMap { value in
            let permission = ExtensionPermission(
                rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let permission, seen.insert(permission).inserted else { return nil }
            return permission
        }
    }

    private static func parseFrontMatter(
        _ raw: String
    ) -> (fields: [String: String], body: String) {
        guard raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else {
            return ([:], raw)
        }
        let lines = raw.components(separatedBy: .newlines)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            return ([:], raw)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { fields[key] = value }
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    private static func stableID(
        source: SkillSourceKind,
        path: String,
        pluginID: String?
    ) -> String {
        let input = [source.rawValue, pluginID ?? "", path].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
