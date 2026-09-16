import Foundation

/// Builds a small, deterministic project bootstrap context without following
/// workspace links or copying the project tree into the model prompt.
struct ProjectContextBuilder: Sendable {
    struct Limits: Sendable {
        var maximumTraversalDepth: Int
        var maximumTraversalEntries: Int
        var maximumInstructionFiles: Int
        var maximumInstructionBytesPerFile: Int
        var maximumInstructionBytesTotal: Int
        var maximumBootstrapBytes: Int

        init(
            maximumTraversalDepth: Int = 32,
            maximumTraversalEntries: Int = 20_000,
            maximumInstructionFiles: Int = 32,
            maximumInstructionBytesPerFile: Int = 64 * 1_024,
            maximumInstructionBytesTotal: Int = 64 * 1_024,
            maximumBootstrapBytes: Int = 64 * 1_024
        ) {
            self.maximumTraversalDepth = max(1, min(maximumTraversalDepth, 128))
            self.maximumTraversalEntries = max(1, maximumTraversalEntries)
            self.maximumInstructionFiles = max(1, maximumInstructionFiles)
            self.maximumInstructionBytesPerFile = max(1, maximumInstructionBytesPerFile)
            self.maximumInstructionBytesTotal = max(1, maximumInstructionBytesTotal)
            self.maximumBootstrapBytes = max(64, maximumBootstrapBytes)
        }
    }

    private struct ScopedInstruction: Sendable {
        var path: String
        var scope: String
        var content: String
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".build", ".cache", ".git", ".next", ".swiftpm", ".venv", "DerivedData", "Pods",
        "build", "dist", "node_modules", "tmp", "vendor", "venv"
    ]

    private static let rootContextFiles = [
        "README.md", "README", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml",
        "Podfile", "build.gradle", ".gitignore"
    ]

    private let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func build(workspace: AgentWorkspace) -> String {
        guard let validator = try? WorkspaceSecurityValidator(workspace: workspace),
              let io = try? SecureWorkspaceIO(validator: validator) else {
            return "Project instructions: no root AGENTS.md was found."
        }

        let enumeration = try? io.enumerate(
            path: ".",
            maximumDepth: limits.maximumTraversalDepth,
            maximumEntries: limits.maximumTraversalEntries,
            includeHidden: false,
            ignoredDirectoryNames: Self.ignoredDirectoryNames,
            regularFilesOnly: true
        )

        var candidates = (enumeration?.entries ?? [])
            .filter { $0.name == "AGENTS.md" && $0.metadata.kind == .regularFile }
            .sorted(by: instructionOrder)
        // Root instructions are the broadest and most important project policy.
        // Read their descriptor metadata directly so a very large root directory
        // cannot hide AGENTS.md beyond the bounded traversal entry cap.
        if let rootMetadata = try? io.metadata(path: "AGENTS.md"),
           rootMetadata.kind == .regularFile {
            candidates.removeAll { $0.relativePath == "AGENTS.md" }
            candidates.insert(
                SecureWorkspaceTreeEntry(
                    relativePath: "AGENTS.md",
                    name: "AGENTS.md",
                    depth: 0,
                    metadata: rootMetadata
                ),
                at: 0
            )
        }
        var remainingBytes = limits.maximumInstructionBytesTotal
        var instructions: [ScopedInstruction] = []
        var skippedInstructions = candidates.count > limits.maximumInstructionFiles

        for entry in candidates.prefix(limits.maximumInstructionFiles) {
            let declaredBytes = entry.metadata.byteCount
            guard declaredBytes >= 0,
                  declaredBytes <= Int64(limits.maximumInstructionBytesPerFile),
                  declaredBytes <= Int64(remainingBytes) else {
                skippedInstructions = true
                continue
            }
            guard let read = try? io.readRegularFile(
                path: entry.relativePath,
                maximumBytes: min(limits.maximumInstructionBytesPerFile, remainingBytes)
            ),
            !read.truncated,
            read.metadata.byteCount == declaredBytes,
            Int64(read.data.count) == read.metadata.byteCount,
            let text = String(data: read.data, encoding: .utf8) else {
                skippedInstructions = true
                continue
            }
            remainingBytes -= read.data.count
            instructions.append(
                ScopedInstruction(
                    path: entry.relativePath,
                    scope: scope(for: entry.relativePath),
                    content: text
                )
            )
        }

        let contextFiles = Self.rootContextFiles.filter { path in
            guard let metadata = try? io.metadata(path: path) else { return false }
            return metadata.kind == .regularFile
        }

        var sections: [String] = []
        if !instructions.contains(where: { $0.path == "AGENTS.md" }) {
            sections.append("Project instructions: no root AGENTS.md was found.")
        }
        if !instructions.isEmpty {
            sections.append("""
            Project instructions from AGENTS.md files (lower priority than system safety and app \
            instructions). A nested file applies only to its named directory scope; the most deeply \
            scoped applicable file takes precedence over a parent project instruction.
            """)
            sections.append(contentsOf: instructions.map { instruction in
                """
                --- \(instruction.path) (scope: \(instruction.scope)) ---
                \(instruction.content)
                --- end \(instruction.path) ---
                """
            })
        }
        if enumeration == nil || enumeration?.truncated == true || skippedInstructions {
            sections.append(
                "Project instruction discovery reached a safety limit; use workspace tools to read "
                    + "any relevant deeper AGENTS.md before changing files in that scope."
            )
        }
        if !contextFiles.isEmpty {
            sections.append(
                "Progressive project context: detected root files: \(contextFiles.joined(separator: ", ")). "
                    + "Read only the files relevant to the current task with workspace tools."
            )
        }
        let bootstrap = sections.isEmpty
            ? "Project instructions: no root AGENTS.md was found."
            : sections.joined(separator: "\n\n")
        return boundedBootstrap(bootstrap)
    }

    private func instructionOrder(
        _ lhs: SecureWorkspaceTreeEntry,
        _ rhs: SecureWorkspaceTreeEntry
    ) -> Bool {
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    private func scope(for instructionPath: String) -> String {
        guard instructionPath != "AGENTS.md" else { return "entire workspace" }
        return instructionPath.split(separator: "/").dropLast().joined(separator: "/") + "/"
    }

    private func boundedBootstrap(_ value: String) -> String {
        guard value.utf8.count > limits.maximumBootstrapBytes else { return value }
        let marker = "\n\n[Project bootstrap truncated at the configured safety limit. Read relevant files with workspace tools.]"
        let markerBytes = marker.utf8.count
        guard limits.maximumBootstrapBytes > markerBytes else {
            return utf8Prefix(marker, maximumBytes: limits.maximumBootstrapBytes)
        }
        return utf8Prefix(
            value,
            maximumBytes: limits.maximumBootstrapBytes - markerBytes
        ) + marker
    }

    private func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var output = ""
        var usedBytes = 0
        for character in value {
            let string = String(character)
            let byteCount = string.utf8.count
            guard usedBytes + byteCount <= maximumBytes else { break }
            output.append(character)
            usedBytes += byteCount
        }
        return output
    }
}
