import Foundation
import XCTest

@testable import LumaChat

private actor ReviewIntegrationSessionStore: AgentSessionPersisting {
    private var values: [AgentSession]

    init(_ values: [AgentSession]) { self.values = values }

    func loadSessions() async throws -> [AgentSession] { values }

    func save(_ session: AgentSession) async throws {
        if let index = values.firstIndex(where: { $0.id == session.id }) {
            values[index] = session
        } else {
            values.append(session)
        }
    }

    func delete(id: UUID) async throws {
        values.removeAll { $0.id == id }
    }

    func presence(id: UUID) async -> AgentSessionPresence {
        values.contains(where: { $0.id == id }) ? .found : .absent
    }

    func session(id: UUID) -> AgentSession? {
        values.first { $0.id == id }
    }
}

private actor ReviewIntegrationProjectStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject] = []

    func loadProjects() async throws -> [AgentProject] { values }

    func saveProjects(_ projects: [AgentProject]) async throws {
        try AgentProjectCatalogValidation.validate(projects)
        values = projects
    }

    func touchProject(id: UUID, openedAt: Date) async throws {
        guard let index = values.firstIndex(where: { $0.id == id }),
              openedAt > values[index].lastOpenedAt else { return }
        values[index].lastOpenedAt = openedAt
    }

    func refreshFolder(
        projectID: UUID,
        folderID: UUID,
        workspace: AgentWorkspace,
        openedAt: Date
    ) async throws {
        guard let projectIndex = values.firstIndex(where: { $0.id == projectID }),
              let folderIndex = values[projectIndex].folders.firstIndex(where: {
                  $0.id == folderID
              }) else { return }
        values[projectIndex].folders[folderIndex].workspace = workspace
        values[projectIndex].folders[folderIndex].lastOpenedAt = openedAt
        values[projectIndex].lastOpenedAt = openedAt
    }
}

final class AgentViewModelReviewIntegrationTests: XCTestCase {
    @MainActor
    func testProductionReviewLoadsPersistsCommentsAndStagesUnstagesReverts() async throws {
        var phase = "fixture setup"
        do {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "review-production-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], at: root)
        try runGit(["config", "user.email", "review@example.invalid"], at: root)
        try runGit(["config", "user.name", "Review Test"], at: root)
        let file = root.appendingPathComponent("Feature.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try runGit(["add", "--", "Feature.swift"], at: root)
        try runGit(["commit", "-m", "base"], at: root)
        try Data("let value = 2\n".utf8).write(to: file)

        var session = AgentSession(mode: .plan)
        session.workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        session.model = "review-test-model"
        let store = ReviewIntegrationSessionStore([session])
        let viewModel = AgentViewModel(
            sessionStore: store,
            projectCatalogStore: ReviewIntegrationProjectStore()
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(
                at: AppPaths.agentSessions.appendingPathComponent(
                    session.id.uuidString,
                    isDirectory: true
                )
            )
        }

        phase = "restore project catalog"
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectedSessionID = session.id
        phase = "create production Review service"
        let service = try await viewModel.reviewService(for: session.id)

        phase = "load unstaged Review source"
        let unstaged = try await service.load(.unstaged)
        let changedFile = try XCTUnwrap(unstaged.files.first)
        phase = "persist inline Review comment"
        let comment = try await service.addComment(
            source: .unstaged,
            target: .line(path: "Feature.swift", side: .new, line: 1),
            body: "Keep the public value stable"
        )
        let persistedComment = await store.session(id: session.id)?.reviewComments?.first
        XCTAssertEqual(persistedComment, comment)

        let stageSelection = ReviewPatchSelection(
            fileID: changedFile.id,
            fileFingerprint: changedFile.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        phase = "build staging patch"
        let stagePatch = try await service.patch(
            source: .unstaged,
            selection: stageSelection,
            direction: .forward
        )
        phase = "stage Review selection"
        try await viewModel.performReviewMutation(
            ReviewMutationRequest(
                source: .unstaged,
                kind: .stage,
                target: .file(path: "Feature.swift", selection: stageSelection),
                patch: stagePatch
            ),
            sessionID: session.id
        )
        XCTAssertTrue(try gitOutput(["diff", "--cached", "--", "Feature.swift"], at: root)
            .contains("let value = 2"))
        XCTAssertFalse(viewModel.selectedSession?.changes.isEmpty ?? true)

        phase = "load staged Review source"
        let staged = try await service.load(.staged)
        let stagedFile = try XCTUnwrap(staged.files.first)
        let unstageSelection = ReviewPatchSelection(
            fileID: stagedFile.id,
            fileFingerprint: stagedFile.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        phase = "build unstaging patch"
        let unstagePatch = try await service.patch(
            source: .staged,
            selection: unstageSelection,
            direction: .reverse
        )
        phase = "unstage Review selection"
        try await viewModel.performReviewMutation(
            ReviewMutationRequest(
                source: .staged,
                kind: .unstage,
                target: .file(path: "Feature.swift", selection: unstageSelection),
                patch: unstagePatch
            ),
            sessionID: session.id
        )
        XCTAssertTrue(try gitOutput(["diff", "--cached", "--", "Feature.swift"], at: root)
            .isEmpty)

        phase = "reload unstaged Review source"
        let refreshed = try await service.load(.unstaged)
        let revertFile = try XCTUnwrap(refreshed.files.first)
        let revertSelection = ReviewPatchSelection(
            fileID: revertFile.id,
            fileFingerprint: revertFile.fingerprint,
            hunkID: nil,
            hunkFingerprint: nil
        )
        phase = "build revert patch"
        let revertPatch = try await service.patch(
            source: .unstaged,
            selection: revertSelection,
            direction: .reverse
        )
        let unconfirmed = ReviewMutationRequest(
            source: .unstaged,
            kind: .revert,
            target: .file(path: "Feature.swift", selection: revertSelection),
            patch: revertPatch
        )
        do {
            try await viewModel.performReviewMutation(unconfirmed, sessionID: session.id)
            XCTFail("A Review revert must require explicit confirmation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("explicit user confirmation"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 2\n")

        var confirmed = unconfirmed
        confirmed.userConfirmedDestructiveAction = true
        phase = "apply confirmed Review revert"
        try await viewModel.performReviewMutation(confirmed, sessionID: session.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
        await viewModel.shutdown()
        } catch {
            XCTFail("Review integration failed during \(phase): \(error.localizedDescription)")
            throw error
        }
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let output = try gitOutput(arguments, at: root)
        _ = output
    }

    private func gitOutput(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "AgentViewModelReviewIntegrationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr]
            )
        }
        return stdout
    }
}
