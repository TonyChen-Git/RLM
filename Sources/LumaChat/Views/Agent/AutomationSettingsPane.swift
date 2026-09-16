import SwiftUI

struct AutomationSettingsPane: View {
    @ObservedObject var agentViewModel: AgentViewModel
    @State private var editor: AutomationEditorDraft?
    @State private var presentedError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            definitions
            runHistory
        }
        .sheet(item: $editor) { draft in
            AutomationEditorSheet(
                draft: draft,
                projects: agentViewModel.visibleProjects,
                sessions: agentViewModel.sessions,
                onCancel: { editor = nil },
                onSave: { definition in
                    Task {
                        let succeeded = draft.existingID == nil
                            ? await agentViewModel.createAutomation(definition)
                            : await agentViewModel.updateAutomation(definition)
                        if succeeded {
                            editor = nil
                        } else {
                            presentedError = agentViewModel.errorMessage
                            agentViewModel.errorMessage = nil
                        }
                    }
                }
            )
        }
        .alert("Automation 無法完成", isPresented: Binding(
            get: { presentedError != nil },
            set: { if !$0 { presentedError = nil } }
        )) {
            Button("好", role: .cancel) { presentedError = nil }
        } message: {
            Text(presentedError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automations").font(.headline)
                    Text("一次、interval、五欄 cron 與 event-triggered Agent 工作；排程與 run history 會永久保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editor = AutomationEditorDraft(
                        projectID: agentViewModel.selectedProjectID
                            ?? agentViewModel.visibleProjects.first?.id,
                        reviewSourceSessionID: agentViewModel.sessions.first(where: {
                            $0.resolvedTaskType == .coding
                        })?.id
                    )
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agentViewModel.automationSchedulerIsReady)
            }

            Label(
                agentViewModel.automationSchedulerIsReady
                    ? "Scheduler 運作中；App 關閉時的 running run 會被誠實記為 interrupted。"
                    : "Scheduler 未就緒；請查看上方錯誤訊息。",
                systemImage: agentViewModel.automationSchedulerIsReady
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(agentViewModel.automationSchedulerIsReady ? Color.green : Color.orange)

            HStack {
                Label(
                    notificationStatusText,
                    systemImage: agentViewModel.notificationAuthorizationStatus.permitsDelivery
                        ? "bell.badge.fill" : "bell.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if !agentViewModel.notificationAuthorizationStatus.permitsDelivery {
                    Button("啟用系統通知") {
                        Task { _ = await agentViewModel.requestNotificationAuthorization() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var notificationStatusText: String {
        switch agentViewModel.notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            "完成、失敗與需要核准時可送出 macOS 通知；點擊會回到對應 Task。"
        case .notDetermined:
            "系統通知尚未授權；LumaChat 不會在背景自行彈出授權視窗。"
        case .denied:
            "系統通知已被拒絕；可在 macOS 設定中重新允許。"
        case .unavailable:
            "目前平台不提供 macOS 通知。"
        }
    }

    @ViewBuilder
    private var definitions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已儲存的 Automation").font(.headline)
            if agentViewModel.automations.isEmpty {
                Text("尚未建立 Automation。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            } else {
                ForEach(agentViewModel.automations) { automation in
                    automationRow(automation)
                }
            }
        }
    }

    private func automationRow(_ automation: AutomationDefinition) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { automation.isEnabled },
                set: { enabled in
                    Task { await agentViewModel.setAutomationEnabled(id: automation.id, enabled: enabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                Text(automation.name).font(.callout.weight(.semibold))
                Text("\(automation.task.actionKind.displayTitle) · \(automation.schedule.displayDescription) · \(automation.task.worktreeMode.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(automation.task.prompt)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if agentViewModel.automationBusyIDs.contains(automation.id) {
                ProgressView().controlSize(.small)
            }
            Button("Run now") {
                Task { await agentViewModel.runAutomationNow(id: automation.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(agentViewModel.automationBusyIDs.contains(automation.id))
            Button {
                editor = AutomationEditorDraft(automation)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("編輯")
            Button(role: .destructive) {
                Task { await agentViewModel.deleteAutomation(id: automation.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("刪除定義（保留 run history）")
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private var runHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run history").font(.headline)
            if agentViewModel.automationRuns.isEmpty {
                Text("尚無 run。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agentViewModel.automationRuns.prefix(100)) { run in
                    AutomationRunRow(run: run, agentViewModel: agentViewModel)
                }
            }
        }
    }
}

private struct AutomationRunRow: View {
    let run: AutomationRunRecord
    @ObservedObject var agentViewModel: AgentViewModel
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: run.status.systemImage)
                    .foregroundStyle(run.status.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(automationName).font(.callout.weight(.medium))
                    Text("\(run.status.displayTitle) · \((run.startedAt ?? run.scheduledAt).formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !run.status.isTerminal {
                    Button("取消") {
                        Task { await agentViewModel.cancelAutomationRun(id: run.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if run.result?.metadata["task_id"] != nil {
                    Button("開啟 Task") { agentViewModel.openAutomationRun(run) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if run.status.isTerminal,
                   run.worktree.requestedMode == .dedicated,
                   run.worktree.retained {
                    Button("Discard", role: .destructive) {
                        Task { await agentViewModel.discardAutomationWorktree(runID: run.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    showsLog.toggle()
                } label: {
                    Image(systemName: showsLog ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help("顯示 run log")
            }
            if let summary = run.result?.summary, !summary.isEmpty {
                Text(summary).font(.caption).lineLimit(4)
            }
            if !run.changes.isEmpty {
                Text("\(run.changes.count) 個變更 · 可開啟 Task 查看 Diff、Review、Commit 或建立 PR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let path = run.worktree.path {
                Text("Worktree: \(path)\(run.worktree.retained ? "" : "（已丟棄）")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if showsLog {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.log) { entry in
                        Text("[\(entry.level.rawValue)] \(entry.timestamp.formatted(date: .omitted, time: .standard))  \(entry.message)")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private var automationName: String {
        agentViewModel.automations.first(where: { $0.id == run.automationID })?.name
            ?? "已刪除的 Automation"
    }
}

private enum AutomationScheduleEditorKind: String, CaseIterable, Identifiable {
    case oneTime, interval, cron, event
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneTime: "一次"
        case .interval: "Interval"
        case .cron: "Cron"
        case .event: "Event"
        }
    }
}

private struct AutomationEditorDraft: Identifiable {
    let id = UUID()
    var existingID: UUID?
    var createdAt = Date()
    var name = ""
    var isEnabled = true
    var actionKind = AutomationActionKind.agentTask
    var prompt = "完成指定工作並回報具體結果。"
    var projectID: UUID?
    var worktreeMode = AutomationWorktreeMode.dedicated
    var scheduleKind = AutomationScheduleEditorKind.oneTime
    var runAt = Date().addingTimeInterval(300)
    var intervalMinutes = "60"
    var cronExpression = "0 9 * * 1-5"
    var timeZoneIdentifier = TimeZone.current.identifier
    var eventName = "repository.changed"
    var missedRunPolicy = AutomationMissedRunPolicy.runOnce
    var goal = ""
    var skillName = ""
    var skillArguments = ""
    var commandExecutable = "swift"
    var commandArguments = "test"
    var commandWorkingDirectory = "."
    var reviewSourceSessionID: UUID?
    var reviewInstructions = "檢查目前變更的正確性、安全性與回歸風險。"

    init(projectID: UUID?, reviewSourceSessionID: UUID?) {
        self.projectID = projectID
        self.reviewSourceSessionID = reviewSourceSessionID
    }

    init(_ definition: AutomationDefinition) {
        existingID = definition.id
        createdAt = definition.createdAt
        name = definition.name
        isEnabled = definition.isEnabled
        actionKind = definition.task.actionKind
        prompt = definition.task.prompt
        projectID = definition.task.projectID
        worktreeMode = definition.task.worktreeMode
        missedRunPolicy = definition.missedRunPolicy
        goal = definition.task.goal ?? ""
        skillName = definition.task.skill?.name ?? ""
        skillArguments = definition.task.skill?.arguments.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n") ?? ""
        commandExecutable = definition.task.command?.executable ?? "swift"
        commandArguments = definition.task.command?.arguments.joined(separator: "\n") ?? "test"
        commandWorkingDirectory = definition.task.command?.workingDirectory ?? "."
        reviewSourceSessionID = definition.task.review?.sourceSessionID
        reviewInstructions = definition.task.review?.instructions ?? ""
        switch definition.schedule {
        case .oneTime(let date):
            scheduleKind = .oneTime
            runAt = date
        case .interval(let seconds, _):
            scheduleKind = .interval
            intervalMinutes = String(max(1, Int(seconds / 60)))
        case .cron(let cron):
            scheduleKind = .cron
            cronExpression = cron.expression
            timeZoneIdentifier = cron.timeZoneIdentifier
        case .event(let event):
            scheduleKind = .event
            eventName = event.name
        }
    }
}

private struct AutomationEditorSheet: View {
    @State var draft: AutomationEditorDraft
    let projects: [AgentProject]
    let sessions: [AgentSession]
    let onCancel: () -> Void
    let onSave: (AutomationDefinition) -> Void
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.existingID == nil ? "新增 Automation" : "編輯 Automation")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            Form {
                TextField("名稱", text: $draft.name)
                Toggle("啟用", isOn: $draft.isEnabled)
                Picker("Project", selection: $draft.projectID) {
                    Text("請選擇").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                Picker("Action", selection: $draft.actionKind) {
                    ForEach(AutomationActionKind.allCases, id: \.self) { kind in
                        Text(kind.displayTitle).tag(kind)
                    }
                }
                actionFields
                TextField("Prompt / 補充指示", text: $draft.prompt, axis: .vertical)
                    .lineLimit(3...8)
                Picker("Schedule", selection: $draft.scheduleKind) {
                    ForEach(AutomationScheduleEditorKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                scheduleFields
                Picker("Missed run", selection: missedRunBinding) {
                    Text("略過").tag("skip")
                    Text("補跑一次").tag("run_once")
                    Text("最多補跑 3 次").tag("catch_up")
                }
                Picker("Execution", selection: $draft.worktreeMode) {
                    if draft.actionKind != .reviewChanges {
                        Text("Dedicated Worktree").tag(AutomationWorktreeMode.dedicated)
                    }
                    Text("Project checkout").tag(AutomationWorktreeMode.reuseProject)
                    Text("No managed worktree").tag(AutomationWorktreeMode.none)
                }
                if requiresDedicatedWorktree {
                    Label("Recurring/event mutation 會強制使用 dedicated worktree，絕不在 main checkout 執行。", systemImage: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("取消", action: onCancel)
                Button("儲存") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 620, height: 650)
    }

    @ViewBuilder
    private var actionFields: some View {
        switch draft.actionKind {
        case .agentTask, .projectJob:
            EmptyView()
        case .goal:
            TextField("Goal objective", text: $draft.goal, axis: .vertical)
        case .skill:
            TextField("Skill 名稱", text: $draft.skillName)
            TextField("參數（每行 key=value）", text: $draft.skillArguments, axis: .vertical)
        case .tests, .repositoryCheck:
            TextField("Executable basename", text: $draft.commandExecutable)
            TextField("Arguments（每行一個 argv）", text: $draft.commandArguments, axis: .vertical)
            TextField("Workspace-relative cwd", text: $draft.commandWorkingDirectory)
        case .reviewChanges:
            Picker("來源 Task", selection: $draft.reviewSourceSessionID) {
                Text("請選擇").tag(nil as UUID?)
                ForEach(sessions.filter { $0.resolvedTaskType == .coding }) { session in
                    Text(session.title).tag(session.id as UUID?)
                }
            }
            TextField("Review instructions", text: $draft.reviewInstructions, axis: .vertical)
        }
    }

    @ViewBuilder
    private var scheduleFields: some View {
        switch draft.scheduleKind {
        case .oneTime:
            DatePicker("執行時間", selection: $draft.runAt)
        case .interval:
            TextField("間隔（分鐘）", text: $draft.intervalMinutes)
        case .cron:
            TextField("五欄 Cron", text: $draft.cronExpression)
                .font(.system(.body, design: .monospaced))
            TextField("IANA Time Zone", text: $draft.timeZoneIdentifier)
        case .event:
            TextField("Event name", text: $draft.eventName)
            Text("已保留 GitHub、Slack、Gmail、filesystem 與 webhook producer seam；payload 只做 exact filter，不會當成指令執行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var missedRunBinding: Binding<String> {
        Binding(
            get: {
                switch draft.missedRunPolicy {
                case .skip: "skip"
                case .runOnce: "run_once"
                case .catchUp: "catch_up"
                }
            },
            set: {
                switch $0 {
                case "skip": draft.missedRunPolicy = .skip
                case "catch_up": draft.missedRunPolicy = .catchUp(maxRuns: 3)
                default: draft.missedRunPolicy = .runOnce
                }
            }
        )
    }

    private var requiresDedicatedWorktree: Bool {
        draft.scheduleKind != .oneTime && draft.actionKind.isMutationCapable
    }

    private func save() {
        do {
            guard let projectID = draft.projectID else {
                throw AutomationError.invalidDefinition("請選擇 Project。")
            }
            let schedule: AutomationSchedule
            switch draft.scheduleKind {
            case .oneTime:
                schedule = .oneTime(at: draft.runAt)
            case .interval:
                guard let minutes = Double(draft.intervalMinutes), minutes > 0 else {
                    throw AutomationError.invalidSchedule("Interval 分鐘必須大於 0。")
                }
                schedule = .interval(every: minutes * 60, anchor: Date())
            case .cron:
                schedule = .cron(AutomationCronSchedule(
                    expression: draft.cronExpression,
                    timeZoneIdentifier: draft.timeZoneIdentifier
                ))
            case .event:
                schedule = .event(AutomationEventTrigger(name: draft.eventName))
            }

            let arguments = try parseSkillArguments(draft.skillArguments)
            let command = AutomationCommandInvocation(
                executable: draft.commandExecutable,
                arguments: draft.commandArguments.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty },
                workingDirectory: draft.commandWorkingDirectory
            )
            let task = AutomationTaskSpec(
                actionKind: draft.actionKind,
                prompt: draft.prompt,
                projectID: projectID,
                worktreeMode: draft.actionKind == .reviewChanges
                    ? .reuseProject
                    : (requiresDedicatedWorktree ? .dedicated : draft.worktreeMode),
                goal: draft.actionKind == .goal ? draft.goal : nil,
                skill: draft.actionKind == .skill
                    ? AutomationSkillInvocation(name: draft.skillName, arguments: arguments) : nil,
                command: [.tests, .repositoryCheck].contains(draft.actionKind) ? command : nil,
                review: draft.actionKind == .reviewChanges
                    ? AutomationReviewRequest(
                        sourceSessionID: draft.reviewSourceSessionID ?? UUID(),
                        instructions: draft.reviewInstructions
                    ) : nil
            )
            let definition = AutomationDefinition(
                id: draft.existingID ?? UUID(),
                name: draft.name,
                isEnabled: draft.isEnabled,
                schedule: schedule,
                task: task,
                missedRunPolicy: draft.missedRunPolicy,
                createdAt: draft.createdAt,
                updatedAt: Date()
            )
            _ = try AutomationValidation.validatedDefinition(definition)
            if draft.actionKind == .reviewChanges, draft.reviewSourceSessionID == nil {
                throw AutomationError.invalidDefinition("請選擇 Review 來源 Task。")
            }
            onSave(definition)
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func parseSkillArguments(_ source: String) throws -> [String: String] {
        var output: [String: String] = [:]
        for line in source.components(separatedBy: .newlines) where !line.isEmpty {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else {
                throw AutomationError.invalidDefinition("Skill 參數必須使用 key=value。")
            }
            let key = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, output[key] == nil else {
                throw AutomationError.invalidDefinition("Skill 參數 key 為空或重複。")
            }
            output[key] = String(pieces[1])
        }
        return output
    }
}

private extension AutomationActionKind {
    var displayTitle: String {
        switch self {
        case .agentTask: "Agent Task"
        case .goal: "Goal"
        case .skill: "Skill"
        case .projectJob: "Project Job"
        case .tests: "Tests"
        case .repositoryCheck: "Repository Check"
        case .reviewChanges: "Review Changes"
        }
    }
}

private extension AutomationWorktreeMode {
    var displayTitle: String {
        switch self {
        case .none: "Local"
        case .reuseProject: "Project checkout"
        case .dedicated: "Dedicated worktree"
        }
    }
}

private extension AutomationSchedule {
    var displayDescription: String {
        switch self {
        case .oneTime(let date): "一次 · \(date.formatted(date: .abbreviated, time: .shortened))"
        case .interval(let seconds, _): "每 \(Int(seconds / 60)) 分鐘"
        case .cron(let cron): "Cron \(cron.expression) · \(cron.timeZoneIdentifier)"
        case .event(let event): "Event · \(event.name)"
        }
    }
}

private extension AutomationRunStatus {
    var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .skipped: "Skipped"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled, .interrupted: "pause.circle.fill"
        case .skipped: "forward.end.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .running: .blue
        case .queued: .secondary
        case .cancelled, .interrupted, .skipped: .orange
        }
    }
}
