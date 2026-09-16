import Foundation
import XCTest

@testable import LumaChat

final class ReviewPaneModelTests: XCTestCase {
    @MainActor
    func testModelKeepsStructuredCommentsAndSendsTypedAgentContext() async throws {
        let diff = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        index 1111111..2222222 100644
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1,2 +1,2 @@
        -let value = 1
        +let value = 2
         print(value)
        """
        let loader = reviewPaneLoader(diff: diff)
        let service = ReviewService(loader: loader)
        let mutations = ReviewMutationRecorder()
        let contexts = ReviewContextRecorder()
        let model = ReviewPaneModel(
            service: service,
            actionHandler: ClosureReviewActionHandler { request in
                await mutations.append(request)
            },
            contextSender: ClosureReviewAgentContextSender { context in
                await contexts.append(context)
            }
        )

        await model.load(.unstaged)
        XCTAssertEqual(model.document?.files.count, 1)
        XCTAssertEqual(model.selectedFile?.displayPath, "Sources/Feature.swift")
        XCTAssertEqual(model.presentation?.style, .unified)
        XCTAssertEqual(model.presentation?.unifiedRows.count, 4)

        await model.setStyle(.sideBySide)
        XCTAssertEqual(model.presentation?.style, .sideBySide)
        XCTAssertEqual(model.presentation?.sideBySideRows.count, 2)

        await model.addComment(
            target: .range(
                path: "Sources/Feature.swift",
                side: .new,
                startLine: 1,
                endLine: 2
            ),
            body: "  Preserve the typed range anchor.  "
        )
        XCTAssertEqual(model.comments.count, 1)
        XCTAssertEqual(model.comments.first?.body, "Preserve the typed range anchor.")

        await model.sendToAgent()
        let sentContexts = await contexts.values()
        XCTAssertEqual(sentContexts.count, 1)
        XCTAssertEqual(sentContexts.first?.schemaVersion, ReviewAgentContext.currentSchemaVersion)
        XCTAssertEqual(sentContexts.first?.source, .unstaged)
        XCTAssertEqual(sentContexts.first?.comments, model.comments)
        guard case .range(let path, let side, let start, let end) =
                sentContexts.first?.comments.first?.target else {
            return XCTFail("Expected a typed range comment target")
        }
        XCTAssertEqual(path, "Sources/Feature.swift")
        XCTAssertEqual(side, .new)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(end, 2)

        guard let selectedFile = model.selectedFile else {
            return XCTFail("Expected selected file")
        }
        let intent = ReviewMutationIntent(
            source: .unstaged,
            kind: .stage,
            target: .file(
                path: "Sources/Feature.swift",
                selection: ReviewPatchSelection(
                    fileID: selectedFile.id,
                    fileFingerprint: selectedFile.fingerprint,
                    hunkID: nil,
                    hunkFingerprint: nil
                )
            )
        )
        await model.perform(intent)
        let recordedMutations = await mutations.values()
        XCTAssertEqual(recordedMutations.count, 1)
        XCTAssertEqual(recordedMutations.first?.source, .unstaged)
        XCTAssertEqual(recordedMutations.first?.kind, .stage)
        XCTAssertEqual(recordedMutations.first?.target, intent.target)
        XCTAssertEqual(recordedMutations.first?.patch?.selection, intent.target.selection)
        XCTAssertEqual(recordedMutations.first?.patch?.direction, .forward)
        XCTAssertTrue(recordedMutations.first?.patch?.unifiedDiff.contains("@@ -1,2 +1,2 @@") == true)
        XCTAssertFalse(model.isMutating)

        let staleIntent = ReviewMutationIntent(
            source: .unstaged,
            kind: .revert,
            target: .file(
                path: "Sources/Feature.swift",
                selection: ReviewPatchSelection(
                    fileID: selectedFile.id,
                    fileFingerprint: "stale-ui-fingerprint",
                    hunkID: nil,
                    hunkFingerprint: nil
                )
            )
        )
        await model.perform(staleIntent)
        let mutationCountAfterStaleIntent = await mutations.count()
        XCTAssertEqual(mutationCountAfterStaleIntent, 1)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testModelExposesBinaryFallbackWithoutInventingTextRows() async throws {
        let diff = """
        diff --git a/Assets/icon.png b/Assets/icon.png
        index 1111111..2222222 100644
        Binary files a/Assets/icon.png and b/Assets/icon.png differ
        """
        let service = ReviewService(loader: reviewPaneLoader(diff: diff))
        let model = ReviewPaneModel(service: service)

        await model.load(.staged)

        XCTAssertEqual(model.selectedFile?.displayPath, "Assets/icon.png")
        XCTAssertEqual(model.selectedFile?.fallback, .binary)
        XCTAssertEqual(model.presentation?.unifiedRows, [])
        XCTAssertEqual(model.presentation?.sideBySideRows, [])
    }

    @MainActor
    func testModelStartsTypedChangesWorkflowWithLoadedStructuredContext() async throws {
        let diff = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1 +1 @@
        -let enabled = false
        +let enabled = true
        """
        let workflows = ReviewWorkflowRecorder()
        let model = ReviewPaneModel(
            service: ReviewService(loader: reviewPaneLoader(diff: diff)),
            workflowStarter: ClosureReviewWorkflowStarter { request in
                await workflows.append(request)
            }
        )

        await model.load(.unstaged)
        await model.addComment(
            target: .line(path: "Sources/Feature.swift", side: .new, line: 1),
            body: "Verify callers expect this default."
        )
        await model.startWorkflow(.changes, includingSource: .unstaged)

        let requests = await workflows.values()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.workflow, .changes)
        XCTAssertEqual(requests.first?.sourceContext?.source, .unstaged)
        XCTAssertEqual(requests.first?.sourceContext?.comments.count, 1)
        XCTAssertEqual(
            requests.first?.sourceContext?.comments.first?.target,
            .line(path: "Sources/Feature.swift", side: .new, line: 1)
        )
        XCTAssertFalse(model.isStartingWorkflow)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testModelNormalizesPRWorkflowAndRejectsUnsafeRevision() async throws {
        let workflows = ReviewWorkflowRecorder()
        let model = ReviewPaneModel(
            service: ReviewService(loader: reviewPaneLoader(diff: "")),
            workflowStarter: ClosureReviewWorkflowStarter { request in
                await workflows.append(request)
            }
        )

        await model.startWorkflow(.pullRequest(ReviewPullRequestReference(
            providerID: " GitHub ",
            repositoryID: " owner/repository ",
            pullRequestID: " 42 "
        )))

        var requests = await workflows.values()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.workflow,
            .pullRequest(ReviewPullRequestReference(
                providerID: "github",
                repositoryID: "owner/repository",
                pullRequestID: "42"
            ))
        )
        XCTAssertNil(requests.first?.sourceContext)

        await model.startWorkflow(.commit(revision: "--upload-pack=malicious"))
        requests = await workflows.values()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("cannot start with '-'") == true)
        XCTAssertFalse(model.isStartingWorkflow)
    }

    func testFindingsSortCriticalThroughNoteThenByLocation() {
        let findings = [
            ReviewFinding(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                severity: .note,
                file: "Z.swift",
                line: nil,
                explanation: "note",
                recommendedFix: nil
            ),
            ReviewFinding(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                severity: .high,
                file: "B.swift",
                line: 20,
                explanation: "high b",
                recommendedFix: nil
            ),
            ReviewFinding(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                severity: .critical,
                file: "A.swift",
                line: 3,
                explanation: "critical",
                recommendedFix: "fix"
            ),
            ReviewFinding(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                severity: .high,
                file: "A.swift",
                line: 10,
                explanation: "high a",
                recommendedFix: nil
            ),
            ReviewFinding(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                severity: .medium,
                file: "A.swift",
                line: 1,
                explanation: "medium",
                recommendedFix: nil
            )
        ]

        let sorted = ReviewFindingsPresentation.sorted(findings)

        XCTAssertEqual(sorted.map(\.severity), [.critical, .high, .high, .medium, .note])
        XCTAssertEqual(sorted.map(\.explanation), [
            "critical", "high a", "high b", "medium", "note"
        ])
    }
}

private func reviewPaneLoader(diff: String) -> ClosureReviewSourceLoader {
    let operation: ClosureReviewSourceLoader.NoArgumentLoader = {
        ReviewRawDiff(text: diff, generatedAt: Date(timeIntervalSince1970: 123))
    }
    return ClosureReviewSourceLoader(
        unstaged: operation,
        staged: operation,
        commit: { _ in try await operation() },
        branch: { _, _ in try await operation() },
        lastAgentTurn: { _ in try await operation() }
    )
}

private actor ReviewMutationRecorder {
    private var recorded: [ReviewMutationRequest] = []

    func append(_ request: ReviewMutationRequest) {
        recorded.append(request)
    }

    func values() -> [ReviewMutationRequest] { recorded }
    func count() -> Int { recorded.count }
}

private actor ReviewContextRecorder {
    private var recorded: [ReviewAgentContext] = []

    func append(_ context: ReviewAgentContext) {
        recorded.append(context)
    }

    func values() -> [ReviewAgentContext] { recorded }
}

private actor ReviewWorkflowRecorder {
    private var recorded: [ReviewWorkflowRequest] = []

    func append(_ request: ReviewWorkflowRequest) {
        recorded.append(request)
    }

    func values() -> [ReviewWorkflowRequest] { recorded }
}
