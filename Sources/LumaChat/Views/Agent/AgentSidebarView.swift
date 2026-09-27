import SwiftUI

struct AgentSidebarView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @State private var pendingDelete: AgentSession?
    @State private var isShowingProjectManager = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 31)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Luma Codex")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(agentViewModel.activeMode == .plan ? "Plan workspace" : "Coding agent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    agentViewModel.createSession(
                        mode: agentViewModel.activeMode,
                        route: chatViewModel.settings
                    )
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("新增 Coding 任務 ⌘N")

                Button {
                    Task { await agentViewModel.createProject() }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(agentViewModel.isMutatingProject)
                .help("加入 Project（不建立 Task） ⇧⌘O")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            AgentProjectSelector(isShowingManager: $isShowingProjectManager)
                .padding(.horizontal, 11)
                .padding(.bottom, 8)

            AgentSearchField(text: $agentViewModel.sidebarSearch)
                .padding(.horizontal, 11)
                .padding(.bottom, 10)

            if agentViewModel.filteredSessions.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(emptyTaskLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List(selection: $agentViewModel.selectedSessionID) {
                    Section("Coding 任務") {
                        ForEach(agentViewModel.filteredSessions) { session in
                            AgentSessionRow(
                                session: session,
                                isRunning: agentViewModel.isRunning(sessionID: session.id),
                                isStopping: agentViewModel.stoppingSessionIDs.contains(session.id),
                                hasPendingApproval: agentViewModel.hasPendingApproval(sessionID: session.id)
                            )
                                .padding(.leading,
                                    session.resolvedTaskType.subagentParentSessionID == nil ? 0 : 18
                                )
                                .tag(session.id)
                                .contextMenu {
                                    Section("Task Actions") {
                                        Button {
                                            Task { await agentViewModel.forkSession(id: session.id) }
                                        } label: {
                                            Label("Fork Task", systemImage: "arrow.triangle.branch")
                                        }
                                        .disabled(
                                            taskActionsAreDisabled(for: session)
                                                || session.workspace == nil
                                                || !(session.resolvedExecutionLocation.kind == .local
                                                    || session.resolvedExecutionLocation.kind == .worktree)
                                        )

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
                                            .disabled(taskActionsAreDisabled(for: session))
                                        } else if session.resolvedTaskType == .coding,
                                                  session.resolvedExecutionLocation.kind == .worktree {
                                            Button {
                                                Task {
                                                    await agentViewModel.handoffSessionToLocal(
                                                        id: session.id
                                                    )
                                                }
                                            } label: {
                                                Label(
                                                    "Move Back to Local",
                                                    systemImage: "internaldrive"
                                                )
                                            }
                                            .disabled(taskActionsAreDisabled(for: session))
                                        }

                                        if session.resolvedTaskType == .coding,
                                           (session.resolvedExecutionLocation.kind == .local
                                            || session.resolvedExecutionLocation.kind == .worktree) {
                                            Menu {
                                                let runners = agentViewModel.remoteRunnerSummaries
                                                    .filter {
                                                        $0.configuration.enabled
                                                            && $0.hasCredential
                                                    }
                                                if runners.isEmpty {
                                                    Text("沒有可用的 SSH Runner")
                                                } else {
                                                    ForEach(runners) { runner in
                                                        Button {
                                                            Task {
                                                                await agentViewModel
                                                                    .handoffSessionToRemote(
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
                                                Label(
                                                    "Move to SSH Runner",
                                                    systemImage: "network"
                                                )
                                            }
                                            .disabled(
                                                taskActionsAreDisabled(for: session)
                                                    || agentViewModel.remoteRunnerSummaries
                                                        .allSatisfy {
                                                            !$0.configuration.enabled
                                                                || !$0.hasCredential
                                                        }
                                            )
                                        } else if session.resolvedTaskType == .coding,
                                                  session.resolvedExecutionLocation.kind == .ssh {
                                            Button {
                                                Task {
                                                    await agentViewModel
                                                        .handoffSessionFromRemoteToLocal(
                                                            id: session.id
                                                        )
                                                }
                                            } label: {
                                                Label(
                                                    "Move Back to Local",
                                                    systemImage: "internaldrive"
                                                )
                                            }
                                            .disabled(
                                                taskActionsAreDisabled(for: session)
                                                    || session.localWorkspace == nil
                                            )
                                        }
                                    }
                                    Divider()
                                    Button(session.pinnedAt == nil ? "釘選 Task" : "取消釘選") {
                                        Task { await agentViewModel.toggleSessionPinned(id: session.id) }
                                    }
                                    .disabled(
                                        agentViewModel.isRunning(sessionID: session.id)
                                            || agentViewModel.stoppingSessionIDs.contains(session.id)
                                    )
                                    Button(session.archivedAt == nil ? "封存 Task" : "還原 Task") {
                                        Task {
                                            await agentViewModel.setSessionArchived(
                                                id: session.id,
                                                archived: session.archivedAt == nil
                                            )
                                        }
                                    }
                                    .disabled(
                                        agentViewModel.isRunning(sessionID: session.id)
                                            || agentViewModel.stoppingSessionIDs.contains(session.id)
                                    )
                                    Divider()
                                    Button("刪除任務…", role: .destructive) {
                                        pendingDelete = session
                                    }
                                    .disabled(
                                        agentViewModel.isRunning(sessionID: session.id)
                                            || agentViewModel.stoppingSessionIDs.contains(session.id)
                                    )
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.55)
            HStack(spacing: 9) {
                Circle()
                    .fill(sidebarStatusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sidebarStatusLabel)
                        .font(.caption.weight(.medium))
                    Text(sidebarProjectLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { chatViewModel.isShowingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help("Agent 與連線設定")
            }
            .padding(12)
        }
        .background(LumaTheme.sidebar)
        .confirmationDialog(
            "永久刪除「\(pendingDelete?.title ?? "此任務")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("刪除 Agent session", role: .destructive) {
                guard let id = pendingDelete?.id else { return }
                pendingDelete = nil
                Task { await agentViewModel.deleteSession(id: id) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Session 記錄會被移除；Workspace 原始檔案不會因此刪除。")
        }
        .sheet(isPresented: $isShowingProjectManager) {
            AgentProjectManagerView()
                .environmentObject(agentViewModel)
                .environmentObject(chatViewModel)
        }
    }

    private var emptyTaskLabel: String {
        if !agentViewModel.sidebarSearch.isEmpty { return "找不到符合條件的 Task" }
        if agentViewModel.selectedProject != nil {
            return agentViewModel.showArchivedTasks
                ? "這個 Project 尚無 Task"
                : "這個 Project 尚無未封存 Task\n由你決定何時建立"
        }
        return "開始第一個 Coding 任務"
    }

    private var sidebarProjectLabel: String {
        if let project = agentViewModel.selectedProject { return project.name }
        if let session = agentViewModel.selectedSession {
            return agentViewModel.projectDisplayName(for: session)
        }
        return "所有 Projects"
    }

    private var sidebarStatusColor: Color {
        if !agentViewModel.pendingApprovalsBySession.isEmpty { return .orange }
        if agentViewModel.activeRunCount > 0 { return LumaTheme.accent }
        return Color.secondary.opacity(0.6)
    }

    private var sidebarStatusLabel: String {
        let approvalCount = agentViewModel.pendingApprovalsBySession.count
        if approvalCount > 0 { return "\(approvalCount) 個任務等待允許" }
        let runCount = agentViewModel.activeRunCount
        if runCount > 0 { return "\(runCount) 個任務執行中" }
        return "Local tools ready"
    }

    private func taskActionsAreDisabled(for session: AgentSession) -> Bool {
        session.resolvedTaskType.subagentParentSessionID != nil
            || agentViewModel.isRunning(sessionID: session.id)
            || agentViewModel.stoppingSessionIDs.contains(session.id)
            || agentViewModel.goalMutationSessionIDs.contains(session.id)
            || agentViewModel.locationMutationSessionIDs.contains(session.id)
            || agentViewModel.recoveryBlockedSessionIDs.contains(session.id)
    }
}

private struct AgentProjectSelector: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @Binding var isShowingManager: Bool

    var body: some View {
        HStack(spacing: 7) {
            Menu {
                Button {
                    agentViewModel.selectProject(nil)
                } label: {
                    if agentViewModel.selectedProjectID == nil {
                        Label("所有 Projects", systemImage: "checkmark")
                    } else {
                        Text("所有 Projects")
                    }
                }

                if !agentViewModel.visibleProjects.isEmpty {
                    Divider()
                    Section("Projects") {
                        ForEach(agentViewModel.visibleProjects) { project in
                            Button {
                                agentViewModel.selectProject(project.id)
                            } label: {
                                HStack {
                                    if agentViewModel.selectedProjectID == project.id {
                                        Image(systemName: "checkmark")
                                    }
                                    if project.isPinned {
                                        Image(systemName: "pin.fill")
                                    }
                                    Text(project.name)
                                    Text("\(project.folders.count) folder")
                                }
                            }
                        }
                    }
                }

                Divider()
                Toggle("顯示封存 Tasks", isOn: $agentViewModel.showArchivedTasks)
                Toggle("顯示封存 Projects", isOn: $agentViewModel.showArchivedProjects)
                Divider()
                Button {
                    Task { await agentViewModel.createProject() }
                } label: {
                    Label("加入 Project…", systemImage: "folder.badge.plus")
                }
                Button {
                    isShowingManager = true
                } label: {
                    Label("管理 Projects…", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: agentViewModel.selectedProject?.isPinned == true
                          ? "pin.fill"
                          : "folder.fill")
                        .foregroundStyle(LumaTheme.accent)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(agentViewModel.selectedProject?.name ?? "所有 Projects")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(projectSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            }
            .menuStyle(.borderlessButton)

            Button {
                isShowingManager = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("管理 Projects")
        }
    }

    private var projectSubtitle: String {
        guard let project = agentViewModel.selectedProject else {
            return "跨 Project 搜尋"
        }
        let taskCount = agentViewModel.sessions.lazy.filter {
            $0.projectID == project.id && $0.archivedAt == nil
        }.count
        return "\(project.folders.count) folders · \(taskCount) tasks"
    }
}

private struct AgentProjectManagerView: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var nameDraft = ""
    @State private var pendingDeleteProject: AgentProject?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Projects")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task {
                            await agentViewModel.createProject()
                            selection = agentViewModel.selectedProjectID
                            syncNameDraft()
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .disabled(agentViewModel.isMutatingProject)
                    .help("加入 Project（不建立 Task）")
                }
                .padding(13)

                List(selection: $selection) {
                    ForEach(managerProjects) { project in
                        HStack(spacing: 8) {
                            Image(systemName: project.isArchived
                                  ? "archivebox.fill"
                                  : (project.isPinned ? "pin.fill" : "folder.fill"))
                                .foregroundStyle(project.isArchived ? .secondary : LumaTheme.accent)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).lineLimit(1)
                                Text("\(project.folders.count) folders · \(taskCount(project.id)) tasks")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(project.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()
                Toggle("顯示封存 Projects", isOn: $agentViewModel.showArchivedProjects)
                    .font(.caption)
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 290)
        } detail: {
            if let project = selectedProject {
                projectEditor(project)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 35, weight: .light))
                        .foregroundStyle(LumaTheme.accent)
                    Text("選擇或加入 Project")
                        .font(.headline)
                    Text("加入 Project 不會自動建立 Task。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 820, height: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            selection = agentViewModel.selectedProjectID
                ?? managerProjects.first?.id
            syncNameDraft()
        }
        .onChange(of: selection) { _, _ in
            syncNameDraft()
        }
        .onChange(of: agentViewModel.projects) { _, _ in
            if selectedProject == nil {
                selection = managerProjects.first?.id
            }
            syncNameDraft()
        }
        .confirmationDialog(
            "永久移除 Project「\(pendingDeleteProject?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteProject != nil },
                set: { if !$0 { pendingDeleteProject = nil } }
            )
        ) {
            Button("移除 Project", role: .destructive) {
                guard let id = pendingDeleteProject?.id else { return }
                pendingDeleteProject = nil
                Task { await agentViewModel.deleteProject(id: id) }
            }
            Button("取消", role: .cancel) { pendingDeleteProject = nil }
        } message: {
            Text("只有沒有任何 Task 的 Project 才能移除；原始 folder 不會被刪除。")
        }
    }

    private var managerProjects: [AgentProject] {
        agentViewModel.projects
            .filter { agentViewModel.showArchivedProjects || !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.lastOpenedAt > rhs.lastOpenedAt
            }
    }

    private var selectedProject: AgentProject? {
        guard let selection else { return nil }
        return agentViewModel.projects.first(where: { $0.id == selection })
    }

    @ViewBuilder
    private func projectEditor(_ project: AgentProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.title2.weight(.semibold))
                        Text(project.isArchived ? "Archived Project" : "Project catalog")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await agentViewModel.toggleProjectPinned(id: project.id) }
                    } label: {
                        Label(
                            project.isPinned ? "取消釘選" : "釘選",
                            systemImage: project.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        Task {
                            await agentViewModel.setProjectArchived(
                                id: project.id,
                                archived: !project.isArchived
                            )
                        }
                    } label: {
                        Label(
                            project.isArchived ? "還原" : "封存",
                            systemImage: project.isArchived ? "arrow.uturn.backward" : "archivebox"
                        )
                    }
                }

                GroupBox("Project 名稱") {
                    HStack {
                        TextField("自訂 Project 名稱", text: $nameDraft)
                        Button("儲存") {
                            Task {
                                _ = await agentViewModel.renameProject(
                                    id: project.id,
                                    to: nameDraft
                                )
                                syncNameDraft()
                            }
                        }
                        .disabled(agentViewModel.isMutatingProject)
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Folders")
                            .font(.headline)
                        Text("每個 Task 只使用其中一個 checkout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            agentViewModel.selectProject(project.id)
                            Task { await agentViewModel.addFolderToSelectedProject() }
                        } label: {
                            Label("加入 Folder", systemImage: "folder.badge.plus")
                        }
                        .disabled(agentViewModel.isMutatingProject || project.isArchived)
                    }

                    ForEach(project.folders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: folder.id == project.primaryFolderID
                                  ? "checkmark.circle.fill"
                                  : "folder")
                                .foregroundStyle(folder.id == project.primaryFolderID
                                                 ? LumaTheme.accent : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.callout.weight(.medium))
                                Text(folder.workspace.rootPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if folder.id != project.primaryFolderID {
                                Button("設為 Primary") {
                                    Task {
                                        await agentViewModel.setPrimaryFolder(
                                            projectID: project.id,
                                            folderID: folder.id
                                        )
                                    }
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Text("Primary")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(LumaTheme.accent)
                            }
                            Button(role: .destructive) {
                                Task {
                                    await agentViewModel.removeProjectFolder(
                                        projectID: project.id,
                                        folderID: folder.id
                                    )
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(project.folders.count == 1)
                            .help("沒有 Task 使用時才能移除")
                        }
                        .padding(11)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                Divider()
                HStack {
                    Text("\(taskCount(project.id)) 個 Task 仍引用這個 Project。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("永久移除 Project…", role: .destructive) {
                        pendingDeleteProject = project
                    }
                    .disabled(taskCount(project.id) > 0 || agentViewModel.isMutatingProject)
                }
            }
            .padding(22)
        }
    }

    private func taskCount(_ projectID: UUID) -> Int {
        agentViewModel.sessions.lazy.filter { $0.projectID == projectID }.count
    }

    private func syncNameDraft() {
        nameDraft = selectedProject?.name ?? ""
    }
}

private struct AgentSessionRow: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let session: AgentSession
    let isRunning: Bool
    let isStopping: Bool
    let hasPendingApproval: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.resolvedTaskType.subagentParentSessionID == nil
                ? session.mode.systemImage : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(session.state == .failed ? Color.orange : LumaTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    if let record = agentViewModel.subagentRecords.first(where: {
                        $0.childSessionID == session.id
                    }) {
                        Text("Subagent · \(record.status.rawValue)")
                            .foregroundStyle(record.status == .failed ? .orange : LumaTheme.accent)
                    }
                    Text(session.workspace == nil
                         ? session.mode.title
                         : agentViewModel.projectDisplayName(for: session))
                        .lineLimit(1)
                    if let folder = agentViewModel.projectFolderName(for: session),
                       let projectID = session.projectID,
                       (agentViewModel.projects.first(where: { $0.id == projectID })?
                        .folders.count ?? 0) > 1 {
                        Text("/")
                        Text(folder).lineLimit(1)
                    }
                    Text("·")
                    Text(agentViewModel.executionLocationLabel(for: session))
                        .foregroundStyle(locationColor)
                    Text("·")
                    Text(session.updatedAt.conversationTimestamp)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hasPendingApproval {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("此任務等待你的允許")
                    .accessibilityLabel("等待允許")
            } else if isStopping {
                ProgressView()
                    .controlSize(.small)
                    .help("正在停止任務")
                    .accessibilityLabel("正在停止")
            } else if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("任務在背景執行")
                    .accessibilityLabel("背景執行中")
            } else if session.archivedAt != nil {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .help("已封存")
            } else if session.pinnedAt != nil {
                Image(systemName: "pin.fill")
                    .foregroundStyle(LumaTheme.accent)
                    .help("已釘選")
            }
        }
        .padding(.vertical, 4)
    }

    private var locationColor: Color {
        switch session.resolvedExecutionLocation.kind {
        case .local: .secondary
        case .worktree: LumaTheme.accent
        case .ssh, .futureCloud: .orange
        }
    }
}

private struct AgentSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋 Coding 任務", text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
}
