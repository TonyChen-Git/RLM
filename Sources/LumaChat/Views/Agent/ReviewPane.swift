import AppKit
import Combine
import SwiftUI

enum ReviewMutationKind: String, Codable, Equatable, Sendable {
    case stage
    case unstage
    case revert

    var title: String {
        switch self {
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .revert: "Revert"
        }
    }

    var isDestructive: Bool { self == .revert }
}

enum ReviewMutationTarget: Codable, Equatable, Sendable {
    case file(path: String, selection: ReviewPatchSelection)
    case hunk(path: String, selection: ReviewPatchSelection)

    var path: String {
        switch self {
        case .file(let path, _), .hunk(let path, _): path
        }
    }

    var selection: ReviewPatchSelection {
        switch self {
        case .file(_, let selection), .hunk(_, let selection): selection
        }
    }
}

/// UI-to-Git seam. `ReviewPaneModel` obtains the fingerprint-validated patch
/// from `ReviewService`; a production handler owns repository validation,
/// apply-check, mutation, Undo, and runtime approval. The pane never executes
/// Git or a shell.
struct ReviewMutationRequest: Codable, Equatable, Sendable {
    var source: ReviewSource
    var kind: ReviewMutationKind
    var target: ReviewMutationTarget
    /// Textual files carry a bounded patch. Binary/large/omitted files carry
    /// only the displayed file identity and are handled by the closed path API.
    var patch: ReviewPatchPayload? = nil
    /// Revert is rejected by the production handler unless the pane's
    /// destructive confirmation dialog supplied this explicit user decision.
    var userConfirmedDestructiveAction = false
}

struct ReviewMutationIntent: Codable, Equatable, Sendable {
    var source: ReviewSource
    var kind: ReviewMutationKind
    var target: ReviewMutationTarget
}

protocol ReviewActionHandling: Sendable {
    var isAvailable: Bool { get }
    func perform(_ request: ReviewMutationRequest) async throws
}

extension ReviewActionHandling {
    var isAvailable: Bool { true }
}

struct ClosureReviewActionHandler: ReviewActionHandling, Sendable {
    typealias Operation = @Sendable (ReviewMutationRequest) async throws -> Void

    let isAvailable: Bool
    private let operation: Operation

    init(
        isAvailable: Bool = true,
        operation: @escaping Operation
    ) {
        self.isAvailable = isAvailable
        self.operation = operation
    }

    func perform(_ request: ReviewMutationRequest) async throws {
        try await operation(request)
    }
}

struct UnavailableReviewActionHandler: ReviewActionHandling, Sendable {
    var isAvailable: Bool { false }

    func perform(_ request: ReviewMutationRequest) async throws {
        throw ReviewPaneError.actionsUnavailable
    }
}

/// Typed handoff seam used by the pane's “Send to Agent” action. The payload
/// keeps `ReviewInlineComment` anchors intact; adapters may encode it for a
/// runtime, but the UI never flattens it into an ordinary chat message.
protocol ReviewAgentContextSending: Sendable {
    var isAvailable: Bool { get }
    func send(_ context: ReviewAgentContext) async throws
}

extension ReviewAgentContextSending {
    var isAvailable: Bool { true }
}

struct ClosureReviewAgentContextSender: ReviewAgentContextSending, Sendable {
    typealias Operation = @Sendable (ReviewAgentContext) async throws -> Void

    let isAvailable: Bool
    private let operation: Operation

    init(
        isAvailable: Bool = true,
        operation: @escaping Operation
    ) {
        self.isAvailable = isAvailable
        self.operation = operation
    }

    func send(_ context: ReviewAgentContext) async throws {
        try await operation(context)
    }
}

struct UnavailableReviewAgentContextSender: ReviewAgentContextSending, Sendable {
    var isAvailable: Bool { false }
    func send(_ context: ReviewAgentContext) async throws {
        throw ReviewPaneError.agentContextUnavailable
    }
}

/// Typed UI-to-runtime seam for starting a dedicated Review Agent task. The
/// pane supplies a `ReviewWorkflowRequest`; the production adapter owns task
/// creation, route capture, persistence, and runtime execution.
protocol ReviewWorkflowStarting: Sendable {
    var isAvailable: Bool { get }
    func start(_ request: ReviewWorkflowRequest) async throws
}

extension ReviewWorkflowStarting {
    var isAvailable: Bool { true }
}

struct ClosureReviewWorkflowStarter: ReviewWorkflowStarting, Sendable {
    typealias Operation = @Sendable (ReviewWorkflowRequest) async throws -> Void

    let isAvailable: Bool
    private let operation: Operation

    init(
        isAvailable: Bool = true,
        operation: @escaping Operation
    ) {
        self.isAvailable = isAvailable
        self.operation = operation
    }

    func start(_ request: ReviewWorkflowRequest) async throws {
        try await operation(request)
    }
}

struct UnavailableReviewWorkflowStarter: ReviewWorkflowStarting, Sendable {
    var isAvailable: Bool { false }

    func start(_ request: ReviewWorkflowRequest) async throws {
        throw ReviewPaneError.workflowUnavailable
    }
}

enum ReviewPaneError: LocalizedError, Equatable, Sendable {
    case actionsUnavailable
    case agentContextUnavailable
    case workflowUnavailable
    case invalidWorkflowInput(String)
    case noSelectedFile

    var errorDescription: String? {
        switch self {
        case .actionsUnavailable:
            "Review Git actions are not connected for this Task."
        case .agentContextUnavailable:
            "Sending Review context to the Agent is not connected for this Task."
        case .workflowUnavailable:
            "Starting a Review Agent workflow is not connected for this Task."
        case .invalidWorkflowInput(let detail):
            "Invalid Review workflow input: \(detail)"
        case .noSelectedFile:
            "Select a Review file first."
        }
    }
}

@MainActor
final class ReviewPaneModel: ObservableObject {
    @Published private(set) var source: ReviewSource?
    @Published private(set) var document: ReviewDocument?
    @Published private(set) var presentation: ReviewFilePresentation?
    @Published private(set) var comments: [ReviewInlineComment] = []
    @Published var selectedFileID: String?
    @Published var style: ReviewDiffStyle = .unified
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var isSendingToAgent = false
    @Published private(set) var isStartingWorkflow = false
    @Published var errorMessage: String?

    let actionsAvailable: Bool
    let agentContextSendAvailable: Bool
    let workflowStartingAvailable: Bool

    private let service: ReviewService
    private let actionHandler: any ReviewActionHandling
    private let contextSender: any ReviewAgentContextSending
    private let workflowStarter: any ReviewWorkflowStarting
    private var loadGeneration = UUID()

    init(
        service: ReviewService,
        actionHandler: any ReviewActionHandling = UnavailableReviewActionHandler(),
        contextSender: any ReviewAgentContextSending = UnavailableReviewAgentContextSender(),
        workflowStarter: any ReviewWorkflowStarting = UnavailableReviewWorkflowStarter()
    ) {
        self.service = service
        self.actionHandler = actionHandler
        self.contextSender = contextSender
        self.workflowStarter = workflowStarter
        self.actionsAvailable = actionHandler.isAvailable
        self.agentContextSendAvailable = contextSender.isAvailable
        self.workflowStartingAvailable = workflowStarter.isAvailable
    }

    var selectedFile: ReviewFileDiff? {
        guard let selectedFileID else { return nil }
        return document?.files.first { $0.id == selectedFileID }
    }

    func load(_ newSource: ReviewSource) async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        errorMessage = nil

        do {
            let loaded = try await service.load(newSource)
            guard loadGeneration == generation, !Task.isCancelled else { return }
            source = newSource
            document = loaded
            if let selectedFileID,
               loaded.files.contains(where: { $0.id == selectedFileID }) {
                self.selectedFileID = selectedFileID
            } else {
                selectedFileID = loaded.files.first?.id
            }
            comments = await service.comments(for: newSource)
            try await refreshPresentation(generation: generation)
            guard loadGeneration == generation else { return }
            isLoading = false
        } catch is CancellationError {
            guard loadGeneration == generation else { return }
            isLoading = false
        } catch {
            guard loadGeneration == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let source else { return }
        await load(source)
    }

    func selectFile(_ id: String) async {
        guard document?.files.contains(where: { $0.id == id }) == true else { return }
        selectedFileID = id
        do {
            try await refreshPresentation(generation: loadGeneration)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setStyle(_ newStyle: ReviewDiffStyle) async {
        style = newStyle
        do {
            try await refreshPresentation(generation: loadGeneration)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addComment(target: ReviewCommentTarget, body: String) async {
        guard let source else { return }
        do {
            _ = try await service.addComment(source: source, target: target, body: body)
            comments = await service.comments(for: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeComment(_ id: UUID) async {
        guard let source else { return }
        do {
            try await service.removeComment(source: source, id: id)
            comments = await service.comments(for: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func agentContext() async throws -> ReviewAgentContext {
        guard let source else { throw ReviewServiceError.sourceNotLoaded }
        return try await service.agentContext(for: source)
    }

    func sendToAgent() async {
        guard agentContextSendAvailable, !isSendingToAgent else {
            if !agentContextSendAvailable {
                errorMessage = ReviewPaneError.agentContextUnavailable.localizedDescription
            }
            return
        }
        isSendingToAgent = true
        errorMessage = nil
        do {
            let context = try await agentContext()
            try await contextSender.send(context)
            isSendingToAgent = false
        } catch {
            isSendingToAgent = false
            errorMessage = error.localizedDescription
        }
    }

    func startWorkflow(
        _ workflow: ReviewWorkflow,
        includingSource source: ReviewSource? = nil
    ) async {
        guard workflowStartingAvailable, !isStartingWorkflow else {
            if !workflowStartingAvailable {
                errorMessage = ReviewPaneError.workflowUnavailable.localizedDescription
            }
            return
        }

        isStartingWorkflow = true
        errorMessage = nil
        do {
            let validatedWorkflow = try Self.validated(workflow)
            let contextSource = source == self.source ? source : nil
            let request = try await service.workflowRequest(
                validatedWorkflow,
                source: contextSource
            )
            try await workflowStarter.start(request)
            isStartingWorkflow = false
        } catch {
            isStartingWorkflow = false
            errorMessage = error.localizedDescription
        }
    }

    func perform(
        _ intent: ReviewMutationIntent,
        userConfirmedDestructiveAction: Bool = false
    ) async {
        guard actionsAvailable, !isMutating else {
            if !actionsAvailable { errorMessage = ReviewPaneError.actionsUnavailable.localizedDescription }
            return
        }
        guard intent.source == source else { return }
        isMutating = true
        errorMessage = nil
        do {
            let file = document?.files.first {
                $0.id == intent.target.selection.fileID
            }
            let patch: ReviewPatchPayload?
            if file?.fallback != nil {
                guard case .file(let path, let selection) = intent.target else {
                    throw ReviewServiceError.invalidTarget(
                        "fallback files do not support hunk actions"
                    )
                }
                _ = try await service.fallbackFile(
                    source: intent.source,
                    path: path,
                    selection: selection
                )
                patch = nil
            } else {
                let direction: ReviewPatchDirection = intent.kind == .stage
                    ? .forward
                    : .reverse
                patch = try await service.patch(
                    source: intent.source,
                    selection: intent.target.selection,
                    direction: direction
                )
            }
            let request = ReviewMutationRequest(
                source: intent.source,
                kind: intent.kind,
                target: intent.target,
                patch: patch,
                userConfirmedDestructiveAction: userConfirmedDestructiveAction
            )
            try await actionHandler.perform(request)
            isMutating = false
            await load(intent.source)
        } catch {
            isMutating = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPresentation(generation: UUID) async throws {
        guard let source, let selectedFileID else {
            presentation = nil
            return
        }
        let value = try await service.presentation(
            source: source,
            fileID: selectedFileID,
            style: style
        )
        guard loadGeneration == generation else { return }
        presentation = value
    }

    private static func validated(_ workflow: ReviewWorkflow) throws -> ReviewWorkflow {
        switch workflow {
        case .changes:
            return .changes
        case .commit(let revision):
            return .commit(revision: try validatedRevision(revision, label: "revision"))
        case .branch(let baseRevision, let headRevision):
            return .branch(
                baseRevision: try validatedRevision(baseRevision, label: "base revision"),
                headRevision: try validatedRevision(headRevision, label: "head revision")
            )
        case .pullRequest(let reference):
            let provider = try validatedIdentifier(
                reference.providerID,
                label: "provider",
                maximumBytes: 64,
                allowed: CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "._-")
                )
            ).lowercased()
            let repository = try validatedIdentifier(
                reference.repositoryID,
                label: "repository",
                maximumBytes: 1_024,
                allowed: nil
            )
            let pullRequestID = try validatedIdentifier(
                reference.pullRequestID,
                label: "Pull Request ID",
                maximumBytes: 128,
                allowed: nil
            )
            return .pullRequest(ReviewPullRequestReference(
                providerID: provider,
                repositoryID: repository,
                pullRequestID: pullRequestID
            ))
        }
    }

    private static func validatedRevision(_ rawValue: String, label: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.hasPrefix("-") else {
            throw ReviewPaneError.invalidWorkflowInput("\(label) cannot start with '-'.")
        }
        return try validatedIdentifier(
            value,
            label: label,
            maximumBytes: 4_096,
            allowed: nil
        )
    }

    private static func validatedIdentifier(
        _ rawValue: String,
        label: String,
        maximumBytes: Int,
        allowed: CharacterSet?
    ) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ReviewPaneError.invalidWorkflowInput("\(label) is required.")
        }
        guard value.utf8.count <= maximumBytes else {
            throw ReviewPaneError.invalidWorkflowInput("\(label) is too long.")
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ReviewPaneError.invalidWorkflowInput("\(label) contains control characters.")
        }
        if let allowed,
           !value.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            throw ReviewPaneError.invalidWorkflowInput("\(label) contains unsupported characters.")
        }
        return value
    }
}

/// Resolves production dependencies for one selected Task without teaching the
/// SwiftUI pane how Git, persistence, or Agent execution works.
struct TaskReviewPaneHost: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel

    let sessionID: UUID
    @Binding var isPresented: Bool
    /// Tests and previews may inject a starter. Production deliberately leaves
    /// this nil so the host binds the pane to the selected Task's ViewModel.
    private let injectedWorkflowStarter: (any ReviewWorkflowStarting)?

    @State private var service: ReviewService?
    @State private var errorMessage: String?
    @State private var isLoading = true

    init(
        sessionID: UUID,
        isPresented: Binding<Bool>,
        workflowStarter: (any ReviewWorkflowStarting)? = nil
    ) {
        self.sessionID = sessionID
        _isPresented = isPresented
        self.injectedWorkflowStarter = workflowStarter
    }

    var body: some View {
        Group {
            if let service {
                ReviewPane(
                    sessionID: sessionID,
                    isPresented: $isPresented,
                    service: service,
                    actionHandler: actionHandler,
                    contextSender: contextSender,
                    workflowStarter: workflowStarter
                )
            } else if isLoading {
                ProgressView("Opening Task Review…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Review unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "The Task Review backend is unavailable.")
                        .textSelection(.enabled)
                } actions: {
                    HStack {
                        Button("Retry") { Task { await load() } }
                        Button("Hide") { isPresented = false }
                    }
                }
            }
        }
        .task(id: sessionID) { await load() }
    }

    private var actionHandler: ClosureReviewActionHandler {
        ClosureReviewActionHandler { request in
            try await agentViewModel.performReviewMutation(
                request,
                sessionID: sessionID
            )
        }
    }

    private var contextSender: ClosureReviewAgentContextSender {
        let route = chatViewModel.settings
        let apiKey = chatViewModel.apiKey
        return ClosureReviewAgentContextSender { context in
            try await agentViewModel.sendReviewContext(
                context,
                sessionID: sessionID,
                route: route,
                apiKey: apiKey
            )
        }
    }

    private var workflowStarter: any ReviewWorkflowStarting {
        if let injectedWorkflowStarter {
            return injectedWorkflowStarter
        }

        // Capture the route alongside the user action. AgentViewModel owns
        // validation, durable child-Task creation, and Runtime execution.
        let route = chatViewModel.settings
        let apiKey = chatViewModel.apiKey
        return ClosureReviewWorkflowStarter { request in
            try await agentViewModel.startReviewWorkflow(
                request,
                sessionID: sessionID,
                route: route,
                apiKey: apiKey
            )
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await agentViewModel.reviewService(for: sessionID)
            try Task.checkCancellation()
            service = loaded
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            service = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private enum ReviewSourceOption: String, CaseIterable, Identifiable {
    case unstaged
    case staged
    case commit
    case branch
    case lastAgentTurn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .commit: "Commit"
        case .branch: "Branch"
        case .lastAgentTurn: "Last Agent Turn"
        }
    }
}

private struct ReviewCommentSeed: Identifiable {
    let id = UUID()
    let target: ReviewCommentTarget
}

private enum ReviewWorkflowEditor: String, Identifiable {
    case commit
    case branch
    case pullRequest

    var id: String { rawValue }
}

struct ReviewPane: View {
    let sessionID: UUID
    @Binding private var isPresented: Bool
    @StateObject private var model: ReviewPaneModel
    @State private var sourceOption: ReviewSourceOption = .unstaged
    @State private var commitRevision = "HEAD"
    @State private var branchBaseRevision = "main"
    @State private var branchHeadRevision = "HEAD"
    @State private var pullRequestProviderID = "github"
    @State private var pullRequestRepositoryID = ""
    @State private var pullRequestID = ""
    @State private var commentSeed: ReviewCommentSeed?
    @State private var workflowEditor: ReviewWorkflowEditor?
    @State private var pendingDestructiveAction: ReviewMutationIntent?

    init(
        sessionID: UUID,
        isPresented: Binding<Bool>,
        service: ReviewService,
        actionHandler: any ReviewActionHandling = UnavailableReviewActionHandler(),
        contextSender: any ReviewAgentContextSending = UnavailableReviewAgentContextSender(),
        workflowStarter: any ReviewWorkflowStarting = UnavailableReviewWorkflowStarter()
    ) {
        self.sessionID = sessionID
        _isPresented = isPresented
        _model = StateObject(wrappedValue: ReviewPaneModel(
            service: service,
            actionHandler: actionHandler,
            contextSender: contextSender,
            workflowStarter: workflowStarter
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.55)
            sourceBar
            Divider().opacity(0.4)
            workflowBar
            Divider().opacity(0.4)
            HSplitView {
                fileSidebar
                    .frame(minWidth: 190, idealWidth: 245, maxWidth: 340)
                detail
                    .frame(minWidth: 420)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await loadSelectedSource() }
        .sheet(item: $commentSeed) { seed in
            if let file = model.selectedFile {
                ReviewCommentEditor(file: file, initialTarget: seed.target) { target, body in
                    Task { await model.addComment(target: target, body: body) }
                }
            }
        }
        .sheet(item: $workflowEditor) { editor in
            ReviewWorkflowConfigurationSheet(
                editor: editor,
                commitRevision: $commitRevision,
                branchBaseRevision: $branchBaseRevision,
                branchHeadRevision: $branchHeadRevision,
                pullRequestProviderID: $pullRequestProviderID,
                pullRequestRepositoryID: $pullRequestRepositoryID,
                pullRequestID: $pullRequestID
            ) { workflow in
                workflowEditor = nil
                Task {
                    await model.startWorkflow(
                        workflow,
                        includingSource: matchingSource(for: workflow)
                    )
                }
            }
        }
        .alert(
            "Review Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown Review error")
        }
        .confirmationDialog(
            "Revert uncommitted changes?",
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            )
        ) {
            Button("Revert permanently", role: .destructive) {
                guard let request = pendingDestructiveAction else { return }
                pendingDestructiveAction = nil
                Task {
                    await model.perform(
                        request,
                        userConfirmedDestructiveAction: true
                    )
                }
            }
            Button("Cancel", role: .cancel) { pendingDestructiveAction = nil }
        } message: {
            Text("This discards the selected working-tree change. The Git action handler will still enforce repository validation and approval policy.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("Review", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LumaTheme.accent)

            Picker("Layout", selection: Binding(
                get: { model.style },
                set: { style in Task { await model.setStyle(style) } }
            )) {
                Label("File", systemImage: "list.bullet.rectangle")
                    .tag(ReviewDiffStyle.file)
                Label("Unified", systemImage: "doc.plaintext")
                    .tag(ReviewDiffStyle.unified)
                Label("Side by Side", systemImage: "rectangle.split.2x1")
                    .tag(ReviewDiffStyle.sideBySide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 265)

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.isMutating || model.source == nil)

            Spacer()

            if model.isLoading || model.isMutating || model.isSendingToAgent
                || model.isStartingWorkflow {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await model.sendToAgent() }
            } label: {
                Label("Send to Agent", systemImage: "paperplane")
            }
            .disabled(
                !model.agentContextSendAvailable
                    || model.document == nil
                    || model.comments.isEmpty
                    || model.isSendingToAgent
            )
            .help(model.agentContextSendAvailable
                ? "Send structured Review comments to the Agent"
                : "Agent Review context backend is not connected")
            if let file = model.selectedFile {
                Button {
                    commentSeed = ReviewCommentSeed(target: .file(path: file.displayPath))
                } label: {
                    Label("Comment", systemImage: "text.bubble")
                }
            }
            Button { isPresented = false } label: {
                Image(systemName: "chevron.down")
            }
            .help("Hide Review")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Picker("Source", selection: $sourceOption) {
                ForEach(ReviewSourceOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 155)

            switch sourceOption {
            case .commit:
                TextField("revision", text: $commitRevision)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 100, maxWidth: 220)
                    .onSubmit { Task { await loadSelectedSource() } }
            case .branch:
                TextField("base", text: $branchBaseRevision)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90, maxWidth: 180)
                    .onSubmit { Task { await loadSelectedSource() } }
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                TextField("head", text: $branchHeadRevision)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 90, maxWidth: 180)
                    .onSubmit { Task { await loadSelectedSource() } }
            case .unstaged, .staged, .lastAgentTurn:
                Text(sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            Button("Load") { Task { await loadSelectedSource() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoading || model.isMutating)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    private var workflowBar: some View {
        HStack(spacing: 7) {
            Text("REVIEW AGENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await model.startWorkflow(
                        .changes,
                        includingSource: model.source
                    )
                }
            } label: {
                Label("Review Changes", systemImage: "sparkles.rectangle.stack")
            }

            Button {
                workflowEditor = .commit
            } label: {
                Label("Review Commit", systemImage: "point.3.connected.trianglepath.dotted")
            }

            Button {
                workflowEditor = .branch
            } label: {
                Label("Review Branch", systemImage: "arrow.triangle.branch")
            }

            Button {
                workflowEditor = .pullRequest
            } label: {
                Label("Review PR", systemImage: "arrow.triangle.pull")
            }

            Spacer(minLength: 0)

            Text("Runs as a dedicated Review Task")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.workflowStartingAvailable || model.isStartingWorkflow)
        .help(model.workflowStartingAvailable
            ? "Start a structured Review Agent workflow"
            : "Review Agent workflow backend is not connected")
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var sourceDescription: String {
        switch sourceOption {
        case .unstaged: "Working tree changes"
        case .staged: "Index changes"
        case .lastAgentTurn: "Changes recorded by this Task's latest Agent turn"
        case .commit, .branch: ""
        }
    }

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            if let document = model.document {
                HStack {
                    Text("FILES")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(document.files.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                Divider().opacity(0.35)

                if document.files.isEmpty {
                    ContentUnavailableView(
                        "No changes",
                        systemImage: "checkmark.circle",
                        description: Text("This Review source has no file differences.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(document.files) { file in
                                Button {
                                    Task { await model.selectFile(file.id) }
                                } label: {
                                    ReviewFileRow(
                                        file: file,
                                        isSelected: file.id == model.selectedFileID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }
                }
            } else if model.isLoading {
                ProgressView("Loading Review…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Load a source",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    @ViewBuilder
    private var detail: some View {
        if let file = model.selectedFile, let presentation = model.presentation {
            VStack(spacing: 0) {
                fileHeader(file, presentation: presentation)
                Divider().opacity(0.4)
                if let fallback = file.fallback {
                    ReviewFallbackView(path: file.displayPath, fallback: fallback)
                } else {
                    switch model.style {
                    case .file:
                        ReviewFileOverview(file: file)
                    case .unified:
                        unifiedDiff(file: file, rows: presentation.unifiedRows)
                    case .sideBySide:
                        sideBySideDiff(file: file, rows: presentation.sideBySideRows)
                    }
                }
                if !model.comments.isEmpty {
                    Divider().opacity(0.4)
                    ReviewCommentList(
                        comments: model.comments.filter { $0.target.path == file.displayPath },
                        onDelete: { id in Task { await model.removeComment(id) } }
                    )
                }
            }
        } else if model.document != nil {
            ContentUnavailableView("Select a file", systemImage: "doc")
        } else {
            ContentUnavailableView("Review", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func fileHeader(
        _ file: ReviewFileDiff,
        presentation: ReviewFilePresentation
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: file.change.symbolName)
                .foregroundStyle(file.change.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayPath)
                    .font(.callout.weight(.semibold).monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                if file.change == .renamed, let oldPath = file.oldPath {
                    Text("from \(oldPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            ReviewChangeCount(
                additions: presentation.summary.additions,
                deletions: presentation.summary.deletions
            )
            mutationButtons(target: fileMutationTarget(file))
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 42)
        .background(.ultraThinMaterial)
    }

    private func unifiedDiff(
        file: ReviewFileDiff,
        rows: [ReviewUnifiedRow]
    ) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ReviewUnifiedDiffRow(
                        row: row,
                        path: file.displayPath,
                        mutationButtons: {
                            AnyView(mutationButtons(target: hunkMutationTarget(
                                file: file,
                                hunkID: row.hunkID
                            )))
                        },
                        onComment: { commentSeed = ReviewCommentSeed(target: $0) }
                    )
                }
            }
            .frame(minWidth: 720, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func sideBySideDiff(
        file: ReviewFileDiff,
        rows: [ReviewSideBySideRow]
    ) -> some View {
        let groups = ReviewSideBySideGroup.make(rows: rows, file: file)
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    HStack(spacing: 8) {
                        Text(group.header)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        mutationButtons(target: hunkMutationTarget(
                            file: file,
                            hunkID: group.id
                        ))
                    }
                    .padding(.horizontal, 8)
                    .frame(minWidth: 920, minHeight: 28)
                    .background(LumaTheme.accent.opacity(0.08))

                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        ReviewSideBySideDiffRow(
                            row: row,
                            path: file.displayPath,
                            onComment: { commentSeed = ReviewCommentSeed(target: $0) }
                        )
                    }
                }
            }
            .frame(minWidth: 920, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func mutationButtons(target: ReviewMutationTarget) -> some View {
        if let source = model.source {
            HStack(spacing: 4) {
                if source == .unstaged {
                    mutationButton(kind: .stage, target: target, source: source)
                    mutationButton(kind: .revert, target: target, source: source)
                } else if source == .staged {
                    mutationButton(kind: .unstage, target: target, source: source)
                }
            }
        }
    }

    private func mutationButton(
        kind: ReviewMutationKind,
        target: ReviewMutationTarget,
        source: ReviewSource
    ) -> some View {
        Button(kind.title) {
            let request = ReviewMutationIntent(source: source, kind: kind, target: target)
            if kind.isDestructive {
                pendingDestructiveAction = request
            } else {
                Task { await model.perform(request) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(
            !model.actionsAvailable
                || model.isMutating
                || fallbackDisablesMutation(target)
        )
        .help(mutationHelp(kind: kind, target: target))
    }

    private func fallbackDisablesMutation(_ target: ReviewMutationTarget) -> Bool {
        guard model.document?.files.first(where: {
            $0.id == target.selection.fileID
        })?.fallback != nil else { return false }
        if case .hunk = target { return true }
        return false
    }

    private func mutationHelp(
        kind: ReviewMutationKind,
        target: ReviewMutationTarget
    ) -> String {
        if !model.actionsAvailable { return "Git action backend is not connected" }
        if fallbackDisablesMutation(target) {
            return "Binary, large, and omitted diffs do not support hunk actions"
        }
        if model.document?.files.first(where: {
            $0.id == target.selection.fileID
        })?.fallback != nil {
            return "\(kind.title) the whole file using its refreshed Review identity"
        }
        return "\(kind.title) selected Review change"
    }

    private func fileMutationTarget(_ file: ReviewFileDiff) -> ReviewMutationTarget {
        .file(
            path: file.displayPath,
            selection: ReviewPatchSelection(
                fileID: file.id,
                fileFingerprint: file.fingerprint,
                hunkID: nil,
                hunkFingerprint: nil
            )
        )
    }

    private func hunkMutationTarget(
        file: ReviewFileDiff,
        hunkID: String
    ) -> ReviewMutationTarget {
        let hunk = file.hunks.first { $0.id == hunkID }
        return .hunk(
            path: file.displayPath,
            selection: ReviewPatchSelection(
                fileID: file.id,
                fileFingerprint: file.fingerprint,
                hunkID: hunkID,
                hunkFingerprint: hunk?.fingerprint
            )
        )
    }

    private func loadSelectedSource() async {
        let source: ReviewSource
        switch sourceOption {
        case .unstaged:
            source = .unstaged
        case .staged:
            source = .staged
        case .commit:
            source = .commit(revision: commitRevision)
        case .branch:
            source = .branch(
                baseRevision: branchBaseRevision,
                headRevision: branchHeadRevision
            )
        case .lastAgentTurn:
            source = .lastAgentTurn(taskID: sessionID)
        }
        await model.load(source)
    }

    private func matchingSource(for workflow: ReviewWorkflow) -> ReviewSource? {
        switch (workflow, model.source) {
        case (.changes, let source?):
            return source
        case (.commit(let revision), .commit(let loadedRevision))
            where revision.trimmingCharacters(in: .whitespacesAndNewlines)
                == loadedRevision:
            return model.source
        case (
            .branch(let baseRevision, let headRevision),
            .branch(let loadedBase, let loadedHead)
        ) where baseRevision.trimmingCharacters(in: .whitespacesAndNewlines) == loadedBase
            && headRevision.trimmingCharacters(in: .whitespacesAndNewlines) == loadedHead:
            return model.source
        case (.changes, nil), (.commit, _), (.branch, _), (.pullRequest, _):
            return nil
        }
    }
}

private struct ReviewWorkflowConfigurationSheet: View {
    let editor: ReviewWorkflowEditor
    @Binding var commitRevision: String
    @Binding var branchBaseRevision: String
    @Binding var branchHeadRevision: String
    @Binding var pullRequestProviderID: String
    @Binding var pullRequestRepositoryID: String
    @Binding var pullRequestID: String
    let onStart: (ReviewWorkflow) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbolName)
                .font(.title3.weight(.semibold))

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            fields

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Review") {
                    onStart(workflow)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasRequiredInput)
            }
        }
        .padding(20)
        .frame(width: editor == .pullRequest ? 480 : 420)
    }

    @ViewBuilder
    private var fields: some View {
        switch editor {
        case .commit:
            LabeledContent("Revision") {
                TextField("HEAD or commit SHA", text: $commitRevision)
                    .textFieldStyle(.roundedBorder)
            }
        case .branch:
            LabeledContent("Base") {
                TextField("main", text: $branchBaseRevision)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Head") {
                TextField("HEAD", text: $branchHeadRevision)
                    .textFieldStyle(.roundedBorder)
            }
        case .pullRequest:
            LabeledContent("Provider") {
                TextField("github", text: $pullRequestProviderID)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Repository") {
                TextField("owner/repository", text: $pullRequestRepositoryID)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Pull Request") {
                TextField("number or provider ID", text: $pullRequestID)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var workflow: ReviewWorkflow {
        switch editor {
        case .commit:
            .commit(revision: commitRevision)
        case .branch:
            .branch(
                baseRevision: branchBaseRevision,
                headRevision: branchHeadRevision
            )
        case .pullRequest:
            .pullRequest(ReviewPullRequestReference(
                providerID: pullRequestProviderID,
                repositoryID: pullRequestRepositoryID,
                pullRequestID: pullRequestID
            ))
        }
    }

    private var hasRequiredInput: Bool {
        switch editor {
        case .commit:
            !commitRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .branch:
            !branchBaseRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !branchHeadRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pullRequest:
            !pullRequestProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !pullRequestRepositoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !pullRequestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var title: String {
        switch editor {
        case .commit: "Review Commit"
        case .branch: "Review Branch"
        case .pullRequest: "Review Pull Request"
        }
    }

    private var symbolName: String {
        switch editor {
        case .commit: "point.3.connected.trianglepath.dotted"
        case .branch: "arrow.triangle.branch"
        case .pullRequest: "arrow.triangle.pull"
        }
    }

    private var detail: String {
        switch editor {
        case .commit:
            "Inspect one Git revision and return structured findings."
        case .branch:
            "Compare the head revision against the selected base."
        case .pullRequest:
            "Load provider-backed Pull Request context and inspect its changes."
        }
    }
}

private struct ReviewFileRow: View {
    let file: ReviewFileDiff
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.change.symbolName)
                .font(.caption)
                .foregroundStyle(file.change.color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayPath)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(file.change.rawValue.capitalized)
                    ReviewChangeCount(
                        additions: file.additionCount,
                        deletions: file.deletionCount
                    )
                    if file.fallback != nil {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected ? LumaTheme.accent.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

private struct ReviewChangeCount: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .font(.caption2.monospacedDigit())
    }
}

private struct ReviewFallbackView: View {
    let path: String
    let fallback: ReviewDiffFallback

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.badge.ellipsis")
        } description: {
            Text(detail)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch fallback {
        case .binary: "Binary file"
        case .large: "Large diff"
        case .omitted: "Diff unavailable"
        }
    }

    private var detail: String {
        switch fallback {
        case .binary:
            "\(path) is binary. File metadata and Git actions remain available."
        case .large(let byteCount, let limit):
            "\(path) contains a \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) diff, above the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) display limit."
        case .omitted(let reason):
            reason
        }
    }
}

private struct ReviewFileOverview: View {
    let file: ReviewFileDiff

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("File summary", systemImage: "doc")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { Text("Change"); Text(file.change.rawValue.capitalized) }
                    GridRow { Text("Language"); Text(file.language?.rawValue ?? "Plain text") }
                    GridRow { Text("Hunks"); Text("\(file.hunks.count)") }
                    GridRow { Text("Additions"); Text("+\(file.additionCount)").foregroundStyle(.green) }
                    GridRow { Text("Deletions"); Text("−\(file.deletionCount)").foregroundStyle(.red) }
                }
                .font(.callout)
                ForEach(file.hunks) { hunk in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hunk.header)
                            .font(.caption.monospaced())
                        Text("\(hunk.lines.count) visible lines")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReviewUnifiedDiffRow: View {
    let row: ReviewUnifiedRow
    let path: String
    let mutationButtons: () -> AnyView
    let onComment: (ReviewCommentTarget) -> Void

    var body: some View {
        if row.kind == .hunkHeader {
            HStack(spacing: 8) {
                Text(row.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    onComment(.hunk(path: path, hunkID: row.hunkID))
                } label: {
                    Image(systemName: "text.bubble")
                }
                .buttonStyle(.plain)
                Spacer()
                mutationButtons()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(LumaTheme.accent.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                ReviewLineNumber(value: row.oldLineNumber)
                ReviewLineNumber(value: row.newLineNumber)
                Text(row.kind.marker)
                    .font(.caption.monospaced())
                    .foregroundStyle(row.kind.foregroundColor)
                    .frame(width: 18)
                ReviewSyntaxText(text: row.text, spans: row.syntax)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let target = commentTarget {
                    Button { onComment(target) } label: {
                        Image(systemName: "plus.bubble")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }
            }
            .frame(minHeight: 22)
            .background(row.kind.backgroundColor)
        }
    }

    private var commentTarget: ReviewCommentTarget? {
        if let line = row.newLineNumber {
            return .line(path: path, side: .new, line: line)
        }
        if let line = row.oldLineNumber {
            return .line(path: path, side: .old, line: line)
        }
        return nil
    }
}

private struct ReviewSideBySideGroup: Identifiable {
    let id: String
    let header: String
    var rows: [ReviewSideBySideRow]

    static func make(rows: [ReviewSideBySideRow], file: ReviewFileDiff) -> [Self] {
        let headers = Dictionary(uniqueKeysWithValues: file.hunks.map { ($0.id, $0.header) })
        var groups: [Self] = []
        for row in rows {
            if groups.last?.id == row.hunkID {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(Self(
                    id: row.hunkID,
                    header: headers[row.hunkID] ?? row.hunkID,
                    rows: [row]
                ))
            }
        }
        return groups
    }
}

private struct ReviewSideBySideDiffRow: View {
    let row: ReviewSideBySideRow
    let path: String
    let onComment: (ReviewCommentTarget) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ReviewDiffCellView(cell: row.left, side: .old, path: path, onComment: onComment)
            Divider()
            ReviewDiffCellView(cell: row.right, side: .new, path: path, onComment: onComment)
        }
        .frame(minWidth: 920, minHeight: 22)
    }
}

private struct ReviewDiffCellView: View {
    let cell: ReviewDiffCell?
    let side: ReviewLineSide
    let path: String
    let onComment: (ReviewCommentTarget) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let cell {
                ReviewLineNumber(value: cell.lineNumber)
                Text(cell.kind.marker)
                    .font(.caption.monospaced())
                    .foregroundStyle(cell.kind.foregroundColor)
                    .frame(width: 18)
                ReviewSyntaxText(text: cell.text, spans: cell.syntax)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    onComment(.line(path: path, side: side, line: cell.lineNumber))
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            } else {
                Color.primary.opacity(0.025)
            }
        }
        .frame(width: 459, alignment: .leading)
        .background(cell?.kind.backgroundColor ?? Color.primary.opacity(0.025))
    }
}

private struct ReviewLineNumber: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 46, alignment: .trailing)
            .padding(.trailing, 6)
            .background(Color.primary.opacity(0.025))
    }
}

private struct ReviewSyntaxText: View {
    let text: String
    let spans: [ReviewSyntaxSpan]

    var body: some View {
        Text(Self.attributed(text: text, spans: spans))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(.horizontal, 4)
    }

    private static func attributed(
        text: String,
        spans: [ReviewSyntaxSpan]
    ) -> AttributedString {
        let value = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: value.length)
        value.addAttribute(
            .foregroundColor,
            value: NSColor.textColor,
            range: fullRange
        )
        for span in spans {
            let requested = NSRange(location: max(0, span.location), length: max(0, span.length))
            let bounded = NSIntersectionRange(fullRange, requested)
            guard bounded.length > 0 else { continue }
            value.addAttribute(
                .foregroundColor,
                value: span.role.color,
                range: bounded
            )
        }
        return AttributedString(value)
    }
}

private struct ReviewCommentEditor: View {
    private enum TargetKind: String, CaseIterable, Identifiable {
        case file
        case line
        case range
        case hunk
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Environment(\.dismiss) private var dismiss
    let file: ReviewFileDiff
    let onSave: (ReviewCommentTarget, String) -> Void
    @State private var targetKind: TargetKind
    @State private var side: ReviewLineSide
    @State private var startLine: Int
    @State private var endLine: Int
    @State private var hunkID: String
    @State private var bodyText = ""

    init(
        file: ReviewFileDiff,
        initialTarget: ReviewCommentTarget,
        onSave: @escaping (ReviewCommentTarget, String) -> Void
    ) {
        self.file = file
        self.onSave = onSave
        switch initialTarget {
        case .file:
            _targetKind = State(initialValue: .file)
            _side = State(initialValue: .new)
            _startLine = State(initialValue: 1)
            _endLine = State(initialValue: 1)
            _hunkID = State(initialValue: file.hunks.first?.id ?? "")
        case .line(_, let side, let line):
            _targetKind = State(initialValue: .line)
            _side = State(initialValue: side)
            _startLine = State(initialValue: line)
            _endLine = State(initialValue: line)
            _hunkID = State(initialValue: file.hunks.first?.id ?? "")
        case .range(_, let side, let startLine, let endLine):
            _targetKind = State(initialValue: .range)
            _side = State(initialValue: side)
            _startLine = State(initialValue: startLine)
            _endLine = State(initialValue: endLine)
            _hunkID = State(initialValue: file.hunks.first?.id ?? "")
        case .hunk(_, let hunkID):
            _targetKind = State(initialValue: .hunk)
            _side = State(initialValue: .new)
            _startLine = State(initialValue: 1)
            _endLine = State(initialValue: 1)
            _hunkID = State(initialValue: hunkID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inline Review Comment")
                .font(.headline)
            Text(file.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("Target", selection: $targetKind) {
                ForEach(TargetKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            targetFields

            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )

            HStack {
                Text("Structured file/line/range/hunk anchors are sent to the Agent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Comment") {
                    onSave(target, bodyText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 330)
    }

    @ViewBuilder
    private var targetFields: some View {
        switch targetKind {
        case .file:
            Text("Whole file")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .line:
            HStack {
                sidePicker
                Stepper("Line \(startLine)", value: $startLine, in: 1...10_000_000)
            }
        case .range:
            HStack {
                sidePicker
                Stepper("Start \(startLine)", value: $startLine, in: 1...10_000_000)
                Stepper("End \(endLine)", value: $endLine, in: startLine...10_000_000)
            }
        case .hunk:
            Picker("Hunk", selection: $hunkID) {
                ForEach(file.hunks) { hunk in
                    Text(hunk.header).tag(hunk.id)
                }
            }
        }
    }

    private var sidePicker: some View {
        Picker("Side", selection: $side) {
            Text("Old").tag(ReviewLineSide.old)
            Text("New").tag(ReviewLineSide.new)
        }
        .frame(width: 120)
    }

    private var target: ReviewCommentTarget {
        switch targetKind {
        case .file:
            .file(path: file.displayPath)
        case .line:
            .line(path: file.displayPath, side: side, line: startLine)
        case .range:
            .range(
                path: file.displayPath,
                side: side,
                startLine: startLine,
                endLine: max(startLine, endLine)
            )
        case .hunk:
            .hunk(path: file.displayPath, hunkID: hunkID)
        }
    }
}

private struct ReviewCommentList: View {
    let comments: [ReviewInlineComment]
    let onDelete: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("COMMENTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(comments) { comment in
                    HStack(spacing: 6) {
                        Text(comment.target.shortLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(LumaTheme.accent)
                        Text(comment.body)
                            .font(.caption)
                            .lineLimit(1)
                        Button(role: .destructive) { onDelete(comment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 38)
    }
}

private extension ReviewFileChangeKind {
    var symbolName: String {
        switch self {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .modified: "pencil.square"
        case .renamed: "arrow.right.square"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed: .blue
        }
    }
}

private extension ReviewUnifiedRow.Kind {
    var marker: String {
        switch self {
        case .addition: "+"
        case .removal: "−"
        case .context: " "
        case .hunkHeader: "@"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .addition: .green
        case .removal: .red
        case .context, .hunkHeader: .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .addition: .green.opacity(0.09)
        case .removal: .red.opacity(0.09)
        case .context: .clear
        case .hunkHeader: LumaTheme.accent.opacity(0.08)
        }
    }
}

private extension ReviewDiffLineKind {
    var marker: String {
        switch self {
        case .addition: "+"
        case .removal: "−"
        case .context: " "
        }
    }

    var foregroundColor: Color {
        switch self {
        case .addition: .green
        case .removal: .red
        case .context: .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .addition: .green.opacity(0.09)
        case .removal: .red.opacity(0.09)
        case .context: .clear
        }
    }
}

private extension ReviewSyntaxRole {
    var color: NSColor {
        switch self {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .number: .systemBlue
        case .comment: .systemGreen
        case .directive: .systemOrange
        }
    }
}

private extension ReviewCommentTarget {
    var shortLabel: String {
        switch self {
        case .file:
            "File"
        case .line(_, let side, let line):
            "\(side.rawValue):\(line)"
        case .range(_, let side, let start, let end):
            "\(side.rawValue):\(start)–\(end)"
        case .hunk(_, let id):
            "Hunk \(id.prefix(8))"
        }
    }
}
