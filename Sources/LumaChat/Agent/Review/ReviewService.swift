import Foundation

protocol ReviewSourceLoading: Sendable {
    func loadDiff(for source: ReviewSource) async throws -> ReviewRawDiff
}

/// Composition seam used by Git, task history, and tests. Each source remains a
/// separate typed operation instead of being converted into a shell argument.
struct ClosureReviewSourceLoader: ReviewSourceLoading, Sendable {
    typealias NoArgumentLoader = @Sendable () async throws -> ReviewRawDiff
    typealias CommitLoader = @Sendable (_ revision: String) async throws -> ReviewRawDiff
    typealias BranchLoader = @Sendable (
        _ baseRevision: String,
        _ headRevision: String
    ) async throws -> ReviewRawDiff
    typealias LastTurnLoader = @Sendable (_ taskID: UUID) async throws -> ReviewRawDiff

    var unstaged: NoArgumentLoader
    var staged: NoArgumentLoader
    var commit: CommitLoader
    var branch: BranchLoader
    var lastAgentTurn: LastTurnLoader

    func loadDiff(for source: ReviewSource) async throws -> ReviewRawDiff {
        switch source {
        case .unstaged:
            try await unstaged()
        case .staged:
            try await staged()
        case .commit(let revision):
            try await commit(revision)
        case .branch(let baseRevision, let headRevision):
            try await branch(baseRevision, headRevision)
        case .lastAgentTurn(let taskID):
            try await lastAgentTurn(taskID)
        }
    }
}

enum ReviewServiceError: LocalizedError, Equatable, Sendable {
    case sourceNotLoaded
    case invalidRevision(String)
    case fileNotFound(String)
    case invalidTarget(String)
    case invalidComment(String)
    case commentNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .sourceNotLoaded:
            "Load the Review source before using it."
        case .invalidRevision(let value):
            "Review revision is invalid: \(value)"
        case .fileNotFound(let path):
            "Review file is not present in this diff: \(path)"
        case .invalidTarget(let detail):
            "Review comment target is invalid: \(detail)"
        case .invalidComment(let detail):
            "Review comment is invalid: \(detail)"
        case .commentNotFound(let id):
            "Review comment does not exist: \(id.uuidString)"
        }
    }
}

actor ReviewService {
    typealias IDGenerator = @Sendable () -> UUID
    typealias Clock = @Sendable () -> Date
    typealias CommentPersistence = @Sendable ([ReviewInlineComment]) async throws -> Void

    private let loader: any ReviewSourceLoading
    private let parser: ReviewDiffParser
    private let presenter: ReviewPresentationBuilder
    private let patchBuilder: ReviewPatchBuilder
    private let idGenerator: IDGenerator
    private let clock: Clock
    private let commentPersistence: CommentPersistence
    private var documents: [ReviewSource: ReviewDocument] = [:]
    private var storedComments: [ReviewSource: [ReviewInlineComment]] = [:]

    init(
        loader: any ReviewSourceLoading,
        parser: ReviewDiffParser = ReviewDiffParser(),
        presenter: ReviewPresentationBuilder = ReviewPresentationBuilder(),
        patchBuilder: ReviewPatchBuilder = ReviewPatchBuilder(),
        idGenerator: @escaping IDGenerator = { UUID() },
        clock: @escaping Clock = { Date() },
        initialComments: [ReviewInlineComment] = [],
        commentPersistence: @escaping CommentPersistence = { _ in }
    ) {
        self.loader = loader
        self.parser = parser
        self.presenter = presenter
        self.patchBuilder = patchBuilder
        self.idGenerator = idGenerator
        self.clock = clock
        self.commentPersistence = commentPersistence
        for comment in initialComments.prefix(512) {
            storedComments[comment.source, default: []].append(comment)
        }
    }

    @discardableResult
    func load(_ source: ReviewSource) async throws -> ReviewDocument {
        try validate(source)
        let raw = try await loader.loadDiff(for: source)
        var document = try parser.parse(raw.text, source: source)
        document.generatedAt = raw.generatedAt
        documents[source] = document

        // A refreshed Git/index snapshot may invalidate old line and hunk
        // anchors. Never forward a stale target to the Agent.
        let previousComments = storedComments[source, default: []]
        storedComments[source] = previousComments.filter {
            (try? validate($0.target, in: document)) != nil
        }
        if storedComments[source] != previousComments {
            try await persistComments()
        }
        return document
    }

    func document(for source: ReviewSource) -> ReviewDocument? {
        documents[source]
    }

    func presentation(
        source: ReviewSource,
        fileID: String,
        style: ReviewDiffStyle
    ) throws -> ReviewFilePresentation {
        guard let document = documents[source] else {
            throw ReviewServiceError.sourceNotLoaded
        }
        guard let file = document.files.first(where: { $0.id == fileID }) else {
            throw ReviewServiceError.fileNotFound(fileID)
        }
        return presenter.make(file: file, style: style)
    }

    /// Produces a bounded file/hunk patch only when the caller's displayed
    /// fingerprints still match the latest loaded Review snapshot. The Git
    /// executor must additionally run `git apply --check` against its index or
    /// worktree immediately before mutation.
    func patch(
        source: ReviewSource,
        selection: ReviewPatchSelection,
        direction: ReviewPatchDirection
    ) throws -> ReviewPatchPayload {
        guard let document = documents[source] else {
            throw ReviewServiceError.sourceNotLoaded
        }
        guard let file = document.files.first(where: { $0.id == selection.fileID }) else {
            throw ReviewServiceError.fileNotFound(selection.fileID)
        }
        return try patchBuilder.make(
            file: file,
            expectedFileFingerprint: selection.fileFingerprint,
            hunkID: selection.hunkID,
            expectedHunkFingerprint: selection.hunkFingerprint,
            direction: direction
        )
    }

    /// Validates the UI's displayed identity for a file whose textual patch
    /// was intentionally unavailable. The Git layer repeats this validation
    /// against a freshly loaded source while holding its command gate.
    func fallbackFile(
        source: ReviewSource,
        path: String,
        selection: ReviewPatchSelection
    ) throws -> ReviewFileDiff {
        guard let document = documents[source] else {
            throw ReviewServiceError.sourceNotLoaded
        }
        guard selection.hunkID == nil, selection.hunkFingerprint == nil else {
            throw ReviewServiceError.invalidTarget(
                "fallback files do not support hunk actions"
            )
        }
        guard let file = document.files.first(where: { $0.id == selection.fileID }),
              file.fingerprint == selection.fileFingerprint,
              file.displayPath == path else {
            throw ReviewPatchError.staleFile
        }
        guard file.fallback != nil else {
            throw ReviewServiceError.invalidTarget(
                "file-level fallback action requires an unavailable textual diff"
            )
        }
        return file
    }

    @discardableResult
    func addComment(
        source: ReviewSource,
        target: ReviewCommentTarget,
        body: String
    ) async throws -> ReviewInlineComment {
        guard let document = documents[source] else {
            throw ReviewServiceError.sourceNotLoaded
        }
        let normalizedBody = try validatedCommentBody(body)
        try validate(target, in: document)
        let id = idGenerator()
        guard !storedComments.values.joined().contains(where: { $0.id == id }) else {
            throw ReviewServiceError.invalidComment("comment identity is duplicated")
        }
        let comment = ReviewInlineComment(
            id: id,
            source: source,
            target: target,
            body: normalizedBody,
            createdAt: clock()
        )
        var updated = storedComments[source, default: []]
        guard allComments().count < 512 else {
            throw ReviewServiceError.invalidComment("Task has reached the 512-comment limit")
        }
        updated.append(comment)
        let previous = storedComments[source]
        storedComments[source] = updated
        do {
            try await persistComments()
        } catch {
            storedComments[source] = previous
            throw error
        }
        return comment
    }

    func removeComment(source: ReviewSource, id: UUID) async throws {
        guard let index = storedComments[source]?.firstIndex(where: { $0.id == id }) else {
            throw ReviewServiceError.commentNotFound(id)
        }
        let previous = storedComments[source]
        storedComments[source]?.remove(at: index)
        do {
            try await persistComments()
        } catch {
            storedComments[source] = previous
            throw error
        }
    }

    func comments(for source: ReviewSource) -> [ReviewInlineComment] {
        storedComments[source, default: []]
    }

    func allComments() -> [ReviewInlineComment] {
        storedComments.values
            .flatMap { $0 }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func agentContext(for source: ReviewSource) throws -> ReviewAgentContext {
        guard let document = documents[source] else {
            throw ReviewServiceError.sourceNotLoaded
        }
        return ReviewAgentContext(
            schemaVersion: ReviewAgentContext.currentSchemaVersion,
            source: source,
            files: document.files.map(presenter.summary(for:)),
            comments: storedComments[source, default: []]
        )
    }

    func workflowRequest(
        _ workflow: ReviewWorkflow,
        source: ReviewSource?
    ) throws -> ReviewWorkflowRequest {
        let context = try source.map { try agentContext(for: $0) }
        return try ReviewWorkflowValidator().validated(ReviewWorkflowRequest(
            workflow: workflow,
            sourceContext: context
        ))
    }

    private func validate(_ source: ReviewSource) throws {
        switch source {
        case .unstaged, .staged, .lastAgentTurn:
            return
        case .commit(let revision):
            try validateRevision(revision)
        case .branch(let baseRevision, let headRevision):
            try validateRevision(baseRevision)
            try validateRevision(headRevision)
        }
    }

    private func validateRevision(_ revision: String) throws {
        guard !revision.isEmpty,
              revision == revision.trimmingCharacters(in: .whitespacesAndNewlines),
              revision.utf8.count <= 4_096,
              !revision.hasPrefix("-"),
              !revision.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ReviewServiceError.invalidRevision(revision)
        }
    }

    private func validatedCommentBody(_ body: String) throws -> String {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ReviewServiceError.invalidComment("body is empty")
        }
        guard value.utf8.count <= 16 * 1_024 else {
            throw ReviewServiceError.invalidComment("body exceeds 16 KiB")
        }
        let invalidControl = value.unicodeScalars.contains { scalar in
            scalar != "\n" && scalar != "\t"
                && CharacterSet.controlCharacters.contains(scalar)
        }
        guard !invalidControl else {
            throw ReviewServiceError.invalidComment("body contains control data")
        }
        return value
    }

    private func validate(
        _ target: ReviewCommentTarget,
        in document: ReviewDocument
    ) throws {
        guard let file = document.files.first(where: {
            $0.displayPath == target.path || $0.oldPath == target.path
        }) else {
            throw ReviewServiceError.fileNotFound(target.path)
        }
        switch target {
        case .file:
            return
        case .hunk(_, let hunkID):
            guard file.hunks.contains(where: { $0.id == hunkID }) else {
                throw ReviewServiceError.invalidTarget("hunk is not present in the file diff")
            }
        case .line(_, let side, let line):
            guard line > 0, contains(line: line, side: side, in: file) else {
                throw ReviewServiceError.invalidTarget("line is not visible on the selected side")
            }
        case .range(_, let side, let startLine, let endLine):
            guard startLine > 0, endLine >= startLine,
                  endLine - startLine <= 10_000 else {
                throw ReviewServiceError.invalidTarget("line range is invalid or too large")
            }
            for line in startLine...endLine where !contains(line: line, side: side, in: file) {
                throw ReviewServiceError.invalidTarget("line range contains a hidden line")
            }
        }
    }

    private func contains(
        line expected: Int,
        side: ReviewLineSide,
        in file: ReviewFileDiff
    ) -> Bool {
        file.hunks.contains { hunk in
            hunk.lines.contains { line in
                switch side {
                case .old: line.oldLineNumber == expected
                case .new: line.newLineNumber == expected
                }
            }
        }
    }

    private func persistComments() async throws {
        try await commentPersistence(allComments())
    }
}
