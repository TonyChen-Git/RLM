import Foundation
import XCTest
@testable import LumaChat

final class ReviewWorkflowCoreTests: XCTestCase {
    func testRequestValidationNormalizesNestedContextAndRejectsSourceMismatch() throws {
        let validator = ReviewWorkflowValidator()
        let source: ReviewSource = .commit(revision: "HEAD~1")
        let request = ReviewWorkflowRequest(
            workflow: .commit(revision: "HEAD~1"),
            sourceContext: Self.context(
                source: source,
                commentBody: "  password=hunter2 keep this stable  "
            )
        )

        let validated = try validator.validated(request)

        XCTAssertEqual(validated.workflow, .commit(revision: "HEAD~1"))
        XCTAssertEqual(
            validated.sourceContext?.comments.first?.body,
            "password=[REDACTED] keep this stable"
        )

        let mismatched = ReviewWorkflowRequest(
            workflow: .commit(revision: "HEAD"),
            sourceContext: Self.context(source: .unstaged)
        )
        XCTAssertThrowsError(try validator.validated(mismatched)) { error in
            guard case .invalidRequest(let detail) = error as? ReviewWorkflowValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("does not match"))
        }

        XCTAssertThrowsError(try validator.validated(ReviewWorkflowRequest(
            workflow: .branch(baseRevision: "main", headRevision: "main"),
            sourceContext: nil
        ))) { error in
            XCTAssertEqual(
                error as? ReviewWorkflowValidationError,
                .invalidRequest("branch base and head revisions must differ")
            )
        }
    }

    func testPullRequestRequestRejectsLocalContextTraversalAndSecretIdentity() throws {
        let validator = ReviewWorkflowValidator()
        let validReference = PullRequestReference(
            providerID: "github",
            repositoryID: "acme/luma",
            pullRequestID: "42"
        )
        XCTAssertEqual(
            try validator.validated(ReviewWorkflowRequest(
                workflow: .pullRequest(validReference),
                sourceContext: nil
            )).workflow,
            .pullRequest(validReference)
        )

        XCTAssertThrowsError(try validator.validated(ReviewWorkflowRequest(
            workflow: .pullRequest(validReference),
            sourceContext: Self.context(source: .unstaged)
        )))
        XCTAssertThrowsError(try validator.validated(ReviewWorkflowRequest(
            workflow: .pullRequest(PullRequestReference(
                providerID: "github",
                repositoryID: "../escape",
                pullRequestID: "42"
            )),
            sourceContext: nil
        )))
        XCTAssertThrowsError(try validator.validated(ReviewWorkflowRequest(
            workflow: .pullRequest(PullRequestReference(
                providerID: "github",
                repositoryID: "token=github_pat_abcdefghijklmnopqrstuvwxyz",
                pullRequestID: "42"
            )),
            sourceContext: nil
        ))) { error in
            XCTAssertEqual(
                error as? ReviewWorkflowValidationError,
                .secretBearingIdentity("repository ID")
            )
        }
    }

    func testResultValidationEnforcesLockedPathsHostIDsBoundsAndSecretSafety() throws {
        let validator = ReviewWorkflowValidator()
        let request = ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: Self.context(source: .unstaged)
        )
        let identifier = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let normalized = try validator.validated(ReviewWorkflowResult(
            findings: [ReviewFinding(
                id: identifier,
                severity: .high,
                file: "Sources/Value.swift",
                line: 7,
                explanation: "  token=github_pat_abcdefghijklmnopqrstuvwxyz is exposed  ",
                recommendedFix: "  Read it from Keychain.  "
            )],
            summary: "  Found one credential issue.  "
        ), for: request, allowedFiles: ["Sources/Value.swift"])

        XCTAssertEqual(normalized.summary, "Found one credential issue.")
        XCTAssertEqual(normalized.findings.first?.id, identifier)
        XCTAssertEqual(
            normalized.findings.first?.explanation,
            "token=[REDACTED] is exposed"
        )
        XCTAssertEqual(normalized.findings.first?.recommendedFix, "Read it from Keychain.")

        let outsideSource = ReviewWorkflowResult(
            findings: [ReviewFinding(
                id: UUID(),
                severity: .medium,
                file: "Sources/Other.swift",
                line: nil,
                explanation: "Outside the locked file set",
                recommendedFix: nil
            )],
            summary: "Invalid"
        )
        XCTAssertThrowsError(try validator.validated(
            outsideSource,
            for: request,
            allowedFiles: ["Sources/Value.swift"]
        )) { error in
            guard case .invalidFinding(let detail) = error as? ReviewWorkflowValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("locked Review source"))
        }

        let duplicateID = ReviewWorkflowResult(
            findings: [
                ReviewFinding(
                    id: identifier,
                    severity: .low,
                    file: "Sources/Value.swift",
                    line: 1,
                    explanation: "First",
                    recommendedFix: nil
                ),
                ReviewFinding(
                    id: identifier,
                    severity: .high,
                    file: "Sources/Value.swift",
                    line: 2,
                    explanation: "Second",
                    recommendedFix: nil
                )
            ],
            summary: "Invalid"
        )
        XCTAssertThrowsError(try validator.validated(
            duplicateID,
            for: request,
            allowedFiles: ["Sources/Value.swift"]
        )) { error in
            XCTAssertEqual(
                error as? ReviewWorkflowValidationError,
                .invalidResult("finding host UUID is duplicated")
            )
        }

        var tooMany = Self.context(source: .unstaged)
        tooMany.comments = (0...ReviewWorkflowLimits.maximumComments).map { index in
            ReviewInlineComment(
                id: UUID(),
                source: .unstaged,
                target: .file(path: "Sources/Value.swift"),
                body: "Comment \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        XCTAssertThrowsError(try validator.validated(ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: tooMany
        )))
    }

    func testServiceWorkflowRequestUsesStrictWorkflowValidation() async throws {
        let service = ReviewService(loader: WorkflowCoreSourceLoader())
        _ = try await service.load(.unstaged)

        do {
            _ = try await service.workflowRequest(
                .commit(revision: "HEAD"),
                source: .unstaged
            )
            XCTFail("Expected source/workflow mismatch")
        } catch let error as ReviewWorkflowValidationError {
            guard case .invalidRequest(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("does not match"))
        }
    }

    private static func context(
        source: ReviewSource,
        commentBody: String = "Keep the API stable"
    ) -> ReviewAgentContext {
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
            comments: [ReviewInlineComment(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                source: source,
                target: .line(path: "Sources/Value.swift", side: .new, line: 7),
                body: commentBody,
                createdAt: Date(timeIntervalSince1970: 123)
            )]
        )
    }
}

private struct WorkflowCoreSourceLoader: ReviewSourceLoading {
    func loadDiff(for source: ReviewSource) async throws -> ReviewRawDiff {
        ReviewRawDiff(text: """
        diff --git a/Sources/Value.swift b/Sources/Value.swift
        --- a/Sources/Value.swift
        +++ b/Sources/Value.swift
        @@ -7,1 +7,1 @@
        -let value = false
        +let value = true
        """)
    }
}
