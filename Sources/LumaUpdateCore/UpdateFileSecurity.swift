import Darwin
import CryptoKit
import Foundation

public struct LumaUpdateApplicationIdentity: Equatable, Sendable {
    public var bundleIdentifier: String
    public var version: String
    public var build: Int
    public var teamIdentifier: String

    public init(bundleIdentifier: String, version: String, build: Int, teamIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.teamIdentifier = teamIdentifier
    }
}

public enum LumaUpdateFileSecurity {
    public static let maximumJournalBytes = 128 * 1_024

    public static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let path = url.standardizedFileURL.path
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw LumaUpdateError.unsafePath(path) }
        defer { _ = Darwin.close(descriptor) }
        var before = Darwin.stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw LumaUpdateError.unsafePath(path)
        }
        let expected = Int(before.st_size)
        var data = Data(count: expected)
        var offset = 0
        while offset < expected {
            let count = data.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: offset), expected - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LumaUpdateError.unsafePath(path) }
            offset += count
        }
        var after = Darwin.stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              after.st_nlink == 1,
              after.st_mode & S_IFMT == S_IFREG else {
            throw LumaUpdateError.unsafePath(path)
        }
        return data
    }

    public static func writeJSONAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(value) } catch {
            throw LumaUpdateError.persistenceFailure(error.localizedDescription)
        }
        guard data.count <= maximumJournalBytes else {
            throw LumaUpdateError.persistenceFailure("document exceeds the bounded size")
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw LumaUpdateError.persistenceFailure(error.localizedDescription)
        }
        let temporary = parent.appendingPathComponent(
            ".lumachat-update-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            _ = chmod(temporary.path, S_IRUSR | S_IWUSR)
            let descriptor = Darwin.open(temporary.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard descriptor >= 0 else { throw LumaUpdateError.unsafePath(temporary.path) }
            let syncResult = Darwin.fsync(descriptor)
            _ = Darwin.close(descriptor)
            guard syncResult == 0 else {
                throw LumaUpdateError.persistenceFailure("temporary document could not be synced")
            }
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw LumaUpdateError.persistenceFailure(String(cString: strerror(errno)))
            }
            let parentDescriptor = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
            if parentDescriptor >= 0 {
                _ = Darwin.fsync(parentDescriptor)
                _ = Darwin.close(parentDescriptor)
            }
        } catch {
            // This is a single host-created regular file, never a recursive
            // cleanup. AppleDouble material is neither matched nor removed.
            try? FileManager.default.removeItem(at: temporary)
            if let known = error as? LumaUpdateError { throw known }
            throw LumaUpdateError.persistenceFailure(error.localizedDescription)
        }
    }

    public static func containsAppleDouble(at root: URL) -> Bool {
        let root = root.standardizedFileURL
        if root.lastPathComponent.hasPrefix("._") { return true }
        var rootInfo = Darwin.stat()
        guard Darwin.lstat(root.path, &rootInfo) == 0 else { return true }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { return false }

        // Foundation intentionally hides AppleDouble sidecars from its directory
        // enumerators on some macOS filesystems. Use POSIX traversal so a safety
        // check cannot silently miss the very metadata it is meant to preserve.
        var pending = [root.path]
        while let directoryPath = pending.popLast() {
            guard let directory = Darwin.opendir(directoryPath) else { return true }
            var childDirectories: [String] = []
            var foundAppleDouble = false
            var traversalFailed = false
            while let entry = Darwin.readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                if name.hasPrefix("._") {
                    foundAppleDouble = true
                    break
                }
                let childPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: false)
                    .path
                var childInfo = Darwin.stat()
                guard Darwin.lstat(childPath, &childInfo) == 0 else {
                    traversalFailed = true
                    break
                }
                if childInfo.st_mode & S_IFMT == S_IFDIR {
                    childDirectories.append(childPath)
                }
            }
            _ = Darwin.closedir(directory)
            if foundAppleDouble || traversalFailed { return true }
            pending.append(contentsOf: childDirectories)
        }
        return false
    }

    public static func containsSymlink(at root: URL) -> Bool {
        var rootInfo = Darwin.stat()
        if Darwin.lstat(root.path, &rootInfo) != 0 || rootInfo.st_mode & S_IFMT == S_IFLNK {
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { return false }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    /// Recursive removal is permitted only for a narrow caller-owned path and
    /// never when AppleDouble metadata exists. In that case the tree is kept so
    /// the operator can move it intact to a metadata-safe filesystem.
    public static func removeOwnedTreeIfSafe(_ url: URL, requiredParent: URL) throws {
        let candidate = url.standardizedFileURL
        let parent = requiredParent.standardizedFileURL
        guard candidate.deletingLastPathComponent() == parent,
              candidate.path != parent.path,
              candidate.path != "/",
              candidate.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw LumaUpdateError.unsafePath(candidate.path)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        guard !containsAppleDouble(at: candidate) else {
            throw LumaUpdateError.unsafePath("AppleDouble-preserved tree: \(candidate.path)")
        }
        try FileManager.default.removeItem(at: candidate)
    }

    public static func applicationIdentity(
        at applicationURL: URL,
        requireNotarization: Bool
    ) throws -> LumaUpdateApplicationIdentity {
        let app = applicationURL.standardizedFileURL
        guard app.pathExtension == "app",
              !containsAppleDouble(at: app),
              !containsSymlink(at: app) else {
            throw LumaUpdateError.untrustedApplication("bundle tree is unsafe")
        }
        let plistURL = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let plistData = try readRegularFile(plistURL, maximumBytes: 1_048_576)
        let plistValue: Any
        do { plistValue = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) }
        catch { throw LumaUpdateError.untrustedApplication("Info.plist is invalid") }
        guard let plist = plistValue as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String,
              let rawBuild = plist["CFBundleVersion"] as? String,
              let build = Int(rawBuild),
              bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              version == version.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LumaUpdateError.untrustedApplication("bundle identity is incomplete")
        }
        _ = try LumaSemanticVersion(version)
        guard build > 0 else { throw LumaUpdateError.invalidBuild }

        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path])
        let details = try run(
            "/usr/bin/codesign",
            ["--display", "--verbose=4", app.path],
            captureOutput: true
        )
        guard let teamLine = details.split(separator: "\n").first(where: {
            $0.hasPrefix("TeamIdentifier=")
        }), !teamLine.dropFirst("TeamIdentifier=".count).isEmpty else {
            throw LumaUpdateError.untrustedApplication("Developer ID TeamIdentifier is absent")
        }
        let team = String(teamLine.dropFirst("TeamIdentifier=".count))
        let lower = details.lowercased()
        guard lower.contains("runtime"), lower.contains("timestamp=") else {
            throw LumaUpdateError.untrustedApplication("hardened runtime or secure timestamp is absent")
        }
        if requireNotarization {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", app.path])
            try run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        }
        return LumaUpdateApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build,
            teamIdentifier: team
        )
    }

    /// Canonical digest of every regular file, directory path and POSIX mode in
    /// an app bundle. The value is signed in the feed, binding the extracted
    /// candidate to the archive even if a local process races staging.
    public static func applicationTreeSHA256(at applicationURL: URL) throws -> String {
        let root = applicationURL.standardizedFileURL
        guard root.pathExtension == "app",
              !containsAppleDouble(at: root),
              !containsSymlink(at: root),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [],
                errorHandler: { _, _ in false }
              ) else {
            throw LumaUpdateError.untrustedApplication("bundle tree cannot be enumerated")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard urls.count < 100_000 else {
                throw LumaUpdateError.untrustedApplication("bundle contains too many entries")
            }
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }
        var hasher = SHA256()
        for url in urls {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty,
                  !relative.contains("\0"),
                  relative.utf8.count <= 4_096 else {
                throw LumaUpdateError.untrustedApplication("bundle path is invalid")
            }
            var info = Darwin.stat()
            guard Darwin.lstat(url.path, &info) == 0 else {
                throw LumaUpdateError.untrustedApplication("bundle entry changed")
            }
            let type: String
            if info.st_mode & S_IFMT == S_IFDIR {
                type = "d"
            } else if info.st_mode & S_IFMT == S_IFREG {
                type = "f"
            } else {
                throw LumaUpdateError.untrustedApplication("bundle contains a special file")
            }
            let header = "\(type)\0\(relative)\0\(info.st_mode & 0o7777)\0\(info.st_size)\0"
            hasher.update(data: Data(header.utf8))
            if type == "f" {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
            }
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        captureOutput: Bool = false
    ) throws -> String {
        guard executable.hasPrefix("/"), arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw LumaUpdateError.processFailure("invalid fixed process invocation")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LumaUpdateError.processFailure(error.localizedDescription)
        }
        let output: String
        if captureOutput {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(decoding: data.prefix(64 * 1_024), as: UTF8.self)
        } else {
            output = ""
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw LumaUpdateError.processFailure(
                output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_048).description
            )
        }
        return output
    }
}
