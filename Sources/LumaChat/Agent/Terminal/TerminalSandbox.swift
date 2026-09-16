import Foundation
import Darwin

/// A fail-closed macOS Seatbelt policy for commands launched by the Agent.
///
/// Lexical command analysis is useful for approval UX, but it is not a security
/// boundary. Every shell and every descendant instead inherits this OS policy:
/// source reads/writes stay in explicitly selected workspace roots, disposable
/// state stays in the repository-local tmp tree, and network syscalls are only
/// enabled for commands that the risk analyzer identified as network-bearing.
struct TerminalSandbox: AgentSandboxPolicy, Sendable {
    private static let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    private static let processGroupLauncher = URL(fileURLWithPath: "/usr/bin/perl")

    /// This fixed launcher creates a new session/process group before applying
    /// the sandbox. No command-controlled string is evaluated by Perl.
    private static let processGroupLauncherProgram = """
    use POSIX qw(setsid);
    my $session = setsid();
    die "Unable to create process group: $!\\n"
        if $session < 0 && getpgrp(0) != $$;
    exec @ARGV;
    die "Unable to launch sandbox: $!\\n";
    """

    let runtimeEnvironment: AgentExecutionEnvironment

    private let workspaceRoots: [URL]
    /// Verified repository metadata is not a workspace root. It is activated
    /// only for GitService's closed command surface and never becomes a cwd,
    /// PATH component, or model-facing filesystem authorization.
    private let gitMetadataRoots: [URL]
    private let readOnlyToolchainRoots: [URL]
    private let shimDirectory: URL

    init(
        validator: WorkspaceSecurityValidator,
        additionalReadOnlyRoots: [URL] = []
    ) throws {
        let roots = Self.workspaceRoots(for: validator.workspace)
        let repositoryLayout = roots.first.flatMap { root in
            try? GitRepositoryLayout.inspect(workspaceRoot: root)
        }
        try self.init(
            workspaceRoots: roots,
            gitMetadataRoots: repositoryLayout?.metadataRoots ?? [],
            additionalReadOnlyRoots: additionalReadOnlyRoots
        )
    }

    /// MCP's default working directory is a fresh, host-created directory
    /// inside `tmp/mcp-runtime`. User workspaces must never be allowed to select
    /// that protected tree, so this narrowly-scoped initializer validates the
    /// exact fresh runtime root without weakening WorkspaceSecurityValidator.
    init(trustedMCPRuntimeRoot root: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let expectedParent = AppPaths.projectTemporaryRoot
            .appendingPathComponent("mcp-runtime", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var info = Darwin.stat()
        guard canonicalRoot.path == root.standardizedFileURL.path,
              canonicalRoot.deletingLastPathComponent().path == expectedParent.path,
              Darwin.lstat(canonicalRoot.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw TerminalSessionError.sandboxUnavailable(
                "The MCP runtime root is not a trusted project tmp directory."
            )
        }
        try self.init(
            workspaceRoots: [canonicalRoot],
            gitMetadataRoots: [],
            additionalReadOnlyRoots: []
        )
    }

    /// Extension processes without workspace-file permission execute from one
    /// fresh direct child of the project-local extension scratch directory.
    /// Their package is added read-only, so `process` does not silently imply
    /// access to the user's checkout or persistent extension records.
    init(
        trustedExtensionRuntimeRoot root: URL,
        pluginReadOnlyRoot: URL
    ) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let expectedParent = AppPaths.extensionScratch
            .appendingPathComponent("plugin-sandboxes", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var info = Darwin.stat()
        guard canonicalRoot.path == root.standardizedFileURL.path,
              canonicalRoot.deletingLastPathComponent().path == expectedParent.path,
              Darwin.lstat(canonicalRoot.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw TerminalSessionError.sandboxUnavailable(
                "The extension runtime root is not a trusted project tmp directory."
            )
        }
        try self.init(
            workspaceRoots: [canonicalRoot],
            gitMetadataRoots: [],
            additionalReadOnlyRoots: [pluginReadOnlyRoot]
        )
    }

    private init(
        workspaceRoots: [URL],
        gitMetadataRoots: [URL],
        additionalReadOnlyRoots: [URL]
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: Self.sandboxExecutable.path) else {
            throw TerminalSessionError.sandboxUnavailable(
                "macOS sandbox-exec is unavailable; command execution is disabled."
            )
        }
        guard fileManager.isExecutableFile(atPath: Self.processGroupLauncher.path) else {
            throw TerminalSessionError.sandboxUnavailable(
                "The process-group launcher is unavailable; command execution is disabled."
            )
        }

        runtimeEnvironment = try AgentTemporaryStorage.makeExecutionEnvironment()
        self.workspaceRoots = Self.removingNestedDuplicates(workspaceRoots)
        self.gitMetadataRoots = Self.removingNestedDuplicates(gitMetadataRoots)
        guard !self.workspaceRoots.isEmpty else {
            throw TerminalSessionError.sandboxUnavailable("No valid workspace root is available.")
        }
        let validatedReadOnlyRoots = try additionalReadOnlyRoots.map { root in
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            var metadata = Darwin.stat()
            guard canonical.path != "/",
                  canonical.path != FileManager.default.homeDirectoryForCurrentUser.path,
                  Darwin.lstat(canonical.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else {
                throw TerminalSessionError.sandboxUnavailable(
                    "An additional read-only sandbox root is invalid."
                )
            }
            return canonical
        }
        readOnlyToolchainRoots = Self.removingNestedDuplicates(
            Self.toolchainRoots() + validatedReadOnlyRoots
        )
        shimDirectory = runtimeEnvironment.root.appendingPathComponent("bin", isDirectory: true)
        do {
            try installDeveloperToolShims()
            try preflight()
        } catch {
            let runtime = runtimeEnvironment.root.standardizedFileURL
            let parent = AppPaths.agentProcesses.standardizedFileURL
            if runtime.path.hasPrefix(parent.path + "/") {
                try? FileManager.default.removeItem(at: runtime)
            }
            throw error
        }
    }

    var launcherExecutable: URL { Self.processGroupLauncher }
    /// forkpty already creates a session and controlling terminal, so its child
    /// can enter Seatbelt directly without executing the Perl setsid launcher
    /// in the unsandboxed prelude.
    var pseudoTerminalLauncherExecutable: URL { Self.sandboxExecutable }

    func pseudoTerminalLauncherArguments(
        command: String,
        shell: String,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool = false,
        allowsGitMetadataWrite: Bool = false,
        allowsWorkspaceWrite: Bool = true
    ) -> [String] {
        [
            "-p", profile(
                allowsNetwork: allowsNetwork,
                allowsGitMetadata: allowsGitMetadata,
                allowsGitMetadataWrite: allowsGitMetadataWrite,
                allowsWorkspaceWrite: allowsWorkspaceWrite
            ),
            shell, "-lc", rewriteKnownDeveloperShims(in: command)
        ]
    }

    func containsWorkspacePath(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return workspaceRoots.contains { root in
            resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
        }
    }

    func launcherArguments(
        command: String,
        shell: String,
        allowsNetwork: Bool,
        allowsGitMetadata: Bool = false,
        allowsGitMetadataWrite: Bool = false,
        allowsWorkspaceWrite: Bool = true
    ) -> [String] {
        [
            "-e", Self.processGroupLauncherProgram,
            Self.sandboxExecutable.path,
            "-p", profile(
                allowsNetwork: allowsNetwork,
                allowsGitMetadata: allowsGitMetadata,
                allowsGitMetadataWrite: allowsGitMetadataWrite,
                allowsWorkspaceWrite: allowsWorkspaceWrite
            ),
            shell, "-lc", rewriteKnownDeveloperShims(in: command)
        ]
    }

    /// Launches one exact executable without a shell. The fixed Perl prelude
    /// creates a process group, then Seatbelt directly execs the declared
    /// binary and its already-separated argument vector.
    func launcherArguments(
        executable: URL,
        arguments: [String],
        allowsNetwork: Bool,
        allowsWorkspaceWrite: Bool
    ) -> [String] {
        [
            "-e", Self.processGroupLauncherProgram,
            Self.sandboxExecutable.path,
            "-p", profile(
                allowsNetwork: allowsNetwork,
                allowsGitMetadata: false,
                allowsGitMetadataWrite: false,
                allowsWorkspaceWrite: allowsWorkspaceWrite
            ),
            executable.path
        ] + arguments
    }

    func environment(
        session: [String: String],
        command: [String: String]
    ) -> [String: String] {
        var result = Self.inheritedEnvironment()
        result.merge(Self.safeOverrides(session)) { _, new in new }
        result.merge(Self.safeOverrides(command)) { _, new in new }

        // These values are deliberately applied last. A model-provided command
        // cannot redirect caches or temporary files back into the user's home.
        result.merge(runtimeEnvironment.variables) { _, forced in forced }
        result["PATH"] = safePath(from: result["PATH"])
        return result
    }

    private func preflight() throws {
        let process = Process()
        process.executableURL = Self.sandboxExecutable
        process.arguments = [
            "-p", profile(
                allowsNetwork: false,
                allowsGitMetadata: false,
                allowsGitMetadataWrite: false,
                allowsWorkspaceWrite: true
            ),
            "/usr/bin/true"
        ]
        process.currentDirectoryURL = workspaceRoots[0]
        process.environment = runtimeEnvironment.variables
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TerminalSessionError.sandboxUnavailable(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TerminalSessionError.sandboxUnavailable(
                detail.isEmpty ? "The macOS sandbox policy failed its preflight." : detail
            )
        }
    }

    private func profile(
        allowsNetwork: Bool,
        allowsGitMetadata: Bool,
        allowsGitMetadataWrite: Bool,
        allowsWorkspaceWrite: Bool
    ) -> String {
        let runtimeRoot = runtimeEnvironment.root.resolvingSymlinksInPath()
        let activeGitMetadataRoots = allowsGitMetadata ? gitMetadataRoots : []
        let writableGitMetadataRoots = allowsGitMetadataWrite
            ? activeGitMetadataRoots
            : []
        let protectedAgentRoots = ([
            AppPaths.agentArtifacts,
            AppPaths.agentSnapshots,
            AppPaths.agentProcesses,
            AppPaths.agentLogs,
            AppPaths.agentWorktreeScratch,
            AppPaths.extensionScratch,
            AppPaths.hookLogs,
            AppPaths.browserAnnotations,
            AppPaths.browserRuntime,
            AppPaths.projectTemporaryRoot.appendingPathComponent("mcp-runtime", isDirectory: true)
        ] + workspaceRoots.map {
            $0.appendingPathComponent("tmp/browser", isDirectory: true)
        }).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let workspaceRules = workspaceRoots.map { root in
            let exclusions = protectedAgentRoots.filter { protectedRoot in
                root.path != protectedRoot.path
                    && !root.path.hasPrefix(protectedRoot.path + "/")
            }.map {
                "        (require-not (subpath \(Self.profileString($0.path))))"
            }.joined(separator: "\n")
            return """
                (require-all
                    (subpath \(Self.profileString(root.path)))
            \(exclusions))
            """
        }.joined(separator: "\n")
        let workspaceWriteRules = allowsWorkspaceWrite ? workspaceRules : ""
        let readOnlyRules = readOnlyToolchainRoots
            .map { "    (subpath \(Self.profileString($0.path)))" }
            .joined(separator: "\n")
        let gitMetadataRules = activeGitMetadataRoots
            .map { "    (subpath \(Self.profileString($0.path)))" }
            .joined(separator: "\n")
        let writableGitMetadataRules = writableGitMetadataRoots
            .map { "    (subpath \(Self.profileString($0.path)))" }
            .joined(separator: "\n")
        let readRules = """
        \(workspaceRules)
        \(gitMetadataRules)
            (subpath \(Self.profileString(runtimeRoot.path)))
        \(readOnlyRules)
        """
        let readableRoots = Self.removingNestedDuplicates(
            workspaceRoots + activeGitMetadataRoots + [runtimeRoot] + readOnlyToolchainRoots
        )
        let ancestorRules = readableRoots
            .map { "    (path-ancestors \(Self.profileString($0.path)))" }
            .joined(separator: "\n")
        let writeRules = """
        \(workspaceWriteRules)
        \(writableGitMetadataRules)
            (subpath \(Self.profileString(runtimeRoot.path)))
        """
        let protectedMetadataRules = (
            [AppPaths.projectTemporaryRoot]
                + protectedAgentRoots
                + writableGitMetadataRoots
                + [runtimeRoot]
        )
            .map { "    (literal \(Self.profileString($0.path)))" }
            .joined(separator: "\n")
        let networkRules = allowsNetwork ? """
        (system-network)
        (allow network-outbound network-inbound network-bind)
        """ : ""
        let networkFileRules = allowsNetwork ? """
        (allow file-read* file-test-existence
            (literal "/private/etc/hosts")
            (literal "/private/etc/resolv.conf")
            (subpath "/private/etc/ssl"))
        """ : ""

        return """
        (version 1)
        (import "system.sb")
        (deny default)

        ; system.sb exposes identity files for ordinary platform processes. An
        ; Agent shell does not need them, so explicitly close those exceptions.
        ; `/System/Volumes/Data` is also an alternate namespace for user homes,
        ; external volumes and private caches; denying the entire alias prevents
        ; system.sb's broad `/System` read grant from bypassing workspace roots.
        (deny file-read* file-write* file-test-existence
            (subpath "/System/Volumes/Data"))
        (deny file-read* file-test-existence
            (literal "/private/etc/master.passwd")
            (literal "/private/etc/passwd")
            (literal "/private/var/db/DarwinDirectory/local/recordStore.data")
            (subpath "/System/Volumes/Data/Users")
            (subpath "/opt/homebrew/etc")
            (subpath "/opt/homebrew/var")
            (subpath "/usr/local/etc")
            (subpath "/usr/local/var"))
        (deny file-write* (subpath \(Self.profileString(shimDirectory.path))))
        ; A child may use approved descendants, but it cannot rename or replace
        ; the shared tmp/agent roots themselves and redirect later app writes.
        (deny file-write*
        \(protectedMetadataRules))

        ; Commands may create and inspect only descendants in their own sandbox.
        ; Broad `process*` would expose host process arguments/environments and
        ; permit signaling unrelated user processes.
        (allow process-fork process-exec)
        (allow process-info* (target self))
        (allow process-info* (target children))
        (allow process-info* (target same-sandbox))
        (allow signal (target self))
        (allow signal (target children))
        (allow signal (target same-sandbox))
        ; The PTY is allocated by the trusted parent before sandbox-exec. Its
        ; descendants may operate that inherited slave for raw mode, window
        ; sizing and foreground process-group job control, but cannot open the
        ; allocator (/dev/ptmx) or create another pseudo terminal.
        (allow file-ioctl (regex #"^/dev/ttys[0-9]+$"))
        (deny lsopen appleevent-send authorization-right-obtain)
        (deny mach-lookup
            (global-name "com.apple.securityd")
            (global-name "com.apple.securityd.xpc")
            (global-name "com.apple.securityd.systemkeychain")
            (global-name "com.apple.coreservices.launchservicesd")
            (global-name "com.apple.coreservices.appleevents")
            (global-name "com.apple.lsd.mapdb")
            (global-name "com.apple.pboard"))
        (allow file-read* file-test-existence file-map-executable
        \(readRules))
        (allow file-read-metadata file-test-existence
        \(ancestorRules))
        (allow file-write*
        \(writeRules))

        ; Network configuration and trust roots contain no user project data.
        ; They are readable only when a classified/approved network command runs.
        \(networkFileRules)
        \(networkRules)
        """
    }

    private func safePath(from proposed: String?) -> String {
        let fixedRoots = readOnlyToolchainRoots + workspaceRoots
            + [runtimeEnvironment.root.resolvingSymlinksInPath()]
        let proposedComponents = (proposed ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { rawPath in
                guard rawPath.hasPrefix("/") else { return false }
                let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
                return fixedRoots.contains { root in
                    path.path == root.path || path.path.hasPrefix(root.path + "/")
                }
            }
        let developerBins = readOnlyToolchainRoots.flatMap { root -> [String] in
            guard root.path.hasSuffix("Contents/Developer") else { return [] }
            return [
                root.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin").path,
                root.appendingPathComponent("usr/bin").path
            ]
        }
        let defaults = [shimDirectory.path] + developerBins + [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        var result: [String] = []
        for path in defaults + proposedComponents where !result.contains(path) {
            result.append(path)
        }
        return result.joined(separator: ":")
    }

    private func installDeveloperToolShims() throws {
        try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        guard let developerRoot = readOnlyToolchainRoots.first(where: {
            $0.path.hasSuffix("/Contents/Developer")
        }) else { return }
        let toolchainBin = developerRoot
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin", isDirectory: true)
        let developerBin = developerRoot.appendingPathComponent("usr/bin", isDirectory: true)
        let candidates: [(String, URL, String?)] = [
            ("git", developerBin.appendingPathComponent("git"), nil),
            ("swift", toolchainBin.appendingPathComponent("swift-driver"), "swift"),
            ("swiftc", toolchainBin.appendingPathComponent("swift-driver"), "swiftc"),
            ("clang", toolchainBin.appendingPathComponent("clang"), nil),
            ("clang++", toolchainBin.appendingPathComponent("clang++"), nil),
            ("xcodebuild", developerBin.appendingPathComponent("xcodebuild"), nil)
        ]
        for (name, target, argv0) in candidates
        where FileManager.default.isExecutableFile(atPath: target.path) {
            let invocation: String
            if name == "swift" {
                let variables = runtimeEnvironment.variables
                let scratch = Self.shellQuote(variables["LUMACHAT_SWIFT_SCRATCH_PATH"] ?? "")
                let cache = Self.shellQuote(variables["SWIFTPM_CACHE_PATH"] ?? "")
                let config = Self.shellQuote(variables["LUMACHAT_SWIFT_CONFIG_PATH"] ?? "")
                let security = Self.shellQuote(variables["LUMACHAT_SWIFT_SECURITY_PATH"] ?? "")
                let swiftBuild = Self.shellQuote(toolchainBin.appendingPathComponent("swift-build").path)
                let swiftTest = Self.shellQuote(toolchainBin.appendingPathComponent("swift-test").path)
                let swiftRun = Self.shellQuote(toolchainBin.appendingPathComponent("swift-run").path)
                let swiftPackage = Self.shellQuote(toolchainBin.appendingPathComponent("swift-package").path)
                invocation = """
                typeset __luma_swift_operation=''
                for __luma_probe in "$@"; do
                    case "$__luma_probe" in
                        build|test|run|package) __luma_swift_operation="$__luma_probe"; break ;;
                    esac
                done
                if [[ -n "$__luma_swift_operation" ]]; then
                    typeset -a __luma_args
                    typeset __luma_skip=0
                    typeset __luma_removed_operation=0
                    for __luma_arg in "$@"; do
                        if (( __luma_skip )); then __luma_skip=0; continue; fi
                        if (( ! __luma_removed_operation )) && \
                            [[ "$__luma_arg" == "$__luma_swift_operation" ]]; then
                            __luma_removed_operation=1
                            continue
                        fi
                        case "$__luma_arg" in
                            --scratch-path|--cache-path|--config-path|--security-path|--manifest-cache)
                                __luma_skip=1 ;;
                            --scratch-path=*|--cache-path=*|--config-path=*|--security-path=*|--manifest-cache=*) ;;
                            *) __luma_args+=("$__luma_arg") ;;
                        esac
                    done
                    case "$__luma_swift_operation" in
                        build) typeset __luma_swift_tool=\(swiftBuild) ;;
                        test) typeset __luma_swift_tool=\(swiftTest) ;;
                        run) typeset __luma_swift_tool=\(swiftRun) ;;
                        package) typeset __luma_swift_tool=\(swiftPackage) ;;
                    esac
                    exec "$__luma_swift_tool" "${__luma_args[@]}" \\
                        --scratch-path \(scratch) --cache-path \(cache) \\
                        --config-path \(config) --security-path \(security) \\
                        --manifest-cache local --disable-sandbox
                fi
                exec -a swift \(Self.shellQuote(target.path)) "$@"
                """
            } else if name == "xcodebuild" {
                let variables = runtimeEnvironment.variables
                let derivedData = Self.shellQuote(variables["LUMACHAT_XCODE_DERIVED_DATA_PATH"] ?? "")
                let packages = Self.shellQuote(variables["LUMACHAT_XCODE_PACKAGES_PATH"] ?? "")
                invocation = """
                typeset -a __luma_args
                typeset __luma_skip=0
                for __luma_arg in "$@"; do
                    if (( __luma_skip )); then __luma_skip=0; continue; fi
                    case "$__luma_arg" in
                        -derivedDataPath|-clonedSourcePackagesDirPath) __luma_skip=1 ;;
                        *) __luma_args+=("$__luma_arg") ;;
                    esac
                done
                exec \(Self.shellQuote(target.path)) "${__luma_args[@]}" \\
                    -derivedDataPath \(derivedData) \\
                    -clonedSourcePackagesDirPath \(packages)
                """
            } else if let argv0 {
                invocation = "ARGV0=\(Self.shellQuote(argv0)) exec \(Self.shellQuote(target.path)) \"$@\""
            } else {
                invocation = "exec \(Self.shellQuote(target.path)) \"$@\""
            }
            let data = Data("#!/bin/zsh\n\(invocation)\n".utf8)
            let destination = shimDirectory.appendingPathComponent(name)
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: destination.path
            )
        }
    }

    private func rewriteKnownDeveloperShims(in command: String) -> String {
        var result = command
        for name in ["git", "swift", "swiftc", "clang", "clang++", "xcodebuild"] {
            let shim = shimDirectory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: shim.path) else { continue }
            result = result.replacingOccurrences(
                of: "/usr/bin/\(name)",
                with: shim.path
            )
            for developerRoot in readOnlyToolchainRoots where developerRoot.path.hasSuffix("Contents/Developer") {
                let candidates = [
                    developerRoot.appendingPathComponent("usr/bin/\(name)").path,
                    developerRoot.appendingPathComponent(
                        "Toolchains/XcodeDefault.xctoolchain/usr/bin/\(name)"
                    ).path
                ]
                for candidate in candidates {
                    result = result.replacingOccurrences(of: candidate, with: shim.path)
                }
                if name == "swift" {
                    let driver = developerRoot.appendingPathComponent(
                        "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver"
                    ).path
                    result = result.replacingOccurrences(of: driver, with: shim.path)
                }
            }
            if name == "swift" || name == "xcodebuild" {
                result = result.replacingOccurrences(
                    of: #"(?:[^\s;&|()<>]+/)?xcrun(?:\s+--(?:sdk|toolchain)\s+[^\s;&|()<>]+|\s+-[^\s;&|()<>]+)*\s+"#
                        + NSRegularExpression.escapedPattern(for: name)
                        + #"(?=\s|$)"#,
                    with: shim.path,
                    options: .regularExpression
                )
            }
        }
        return result
    }

    private static func workspaceRoots(for workspace: AgentWorkspace) -> [URL] {
        let fileManager = FileManager.default
        // Persisted allowedPaths are not independent security-scoped grants and
        // can be tampered with in session JSON. Only the selected/bookmarked
        // workspace root is authoritative for terminal access.
        return removingNestedDuplicates([workspace.rootPath].compactMap { raw in
            guard raw.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: raw, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard url.path != "/",
                  fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url
        })
    }

    private static func toolchainRoots() -> [URL] {
        var candidates = [
            "/System/Library", "/System/usr",
            "/Library/Apple", "/Library/Developer", "/Library/Frameworks",
            "/Applications/Xcode.app/Contents/Developer",
            "/Applications/Xcode.app/Contents/Frameworks",
            "/Applications/Xcode.app/Contents/SharedFrameworks",
            "/Applications/Xcode.app/Contents/SystemFrameworks",
            "/usr/bin", "/usr/lib", "/usr/share", "/bin", "/sbin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/opt/homebrew/lib",
            "/opt/homebrew/share", "/opt/homebrew/Cellar", "/opt/homebrew/opt",
            "/usr/local/bin", "/usr/local/sbin", "/usr/local/lib",
            "/usr/local/share", "/usr/local/Cellar", "/usr/local/opt"
        ]
        if let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            let canonicalDeveloperDirectory = URL(
                fileURLWithPath: developerDirectory,
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath()
            let isApplicationDeveloperDirectory = canonicalDeveloperDirectory.path.range(
                of: #"^/Applications/[^/]+\.app/Contents/Developer(?:/.*)?$"#,
                options: .regularExpression
            ) != nil
            let isSystemDeveloperDirectory = canonicalDeveloperDirectory.path
                .hasPrefix("/Library/Developer/")
            if isApplicationDeveloperDirectory || isSystemDeveloperDirectory {
                candidates.append(canonicalDeveloperDirectory.path)
                if isApplicationDeveloperDirectory {
                    let contents = canonicalDeveloperDirectory
                        .deletingLastPathComponent()
                    candidates.append(contents.appendingPathComponent("Frameworks").path)
                    candidates.append(contents.appendingPathComponent("SharedFrameworks").path)
                    candidates.append(contents.appendingPathComponent("SystemFrameworks").path)
                }
            }
        }
        let fileManager = FileManager.default
        return removingNestedDuplicates(candidates.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue ? url : nil
        })
    }

    private static func inheritedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = [
            "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM", "NO_COLOR",
            "USER", "LOGNAME", "SHELL", "DEVELOPER_DIR", "SDKROOT", "ARCHFLAGS"
        ]
        return Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            source[key].map { (key, $0) }
        })
    }

    private static func safeOverrides(_ values: [String: String]) -> [String: String] {
        let blocked = Set([
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD", "BASH_ENV", "ENV",
            "SSH_AUTH_SOCK", "GPG_AGENT_INFO"
        ])
        return values.filter { key, value in
            let normalized = key.uppercased()
            let isLoaderVariable = normalized.hasPrefix("DYLD_")
                || normalized.hasPrefix("LD_")
                || normalized.hasPrefix("PERL")
            return !blocked.contains(normalized) && !isLoaderVariable
                && !key.contains("=") && !key.contains("\0")
                && !value.contains("\0")
        }
    }

    private static func profileString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func removingNestedDuplicates(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls.sorted(by: { $0.path.count < $1.path.count }) {
            if result.contains(where: { root in
                url.path == root.path || url.path.hasPrefix(root.path + "/")
            }) { continue }
            result.append(url)
        }
        return result
    }
}
