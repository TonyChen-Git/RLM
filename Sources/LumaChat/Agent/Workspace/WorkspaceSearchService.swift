import Foundation

struct FileSearchMatch: Codable, Sendable, Equatable {
    var path: String
    var byteCount: Int64
}

struct TextSearchMatch: Codable, Sendable, Equatable {
    var path: String
    var line: Int
    var column: Int?
    var text: String
}

struct SearchResult<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var matches: [Value]
    var truncated: Bool
    var engine: String
}

enum SourceSymbolKind: String, Codable, CaseIterable, Sendable {
    case `class`
    case function
    case `struct`
    case `enum`
    case `protocol`
    case variable
}

enum WorkspaceSearchError: LocalizedError, Equatable, Sendable {
    case literalPatternTooLong(Int)
    case tooManyFilters(Int)
    case filtersTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .literalPatternTooLong(let maximum):
            "Literal search pattern exceeds the \(maximum)-byte safety limit."
        case .tooManyFilters(let maximum):
            "Search accepts at most \(maximum) include/exclude filters."
        case .filtersTooLarge(let maximum):
            "Search filters exceed the \(maximum)-byte safety limit."
        }
    }
}

/// Bounded workspace search performed through pinned directory descriptors.
/// No external executable is discovered or launched; this keeps PATH, process,
/// sandbox, network, and descendant-cleanup risks outside the search boundary.
final class WorkspaceSearchService: @unchecked Sendable {
    static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "DerivedData", "build", "dist", ".next",
        ".cache", "venv", ".venv", "Pods"
    ]

    private static let maximumLiteralPatternBytes = 64 * 1_024
    private static let maximumFilterCount = 128
    private static let maximumFilterBytes = 64 * 1_024
    private static let maximumGitIgnoreRules = 512
    private static let maximumGitIgnorePatternBytes = 64 * 1_024
    private static let maximumGitIgnoreBytes = 1 * 1_024 * 1_024
    private static let maximumGlobOperations = 2_000_000

    private let validator: WorkspaceSecurityValidator
    private let secureIO: SecureWorkspaceIO?
    private let maximumFileBytes: Int64
    private let limits: WorkspaceSearchLimits

    init(
        validator: WorkspaceSecurityValidator,
        fileManager: FileManager = .default,
        maximumFileBytes: Int64 = 2 * 1_024 * 1_024,
        limits: WorkspaceSearchLimits = WorkspaceSearchLimits()
    ) {
        self.validator = validator
        _ = fileManager // Kept for source compatibility with existing callers.
        secureIO = try? SecureWorkspaceIO(validator: validator)
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.limits = limits
    }

    func searchFiles(
        path: String = ".",
        filename: String? = nil,
        extension fileExtension: String? = nil,
        glob: String? = nil,
        maximumResults requestedMaximum: Int = 500
    ) throws -> SearchResult<FileSearchMatch> {
        try Task.checkCancellation()
        try validateShortFilter(filename)
        try validateShortFilter(fileExtension)
        let requestedGlob = try glob.map(BoundedWorkspaceGlob.init)
        let maximum = max(1, min(requestedMaximum, 5_000))
        let secureIO = try requireSecureIO()
        let baseRelativePath = try validator.secureRelativePath(for: path)
        let gitIgnore = GitIgnoreEvaluationState()
        var globBudget = BoundedWorkspaceGlob.WorkBudget(
            maximumOperations: Self.maximumGlobOperations
        )
        if try basePathIsIgnored(
            baseRelativePath,
            io: secureIO,
            state: gitIgnore,
            budget: &globBudget
        ) {
            return SearchResult(matches: [], truncated: gitIgnore.truncated, engine: "descriptor")
        }
        let traversal = try SecureWorkspaceSearchTraversal(
            validator: validator,
            path: path,
            limits: limits
        )
        var matches: [FileSearchMatch] = []
        matches.reserveCapacity(min(maximum, 512))
        var truncated = gitIgnore.truncated

        do {
            let traversalWasTruncated = try traversal.forEachRegularFile(
                shouldDescend: { [self] relativePath, name in
                    guard !Self.ignoredDirectoryNames.contains(name) else { return false }
                    let workspacePath = join(base: baseRelativePath, relative: relativePath)
                    let rules = try gitIgnoreRules(
                        applyingToChildrenOf: parentDirectory(of: workspacePath),
                        io: secureIO,
                        state: gitIgnore
                    )
                    return try !isIgnored(
                        workspaceRelativePath: workspacePath,
                        name: name,
                        isDirectory: true,
                        rules: rules,
                        budget: &globBudget
                    )
                },
                body: { [self] entry in
                    let workspacePath = join(
                        base: baseRelativePath,
                        relative: entry.relativePath
                    )
                    let rules = try gitIgnoreRules(
                        applyingToChildrenOf: parentDirectory(of: workspacePath),
                        io: secureIO,
                        state: gitIgnore
                    )
                    let candidate = WorkspaceGlobCandidate(
                        relativePath: entry.relativePath,
                        name: entry.name
                    )
                    if try isIgnored(
                        workspaceRelativePath: workspacePath,
                        name: entry.name,
                        isDirectory: false,
                        rules: rules,
                        budget: &globBudget
                    ) { return true }
                    if let filename,
                       !entry.name.localizedCaseInsensitiveContains(filename) { return true }
                    if let fileExtension {
                        let wanted = fileExtension.trimmingCharacters(
                            in: CharacterSet(charactersIn: ".")
                        )
                        if URL(fileURLWithPath: entry.name).pathExtension
                            .caseInsensitiveCompare(wanted) != .orderedSame { return true }
                    }
                    if let requestedGlob,
                       try !Self.matchesUserGlob(
                        requestedGlob,
                        candidate: candidate,
                        budget: &globBudget
                       ) { return true }
                    guard matches.count < maximum else { return false }
                    matches.append(FileSearchMatch(
                        path: displayPath(entry.relativePath, base: path),
                        byteCount: entry.byteCount
                    ))
                    return true
                }
            )
            truncated = traversalWasTruncated || gitIgnore.truncated || truncated
        } catch BoundedWorkspaceGlob.MatchLimit.exhausted {
            truncated = true
        }
        return SearchResult(matches: matches, truncated: truncated, engine: "descriptor")
    }

    func grep(
        path: String = ".",
        pattern: String,
        isRegularExpression: Bool = true,
        caseSensitive: Bool = true,
        include: [String] = [],
        exclude: [String] = [],
        maximumResults requestedMaximum: Int = 200
    ) throws -> SearchResult<TextSearchMatch> {
        try Task.checkCancellation()
        let expression: BoundedWorkspaceRegex?
        if isRegularExpression {
            expression = try BoundedWorkspaceRegex(
                pattern: pattern,
                caseSensitive: caseSensitive
            )
        } else {
            guard pattern.utf8.count <= Self.maximumLiteralPatternBytes else {
                throw WorkspaceSearchError.literalPatternTooLong(
                    Self.maximumLiteralPatternBytes
                )
            }
            expression = nil
        }
        let filters = try CompiledFilters(include: include, exclude: exclude)
        let maximum = max(1, min(requestedMaximum, 2_000))
        let secureIO = try requireSecureIO()
        let baseRelativePath = try validator.secureRelativePath(for: path)
        let gitIgnore = GitIgnoreEvaluationState()
        var globBudget = BoundedWorkspaceGlob.WorkBudget(
            maximumOperations: Self.maximumGlobOperations
        )
        if try basePathIsIgnored(
            baseRelativePath,
            io: secureIO,
            state: gitIgnore,
            budget: &globBudget
        ) {
            return SearchResult(matches: [], truncated: gitIgnore.truncated, engine: "descriptor")
        }
        let traversal = try SecureWorkspaceSearchTraversal(
            validator: validator,
            path: path,
            limits: limits
        )
        var totalMatchBudget = BoundedWorkspaceRegex.WorkBudget(
            maximumOperations: limits.maximumRegexOperationsTotal,
            maximumDuration: limits.maximumRegexDurationTotal,
            scope: .total
        )
        var matches: [TextSearchMatch] = []
        matches.reserveCapacity(min(maximum, 256))
        var truncated = gitIgnore.truncated

        do {
            let traversalWasTruncated = try traversal.forEachRegularFile(
                shouldDescend: { [self] relativePath, name in
                    guard !Self.ignoredDirectoryNames.contains(name) else { return false }
                    let workspacePath = join(base: baseRelativePath, relative: relativePath)
                    let rules = try gitIgnoreRules(
                        applyingToChildrenOf: parentDirectory(of: workspacePath),
                        io: secureIO,
                        state: gitIgnore
                    )
                    return try !isIgnored(
                        workspaceRelativePath: workspacePath,
                        name: name,
                        isDirectory: true,
                        rules: rules,
                        budget: &globBudget
                    )
                },
                body: { [self] entry in
                    let workspacePath = join(
                        base: baseRelativePath,
                        relative: entry.relativePath
                    )
                    let rules = try gitIgnoreRules(
                        applyingToChildrenOf: parentDirectory(of: workspacePath),
                        io: secureIO,
                        state: gitIgnore
                    )
                    let candidate = WorkspaceGlobCandidate(
                        relativePath: entry.relativePath,
                        name: entry.name
                    )
                    if try isIgnored(
                        workspaceRelativePath: workspacePath,
                        name: entry.name,
                        isDirectory: false,
                        rules: rules,
                        budget: &globBudget
                    ) { return true }
                    if try !filters.includes(candidate, budget: &globBudget) { return true }
                    guard entry.byteCount >= 0,
                          entry.byteCount <= maximumFileBytes else { return true }
                    let readLimit = traversal.maximumContentReadBytes(
                        upTo: maximumFileReadBytes
                    )
                    guard readLimit > 0 else { return false }

                    let read = try secureIO.readRegularFile(
                        path: workspacePath,
                        maximumBytes: readLimit
                    )
                    if read.truncated {
                        // Exhausting the aggregate allowance truncates the whole
                        // search. A concurrent growth beyond the per-file limit is
                        // simply an oversized file and remains skipped.
                        return readLimit == maximumFileReadBytes
                    }
                    guard traversal.consumeContentBytes(read.data.count) else { return false }
                    guard read.metadata.kind == .regularFile,
                          !read.data.contains(0),
                          let text = String(data: read.data, encoding: .utf8) else { return true }

                    var fileMatchBudget = BoundedWorkspaceRegex.WorkBudget(
                        maximumOperations: limits.maximumRegexOperationsPerFile,
                        maximumDuration: limits.maximumRegexDurationPerFile,
                        scope: .file
                    )
                    do {
                        let completedFile = try forEachLine(in: text) { lineNumber, line in
                            try Task.checkCancellation()
                            let column: Int?
                            if let expression {
                                guard line.utf8.count <= limits.maximumRegexLineBytes else {
                                    truncated = true
                                    return true
                                }
                                column = try expression.firstMatch(
                                    in: String(line),
                                    fileBudget: &fileMatchBudget,
                                    totalBudget: &totalMatchBudget
                                )
                            } else {
                                try fileMatchBudget.checkNow()
                                try totalMatchBudget.checkNow()
                                column = literalColumn(
                                    pattern: pattern,
                                    in: line,
                                    caseSensitive: caseSensitive
                                )
                            }
                            guard let column else { return true }
                            matches.append(TextSearchMatch(
                                path: displayPath(entry.relativePath, base: path),
                                line: lineNumber,
                                column: column,
                                text: String(line.prefix(500))
                            ))
                            return matches.count < maximum
                        }
                        return completedFile
                    } catch BoundedWorkspaceRegex.MatchLimit.file {
                        truncated = true
                        return true
                    } catch BoundedWorkspaceRegex.MatchLimit.total {
                        truncated = true
                        return false
                    }
                }
            )
            truncated = traversalWasTruncated || gitIgnore.truncated || truncated
        } catch BoundedWorkspaceGlob.MatchLimit.exhausted {
            truncated = true
        }
        return SearchResult(matches: matches, truncated: truncated, engine: "descriptor")
    }

    func findSymbol(
        path: String = ".",
        name: String,
        kind: SourceSymbolKind? = nil,
        maximumResults: Int = 100
    ) throws -> SearchResult<TextSearchMatch> {
        let escapedName = Self.escapeRegularExpressionLiteral(name)
        let patterns: [SourceSymbolKind: String] = [
            .class: #"\b(?:class|actor)\s+"#,
            .function: #"\b(?:func|function|def|fn)\s+"#,
            .struct: #"\bstruct\s+"#,
            .enum: #"\benum\s+"#,
            .protocol: #"\b(?:protocol|interface|trait)\s+"#,
            .variable: #"\b(?:let|var|const)\s+"#
        ]
        let prefix: String
        if let kind { prefix = patterns[kind] ?? "" }
        else { prefix = "(?:" + patterns.values.sorted().joined(separator: "|") + ")" }
        return try grep(
            path: path,
            pattern: prefix + escapedName + #"\b"#,
            isRegularExpression: true,
            caseSensitive: true,
            include: ["*.swift", "*.m", "*.mm", "*.h", "*.c", "*.cc", "*.cpp", "*.ts", "*.tsx", "*.js", "*.jsx", "*.py", "*.rs", "*.go", "*.java", "*.kt"],
            maximumResults: maximumResults
        )
    }

    private struct CompiledFilters {
        var include: [BoundedWorkspaceGlob]
        var exclude: [BoundedWorkspaceGlob]

        init(include: [String], exclude: [String]) throws {
            guard include.count <= WorkspaceSearchService.maximumFilterCount,
                  exclude.count <= WorkspaceSearchService.maximumFilterCount else {
                throw WorkspaceSearchError.tooManyFilters(
                    WorkspaceSearchService.maximumFilterCount
                )
            }
            let byteCount = (include + exclude).reduce(0) { partial, filter in
                partial + filter.utf8.count
            }
            guard byteCount <= WorkspaceSearchService.maximumFilterBytes else {
                throw WorkspaceSearchError.filtersTooLarge(
                    WorkspaceSearchService.maximumFilterBytes
                )
            }
            self.include = try include.map(BoundedWorkspaceGlob.init)
            self.exclude = try exclude.map(BoundedWorkspaceGlob.init)
        }

        func includes(
            _ candidate: WorkspaceGlobCandidate,
            budget: inout BoundedWorkspaceGlob.WorkBudget
        ) throws -> Bool {
            if !include.isEmpty {
                var found = false
                for glob in include where !found {
                    found = try WorkspaceSearchService.matchesUserGlob(
                        glob,
                        candidate: candidate,
                        budget: &budget
                    )
                }
                if !found { return false }
            }
            for glob in exclude {
                if try WorkspaceSearchService.matchesUserGlob(
                    glob,
                    candidate: candidate,
                    budget: &budget
                ) { return false }
            }
            return true
        }
    }

    private struct GitIgnoreRule {
        var glob: BoundedWorkspaceGlob
        var negated: Bool
        var directoryOnly: Bool
        var matchesWholePath: Bool
        var scopeRelativePath: String
        var patternBytes: Int
    }

    private struct GitIgnoreRules {
        var rules: [GitIgnoreRule]
        var truncated: Bool
        var patternBytes: Int
    }

    private final class GitIgnoreEvaluationState {
        var rulesByDirectory: [String: [GitIgnoreRule]] = [:]
        var loadedDirectories: Set<String> = []
        var truncated = false
        var readBytes = 0
        var ruleCount = 0
        var patternBytes = 0
    }

    private func loadGitIgnoreRules(
        directory: String,
        io: SecureWorkspaceIO,
        state: GitIgnoreEvaluationState
    ) throws {
        let normalizedDirectory = normalizedDirectory(directory)
        guard state.loadedDirectories.insert(normalizedDirectory).inserted else { return }
        state.rulesByDirectory[normalizedDirectory] = []

        let remainingBytes = Self.maximumGitIgnoreBytes - min(
            state.readBytes,
            Self.maximumGitIgnoreBytes
        )
        guard remainingBytes > 0 else {
            state.truncated = true
            return
        }
        let gitIgnorePath = join(base: normalizedDirectory, relative: ".gitignore")
        let read: SecureWorkspaceRead
        do {
            read = try io.readRegularFile(
                path: gitIgnorePath,
                maximumBytes: remainingBytes
            )
        } catch {
            try Task.checkCancellation()
            // Missing files, links, FIFOs, sockets, and devices are all treated
            // as no ignore file. SecureWorkspaceIO opens nonblocking, verifies a
            // regular descriptor with fstat, and never follows a link.
            return
        }
        state.readBytes += read.data.count
        guard !read.truncated else {
            state.truncated = true
            return
        }
        guard read.metadata.kind == .regularFile,
              !read.data.contains(0),
              let text = String(data: read.data, encoding: .utf8) else {
            return
        }
        let parsed = parseGitIgnore(text, scopeRelativePath: normalizedDirectory)
        state.truncated = state.truncated || parsed.truncated
        var accepted: [GitIgnoreRule] = []
        accepted.reserveCapacity(parsed.rules.count)
        for rule in parsed.rules {
            guard state.ruleCount < Self.maximumGitIgnoreRules,
                  rule.patternBytes <= Self.maximumGitIgnorePatternBytes - min(
                    state.patternBytes,
                    Self.maximumGitIgnorePatternBytes
                  ) else {
                state.truncated = true
                break
            }
            accepted.append(rule)
            state.ruleCount += 1
            state.patternBytes += rule.patternBytes
        }
        state.rulesByDirectory[normalizedDirectory] = accepted
    }

    private func parseGitIgnore(
        _ text: String,
        scopeRelativePath: String
    ) -> GitIgnoreRules {
        var rules: [GitIgnoreRule] = []
        rules.reserveCapacity(min(Self.maximumGitIgnoreRules, 128))
        var patternBytes = 0
        var truncated = false

        var start = text.startIndex
        while true {
            let remainder = text[start...]
            let end = remainder.firstIndex(where: { $0 == "\n" || $0 == "\r" })
                ?? text.endIndex
            var line = normalizedGitIgnoreLine(text[start..<end])
            // Only an unescaped leading `#` starts a comment. Leading spaces
            // are part of a pattern, exactly as they are in a git ignore file.
            if !line.isEmpty, !line.hasPrefix("#") {
                guard rules.count < Self.maximumGitIgnoreRules else {
                    truncated = true
                    break
                }
                let negated = line.hasPrefix("!")
                if negated { line.removeFirst() }
                let anchored = line.hasPrefix("/")
                if anchored { line.removeFirst() }
                let directoryOnly = line.hasSuffix("/")
                    && !Self.lastCharacterIsEscaped(in: line)
                if directoryOnly { line.removeLast() }
                if !line.isEmpty {
                    patternBytes += line.utf8.count
                    guard patternBytes <= Self.maximumGitIgnorePatternBytes else {
                        truncated = true
                        break
                    }
                    do {
                        rules.append(GitIgnoreRule(
                            glob: try BoundedWorkspaceGlob(line),
                            negated: negated,
                            directoryOnly: directoryOnly,
                            matchesWholePath: anchored || line.contains("/"),
                            scopeRelativePath: normalizedDirectory(scopeRelativePath),
                            patternBytes: line.utf8.count
                        ))
                    } catch {
                        // An individually oversized rule is ignored, but callers
                        // are told that ignore evaluation was incomplete.
                        truncated = true
                    }
                }
            }
            guard end != text.endIndex else { break }
            start = text.index(after: end)
            if text[end] == "\r", start < text.endIndex, text[start] == "\n" {
                start = text.index(after: start)
            }
        }
        return GitIgnoreRules(
            rules: rules,
            truncated: truncated,
            patternBytes: patternBytes
        )
    }

    /// Git ignores unescaped trailing ASCII spaces while retaining escaped
    /// ones. Backslashes stay in the pattern so `BoundedWorkspaceGlob` can
    /// consistently quote `#`, `!`, whitespace, and wildcard metacharacters.
    private func normalizedGitIgnoreLine(_ rawLine: Substring) -> String {
        var characters = Array(rawLine)
        while characters.last == " " {
            var backslashCount = 0
            var index = characters.count - 1
            while index > 0, characters[index - 1] == "\\" {
                backslashCount += 1
                index -= 1
            }
            if backslashCount.isMultiple(of: 2) {
                characters.removeLast()
            } else {
                break
            }
        }
        return String(characters)
    }

    private static func lastCharacterIsEscaped(in value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var backslashCount = 0
        var index = value.index(before: value.endIndex)
        while index > value.startIndex {
            let previous = value.index(before: index)
            guard value[previous] == "\\" else { break }
            backslashCount += 1
            index = previous
        }
        return !backslashCount.isMultiple(of: 2)
    }

    private func gitIgnoreRules(
        applyingToChildrenOf directory: String,
        io: SecureWorkspaceIO,
        state: GitIgnoreEvaluationState
    ) throws -> [GitIgnoreRule] {
        var result: [GitIgnoreRule] = []
        for ancestor in ancestorDirectories(including: directory) {
            try loadGitIgnoreRules(directory: ancestor, io: io, state: state)
            result.append(contentsOf: state.rulesByDirectory[ancestor] ?? [])
        }
        return result
    }

    private func basePathIsIgnored(
        _ baseRelativePath: String,
        io: SecureWorkspaceIO,
        state: GitIgnoreEvaluationState,
        budget: inout BoundedWorkspaceGlob.WorkBudget
    ) throws -> Bool {
        let normalizedBase = normalizedDirectory(baseRelativePath)
        guard normalizedBase != "." else { return false }
        var parent = "."
        var current = ""
        for component in normalizedBase.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            let rules = try gitIgnoreRules(
                applyingToChildrenOf: parent,
                io: io,
                state: state
            )
            if try isIgnored(
                workspaceRelativePath: current,
                name: String(component),
                isDirectory: true,
                rules: rules,
                budget: &budget
            ) {
                return true
            }
            parent = current
        }
        return false
    }

    private func isIgnored(
        workspaceRelativePath: String,
        name: String,
        isDirectory: Bool,
        rules: [GitIgnoreRule],
        budget: inout BoundedWorkspaceGlob.WorkBudget
    ) throws -> Bool {
        var ignored = false
        for rule in rules {
            if rule.directoryOnly, !isDirectory { continue }
            guard let scopedPath = path(
                workspaceRelativePath,
                relativeToScope: rule.scopeRelativePath
            ) else { continue }
            let candidate = WorkspaceGlobCandidate(
                relativePath: scopedPath,
                name: name
            )
            let matched: Bool
            if rule.matchesWholePath {
                matched = try rule.glob.matches(candidate.path, budget: &budget)
            } else {
                // A slashless gitignore pattern applies to the basename at
                // every depth. It must not be tested against ancestor
                // components while evaluating a descendant: otherwise a rule
                // such as `!foo` could accidentally unignore `foo/bar.txt`.
                matched = try rule.glob.matches(candidate.name, budget: &budget)
            }
            if matched { ignored = !rule.negated }
        }
        return ignored
    }

    private func normalizedDirectory(_ path: String) -> String {
        let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value.isEmpty || value == "." ? "." : value
    }

    private func parentDirectory(of path: String) -> String {
        let normalized = normalizedDirectory(path)
        guard normalized != ".", let separator = normalized.lastIndex(of: "/") else {
            return "."
        }
        return String(normalized[..<separator])
    }

    private func ancestorDirectories(including directory: String) -> [String] {
        let normalized = normalizedDirectory(directory)
        guard normalized != "." else { return ["."] }
        var ancestors = ["."]
        var current = ""
        for component in normalized.split(separator: "/") {
            current = current.isEmpty ? String(component) : current + "/" + component
            ancestors.append(current)
        }
        return ancestors
    }

    private func path(_ workspacePath: String, relativeToScope scope: String) -> String? {
        let normalizedPath = normalizedDirectory(workspacePath)
        let normalizedScope = normalizedDirectory(scope)
        if normalizedScope == "." { return normalizedPath == "." ? nil : normalizedPath }
        let prefix = normalizedScope + "/"
        guard normalizedPath.hasPrefix(prefix) else { return nil }
        let relative = String(normalizedPath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    private func requireSecureIO() throws -> SecureWorkspaceIO {
        guard let secureIO else {
            throw SecureWorkspaceIOError.cannotOpenWorkspace(validator.secureRootPath)
        }
        return secureIO
    }

    private var maximumFileReadBytes: Int {
        Int(min(maximumFileBytes, Int64(Int.max - 1)))
    }

    private func validateShortFilter(_ filter: String?) throws {
        guard let filter else { return }
        guard filter.utf8.count <= BoundedWorkspaceGlob.maximumPatternBytes else {
            throw WorkspaceSearchError.filtersTooLarge(BoundedWorkspaceGlob.maximumPatternBytes)
        }
    }

    private func join(base: String, relative: String) -> String {
        if base.isEmpty || base == "." { return relative }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + relative
    }

    private func displayPath(_ relative: String, base: String) -> String {
        if base == "." || base.isEmpty { return relative }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + relative
    }

    private func literalColumn(
        pattern: String,
        in line: Substring,
        caseSensitive: Bool
    ) -> Int? {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        guard let range = line.range(of: pattern, options: options) else { return nil }
        return line.distance(from: line.startIndex, to: range.lowerBound) + 1
    }

    /// Iterates line slices without materializing an array of every line in a
    /// multi-megabyte file.
    private func forEachLine(
        in text: String,
        body: (_ lineNumber: Int, _ line: Substring) throws -> Bool
    ) rethrows -> Bool {
        var lineNumber = 1
        var start = text.startIndex
        while true {
            let remainder = text[start...]
            let end = remainder.firstIndex(of: "\n") ?? text.endIndex
            guard try body(lineNumber, text[start..<end]) else { return false }
            guard end != text.endIndex else { return true }
            start = text.index(after: end)
            lineNumber += 1
        }
    }

    private static func matchesUserGlob(
        _ glob: BoundedWorkspaceGlob,
        candidate: WorkspaceGlobCandidate,
        budget: inout BoundedWorkspaceGlob.WorkBudget
    ) throws -> Bool {
        if try glob.matches(candidate.path, budget: &budget) { return true }
        return try glob.matches(candidate.name, budget: &budget)
    }

    private static func escapeRegularExpressionLiteral(_ value: String) -> String {
        let metacharacters = Set("\\.^$|?*+()[]{}")
        return value.reduce(into: "") { result, character in
            if metacharacters.contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
