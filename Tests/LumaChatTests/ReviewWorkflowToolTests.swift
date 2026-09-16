import Foundation
import XCTest
@testable import LumaChat

final class ReviewWorkflowToolTests: XCTestCase {
    func testEmptySourceIsOneCompletePageAndMalformedZeroProgressReceiptFailsClosed() async throws {
        let request = ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        let readers = ReviewWorkflowSourceReaders(
            local: { _, _ in ReviewWorkflowSourceSnapshot(content: "") },
            pullRequest: { _, _ in throw ReviewWorkflowToolError.sourceReaderUnavailable }
        )
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
                .first { $0.name == ReviewWorkflowToolFactory.sourceToolName }
        )
        let result = try await tool.execute(
            arguments: .emptyObject,
            context: Self.context(reviewWorkflow: request)
        )
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: request
        )

        XCTAssertEqual(receipt.offset, 0)
        XCTAssertEqual(receipt.nextOffset, 0)
        XCTAssertEqual(receipt.totalBytes, 0)
        XCTAssertFalse(receipt.hasMore)
        XCTAssertTrue(receipt.isComplete)
        XCTAssertTrue(result.content.contains("[No source changes]"))
        XCTAssertTrue(result.content.contains("paging complete"))

        var malformed = result
        guard case .object(var data)? = malformed.data else {
            return XCTFail("Missing source receipt")
        }
        data["total_bytes"] = .number(1)
        data["has_more"] = .bool(true)
        malformed.data = .object(data)
        XCTAssertThrowsError(try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: malformed,
            expected: request
        ))

        do {
            _ = try await tool.execute(
                arguments: .object(["offset": .number(1)]),
                context: Self.context(reviewWorkflow: request)
            )
            XCTFail("Expected out-of-range empty-source offset rejection")
        } catch let error as ReviewWorkflowToolError {
            guard case .invalidArguments(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("UTF-8 boundary"), detail)
        }
    }

    func testSourceRejectsOversizedRawDocumentBeforePaging() async throws {
        let readers = ReviewWorkflowSourceReaders(
            local: { _, _ in
                ReviewWorkflowSourceSnapshot(
                    content: String(repeating: "x", count: 16 * 1_024 * 1_024 + 1)
                )
            },
            pullRequest: { _, _ in throw ReviewWorkflowToolError.sourceReaderUnavailable }
        )
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
                .first { $0.name == ReviewWorkflowToolFactory.sourceToolName }
        )
        let context = Self.context(reviewWorkflow: .init(
            workflow: .changes,
            sourceContext: nil
        ))

        do {
            _ = try await tool.execute(arguments: .emptyObject, context: context)
            XCTFail("Expected oversized source rejection")
        } catch let error as ReviewWorkflowToolError {
            guard case .invalidSource(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("16 MiB"), detail)
        }
    }

    func testToolsAreUnavailableAndFailClosedOutsideLockedWorkflow() async throws {
        let tools = ReviewWorkflowToolFactory.makeTools()
        let context = Self.context(reviewWorkflow: nil)

        XCTAssertEqual(
            Set(tools.map(\.name)),
            [
                "review_source_read",
                "review_pull_request_source_read",
                "review_submit_findings"
            ]
        )
        XCTAssertTrue(tools.allSatisfy { !$0.isAvailable(in: context) })
        let source = try XCTUnwrap(tools.first { $0.name == "review_source_read" })
        do {
            _ = try await source.execute(arguments: .emptyObject, context: context)
            XCTFail("Expected workflow lock requirement")
        } catch let error as ReviewWorkflowToolError {
            XCTAssertEqual(error, .workflowUnavailable)
        }
    }

    func testSourceReadUsesContextLockedRevisionAndRejectsModelRevision() async throws {
        let recorder = WorkflowReaderRecorder()
        let readers = ReviewWorkflowSourceReaders(
            local: { request, _ in
                await recorder.recordLocal(request)
                return ReviewWorkflowSourceSnapshot(
                    content: "token=github_pat_abcdefghijklmnopqrstuvwxyz\u{0000}\n"
                        + String(repeating: "é", count: 2_000),
                    filePaths: ["Sources/Value.swift"]
                )
            },
            pullRequest: { reference, _ in
                await recorder.recordPullRequest(reference)
                return ReviewWorkflowSourceSnapshot(content: "PR")
            }
        )
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
                .first { $0.name == "review_source_read" }
        )
        XCTAssertFalse(tool.requiresNetwork)
        XCTAssertEqual(tool.permissionLevel, .read)
        let request = ReviewWorkflowRequest(
            workflow: .commit(revision: "locked-sha"),
            sourceContext: Self.sourceContext(source: .commit(revision: "locked-sha"))
        )
        var context = Self.context(reviewWorkflow: request)
        context.maximumToolResultCharacters = 1_024

        do {
            _ = try await tool.execute(
                arguments: .object(["revision": .string("attacker-sha")]),
                context: context
            )
            XCTFail("Expected model-provided revision rejection")
        } catch let error as ReviewWorkflowToolError {
            guard case .invalidArguments(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("revision"))
        }
        let callsBeforeRead = await recorder.localRequests()
        XCTAssertTrue(callsBeforeRead.isEmpty)

        let result = try await tool.execute(
            arguments: .object(["max_bytes": .number(1_024)]),
            context: context
        )

        let requests = await recorder.localRequests()
        XCTAssertEqual(requests.map(\.workflow), [.commit(revision: "locked-sha")])
        XCTAssertTrue(result.content.contains("token=[REDACTED]"))
        XCTAssertFalse(result.content.contains("github_pat_abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(result.content.contains("\u{0000}"))
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 1_024)
        XCTAssertEqual(result.data?["workflow"]?["revision"]?.stringValue, "locked-sha")
        var receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: request
        )
        XCTAssertEqual(receipt.offset, 0)
        XCTAssertTrue(receipt.hasMore)
        XCTAssertFalse(receipt.isComplete)
        let sourceID = receipt.sourceID
        while receipt.hasMore {
            let page = try await tool.execute(
                arguments: .object([
                    "max_bytes": .number(1_024),
                    "offset": .number(Double(receipt.nextOffset))
                ]),
                context: context
            )
            XCTAssertLessThanOrEqual(page.content.utf8.count, 1_024)
            let next = try ReviewWorkflowToolFactory.decodedSourceReceipt(
                from: page,
                expected: request
            )
            XCTAssertEqual(next.sourceID, sourceID)
            XCTAssertEqual(next.offset, receipt.nextOffset)
            receipt = next
        }
        // A continuation receipt authenticates only that individual page. The
        // Runtime, not the tool caller, folds the continuous sequence into an
        // offset-zero receipt before it can become submission authority.
        XCTAssertFalse(receipt.isComplete)
        XCTAssertGreaterThan(receipt.offset, 0)
        XCTAssertFalse(receipt.hasMore)
        XCTAssertEqual(receipt.nextOffset, receipt.totalBytes)
    }

    func testPullRequestSourceUsesInjectedProviderNeutralReaderAndLockedReference() async throws {
        let recorder = WorkflowReaderRecorder()
        let readers = ReviewWorkflowSourceReaders(
            local: { request, _ in
                await recorder.recordLocal(request)
                return ReviewWorkflowSourceSnapshot(content: "local")
            },
            pullRequest: { reference, _ in
                await recorder.recordPullRequest(reference)
                return ReviewWorkflowSourceSnapshot(
                    content: "remote patch",
                    filePaths: ["Sources/Remote.swift"]
                )
            }
        )
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
                .first { $0.name == "review_pull_request_source_read" }
        )
        XCTAssertTrue(tool.requiresNetwork)
        let reference = PullRequestReference(
            providerID: "example",
            repositoryID: "opaque/repository",
            pullRequestID: "PR-9"
        )

        let result = try await tool.execute(
            arguments: .emptyObject,
            context: Self.context(reviewWorkflow: ReviewWorkflowRequest(
                workflow: .pullRequest(reference),
                sourceContext: nil
            ))
        )

        let references = await recorder.pullRequestReferences()
        let localRequests = await recorder.localRequests()
        XCTAssertEqual(references, [reference])
        XCTAssertTrue(localRequests.isEmpty)
        XCTAssertEqual(result.data?["workflow"]?["pull_request_id"]?.stringValue, "PR-9")
        XCTAssertEqual(
            result.data?["files"]?.arrayValue?.compactMap(\.stringValue),
            ["Sources/Remote.swift"]
        )
    }

    func testWorkflowSpecificSourceToolsAreMutuallyExclusive() throws {
        let tools = ReviewWorkflowToolFactory.makeTools()
        let local = try XCTUnwrap(tools.first { $0.name == "review_source_read" })
        let remote = try XCTUnwrap(
            tools.first { $0.name == "review_pull_request_source_read" }
        )
        let submission = try XCTUnwrap(
            tools.first { $0.name == "review_submit_findings" }
        )
        let localContext = Self.context(reviewWorkflow: .init(
            workflow: .changes,
            sourceContext: nil
        ))
        let remoteContext = Self.context(reviewWorkflow: .init(
            workflow: .pullRequest(.init(
                providerID: "github",
                repositoryID: "acme/luma",
                pullRequestID: "9"
            )),
            sourceContext: nil
        ))

        XCTAssertTrue(local.isAvailable(in: localContext))
        XCTAssertFalse(remote.isAvailable(in: localContext))
        XCTAssertFalse(local.isAvailable(in: remoteContext))
        XCTAssertTrue(remote.isAvailable(in: remoteContext))
        XCTAssertTrue(submission.isAvailable(in: localContext))
        XCTAssertTrue(submission.isAvailable(in: remoteContext))
        XCTAssertFalse(local.requiresNetwork)
        XCTAssertTrue(remote.requiresNetwork)
        XCTAssertFalse(submission.requiresNetwork)
    }

    func testSubmitFindingsGeneratesHostUUIDsAndReturnsSecretSafeStructuredResult() async throws {
        let identifier = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(idGenerator: { identifier })
                .first { $0.name == "review_submit_findings" }
        )
        let context = Self.context(reviewWorkflow: ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: Self.sourceContext(source: .unstaged)
        ))
        let result = try await tool.execute(
            arguments: .object([
                "summary": .string("  Found token=github_pat_abcdefghijklmnopqrstuvwxyz  "),
                "findings": .array([.object([
                    "severity": .string("critical"),
                    "file": .string("Sources/Value.swift"),
                    "line": .number(7),
                    "explanation": .string(
                        "  password=hunter2 is committed  "
                    ),
                    "recommended_fix": .string("  Rotate it and use Keychain.  ")
                ])])
            ]),
            context: context
        )

        let encodedFinding = try XCTUnwrap(
            result.data?["result"]?["findings"]?.arrayValue?.first
        )
        XCTAssertEqual(encodedFinding["id"]?.stringValue, identifier.uuidString)
        XCTAssertEqual(encodedFinding["severity"]?.stringValue, "critical")
        XCTAssertEqual(encodedFinding["file"]?.stringValue, "Sources/Value.swift")
        XCTAssertEqual(
            encodedFinding["explanation"]?.stringValue,
            "password=[REDACTED] is committed"
        )
        XCTAssertFalse(result.content.contains("hunter2"))
        XCTAssertFalse(result.content.contains("github_pat_abcdefghijklmnopqrstuvwxyz"))
    }

    func testSourceContextIsSupplementalAndRuntimeDecodersVerifyExactWorkflow() async throws {
        let readers = ReviewWorkflowSourceReaders(
            local: { _, _ in
                ReviewWorkflowSourceSnapshot(
                    content: "diff --git a/Sources/Actual.swift b/Sources/Actual.swift",
                    filePaths: ["Sources/Actual.swift"]
                )
            },
            pullRequest: { _, _ in
                throw ReviewWorkflowToolError.sourceReaderUnavailable
            }
        )
        let tools = ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
        let source = try XCTUnwrap(
            tools.first { $0.name == "review_source_read" }
        )
        let submit = try XCTUnwrap(
            tools.first { $0.name == "review_submit_findings" }
        )
        let request = ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: Self.sourceContext(source: .unstaged)
        )
        let context = Self.context(reviewWorkflow: request)

        let sourceResult = try await source.execute(
            arguments: .emptyObject,
            context: context
        )
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: sourceResult,
            expected: request
        )
        XCTAssertEqual(receipt.schemaVersion, ReviewWorkflowSourceReceipt.currentSchemaVersion)
        XCTAssertEqual(receipt.workflow, .changes)
        XCTAssertEqual(receipt.filePaths, ["Sources/Actual.swift"])

        let submission = try await submit.execute(
            arguments: Self.submission(
                file: "Sources/Actual.swift",
                line: 4,
                count: 1
            ),
            context: context
        )
        let decoded = try ReviewWorkflowToolFactory.decodedSubmissionResult(
            from: submission,
            expected: request
        )
        XCTAssertEqual(decoded.findings.map(\.file), ["Sources/Actual.swift"])
        XCTAssertNoThrow(try ReviewWorkflowValidator().validated(
            decoded,
            for: request,
            allowedFiles: Set(receipt.filePaths)
        ))
        XCTAssertThrowsError(try ReviewWorkflowValidator().validated(
            decoded,
            for: request,
            allowedFiles: []
        ))

        XCTAssertThrowsError(try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: sourceResult,
            expected: .init(
                workflow: .commit(revision: "different"),
                sourceContext: nil
            )
        ))
        var tampered = sourceResult
        guard case .object(var data)? = tampered.data else {
            return XCTFail("Missing source receipt")
        }
        data["schema_version"] = .number(999)
        tampered.data = .object(data)
        XCTAssertThrowsError(try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: tampered,
            expected: request
        ))
    }

    func testSubmitFindingsRejectsModelUUIDUnsafePathInvalidLineAndDuplicateHostIDs() async throws {
        let duplicate = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let tool = try XCTUnwrap(
            ReviewWorkflowToolFactory.makeTools(idGenerator: { duplicate })
                .first { $0.name == "review_submit_findings" }
        )
        let context = Self.context(reviewWorkflow: ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: Self.sourceContext(source: .unstaged)
        ))

        do {
            _ = try await tool.execute(arguments: .object([
                "summary": .string("Invalid"),
                "findings": .array([.object([
                    "id": .string(UUID().uuidString),
                    "severity": .string("high"),
                    "file": .string("Sources/Value.swift"),
                    "explanation": .string("Model supplied an ID")
                ])])
            ]), context: context)
            XCTFail("Expected model UUID rejection")
        } catch let error as ReviewWorkflowToolError {
            guard case .invalidArguments(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("id"))
        }

        do {
            _ = try await tool.execute(arguments: Self.submission(
                file: "../escape.swift",
                line: 1,
                count: 1
            ), context: context)
            XCTFail("Expected unsafe path rejection")
        } catch {
            XCTAssertTrue(error is ReviewWorkflowValidationError)
        }

        do {
            _ = try await tool.execute(arguments: Self.submission(
                file: "Sources/Value.swift",
                line: 1.5,
                count: 1
            ), context: context)
            XCTFail("Expected non-integral line rejection")
        } catch {
            XCTAssertTrue(error is ReviewWorkflowToolError)
        }

        do {
            _ = try await tool.execute(arguments: Self.submission(
                file: "Sources/Value.swift",
                line: 7,
                count: 2
            ), context: context)
            XCTFail("Expected duplicate host UUID rejection")
        } catch let error as ReviewWorkflowValidationError {
            XCTAssertEqual(error, .invalidResult("finding host UUID is duplicated"))
        }
    }

    func testProductionLocalReaderUsesSourceTaskGitAndCombinesStagedAndUnstaged() async throws {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("review-workflow-tool-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.runGit(["init", "--initial-branch=main"], at: root)
        try Self.runGit(["config", "user.email", "review@example.test"], at: root)
        try Self.runGit(["config", "user.name", "Review Test"], at: root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("Staged.txt"))
        try Data("two\n".utf8).write(to: root.appendingPathComponent("Unstaged.txt"))
        try Self.runGit(["add", "--", "Staged.txt", "Unstaged.txt"], at: root)
        try Self.runGit(["commit", "-m", "initial"], at: root)
        try Data("one changed\n".utf8).write(to: root.appendingPathComponent("Staged.txt"))
        try Self.runGit(["add", "--", "Staged.txt"], at: root)
        try Data("two changed\n".utf8).write(to: root.appendingPathComponent("Unstaged.txt"))
        try Data("three untracked\n".utf8).write(to: root.appendingPathComponent("Untracked.txt"))
        _ = try XCTUnwrap(GitRepositoryLayout.inspect(workspaceRoot: root))

        let environment = BuiltinToolEnvironment()
        let tools = BuiltinToolFactory.makeTools(
            environment: environment,
            todoManager: TodoManager()
        )
        let tool = try XCTUnwrap(
            tools.first { $0.name == "review_source_read" }
        )
        let request = ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        let reviewID = UUID()
        let sourceID = UUID()
        let context = AgentToolContext(
            sessionID: reviewID,
            mode: .plan,
            workspace: AgentWorkspace(
                name: root.lastPathComponent,
                rootPath: root.path,
                allowedPaths: [],
                gitRepository: true
            ),
            reviewWorkflow: request,
            reviewSourceSessionID: sourceID
        )

        let result = try await tool.execute(arguments: .emptyObject, context: context)
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: request
        )
        XCTAssertEqual(Set(receipt.filePaths), ["Staged.txt", "Unstaged.txt", "Untracked.txt"])
        XCTAssertTrue(result.content.contains("Staged changes"))
        XCTAssertTrue(result.content.contains("Unstaged changes"))

        for (selectedSource, expectedFiles) in [
            (ReviewSource.staged, Set(["Staged.txt"])),
            (ReviewSource.unstaged, Set(["Unstaged.txt", "Untracked.txt"]))
        ] {
            let selectedRequest = ReviewWorkflowRequest(
                workflow: .changes,
                sourceContext: Self.sourceContext(source: selectedSource)
            )
            var selectedContext = context
            selectedContext.reviewWorkflow = selectedRequest
            let selectedResult = try await tool.execute(
                arguments: .emptyObject,
                context: selectedContext
            )
            let selectedReceipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
                from: selectedResult,
                expected: selectedRequest
            )
            XCTAssertEqual(Set(selectedReceipt.filePaths), expectedFiles)
            XCTAssertFalse(selectedResult.content.contains("===== Staged changes ====="))
            XCTAssertFalse(selectedResult.content.contains("===== Unstaged changes ====="))
        }
    }

    func testProductionLocalReaderUsesFrozenLastAgentTurnSnapshot() async throws {
        try AppPaths.ensureAgentDirectories()
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("review-workflow-last-turn-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.runGit(["init", "--initial-branch=main"], at: root)
        try Self.runGit(["config", "user.email", "review@example.test"], at: root)
        try Self.runGit(["config", "user.name", "Review Test"], at: root)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("Feature.txt"))
        try Self.runGit(["add", "--", "Feature.txt"], at: root)
        try Self.runGit(["commit", "-m", "initial"], at: root)

        let sourceID = UUID()
        let reviewID = UUID()
        let workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            gitRepository: true
        )
        let environment = BuiltinToolEnvironment()
        let sourceContext = AgentToolContext(
            sessionID: sourceID,
            mode: .agent,
            workspace: workspace
        )
        let git = try await environment.gitService(for: sourceContext)
        let baseline = try await git.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: sourceID
        )
        try Data("after\n".utf8).write(to: root.appendingPathComponent("Feature.txt"))
        try Self.runGit(["add", "--", "Feature.txt"], at: root)
        try Self.runGit(["commit", "-m", "agent turn"], at: root)
        try Data("shell output\n".utf8).write(to: root.appendingPathComponent("Shell.txt"))
        let snapshot = try await git.finalizeAgentTurnReviewSnapshot(since: baseline)

        // Later checkout edits must not leak into the completed turn.
        try Data("post-run external edit\n".utf8).write(
            to: root.appendingPathComponent("Feature.txt")
        )
        try Data("post-run only\n".utf8).write(
            to: root.appendingPathComponent("External.txt")
        )

        let request = ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: Self.sourceContext(
                source: .lastAgentTurn(taskID: sourceID)
            )
        )
        let context = AgentToolContext(
            sessionID: reviewID,
            mode: .plan,
            workspace: workspace,
            reviewWorkflow: request,
            reviewSourceSessionID: sourceID,
            reviewSourceSnapshot: snapshot
        )
        let tool = try XCTUnwrap(
            BuiltinToolFactory.makeTools(
                environment: environment,
                todoManager: TodoManager()
            ).first { $0.name == "review_source_read" }
        )
        let result = try await tool.execute(arguments: .emptyObject, context: context)
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: request
        )
        XCTAssertEqual(Set(receipt.filePaths), ["Feature.txt", "Shell.txt"])
        XCTAssertTrue(result.content.contains("after"))
        XCTAssertTrue(result.content.contains("shell output"))
        XCTAssertFalse(result.content.contains("post-run external edit"))
        XCTAssertFalse(result.content.contains("External.txt"))

        var missingSnapshot = context
        missingSnapshot.reviewSourceSnapshot = nil
        do {
            _ = try await tool.execute(arguments: .emptyObject, context: missingSnapshot)
            XCTFail("Last Agent Turn must fail closed without its frozen source")
        } catch let error as ReviewWorkflowToolError {
            guard case .invalidSource(let detail) = error else { throw error }
            XCTAssertTrue(detail.contains("frozen source"))
        }
    }

    func testProductionPullRequestReaderUsesPerRunProviderConfiguration() async throws {
        let resolver = PullRequestProviderResolver { configuration in
            ReviewWorkflowStubProvider(configuration: try configuration.normalized())
        }
        let tools = BuiltinToolFactory.makeTools(
            todoManager: TodoManager(),
            pullRequestResolver: resolver
        )
        let tool = try XCTUnwrap(
            tools.first { $0.name == "review_pull_request_source_read" }
        )
        let reference = ReviewPullRequestReference(
            providerID: "github",
            repositoryID: "acme/luma",
            pullRequestID: "17"
        )
        let request = ReviewWorkflowRequest(
            workflow: .pullRequest(reference),
            sourceContext: nil
        )
        let context = AgentToolContext(
            sessionID: UUID(),
            mode: .plan,
            workspace: AgentWorkspace(
                name: "Review PR",
                rootPath: FileManager.default.temporaryDirectory.path,
                allowedPaths: [],
                gitRepository: false
            ),
            pullRequestProvider: .init(
                providerID: "GitHub",
                apiEndpoint: "https://enterprise.example/api/v3/"
            ),
            reviewWorkflow: request,
            reviewSourceSessionID: UUID()
        )

        let result = try await tool.execute(arguments: .emptyObject, context: context)
        let receipt = try ReviewWorkflowToolFactory.decodedSourceReceipt(
            from: result,
            expected: request
        )
        XCTAssertEqual(receipt.filePaths, ["Sources/Remote.swift"])
        XCTAssertTrue(result.content.contains("enterprise.example/api/v3"))
        XCTAssertTrue(tool.requiresNetwork)
    }

    private static func submission(file: String, line: Double, count: Int) -> JSONValue {
        .object([
            "summary": .string("Summary"),
            "findings": .array((0..<count).map { index in
                .object([
                    "severity": .string(index == 0 ? "high" : "medium"),
                    "file": .string(file),
                    "line": .number(line),
                    "explanation": .string("Finding \(index)")
                ])
            })
        ])
    }

    private static func sourceContext(source: ReviewSource) -> ReviewAgentContext {
        ReviewAgentContext(
            schemaVersion: ReviewAgentContext.currentSchemaVersion,
            source: source,
            files: [ReviewFileSummary(
                path: "Sources/Value.swift",
                oldPath: nil,
                change: .modified,
                additions: 1,
                deletions: 1,
                hunkCount: 1,
                fallback: nil
            )],
            comments: []
        )
    }

    private static func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "credential.helper="
        ] + arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false"
        ]) { _, value in value }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "ReviewWorkflowToolTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
    }

    private static func context(
        reviewWorkflow: ReviewWorkflowRequest?
    ) -> AgentToolContext {
        AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "Review",
                rootPath: "/tmp/lumachat-review-workflow-tests",
                allowedPaths: [],
                gitRepository: true
            ),
            reviewWorkflow: reviewWorkflow
        )
    }
}

private actor WorkflowReaderRecorder {
    private var locals: [ReviewWorkflowRequest] = []
    private var pullRequests: [ReviewPullRequestReference] = []

    func recordLocal(_ request: ReviewWorkflowRequest) { locals.append(request) }
    func recordPullRequest(_ reference: ReviewPullRequestReference) {
        pullRequests.append(reference)
    }

    func localRequests() -> [ReviewWorkflowRequest] { locals }
    func pullRequestReferences() -> [ReviewPullRequestReference] { pullRequests }
}

private struct ReviewWorkflowStubProvider: PullRequestProvider {
    let configuration: PullRequestProviderConfiguration
    var id: String { configuration.providerID }

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary {
        try summary(reference: .init(
            providerID: id,
            repositoryID: request.repositoryID,
            pullRequestID: "created"
        ))
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        try summary(reference: reference)
    }

    func context(
        for reference: PullRequestReference,
        maximumFiles _: Int
    ) async throws -> PullRequestContext {
        PullRequestContext(
            summary: try summary(reference: reference),
            files: [PullRequestFile(
                path: "Sources/Remote.swift",
                previousPath: nil,
                status: .modified,
                additions: 1,
                deletions: 1,
                changes: 2,
                patch: "@@ -1 +1 @@\n-old\n+\(configuration.apiEndpoint)",
                isPatchUnavailable: false
            )],
            filesTruncated: false,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func summary(reference: PullRequestReference) throws -> PullRequestSummary {
        let endpoint = try XCTUnwrap(URL(string: configuration.apiEndpoint))
        return PullRequestSummary(
            reference: reference,
            title: "Configured endpoint \(endpoint.host ?? "missing")",
            body: nil,
            webURL: endpoint,
            state: .open,
            isDraft: false,
            baseBranch: "main",
            headBranch: "feature/review",
            author: nil,
            mergeable: true,
            changedFileCount: 1
        )
    }
}
