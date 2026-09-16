import Foundation
import XCTest
@testable import LumaChat

final class ReviewCoreTests: XCTestCase {
    func testParserPreservesFileKindsLineNumbersFallbacksAndSyntax() throws {
        let document = try ReviewDiffParser().parse(Self.comprehensiveDiff, source: .unstaged)

        XCTAssertEqual(document.files.count, 5)
        let modified = try XCTUnwrap(document.files.first { $0.displayPath == "Sources/Value.swift" })
        XCTAssertEqual(modified.change, .modified)
        XCTAssertEqual(modified.language, .swift)
        XCTAssertEqual(modified.additionCount, 1)
        XCTAssertEqual(modified.deletionCount, 1)
        let changedLines = try XCTUnwrap(modified.hunks.first).lines
        XCTAssertEqual(changedLines.map(\.oldLineNumber), [1, 2, nil, 3])
        XCTAssertEqual(changedLines.map(\.newLineNumber), [1, nil, 2, 3])
        let added = try XCTUnwrap(changedLines.first { $0.kind == .addition })
        XCTAssertTrue(added.syntax.contains { $0.role == .keyword })
        XCTAssertTrue(added.syntax.contains { $0.role == .string })
        XCTAssertTrue(added.syntax.contains { $0.role == .comment })

        let renamed = try XCTUnwrap(document.files.first { $0.change == .renamed })
        XCTAssertEqual(renamed.oldPath, "old name.txt")
        XCTAssertEqual(renamed.newPath, "new name.txt")
        XCTAssertTrue(renamed.hunks.isEmpty)

        let binary = try XCTUnwrap(document.files.first { $0.displayPath == "Assets/icon.bin" })
        XCTAssertEqual(binary.fallback, .binary)
        XCTAssertEqual(binary.change, .modified)

        let created = try XCTUnwrap(document.files.first { $0.displayPath == "New.swift" })
        XCTAssertEqual(created.change, .added)
        XCTAssertNil(created.oldPath)

        let deleted = try XCTUnwrap(document.files.first { $0.displayPath == "Old.txt" })
        XCTAssertEqual(deleted.change, .deleted)
        XCTAssertNil(deleted.newPath)
    }

    func testParserFailsClosedForTraversalAndFallsBackForLargeFile() throws {
        let unsafe = """
        diff --git a/safe.txt b/../../escape.txt
        --- a/safe.txt
        +++ b/../../escape.txt
        @@ -1,1 +1,1 @@
        -safe
        +escape
        """
        XCTAssertThrowsError(try ReviewDiffParser().parse(unsafe, source: .unstaged)) { error in
            XCTAssertEqual(error as? ReviewDiffParserError, .unsafePath("../../escape.txt"))
        }

        let large = """
        diff --git a/Large.txt b/Large.txt
        --- a/Large.txt
        +++ b/Large.txt
        @@ -1,1 +1,1 @@
        -small
        +\(String(repeating: "x", count: 512))
        """
        var limits = ReviewDiffParser.Limits()
        limits.maximumDocumentBytes = 4_096
        limits.maximumFileBytes = 128
        let document = try ReviewDiffParser(limits: limits).parse(large, source: .staged)
        let file = try XCTUnwrap(document.files.first)
        guard case .large(let byteCount, let limit) = file.fallback else {
            return XCTFail("Expected a large-file fallback")
        }
        XCTAssertGreaterThan(byteCount, limit)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func testHeaderLikeHunkLinesDoNotSplitHeaderlessUnifiedDiff() throws {
        let raw = """
        --- a/script.sh
        +++ b/script.sh
        @@ -1,1 +1,1 @@
        --- old option
        +++ new option
        """
        let document = try ReviewDiffParser().parse(raw, source: .lastAgentTurn(taskID: UUID()))
        XCTAssertEqual(document.files.count, 1)
        let file = try XCTUnwrap(document.files.first)
        XCTAssertEqual(file.hunks.first?.lines.map(\.text), ["-- old option", "++ new option"])
        XCTAssertNil(file.fallback)
    }

    func testPresentationBuildsUnifiedAndAlignedSideBySideRows() throws {
        let document = try ReviewDiffParser().parse(Self.comprehensiveDiff, source: .unstaged)
        let file = try XCTUnwrap(document.files.first { $0.displayPath == "Sources/Value.swift" })
        let builder = ReviewPresentationBuilder()

        let fileOnly = builder.make(file: file, style: .file)
        XCTAssertEqual(fileOnly.summary.additions, 1)
        XCTAssertEqual(fileOnly.summary.deletions, 1)
        XCTAssertTrue(fileOnly.unifiedRows.isEmpty)

        let unified = builder.make(file: file, style: .unified)
        XCTAssertEqual(unified.unifiedRows.first?.kind, .hunkHeader)
        XCTAssertEqual(unified.unifiedRows.count, 5)
        XCTAssertEqual(unified.unifiedRows[2].oldLineNumber, 2)
        XCTAssertEqual(unified.unifiedRows[3].newLineNumber, 2)

        let split = builder.make(file: file, style: .sideBySide)
        XCTAssertEqual(split.sideBySideRows.count, 3)
        XCTAssertEqual(split.sideBySideRows[1].left?.lineNumber, 2)
        XCTAssertEqual(split.sideBySideRows[1].left?.kind, .removal)
        XCTAssertEqual(split.sideBySideRows[1].right?.lineNumber, 2)
        XCTAssertEqual(split.sideBySideRows[1].right?.kind, .addition)
    }

    func testStableFingerprintsAndForwardReverseHunkPatchesFailClosedWhenStale() throws {
        let first = try ReviewDiffParser().parse(Self.comprehensiveDiff, source: .unstaged)
        let second = try ReviewDiffParser().parse(Self.comprehensiveDiff, source: .unstaged)
        let file = try XCTUnwrap(first.files.first { $0.displayPath == "Sources/Value.swift" })
        let reparsed = try XCTUnwrap(second.files.first { $0.displayPath == "Sources/Value.swift" })
        XCTAssertEqual(file.id, reparsed.id)
        XCTAssertEqual(file.fingerprint, reparsed.fingerprint)
        XCTAssertEqual(file.hunks.map(\.id), reparsed.hunks.map(\.id))
        XCTAssertEqual(file.hunks.map(\.fingerprint), reparsed.hunks.map(\.fingerprint))

        let hunk = try XCTUnwrap(file.hunks.first)
        let builder = ReviewPatchBuilder()
        let forward = try builder.make(
            file: file,
            expectedFileFingerprint: file.fingerprint,
            hunkID: hunk.id,
            expectedHunkFingerprint: hunk.fingerprint,
            direction: .forward
        )
        XCTAssertEqual(forward.selection.fileID, file.id)
        XCTAssertEqual(forward.selection.hunkID, hunk.id)
        XCTAssertTrue(forward.unifiedDiff.contains("--- a/Sources/Value.swift"))
        XCTAssertTrue(forward.unifiedDiff.contains("-let value = \"old\""))
        XCTAssertTrue(forward.unifiedDiff.contains("+let value = \"new\""))

        let checkRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lumachat-review-patch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkRoot) }
        try FileManager.default.createDirectory(
            at: checkRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let checkedFile = checkRoot.appendingPathComponent("Sources/Value.swift")
        try Data("import Foundation\nlet value = \"old\" // old\nreturn value\n".utf8)
            .write(to: checkedFile)
        XCTAssertEqual(try gitApplyCheck(forward.unifiedDiff, in: checkRoot), 0)

        let reverse = try builder.make(
            file: file,
            expectedFileFingerprint: file.fingerprint,
            hunkID: hunk.id,
            expectedHunkFingerprint: hunk.fingerprint,
            direction: .reverse
        )
        XCTAssertTrue(reverse.unifiedDiff.contains("-let value = \"new\""))
        XCTAssertTrue(reverse.unifiedDiff.contains("+let value = \"old\""))
        try Data("import Foundation\nlet value = \"new\" // new\nreturn value\n".utf8)
            .write(to: checkedFile)
        XCTAssertEqual(try gitApplyCheck(reverse.unifiedDiff, in: checkRoot), 0)

        XCTAssertThrowsError(try builder.make(
            file: file,
            expectedFileFingerprint: "stale",
            direction: .forward
        )) { error in
            XCTAssertEqual(error as? ReviewPatchError, .staleFile)
        }
        XCTAssertThrowsError(try builder.make(
            file: file,
            expectedFileFingerprint: file.fingerprint,
            hunkID: hunk.id,
            expectedHunkFingerprint: "stale",
            direction: .forward
        )) { error in
            XCTAssertEqual(error as? ReviewPatchError, .staleHunk)
        }

        let binary = try XCTUnwrap(first.files.first { $0.fallback == .binary })
        XCTAssertThrowsError(try builder.make(
            file: binary,
            expectedFileFingerprint: binary.fingerprint,
            direction: .forward
        )) { error in
            XCTAssertEqual(error as? ReviewPatchError, .unavailable(.binary))
        }
    }

    func testSyntaxSpansDoNotTokenizeCommentOrStringContentsAgain() {
        let highlighter = ReviewSyntaxHighlighter()
        let line = #"let count = 42; let url = "https://host/7" // comment 9"#
        let spans = highlighter.spans(in: line, language: .swift)
        XCTAssertEqual(spans.filter { $0.role == .keyword }.count, 2)
        XCTAssertEqual(spans.filter { $0.role == .number }.count, 1)
        XCTAssertEqual(spans.filter { $0.role == .string }.count, 1)
        XCTAssertEqual(spans.filter { $0.role == .comment }.count, 1)
        for (leftIndex, left) in spans.enumerated() {
            for right in spans.dropFirst(leftIndex + 1) {
                XCTAssertLessThanOrEqual(left.location + left.length, right.location)
            }
        }
    }

    func testServiceLoadsEverySourceAndProducesValidatedStructuredContext() async throws {
        let loader = RecordingReviewSourceLoader(rawDiff: Self.comprehensiveDiff)
        let ids = ReviewTestIDGenerator()
        let fixedID = ids.firstID
        let fixedDate = Date(timeIntervalSince1970: 1_234)
        let service = ReviewService(
            loader: loader,
            idGenerator: { ids.next() },
            clock: { fixedDate }
        )
        let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let sources: [ReviewSource] = [
            .unstaged,
            .staged,
            .commit(revision: "HEAD~1"),
            .branch(baseRevision: "main", headRevision: "HEAD"),
            .lastAgentTurn(taskID: taskID)
        ]
        for source in sources {
            _ = try await service.load(source)
        }
        let recordedSources = await loader.recordedSources()
        XCTAssertEqual(recordedSources, sources)

        let loadedDocument = await service.document(for: .unstaged)
        let document = try XCTUnwrap(loadedDocument)
        let file = try XCTUnwrap(document.files.first { $0.displayPath == "Sources/Value.swift" })
        let hunk = try XCTUnwrap(file.hunks.first)
        _ = try await service.addComment(
            source: .unstaged,
            target: .file(path: file.displayPath),
            body: "  Keep the API stable.  "
        )
        _ = try await service.addComment(
            source: .unstaged,
            target: .line(path: file.displayPath, side: .new, line: 2),
            body: "Do not change this value."
        )
        _ = try await service.addComment(
            source: .unstaged,
            target: .range(path: file.displayPath, side: .new, startLine: 1, endLine: 3),
            body: "Review this block."
        )
        _ = try await service.addComment(
            source: .unstaged,
            target: .hunk(path: file.displayPath, hunkID: hunk.id),
            body: "Keep this hunk focused."
        )

        do {
            _ = try await service.addComment(
                source: .unstaged,
                target: .line(path: file.displayPath, side: .new, line: 999),
                body: "Invalid"
            )
            XCTFail("Expected invalid line target to be rejected")
        } catch let error as ReviewServiceError {
            guard case .invalidTarget = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let context = try await service.agentContext(for: .unstaged)
        XCTAssertEqual(context.schemaVersion, 1)
        XCTAssertEqual(context.comments.count, 4)
        XCTAssertEqual(context.comments.first?.id, fixedID)
        XCTAssertEqual(context.comments.first?.body, "Keep the API stable.")
        let encoded = try JSONEncoder().encode(context)
        XCTAssertEqual(try JSONDecoder().decode(ReviewAgentContext.self, from: encoded), context)
        XCTAssertGreaterThan(encoded.count, 100)

        do {
            _ = try await service.load(.commit(revision: "--inject"))
            XCTFail("Expected revision validation to fail before loading")
        } catch let error as ReviewServiceError {
            XCTAssertEqual(error, .invalidRevision("--inject"))
        }
        let sourcesAfterRejection = await loader.recordedSources()
        XCTAssertEqual(sourcesAfterRejection, sources)
    }

    func testReloadDropsCommentsWhoseAnchorsAreNoLongerVisible() async throws {
        let loader = RecordingReviewSourceLoader(rawDiff: Self.comprehensiveDiff)
        let service = ReviewService(loader: loader)
        let first = try await service.load(.unstaged)
        let file = try XCTUnwrap(first.files.first { $0.displayPath == "Sources/Value.swift" })
        _ = try await service.addComment(
            source: .unstaged,
            target: .line(path: file.displayPath, side: .new, line: 2),
            body: "Anchor"
        )
        let commentsBeforeReload = await service.comments(for: .unstaged)
        XCTAssertEqual(commentsBeforeReload.count, 1)

        await loader.setRawDiff("""
        diff --git a/Sources/Value.swift b/Sources/Value.swift
        --- a/Sources/Value.swift
        +++ b/Sources/Value.swift
        @@ -20,1 +20,1 @@
        -let old = true
        +let new = true
        """)
        _ = try await service.load(.unstaged)
        let commentsAfterReload = await service.comments(for: .unstaged)
        XCTAssertTrue(commentsAfterReload.isEmpty)
    }

    private static let comprehensiveDiff = """
    diff --git a/Sources/Value.swift b/Sources/Value.swift
    index 1111111..2222222 100644
    --- a/Sources/Value.swift
    +++ b/Sources/Value.swift
    @@ -1,3 +1,3 @@
     import Foundation
    -let value = "old" // old
    +let value = "new" // new
     return value
    diff --git "a/old name.txt" "b/new name.txt"
    similarity index 100%
    rename from old name.txt
    rename to new name.txt
    diff --git a/Assets/icon.bin b/Assets/icon.bin
    index 1111111..2222222 100644
    Binary files a/Assets/icon.bin and b/Assets/icon.bin differ
    diff --git a/New.swift b/New.swift
    new file mode 100644
    --- /dev/null
    +++ b/New.swift
    @@ -0,0 +1,1 @@
    +let created = true
    diff --git a/Old.txt b/Old.txt
    deleted file mode 100644
    --- a/Old.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -obsolete
    """

    private func gitApplyCheck(_ patch: String, in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["apply", "--check", "-"]
        process.currentDirectoryURL = directory
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(patch.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("git apply --check rejected generated patch: \(detail)")
        }
        return process.terminationStatus
    }
}

private final class ReviewTestIDGenerator: @unchecked Sendable {
    let firstID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1")!
    private let lock = NSLock()
    private var values = [
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1")!,
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2")!,
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE3")!,
        UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE4")!
    ]

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? UUID() : values.removeFirst()
    }
}

private actor RecordingReviewSourceLoader: ReviewSourceLoading {
    private var rawDiff: String
    private var sources: [ReviewSource] = []

    init(rawDiff: String) {
        self.rawDiff = rawDiff
    }

    func loadDiff(for source: ReviewSource) async throws -> ReviewRawDiff {
        sources.append(source)
        return ReviewRawDiff(
            text: rawDiff,
            generatedAt: Date(timeIntervalSince1970: 321)
        )
    }

    func recordedSources() -> [ReviewSource] { sources }

    func setRawDiff(_ value: String) { rawDiff = value }
}
