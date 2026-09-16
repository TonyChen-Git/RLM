import Darwin
import Foundation

/// Resolves LumaChat-owned plugin packages without bypassing the normal plugin
/// inspection, permission review, installation, persistence, or failure paths.
/// The catalog is deliberately allow-listed: an arbitrary caller-supplied ID
/// can never turn a bundle resource lookup into a filesystem read primitive.
struct BundledPluginCatalog: Sendable {
    static let artifactWorkflowsID = "com.lumachat.artifact-workflows"

    private static let knownPluginIDs: Set<String> = [artifactWorkflowsID]
    private let explicitRoot: URL?

    init(root: URL? = nil) {
        explicitRoot = root?.standardizedFileURL
    }

    func packageURL(for pluginID: String) throws -> URL {
        guard Self.knownPluginIDs.contains(pluginID) else {
            throw ExtensionSubsystemError.pluginNotFound(pluginID)
        }

        for root in candidateRoots() {
            guard Self.isRealDirectory(root) else { continue }
            let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = canonicalRoot
                .appendingPathComponent(pluginID, isDirectory: true)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent().path == canonicalRoot.path,
                  Self.isRealDirectory(candidate) else { continue }
            return candidate
        }
        throw ExtensionSubsystemError.pluginNotFound(
            "\(pluginID)（此安裝未包含 BuiltinPlugins package）"
        )
    }

    private func candidateRoots() -> [URL] {
        if let explicitRoot { return [explicitRoot] }

        var roots: [URL] = []
        if let resourceRoot = Bundle.main.resourceURL {
            roots.append(resourceRoot.appendingPathComponent("BuiltinPlugins", isDirectory: true))
        }

        // A packaged application must use only the resources covered by its
        // application signature. Falling back to a compile-time checkout path
        // here would let a missing bundle resource silently become mutable
        // local source at runtime.
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            return roots
        }

        // `swift run` does not create an application bundle. This exact source
        // checkout fallback keeps development usable while remaining confined
        // to the repository containing this source file.
        let sourceRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent() // Extensions
            .deletingLastPathComponent() // Agent
            .deletingLastPathComponent() // LumaChat
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Extensions/Builtin", isDirectory: true)
        roots.append(sourceRoot)
        return roots
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
    }
}
