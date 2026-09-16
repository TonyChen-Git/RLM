import Foundation
import XCTest
@testable import LumaChat

private actor ReviewRuntimeScriptProvider: AgentModelProvider {
    nonisolated let id = "review-runtime-script"
    private var responses: [AgentModelResponse]
    private var capturedRequests: [AgentModelRequest] = []

    init(_ responses: [AgentModelResponse]) {
        self.responses = responses
    }

    nonisolated func capabilities(for model: String) async -> ModelCapabilities {
        ModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsStreaming: false,
            supportsParallelTools: false,
            supportsReasoning: false,
            supportsSystemPrompt: true,
            contextWindow: 16_384,
            maxOutputTokens: 2_048
        )
    }

    func generate(request: AgentModelRequest) async throws -> AgentModelResponse {
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            throw ProviderWireError.invalidRequest(
                "Review Runtime response script exhausted"
            )
        }
        return responses.removeFirst()
    }

    func requests() -> [AgentModelRequest] { capturedRequests }
}

private actor ReviewRuntimeSourceProbe {
    private var localCalls = 0
    private var pullRequestCalls = 0
    let localSnapshots: [ReviewWorkflowSourceSnapshot]
    let pullRequestSnapshot: ReviewWorkflowSourceSnapshot

    init(
        localFiles: [String] = ["Sources/App.swift"],
        pullRequestFiles: [String] = ["Sources/Remote.swift"],
        localContent: String = "diff --git a/Sources/App.swift b/Sources/App.swift",
        localContents: [String]? = nil
    ) {
        localSnapshots = (localContents ?? [localContent]).map {
            ReviewWorkflowSourceSnapshot(content: $0, filePaths: localFiles)
        }
        pullRequestSnapshot = ReviewWorkflowSourceSnapshot(
            content: "diff --git a/Sources/Remote.swift b/Sources/Remote.swift",
            filePaths: pullRequestFiles
        )
    }

    func readLocal() -> ReviewWorkflowSourceSnapshot {
        let index = min(localCalls, localSnapshots.count - 1)
        localCalls += 1
        return localSnapshots[index]
    }

    func readPullRequest() -> ReviewWorkflowSourceSnapshot {
        pullRequestCalls += 1
        return pullRequestSnapshot
    }

    func counts() -> (local: Int, pullRequest: Int) {
        (localCalls, pullRequestCalls)
    }
}

final class AgentRuntimeReviewWorkflowTests: XCTestCase {
    func testLocalSourceReadThenStructuredSubmissionIsTheOnlyDurableCompletion() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ReviewRuntimeScriptProvider([
            Self.toolResponse(
                id: "read-local",
                name: ReviewWorkflowToolFactory.sourceToolName
            ),
            Self.toolResponse(
                id: "submit-local",
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: Self.submission(file: "Sources/App.swift")
            ),
            Self.finalResponse("Structured Review complete")
        ])

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review the current changes",
            provider: provider,
            settings: Self.settings(maxSteps: 8),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        let reviewResult = try XCTUnwrap(result.reviewResult)
        XCTAssertEqual(reviewResult.summary, "One actionable issue")
        XCTAssertEqual(reviewResult.findings.map(\.file), ["Sources/App.swift"])
        XCTAssertEqual(reviewResult.findings.map(\.severity), [.high])
        XCTAssertEqual(
            result.steps.compactMap { $0.toolCall?.name },
            [
                ReviewWorkflowToolFactory.sourceToolName,
                ReviewWorkflowToolFactory.submissionToolName
            ]
        )
        XCTAssertTrue(result.steps.contains { $0.kind == .completed })
        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(restored.reviewResult, reviewResult)
        XCTAssertEqual(restored.resolvedTaskType, result.resolvedTaskType)
    }

    func testPullRequestReviewExposesAndRequiresTheNetworkSourceTool() async throws {
        let reference = ReviewPullRequestReference(
            providerID: "github",
            repositoryID: "acme/luma",
            pullRequestID: "42"
        )
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(
                workflow: .pullRequest(reference),
                sourceContext: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ReviewRuntimeScriptProvider([
            Self.toolResponse(
                id: "read-pr",
                name: ReviewWorkflowToolFactory.pullRequestSourceToolName
            ),
            Self.toolResponse(
                id: "submit-pr",
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: Self.submission(file: "Sources/Remote.swift")
            ),
            Self.finalResponse("Pull Request Review complete")
        ])

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review the locked Pull Request",
            provider: provider,
            settings: Self.settings(maxSteps: 8, networkAccess: true),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .completed, result.lastError ?? "")
        XCTAssertEqual(result.reviewResult?.findings.map(\.file), ["Sources/Remote.swift"])
        let counts = await fixture.probe.counts()
        XCTAssertEqual(counts.local, 0)
        XCTAssertEqual(counts.pullRequest, 1)
        let requests = await provider.requests()
        let firstRequest = try XCTUnwrap(requests.first)
        let names = Set(firstRequest.tools.map(\.name))
        XCTAssertTrue(names.contains(ReviewWorkflowToolFactory.pullRequestSourceToolName))
        XCTAssertFalse(names.contains(ReviewWorkflowToolFactory.sourceToolName))
    }

    func testPrematureProseFinalIsDiscardedAndRuntimeRequestsContractContinuation() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ReviewRuntimeScriptProvider([
            Self.finalResponse("Looks good to me")
        ])

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review the current changes",
            provider: provider,
            settings: Self.settings(maxSteps: 1),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        XCTAssertNil(result.reviewResult)
        XCTAssertFalse(result.steps.contains { $0.kind == .completed })
        XCTAssertFalse(result.messages.contains {
            $0.role == .assistant && $0.content == "Looks good to me"
        })
        let invariant = try XCTUnwrap(result.messages.first {
            $0.name == "luma-review-completion-invariant"
        })
        XCTAssertTrue(invariant.content.contains(ReviewWorkflowToolFactory.sourceToolName))
        XCTAssertTrue(invariant.content.contains(ReviewWorkflowToolFactory.submissionToolName))
    }

    func testSubmissionBeforeSourceReadCannotComplete() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provider = ReviewRuntimeScriptProvider([
            Self.toolResponse(
                id: "early-submit",
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: Self.submission(file: "Sources/App.swift")
            ),
            Self.finalResponse("Submitted without reading")
        ])

        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review the current changes",
            provider: provider,
            settings: Self.settings(maxSteps: 3),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        XCTAssertNil(result.reviewResult)
        XCTAssertFalse(result.steps.contains { $0.kind == .completed })
        let submitted = try XCTUnwrap(result.steps.first {
            $0.toolCall?.name == ReviewWorkflowToolFactory.submissionToolName
        })
        XCTAssertTrue(submitted.toolResult?.isError == true)
        XCTAssertTrue(
            submitted.toolResult?.content.contains(
                "Review completion contract rejected"
            ) == true,
            submitted.toolResult?.content ?? ""
        )
        let counts = await fixture.probe.counts()
        XCTAssertEqual(counts.local, 0)
    }

    func testSourcePaginationMustBeContinuousAndCompleteBeforeSubmission() async throws {
        let content = String(repeating: "x", count: 1_500)
        let incomplete = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            localContent: content,
            label: "incomplete-pagination"
        )
        defer { try? FileManager.default.removeItem(at: incomplete.root) }
        let incompleteResult = await incomplete.runtime.run(
            session: incomplete.session,
            userRequest: "Review every page",
            provider: ReviewRuntimeScriptProvider([
                Self.toolResponse(
                    id: "read-first-page",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object(["max_bytes": .number(1_024)])
                ),
                Self.toolResponse(
                    id: "submit-too-early",
                    name: ReviewWorkflowToolFactory.submissionToolName,
                    arguments: Self.submission(file: "Sources/App.swift")
                ),
                Self.finalResponse("Partial source is enough")
            ]),
            settings: Self.settings(maxSteps: 5),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(incompleteResult.state, .stepLimit)
        XCTAssertNil(incompleteResult.reviewResult)
        let earlySubmission = try XCTUnwrap(incompleteResult.steps.first {
            $0.toolCall?.id == "submit-too-early"
        })
        XCTAssertTrue(earlySubmission.toolResult?.isError == true)
        XCTAssertTrue(
            earlySubmission.toolResult?.content.contains("offset=1024") == true,
            earlySubmission.toolResult?.content ?? ""
        )

        let complete = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            localContent: content,
            label: "complete-pagination"
        )
        defer { try? FileManager.default.removeItem(at: complete.root) }
        let completeResult = await complete.runtime.run(
            session: complete.session,
            userRequest: "Review every page",
            provider: ReviewRuntimeScriptProvider([
                Self.toolResponse(
                    id: "read-page-one",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object(["max_bytes": .number(1_024)])
                ),
                Self.toolResponse(
                    id: "read-page-two",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object([
                        "max_bytes": .number(1_024),
                        "offset": .number(1_024)
                    ])
                ),
                Self.toolResponse(
                    id: "submit-after-all-pages",
                    name: ReviewWorkflowToolFactory.submissionToolName,
                    arguments: Self.submission(file: "Sources/App.swift")
                ),
                Self.finalResponse("All pages reviewed")
            ]),
            settings: Self.settings(maxSteps: 10),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(completeResult.state, .completed, completeResult.lastError ?? "")
        XCTAssertEqual(completeResult.reviewResult?.findings.map(\.file), ["Sources/App.swift"])
        let counts = await complete.probe.counts()
        XCTAssertEqual(counts.local, 2)
    }

    func testSourceChangeMidPaginationClearsAuthorityAndRejectsSubmission() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            localContents: [
                String(repeating: "a", count: 1_500),
                String(repeating: "b", count: 1_500)
            ],
            label: "changed-pagination"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review a stable source",
            provider: ReviewRuntimeScriptProvider([
                Self.toolResponse(
                    id: "read-before-change",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object(["max_bytes": .number(1_024)])
                ),
                Self.toolResponse(
                    id: "read-after-change",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object([
                        "max_bytes": .number(1_024),
                        "offset": .number(1_024)
                    ])
                ),
                Self.toolResponse(
                    id: "submit-after-change",
                    name: ReviewWorkflowToolFactory.submissionToolName,
                    arguments: Self.submission(file: "Sources/App.swift")
                ),
                Self.finalResponse("Changed source was fully reviewed")
            ]),
            settings: Self.settings(maxSteps: 7),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(result.state, .stepLimit)
        XCTAssertNil(result.reviewResult)
        let changedPage = try XCTUnwrap(result.steps.first {
            $0.toolCall?.id == "read-after-change"
        })
        XCTAssertTrue(changedPage.toolResult?.isError == true)
        XCTAssertTrue(
            changedPage.toolResult?.content.contains("來源已改變") == true,
            changedPage.toolResult?.content ?? ""
        )
        let submission = try XCTUnwrap(result.steps.first {
            $0.toolCall?.id == "submit-after-change"
        })
        XCTAssertTrue(submission.toolResult?.isError == true)
        XCTAssertTrue(
            submission.toolResult?.content.contains("成功讀取") == true,
            submission.toolResult?.content ?? ""
        )
    }

    func testJumpedAndRepeatedPagesClearPaginationAuthority() async throws {
        let cases: [(label: String, offsets: [Int])] = [
            ("jumped", [0, 1_500]),
            ("repeated", [0, 1_024, 1_024])
        ]
        for item in cases {
            let fixture = try await makeFixture(
                request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
                localContent: String(repeating: "x", count: 3_000),
                label: item.label
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var responses = item.offsets.enumerated().map { index, offset in
                Self.toolResponse(
                    id: "\(item.label)-page-\(index)",
                    name: ReviewWorkflowToolFactory.sourceToolName,
                    arguments: .object([
                        "max_bytes": .number(1_024),
                        "offset": .number(Double(offset))
                    ])
                )
            }
            responses.append(Self.toolResponse(
                id: "\(item.label)-submit",
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: Self.submission(file: "Sources/App.swift")
            ))
            responses.append(Self.finalResponse("Out-of-order pages were enough"))

            let result = await fixture.runtime.run(
                session: fixture.session,
                userRequest: "Review every page in sequence",
                provider: ReviewRuntimeScriptProvider(responses),
                settings: Self.settings(maxSteps: item.offsets.count * 2 + 3),
                approvalHandler: nil,
                eventHandler: { _ in }
            )

            XCTAssertEqual(result.state, .stepLimit, item.label)
            XCTAssertNil(result.reviewResult, item.label)
            let rejectedPage = try XCTUnwrap(result.steps.first {
                $0.toolCall?.id == "\(item.label)-page-\(item.offsets.count - 1)"
            })
            XCTAssertTrue(rejectedPage.toolResult?.isError == true, item.label)
            XCTAssertTrue(
                rejectedPage.toolResult?.content.contains("分頁不連續") == true,
                "\(item.label): \(rejectedPage.toolResult?.content ?? "")"
            )
            let submission = try XCTUnwrap(result.steps.first {
                $0.toolCall?.id == "\(item.label)-submit"
            })
            XCTAssertTrue(submission.toolResult?.isError == true, item.label)
        }
    }

    func testFindingsMustBelongToTheActualReceiptIncludingAnEmptyFileSet() async throws {
        let cases: [(label: String, receipt: [String], submitted: String)] = [
            ("outside", ["Sources/Actual.swift"], "Sources/Other.swift"),
            ("empty", [], "Sources/Unexpected.swift")
        ]

        for item in cases {
            let fixture = try await makeFixture(
                request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
                localFiles: item.receipt,
                label: item.label
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let provider = ReviewRuntimeScriptProvider([
                Self.toolResponse(
                    id: "read-\(item.label)",
                    name: ReviewWorkflowToolFactory.sourceToolName
                ),
                Self.toolResponse(
                    id: "submit-\(item.label)",
                    name: ReviewWorkflowToolFactory.submissionToolName,
                    arguments: Self.submission(file: item.submitted)
                ),
                Self.finalResponse("Invalid scope must not complete")
            ])

            let result = await fixture.runtime.run(
                session: fixture.session,
                userRequest: "Review \(item.label)",
                provider: provider,
                settings: Self.settings(maxSteps: 5),
                approvalHandler: nil,
                eventHandler: { _ in }
            )

            XCTAssertEqual(result.state, .stepLimit, item.label)
            XCTAssertNil(result.reviewResult, item.label)
            XCTAssertFalse(result.steps.contains { $0.kind == .completed }, item.label)
            let submitted = try XCTUnwrap(result.steps.first {
                $0.toolCall?.name == ReviewWorkflowToolFactory.submissionToolName
            })
            XCTAssertTrue(submitted.toolResult?.isError == true, item.label)
            XCTAssertTrue(
                submitted.toolResult?.content.contains("outside the locked Review source") == true,
                "\(item.label): \(submitted.toolResult?.content ?? "")"
            )
        }
    }

    func testRetryReconstructsOrderedReceiptAndSubmissionFromPersistedSteps() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstProvider = ReviewRuntimeScriptProvider([
            Self.toolResponse(
                id: "persisted-read",
                name: ReviewWorkflowToolFactory.sourceToolName
            ),
            Self.toolResponse(
                id: "persisted-submit",
                name: ReviewWorkflowToolFactory.submissionToolName,
                arguments: Self.submission(file: "Sources/App.swift")
            )
        ])
        let limited = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Review and pause at the step ceiling",
            provider: firstProvider,
            settings: Self.settings(maxSteps: 4),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(limited.state, .stepLimit)
        XCTAssertNotNil(limited.reviewResult)
        XCTAssertEqual(
            limited.steps.compactMap { $0.toolCall?.name },
            [
                ReviewWorkflowToolFactory.sourceToolName,
                ReviewWorkflowToolFactory.submissionToolName
            ]
        )

        let resumedRuntime = AgentRuntime(
            registry: fixture.registry,
            executor: ToolExecutor(registry: fixture.registry)
        )
        let resumed = await resumedRuntime.run(
            session: limited,
            userRequest: nil,
            provider: ReviewRuntimeScriptProvider([
                Self.finalResponse("Completed from durable structured state")
            ]),
            settings: Self.settings(maxSteps: 1),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(resumed.state, .completed, resumed.lastError ?? "")
        XCTAssertEqual(resumed.reviewResult, limited.reviewResult)
        XCTAssertEqual(resumed.messages.last?.content, "Completed from durable structured state")
    }

    func testNewUserTurnInvalidatesOldResultAndRequiresFreshSourceRead() async throws {
        let fixture = try await makeFixture(
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let completed = await fixture.runtime.run(
            session: fixture.session,
            userRequest: "Initial Review",
            provider: ReviewRuntimeScriptProvider([
                Self.toolResponse(
                    id: "initial-read",
                    name: ReviewWorkflowToolFactory.sourceToolName
                ),
                Self.toolResponse(
                    id: "initial-submit",
                    name: ReviewWorkflowToolFactory.submissionToolName,
                    arguments: Self.submission(file: "Sources/App.swift")
                ),
                Self.finalResponse("Initial Review complete")
            ]),
            settings: Self.settings(maxSteps: 8),
            approvalHandler: nil,
            eventHandler: { _ in }
        )
        XCTAssertEqual(completed.state, .completed, completed.lastError ?? "")
        XCTAssertNotNil(completed.reviewResult)

        let followUp = await fixture.runtime.run(
            session: completed,
            userRequest: "Review it again after my follow-up",
            provider: ReviewRuntimeScriptProvider([
                Self.finalResponse("Reusing the old result")
            ]),
            settings: Self.settings(maxSteps: 1),
            approvalHandler: nil,
            eventHandler: { _ in }
        )

        XCTAssertEqual(followUp.state, .stepLimit)
        XCTAssertNil(followUp.reviewResult)
        XCTAssertFalse(followUp.steps.contains {
            $0.kind == .completed && $0.detail == "Reusing the old result"
        })
        let invariant = try XCTUnwrap(followUp.messages.first {
            $0.name == "luma-review-completion-invariant"
        })
        XCTAssertTrue(invariant.content.contains(ReviewWorkflowToolFactory.sourceToolName))
    }

    private func makeFixture(
        request: ReviewWorkflowRequest,
        localFiles: [String] = ["Sources/App.swift"],
        pullRequestFiles: [String] = ["Sources/Remote.swift"],
        localContent: String = "diff --git a/Sources/App.swift b/Sources/App.swift",
        localContents: [String]? = nil,
        label: String = "fixture"
    ) async throws -> (
        root: URL,
        registry: ToolRegistry,
        runtime: AgentRuntime,
        session: AgentSession,
        probe: ReviewRuntimeSourceProbe
    ) {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "agent-review-runtime-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let probe = ReviewRuntimeSourceProbe(
            localFiles: localFiles,
            pullRequestFiles: pullRequestFiles,
            localContent: localContent,
            localContents: localContents
        )
        let readers = ReviewWorkflowSourceReaders(
            local: { _, _ in await probe.readLocal() },
            pullRequest: { _, _ in await probe.readPullRequest() }
        )
        let registry = ToolRegistry()
        try await registry.register(
            ReviewWorkflowToolFactory.makeTools(sourceReaders: readers)
        )
        let runtime = AgentRuntime(
            registry: registry,
            executor: ToolExecutor(registry: registry)
        )
        var session = AgentSession(mode: .plan)
        session.model = "review-model"
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        session.taskType = .review(
            sourceSessionID: UUID(),
            request: request
        )
        return (root, registry, runtime, session, probe)
    }

    private static func settings(
        maxSteps: Int,
        networkAccess: Bool = false
    ) -> AgentSettings {
        var settings = AgentSettings()
        settings.maxSteps = maxSteps
        settings.networkAccess = networkAccess
        settings.autoRunTests = false
        return settings
    }

    private static func toolResponse(
        id: String,
        name: String,
        arguments: JSONValue = .emptyObject
    ) -> AgentModelResponse {
        AgentModelResponse(
            content: "",
            reasoningSummary: nil,
            toolCalls: [AgentToolCall(id: id, name: name, arguments: arguments)],
            finishReason: "tool_calls",
            usage: nil
        )
    }

    private static func finalResponse(_ content: String) -> AgentModelResponse {
        AgentModelResponse(
            content: content,
            reasoningSummary: nil,
            toolCalls: [],
            finishReason: "stop",
            usage: nil
        )
    }

    private static func submission(file: String) -> JSONValue {
        .object([
            "summary": .string("One actionable issue"),
            "findings": .array([.object([
                "severity": .string("high"),
                "file": .string(file),
                "line": .number(7),
                "explanation": .string("The value can become inconsistent."),
                "recommended_fix": .string("Validate it before committing state.")
            ])])
        ])
    }
}
