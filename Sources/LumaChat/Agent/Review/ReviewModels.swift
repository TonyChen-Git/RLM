import Foundation

// MARK: - Sources

/// A Review source is a typed request. Revisions are data passed to a loader,
/// never command fragments; the production Git loader remains responsible for
/// invoking Git without a shell.
enum ReviewSource: Codable, Equatable, Hashable, Sendable {
    case unstaged
    case staged
    case commit(revision: String)
    case branch(baseRevision: String, headRevision: String)
    case lastAgentTurn(taskID: UUID)

    var title: String {
        switch self {
        case .unstaged:
            "Unstaged"
        case .staged:
            "Staged"
        case .commit(let revision):
            "Commit \(revision)"
        case .branch(let base, let head):
            "Branch \(base)…\(head)"
        case .lastAgentTurn:
            "Last Agent Turn"
        }
    }
}

struct ReviewRawDiff: Equatable, Sendable {
    var text: String
    var generatedAt: Date

    init(text: String, generatedAt: Date = Date()) {
        self.text = text
        self.generatedAt = generatedAt
    }
}

/// Durable pre-run state used to calculate the net workspace delta of one
/// coding Agent turn. Only files that were already dirty/untracked at the
/// boundary need embedded content; clean tracked files remain anchored to the
/// immutable start revision.
struct AgentTurnReviewFileBaseline: Codable, Equatable, Sendable {
    var path: String
    var existed: Bool
    var byteCount: Int64
    var permissions: Int?
    var sha256: String?
    /// Present only while the aggregate durable-content budget permits it.
    /// A digest-only baseline still produces a truthful file-level fallback.
    var data: Data?
}

struct AgentTurnReviewBaseline: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var runID: UUID
    var sessionID: UUID
    var capturedAt: Date
    var workspaceID: UUID
    var canonicalRootPath: String
    var rootDevice: UInt64
    var rootInode: UInt64
    var startRevision: String?
    var files: [AgentTurnReviewFileBaseline]
}

/// Immutable, workspace-bound Review source finalized at the end of one coding
/// run. Keeping the rendered source (and its digest) makes Last Agent Turn
/// independent of later edits to the checkout while retaining fail-closed
/// workspace and Task provenance checks.
struct AgentTurnReviewSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var runID: UUID
    var sessionID: UUID
    var finalizedAt: Date
    var workspaceID: UUID
    var canonicalRootPath: String
    var rootDevice: UInt64
    var rootInode: UInt64
    var source: String
    var sourceSHA256: String
    var truncated: Bool
}

// MARK: - Parsed diff

enum ReviewFileChangeKind: String, Codable, Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed
}

enum ReviewDiffFallback: Codable, Equatable, Sendable {
    case binary
    case large(byteCount: Int, limit: Int)
    case omitted(reason: String)
}

enum ReviewDiffLineKind: String, Codable, Equatable, Sendable {
    case context
    case addition
    case removal
}

enum ReviewLanguage: String, Codable, Equatable, Sendable {
    case swift
    case objectiveC
    case cFamily
    case javascript
    case typescript
    case python
    case ruby
    case shell
    case rust
    case go
    case java
    case kotlin
    case json
    case yaml
    case html
    case css
    case markdown
}

enum ReviewSyntaxRole: String, Codable, Equatable, Sendable {
    case keyword
    case string
    case number
    case comment
    case directive
}

/// UTF-16 offsets match NSString/AppKit ranges and stay stable when encoded.
struct ReviewSyntaxSpan: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var role: ReviewSyntaxRole
}

struct ReviewDiffLine: Codable, Equatable, Sendable {
    var kind: ReviewDiffLineKind
    var oldLineNumber: Int?
    var newLineNumber: Int?
    var text: String
    var syntax: [ReviewSyntaxSpan]
}

struct ReviewDiffHunk: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// Changes whenever this hunk's ranges or lines change. Mutating actions
    /// require the caller's previously observed value to prevent stale apply.
    var fingerprint: String
    var header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [ReviewDiffLine]
}

struct ReviewFileDiff: Codable, Equatable, Identifiable, Sendable {
    /// Stable for the old/new path pair so UI selection does not depend on
    /// process-local UUID generation.
    var id: String
    /// Changes with the complete raw file diff, including index/mode metadata.
    var fingerprint: String
    var oldPath: String?
    var newPath: String?
    var change: ReviewFileChangeKind
    var language: ReviewLanguage?
    var hunks: [ReviewDiffHunk]
    var fallback: ReviewDiffFallback?
    /// Set only by the host-generated marker that accompanies an untracked
    /// regular file. This is mutation provenance, not a filename heuristic.
    var isUntracked: Bool? = nil

    var displayPath: String { newPath ?? oldPath ?? id }

    var additionCount: Int {
        hunks.reduce(0) { result, hunk in
            result + hunk.lines.lazy.filter { $0.kind == .addition }.count
        }
    }

    var deletionCount: Int {
        hunks.reduce(0) { result, hunk in
            result + hunk.lines.lazy.filter { $0.kind == .removal }.count
        }
    }
}

struct ReviewDocument: Codable, Equatable, Sendable {
    var source: ReviewSource
    var files: [ReviewFileDiff]
    var generatedAt: Date
}

// MARK: - Presentation

enum ReviewDiffStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case file
    case unified
    case sideBySide
}

struct ReviewFileSummary: Codable, Equatable, Sendable {
    var path: String
    var oldPath: String?
    var change: ReviewFileChangeKind
    var additions: Int
    var deletions: Int
    var hunkCount: Int
    var fallback: ReviewDiffFallback?
}

struct ReviewUnifiedRow: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case hunkHeader
        case context
        case addition
        case removal
    }

    var kind: Kind
    var hunkID: String
    var oldLineNumber: Int?
    var newLineNumber: Int?
    var text: String
    var syntax: [ReviewSyntaxSpan]
}

struct ReviewDiffCell: Codable, Equatable, Sendable {
    var lineNumber: Int
    var text: String
    var kind: ReviewDiffLineKind
    var syntax: [ReviewSyntaxSpan]
}

struct ReviewSideBySideRow: Codable, Equatable, Sendable {
    var hunkID: String
    var left: ReviewDiffCell?
    var right: ReviewDiffCell?
}

struct ReviewFilePresentation: Codable, Equatable, Sendable {
    var style: ReviewDiffStyle
    var summary: ReviewFileSummary
    var unifiedRows: [ReviewUnifiedRow]
    var sideBySideRows: [ReviewSideBySideRow]
}

// MARK: - Structured comments and review-agent contract

enum ReviewLineSide: String, Codable, Equatable, Sendable {
    case old
    case new
}

enum ReviewCommentTarget: Codable, Equatable, Sendable {
    case file(path: String)
    case line(path: String, side: ReviewLineSide, line: Int)
    case range(path: String, side: ReviewLineSide, startLine: Int, endLine: Int)
    case hunk(path: String, hunkID: String)

    var path: String {
        switch self {
        case .file(let path), .line(let path, _, _), .range(let path, _, _, _),
             .hunk(let path, _):
            path
        }
    }
}

struct ReviewInlineComment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var source: ReviewSource
    var target: ReviewCommentTarget
    var body: String
    var createdAt: Date
}

/// This value is passed to an Agent as Codable structured context. The UI does
/// not flatten targets into prose, so file/line/range/hunk identity survives.
struct ReviewAgentContext: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var source: ReviewSource
    var files: [ReviewFileSummary]
    var comments: [ReviewInlineComment]
}

enum ReviewSeverity: String, Codable, CaseIterable, Equatable, Sendable {
    case note
    case low
    case medium
    case high
    case critical
}

struct ReviewFinding: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var severity: ReviewSeverity
    var file: String
    var line: Int?
    var explanation: String
    var recommendedFix: String?
}

typealias ReviewPullRequestReference = PullRequestReference

enum ReviewWorkflow: Codable, Equatable, Sendable {
    case changes
    case commit(revision: String)
    case branch(baseRevision: String, headRevision: String)
    case pullRequest(ReviewPullRequestReference)
}

struct ReviewWorkflowRequest: Codable, Equatable, Sendable {
    var workflow: ReviewWorkflow
    var sourceContext: ReviewAgentContext?
}

struct ReviewWorkflowResult: Codable, Equatable, Sendable {
    var findings: [ReviewFinding]
    var summary: String
}

/// Host-authenticated acknowledgement of the exact source a Review tool
/// exposed to the model. `sourceContext` is optional UI/comment context and is
/// deliberately not an authority boundary; Runtime uses these actual paths to
/// scope submitted findings.
struct ReviewWorkflowSourceReceipt: Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var workflow: ReviewWorkflow
    var filePaths: [String]
    /// SHA-256 of the complete redacted source plus its locked workflow/files.
    /// Consecutive pages must retain this identity.
    var sourceID: String
    var offset: Int
    var nextOffset: Int
    var totalBytes: Int
    var hasMore: Bool
    /// True only for semantic source omissions (for example a provider did not
    /// return a patch), not ordinary transport pagination.
    var truncated: Bool

    var isComplete: Bool {
        offset == 0 && nextOffset == totalBytes && !hasMore
    }
}

enum ReviewWorkflowLimits {
    static let maximumRequestBytes = 512 * 1_024
    static let maximumResultBytes = 384 * 1_024
    static let maximumFiles = 256
    static let maximumComments = 128
    static let maximumFindings = 128
    static let maximumPathBytes = 4_096
    static let maximumRevisionBytes = 4_096
    static let maximumExplanationBytes = 16 * 1_024
    static let maximumRecommendedFixBytes = 16 * 1_024
    static let maximumSummaryBytes = 16 * 1_024
    static let maximumLine = 10_000_000
}

enum ReviewWorkflowValidationError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidFinding(String)
    case invalidResult(String)
    case unsafePath(String)
    case secretBearingIdentity(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail):
            "Invalid Review workflow request: \(detail)"
        case .invalidFinding(let detail):
            "Invalid Review finding: \(detail)"
        case .invalidResult(let detail):
            "Invalid Review workflow result: \(detail)"
        case .unsafePath(let path):
            "Review workflow path is unsafe: \(path)"
        case .secretBearingIdentity(let field):
            "Review workflow identity contains secret-like data: \(field)"
        }
    }
}

/// The only validation boundary for Review-Agent context and structured
/// findings. It intentionally returns a normalized copy: human-authored text
/// is trimmed and secret-redacted, while identity-bearing values (revision,
/// provider identifiers, paths) are rejected rather than rewritten.
struct ReviewWorkflowValidator: Sendable {
    private let redactor = SecretRedactor()

    func validated(_ request: ReviewWorkflowRequest) throws -> ReviewWorkflowRequest {
        var copy = request
        copy.workflow = try validated(request.workflow)
        if let context = request.sourceContext {
            copy.sourceContext = try validated(context)
            try validateSourceContext(copy.sourceContext, matches: copy.workflow)
        } else {
            copy.sourceContext = nil
        }
        if case .pullRequest = copy.workflow, copy.sourceContext != nil {
            throw ReviewWorkflowValidationError.invalidRequest(
                "Pull Request workflows cannot carry an unrelated local diff context"
            )
        }
        try validateEncodedSize(
            copy,
            maximumBytes: ReviewWorkflowLimits.maximumRequestBytes,
            error: .invalidRequest("encoded request exceeds 512 KiB")
        )
        return copy
    }

    func validated(
        _ finding: ReviewFinding,
        allowedFiles: Set<String>? = nil
    ) throws -> ReviewFinding {
        guard finding.id != Self.zeroUUID else {
            throw ReviewWorkflowValidationError.invalidFinding("host UUID is empty")
        }
        let file = try validatedPath(finding.file)
        if let allowedFiles, !allowedFiles.contains(file) {
            throw ReviewWorkflowValidationError.invalidFinding(
                "file is outside the locked Review source"
            )
        }
        if let line = finding.line,
           !(1...ReviewWorkflowLimits.maximumLine).contains(line) {
            throw ReviewWorkflowValidationError.invalidFinding(
                "line must be between 1 and \(ReviewWorkflowLimits.maximumLine)"
            )
        }
        let explanation = try validatedText(
            finding.explanation,
            field: "explanation",
            maximumBytes: ReviewWorkflowLimits.maximumExplanationBytes,
            error: ReviewWorkflowValidationError.invalidFinding
        )
        let recommendedFix = try finding.recommendedFix.map {
            try validatedText(
                $0,
                field: "recommended fix",
                maximumBytes: ReviewWorkflowLimits.maximumRecommendedFixBytes,
                error: ReviewWorkflowValidationError.invalidFinding
            )
        }
        return ReviewFinding(
            id: finding.id,
            severity: finding.severity,
            file: file,
            line: finding.line,
            explanation: explanation,
            recommendedFix: recommendedFix
        )
    }

    func validated(
        _ result: ReviewWorkflowResult,
        for request: ReviewWorkflowRequest,
        allowedFiles: Set<String>? = nil
    ) throws -> ReviewWorkflowResult {
        _ = try validated(request)
        guard result.findings.count <= ReviewWorkflowLimits.maximumFindings else {
            throw ReviewWorkflowValidationError.invalidResult(
                "finding count exceeds \(ReviewWorkflowLimits.maximumFindings)"
            )
        }
        var identifiers = Set<UUID>()
        var signatures = Set<String>()
        let findings = try result.findings.map { finding in
            guard identifiers.insert(finding.id).inserted else {
                throw ReviewWorkflowValidationError.invalidResult(
                    "finding host UUID is duplicated"
                )
            }
            let copy = try validated(finding, allowedFiles: allowedFiles)
            let signature = [
                copy.severity.rawValue,
                copy.file,
                copy.line.map(String.init) ?? "",
                copy.explanation,
                copy.recommendedFix ?? ""
            ].joined(separator: "\u{001F}")
            guard signatures.insert(signature).inserted else {
                throw ReviewWorkflowValidationError.invalidResult(
                    "finding content is duplicated"
                )
            }
            return copy
        }
        let summary = try validatedText(
            result.summary,
            field: "summary",
            maximumBytes: ReviewWorkflowLimits.maximumSummaryBytes,
            error: ReviewWorkflowValidationError.invalidResult
        )
        let copy = ReviewWorkflowResult(findings: findings, summary: summary)
        try validateEncodedSize(
            copy,
            maximumBytes: ReviewWorkflowLimits.maximumResultBytes,
            error: .invalidResult("encoded result exceeds 384 KiB")
        )
        return copy
    }

    func validatedPath(_ path: String) throws -> String {
        let components = NSString(string: path).pathComponents
        guard !path.isEmpty,
              path.utf8.count <= ReviewWorkflowLimits.maximumPathBytes,
              !path.hasPrefix("/"),
              path != ".",
              !components.contains(".."),
              !components.contains("~"),
              !containsControl(path, allowingNewlinesAndTabs: false) else {
            throw ReviewWorkflowValidationError.unsafePath(path)
        }
        guard redactor.redact(path) == path else {
            throw ReviewWorkflowValidationError.secretBearingIdentity("file path")
        }
        return path
    }

    private func validated(_ workflow: ReviewWorkflow) throws -> ReviewWorkflow {
        switch workflow {
        case .changes:
            return .changes
        case .commit(let revision):
            return .commit(revision: try validatedRevision(revision))
        case .branch(let baseRevision, let headRevision):
            let base = try validatedRevision(baseRevision)
            let head = try validatedRevision(headRevision)
            guard base != head else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "branch base and head revisions must differ"
                )
            }
            return .branch(baseRevision: base, headRevision: head)
        case .pullRequest(let reference):
            return .pullRequest(try validated(reference))
        }
    }

    private func validated(_ reference: ReviewPullRequestReference) throws
        -> ReviewPullRequestReference {
        let provider = try validatedIdentity(
            reference.providerID,
            field: "provider ID",
            maximumBytes: 64,
            allowed: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "._-")
            )
        )
        let repository = try validatedOpaqueIdentity(
            reference.repositoryID,
            field: "repository ID",
            maximumBytes: 256
        )
        let pullRequest = try validatedOpaqueIdentity(
            reference.pullRequestID,
            field: "Pull Request ID",
            maximumBytes: 128
        )
        return ReviewPullRequestReference(
            providerID: provider,
            repositoryID: repository,
            pullRequestID: pullRequest
        )
    }

    private func validated(_ context: ReviewAgentContext) throws -> ReviewAgentContext {
        guard context.schemaVersion == ReviewAgentContext.currentSchemaVersion else {
            throw ReviewWorkflowValidationError.invalidRequest(
                "unsupported source-context schema version"
            )
        }
        guard context.files.count <= ReviewWorkflowLimits.maximumFiles else {
            throw ReviewWorkflowValidationError.invalidRequest(
                "source context exceeds \(ReviewWorkflowLimits.maximumFiles) files"
            )
        }
        guard context.comments.count <= ReviewWorkflowLimits.maximumComments else {
            throw ReviewWorkflowValidationError.invalidRequest(
                "source context exceeds \(ReviewWorkflowLimits.maximumComments) comments"
            )
        }
        let source = try validated(context.source)
        var filePaths = Set<String>()
        var files: [ReviewFileSummary] = []
        files.reserveCapacity(context.files.count)
        for summary in context.files {
            let path = try validatedPath(summary.path)
            guard filePaths.insert(path).inserted else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "source context contains duplicate file paths"
                )
            }
            let oldPath = try summary.oldPath.map(validatedPath)
            guard summary.additions >= 0,
                  summary.deletions >= 0,
                  summary.hunkCount >= 0,
                  summary.additions <= ReviewWorkflowLimits.maximumLine,
                  summary.deletions <= ReviewWorkflowLimits.maximumLine,
                  summary.hunkCount <= ReviewWorkflowLimits.maximumLine else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "source context contains invalid file counters"
                )
            }
            files.append(ReviewFileSummary(
                path: path,
                oldPath: oldPath,
                change: summary.change,
                additions: summary.additions,
                deletions: summary.deletions,
                hunkCount: summary.hunkCount,
                fallback: try validated(summary.fallback)
            ))
        }

        var commentIDs = Set<UUID>()
        let knownPaths = Set(files.flatMap { summary in
            [summary.path] + (summary.oldPath.map { [$0] } ?? [])
        })
        let comments = try context.comments.map { comment -> ReviewInlineComment in
            guard comment.source == source else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "comment source does not match its source context"
                )
            }
            guard comment.id != Self.zeroUUID, commentIDs.insert(comment.id).inserted else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "comment host UUID is empty or duplicated"
                )
            }
            let target = try validated(comment.target, knownPaths: knownPaths)
            let body = try validatedText(
                comment.body,
                field: "comment body",
                maximumBytes: ReviewWorkflowLimits.maximumExplanationBytes,
                error: ReviewWorkflowValidationError.invalidRequest
            )
            return ReviewInlineComment(
                id: comment.id,
                source: source,
                target: target,
                body: body,
                createdAt: comment.createdAt
            )
        }
        return ReviewAgentContext(
            schemaVersion: ReviewAgentContext.currentSchemaVersion,
            source: source,
            files: files,
            comments: comments
        )
    }

    private func validated(_ source: ReviewSource) throws -> ReviewSource {
        switch source {
        case .unstaged:
            return .unstaged
        case .staged:
            return .staged
        case .commit(let revision):
            return .commit(revision: try validatedRevision(revision))
        case .branch(let baseRevision, let headRevision):
            let base = try validatedRevision(baseRevision)
            let head = try validatedRevision(headRevision)
            guard base != head else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "source branch base and head revisions must differ"
                )
            }
            return .branch(baseRevision: base, headRevision: head)
        case .lastAgentTurn(let taskID):
            guard taskID != Self.zeroUUID else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "last-Agent-turn task UUID is empty"
                )
            }
            return .lastAgentTurn(taskID: taskID)
        }
    }

    private func validateSourceContext(
        _ context: ReviewAgentContext?,
        matches workflow: ReviewWorkflow
    ) throws {
        guard let context else { return }
        let matches: Bool
        switch (workflow, context.source) {
        case (.changes, .unstaged), (.changes, .staged), (.changes, .lastAgentTurn):
            matches = true
        case (.commit(let left), .commit(let right)):
            matches = left == right
        case (
            .branch(let leftBase, let leftHead),
            .branch(let rightBase, let rightHead)
        ):
            matches = leftBase == rightBase && leftHead == rightHead
        case (.pullRequest, _):
            matches = false
        default:
            matches = false
        }
        guard matches else {
            throw ReviewWorkflowValidationError.invalidRequest(
                "source context does not match the locked workflow"
            )
        }
    }

    private func validated(_ target: ReviewCommentTarget, knownPaths: Set<String>) throws
        -> ReviewCommentTarget {
        let path = try validatedPath(target.path)
        guard knownPaths.contains(path) else {
            throw ReviewWorkflowValidationError.invalidRequest(
                "comment path is outside its source context"
            )
        }
        switch target {
        case .file:
            return .file(path: path)
        case .line(_, let side, let line):
            guard (1...ReviewWorkflowLimits.maximumLine).contains(line) else {
                throw ReviewWorkflowValidationError.invalidRequest("comment line is invalid")
            }
            return .line(path: path, side: side, line: line)
        case .range(_, let side, let startLine, let endLine):
            guard startLine >= 1,
                  endLine >= startLine,
                  endLine <= ReviewWorkflowLimits.maximumLine,
                  endLine - startLine <= 10_000 else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "comment line range is invalid"
                )
            }
            return .range(
                path: path,
                side: side,
                startLine: startLine,
                endLine: endLine
            )
        case .hunk(_, let hunkID):
            let identifier = try validatedOpaqueIdentity(
                hunkID,
                field: "hunk ID",
                maximumBytes: 512
            )
            return .hunk(path: path, hunkID: identifier)
        }
    }

    private func validated(_ fallback: ReviewDiffFallback?) throws -> ReviewDiffFallback? {
        guard let fallback else { return nil }
        switch fallback {
        case .binary:
            return .binary
        case .large(let byteCount, let limit):
            guard byteCount >= 0, limit > 0, byteCount > limit else {
                throw ReviewWorkflowValidationError.invalidRequest(
                    "large-file fallback counters are invalid"
                )
            }
            return fallback
        case .omitted(let reason):
            return .omitted(reason: try validatedText(
                reason,
                field: "fallback reason",
                maximumBytes: 4_096,
                error: ReviewWorkflowValidationError.invalidRequest
            ))
        }
    }

    private func validatedRevision(_ revision: String) throws -> String {
        guard !revision.isEmpty,
              revision == revision.trimmingCharacters(in: .whitespacesAndNewlines),
              revision.utf8.count <= ReviewWorkflowLimits.maximumRevisionBytes,
              !revision.hasPrefix("-"),
              !containsControl(revision, allowingNewlinesAndTabs: false),
              redactor.redact(revision) == revision else {
            throw ReviewWorkflowValidationError.invalidRequest("revision is malformed")
        }
        return revision
    }

    private func validatedIdentity(
        _ value: String,
        field: String,
        maximumBytes: Int,
        allowed: CharacterSet
    ) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy(allowed.contains),
              redactor.redact(value) == value else {
            throw ReviewWorkflowValidationError.invalidRequest("\(field) is malformed")
        }
        return value
    }

    private func validatedOpaqueIdentity(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("-"),
              !containsControl(value, allowingNewlinesAndTabs: false),
              !NSString(string: value).pathComponents.contains("..") else {
            throw ReviewWorkflowValidationError.invalidRequest("\(field) is malformed")
        }
        guard redactor.redact(value) == value else {
            throw ReviewWorkflowValidationError.secretBearingIdentity(field)
        }
        return value
    }

    private func validatedText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        error: (String) -> ReviewWorkflowValidationError
    ) throws -> String {
        let copy = redactor.redact(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !copy.isEmpty else { throw error("\(field) is empty") }
        guard copy.utf8.count <= maximumBytes else {
            throw error("\(field) exceeds \(maximumBytes) bytes")
        }
        guard !containsControl(copy, allowingNewlinesAndTabs: true) else {
            throw error("\(field) contains control data")
        }
        return copy
    }

    private func containsControl(
        _ value: String,
        allowingNewlinesAndTabs: Bool
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            if allowingNewlinesAndTabs, scalar == "\n" || scalar == "\t" { return false }
            return CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private func validateEncodedSize<Value: Encodable>(
        _ value: Value,
        maximumBytes: Int,
        error: ReviewWorkflowValidationError
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), data.count <= maximumBytes else {
            throw error
        }
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}
