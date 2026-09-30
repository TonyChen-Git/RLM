import SwiftUI

private func capturedAgentRouteLabel(
    session: AgentSession?,
    settings: AppSettings
) -> String {
    guard let session else { return settings.provider.title }
    guard let connection = session.connection else {
        if let profileID = session.profileID,
           let profile = settings.connectionProfiles.first(where: { $0.id == profileID }) {
            return profile.displayName
        }
        return session.provider.title
    }
    if let profileID = connection.profileID,
       let profile = settings.connectionProfiles.first(where: { $0.id == profileID }),
       profile.provider == connection.provider,
       EndpointNormalizer.normalized(profile.endpoint)
        == EndpointNormalizer.normalized(connection.endpoint) {
        return profile.displayName
    }
    let endpoint = EndpointNormalizer.normalized(connection.endpoint) ?? connection.endpoint
    let host = URLComponents(string: endpoint)?.host
        ?? URL(string: endpoint)?.host
        ?? endpoint
    let boundedHost = String(host.prefix(80))
    return boundedHost.isEmpty
        ? connection.provider.title
        : "\(connection.provider.title) · \(boundedHost)"
}

/// Keeps dedicated Review Tasks on their read-only result surface. These
/// predicates are intentionally independent of SwiftUI so their safety-facing
/// visibility rules can be covered by focused tests.
enum AgentDetailSurfacePolicy {
    static func allowsAuxiliaryPanes(for taskType: AgentTaskType) -> Bool {
        guard case .coding = taskType else { return false }
        return true
    }

    static func showsExecutePlan(
        taskType: AgentTaskType,
        mode: AppMode,
        state: AgentRunState
    ) -> Bool {
        guard case .coding = taskType else { return false }
        return mode == .plan && state == .completed
    }
}

private struct AgentTranscriptComposerLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let bottomHeight = subviews[1].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        let transcriptHeight = max(0, bounds.height - bottomHeight)
        subviews[0].place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: transcriptHeight)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - bottomHeight),
            proposal: ProposedViewSize(width: bounds.width, height: bottomHeight)
        )
    }
}

struct AgentDetailView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var isTaskTerminalPresented = false
    @State private var isReviewPresented = false
    @State private var isBrowserPresented = false

    var body: some View {
        ZStack {
            LumaTheme.canvas
                .overlay(LumaTheme.ambientGradient)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                AgentHeader()
                Divider().opacity(0.45)

                if let session = agentViewModel.selectedSession,
                   let goal = session.goal {
                    AgentGoalBar(session: session, goal: goal)
                }

                if let session = agentViewModel.selectedSession {
                    let records = agentViewModel.subagentRecords(for: session)
                    if !records.isEmpty {
                        SubagentStatusPanel(records: records)
                    }
                }

                if let session = agentViewModel.selectedSession,
                   session.workspace != nil {
                    let allowsAuxiliaryPanes = AgentDetailSurfacePolicy
                        .allowsAuxiliaryPanes(for: session.resolvedTaskType)
                    if allowsAuxiliaryPanes
                        && (taskTerminalSurfaceAvailable && isTaskTerminalPresented
                            || localReviewSurfaceAvailable && isReviewPresented
                            || browserSurfaceAvailable && isBrowserPresented) {
                        VSplitView {
                            agentPrimaryContent
                                .frame(minHeight: 250)
                            if localReviewSurfaceAvailable && isReviewPresented {
                                TaskReviewPaneHost(
                                    sessionID: session.id,
                                    isPresented: $isReviewPresented
                                )
                                .id("review-\(session.id.uuidString)")
                                .frame(minHeight: 220, idealHeight: 360, maxHeight: 720)
                            }
                            if isBrowserPresented {
                                BrowserAnnotationPane(
                                    session: session,
                                    isPresented: $isBrowserPresented
                                )
                                .id("browser-\(session.id.uuidString)")
                                .frame(minHeight: 260, idealHeight: 430, maxHeight: 760)
                            }
                            if taskTerminalSurfaceAvailable && isTaskTerminalPresented {
                                TaskTerminalPane(
                                    sessionID: session.id,
                                    isPresented: $isTaskTerminalPresented
                                )
                                .id("terminal-\(session.id.uuidString)")
                                .frame(minHeight: 180, idealHeight: 285, maxHeight: 620)
                            }
                        }
                    } else {
                        agentPrimaryContent
                    }
                    if allowsAuxiliaryPanes {
                        collapsedTaskPanelsBar
                    }
                } else {
                    agentPrimaryContent
                }
            }
        }
        .onChange(of: agentViewModel.selectedSessionID) { _, _ in
            // Panel state belongs to one Task. In particular, a panel left
            // open by a coding Task must not leak onto a Review Task.
            isTaskTerminalPresented = false
            isReviewPresented = false
            isBrowserPresented = false
        }
        .onChange(of: agentViewModel.selectedSession?.resolvedExecutionLocation.kind) { _, kind in
            guard kind == .ssh || kind == .futureCloud else { return }
            isTaskTerminalPresented = false
            isReviewPresented = false
            isBrowserPresented = false
        }
    }

    @ViewBuilder
    private var agentPrimaryContent: some View {
        GeometryReader { available in
            AgentTranscriptComposerLayout {
                agentTranscript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    if agentViewModel.selectedSession != nil {
                        if let approval = agentViewModel.pendingApproval,
                           approval.sessionID == agentViewModel.selectedSessionID {
                            AgentApprovalCard(request: approval)
                                .padding(.horizontal, 22)
                                .padding(.bottom, 9)
                        }
                        AgentComposer()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: available.size.width, height: available.size.height)
        }
    }

    @ViewBuilder
    private var agentTranscript: some View {
        Group {
            if let session = agentViewModel.selectedSession {
                if session.workspace != nil {
                    if case .review = session.resolvedTaskType,
                       let reviewResult = session.reviewResult {
                        VSplitView {
                            ReviewFindingsPanel(result: reviewResult)
                                .frame(minHeight: 190, idealHeight: 320)
                            AgentActivityTimeline(session: session)
                                .frame(minHeight: 180)
                        }
                    } else if session.messages.filter({ $0.role == .user }).isEmpty {
                        AgentWelcomeView()
                    } else {
                        AgentActivityTimeline(session: session)
                    }
                } else {
                    WorkspaceRequiredView()
                }
            } else {
                NoAgentSessionView()
            }
        }
    }

    @ViewBuilder
    private var collapsedTaskPanelsBar: some View {
        if localReviewSurfaceAvailable && !isReviewPresented
            || taskTerminalSurfaceAvailable && !isTaskTerminalPresented
            || browserSurfaceAvailable && !isBrowserPresented {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            HStack(spacing: 16) {
                if localReviewSurfaceAvailable && !isReviewPresented {
                    Button {
                        isReviewPresented = true
                    } label: {
                        Label("Review", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaTheme.accent)
                    .help("Show Task Review")
                }
                if browserSurfaceAvailable && !isBrowserPresented {
                    Button {
                        isBrowserPresented = true
                    } label: {
                        Label("Browser", systemImage: "globe.desk")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaTheme.accent)
                    .help("Show Browser screenshots and annotations")
                }
                if taskTerminalSurfaceAvailable && !isTaskTerminalPresented {
                    Button {
                        isTaskTerminalPresented = true
                    } label: {
                        Label("Task Terminal", systemImage: "terminal")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LumaTheme.accent)
                    .help("Show Task Terminal")
                }
                Spacer()
                Text("Task-owned Review, Browser and Terminal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.ultraThinMaterial)
        }
        }
    }

    private var browserSurfaceAvailable: Bool {
        guard localReviewSurfaceAvailable else { return false }
        return agentViewModel.settings.browserEnabled
            || agentViewModel.selectedSession.flatMap {
                BrowserScreenshotEvidence.latest(in: $0)
            } != nil
    }

    private var taskTerminalSurfaceAvailable: Bool {
        localReviewSurfaceAvailable
    }

    private var localReviewSurfaceAvailable: Bool {
        guard let kind = agentViewModel.selectedSession?.resolvedExecutionLocation.kind else {
            return false
        }
        return kind == .local || kind == .worktree
    }
}

private struct SubagentStatusPanel: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let records: [SubagentRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Subagents", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LumaTheme.accent)
                Text("\(records.filter { !$0.status.isTerminal }.count) active")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(records) { record in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(color(for: record.status))
                                .frame(width: 7, height: 7)
                            Button {
                                agentViewModel.selectedSessionID = record.childSessionID
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.goal)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(record.status.rawValue) · attempt \(record.attempt)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            if !record.status.isTerminal && record.status != .interrupted {
                                Button {
                                    Task { await agentViewModel.cancelSubagent(record) }
                                } label: {
                                    Image(systemName: "stop.fill")
                                }
                                .buttonStyle(.plain)
                                .help("Cancel Subagent")
                            } else if [.paused, .failed, .cancelled, .timedOut, .interrupted]
                                .contains(record.status),
                                      agentViewModel.selectedSession.map({
                                          $0.resolvedExecutionLocation.kind == .local
                                            || $0.resolvedExecutionLocation.kind == .worktree
                                      }) == true {
                                Button {
                                    Task { await agentViewModel.resumeSubagent(record) }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.plain)
                                .help("Resume Subagent")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .frame(maxWidth: 300)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider().opacity(0.45)
        }
        .background(.ultraThinMaterial)
    }

    private func color(for status: SubagentStatus) -> Color {
        switch status {
        case .queued, .paused, .interrupted: .secondary
        case .running: LumaTheme.accent
        case .completed: .green
        case .failed, .timedOut: .orange
        case .cancelled: .red
        }
    }
}

enum ReviewFindingsPresentation {
    static func sorted(_ findings: [ReviewFinding]) -> [ReviewFinding] {
        findings.sorted { lhs, rhs in
            let lhsRank = severityRank(lhs.severity)
            let rhsRank = severityRank(rhs.severity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            let pathOrder = lhs.file.localizedStandardCompare(rhs.file)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }

            let lhsLine = lhs.line ?? Int.max
            let rhsLine = rhs.line ?? Int.max
            if lhsLine != rhsLine { return lhsLine < rhsLine }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func severityRank(_ severity: ReviewSeverity) -> Int {
        switch severity {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .note: 4
        }
    }
}

/// Read-only result surface for dedicated Review Tasks. Keeping this view
/// independent of `AgentSession` lets persistence/runtime integration pass its
/// typed result directly without projecting findings through chat text.
struct ReviewFindingsPanel: View {
    let result: ReviewWorkflowResult

    private var findings: [ReviewFinding] {
        ReviewFindingsPresentation.sorted(result.findings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Review Findings", systemImage: "checklist.checked")
                    .font(.headline)
                    .foregroundStyle(LumaTheme.accent)
                Text("\(findings.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(result.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                LumaTheme.accent.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                    }

                    if findings.isEmpty {
                        ContentUnavailableView(
                            "No findings",
                            systemImage: "checkmark.seal",
                            description: Text("The Review Task did not report actionable issues.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(findings) { finding in
                                ReviewFindingRow(finding: finding)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review findings")
    }
}

private struct ReviewFindingRow: View {
    let finding: ReviewFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(finding.severity.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(severityColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(severityColor.opacity(0.12), in: Capsule())

                Text(location)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer(minLength: 0)
            }

            Text(finding.explanation)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let recommendedFix = finding.recommendedFix?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !recommendedFix.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("RECOMMENDED FIX")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(recommendedFix)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(severityColor.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(finding.severity.rawValue) finding at \(location): \(finding.explanation)"
        )
    }

    private var location: String {
        guard let line = finding.line else { return finding.file }
        return "\(finding.file):\(line)"
    }

    private var severityColor: Color {
        switch finding.severity {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .note: .secondary
        }
    }
}

private struct AgentGoalBar: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    let session: AgentSession
    let goal: AgentGoal
    @State private var editorMode: AgentGoalEditorMode?
    @State private var isConfirmingClear = false

    private var status: AgentGoalStatus { session.goalStatus ?? .active }
    private var completedTodoCount: Int {
        session.todos.lazy.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Label("Goal", systemImage: "scope")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(LumaTheme.accent)
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                if !session.todos.isEmpty {
                    Text("\(completedTodoCount)/\(session.todos.count) Todo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if agentViewModel.selectedSessionIsRunning {
                    Button {
                        agentViewModel.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if status != .completed {
                    Button {
                        agentViewModel.resumeGoal(
                            route: chatViewModel.settings,
                            apiKey: chatViewModel.apiKey
                        )
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(agentViewModel.selectedGoalIsMutating)
                } else {
                    Button {
                        editorMode = .start
                    } label: {
                        Label("New Goal", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Menu {
                    Button {
                        editorMode = .edit
                    } label: {
                        Label("Edit Goal…", systemImage: "pencil")
                    }
                    .disabled(agentViewModel.selectedSessionIsRunning)
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label("Clear Goal", systemImage: "trash")
                    }
                    .disabled(agentViewModel.selectedSessionIsRunning)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(goal.objective)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)

            if !session.todos.isEmpty {
                ProgressView(
                    value: Double(completedTodoCount),
                    total: Double(session.todos.count)
                )
                .tint(status == .completed ? .green : LumaTheme.accent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(LumaTheme.accent.opacity(0.055))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
        .sheet(item: $editorMode) { mode in
            AgentGoalEditor(mode: mode)
                .environmentObject(agentViewModel)
                .environmentObject(chatViewModel)
        }
        .alert("清除 Goal？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { _ = await agentViewModel.clearGoal() }
            }
        } message: {
            Text("只會移除 Goal 目標與完成條件；對話、Todo、變更與執行記錄都會保留。")
        }
    }

    private var statusLabel: String {
        switch status {
        case .active: "Active"
        case .paused: "Paused"
        case .completed: "Completed"
        case .needsAttention: "Needs attention"
        }
    }

    private var statusColor: Color {
        switch status {
        case .active: LumaTheme.accent
        case .paused: .secondary
        case .completed: .green
        case .needsAttention: .orange
        }
    }
}

private struct AgentHeader: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""
    @State private var isShowingModelParameters = false
    @State private var isShowingLocalMemories = false

    private var modelParameterRoute: ModelParameterRoute {
        if let session = agentViewModel.selectedSession,
           let connection = session.connection {
            return ModelParameterRoute(
                provider: connection.provider,
                backend: connection.resolvedBackend,
                endpoint: connection.endpoint,
                modelID: session.model,
                useCase: .agent
            )
        }
        return ModelParameterRoute(
            settings: chatViewModel.settings,
            useCase: .agent,
            modelID: agentViewModel.selectedSession?.model
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agentViewModel.selectedSession?.title ?? "尚未選擇 Coding 任務")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let workspace = agentViewModel.selectedSession?.workspace {
                        Button {
                            if let session = agentViewModel.selectedSession {
                                projectNameDraft = agentViewModel.projectDisplayName(for: session)
                            } else {
                                projectNameDraft = agentViewModel.projectDisplayName(for: workspace)
                            }
                            isRenamingProject = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                Text(agentViewModel.selectedSession.map {
                                    agentViewModel.projectDisplayName(for: $0)
                                } ?? agentViewModel.projectDisplayName(for: workspace))
                                    .lineLimit(1)
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("自訂專案名稱")

                        if let session = agentViewModel.selectedSession,
                           session.resolvedExecutionLocation.kind == .local,
                           let projectID = session.projectID,
                           let project = agentViewModel.projects.first(
                            where: { $0.id == projectID }
                           ), project.folders.count > 1 {
                            Text("/")
                            Menu {
                                ForEach(project.folders) { folder in
                                    Button {
                                        Task {
                                            await agentViewModel.assignSelectedSession(
                                                toProjectFolder: folder.id
                                            )
                                        }
                                    } label: {
                                        if folder.id == session.projectFolderID {
                                            Label(folder.name, systemImage: "checkmark")
                                        } else {
                                            Text(folder.name)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(agentViewModel.projectFolderName(for: session) ?? workspace.name)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(
                                agentViewModel.selectedSessionIsRunning
                                    || agentViewModel.selectedGoalIsMutating
                            )
                            .help("切換此新 Task 使用的 Project folder")
                        }
                    } else {
                        Image(systemName: "folder")
                        Text("尚未開啟專案")
                    }
                    if let session = agentViewModel.selectedSession,
                       session.workspace != nil {
                        Text("·")
                        Image(systemName: executionLocationIcon(session))
                        Text(agentViewModel.executionLocationLabel(for: session))
                            .lineLimit(1)
                    }
                    if let branch = agentViewModel.selectedSession?.workspace?.branch {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1)
                    }
                    if let state = agentViewModel.selectedSession?.state {
                        Text("·")
                        AgentStateLabel(state: state)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            ModeSelector(
                selection: agentViewModel.activeMode,
                isDisabled: false
            ) { mode in
                agentViewModel.switchMode(mode, route: chatViewModel.settings)
            }

            if agentViewModel.selectedSession?.projectID != nil {
                Button {
                    isShowingLocalMemories = true
                } label: {
                    Image(systemName: "brain.head.profile")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("本機記憶")
                .accessibilityLabel("本機記憶")
            }

            if let session = agentViewModel.selectedSession {
                Menu {
                    Section("Task Actions") {
                        if session.resolvedTaskType == .coding,
                           (session.resolvedExecutionLocation.kind == .local
                            || session.resolvedExecutionLocation.kind == .worktree) {
                            Button {
                                Task { await agentViewModel.forkSession(id: session.id) }
                            } label: {
                                Label("Fork Task", systemImage: "arrow.triangle.branch")
                            }
                            .disabled(session.workspace == nil)
                        }

                        if session.resolvedTaskType == .coding,
                           session.resolvedExecutionLocation.kind == .local,
                           session.workspace?.gitRepository == true {
                            Button {
                                Task {
                                    await agentViewModel.handoffSessionToWorktree(
                                        id: session.id
                                    )
                                }
                            } label: {
                                Label(
                                    "Move to Managed Worktree",
                                    systemImage: "arrow.triangle.branch"
                                )
                            }
                        } else if session.resolvedTaskType == .coding,
                                  session.resolvedExecutionLocation.kind == .worktree {
                            Button {
                                Task {
                                    await agentViewModel.handoffSessionToLocal(id: session.id)
                                }
                            } label: {
                                Label(
                                    "Move Back to Local",
                                    systemImage: "internaldrive"
                                )
                            }
                        }

                        if session.resolvedTaskType == .coding,
                           (session.resolvedExecutionLocation.kind == .local
                            || session.resolvedExecutionLocation.kind == .worktree) {
                            Menu {
                                let runners = agentViewModel.remoteRunnerSummaries.filter {
                                    $0.configuration.enabled && $0.hasCredential
                                }
                                if runners.isEmpty {
                                    Text("沒有可用的 SSH Runner")
                                } else {
                                    ForEach(runners) { runner in
                                        Button {
                                            Task {
                                                await agentViewModel.handoffSessionToRemote(
                                                    id: session.id,
                                                    runnerID: runner.id
                                                )
                                            }
                                        } label: {
                                            Label(
                                                runner.configuration.name,
                                                systemImage: "server.rack"
                                            )
                                        }
                                    }
                                }
                            } label: {
                                Label("Move to SSH Runner", systemImage: "network")
                            }
                            .disabled(
                                agentViewModel.remoteRunnerSummaries.allSatisfy {
                                    !$0.configuration.enabled || !$0.hasCredential
                                }
                            )
                        } else if session.resolvedTaskType == .coding,
                                  session.resolvedExecutionLocation.kind == .ssh {
                            Button {
                                Task {
                                    await agentViewModel.handoffSessionFromRemoteToLocal(
                                        id: session.id
                                    )
                                }
                            } label: {
                                Label("Move Back to Local", systemImage: "internaldrive")
                            }
                            .disabled(session.localWorkspace == nil)
                        }
                    }
                } label: {
                    if agentViewModel.selectedSessionLocationIsMutating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 28, height: 28)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selectedTaskActionsAreDisabled)
                .help("Task Actions")
                .accessibilityLabel("Task Actions")
            }

            Menu {
                Section("切換 Task 路由（目前連線）") {
                    if chatViewModel.availableModels.isEmpty {
                        Text("尚未取得模型")
                    } else {
                        ForEach(chatViewModel.availableModels, id: \.self) { model in
                            Button {
                                agentViewModel.selectModel(model, route: chatViewModel.settings)
                            } label: {
                                if model == agentViewModel.selectedSession?.model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    Task { await chatViewModel.refreshModels() }
                } label: {
                    Label("重新整理模型", systemImage: "arrow.clockwise")
                }
                Button { chatViewModel.isShowingSettings = true } label: {
                    Label("連線與 Agent 設定", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 7) {
                    if chatViewModel.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "network")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(
                            capturedAgentRouteLabel(
                                session: agentViewModel.selectedSession,
                                settings: chatViewModel.settings
                            )
                        )
                            .font(.caption.weight(.semibold))
                        Text(selectedModelLabel)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(
                agentViewModel.selectedSession == nil
                    || agentViewModel.selectedSessionIsRunning
                    || agentViewModel.selectedGoalIsMutating
            )

            Button {
                isShowingModelParameters.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) {
                        let mode = chatViewModel.effectiveModelParameters(
                            for: modelParameterRoute
                        ).mode
                        Circle()
                            .fill(mode == .auto ? Color.green : LumaTheme.accent)
                            .frame(width: 6, height: 6)
                    }
            }
            .buttonStyle(.plain)
            .help("目前 Agent 模型參數")
            .disabled(
                modelParameterRoute.modelID.isEmpty
                    || agentViewModel.selectedSessionIsRunning
            )
            .popover(isPresented: $isShowingModelParameters, arrowEdge: .bottom) {
                ModelParameterEditor(
                    viewModel: chatViewModel,
                    route: modelParameterRoute,
                    compact: true
                )
                .padding(8)
            }

            Button { chatViewModel.isShowingSettings = true } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("設定")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(LumaTheme.surface)
        .sheet(isPresented: $isShowingLocalMemories) {
            AgentLocalMemoryPane()
                .environmentObject(agentViewModel)
        }
        .alert("自訂專案名稱", isPresented: $isRenamingProject) {
            TextField("留空使用資料夾名稱", text: $projectNameDraft)
            Button("取消", role: .cancel) {}
            Button("儲存") {
                Task { await agentViewModel.renameSelectedProject(to: projectNameDraft) }
            }
        } message: {
            Text("名稱會套用到此專案的所有 Coding 任務；不會重新命名資料夾或任務對話。")
        }
    }

    private func executionLocationIcon(_ session: AgentSession) -> String {
        switch session.resolvedExecutionLocation.kind {
        case .local: "internaldrive"
        case .worktree: "arrow.triangle.branch"
        case .ssh: "network"
        case .futureCloud: "cloud"
        }
    }

    private var selectedModelLabel: String {
        guard let model = agentViewModel.selectedSession?.model, !model.isEmpty else {
            return "選擇 Agent 模型"
        }
        return model
    }

    private var selectedTaskActionsAreDisabled: Bool {
        agentViewModel.selectedSessionIsRunning
            || agentViewModel.selectedSessionIsStopping
            || agentViewModel.selectedGoalIsMutating
            || agentViewModel.selectedSessionLocationIsMutating
            || agentViewModel.selectedSession.map {
                agentViewModel.recoveryBlockedSessionIDs.contains($0.id)
            } == true
    }
}

private struct NoAgentSessionView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 45, weight: .light))
                .foregroundStyle(LumaTheme.accent)
            VStack(spacing: 7) {
                Text(agentViewModel.selectedProject?.name ?? "尚未選擇 Coding 任務")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text(agentViewModel.selectedProject == nil
                     ? "切換 Plan 或 Agent 只會切換介面；由你決定何時建立新任務。"
                     : "Project 已開啟，但不會自動建立 Task；由你決定何時開始。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                agentViewModel.createSession(
                    mode: agentViewModel.activeMode,
                    route: chatViewModel.settings
                )
            } label: {
                Label("新增 Coding 任務", systemImage: "square.and.pencil")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            if agentViewModel.selectedProject == nil {
                Button {
                    Task { await agentViewModel.createProject() }
                } label: {
                    Label("加入 Project（不建立 Task）", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(agentViewModel.isMutatingProject)
            }
            Spacer()
        }
        .padding(24)
    }
}

private struct AgentStateLabel: View {
    let state: AgentRunState

    var body: some View {
        Text(label)
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .idle: "Ready"
        case .running: "Running"
        case .awaitingApproval: "Approval"
        case .paused: "Paused"
        case .completed: "Completed"
        case .cancelled: "Stopped"
        case .failed: "Failed"
        case .stepLimit: "Step limit"
        }
    }

    private var color: Color {
        switch state {
        case .running: LumaTheme.accent
        case .completed: .green
        case .failed, .stepLimit: .orange
        default: .secondary
        }
    }
}

private struct WorkspaceRequiredView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 45, weight: .light))
                .foregroundStyle(LumaTheme.accent)
            VStack(spacing: 7) {
                Text("開啟一個 Coding Project")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Plan 與 Agent 的本機工具只會在你選擇的 Workspace 內運作。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await agentViewModel.chooseWorkspace(route: chatViewModel.settings) }
            } label: {
                Label("Open Project", systemImage: "folder")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
    }
}

private struct AgentWelcomeView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel

    private let suggestions = [
        ("理解這個專案", "point.3.connected.trianglepath.dotted", "先掃描專案架構、主要資料流與建置方式，再提出重點摘要。"),
        ("修正問題並測試", "wrench.and.screwdriver", "分析目前專案，找出最明顯的問題，做最小修正並執行相關測試。"),
        ("審查目前變更", "doc.text.magnifyingglass", "查看 Git 狀態與 diff，審查 correctness、安全性與可能的 regression。")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 65)
                Image(systemName: agentViewModel.activeMode == .plan ? "list.bullet.clipboard.fill" : "terminal.fill")
                    .font(.system(size: 43, weight: .medium))
                    .foregroundStyle(LumaTheme.accent)
                VStack(spacing: 7) {
                    Text(agentViewModel.activeMode == .plan ? "先理解，再決定" : "交給 Agent 動手完成")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text(agentViewModel.activeMode == .plan
                         ? "Plan 只會讀取與分析，不會修改專案。"
                         : "Agent 會逐步檢查、修改、執行與驗證，危險操作仍需你確認。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    ForEach(suggestions, id: \.0) { item in
                        Button { agentViewModel.draft = item.2 } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: item.1)
                                    .font(.title3)
                                    .foregroundStyle(LumaTheme.accent)
                                Text(item.0)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(radius: 14, padding: 13)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 650)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

private enum AgentTimelineItem: Identifiable {
    case message(AgentMessage)
    case step(AgentStep)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id.uuidString)"
        case .step(let step): "step-\(step.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .message(let message): message.createdAt
        case .step(let step): step.startedAt
        }
    }
}

private struct AgentActivityTimeline: View {
    let session: AgentSession

    private var items: [AgentTimelineItem] {
        let messages = session.messages.compactMap { message -> AgentTimelineItem? in
            guard message.role == .user
                    || (message.role == .assistant && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            else { return nil }
            return .message(message)
        }
        return (messages + session.steps.map(AgentTimelineItem.step)).sorted { $0.date < $1.date }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let skills = session.loadedSkills, !skills.isEmpty {
                        AgentLoadedSkillsPanel(skills: skills)
                    }
                    if !session.todos.isEmpty {
                        AgentTodoPanel(todos: session.todos)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .message(let message): AgentMessageBubble(message: message)
                        case .step(let step): AgentStepCard(step: step)
                        }
                    }
                    if !session.changes.isEmpty {
                        AgentChangesPanel(
                            changes: session.changes,
                            executionLocation: session.resolvedExecutionLocation
                        )
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .onAppear { proxy.scrollTo("agent-bottom", anchor: .bottom) }
            .onChange(of: session.updatedAt) { proxy.scrollTo("agent-bottom", anchor: .bottom) }
        }
    }
}

private struct AgentLoadedSkillsPanel: View {
    let skills: [LoadedSkillReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Loaded Skills", systemImage: "text.book.closed.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(LumaTheme.accent)
            ForEach(skills) { skill in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("$\(skill.name)")
                        .font(.caption.monospaced().weight(.semibold))
                    Text(skill.source.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        skill.permissions.isEmpty
                            ? "No extra permissions"
                            : skill.permissions.map(\.title).joined(separator: ", ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Text("指令按 run 暫態載入；Session 只保存來源與權限 metadata。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .glassCard(radius: 13, padding: 12)
    }
}

private struct AgentMessageBubble: View {
    let message: AgentMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 90) }
            if !isUser { BrandMark(size: 28).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AgentMarkdownText(message.content)
                }
                if !message.imageAttachments.isEmpty {
                    AgentMessageImageAttachments(attachments: message.imageAttachments)
                }
            }
                .padding(.horizontal, isUser ? 14 : 0)
                .padding(.vertical, isUser ? 10 : 0)
                .background(isUser ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 15))
                .textSelection(.enabled)
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

private struct AgentMessageImageAttachments: View {
    let attachments: [AgentImageAttachmentReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                Label {
                    Text("\(attachment.name) · \(attachment.pixelWidth)×\(attachment.pixelHeight)")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "photo")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.06), in: Capsule())
                .help("\(attachment.mimeType) · \(attachment.byteCount) bytes")
            }
        }
    }
}

private struct AgentMarkdownText: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .full)
        ) {
            Text(attributed).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentStepCard: View {
    let step: AgentStep
    @State private var expanded = false

    init(step: AgentStep) {
        self.step = step
        // A newly-launched terminal command should visibly stream without an
        // extra click. Persisted/completed cards retain the compact default.
        _expanded = State(initialValue: step.kind == .running && step.status == .running)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let call = step.toolCall {
                    Text(prettyJSON(call.arguments))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result = step.toolResult {
                    Divider()
                    Text(result.content)
                        .font(.system(.caption, design: result.change == nil ? .default : .monospaced))
                        .foregroundStyle(result.isError ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let destination = PullRequestToolResultLink.destination(for: step) {
                        Link(destination: destination) {
                            Label("Open Pull Request", systemImage: "arrow.up.right.square")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    if let change = result.change, !change.unifiedDiff.isEmpty {
                        AgentDiffText(diff: change.unifiedDiff)
                    }
                } else if let progress = step.terminalProgress {
                    Divider()
                    AgentTerminalProgressView(progress: progress)
                } else if let detail = step.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                stepIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.callout.weight(.medium))
                    if let detail = step.detail, !expanded {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let duration = step.toolResult?.duration {
                    Text(duration.formatted(.number.precision(.fractionLength(2))) + "s")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)) }
    }

    @ViewBuilder
    private var stepIcon: some View {
        if step.status == .running {
            ProgressView().controlSize(.small).frame(width: 24)
        } else {
            Image(systemName: icon)
                .foregroundStyle(step.status == .failed ? Color.orange : LumaTheme.accent)
                .frame(width: 24)
        }
    }

    private var icon: String {
        switch step.kind {
        case .thinking: "brain.head.profile"
        case .reading: "doc.text.magnifyingglass"
        case .searching: "magnifyingglass"
        case .editing: "square.and.pencil"
        case .running, .testing: "terminal"
        case .git: "arrow.triangle.branch"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .approval: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

private struct AgentTerminalProgressView: View {
    let progress: AgentTerminalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !progress.stdout.isEmpty {
                stream(title: "STDOUT", value: progress.stdout, color: .secondary)
            }
            if !progress.stderr.isEmpty {
                stream(title: "STDERR", value: progress.stderr, color: .orange)
            }
            if progress.truncated {
                Label("即時輸出已達顯示上限；完成後可查看正式結果或 artifact。", systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stream(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            ScrollView(.vertical) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct AgentDiffText: View {
    let diff: String

    var body: some View {
        Text(diff)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentTodoPanel: View {
    let todos: [AgentTodo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plan", systemImage: "checklist")
                .font(.callout.weight(.semibold))
            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: todoIcon(todo.status))
                        .foregroundStyle(todo.status == .inProgress ? LumaTheme.accent : .secondary)
                    Text(todo.title)
                        .font(.callout)
                        .strikethrough(todo.status == .completed)
                        .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 13, padding: 13)
    }

    private func todoIcon(_ status: AgentTodoStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "arrow.right.circle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }
}

private struct AgentChangesPanel: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let changes: [AgentChangeRecord]
    let executionLocation: AgentExecutionLocation
    @State private var expanded = false
    @State private var confirmUndoTask = false

    private var latestActionableChangeID: UUID? {
        changes.last(where: { $0.disposition == nil })?.id
    }

    private var allowsLocalChangeActions: Bool {
        executionLocation.kind == .local || executionLocation.kind == .worktree
    }

    var body: some View {
        DisclosureGroup("Changed Files · \(changes.count)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(changes) { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(change.relativePath, systemImage: change.kind == .create ? "plus.circle" : "pencil.circle")
                            .font(.callout.weight(.medium))
                        if !change.unifiedDiff.isEmpty { AgentDiffText(diff: change.unifiedDiff) }
                        HStack(spacing: 8) {
                            Spacer()
                            if change.disposition == .kept {
                                Label("Kept", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            } else if change.disposition == .unavailable {
                                Label("Undo snapshot unavailable", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            } else if allowsLocalChangeActions,
                                      change.id == latestActionableChangeID {
                                Button("Keep") {
                                    Task { await agentViewModel.keepChange(id: change.id) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(agentViewModel.selectedSessionIsRunning)
                                Button("Revert", role: .destructive) {
                                    Task { await agentViewModel.revertChange(id: change.id) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(agentViewModel.selectedSessionIsRunning)
                            } else {
                                Text("先處置較新的變更")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if allowsLocalChangeActions {
                    HStack {
                        Spacer()
                        Button("Undo Last Change") {
                            Task { await agentViewModel.undoLastChange() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(agentViewModel.selectedSessionIsRunning || latestActionableChangeID == nil)
                        Button("Undo Task…", role: .destructive) { confirmUndoTask = true }
                            .buttonStyle(.bordered)
                            .disabled(agentViewModel.selectedSessionIsRunning || latestActionableChangeID == nil)
                    }
                } else {
                    Label(
                        "Remote Task 的本機 Undo snapshot 僅供檢視；移回 Local 後才能處置。",
                        systemImage: "network"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(LumaTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("復原這個 Task 的所有檔案變更？", isPresented: $confirmUndoTask) {
            Button("Undo Task", role: .destructive) {
                Task { await agentViewModel.undoTaskChanges() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會依相反順序套用本次 Task 的 snapshots；Git push 不在任何 Agent 工具中。")
        }
    }
}

private struct AgentApprovalCard: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let request: AgentApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    request.permissionLevel == .dangerous ? "Dangerous action" : "Agent 需要你的允許",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(request.permissionLevel == .dangerous ? Color.orange : LumaTheme.accent)
                Spacer()
                Text(request.displayName).font(.caption).foregroundStyle(.secondary)
            }
            if let session = agentViewModel.sessions.first(where: { $0.id == request.sessionID }) {
                Label(
                    "\(session.title) · \(agentViewModel.projectDisplayName(for: session))",
                    systemImage: "folder"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let host = request.remoteHost,
               let user = request.remoteUser,
               let root = request.remoteWorkspaceRoot {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Remote execution", systemImage: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Backend: \(request.executionBackend ?? "SSH")")
                    Text("Host: \(host)\(request.remotePort.map { ":\($0)" } ?? "")")
                    Text("User: \(user)")
                    Text("Path: \(root)")
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }
            if let command = request.command {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
            }
            if let cwd = request.workingDirectory {
                Text("Working directory: \(cwd)").font(.caption).foregroundStyle(.secondary)
            }
            if let reason = request.reason {
                Text("Reason: \(reason)").font(.caption).foregroundStyle(.secondary)
            }
            if let scope = computerUseApprovalScope {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Computer Use scope", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                    Text(scope.summary)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Label(
                        scope.isAlwaysAllowEligible
                            ? "Always Allow 只可套用於這個精確範圍的唯讀觀察。"
                            : "Always Allow 不適用於此動作；本次核准仍是 fresh capture 綁定的單次授權。",
                        systemImage: scope.isAlwaysAllowEligible
                            ? "checkmark.shield"
                            : "hand.raised.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(scope.isAlwaysAllowEligible ? Color.gray : Color.orange)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            if computerUseApprovalScope?.isAlwaysAllowEligible == false {
                Label(
                    "External Side Effect · Not Undoable",
                    systemImage: "arrow.up.forward.square.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
            if let preview = computerUsePreview {
                ComputerUseApprovalPreview(preview: preview)
            }
            if request.command == nil {
                Text(prettyArguments)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            if let diff = request.diffPreview, !diff.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Preview Diff").font(.caption.weight(.semibold))
                    AgentDiffText(diff: diff)
                }
            }
            if !request.riskReasons.isEmpty {
                Text(request.riskReasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("拒絕", role: .destructive) {
                    agentViewModel.resolveApproval(.deny, requestID: request.id)
                }
                Button("本次允許") {
                    agentViewModel.resolveApproval(.allowOnce, requestID: request.id)
                }
                    .buttonStyle(.borderedProminent)
                if canAllowForSession {
                    Button("本 Session 允許") {
                        agentViewModel.resolveApproval(.allowForSession, requestID: request.id)
                    }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(request.permissionLevel == .dangerous ? Color.orange.opacity(0.55) : LumaTheme.accent.opacity(0.35))
        }
    }

    private var computerUseApprovalScope: ComputerUseApprovalScope? {
        ComputerUseScopedApprovalPolicy.scope(
            toolName: request.toolName,
            arguments: request.arguments
        )
    }

    private var canAllowForSession: Bool {
        guard request.permissionLevel != .dangerous else { return false }
        return computerUseApprovalScope?.isAlwaysAllowEligible ?? true
    }

    private var computerUsePreview: ComputerUseApprovalPreviewData? {
        guard request.toolName.hasPrefix("computer_"),
              let captureID = request.arguments["capture_id"]?.stringValue,
              let session = agentViewModel.sessions.first(where: {
                  $0.id == request.sessionID
              }),
              let message = session.messages.reversed().first(where: {
                  $0.role == .tool
                      && $0.name == "computer_screenshot"
                      && $0.content.contains(captureID)
                      && !$0.imageAttachments.isEmpty
              }),
              let attachment = message.imageAttachments.first else {
            return nil
        }
        return ComputerUseApprovalPreviewData(
            sessionID: request.sessionID,
            attachment: attachment,
            x: argumentNumber("x"),
            y: argumentNumber("y"),
            semanticFrame: semanticFrame(in: session, captureID: captureID)
        )
    }

    private func semanticFrame(in session: AgentSession, captureID: String) -> CGRect? {
        guard let elementID = request.arguments["element_id"]?.stringValue else {
            return nil
        }
        for step in session.steps.reversed() {
            guard step.toolCall?.name == "computer_accessibility_snapshot",
                  step.toolResult?.data?["capture_id"]?.stringValue == captureID,
                  let elements = step.toolResult?.data?["elements"]?.arrayValue,
                  let element = elements.first(where: {
                      $0["element_id"]?.stringValue == elementID
                  }),
                  let x = jsonNumber(element["x"]),
                  let y = jsonNumber(element["y"]),
                  let width = jsonNumber(element["width"]),
                  let height = jsonNumber(element["height"]),
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                  width > 0, height > 0 else {
                continue
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    private func jsonNumber(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value else { return nil }
        return number
    }

    private func argumentNumber(_ name: String) -> Double? {
        guard case .number(let value) = request.arguments[name] else { return nil }
        return value
    }

    private var prettyArguments: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(request.arguments), as: UTF8.self)) ?? "{}"
    }
}

private struct ComputerUseApprovalPreviewData {
    let sessionID: UUID
    let attachment: AgentImageAttachmentReference
    let x: Double?
    let y: Double?
    let semanticFrame: CGRect?
}

private struct ComputerUseApprovalPreview: View {
    let preview: ComputerUseApprovalPreviewData
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("不可變的核准畫面")
                .font(.caption.weight(.semibold))
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(
                            CGFloat(preview.attachment.pixelWidth)
                                / CGFloat(preview.attachment.pixelHeight),
                            contentMode: .fit
                        )
                        .overlay { markers }
                } else {
                    Label("無法載入已驗證的截圖；建議拒絕並重新擷取。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 280)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("十字標示座標點擊；紅框標示 capture-bound 語意元素。其他動作仍使用同一張畫面確認目標視窗。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: preview.attachment.id) {
            let data = try? AgentImageAttachmentStore()
                .loadPayload(
                    for: preview.attachment,
                    sessionID: preview.sessionID
                )
                .data
            image = data.flatMap { NSImage(data: $0) }
        }
    }

    @ViewBuilder
    private var markers: some View {
        if preview.attachment.pixelWidth > 0,
           preview.attachment.pixelHeight > 0 {
            GeometryReader { geometry in
                ZStack {
                    if let x = preview.x, let y = preview.y,
                       x.isFinite, y.isFinite {
                        let px = geometry.size.width
                            * CGFloat(x / Double(preview.attachment.pixelWidth))
                        let py = geometry.size.height
                            * CGFloat(y / Double(preview.attachment.pixelHeight))
                        ZStack {
                            Circle()
                                .stroke(Color.red, lineWidth: 2)
                                .frame(width: 22, height: 22)
                            Rectangle().fill(Color.red).frame(width: 30, height: 2)
                            Rectangle().fill(Color.red).frame(width: 2, height: 30)
                        }
                        .shadow(color: .white, radius: 1)
                        .position(x: px, y: py)
                    }
                    if let frame = preview.semanticFrame,
                       frame.minX.isFinite, frame.minY.isFinite,
                       frame.width.isFinite, frame.height.isFinite {
                        let scaleX = geometry.size.width
                            / CGFloat(preview.attachment.pixelWidth)
                        let scaleY = geometry.size.height
                            / CGFloat(preview.attachment.pixelHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.red, lineWidth: 2)
                            .frame(
                                width: CGFloat(frame.width) * scaleX,
                                height: CGFloat(frame.height) * scaleY
                            )
                            .position(
                                x: CGFloat(frame.midX) * scaleX,
                                y: CGFloat(frame.midY) * scaleY
                            )
                    }
                }
            }
        }
    }
}

private struct AgentComposer: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var presentedSheet: AgentComposerSheet?
    @State private var editingQueuedFollowUp: AgentQueuedFollowUp?
    @State private var editingQueuedSessionID: UUID?
    @State private var queuedEditText = ""

    private var prefersSteerFollowUp: Bool {
        agentViewModel.preferredFollowUpBehavior == .steer
    }

    private var canPrimarySend: Bool {
        if agentViewModel.selectedSessionIsRunning {
            return prefersSteerFollowUp
                ? agentViewModel.canSteerCurrentRun : agentViewModel.canQueueFollowUp
        }
        return agentViewModel.canSend
    }

    private var executionLocationKind: AgentExecutionLocationKind? {
        agentViewModel.selectedSession?.resolvedExecutionLocation.kind
    }

    private var allowsLocalWorkspacePicker: Bool {
        executionLocationKind == .local || executionLocationKind == .worktree
    }

    private var allowsWorkspaceReplacement: Bool {
        executionLocationKind == .local
    }

    var body: some View {
        VStack(spacing: 8) {
            if let session = agentViewModel.selectedSession {
                HStack(spacing: 8) {
                    if AgentDetailSurfacePolicy.showsExecutePlan(
                        taskType: session.resolvedTaskType,
                        mode: session.mode,
                        state: session.state
                    ) {
                        Button {
                            agentViewModel.executePlan(route: chatViewModel.settings, apiKey: chatViewModel.apiKey)
                        } label: {
                            Label("Execute Plan", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if [.failed, .paused, .stepLimit, .cancelled].contains(session.state),
                       !agentViewModel.selectedSessionIsRunning {
                        Button {
                            if session.goal != nil {
                                agentViewModel.resumeGoal(
                                    route: chatViewModel.settings,
                                    apiKey: chatViewModel.apiKey
                                )
                            } else {
                                agentViewModel.retry(
                                    route: chatViewModel.settings,
                                    apiKey: chatViewModel.apiKey
                                )
                            }
                        } label: {
                            Label(
                                session.state == .paused ? "Resume" : (session.state == .stepLimit ? "繼續" : "重試"),
                                systemImage: session.state == .paused ? "play.fill" : "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
            }

            if agentViewModel.isAttachingImage {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在驗證並加入影像…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !agentViewModel.pendingImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(agentViewModel.pendingImageAttachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "photo")
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(attachment.name).lineLimit(1)
                                    Text("\(attachment.pixelWidth)×\(attachment.pixelHeight)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    agentViewModel.removePendingImageAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除影像附件")
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        Task { await agentViewModel.chooseWorkspace(route: chatViewModel.settings) }
                    } label: {
                        Label("Open Project…", systemImage: "folder.badge.plus")
                    }
                    .disabled(
                        !allowsWorkspaceReplacement
                            || agentViewModel.selectedSessionIsRunning
                            || agentViewModel.selectedGoalIsMutating
                    )
                    Button {
                        agentViewModel.attachWorkspaceFiles()
                    } label: {
                        Label("Attach File…", systemImage: "paperclip")
                    }
                    .disabled(
                        !allowsLocalWorkspacePicker
                            || agentViewModel.selectedSession?.workspace == nil
                            || agentViewModel.selectedSessionIsRunning
                            || agentViewModel.selectedGoalIsMutating
                    )
                    Button {
                        Task { await agentViewModel.attachWorkspaceImage() }
                    } label: {
                        Label("Attach Image…", systemImage: "photo")
                    }
                    .disabled(
                        !allowsLocalWorkspacePicker
                            || agentViewModel.selectedSession?.workspace == nil
                            || agentViewModel.selectedSessionIsRunning
                            || agentViewModel.selectedGoalIsMutating
                            || agentViewModel.isAttachingImage
                            || agentViewModel.pendingImageAttachments.count
                                >= AgentImageAttachmentLimits.maximumAttachmentsPerMessage
                    )
                    Divider()
                    Button {
                        presentedSheet = .context
                    } label: {
                        Label("Add Context…", systemImage: "doc.badge.plus")
                    }
                    .disabled(
                        agentViewModel.selectedSessionIsRunning
                            || agentViewModel.selectedGoalIsMutating
                    )
                    Button {
                        presentedSheet = .mcp
                    } label: {
                        Label("MCP…", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(
                        agentViewModel.selectedSessionIsRunning
                            || agentViewModel.selectedGoalIsMutating
                    )
                    Divider()
                    Button {
                        presentedSheet = .goalStart
                    } label: {
                        Label("Start Goal…", systemImage: "scope")
                    }
                    .disabled(!agentViewModel.canStartGoal)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 31, height: 31)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                TextField(
                    "",
                    text: $agentViewModel.draft,
                    prompt: Text("描述要在這個專案完成的工作"),
                    axis: .vertical
                )
                .font(.body)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .lineLimit(1...6)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .padding(.vertical, 4)
                .accessibilityLabel("Agent 訊息輸入框")

                if agentViewModel.selectedSessionIsRunning {
                    Button {
                        agentViewModel.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        agentViewModel.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if agentViewModel.selectedSessionIsRunning {
                    Button {
                        Task {
                            if prefersSteerFollowUp {
                                await agentViewModel.queueFollowUp(
                                    route: chatViewModel.settings,
                                    apiKey: chatViewModel.apiKey
                                )
                            } else {
                                await agentViewModel.steerCurrentRun()
                            }
                        }
                    } label: {
                        Label(
                            prefersSteerFollowUp ? "排隊" : "Steer",
                            systemImage: prefersSteerFollowUp ? "text.badge.plus" : "arrow.up.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(prefersSteerFollowUp
                        ? !agentViewModel.canQueueFollowUp : !agentViewModel.canSteerCurrentRun)
                    .help(prefersSteerFollowUp
                        ? "目前執行完成後送出（⌘⇧↩）"
                        : "送入目前執行的下一模型回合（⌘⇧↩）")
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                }

                Button {
                    if agentViewModel.selectedSessionIsRunning {
                        Task {
                            if prefersSteerFollowUp {
                                await agentViewModel.steerCurrentRun()
                            } else {
                                await agentViewModel.queueFollowUp(
                                    route: chatViewModel.settings,
                                    apiKey: chatViewModel.apiKey
                                )
                            }
                        }
                    } else {
                        agentViewModel.send(route: chatViewModel.settings, apiKey: chatViewModel.apiKey)
                    }
                } label: {
                    Image(systemName: agentViewModel.selectedSessionIsRunning && !prefersSteerFollowUp
                          ? "text.badge.plus" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(
                            canPrimarySend
                                ? Color(nsColor: .windowBackgroundColor) : Color.secondary
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            canPrimarySend
                                ? AnyShapeStyle(Color.primary)
                                : AnyShapeStyle(Color.secondary.opacity(0.16)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canPrimarySend)
                .help(agentViewModel.selectedSessionIsRunning
                    ? (prefersSteerFollowUp
                        ? "Steer：在目前執行的下一模型回合生效"
                        : "排隊：目前執行完成後送出")
                    : "送出訊息")
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(11)
            .background(LumaTheme.elevated, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(LumaTheme.border, lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.045), radius: 12, y: 5)

            if !agentViewModel.selectedQueuedFollowUps.isEmpty,
               let sessionID = agentViewModel.selectedSessionID {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("排隊訊息 · \(agentViewModel.selectedQueuedFollowUps.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if !agentViewModel.selectedSessionIsRunning,
                           agentViewModel.selectedQueuedFollowUps.first?.claimID == nil {
                            Button("送出下一則") {
                                Task {
                                    await agentViewModel.sendNextQueuedFollowUp(
                                        sessionID: sessionID,
                                        route: chatViewModel.settings,
                                        apiKey: chatViewModel.apiKey
                                    )
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    ForEach(agentViewModel.selectedQueuedFollowUps) { entry in
                        HStack(spacing: 8) {
                            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                                .lineLimit(1)
                                .font(.caption)
                            Spacer()
                            if entry.claimID != nil {
                                Text("待核對").font(.caption2).foregroundStyle(.orange)
                                Button("核對") {
                                    Task {
                                        await agentViewModel.resolveClaimedFollowUp(
                                            id: entry.id,
                                            sessionID: sessionID
                                        )
                                    }
                                }
                                .disabled(agentViewModel.selectedSessionIsRunning)
                            } else {
                                Button {
                                    queuedEditText = entry.text
                                    editingQueuedSessionID = sessionID
                                    editingQueuedFollowUp = entry
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .help("編輯排隊訊息")
                                Button {
                                    Task {
                                        await agentViewModel.moveQueuedFollowUp(
                                            id: entry.id,
                                            sessionID: sessionID,
                                            by: -1
                                        )
                                    }
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(agentViewModel.selectedQueuedFollowUps.first?.id == entry.id)
                                .help("提前")
                                Button {
                                    Task {
                                        await agentViewModel.moveQueuedFollowUp(
                                            id: entry.id,
                                            sessionID: sessionID,
                                            by: 1
                                        )
                                    }
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .disabled(agentViewModel.selectedQueuedFollowUps.last?.id == entry.id)
                                .help("延後")
                                Button("移除") {
                                    Task {
                                        await agentViewModel.removeQueuedFollowUp(
                                            id: entry.id,
                                            sessionID: sessionID
                                        )
                                    }
                                }
                            }
                        }
                        .font(.caption2)
                    }
                }
                .padding(9)
                .background(LumaTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }

            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 13)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .context:
                AgentMCPResourcePicker()
                    .environmentObject(agentViewModel)
                    .environmentObject(chatViewModel)
            case .mcp:
                AgentMCPPromptPicker()
                    .environmentObject(agentViewModel)
                    .environmentObject(chatViewModel)
            case .goalStart:
                AgentGoalEditor(mode: .start)
                    .environmentObject(agentViewModel)
                    .environmentObject(chatViewModel)
            }
        }
        .sheet(item: $editingQueuedFollowUp) { entry in
            VStack(alignment: .leading, spacing: 12) {
                Text("編輯排隊訊息").font(.headline)
                TextEditor(text: $queuedEditText)
                    .frame(minHeight: 120)
                HStack {
                    Spacer()
                    Button("取消") { editingQueuedFollowUp = nil }
                    Button("儲存") {
                        guard let sessionID = editingQueuedSessionID else { return }
                        Task {
                            await agentViewModel.updateQueuedFollowUp(
                                id: entry.id,
                                sessionID: sessionID,
                                text: queuedEditText
                            )
                        }
                        editingQueuedFollowUp = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(queuedEditText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || queuedEditText.utf8.count > AgentQueuedFollowUpStore.maximumPromptBytes)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private var footerText: String {
        let route = capturedAgentRouteLabel(
            session: agentViewModel.selectedSession,
            settings: chatViewModel.settings
        )
        switch executionLocationKind {
        case .ssh:
            return "Task 模型路由：\(route)；Filesystem、Shell、Git 與 Build/Test 由 Task-bound SSH Runner 執行；Mac Terminal、Browser、Computer Use 與 executable Plugin 已停用"
        case .futureCloud:
            return "Task 模型路由：\(route)；Cloud execution backend 尚未提供，執行會 fail closed，不會回退到這台 Mac"
        case .local, .worktree, .none:
            break
        }
        if agentViewModel.activeMode == .plan {
            return "Plan 可讀取 Workspace，但不能修改檔案或執行具變更性的命令"
        }
        return "Task 模型路由：\(route)；Filesystem、Terminal、Git 與 MCP 永遠在這台 Mac 執行"
    }
}

private enum AgentComposerSheet: String, Identifiable {
    case context
    case mcp
    case goalStart

    var id: String { rawValue }
}

private enum AgentGoalEditorMode: String, Identifiable {
    case start
    case edit

    var id: String { rawValue }
}

private struct AgentGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    let mode: AgentGoalEditorMode
    @State private var objective = ""
    @State private var completionCriteria = ""
    @State private var didLoadExistingGoal = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(mode == .start ? "Start a durable Goal" : "Edit Goal", systemImage: "scope")
                    .font(.title3.weight(.semibold))
                Text(editorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Objective").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(objective.utf8.count) / \(AgentGoal.maximumObjectiveBytes) bytes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $objective)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 110)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Completion criteria (optional)")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(completionCriteria.utf8.count) / \(AgentGoal.maximumCompletionCriteriaBytes) bytes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                TextEditor(text: $completionCriteria)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 90)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)) }
            }

            HStack {
                Text(mode == .start
                     ? "Goal 會先安全儲存，再啟動 Agent。也可在 Composer 輸入 /goal 目標。"
                     : "執行中不能改寫已送給模型的目標；請先 Pause。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .start ? "Start Goal" : "Save Goal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaveDisabled)
            }
        }
        .padding(22)
        .frame(width: 590)
        .task {
            guard mode == .edit, !didLoadExistingGoal,
                  let goal = agentViewModel.selectedSession?.goal else { return }
            objective = goal.objective
            completionCriteria = goal.completionCriteria ?? ""
            didLoadExistingGoal = true
        }
    }

    private var editorDescription: String {
        if mode == .start {
            return "Goal 會跨暫停、App 重開與模型錯誤持續存在，直到完成或手動清除。"
        }
        return "更新後 Goal 會回到可繼續狀態；既有任務歷史不會被刪除。"
    }

    private var isSaveDisabled: Bool {
        objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || objective.utf8.count > AgentGoal.maximumObjectiveBytes
            || completionCriteria.utf8.count > AgentGoal.maximumCompletionCriteriaBytes
            || isSaving
            || agentViewModel.selectedGoalIsMutating
            || (mode == .start && !agentViewModel.canStartGoal)
            || (mode == .edit && agentViewModel.selectedSessionIsRunning)
    }

    private func save() {
        isSaving = true
        Task {
            let succeeded: Bool
            switch mode {
            case .start:
                succeeded = await agentViewModel.startGoal(
                    objective: objective,
                    completionCriteria: completionCriteria,
                    route: chatViewModel.settings,
                    apiKey: chatViewModel.apiKey
                )
            case .edit:
                succeeded = await agentViewModel.updateGoal(
                    objective: objective,
                    completionCriteria: completionCriteria
                )
            }
            isSaving = false
            if succeeded { dismiss() }
        }
    }
}

private struct AgentMCPResourcePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var selectedID: String?
    @State private var isLoading = false

    private var choices: [AgentMCPResourceChoice] { agentViewModel.availableMCPResources }
    private var selectedChoice: AgentMCPResourceChoice? {
        choices.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Context from MCP").font(.headline)
                    Text("選擇已連線 Server 的 resource；內容會在你確認後讀取並加入 Composer。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            if choices.isEmpty {
                MCPComposerEmptyState(
                    title: "沒有可用的 MCP Resources",
                    detail: "請先連線支援 Resources 的 MCP Server。",
                    openSettings: openSettings
                )
            } else {
                List(choices, selection: $selectedID) { choice in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.title).font(.callout.weight(.medium))
                        Text("\(choice.serverName) · \(choice.resource.uri)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let description = choice.resource.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(choice.id)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("Binary resources 只加入安全摘要，不會把 base64 填入 Composer。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                Button("Add Context", action: addSelectedResource)
                .buttonStyle(.borderedProminent)
                .disabled(selectedChoice == nil || isLoading)
            }
        }
        .padding(20)
        .frame(width: 640, height: 460)
    }

    private func openSettings() {
        dismiss()
        chatViewModel.isShowingSettings = true
    }

    private func addSelectedResource() {
        guard let choice = selectedChoice else { return }
        isLoading = true
        Task {
            let inserted = await agentViewModel.addMCPResourceContext(choice)
            isLoading = false
            if inserted { dismiss() }
        }
    }
}

private struct AgentMCPPromptPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var selectedID: String?
    @State private var argumentValues: [String: String] = [:]
    @State private var isLoading = false

    private var choices: [AgentMCPPromptChoice] { agentViewModel.availableMCPPrompts }
    private var selectedChoice: AgentMCPPromptChoice? {
        choices.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Insert MCP Prompt").font(.headline)
                    Text("Prompts 只會在你選擇、填入參數並按 Insert 後取得。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }

            if choices.isEmpty {
                MCPComposerEmptyState(
                    title: "沒有可用的 MCP Prompts",
                    detail: "請先連線支援 Prompts 的 MCP Server。",
                    openSettings: openSettings
                )
            } else {
                HStack(alignment: .top, spacing: 12) {
                    List(choices, selection: $selectedID) { choice in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title).font(.callout.weight(.medium))
                            Text(choice.serverName).font(.caption2).foregroundStyle(.secondary)
                            if let description = choice.prompt.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(choice.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 270)

                    Divider()
                    promptArguments
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            HStack {
                Text("非文字內容會以類型摘要表示，不會把未檢視的 binary 資料插入輸入框。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { dismiss() }
                Button("Insert", action: insertSelectedPrompt)
                .buttonStyle(.borderedProminent)
                .disabled(selectedChoice == nil || isLoading)
            }
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .onChange(of: selectedID) { argumentValues = [:] }
    }

    @ViewBuilder
    private var promptArguments: some View {
        if let choice = selectedChoice {
            let arguments = choice.prompt.arguments ?? []
            VStack(alignment: .leading, spacing: 12) {
                Text(choice.title).font(.headline)
                if arguments.isEmpty {
                    Text("這個 Prompt 不需要參數。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Arguments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(arguments.enumerated()), id: \.offset) { _, argument in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 4) {
                                        Text(argument.name).font(.caption.weight(.medium))
                                        if argument.required == true {
                                            Text("Required").font(.caption2).foregroundStyle(.orange)
                                        }
                                    }
                                    TextField(
                                        argument.description ?? argument.name,
                                        text: Binding(
                                            get: { argumentValues[argument.name, default: ""] },
                                            set: { argumentValues[argument.name] = $0 }
                                        )
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    if let description = argument.description, !description.isEmpty {
                                        Text(description).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 9) {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.secondary)
                Text("選擇一個 Prompt").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openSettings() {
        dismiss()
        chatViewModel.isShowingSettings = true
    }

    private func insertSelectedPrompt() {
        guard let choice = selectedChoice else { return }
        isLoading = true
        Task {
            let inserted = await agentViewModel.insertMCPPrompt(
                choice,
                arguments: argumentValues
            )
            isLoading = false
            if inserted { dismiss() }
        }
    }
}

private struct MCPComposerEmptyState: View {
    let title: String
    let detail: String
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Button("Open MCP Settings", action: openSettings)
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
