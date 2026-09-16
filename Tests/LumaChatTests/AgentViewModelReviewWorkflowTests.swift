import Foundation
import XCTest

@testable import LumaChat

private actor ReviewWorkflowViewModelSessionStore: AgentSessionPersisting {
    private var values: [AgentSession]
    private var snapshots: [AgentSession] = []

    init(_ values: [AgentSession]) {
        self.values = values
    }

    func loadSessions() async throws -> [AgentSession] { values }

    func save(_ session: AgentSession) async throws {
        snapshots.append(session)
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
        values.first(where: { $0.id == id })
    }

    func savedReviewTasks() -> [AgentSession] {
        snapshots.filter {
            if case .review = $0.resolvedTaskType { return true }
            return false
        }
    }
}

private actor ReviewWorkflowViewModelProjectStore: AgentProjectCatalogPersisting {
    private var values: [AgentProject]

    init(_ values: [AgentProject]) {
        self.values = values
    }

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

private actor ReviewWorkflowViewModelSettingsStore: AgentSettingsPersisting {
    private var value: AgentSettings

    init(_ value: AgentSettings = AgentSettings()) {
        self.value = value
    }

    func load() async throws -> AgentSettings { value }
    func save(_ settings: AgentSettings) async throws { value = settings }
}

final class AgentViewModelReviewWorkflowTests: XCTestCase {
    @MainActor
    func testStartReviewWorkflowPersistsSeparateLockedTaskAndStartsImmediately() async throws {
        let fixture = try makeFixture(label: "start")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let workspace = try XCTUnwrap(fixture.source.workspace)
        let captureEnvironment = BuiltinToolEnvironment()
        let captureGit = try await captureEnvironment.gitService(for: AgentToolContext(
            sessionID: fixture.source.id,
            mode: fixture.source.mode,
            workspace: workspace
        ))
        var durableSource = fixture.source
        let baseline = try await captureGit.captureAgentTurnReviewBaseline(
            runID: UUID(),
            sessionID: fixture.source.id
        )
        durableSource.lastAgentTurnReviewSnapshot = try await captureGit
            .finalizeAgentTurnReviewSnapshot(since: baseline)
        try await fixture.sessionStore.save(durableSource)
        await viewModel.start()

        let sourceBefore = try XCTUnwrap(
            viewModel.sessions.first(where: { $0.id == fixture.source.id })
        )
        let context = reviewContext(
            source: .lastAgentTurn(taskID: sourceBefore.id),
            path: "Sources/Feature.swift"
        )
        let request = ReviewWorkflowRequest(
            workflow: .changes,
            sourceContext: context
        )

        do {
            try await viewModel.startReviewWorkflow(
                request,
                sessionID: sourceBefore.id,
                route: fixture.route,
                apiKey: ""
            )
        } catch {
            await viewModel.shutdown()
            throw error
        }

        guard let review = viewModel.sessions.first(where: { session in
            if case .review = session.resolvedTaskType { return true }
            return false
        }) else {
            XCTFail("Starting a workflow must create a separate Review Task")
            await viewModel.shutdown()
            return
        }

        XCTAssertNotEqual(review.id, sourceBefore.id)
        XCTAssertEqual(review.mode, .plan)
        XCTAssertTrue(
            review.state == .idle || review.state == .running,
            "Runtime may publish its running transition immediately after durable creation"
        )
        XCTAssertEqual(
            review.resolvedTaskType,
            .review(sourceSessionID: sourceBefore.id, request: request)
        )
        XCTAssertNil(review.reviewResult)
        XCTAssertEqual(review.workspace, sourceBefore.workspace)
        XCTAssertEqual(review.executionLocation, sourceBefore.executionLocation)
        XCTAssertEqual(review.localWorkspace, sourceBefore.localWorkspace)
        XCTAssertEqual(review.localProjectFolderID, sourceBefore.localProjectFolderID)
        XCTAssertEqual(
            review.localCheckoutBaselineFingerprint,
            sourceBefore.localCheckoutBaselineFingerprint
        )
        XCTAssertEqual(
            review.localCheckoutBaselineSupplementalPaths,
            sourceBefore.localCheckoutBaselineSupplementalPaths
        )
        XCTAssertEqual(
            review.localCheckoutBaselineReference,
            sourceBefore.localCheckoutBaselineReference
        )
        XCTAssertEqual(review.projectID, sourceBefore.projectID)
        XCTAssertEqual(review.projectFolderID, sourceBefore.projectFolderID)
        XCTAssertEqual(review.connection, sourceBefore.connection)
        XCTAssertEqual(review.provider, sourceBefore.provider)
        XCTAssertEqual(review.profileID, sourceBefore.profileID)
        XCTAssertEqual(review.model, sourceBefore.model)
        XCTAssertEqual(review.permissionAllowances, [])
        XCTAssertNil(review.lastAgentTurnReviewBaseline)
        XCTAssertNil(review.pendingAgentTurnReviewBaseline)
        XCTAssertEqual(
            review.lastAgentTurnReviewSnapshot,
            sourceBefore.lastAgentTurnReviewSnapshot
        )
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == sourceBefore.id }),
            sourceBefore,
            "Creating a Review Task must not mutate its source Task"
        )
        XCTAssertEqual(viewModel.selectedSessionID, review.id)
        XCTAssertEqual(viewModel.activeMode, .plan)
        XCTAssertTrue(
            viewModel.isRunning(sessionID: review.id),
            "The durable Review Task must be handed to Runtime before start returns"
        )
        XCTAssertFalse(viewModel.isRunning(sessionID: sourceBefore.id))

        let durableReviews = await fixture.sessionStore.savedReviewTasks()
        let firstDurableReview = try XCTUnwrap(durableReviews.first)
        XCTAssertEqual(firstDurableReview.id, review.id)
        XCTAssertEqual(firstDurableReview.mode, .plan)
        XCTAssertEqual(firstDurableReview.state, .idle)
        XCTAssertEqual(firstDurableReview.resolvedTaskType, review.resolvedTaskType)
        XCTAssertEqual(firstDurableReview.workspace, sourceBefore.workspace)
        XCTAssertEqual(firstDurableReview.executionLocation, sourceBefore.executionLocation)

        await viewModel.shutdown()
    }

    @MainActor
    func testFinishPromotesPendingBaselineAndFreezesOutPostRunEdits() async throws {
        let fixture = try makeFixture(label: "freeze")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = try XCTUnwrap(fixture.source.workspace)
        let environment = BuiltinToolEnvironment()
        let git = try await environment.gitService(for: AgentToolContext(
            sessionID: fixture.source.id,
            mode: .agent,
            workspace: workspace
        ))
        let runID = UUID()
        let baseline = try await git.captureAgentTurnReviewBaseline(
            runID: runID,
            sessionID: fixture.source.id
        )
        try Data("let feature = \"agent result\"\n".utf8).write(
            to: URL(fileURLWithPath: workspace.rootPath)
                .appendingPathComponent("Feature.swift")
        )

        var completed = fixture.source
        completed.state = .completed
        completed.pendingAgentTurnReviewBaseline = baseline
        fixture.viewModel.beginRunTracking(
            runID: runID,
            session: completed,
            userRequest: "Change Feature.swift"
        )
        await fixture.viewModel.finish(completed, runID: runID)

        let frozenSession = try XCTUnwrap(
            fixture.viewModel.sessions.first(where: { $0.id == completed.id })
        )
        XCTAssertNil(frozenSession.pendingAgentTurnReviewBaseline)
        let snapshot = try XCTUnwrap(frozenSession.lastAgentTurnReviewSnapshot)
        XCTAssertEqual(snapshot.runID, runID)
        XCTAssertTrue(snapshot.source.contains("agent result"))

        try Data("let feature = \"external after run\"\n".utf8).write(
            to: URL(fileURLWithPath: workspace.rootPath)
                .appendingPathComponent("Feature.swift")
        )
        let frozen = try await git.reviewSource(from: snapshot)
        XCTAssertTrue(frozen.output.contains("agent result"))
        XCTAssertFalse(frozen.output.contains("external after run"))
        await fixture.viewModel.shutdown()
    }

    @MainActor
    func testStartReviewWorkflowRejectsInvalidOrMutableSourcesAndProviderMismatch() async throws {
        let fixture = try makeFixture(label: "guards", sourceCount: 7)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        await viewModel.start()
        let loaded = Dictionary(uniqueKeysWithValues: viewModel.sessions.map { ($0.title, $0) })
        let route = fixture.route

        var nonGit = try XCTUnwrap(loaded["Source 1"])
        nonGit.workspace?.gitRepository = false
        await replace(nonGit, in: viewModel)
        await expectReviewStartFailure(
            viewModel,
            sourceID: nonGit.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            route: route
        )

        var archived = try XCTUnwrap(loaded["Source 2"])
        archived.archivedAt = Date()
        await replace(archived, in: viewModel)
        await expectReviewStartFailure(
            viewModel,
            sourceID: archived.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            route: route
        )

        var nested = try XCTUnwrap(loaded["Source 3"])
        nested.taskType = .review(
            sourceSessionID: fixture.source.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        await replace(nested, in: viewModel)
        await expectReviewStartFailure(
            viewModel,
            sourceID: nested.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            route: route
        )

        let wrongContextSource = try XCTUnwrap(loaded["Source 4"])
        await expectReviewStartFailure(
            viewModel,
            sourceID: wrongContextSource.id,
            request: ReviewWorkflowRequest(
                workflow: .changes,
                sourceContext: reviewContext(
                    source: .lastAgentTurn(taskID: UUID()),
                    path: "Sources/Feature.swift"
                )
            ),
            route: route
        )

        let providerSource = try XCTUnwrap(loaded["Source 5"])
        await expectReviewStartFailure(
            viewModel,
            sourceID: providerSource.id,
            request: ReviewWorkflowRequest(
                workflow: .pullRequest(PullRequestReference(
                    providerID: "gitlab",
                    repositoryID: "owner/repository",
                    pullRequestID: "42"
                )),
                sourceContext: nil
            ),
            route: route
        )

        var running = try XCTUnwrap(loaded["Source 6"])
        running.state = .running
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: running, userRequest: nil)
        await viewModel.handle(.sessionUpdated(running), runID: runID)
        await expectReviewStartFailure(
            viewModel,
            sourceID: running.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil),
            route: route
        )

        let missingBaseline = try XCTUnwrap(loaded["Source 7"])
        await expectReviewStartFailure(
            viewModel,
            sourceID: missingBaseline.id,
            request: ReviewWorkflowRequest(
                workflow: .changes,
                sourceContext: reviewContext(
                    source: .lastAgentTurn(taskID: missingBaseline.id),
                    path: "Sources/Feature.swift"
                )
            ),
            route: route
        )

        XCTAssertTrue(
            viewModel.sessions.allSatisfy {
                if case .coding = $0.resolvedTaskType { return true }
                return $0.id == nested.id
            },
            "Rejected starts must not leave a partially-created Review Task"
        )
        let savedReviewTasks = await fixture.sessionStore.savedReviewTasks()
        XCTAssertEqual(
            Set(savedReviewTasks.map(\.id)),
            Set([nested.id]),
            "Rejected starts must not durably create an additional Review Task"
        )
        await viewModel.shutdown()
    }

    @MainActor
    func testReviewTaskCannotExecutePlanOrAcquireCodingSurfaces() async throws {
        let fixture = try makeFixture(label: "surfaces")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var review = fixture.source
        review.mode = .plan
        review.state = .completed
        review.taskType = .review(
            sourceSessionID: UUID(),
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        let store = ReviewWorkflowViewModelSessionStore([review])
        let viewModel = isolatedViewModel(
            root: fixture.root,
            sessionStore: store,
            projectStore: ReviewWorkflowViewModelProjectStore([fixture.project])
        )
        try await viewModel.restoreProjectCatalogState()
        viewModel.selectedSessionID = review.id
        viewModel.activeMode = .plan

        viewModel.executePlan(route: fixture.route, apiKey: "")

        let unchanged = try XCTUnwrap(
            viewModel.sessions.first(where: { $0.id == review.id })
        )
        XCTAssertEqual(unchanged.mode, .plan)
        XCTAssertEqual(unchanged.state, .completed)
        XCTAssertFalse(viewModel.isRunning(sessionID: review.id))

        do {
            _ = try await viewModel.taskTerminalService(for: review.id)
            XCTFail("A dedicated Review Task must not acquire a Task Terminal")
        } catch {}
        do {
            _ = try await viewModel.reviewService(for: review.id)
            XCTFail("A dedicated Review Task must not reopen the mutable coding Review pane")
        } catch {}
        await viewModel.shutdown()
    }

    @MainActor
    func testReviewAndWritableRunsConflictBothWaysAndProtectSourceLifecycle() async throws {
        let fixture = try makeFixture(label: "concurrency", sourceCount: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.source
        var review = try XCTUnwrap(fixture.additionalSources.first)
        review.mode = .plan
        review.model = source.model
        review.taskType = .review(
            sourceSessionID: source.id,
            request: ReviewWorkflowRequest(workflow: .changes, sourceContext: nil)
        )
        let store = ReviewWorkflowViewModelSessionStore([source, review])
        let viewModel = isolatedViewModel(
            root: fixture.root,
            sessionStore: store,
            projectStore: ReviewWorkflowViewModelProjectStore([fixture.project])
        )
        try await viewModel.restoreProjectCatalogState()

        let reviewRunID = UUID()
        viewModel.beginRunTracking(runID: reviewRunID, session: review, userRequest: nil)
        await viewModel.handle(.sessionUpdated(review), runID: reviewRunID)
        viewModel.selectedSessionID = source.id
        viewModel.activeMode = .agent
        viewModel.draft = "mutate this checkout"
        XCTAssertFalse(viewModel.canSend, "An active Review must block a same-root writable Agent")

        await viewModel.setSessionArchived(id: source.id, archived: true)
        XCTAssertNil(
            viewModel.sessions.first(where: { $0.id == source.id })?.archivedAt,
            "The source Task must remain durable while its dependent Review is active"
        )
        await viewModel.deleteSession(id: source.id)
        XCTAssertTrue(viewModel.sessions.contains(where: { $0.id == source.id }))
        await viewModel.handoffSessionToWorktree(id: source.id)
        XCTAssertEqual(
            viewModel.sessions.first(where: { $0.id == source.id })?
                .resolvedExecutionLocation.kind,
            .local
        )

        review.state = .completed
        await viewModel.finish(review, runID: reviewRunID)

        var writable = try XCTUnwrap(
            viewModel.sessions.first(where: { $0.id == source.id })
        )
        writable.mode = .agent
        writable.state = .running
        let writableRunID = UUID()
        viewModel.beginRunTracking(
            runID: writableRunID,
            session: writable,
            userRequest: nil
        )
        await viewModel.handle(.sessionUpdated(writable), runID: writableRunID)
        viewModel.selectedSessionID = review.id
        viewModel.activeMode = .plan
        viewModel.draft = "re-run the review"
        XCTAssertFalse(viewModel.canSend, "A writable Agent must block a same-root Review")

        writable.state = .completed
        await viewModel.finish(writable, runID: writableRunID)
        await viewModel.shutdown()
    }

    private struct Fixture {
        var root: URL
        var source: AgentSession
        var additionalSources: [AgentSession]
        var project: AgentProject
        var route: AppSettings
        var sessionStore: ReviewWorkflowViewModelSessionStore
        var viewModel: AgentViewModel
    }

    @MainActor
    private func makeFixture(label: String, sourceCount: Int = 1) throws -> Fixture {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "review-workflow-vm-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.name", "Review Workflow Tests"], at: repository)
        try runGit(["config", "user.email", "review-workflow@example.invalid"], at: repository)
        try Data("let feature = true\n".utf8).write(
            to: repository.appendingPathComponent("Feature.swift")
        )
        try runGit(["add", "--", "Feature.swift"], at: repository)
        try runGit(["commit", "--no-gpg-sign", "-m", "fixture"], at: repository)

        let workspace = AgentWorkspace(
            name: repository.lastPathComponent,
            rootPath: repository.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: true,
            branch: "main"
        )
        let folder = AgentProjectFolder(workspace: workspace)
        let project = AgentProject(
            name: "Review Workflow Fixture",
            folders: [folder],
            primaryFolderID: folder.id
        )
        let route = AppSettings(
            provider: .ollama,
            endpoint: "http://127.0.0.1:9",
            selectedModel: "fixture-model",
            requestTimeout: 1
        )
        var sources: [AgentSession] = []
        for ordinal in 0..<sourceCount {
            var source = AgentSession(mode: .agent)
            source.title = "Source \(ordinal + 1)"
            source.workspace = workspace
            source.executionLocation = .local
            source.localWorkspace = workspace
            source.localProjectFolderID = folder.id
            source.localCheckoutBaselineFingerprint = "fixture-baseline"
            source.localCheckoutBaselineSupplementalPaths = ["Feature.swift"]
            source.localCheckoutBaselineReference = "refs/heads/main"
            source.projectID = project.id
            source.projectFolderID = folder.id
            source.model = "fixture-model"
            source.connection = AgentConnectionSnapshot(settings: route)
            source.provider = route.provider
            source.profileID = route.activeProfileID
            source.permissionAllowances = [AgentPermissionAllowance(
                toolID: "fixture",
                toolName: "fixture",
                category: AgentToolCategory.filesystem.rawValue,
                effectiveLevel: AgentPermissionLevel.read.rawValue,
                workspaceRoot: workspace.rootPath,
                argumentScope: nil
            )]
            sources.append(source)
        }
        let source = sources.removeFirst()
        let sessionStore = ReviewWorkflowViewModelSessionStore([source] + sources)
        let viewModel = isolatedViewModel(
            root: root,
            sessionStore: sessionStore,
            projectStore: ReviewWorkflowViewModelProjectStore([project])
        )
        return Fixture(
            root: root,
            source: source,
            additionalSources: sources,
            project: project,
            route: route,
            sessionStore: sessionStore,
            viewModel: viewModel
        )
    }

    @MainActor
    private func isolatedViewModel(
        root: URL,
        sessionStore: ReviewWorkflowViewModelSessionStore,
        projectStore: ReviewWorkflowViewModelProjectStore
    ) -> AgentViewModel {
        let worktreeRoot = root.appendingPathComponent("managed", isDirectory: true)
        let checkouts = worktreeRoot.appendingPathComponent("checkouts", isDirectory: true)
        let worktreeRegistry = WorktreeRegistry(
            registryFile: worktreeRoot.appendingPathComponent("registry.json"),
            managedRoot: checkouts
        )
        return AgentViewModel(
            sessionStore: sessionStore,
            projectCatalogStore: projectStore,
            settingsStore: ReviewWorkflowViewModelSettingsStore(),
            mcpSettingsStore: MCPSettingsStore(
                fileURL: root.appendingPathComponent("mcp.json")
            ),
            keychainStore: KeychainStore(
                service: "LumaChat.ReviewWorkflowTests.\(UUID().uuidString)"
            ),
            worktreeService: ManagedWorktreeService(
                registry: worktreeRegistry,
                managedRoot: checkouts
            ),
            handoffJournal: AgentTaskHandoffJournal(
                root: root.appendingPathComponent("handoffs", isDirectory: true)
            ),
            deletionJournal: AgentTaskDeletionJournal(
                root: root.appendingPathComponent("deletions", isDirectory: true)
            ),
            worktreeRecoveryStore: WorktreeStateRecoveryStore(
                root: root.appendingPathComponent("recovery", isDirectory: true)
            )
        )
    }

    @MainActor
    private func replace(_ session: AgentSession, in viewModel: AgentViewModel) async {
        let runID = UUID()
        viewModel.beginRunTracking(runID: runID, session: session, userRequest: nil)
        await viewModel.handle(.sessionUpdated(session), runID: runID)
        await viewModel.finish(session, runID: runID)
    }

    @MainActor
    private func expectReviewStartFailure(
        _ viewModel: AgentViewModel,
        sourceID: UUID,
        request: ReviewWorkflowRequest,
        route: AppSettings,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let originalCount = viewModel.sessions.count
        do {
            try await viewModel.startReviewWorkflow(
                request,
                sessionID: sourceID,
                route: route,
                apiKey: ""
            )
            XCTFail("Expected Review workflow start to fail", file: file, line: line)
        } catch {}
        XCTAssertEqual(viewModel.sessions.count, originalCount, file: file, line: line)
    }

    private func reviewContext(source: ReviewSource, path: String) -> ReviewAgentContext {
        ReviewAgentContext(
            schemaVersion: ReviewAgentContext.currentSchemaVersion,
            source: source,
            files: [ReviewFileSummary(
                path: path,
                oldPath: nil,
                change: .modified,
                additions: 1,
                deletions: 1,
                hunkCount: 1,
                fallback: nil
            )],
            comments: [ReviewInlineComment(
                id: UUID(),
                source: source,
                target: .line(path: path, side: .new, line: 1),
                body: "Inspect this line",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "AgentViewModelReviewWorkflowTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
