import Darwin
import Foundation
import XCTest
@testable import LumaChat

final class WorkspaceSearchSecurityTests: XCTestCase {
    func testWorkspaceExecutableNamedRipgrepIsNeverLaunched() throws {
        let root = try makeWorkspaceRoot("search-no-path-rg")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("executed.txt")
        let fakeRipgrep = root.appendingPathComponent("rg")
        try Data("#!/bin/sh\nprintf executed > executed.txt\n".utf8).write(to: fakeRipgrep)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeRipgrep.path
        )
        try Data("needle\n".utf8).write(to: root.appendingPathComponent("visible.txt"))

        let search = try makeSearch(root: root)
        let result = try search.grep(pattern: "needle", isRegularExpression: false)

        XCTAssertEqual(result.engine, "descriptor")
        XCTAssertEqual(result.matches.map(\.path), ["visible.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSpecialGitIgnoreFilesAreNeverOpenedOrFollowed() throws {
        let root = try makeWorkspaceRoot("search-special-gitignore")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("visible\n".utf8).write(to: root.appendingPathComponent("visible.txt"))

        let gitIgnore = root.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(
            atPath: gitIgnore.path,
            withDestinationPath: "/dev/null"
        )
        var result = try makeSearch(root: root).searchFiles(filename: "visible")
        XCTAssertEqual(result.matches.map(\.path), ["visible.txt"])

        try FileManager.default.removeItem(at: gitIgnore)
        if Darwin.mkfifo(gitIgnore.path, 0o600) == 0 {
            result = try makeSearch(root: root).searchFiles(filename: "visible")
            XCTAssertEqual(result.matches.map(\.path), ["visible.txt"])
        } else {
            // The project volume may be ExFAT, which cannot represent FIFOs.
            XCTAssertTrue(errno == ENOTSUP || errno == EOPNOTSUPP || errno == EPERM)
        }
    }

    func testNestedGitIgnoreRulesAreScopedAndNegationIsApplied() throws {
        let root = try makeWorkspaceRoot("search-nested-gitignore")
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("vendor", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("*.secret\n!visible.secret\n".utf8).write(
            to: root.appendingPathComponent(".gitignore")
        )
        try Data("*.txt\n!keep.txt\n".utf8).write(
            to: vendor.appendingPathComponent(".gitignore")
        )
        try Data("needle hidden\n".utf8).write(
            to: root.appendingPathComponent("hidden.secret")
        )
        try Data("needle visible\n".utf8).write(
            to: root.appendingPathComponent("visible.secret")
        )
        try Data("needle drop\n".utf8).write(to: vendor.appendingPathComponent("drop.txt"))
        try Data("needle keep\n".utf8).write(to: vendor.appendingPathComponent("keep.txt"))
        try Data("needle sibling\n".utf8).write(to: sibling.appendingPathComponent("visible.txt"))

        let search = try makeSearch(root: root)
        let files = try search.searchFiles()
        let paths = Set(files.matches.map(\.path))
        XCTAssertFalse(paths.contains("hidden.secret"))
        XCTAssertTrue(paths.contains("visible.secret"))
        XCTAssertFalse(paths.contains("vendor/drop.txt"))
        XCTAssertTrue(paths.contains("vendor/keep.txt"))
        XCTAssertTrue(paths.contains("sibling/visible.txt"))

        let text = try search.grep(pattern: "needle", isRegularExpression: false)
        XCTAssertEqual(
            Set(text.matches.map(\.path)),
            Set(["visible.secret", "vendor/keep.txt", "sibling/visible.txt"])
        )
    }

    func testSubdirectorySearchInheritsParentRulesAndHonorsItsOwnRules() throws {
        let root = try makeWorkspaceRoot("search-inherited-gitignore")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        let ignored = root.appendingPathComponent("Ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("Sources/*.log\n!Sources/keep.log\nIgnored/\n".utf8).write(
            to: root.appendingPathComponent(".gitignore")
        )
        try Data("*.tmp\n!visible.tmp\n".utf8).write(
            to: source.appendingPathComponent(".gitignore")
        )
        for name in ["drop.log", "keep.log", "hidden.tmp", "visible.tmp", "code.swift"] {
            try Data("needle \(name)\n".utf8).write(to: source.appendingPathComponent(name))
        }
        try Data("needle ignored\n".utf8).write(to: ignored.appendingPathComponent("secret.txt"))

        let search = try makeSearch(root: root)
        let files = try search.searchFiles(path: "Sources")
        XCTAssertEqual(
            Set(files.matches.map(\.path)),
            Set(["Sources/keep.log", "Sources/visible.tmp", "Sources/code.swift"])
        )
        let text = try search.grep(
            path: "Sources",
            pattern: "needle",
            isRegularExpression: false
        )
        XCTAssertEqual(
            Set(text.matches.map(\.path)),
            Set(["Sources/keep.log", "Sources/visible.tmp", "Sources/code.swift"])
        )
        XCTAssertTrue(try search.searchFiles(path: "Ignored").matches.isEmpty)
    }

    func testGitIgnoreBasenameNegationCannotUnignoreDescendantByParentName() throws {
        let root = try makeWorkspaceRoot("search-gitignore-basename-negation")
        defer { try? FileManager.default.removeItem(at: root) }
        let foo = root.appendingPathComponent("foo", isDirectory: true)
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        try Data("*.txt\n!foo\n".utf8).write(
            to: root.appendingPathComponent(".gitignore")
        )
        try Data("hidden\n".utf8).write(to: foo.appendingPathComponent("bar.txt"))
        try Data("visible\n".utf8).write(to: foo.appendingPathComponent("bar.swift"))

        let files = try makeSearch(root: root).searchFiles()
        XCTAssertEqual(Set(files.matches.map(\.path)), Set(["foo/bar.swift"]))
    }

    func testGitIgnoreEscapesLeadingMarkersWildcardsAndTrailingSpaces() throws {
        let root = try makeWorkspaceRoot("search-gitignore-escapes")
        defer { try? FileManager.default.removeItem(at: root) }
        let ignore = "\\#secret\n"
            + "\\!important\n"
            + "with\\ space\n"
            + "trailing\\ \n"
            + "trimmed   \n"
            + "literal\\*name\n"
        try Data(ignore.utf8).write(to: root.appendingPathComponent(".gitignore"))
        for name in [
            "#secret", "!important", "with space", "trailing ", "trimmed",
            "literal*name", "literalXname", "visible.txt"
        ] {
            try Data("value\n".utf8).write(to: root.appendingPathComponent(name))
        }

        let files = try makeSearch(root: root).searchFiles()
        XCTAssertEqual(
            Set(files.matches.map(\.path)),
            Set(["literalXname", "visible.txt"])
        )
    }

    func testGitIgnoreCharacterClassesAndGlobstarMatchGitSemantics() throws {
        let root = try makeWorkspaceRoot("search-gitignore-classes-globstar")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(
            "logs/**/debug[0-3].txt\n**/foo\na/**/b[!0-9].swift\nrange-[a-c].log\n".utf8
        ).write(to: root.appendingPathComponent(".gitignore"))

        let directories = ["logs", "logs/x/y", "nested", "a", "a/x/y"]
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let names = [
            "logs/debug1.txt",       // `**/` matches zero components.
            "logs/x/y/debug3.txt",   // and arbitrarily many components.
            "foo",                   // leading `**/` also matches at root.
            "nested/foo",
            "a/bx.swift",            // middle `/**/` matches zero components.
            "a/x/y/bz.swift",
            "range-b.log",
            "logs/debug8.txt",
            "a/b7.swift",
            "range-z.log",
            "visible.swift"
        ]
        for name in names {
            try Data("value\n".utf8).write(to: root.appendingPathComponent(name))
        }

        let files = try makeSearch(root: root).searchFiles()
        XCTAssertEqual(
            Set(files.matches.map(\.path)),
            Set([
                "logs/debug8.txt", "a/b7.swift", "range-z.log", "visible.swift"
            ])
        )
    }

    func testTraversalEntryTimeAndByteLimitsReturnPartialResultsWithoutMaterializingTree() throws {
        let root = try makeWorkspaceRoot("search-stream-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            try Data("value \(index)\n".utf8).write(
                to: root.appendingPathComponent("file-\(index).txt")
            )
        }

        let entryLimited = try makeSearch(
            root: root,
            limits: WorkspaceSearchLimits(maximumEntries: 1)
        ).searchFiles()
        XCTAssertTrue(entryLimited.truncated)
        XCTAssertLessThanOrEqual(entryLimited.matches.count, 1)

        let byteLimited = try makeSearch(
            root: root,
            limits: WorkspaceSearchLimits(maximumTraversalBytes: 1)
        ).searchFiles()
        XCTAssertTrue(byteLimited.truncated)
        XCTAssertTrue(byteLimited.matches.isEmpty)

        let timeLimited = try makeSearch(
            root: root,
            limits: WorkspaceSearchLimits(maximumDuration: 0)
        ).searchFiles()
        XCTAssertTrue(timeLimited.truncated)
    }

    func testTraversalSkipsSymlinksFIFOsAndTheirTargets() throws {
        let root = try makeWorkspaceRoot("search-special-entries")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("inside\n".utf8).write(to: root.appendingPathComponent("regular.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("passwd-link").path,
            withDestinationPath: "/etc/passwd"
        )
        let fifoResult = Darwin.mkfifo(
            root.appendingPathComponent("named-pipe").path,
            0o600
        )
        if fifoResult != 0 {
            XCTAssertTrue(errno == ENOTSUP || errno == EOPNOTSUPP || errno == EPERM)
        }

        let result = try makeSearch(root: root).searchFiles()
        XCTAssertEqual(result.matches.map(\.path), ["regular.txt"])
    }

    func testUnsafeRegexConstructsAndOversizedPatternsAreRejectedBeforeTraversal() throws {
        let root = try makeWorkspaceRoot("search-regex-validation")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("secret\n".utf8).write(to: root.appendingPathComponent("value.txt"))
        let search = try makeSearch(root: root)

        XCTAssertThrowsError(try search.grep(pattern: "(?=secret)")) { error in
            XCTAssertEqual(
                error as? BoundedWorkspaceRegex.CompileError,
                .unsupported("lookaround or inline option")
            )
        }
        XCTAssertThrowsError(try search.grep(pattern: #"(secret)\1"#)) { error in
            XCTAssertEqual(
                error as? BoundedWorkspaceRegex.CompileError,
                .unsupported("backreference")
            )
        }
        XCTAssertThrowsError(
            try search.grep(
                pattern: String(repeating: "a", count: BoundedWorkspaceRegex.maximumPatternBytes + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? BoundedWorkspaceRegex.CompileError,
                .patternTooLong(BoundedWorkspaceRegex.maximumPatternBytes)
            )
        }
    }

    func testPathologicalRegexIsWorkBoundedWhileLiteralSearchRemainsAvailable() throws {
        let root = try makeWorkspaceRoot("search-regex-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data((String(repeating: "a", count: 8_192) + "!\n").utf8).write(
            to: root.appendingPathComponent("value.txt")
        )
        let limits = WorkspaceSearchLimits(
            maximumRegexOperationsPerFile: 64,
            maximumRegexOperationsTotal: 128,
            maximumRegexDurationPerFile: 1,
            maximumRegexDurationTotal: 1
        )
        let search = try makeSearch(root: root, limits: limits)

        let bounded = try search.grep(pattern: "(a+)+$")
        XCTAssertTrue(bounded.truncated)
        XCTAssertTrue(bounded.matches.isEmpty)

        let literal = try search.grep(pattern: "!", isRegularExpression: false)
        XCTAssertEqual(literal.matches.count, 1)
        XCTAssertEqual(literal.matches.first?.column, 8_193)
    }

    func testGitIgnoreAndFilterWorkAreCapped() throws {
        let root = try makeWorkspaceRoot("search-ignore-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("visible\n".utf8).write(to: root.appendingPathComponent("visible.txt"))
        let rules = (0...WorkspaceSearchServiceTestConstants.maximumGitIgnoreRules)
            .map { "ignored-\($0).txt" }
            .joined(separator: "\n")
        try Data(rules.utf8).write(to: root.appendingPathComponent(".gitignore"))

        let search = try makeSearch(root: root)
        let result = try search.searchFiles(filename: "visible")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.matches.map(\.path), ["visible.txt"])

        XCTAssertThrowsError(
            try search.grep(
                pattern: "visible",
                isRegularExpression: false,
                include: Array(repeating: "*.txt", count: 129)
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceSearchError, .tooManyFilters(128))
        }
    }

    func testCancelledSearchFailsBeforeTraversal() async throws {
        let root = try makeWorkspaceRoot("search-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("value\n".utf8).write(to: root.appendingPathComponent("value.txt"))
        let search = try makeSearch(root: root)

        let task = Task { () throws -> SearchResult<FileSearchMatch> in
            while !Task.isCancelled { await Task.yield() }
            return try search.searchFiles()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeSearch(
        root: URL,
        limits: WorkspaceSearchLimits = WorkspaceSearchLimits()
    ) throws -> WorkspaceSearchService {
        let validator = try WorkspaceSecurityValidator(workspace: AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        ))
        return WorkspaceSearchService(validator: validator, limits: limits)
    }

    private func makeWorkspaceRoot(_ label: String) throws -> URL {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("agent-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Mirrors the intentionally private production cap without exposing it as API.
private enum WorkspaceSearchServiceTestConstants {
    static let maximumGitIgnoreRules = 512
}
