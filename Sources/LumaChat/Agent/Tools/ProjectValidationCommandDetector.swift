import Foundation

enum ProjectValidationAction: String, Codable, Equatable, Sendable {
    case build
    case test
}

enum ProjectValidationProjectKind: String, Codable, Equatable, Sendable {
    case swiftPackage = "swift-package"
    case nodePackage = "node-package"
    case pythonProject = "python-project"
    case rustPackage = "rust-package"
    case goModule = "go-module"
    case xcodeProject = "xcode-project"
    case xcodeWorkspace = "xcode-workspace"
}

struct ProjectValidationCommand: Codable, Equatable, Sendable {
    var action: ProjectValidationAction
    var projectKind: ProjectValidationProjectKind
    var manifestPath: String
    var command: String
    var workingDirectory: String
}

/// The fixed validation command selected for one tool invocation.
///
/// `test` remains the requested action when a build fallback is selected, so
/// callers can report the fallback without pretending that tests ran.
struct ProjectValidationSelection: Codable, Equatable, Sendable {
    var requestedAction: ProjectValidationAction
    var command: ProjectValidationCommand
    var fallbackReason: String?

    var actualAction: ProjectValidationAction { command.action }
    var usedFallback: Bool { requestedAction != actualAction }
}

enum ProjectValidationCommandDetectorError: LocalizedError, Equatable, Sendable {
    case unsupportedProject(ProjectValidationAction)

    var errorDescription: String? {
        switch self {
        case .unsupportedProject(let action):
            "No supported project \(action.rawValue) command was detected at the workspace root."
        }
    }
}

/// Selects a validation command from bounded, descriptor-safe project metadata.
///
/// The model never supplies a command string. Package-manager script bodies are
/// deliberately not copied into the command either: npm resolves only the fixed
/// `build` or `test` script name from the workspace's own package.json.
struct ProjectValidationCommandDetector: Sendable {
    private struct NodePackageManifest: Decodable {
        var scripts: [String: String]?
    }

    private enum PythonTestFramework {
        case pytest
        case unittest

        var command: String {
            switch self {
            case .pytest: "python3 -m pytest"
            case .unittest: "python3 -m unittest discover"
            }
        }
    }

    private enum PythonTestEvidence {
        case pytest
        case unittest
        case none
    }

    private static let maximumManifestBytes: Int64 = 512 * 1_024
    private static let maximumXcodeEntries = 512
    private static let maximumPythonTestEntries = 512
    private static let maximumPythonTestDepth = 6
    private static let maximumPythonTestFileBytes: Int64 = 128 * 1_024
    private static let maximumPythonTestBytes: Int64 = 1_024 * 1_024
    private static let ignoredPythonDirectories: Set<String> = [
        ".git", ".hg", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".svn", ".tox",
        ".venv", "__pycache__", "build", "dist", "node_modules", "tmp", "venv",
    ]

    private let io: SecureWorkspaceIO

    init(validator: WorkspaceSecurityValidator) throws {
        io = try SecureWorkspaceIO(validator: validator)
    }

    func detect(_ action: ProjectValidationAction) throws -> ProjectValidationCommand {
        if isBoundedRegularFile("Package.swift") {
            return command(
                action,
                kind: .swiftPackage,
                manifest: "Package.swift",
                build: "swift build",
                test: "swift test"
            )
        }

        if nodePackageHasScript(action.rawValue) {
            return command(
                action,
                kind: .nodePackage,
                manifest: "package.json",
                build: "npm run build",
                test: "npm run test"
            )
        }

        if isBoundedRegularFile("pyproject.toml") {
            if action == .build {
                return ProjectValidationCommand(
                    action: action,
                    projectKind: .pythonProject,
                    manifestPath: "pyproject.toml",
                    command: "python3 -m compileall -q -x '(^|/)\\._' .",
                    workingDirectory: "."
                )
            }
            guard let framework = pythonTestFramework() else {
                throw ProjectValidationCommandDetectorError.unsupportedProject(.test)
            }
            return ProjectValidationCommand(
                action: action,
                projectKind: .pythonProject,
                manifestPath: "pyproject.toml",
                command: framework.command,
                workingDirectory: "."
            )
        }

        if isBoundedRegularFile("Cargo.toml") {
            return command(
                action,
                kind: .rustPackage,
                manifest: "Cargo.toml",
                build: "cargo build",
                test: "cargo test"
            )
        }

        if isBoundedRegularFile("go.mod") {
            return command(
                action,
                kind: .goModule,
                manifest: "go.mod",
                build: "go build ./...",
                test: "go test ./..."
            )
        }

        if let xcode = xcodeCommand(action) { return xcode }
        throw ProjectValidationCommandDetectorError.unsupportedProject(action)
    }

    /// Selects the most useful deterministic validation without masking a real
    /// test failure. The fallback happens during detection, before any command
    /// is executed, and only for the detector's exact unsupported-test result.
    func detectForExecution(
        _ requestedAction: ProjectValidationAction
    ) throws -> ProjectValidationSelection {
        do {
            return ProjectValidationSelection(
                requestedAction: requestedAction,
                command: try detect(requestedAction),
                fallbackReason: nil
            )
        } catch let error as ProjectValidationCommandDetectorError {
            guard requestedAction == .test,
                  error == .unsupportedProject(.test) else {
                throw error
            }
            return ProjectValidationSelection(
                requestedAction: requestedAction,
                command: try detect(.build),
                fallbackReason: "No deterministic test command was detected; ran the fixed build command instead."
            )
        }
    }

    private func command(
        _ action: ProjectValidationAction,
        kind: ProjectValidationProjectKind,
        manifest: String,
        build: String,
        test: String
    ) -> ProjectValidationCommand {
        ProjectValidationCommand(
            action: action,
            projectKind: kind,
            manifestPath: manifest,
            command: action == .build ? build : test,
            workingDirectory: "."
        )
    }

    private func isBoundedRegularFile(_ path: String) -> Bool {
        guard let metadata = try? io.metadata(path: path) else { return false }
        return metadata.kind == .regularFile
            && metadata.byteCount >= 0
            && metadata.byteCount <= Self.maximumManifestBytes
    }

    private func nodePackageHasScript(_ script: String) -> Bool {
        guard isBoundedRegularFile("package.json"),
              let read = try? io.readRegularFile(
                path: "package.json",
                maximumBytes: Int(Self.maximumManifestBytes)
              ),
              !read.truncated,
              Int64(read.data.count) == read.metadata.byteCount,
              let manifest = try? JSONDecoder().decode(NodePackageManifest.self, from: read.data),
              let value = manifest.scripts?[script] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Chooses a Python test runner only from bounded, workspace-local evidence.
    ///
    /// `python3 -m pytest` is a fixed invocation: detection never installs a
    /// dependency or evaluates manifest-provided command text. If pytest is not
    /// available in the selected Python environment, execution fails normally
    /// and is never converted into a successful build fallback.
    private func pythonTestFramework() -> PythonTestFramework? {
        if pythonManifestExplicitlyUsesPytest() { return .pytest }

        guard let listing = try? io.enumerate(
            path: ".",
            maximumDepth: Self.maximumPythonTestDepth,
            maximumEntries: Self.maximumPythonTestEntries,
            includeHidden: false,
            ignoredDirectoryNames: Self.ignoredPythonDirectories,
            regularFilesOnly: true
        ) else { return nil }

        var foundPytest = false
        var foundUnittest = false
        var inspectionWasIncomplete = listing.truncated
        var inspectedBytes: Int64 = 0

        for entry in listing.entries
            .filter({ isPythonTestCandidate($0.name) })
            .sorted(by: {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }) {
            guard entry.metadata.byteCount >= 0,
                  entry.metadata.byteCount <= Self.maximumPythonTestFileBytes,
                  inspectedBytes + entry.metadata.byteCount <= Self.maximumPythonTestBytes else {
                inspectionWasIncomplete = true
                continue
            }
            inspectedBytes += entry.metadata.byteCount
            guard let read = try? io.readRegularFile(
                path: entry.relativePath,
                maximumBytes: Int(Self.maximumPythonTestFileBytes)
            ),
            !read.truncated,
            Int64(read.data.count) == entry.metadata.byteCount,
            let source = String(data: read.data, encoding: .utf8) else {
                inspectionWasIncomplete = true
                continue
            }

            switch pythonTestEvidence(source: source, relativePath: entry.relativePath) {
            case .pytest:
                foundPytest = true
            case .unittest:
                foundUnittest = true
            case .none:
                break
            }
        }

        // An incomplete scan could make the selected framework depend on
        // filesystem enumeration order. Manifest evidence was handled above;
        // layout evidence is accepted only after a complete bounded traversal.
        guard !inspectionWasIncomplete else { return nil }
        if foundPytest { return .pytest }

        // `unittest discover` may exit zero after finding no tests. Require at
        // least one discoverable TestCase method before selecting it.
        if foundUnittest { return .unittest }
        return nil
    }

    private func pythonManifestExplicitlyUsesPytest() -> Bool {
        guard let read = try? io.readRegularFile(
            path: "pyproject.toml",
            maximumBytes: Int(Self.maximumManifestBytes)
        ),
        !read.truncated,
        Int64(read.data.count) == read.metadata.byteCount,
        let manifest = String(data: read.data, encoding: .utf8) else { return false }

        var table = ""
        var dependencyArrayDepth = 0
        for rawLine in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripTOMLComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if dependencyArrayDepth > 0 {
                if containsPytestRequirement(in: line) { return true }
                dependencyArrayDepth += arrayBracketBalance(in: line)
                dependencyArrayDepth = max(0, dependencyArrayDepth)
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\t", with: "")
                    .lowercased()
                if table == "tool.pytest" || table.hasPrefix("tool.pytest.") {
                    return true
                }
                continue
            }

            guard let assignment = tomlAssignment(in: line) else { continue }
            let key = assignment.key
                .trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(
                        CharacterSet(charactersIn: "'\"")
                    )
                )
                .lowercased()
            let dependencyContext = isDependencyTable(table)
                || key == "dependencies"
                || key.hasSuffix("-dependencies")
            guard dependencyContext else { continue }

            // Poetry and similar dependency tables use the package name as the
            // assignment key rather than placing it in an array value.
            if key == "pytest" { return true }
            if containsPytestRequirement(in: assignment.value) { return true }
            dependencyArrayDepth = max(0, arrayBracketBalance(in: assignment.value))
        }
        return false
    }

    private func isDependencyTable(_ table: String) -> Bool {
        table.split(separator: ".").contains { component in
            component == "dependencies"
                || component == "optional-dependencies"
                || component == "dependency-groups"
                || component == "dev-dependencies"
        }
    }

    private func tomlAssignment(in line: String) -> (key: String, value: String)? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if character == activeQuote, !escaped { quote = nil }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return (
                    String(line[..<index]),
                    String(line[line.index(after: index)...])
                )
            }
        }
        return nil
    }

    private func stripTOMLComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if character == activeQuote, !escaped { quote = nil }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private func containsPytestRequirement(in value: String) -> Bool {
        quotedTOMLValues(in: value).contains { rawRequirement in
            let requirement = rawRequirement
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard requirement.hasPrefix("pytest") else { return false }
            guard requirement.count > "pytest".count else { return true }
            let boundary = requirement[requirement.index(
                requirement.startIndex,
                offsetBy: "pytest".count
            )]
            return "[<>=!~; @".contains(boundary)
        }
    }

    private func quotedTOMLValues(in value: String) -> [String] {
        var values: [String] = []
        var quote: Character?
        var escaped = false
        var current = ""
        for character in value {
            if let activeQuote = quote {
                if character == activeQuote, !escaped {
                    values.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
            } else if character == "\"" || character == "'" {
                quote = character
                escaped = false
            }
        }
        return values
    }

    private func arrayBracketBalance(in value: String) -> Int {
        var balance = 0
        var quote: Character?
        var escaped = false
        for character in value {
            if let activeQuote = quote {
                if character == activeQuote, !escaped { quote = nil }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                balance += 1
            } else if character == "]" {
                balance -= 1
            }
        }
        return balance
    }

    private func isPythonTestCandidate(_ name: String) -> Bool {
        name.hasSuffix(".py") && (name.hasPrefix("test") || name.hasSuffix("_test.py"))
    }

    private func pythonTestEvidence(
        source: String,
        relativePath: String
    ) -> PythonTestEvidence {
        let code = stripPythonCommentsAndStrings(source)
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasTestDeclaration = lines.contains { pythonFunctionName(in: $0)?.hasPrefix("test") == true }
        guard hasTestDeclaration else { return .none }
        let fileName = relativePath.split(separator: "/").last.map(String.init) ?? ""
        let isDefaultPytestFile = fileName.hasPrefix("test_") || fileName.hasSuffix("_test.py")

        let explicitPytest = lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == "import pytest"
                || line.hasPrefix("import pytest as ")
                || line.hasPrefix("from pytest import ")
                || line.hasPrefix("@pytest.")
                || line.hasPrefix("pytest.")
        }
        if explicitPytest, isDefaultPytestFile { return .pytest }

        if isDiscoverableUnittest(relativePath: relativePath),
           containsUnittestTestCase(lines) {
            return .unittest
        }

        let topLevelTest = lines.contains { line in
            guard line.first != " ", line.first != "\t" else { return false }
            return pythonFunctionName(in: line)?.hasPrefix("test") == true
        }
        if topLevelTest, isDefaultPytestFile { return .pytest }

        if isDefaultPytestFile, containsPytestStyleClass(lines) { return .pytest }
        return .none
    }

    private func pythonFunctionName(in rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("async ") { line.removeFirst("async ".count) }
        guard line.hasPrefix("def "), let parenthesis = line.firstIndex(of: "(") else {
            return nil
        }
        let nameStart = line.index(line.startIndex, offsetBy: "def ".count)
        return String(line[nameStart..<parenthesis])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsUnittestTestCase(_ lines: [String]) -> Bool {
        let importsUnittest = lines.contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == "import unittest"
                || line.hasPrefix("import unittest as ")
                || line.hasPrefix("from unittest import ")
        }
        guard importsUnittest else { return false }

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("class "),
                  (line.contains("unittest.TestCase") || line.contains("(TestCase)")) else {
                continue
            }
            let classIndent = indentation(of: rawLine)
            for bodyLine in lines.dropFirst(index + 1) {
                let trimmed = bodyLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let bodyIndent = indentation(of: bodyLine)
                if bodyIndent <= classIndent { break }
                if pythonFunctionName(in: bodyLine)?.hasPrefix("test") == true {
                    return true
                }
            }
        }
        return false
    }

    private func containsPytestStyleClass(_ lines: [String]) -> Bool {
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("class Test") else { continue }
            let classIndent = indentation(of: rawLine)
            for bodyLine in lines.dropFirst(index + 1) {
                let trimmed = bodyLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let bodyIndent = indentation(of: bodyLine)
                if bodyIndent <= classIndent { break }
                if pythonFunctionName(in: bodyLine)?.hasPrefix("test") == true {
                    return true
                }
            }
        }
        return false
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func isDiscoverableUnittest(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last,
              fileName.hasPrefix("test"),
              fileName.hasSuffix(".py") else { return false }
        guard components.count > 1 else { return true }

        var directory = ""
        for component in components.dropLast() {
            directory = directory.isEmpty ? component : "\(directory)/\(component)"
            guard isBoundedRegularFile("\(directory)/__init__.py") else { return false }
        }
        return true
    }

    /// Removes Python comments and string contents while preserving code and
    /// newlines. This prevents examples in comments/docstrings from being
    /// mistaken for executable TestCase declarations.
    private func stripPythonCommentsAndStrings(_ source: String) -> String {
        let characters = Array(source)
        var output = ""
        output.reserveCapacity(characters.count)
        var index = 0
        var quote: Character?
        var tripleQuoted = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if tripleQuoted,
                   character == activeQuote,
                   index + 2 < characters.count,
                   characters[index + 1] == activeQuote,
                   characters[index + 2] == activeQuote {
                    output.append(contentsOf: "   ")
                    index += 3
                    quote = nil
                    tripleQuoted = false
                    escaped = false
                    continue
                }
                if !tripleQuoted, character == activeQuote, !escaped {
                    output.append(" ")
                    index += 1
                    quote = nil
                    escaped = false
                    continue
                }
                if character == "\n" {
                    output.append("\n")
                    if !tripleQuoted {
                        quote = nil
                        escaped = false
                    }
                } else {
                    output.append(" ")
                    escaped = character == "\\" && !escaped
                    if character != "\\" { escaped = false }
                }
                index += 1
                continue
            }

            if character == "#" {
                while index < characters.count, characters[index] != "\n" {
                    output.append(" ")
                    index += 1
                }
                continue
            }
            if character == "\"" || character == "'" {
                let isTriple = index + 2 < characters.count
                    && characters[index + 1] == character
                    && characters[index + 2] == character
                quote = character
                tripleQuoted = isTriple
                escaped = false
                output.append(contentsOf: isTriple ? "   " : " ")
                index += isTriple ? 3 : 1
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private func xcodeCommand(
        _ action: ProjectValidationAction
    ) -> ProjectValidationCommand? {
        guard let listing = try? io.enumerate(
            path: ".",
            maximumDepth: 1,
            maximumEntries: Self.maximumXcodeEntries,
            includeHidden: false,
            regularFilesOnly: false
        ), !listing.truncated else { return nil }

        let containers = listing.entries.filter { entry in
            entry.depth == 1
                && entry.metadata.kind == .directory
                && (entry.name.hasSuffix(".xcworkspace") || entry.name.hasSuffix(".xcodeproj"))
        }.sorted { lhs, rhs in
            let lhsWorkspace = lhs.name.hasSuffix(".xcworkspace")
            let rhsWorkspace = rhs.name.hasSuffix(".xcworkspace")
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        for container in containers {
            let kind: ProjectValidationProjectKind = container.name.hasSuffix(".xcworkspace")
                ? .xcodeWorkspace
                : .xcodeProject
            let option = kind == .xcodeWorkspace ? "-workspace" : "-project"
            let base = "xcodebuild \(option) \(shellQuote(container.relativePath))"
            let scheme = sharedScheme(in: container.relativePath)
            if action == .test, scheme == nil {
                // `xcodebuild test` is not deterministic without a shared scheme.
                continue
            }
            let schemeArgument = scheme.map { " -scheme \(shellQuote($0))" } ?? ""
            let invocation = "\(base)\(schemeArgument) -configuration Debug \(action.rawValue)"
            return ProjectValidationCommand(
                action: action,
                projectKind: kind,
                manifestPath: container.relativePath,
                command: invocation,
                workingDirectory: "."
            )
        }
        return nil
    }

    private func sharedScheme(in container: String) -> String? {
        let directory = "\(container)/xcshareddata/xcschemes"
        guard let listing = try? io.enumerate(
            path: directory,
            maximumDepth: 1,
            maximumEntries: 128,
            includeHidden: false,
            regularFilesOnly: true
        ), !listing.truncated else { return nil }
        return listing.entries
            .filter { $0.depth == 1 && $0.name.hasSuffix(".xcscheme") }
            .map { String($0.name.dropLast(".xcscheme".count)) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
