import Foundation

enum CommandRiskLevel: String, Codable, Sendable, Comparable {
    case safe
    case network
    case dangerous

    private var rank: Int {
        switch self {
        case .safe: 0
        case .network: 1
        case .dangerous: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct CommandRiskAssessment: Codable, Sendable, Equatable {
    var level: CommandRiskLevel
    var reasons: [String]
    /// Kept separately from `level`: a download piped into a shell is both
    /// dangerous and network-bearing, and the sandbox needs both facts.
    var usesNetwork: Bool = false
}

/// A deliberately conservative, lexical preflight for shell commands.
/// PermissionManager remains the authority; this analyzer supplies the signal
/// that prevents apparently ordinary terminal calls from hiding destructive or
/// network-bearing shell fragments.
struct CommandRiskAnalyzer: Sendable {
    func assess(_ command: String) -> CommandRiskAssessment {
        let normalized = command
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\n", with: "; ")
            // Removing lexical quoting is intentionally conservative. It lets
            // us see `/usr/bin/curl` inside env/sh/command wrappers and command
            // substitutions without pretending to be a complete shell parser.
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(
                of: #"\\([^\n])"#,
                with: "$1",
                options: .regularExpression
            )
            .lowercased()

        var dangerousReasons = Set<String>()
        var networkReasons = Set<String>()

        if Self.containsExecutable(
            ["sudo", "doas"],
            in: normalized
        ) {
            dangerousReasons.insert("uses privilege escalation")
        }
        if Self.containsExecutable(
            ["rm", "rmdir", "unlink", "shred"],
            in: normalized
        ) {
            // Even a plain `rm file` is irreversible from the terminal tool and
            // has no ChangeManager snapshot, so it always needs explicit consent.
            dangerousReasons.insert("deletes files without an Agent undo snapshot")
        }
        if Self.containsExecutable(
            ["truncate", "tee"],
            in: normalized
        ) || Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?sed(?=$|[\s;&|()<>])[^;&|\n]*\s-i(?:[a-z]*|\s)"#,
            in: normalized
        ) || Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?perl(?=$|[\s;&|()<>])[^;&|\n]*\s-[a-z]*i[a-z]*"#,
            in: normalized
        ) {
            dangerousReasons.insert("modifies files without an Agent undo snapshot")
        }
        if Self.matches(
            #"(?:^|[^>])>{1,2}\s*(?!&)(?!/dev/(?:null|stdout|stderr)\b)[^;&|\s]+"#,
            in: normalized
        ) {
            dangerousReasons.insert("redirects output into a file without an Agent undo snapshot")
        }
        if Self.containsExecutable(
            ["dd", "wipefs", "newfs", "fdisk", "gpt"],
            in: normalized
        ) || Self.matches(#"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?mkfs(?:\.[a-z0-9_-]+)?(?=$|[\s;&|()<>])"#, in: normalized) {
            dangerousReasons.insert("can overwrite a disk or filesystem")
        }
        if Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?diskutil(?=$|[\s;&|()<>])[^;&|\n]*(?:erase|partition|delete|remove|resize)"#,
            in: normalized
        ) {
            dangerousReasons.insert("can alter a disk or volume")
        }
        if Self.containsExecutable(
            ["shutdown", "reboot", "halt"],
            in: normalized
        ) {
            dangerousReasons.insert("can stop or restart the computer")
        }
        if Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?(?:chmod|chown|chgrp)(?=$|[\s;&|()<>])[^;&|\n]*(?:\s--recursive(?:\s|$)|\s-[a-z]*r[a-z]*(?:\s|$))"#,
            in: normalized
        ) {
            dangerousReasons.insert("recursively changes permissions or ownership")
        }
        if Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?find(?=$|[\s;&|()<>])[^;&|\n]*(?:\s-delete|\s-exec\s+(?:[^\s;&|()<>]+/)?rm\b)"#,
            in: normalized
        ) {
            dangerousReasons.insert("performs a recursive deletion")
        }
        if Self.containsExecutable(["kill", "killall", "pkill"], in: normalized) {
            dangerousReasons.insert("can terminate processes not owned by this Agent session")
        }
        if Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?git(?=$|[\s;&|()<>])[^;&|\n]*(?:reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--|restore[^;&|\n]*--source)"#,
            in: normalized
        ) {
            dangerousReasons.insert("can discard uncommitted Git changes")
        }
        if Self.matches(#">\s*/dev/(?:r?disk|rdisk)[a-z0-9]*"#, in: normalized) {
            dangerousReasons.insert("writes directly to a device")
        }
        if Self.containsExecutable(
            ["osascript", "open", "launchctl", "security", "ps", "pgrep", "top", "lsof"],
            in: normalized
        ) {
            dangerousReasons.insert("can inspect or control host applications, processes, or credentials")
        }

        let directNetworkTools = [
            "curl", "wget", "ftp", "sftp", "ssh", "scp", "telnet", "nc", "ncat",
            "netcat", "socat", "rsync", "aria2c", "http", "https", "ping", "traceroute",
            "traceroute6", "dig", "host", "nslookup", "gh", "glab", "aws", "gcloud", "az",
            "kubectl", "helm", "docker", "podman"
        ]
        if Self.containsExecutable(directNetworkTools, in: normalized) {
            networkReasons.insert("uses a network-capable command")
        }
        if Self.commandSegment(
            executable: "git",
            containsAny: [
                "fetch", "pull", "push", "clone", "ls-remote", "upload-pack",
                "receive-pack", "update", "sync"
            ],
            in: normalized
        ) {
            networkReasons.insert("contacts a Git remote")
        }
        if Self.commandSegment(executable: "git", containsAny: ["push"], in: normalized) {
            // Publishing is an external side effect. It always requires a
            // fresh explicit approval, including in Full Access mode.
            dangerousReasons.insert("publishes local changes to a Git remote")
        }
        let dependencyManagers: [String: [String]] = [
            "npm": ["install", "add", "update", "ci", "publish", "login"],
            "pnpm": ["install", "add", "update", "fetch", "publish"],
            "yarn": ["install", "add", "upgrade", "set", "publish"],
            "pip": ["install", "download"], "pip3": ["install", "download"],
            "gem": ["install", "update", "push"],
            "bundle": ["install", "update"],
            "cargo": ["install", "add", "fetch", "update", "publish", "login"],
            "go": ["get", "install"],
            "brew": ["install", "update", "upgrade", "tap"],
            "pod": ["install", "update", "repo"],
            "composer": ["install", "update", "require"],
            "swift": ["resolve", "update"],
            "xcodebuild": ["-resolvepackagedependencies"]
        ]
        for (tool, operations) in dependencyManagers where Self.commandSegment(
            executable: tool,
            containsAny: operations,
            in: normalized
        ) {
            networkReasons.insert("may download or publish dependencies")
        }
        let developmentServers: [String: [String]] = [
            "npm": ["dev", "start", "serve"],
            "pnpm": ["dev", "start", "serve"],
            "yarn": ["dev", "start", "serve"],
            "bun": ["dev", "start", "serve"],
            "next": ["dev", "start"],
            "vite": ["dev", "serve", "preview"],
            "webpack-dev-server": ["serve"]
        ]
        for (tool, operations) in developmentServers where Self.commandSegment(
            executable: tool,
            containsAny: operations,
            in: normalized
        ) {
            networkReasons.insert("starts a development server or listener")
        }
        if Self.containsExecutable(["uvicorn", "gunicorn", "http-server"], in: normalized)
            || Self.commandSegment(executable: "flask", containsAny: ["run"], in: normalized)
            || Self.commandSegment(executable: "rails", containsAny: ["server", "s"], in: normalized)
            || Self.matches(
                #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?python(?:[0-9.]*)?(?=$|[\s;&|()<>])[^;&|\n]*\s-m\s+(?:http\.server|uvicorn)\b"#,
                in: normalized
            )
            || Self.matches(
                #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?php(?=$|[\s;&|()<>])[^;&|\n]*(?:^|\s)-s(?:\s|$)"#,
                in: normalized
            ) {
            networkReasons.insert("starts a development server or listener")
        }
        if normalized.contains("/dev/tcp/") || normalized.contains("/dev/udp/") {
            networkReasons.insert("opens a shell network socket")
        }
        if Self.matches(
            #"(?:^|[\s;&|()<>])(?:[^\s;&|()<>]+/)?open(?=$|[\s;&|()<>])[^;&|\n]*(?:https?|ftp)://"#,
            in: normalized
        ) {
            networkReasons.insert("opens a remote URL")
        }

        let usesNetwork = !networkReasons.isEmpty
        if usesNetwork, Self.matches(
            #"(?:\||\|&)\s*(?:[^\s;&|()<>]+/)?(?:ba|z|fi)?sh(?=$|[\s;&|()<>])"#,
            in: normalized
        ) {
            dangerousReasons.insert("pipes network-derived content into a shell")
        }

        let level: CommandRiskLevel = !dangerousReasons.isEmpty
            ? .dangerous
            : (usesNetwork ? .network : .safe)
        return CommandRiskAssessment(
            level: level,
            reasons: Array(dangerousReasons.union(networkReasons)).sorted(),
            usesNetwork: usesNetwork
        )
    }

    /// The narrow, read-only command set that Auto Approve Safe may execute
    /// without an inline prompt. Builds, tests, package scripts and arbitrary
    /// interpreters execute repository-controlled code, so they require an
    /// explicit approval even when lexical scanning finds no known bad token.
    func isConservativeAutomaticCommand(_ command: String) -> Bool {
        guard assess(command).level == .safe else { return false }
        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let forbiddenFragments = [
            ";", "&", "|", ">", "<", "`", "$(", "${", "\n", "\r", "\\\n"
        ]
        guard !forbiddenFragments.contains(where: lowered.contains) else { return false }

        let words = lowered
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        guard let rawExecutable = words.first, !rawExecutable.isEmpty else { return false }
        let executable = URL(fileURLWithPath: rawExecutable).lastPathComponent

        // Bare names can be shadowed by a user- or workspace-writable PATH and
        // `./cat` can be an arbitrary executable. Automatic execution is
        // therefore limited to exact platform binaries whose semantics are
        // non-executing and read-only under the Seatbelt workspace boundary.
        let automaticReadBinaries: Set<String> = [
            "/bin/cat", "/bin/ls", "/bin/pwd",
            "/usr/bin/grep", "/usr/bin/egrep", "/usr/bin/fgrep",
            "/usr/bin/head", "/usr/bin/tail", "/usr/bin/wc", "/usr/bin/stat",
            "/usr/bin/file", "/usr/bin/du", "/usr/bin/which"
        ]
        guard automaticReadBinaries.contains(rawExecutable) else { return false }

        switch executable {
        case "grep", "egrep", "fgrep", "ls", "pwd", "cat", "head", "tail", "wc", "stat", "file", "du", "which":
            return true
        default:
            return false
        }
    }

    private static func containsExecutable(_ names: [String], in command: String) -> Bool {
        let alternatives = names
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return matches(
            "(?:^|[\\s;&|()<>])(?:[^\\s;&|()<>]+/)?(?:\(alternatives))(?=$|[\\s;&|()<>])",
            in: command
        )
    }

    private static func commandSegment(
        executable: String,
        containsAny operations: [String],
        in command: String
    ) -> Bool {
        let executablePattern = NSRegularExpression.escapedPattern(for: executable)
        let operationPattern = operations
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return matches(
            "(?:^|[\\s;&|()<>])(?:[^\\s;&|()<>]+/)?\(executablePattern)(?=$|[\\s;&|()<>])"
                + "[^;&|\\n]*(?:^|[\\s()<>])(?:\(operationPattern))(?=$|[\\s;&|()<>])",
            in: command
        )
    }

    private static func matches(_ pattern: String, in command: String) -> Bool {
        command.range(of: pattern, options: .regularExpression) != nil
    }
}
