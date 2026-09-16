import Foundation

/// The repository-local storage used for tool artifacts.
///
/// Tool output must never spill into the system temporary directory. Keeping the
/// location explicit also makes it straightforward for the UI to clean artifacts
/// without touching a user's source files.
enum AgentTemporaryStorage {
    static let root = AppPaths.projectTemporaryRoot

    static func artifactDirectory() throws -> URL {
        try AppPaths.ensureAgentDirectories()
        return AppPaths.agentArtifacts
    }

    static func makeArtifactURL(prefix: String, identifier: UUID = UUID()) throws -> URL {
        let safePrefix = prefix.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return try artifactDirectory()
            .appendingPathComponent("\(String(safePrefix))-\(identifier.uuidString.lowercased()).log")
    }

    /// Creates an isolated HOME and the common toolchain cache locations for one
    /// terminal session. Every path is underneath the source project's tmp tree;
    /// command-provided environment values are not allowed to override them.
    static func makeExecutionEnvironment(
        identifier: UUID = UUID()
    ) throws -> AgentExecutionEnvironment {
        try AppPaths.ensureAgentDirectories()
        let executionRoot = AppPaths.agentProcesses
            .appendingPathComponent("runtime-\(identifier.uuidString.lowercased())", isDirectory: true)
        let directories: [String: URL] = [
            "home": executionRoot.appendingPathComponent("home", isDirectory: true),
            "temporary": executionRoot.appendingPathComponent("tmp", isDirectory: true),
            "xdg-cache": executionRoot.appendingPathComponent("xdg-cache", isDirectory: true),
            "xdg-config": executionRoot.appendingPathComponent("xdg-config", isDirectory: true),
            "xdg-data": executionRoot.appendingPathComponent("xdg-data", isDirectory: true),
            "xdg-state": executionRoot.appendingPathComponent("xdg-state", isDirectory: true),
            "swift-module-cache": executionRoot.appendingPathComponent("swift-module-cache", isDirectory: true),
            "clang-module-cache": executionRoot.appendingPathComponent("clang-module-cache", isDirectory: true),
            "package-cache": executionRoot.appendingPathComponent("package-cache", isDirectory: true),
            "swift-scratch": executionRoot.appendingPathComponent("swift-scratch", isDirectory: true),
            "swift-config": executionRoot.appendingPathComponent("swift-config", isDirectory: true),
            "swift-security": executionRoot.appendingPathComponent("swift-security", isDirectory: true),
            "xcode-derived-data": executionRoot.appendingPathComponent("xcode-derived-data", isDirectory: true),
            "xcode-packages": executionRoot.appendingPathComponent("xcode-packages", isDirectory: true),
            "cargo-home": executionRoot.appendingPathComponent("cargo-home", isDirectory: true),
            "cargo-target": executionRoot.appendingPathComponent("cargo-target", isDirectory: true),
            "rustup-home": executionRoot.appendingPathComponent("rustup-home", isDirectory: true),
            "go-cache": executionRoot.appendingPathComponent("go-cache", isDirectory: true),
            "go-mod-cache": executionRoot.appendingPathComponent("go-mod-cache", isDirectory: true),
            "go-path": executionRoot.appendingPathComponent("go-path", isDirectory: true),
            "gradle-home": executionRoot.appendingPathComponent("gradle-home", isDirectory: true),
            "nuget-packages": executionRoot.appendingPathComponent("nuget-packages", isDirectory: true)
        ]
        for directory in directories.values {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        guard let home = directories["home"],
              let temporary = directories["temporary"],
              let xdgCache = directories["xdg-cache"],
              let xdgConfig = directories["xdg-config"],
              let xdgData = directories["xdg-data"],
              let xdgState = directories["xdg-state"],
              let swiftCache = directories["swift-module-cache"],
              let clangCache = directories["clang-module-cache"],
              let packageCache = directories["package-cache"],
              let swiftScratch = directories["swift-scratch"],
              let swiftConfig = directories["swift-config"],
              let swiftSecurity = directories["swift-security"],
              let xcodeDerivedData = directories["xcode-derived-data"],
              let xcodePackages = directories["xcode-packages"],
              let cargoHome = directories["cargo-home"],
              let cargoTarget = directories["cargo-target"],
              let rustupHome = directories["rustup-home"],
              let goCache = directories["go-cache"],
              let goModCache = directories["go-mod-cache"],
              let goPath = directories["go-path"],
              let gradleHome = directories["gradle-home"],
              let nugetPackages = directories["nuget-packages"] else {
            throw CocoaError(.fileWriteUnknown)
        }
        let temporaryPath = temporary.path.hasSuffix("/") ? temporary.path : temporary.path + "/"
        return AgentExecutionEnvironment(
            root: executionRoot,
            variables: [
                "HOME": home.path,
                "CFFIXED_USER_HOME": home.path,
                "TMPDIR": temporaryPath,
                "TMP": temporary.path,
                "TEMP": temporary.path,
                "XDG_CACHE_HOME": xdgCache.path,
                "XDG_CONFIG_HOME": xdgConfig.path,
                "XDG_DATA_HOME": xdgData.path,
                "XDG_STATE_HOME": xdgState.path,
                "SWIFTPM_MODULECACHE_OVERRIDE": swiftCache.path,
                "CLANG_MODULE_CACHE_PATH": clangCache.path,
                "SWIFTPM_CACHE_PATH": packageCache.path,
                "SWIFTPM_BUILD_DIR": swiftScratch.path,
                "LUMACHAT_SWIFT_SCRATCH_PATH": swiftScratch.path,
                "LUMACHAT_SWIFT_CONFIG_PATH": swiftConfig.path,
                "LUMACHAT_SWIFT_SECURITY_PATH": swiftSecurity.path,
                "LUMACHAT_XCODE_DERIVED_DATA_PATH": xcodeDerivedData.path,
                "LUMACHAT_XCODE_PACKAGES_PATH": xcodePackages.path,
                "PIP_CACHE_DIR": packageCache.appendingPathComponent("pip", isDirectory: true).path,
                "PYTHONPYCACHEPREFIX": packageCache
                    .appendingPathComponent("python-bytecode", isDirectory: true).path,
                "npm_config_cache": packageCache.appendingPathComponent("npm", isDirectory: true).path,
                "YARN_CACHE_FOLDER": packageCache.appendingPathComponent("yarn", isDirectory: true).path,
                "BUNDLE_USER_CACHE": packageCache.appendingPathComponent("bundler", isDirectory: true).path,
                "COMPOSER_CACHE_DIR": packageCache.appendingPathComponent("composer", isDirectory: true).path,
                "CARGO_HOME": cargoHome.path,
                "CARGO_TARGET_DIR": cargoTarget.path,
                "RUSTUP_HOME": rustupHome.path,
                "GOCACHE": goCache.path,
                "GOMODCACHE": goModCache.path,
                "GOPATH": goPath.path,
                "GRADLE_USER_HOME": gradleHome.path,
                "NUGET_PACKAGES": nugetPackages.path
            ]
        )
    }
}

struct AgentExecutionEnvironment: Sendable {
    var root: URL
    var variables: [String: String]
}
