import Darwin
import Foundation

enum BrowserProfilePersistence: Equatable, Sendable {
    /// A new, randomly named profile which is removed when its browser session
    /// ends. This is deliberately the default everywhere in the browser core.
    case ephemeral

    /// A caller-explicit profile that survives normal session shutdown. The
    /// name is a bounded local identifier, not an arbitrary path.
    case persistent(name: String)
}

struct BrowserProfile: Equatable, Identifiable, Sendable {
    static let maximumPersistentNameBytes = 64

    let id: UUID
    let persistence: BrowserProfilePersistence
    let repositoryRoot: URL
    let runtimeRoot: URL
    let dataDirectory: URL

    var isEphemeral: Bool {
        if case .ephemeral = persistence { return true }
        return false
    }

    /// Creates an isolated Chromium user-data directory below the exact
    /// `<repository>/tmp/browser` root. A symlink in the runtime path is
    /// rejected even when it happens to resolve back into the repository.
    static func create(
        repositoryRoot: URL,
        persistence: BrowserProfilePersistence = .ephemeral,
        fileManager: FileManager = .default
    ) throws -> BrowserProfile {
        let standardizedRepository = repositoryRoot.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedRepository.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw BrowserError.invalidRepositoryRoot
        }

        let canonicalRepository = standardizedRepository.resolvingSymlinksInPath()
        let runtimeRoot = canonicalRepository
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
            .standardizedFileURL

        try fileManager.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateDirectory(
            runtimeRoot,
            beneath: canonicalRepository,
            fileManager: fileManager,
            requireExactUnresolvedPath: true
        )

        let id = UUID()
        let kindDirectory: URL
        let profileDirectory: URL
        switch persistence {
        case .ephemeral:
            kindDirectory = runtimeRoot.appendingPathComponent("ephemeral", isDirectory: true)
            profileDirectory = kindDirectory.appendingPathComponent(
                id.uuidString.lowercased(),
                isDirectory: true
            )
        case .persistent(let rawName):
            let name = try validatedPersistentName(rawName)
            kindDirectory = runtimeRoot.appendingPathComponent("persistent", isDirectory: true)
            profileDirectory = kindDirectory.appendingPathComponent(name, isDirectory: true)
        }

        try fileManager.createDirectory(
            at: kindDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateDirectory(
            kindDirectory,
            beneath: runtimeRoot,
            fileManager: fileManager,
            requireExactUnresolvedPath: true
        )

        if fileManager.fileExists(atPath: profileDirectory.path) {
            guard case .persistent = persistence else {
                throw BrowserError.profileDirectoryCollision
            }
            try validateDirectory(
                profileDirectory,
                beneath: kindDirectory,
                fileManager: fileManager,
                requireExactUnresolvedPath: true
            )
        } else {
            try fileManager.createDirectory(
                at: profileDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                try validateDirectory(
                    profileDirectory,
                    beneath: kindDirectory,
                    fileManager: fileManager,
                    requireExactUnresolvedPath: true
                )
            } catch {
                try? fileManager.removeItem(at: profileDirectory)
                throw error
            }
        }

        return BrowserProfile(
            id: id,
            persistence: persistence,
            repositoryRoot: canonicalRepository,
            runtimeRoot: runtimeRoot,
            dataDirectory: profileDirectory
        )
    }

    /// Removes only the exact ephemeral directory created for this profile.
    /// Persistent data can only be removed through the separately explicit
    /// `BrowserService.deletePersistentProfile` operation.
    func removeEphemeralData(fileManager: FileManager = .default) throws {
        guard isEphemeral else { return }
        let expectedParent = runtimeRoot
            .appendingPathComponent("ephemeral", isDirectory: true)
            .standardizedFileURL
        let candidate = dataDirectory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedParent,
              candidate.lastPathComponent == id.uuidString.lowercased(),
              isStrictDescendant(candidate, of: runtimeRoot) else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        try fileManager.removeItem(at: candidate)
    }

    static func validatedPersistentName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.utf8.count <= maximumPersistentNameBytes,
              name != ".",
              name != "..",
              name.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122:
                      true
                  case 45, 46, 95: // -, ., _
                      true
                  default:
                      false
                  }
              }),
              name.first?.isLetter == true || name.first?.isNumber == true else {
            throw BrowserError.invalidPersistentProfileName
        }
        return name
    }

    static func persistentDataDirectory(
        repositoryRoot: URL,
        name rawName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = try validatedPersistentName(rawName)
        let canonicalRepository = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: canonicalRepository.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw BrowserError.invalidRepositoryRoot
        }
        let runtimeRoot = canonicalRepository
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
            .standardizedFileURL
        let persistentRoot = runtimeRoot.appendingPathComponent("persistent", isDirectory: true)
        let candidate = persistentRoot.appendingPathComponent(name, isDirectory: true)
        guard isStrictDescendant(candidate, of: runtimeRoot) else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        return candidate
    }

    static func removePersistentData(
        repositoryRoot: URL,
        name rawName: String,
        fileManager: FileManager = .default
    ) throws {
        let name = try validatedPersistentName(rawName)
        let repository = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        var repositoryIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: repository.path,
            isDirectory: &repositoryIsDirectory
        ), repositoryIsDirectory.boolValue else {
            throw BrowserError.invalidRepositoryRoot
        }
        let runtimeRoot = repository
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: runtimeRoot.path) else { return }
        try validateDirectory(
            runtimeRoot,
            beneath: repository,
            fileManager: fileManager,
            requireExactUnresolvedPath: true
        )
        let persistentRoot = runtimeRoot.appendingPathComponent("persistent", isDirectory: true)
        guard fileManager.fileExists(atPath: persistentRoot.path) else { return }
        try validateDirectory(
            persistentRoot,
            beneath: runtimeRoot,
            fileManager: fileManager,
            requireExactUnresolvedPath: true
        )
        let candidate = persistentRoot.appendingPathComponent(name, isDirectory: true)
        guard isStrictDescendant(candidate, of: runtimeRoot) else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        try validateDirectory(
            candidate,
            beneath: persistentRoot,
            fileManager: fileManager,
            requireExactUnresolvedPath: true
        )
        try fileManager.removeItem(at: candidate)
    }

    private static func validateDirectory(
        _ directory: URL,
        beneath parent: URL,
        fileManager: FileManager,
        requireExactUnresolvedPath: Bool
    ) throws {
        let standardized = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BrowserError.profileDirectoryUnavailable
        }
        let values = try standardized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }

        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        guard isStrictDescendant(resolved, of: resolvedParent) else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        if requireExactUnresolvedPath, resolved.path != standardized.path {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }

        // Persistent profiles can contain authenticated cookies and storage.
        // Validate through a no-follow descriptor, require current-user
        // ownership, and repair legacy group/world permissions to 0700.
        let descriptor = Darwin.open(
            standardized.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw BrowserError.profileDirectoryUnavailable }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw BrowserError.profileDirectoryUnavailable
        }
        if metadata.st_mode & 0o077 != 0 {
            guard Darwin.fchmod(descriptor, 0o700) == 0,
                  Darwin.fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & 0o077 == 0 else {
                throw BrowserError.profileDirectoryUnavailable
            }
        }
    }

    private static func isStrictDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(parentPath + "/")
    }
}
