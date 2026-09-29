import AppKit
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case connections
    case generation
    case agent
    case remoteRunners
    case automations
    case pullRequests
    case project
    case mcp
    case extensions
    case integrations
    case updates
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "連線與模型"
        case .generation: "對話與生成"
        case .agent: "Codex Agent"
        case .remoteRunners: "Remote Runners"
        case .automations: "Automations"
        case .pullRequests: "Pull Requests"
        case .project: "Project Settings"
        case .mcp: "MCP Servers"
        case .extensions: "Extensions"
        case .integrations: "App 與專案"
        case .updates: "更新與回滾"
        case .privacy: "資料與隱私"
        }
    }

    var icon: String {
        switch self {
        case .connections: "network"
        case .generation: "text.bubble"
        case .agent: "terminal"
        case .remoteRunners: "server.rack"
        case .automations: "calendar.badge.clock"
        case .pullRequests: "arrow.triangle.pull"
        case .project: "folder.badge.gearshape"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .extensions: "puzzlepiece.extension"
        case .integrations: "folder.badge.gearshape"
        case .updates: "arrow.triangle.2.circlepath.circle"
        case .privacy: "lock.shield"
        }
    }
}

private enum ProjectMCPSelectionMode: String, CaseIterable, Identifiable {
    case inherit
    case none
    case selected

    var id: String { rawValue }
}

private struct ProjectEnvironmentRow: Identifiable, Equatable {
    var id = UUID()
    var key: String
    var value: String
}

private struct ProbeFingerprint: Hashable {
    let provider: ProviderKind
    let endpoint: String
    let apiKey: String
}

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject var agentViewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings
    @State private var agentDraft: AgentSettings
    @State private var projectDraft: AgentProjectSettings
    @State private var projectCatalogNameDraft: String
    @State private var projectAllowedCommandsText: String
    @State private var projectDeniedCommandsText: String
    @State private var computerUseAllowedBundleIdentifiersText: String
    @State private var pullRequestProviderDraft: PullRequestProviderConfiguration
    @State private var pullRequestToken: String
    @State private var pullRequestCredentialScope: String
    @State private var projectMCPMode: ProjectMCPSelectionMode
    @State private var projectMCPServerIDs: Set<UUID>
    @State private var projectEnvironmentRows: [ProjectEnvironmentRow]
    @State private var apiKey: String
    @State private var showAdvanced = false
    @State private var confirmClear = false
    @State private var isTesting = false
    @State private var isRefreshingModels = false
    @State private var testResult: String?
    @State private var testSucceeded: Bool?
    @State private var draftModels: [String]
    @State private var credentialScope: String
    @State private var selectedPage: SettingsPage = .connections
    @State private var profileName: String
    @State private var activeProbeID: UUID?
    @State private var saveError: String?
    @State private var instructionImportPreview: ProjectInstructionImportPreview?
    @State private var instructionImportDraft = ""
    @State private var isShowingInstructionImport = false

    init(viewModel: ChatViewModel, agentViewModel: AgentViewModel) {
        self.viewModel = viewModel
        self.agentViewModel = agentViewModel
        _draft = State(initialValue: viewModel.settings)
        _agentDraft = State(initialValue: agentViewModel.settings)
        let project = agentViewModel.projectSettings
        _projectDraft = State(initialValue: project)
        _projectCatalogNameDraft = State(initialValue: agentViewModel.selectedSession.map {
            agentViewModel.projectDisplayName(for: $0)
        } ?? "")
        _projectAllowedCommandsText = State(initialValue: project.allowedCommands.joined(separator: "\n"))
        _projectDeniedCommandsText = State(initialValue: project.deniedCommands.joined(separator: "\n"))
        _computerUseAllowedBundleIdentifiersText = State(
            initialValue: agentViewModel.settings.computerUseAllowedBundleIdentifiers
                .joined(separator: "\n")
        )
        let pullRequestProvider = agentViewModel.settings.pullRequestProvider
        _pullRequestProviderDraft = State(initialValue: pullRequestProvider)
        _pullRequestToken = State(
            initialValue: agentViewModel.storedPullRequestToken(
                for: pullRequestProvider
            )
        )
        _pullRequestCredentialScope = State(
            initialValue: (try? PullRequestCredentialStore.account(
                configuration: pullRequestProvider
            )) ?? ""
        )
        _projectMCPMode = State(initialValue: project.mcpServerIDs == nil
            ? .inherit : (project.mcpServerIDs?.isEmpty == true ? .none : .selected))
        _projectMCPServerIDs = State(initialValue: Set(project.mcpServerIDs ?? []))
        _projectEnvironmentRows = State(initialValue: project.environmentVariables
            .sorted { $0.key < $1.key }
            .map { ProjectEnvironmentRow(key: $0.key, value: $0.value) })
        _apiKey = State(initialValue: viewModel.apiKey)
        _draftModels = State(initialValue: viewModel.availableModels)
        _credentialScope = State(initialValue: KeychainStore.account(for: viewModel.settings))
        _profileName = State(initialValue: viewModel.activeProfile?.displayName ?? "")
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider().opacity(0.5)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        pageContent
                    }
                    .padding(26)
                }
                Divider().opacity(0.5)
                footer
            }
        }
        .frame(width: 780, height: 660)
        .background(LumaTheme.canvas.overlay(LumaTheme.ambientGradient))
        .confirmationDialog("永久清除所有對話？", isPresented: $confirmClear) {
            Button("刪除全部訊息與附件", role: .destructive) {
                Task { await viewModel.deleteAllConversations() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("每個對話資料夾都會被移除，無法復原。設定會保留。")
        }
        .onChange(of: draft.endpoint) {
            resetCredentialIfScopeChanged()
        }
        .onChange(of: draft.provider) {
            if draft.backend?.provider != draft.provider {
                draft.backend = ModelBackendKind.inferred(
                    provider: draft.provider,
                    endpoint: draft.endpoint
                )
            }
            resetCredentialIfScopeChanged()
        }
        .onChange(of: viewModel.settings.modelParameterProfiles) { _, profiles in
            // Parameter controls write through the shared view model. Keep the
            // connection draft from overwriting those live edits on Save.
            draft.modelParameterProfiles = profiles
        }
        .onChange(of: pullRequestProviderDraft.apiEndpoint) {
            resetPullRequestCredentialIfScopeChanged()
        }
        .task(id: probeFingerprint) {
            await runConnectionProbe(after: .milliseconds(650))
        }
        .onChange(of: agentViewModel.projectSettings) { _, newValue in
            synchronizeProjectDraft(newValue)
        }
        .onChange(of: agentViewModel.selectedSessionID) { _, _ in
            synchronizeProjectCatalogName()
        }
        .onChange(of: agentViewModel.projects) { _, _ in
            synchronizeProjectCatalogName()
        }
        .onChange(of: agentViewModel.errorMessage) { _, message in
            guard let message else { return }
            saveError = message
            agentViewModel.errorMessage = nil
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            saveError = message
            viewModel.errorMessage = nil
        }
        .alert("設定無法完成", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .sheet(isPresented: $isShowingInstructionImport) {
            instructionImportSheet
        }
    }

    private var probeFingerprint: ProbeFingerprint {
        ProbeFingerprint(provider: draft.provider, endpoint: draft.endpoint, apiKey: apiKey)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(size: 32)
                Text("設定").font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 17)

            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 178)
        .background(LumaTheme.sidebar)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .connections:
            profilesSection
            providerSection
            connectionSection
            modelSection
        case .generation:
            contextSection
            advancedSection
        case .agent:
            agentBehaviorSection
            agentSafetySection
            agentBrowserSection
            agentComputerUseSection
            agentContextSection
        case .remoteRunners:
            RemoteRunnerSettingsPane(agentViewModel: agentViewModel)
        case .automations:
            AutomationSettingsPane(agentViewModel: agentViewModel)
        case .pullRequests:
            pullRequestProviderSection
        case .project:
            projectSettingsSection
        case .mcp:
            MCPSettingsPane(agentViewModel: agentViewModel)
        case .extensions:
            ExtensionSettingsPane(agentViewModel: agentViewModel)
        case .integrations:
            integrationsSection
            projectSection
        case .updates:
            UpdateSettingsPane(controller: .shared)
        case .privacy:
            privacySection
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPage.title)
                    .font(.title3.weight(.semibold))
                Text(pageSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(LumaTheme.surface)
    }

    private var pageSubtitle: String {
        switch selectedPage {
        case .connections: "管理多組 Remote，並檢查可用模型"
        case .generation: "調整 context、回答風格與逾時"
        case .agent: "設定 Plan 與 Agent 的模型、工具權限及執行上限"
        case .remoteRunners: "管理受 host receipt 驗證的 SSH 執行位置與 Keychain credential"
        case .automations: "排程 Agent 工作、隔離 recurring coding run，並查看持久化結果"
        case .pullRequests: "設定 GitHub API 與只存於 Keychain 的存取權杖"
        case .project: "只套用到目前 Workspace，秘密值保存在 Keychain"
        case .mcp: "連接本機或遠端工具，並動態加入 Coding Agent"
        case .extensions: "管理 Skills、Plugins、Hooks 與 Keychain OAuth Connectors"
        case .integrations: "只在你主動操作時讀取或修改本機內容"
        case .updates: "驗證簽名 feed、Developer ID、notarization，並管理 Last Known Good"
        case .privacy: "檢視儲存方式與清除對話資料"
        }
    }

    private var profilesSection: some View {
        SettingsSection(title: "已儲存的 Remote", subtitle: "儲存後可在主畫面直接套用到目前對話，或開新對話。") {
            VStack(spacing: 8) {
                ForEach(draft.connectionProfiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: providerIcon(profile.provider))
                            .foregroundStyle(profile.id == draft.activeProfileID ? LumaTheme.accent : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName).font(.callout.weight(.medium))
                            Text("\(profile.resolvedBackend.title) · \(profile.endpoint)  ·  \(profile.selectedModel.isEmpty ? "未選模型" : profile.selectedModel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if profile.id == draft.activeProfileID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LumaTheme.accent)
                                .help("目前編輯")
                        }
                        Button("載入") { loadProfile(profile) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button(role: .destructive) { removeProfile(profile) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.connectionProfiles.count == 1)
                        .help("刪除這組連線")
                    }
                    .padding(9)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 8) {
                    TextField("連線名稱，例如家裡 Ollama", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                    Button(draft.activeProfileID == nil ? "儲存新連線" : "更新這組連線") {
                        saveCurrentProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("另存新連線") {
                        draft.activeProfileID = nil
                        profileName = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var providerSection: some View {
        SettingsSection(title: "API 類型", subtitle: draft.provider.subtitle) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("API 類型", selection: $draft.provider) {
                    ForEach(ProviderKind.allCases) { provider in
                        Label(provider.title, systemImage: providerIcon(provider)).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("Backend").font(.callout.weight(.medium))
                    Spacer()
                    Picker("Backend", selection: Binding(
                        get: { draft.resolvedBackend },
                        set: { draft.backend = $0 }
                    )) {
                        ForEach(ModelBackendKind.choices(for: draft.provider)) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Text("Provider 決定 API 格式；Backend 會限制實際可送出的模型參數。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionSection: some View {
        SettingsSection(title: "伺服器", subtitle: "可填遠端網址，例如 http://chihchung.mooo.com:11434") {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("伺服器網址").font(.callout.weight(.medium))
                    Spacer()
                    Menu("使用範本") {
                        ForEach(ServerPreset.builtIns) { preset in
                            Button(preset.name) {
                                selectConfiguration(
                                    provider: preset.provider,
                                    backend: preset.backend,
                                    endpoint: preset.endpoint
                                )
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    TextField("http://伺服器:連接埠", text: $draft.endpoint)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        Task { await runConnectionProbe() }
                    } label: {
                        if isTesting { ProgressView().controlSize(.small) } else { Text("立即檢查") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting || draft.endpoint.isEmpty)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 8) {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    SecureField(
                        draft.provider.requiresAPIKey
                            ? "API Key（必填）"
                            : (draft.provider == .ollama
                               ? "Bearer Token（可留空）"
                               : "API Key（雲端必填，本機可留空）"),
                        text: $apiKey
                    )
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if usesRemoteOpenAIHTTP {
                    Text("遠端 HTTP 未加密；API Key 與對話內容會以明文傳送到這台伺服器。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let testResult {
                    Label(testResult, systemImage: isTesting ? "clock" : (testSucceeded == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .font(.caption)
                        .foregroundStyle(isTesting ? Color.secondary : (testSucceeded == true ? Color.green : Color.orange))
                }
            }
        }
    }

    private var usesRemoteOpenAIHTTP: Bool {
        guard draft.provider == .openAICompatible,
              let endpoint = EndpointNormalizer.normalized(draft.endpoint),
              let url = URL(string: endpoint) else { return false }
        return url.scheme == "http" && !AgentHTTPOrigin.isLoopback(url.host)
    }

    private var pullRequestProviderSection: some View {
        SettingsSection(
            title: "GitHub Pull Requests",
            subtitle: "Agent 可讀取 PR context，並在你明確核准後建立 PR。Endpoint 設定會隨每次 run 固定快照。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Provider").font(.callout.weight(.medium))
                    Spacer()
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Endpoint").font(.callout.weight(.medium))
                    TextField(
                        "https://api.github.com",
                        text: $pullRequestProviderDraft.apiEndpoint
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    Text("GitHub Enterprise 可填 credential-free HTTPS API base URL；僅 loopback 測試端點可使用 HTTP。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal Access Token").font(.callout.weight(.medium))
                    SecureField("GitHub token（留空會移除目前 endpoint 的 token）", text: $pullRequestToken)
                        .textFieldStyle(.roundedBorder)
                    Label(
                        "Token 只儲存在 macOS Keychain，不會寫入 settings.json、Task 或模型 context。",
                        systemImage: "lock.shield"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Text("建立 PR 仍會逐次要求 Dangerous + Network 核准；讀取遠端 PR 的文字與 patch 一律視為不可信資料。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelSection: some View {
        SettingsSection(title: "模型", subtitle: "可從伺服器讀取，或直接輸入模型 ID。") {
            HStack(spacing: 9) {
                TextField("例如 llama3.2、gpt-4.1-mini", text: $draft.selectedModel)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    if draftModels.isEmpty {
                        Text("請先測試連線或重新整理")
                    }
                    ForEach(draftModels, id: \.self) { model in
                        Button(model) { draft.selectedModel = model }
                    }
                } label: {
                    Label("選取", systemImage: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                Button {
                    Task {
                        isRefreshingModels = true
                        await runConnectionProbe()
                        isRefreshingModels = false
                    }
                } label: {
                    if isRefreshingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingModels)
                .help("讀取模型清單")
            }
        }
    }

    private var contextSection: some View {
        SettingsSection(
            title: "Model Parameters",
            subtitle: "每個 backend/provider + model ID 都有獨立 Auto 或 Custom Profile；修改立即保存。"
        ) {
            ModelParameterEditor(
                viewModel: viewModel,
                route: ModelParameterRoute(
                    provider: draft.provider,
                    backend: draft.resolvedBackend,
                    endpoint: draft.endpoint,
                    modelID: draft.selectedModel,
                    useCase: .chat
                )
            )
        }
    }

    private var integrationsSection: some View {
        SettingsSection(
            title: "本機 App 即時連接",
            subtitle: "連接後會在每次送出前直接讀取目前文件；不建立中介文字檔，也不在背景持續監看。"
        ) {
            HStack(spacing: 12) {
                HStack(spacing: -5) {
                    ForEach([
                        LocalContextSource.notes,
                        .textEdit,
                        .visualStudioCode,
                        .xcode
                    ]) { source in
                        LocalAppIcon(source: source, size: 29, cornerRadius: 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.primary.opacity(0.08))
                            }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.isAccessibilityTrusted ? "已可即時讀取與修改 App" : "即時讀取與修改需要輔助使用權限")
                        .font(.callout.weight(.medium))
                    Text("支援備忘錄、TextEdit、VS Code、Xcode；TextEdit 的 Rich Text 僅讀取，套用修改前仍會要求確認。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !viewModel.isAccessibilityTrusted {
                    Button("授權…") { viewModel.requestAccessibilityPermission() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(11)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var projectSection: some View {
        SettingsSection(title: "專案資料夾", subtitle: "從輸入框的 ＋ 選擇專案；LumaChat 會建立受 context 限制的本機快照。") {
            VStack(alignment: .leading, spacing: 9) {
                Label("預設略過 .git、node_modules、build、tmp 與敏感憑證檔", systemImage: "eye.slash")
                Label("模型產生的程式碼可由你指定檔案並確認後儲存", systemImage: "checkmark.shield")
                Text("模型是否支援 tool calling 不會改變本機權限；任何寫入都需要你主動選擇。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(11)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("其他對話設定", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("系統提示詞").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextEditor(text: $draft.systemPrompt)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(8)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
                HStack {
                    Text("逾時")
                    Spacer()
                    TextField("秒", value: $draft.requestTimeout, format: .number)
                        .frame(width: 75)
                    Text("秒").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
        }
        .font(.callout.weight(.medium))
    }

    private var agentBehaviorSection: some View {
        SettingsSection(
            title: "Coding Agent",
            subtitle: "Chat 保持原本對話流程；Plan 僅分析，Agent 才能在選定 Workspace 內修改與執行。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("啟動時模式", selection: $agentDraft.defaultMode) {
                    ForEach(AppMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("執行中送出訊息", selection: $agentDraft.followUpBehavior) {
                    ForEach(AgentFollowUpBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("啟用本機記憶", isOn: $agentDraft.memoriesEnabled)
                Text("預設關閉。啟用後仍須在專案與 Task 明確允許；已核准的記憶會隨下一次執行傳給所選模型服務。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Plan 模型")
                    Spacer()
                    TextField("留空則沿用目前連線模型", text: $agentDraft.preferredPlanModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                HStack {
                    Text("Agent 模型")
                    Spacer()
                    TextField("留空則沿用目前連線模型", text: $agentDraft.preferredAgentModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
            }
        }
    }

    private var agentSafetySection: some View {
        SettingsSection(
            title: "權限與安全界線",
            subtitle: "所有路徑都會先正規化並限制在你開啟的 Workspace；高風險命令永遠要求確認。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Picker("工具核准", selection: $agentDraft.permissionMode) {
                    ForEach(AgentPermissionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("允許工具存取網路", isOn: $agentDraft.networkAccess)
                Picker("模型影像輸入", selection: $agentDraft.visionMode) {
                    ForEach(AgentVisionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Agent 執行工具前建立 Checkpoint", isOn: $agentDraft.gitCheckpoint)
                Toggle("Agent 完成修改後自動執行測試", isOn: $agentDraft.autoRunTests)

                Label(
                    "自動模式只信任模型 metadata；OpenAI-compatible／Anthropic 的未知模型會安全地只傳影像 metadata。已確認模型支援圖片時才手動啟用。",
                    systemImage: "photo.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "每次原生檔案變更都會建立有容量上限的復原 snapshot。",
                    systemImage: "arrow.uturn.backward.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "Build 與測試只會在任務明確需要、且通過命令權限後執行。",
                    systemImage: "hammer"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "Plan 模式固定為唯讀；即使選擇完整存取，危險命令、Workspace 外路徑與 Git push 仍不會被靜默開放。",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var agentComputerUseSection: some View {
        SettingsSection(
            title: "Computer Use",
            subtitle: "讓 Agent 觀察並操作你明確允許的 Mac App；預設關閉，且沒有「任何 App」模式。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("啟用 Computer Use（實驗性）", isOn: $agentDraft.computerUseEnabled)

                Label(
                    "Observe–Act 需要支援 vision 的模型，且「模型影像輸入」不能停用；否則畫面像素不會送達模型，Computer Use 也無法工作。",
                    systemImage: "eye.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                Label(
                    "App 畫面可能以截圖傳送到目前選定的模型伺服器。請先關閉或遮蔽密碼、私人訊息與其他敏感內容。",
                    systemImage: "rectangle.inset.filled.and.person.filled"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "每個 UI 動作都要使用 30 秒內的新截圖並逐次核准；同 bundle ID 有多個程序時會安全拒絕，多個可見視窗則必須先列出並選定 window_id。密碼、Token 等秘密必須由你親自輸入。",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "白名單 App 仍可能包含瀏覽器、網路功能或內嵌終端機；2.0 語意 targeting 只支援受限的 press／focus，仍無法完整分類瀏覽器、終端機或敏感效果。只允許你信任的 App，並仔細查看每次核准截圖。",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("允許的 App Bundle IDs")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(
                            "\(normalizedComputerUseBundleIdentifiers.count) / \(AgentComputerUseSettingsLimits.maximumAllowedApplications)"
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                    TextEditor(text: $computerUseAllowedBundleIdentifiersText)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 105)
                        .padding(8)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                    Text(
                        "每行一個完整 bundle identifier，例如 com.apple.TextEdit。重複、控制字元、超長或超過上限的項目會在儲存時移除；留空代表不允許任何 App。"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Button {
                        openPrivacySettings(pane: "Privacy_ScreenCapture")
                    } label: {
                        Label("螢幕錄製權限…", systemImage: "rectangle.dashed.badge.record")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openPrivacySettings(pane: "Privacy_Accessibility")
                    } label: {
                        Label("輔助使用權限…", systemImage: "figure.arms.open")
                    }
                    .buttonStyle(.bordered)
                }

                Text("螢幕錄製用於觀察畫面；輔助使用用於點按、輸入與捲動。macOS 可能要求重新啟動 App 才會套用新權限。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var agentBrowserSection: some View {
        SettingsSection(
            title: "Browser",
            subtitle: "以 DOM、Accessibility tree 與 Chrome DevTools Protocol 操作網頁；預設使用完全隔離的暫存 Profile。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Toggle("啟用 Browser tools", isOn: $agentDraft.browserEnabled)

                Picker("Browser Profile", selection: $agentDraft.browserProfileMode) {
                    ForEach(AgentBrowserProfileMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!agentDraft.browserEnabled)

                switch agentDraft.browserProfileMode {
                case .isolatedTemporary:
                    Label(
                        "每個 Task 使用 repo/tmp/browser 下的獨立 user-data；Cookie、storage、cache 與憑證不與其他 Task 共用。",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                case .persistent:
                    HStack {
                        Text("持久 Profile 名稱")
                        Spacer()
                        TextField("default", text: $agentDraft.browserPersistentProfileName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }
                    Label(
                        "這是明確的持久化選擇；登入狀態與網站資料會保留供之後 Task 使用。名稱只接受英數字、句點、連字號與底線。",
                        systemImage: "externaldrive.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                case .attachExisting:
                    HStack {
                        Text("本機 DevTools endpoint")
                        Spacer()
                        TextField(
                            AgentBrowserSettingsLimits.defaultExistingDebugEndpoint,
                            text: $agentDraft.browserExistingDebugEndpoint
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 330)
                    }
                    Label(
                        "高權限模式：現有 Browser 可能包含已登入帳號、Cookie 與私人頁面。只允許含 port 的 localhost／127.0.0.1／::1 HTTP endpoint；LumaChat 不會自行開啟遠端偵錯。",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Label(
                    "網頁內容一律視為不可信資料。Agent 會優先使用 structured tool，再使用 Browser DOM/CDP；Accessibility 與像素操作是後備路徑。",
                    systemImage: "network.badge.shield.half.filled"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !agentDraft.networkAccess {
                    Label(
                        "全域網路存取目前關閉；每個需要網路的 Browser 動作仍會經過權限核准。",
                        systemImage: "hand.raised"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var agentContextSection: some View {
        SettingsSection(
            title: "執行與 Context",
            subtitle: "限制單次任務的迴圈、命令時間與回傳內容，避免失控或讓工具輸出塞滿模型 context。"
        ) {
            VStack(spacing: 13) {
                HStack {
                    Text("最多步驟")
                    Spacer()
                    TextField("步", value: $agentDraft.maxSteps, format: .number)
                        .frame(width: 82)
                    Text("步").foregroundStyle(.secondary)
                }
                HStack {
                    Text("命令逾時")
                    Spacer()
                    TextField("秒", value: $agentDraft.commandTimeout, format: .number)
                        .frame(width: 82)
                    Text("秒").foregroundStyle(.secondary)
                }
                HStack {
                    Text("工具結果上限")
                    Spacer()
                    TextField("字元", value: $agentDraft.maximumToolResultCharacters, format: .number)
                        .frame(width: 100)
                    Text("字元").foregroundStyle(.secondary)
                }
                Toggle("自動壓縮過長 Context", isOn: $agentDraft.autoContextCompression)
            }
        }
    }

    @ViewBuilder
    private var projectSettingsSection: some View {
        if let session = agentViewModel.selectedSession,
           let workspace = session.workspace {
            SettingsSection(
                title: agentViewModel.projectDisplayName(for: session),
                subtitle: "Folder「\(workspace.name)」的設定依 canonical Workspace 儲存於 Luma Chat；不會寫入專案目錄。"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Project catalog 名稱")
                        Spacer()
                        TextField("留空＝使用 Primary folder 名稱", text: $projectCatalogNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                        Button("更新") {
                            Task {
                                _ = await agentViewModel.renameSelectedProject(
                                    to: projectCatalogNameDraft
                                )
                                synchronizeProjectCatalogName()
                            }
                        }
                        .disabled(agentViewModel.isMutatingProject)
                    }

                    HStack {
                        Text("Preferred Model")
                        Spacer()
                        TextField(
                            "留空＝沿用目前 Agent 模型",
                            text: Binding(
                                get: { projectDraft.preferredModel ?? "" },
                                set: { projectDraft.preferredModel = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                    }

                    Picker(
                        "Agent Permission",
                        selection: Binding(
                            get: { projectDraft.agentPermission },
                            set: { projectDraft.agentPermission = $0 }
                        )
                    ) {
                        Text("沿用全域").tag(nil as AgentPermissionMode?)
                        ForEach(AgentPermissionMode.allCases) { mode in
                            Text(mode.title).tag(mode as AgentPermissionMode?)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        projectCommandEditor(
                            title: "Allowed Commands",
                            detail: "每行一個 exact command；只有安全且完全相符者可免重複核准。",
                            text: $projectAllowedCommandsText
                        )
                        projectCommandEditor(
                            title: "Denied Commands",
                            detail: "每行一個 exact command；deny 永遠優先且直接拒絕。",
                            text: $projectDeniedCommandsText
                        )
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        Text("MCP Servers").font(.callout.weight(.medium))
                        Picker("MCP", selection: $projectMCPMode) {
                            Text("沿用全域").tag(ProjectMCPSelectionMode.inherit)
                            Text("全部停用").tag(ProjectMCPSelectionMode.none)
                            Text("選擇 Server").tag(ProjectMCPSelectionMode.selected)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if projectMCPMode == .selected {
                            if agentViewModel.mcpServers.isEmpty {
                                Text("尚未建立 MCP Server。請先到 MCP Servers 頁面新增。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(agentViewModel.mcpServers) { server in
                                    Toggle(
                                        isOn: Binding(
                                            get: { projectMCPServerIDs.contains(server.id) },
                                            set: { selected in
                                                if selected { projectMCPServerIDs.insert(server.id) }
                                                else { projectMCPServerIDs.remove(server.id) }
                                            }
                                        )
                                    ) {
                                        HStack {
                                            Text(server.name)
                                            Spacer()
                                            Text(server.enabled ? "Enabled" : "Global disabled")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Environment Variables").font(.callout.weight(.medium))
                                Text("Value 只存於 macOS Keychain；PATH、HOME、TMP 與 loader 變數不可覆寫。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                projectEnvironmentRows.append(
                                    ProjectEnvironmentRow(key: "", value: "")
                                )
                            } label: {
                                Label("新增", systemImage: "plus")
                            }
                            .disabled(
                                projectEnvironmentRows.count
                                    >= AgentProjectSettingsLimits.maximumEnvironmentVariables
                            )
                        }
                        ForEach($projectEnvironmentRows) { $row in
                            HStack(spacing: 8) {
                                TextField("KEY", text: $row.key)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                                SecureField("Value", text: $row.value)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) {
                                    projectEnvironmentRows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("System Prompt").font(.callout.weight(.medium))
                            Spacer()
                            Menu("從其他助理匯入…") {
                                ForEach(ProjectInstructionImportSource.allCases) { source in
                                    Button(source.title) {
                                        previewProjectInstructions(source)
                                    }
                                }
                            }
                        }
                        TextEditor(text: Binding(
                            get: { projectDraft.systemPrompt ?? "" },
                            set: { projectDraft.systemPrompt = $0 }
                        ))
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        Text("優先序：System Safety → App Agent Instructions → Project Settings / AGENTS.md → User Request。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("目前支援專案根目錄的 CLAUDE.md 與舊版 .cursorrules。匯入前可預覽及編輯，套用後仍須儲存 Project Settings。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        if agentViewModel.isLoadingProjectSettings {
                            ProgressView().controlSize(.small)
                            Text("正在載入…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢復全部沿用") {
                            synchronizeProjectDraft(AgentProjectSettings())
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        } else {
            SettingsSection(
                title: "尚未開啟 Workspace",
                subtitle: "請先切換到 Plan 或 Agent 並選擇 Open Project。"
            ) {
                Label("Project Settings 不會套用到 Classic Chat。", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewProjectInstructions(_ source: ProjectInstructionImportSource) {
        guard let workspace = agentViewModel.selectedHostSettingsWorkspace else {
            saveError = "請先選擇本機 Project folder。"
            return
        }
        do {
            let preview = try ProjectInstructionImporter().preview(
                source: source,
                workspaceRootPath: workspace.rootPath
            )
            instructionImportPreview = preview
            instructionImportDraft = preview.redactedContent
            isShowingInstructionImport = true
        } catch {
            saveError = SecretRedactor().redact(error.localizedDescription)
        }
    }

    private var instructionImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(instructionImportPreview?.source.title ?? "匯入預覽")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("取消") { isShowingInstructionImport = false }
            }
            Text(instructionImportPreview?.sourcePath ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("請審閱並修改內容。按「套用到草稿」會取代目前的 System Prompt 草稿；關閉設定前仍需按儲存。匯入檔案不會被改寫。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $instructionImportDraft)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 310)
                .padding(7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(instructionImportDraft.utf8.count) / \(AgentProjectSettingsLimits.maximumSystemPromptBytes) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("套用到草稿") { applyInstructionImport() }
                    .disabled(instructionImportDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || instructionImportDraft.utf8.count
                            > AgentProjectSettingsLimits.maximumSystemPromptBytes)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 500)
    }

    private func applyInstructionImport() {
        guard let preview = instructionImportPreview,
              let rootPath = agentViewModel.selectedHostSettingsWorkspace?.rootPath,
              preview.belongs(toWorkspaceRootPath: rootPath) else {
            saveError = "Project folder 已變更；請重新預覽指令檔。"
            return
        }
        let redacted = SecretRedactor().redact(instructionImportDraft)
        guard !redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              redacted.utf8.count <= AgentProjectSettingsLimits.maximumSystemPromptBytes else {
            saveError = "匯入內容為空或超出 Project System Prompt 長度上限。"
            return
        }
        projectDraft.systemPrompt = redacted
        isShowingInstructionImport = false
    }

    private func projectCommandEditor(
        title: String,
        detail: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 92)
                .padding(7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var privacySection: some View {
        SettingsSection(title: "隱私與儲存", subtitle: "對話按資料夾保存；刪除時訊息、圖片與檔案一併清除。") {
            HStack {
                Label("API Key 儲存在 macOS Keychain", systemImage: "lock.shield")
                    .font(.callout)
                Spacer()
                Button("清除所有對話…", role: .destructive) { confirmClear = true }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(footerActionTitle) {
                Task { await saveSelectedPage() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                (selectedPage == .connections || selectedPage == .generation)
                    && draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || selectedPage == .pullRequests
                    && pullRequestProviderDraft.apiEndpoint
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(16)
        .background(LumaTheme.surface)
    }

    private var footerMessage: String {
        switch selectedPage {
        case .connections:
            "只儲存目前的 Classic Chat 連線設定；公開網路建議使用 HTTPS。"
        case .generation:
            "模型參數已即時保存；此按鈕儲存系統提示詞與逾時設定。"
        case .agent:
            "只儲存全域 Plan / Agent 設定，不會改動 Classic Chat。"
        case .remoteRunners:
            "Remote Runner 的每項操作會立即保存；私鑰只寫入 Keychain，設定頁不會讀回。"
        case .automations:
            "Automation 的每項操作會立即保存；run history 與 worktree 狀態不依賴此視窗。"
        case .pullRequests:
            "Endpoint 存在 Agent Settings；token 僅存在目前 endpoint 的 Keychain scope。"
        case .project:
            "只儲存目前 Workspace 的 Project Settings。"
        case .mcp, .extensions, .integrations, .updates, .privacy:
            "此頁操作會在你明確按下各項動作時個別套用。"
        }
    }

    private var footerActionTitle: String {
        switch selectedPage {
        case .remoteRunners, .automations, .mcp, .extensions, .integrations, .updates, .privacy: "完成"
        default: "儲存此頁"
        }
    }

    @MainActor
    private func saveSelectedPage() async {
        switch selectedPage {
        case .connections, .generation:
            draft.modelParameterProfiles = viewModel.settings.modelParameterProfiles
            guard await viewModel.applySettings(draft, apiKey: apiKey) else {
                saveError = viewModel.errorMessage ?? "Classic Chat 設定無法儲存。"
                viewModel.errorMessage = nil
                return
            }
        case .agent:
            agentDraft.computerUseAllowedBundleIdentifiers = normalizedComputerUseBundleIdentifiers
            computerUseAllowedBundleIdentifiersText = agentDraft
                .computerUseAllowedBundleIdentifiers
                .joined(separator: "\n")
            guard await agentViewModel.updateSettings(agentDraft) else {
                saveError = agentViewModel.errorMessage ?? "Agent 設定無法儲存。"
                agentViewModel.errorMessage = nil
                return
            }
        case .pullRequests:
            guard await agentViewModel.updatePullRequestConfiguration(
                pullRequestProviderDraft,
                token: pullRequestToken
            ) else {
                saveError = agentViewModel.errorMessage ?? "Pull Request 設定無法儲存。"
                agentViewModel.errorMessage = nil
                return
            }
            pullRequestProviderDraft = agentViewModel.settings.pullRequestProvider
            agentDraft.pullRequestProvider = pullRequestProviderDraft
        case .project:
            do {
                let project = try normalizedProjectDraft()
                guard await agentViewModel.saveProjectSettings(project) else {
                    saveError = agentViewModel.errorMessage ?? "Project Settings 無法儲存。"
                    agentViewModel.errorMessage = nil
                    return
                }
            } catch {
                saveError = error.localizedDescription
                return
            }
        case .remoteRunners, .automations, .mcp, .extensions, .integrations, .updates, .privacy:
            break
        }
        dismiss()
    }

    private func providerIcon(_ provider: ProviderKind) -> String {
        switch provider {
        case .ollama: "server.rack"
        case .openAICompatible: "point.3.connected.trianglepath.dotted"
        case .anthropic: "sparkles"
        }
    }

    private var normalizedComputerUseBundleIdentifiers: [String] {
        AgentComputerUseSettingsLimits.normalizedBundleIdentifiers(
            computerUseAllowedBundleIdentifiersText.components(separatedBy: .newlines)
        )
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func synchronizeProjectDraft(_ settings: AgentProjectSettings) {
        var settings = settings
        if agentViewModel.selectedSession?.projectID != nil {
            // Projects 2.0 owns the catalog name. Workspace settings retain the
            // legacy field only for sessions that have not yet been migrated.
            settings.displayName = nil
        }
        projectDraft = settings
        projectAllowedCommandsText = settings.allowedCommands.joined(separator: "\n")
        projectDeniedCommandsText = settings.deniedCommands.joined(separator: "\n")
        if let ids = settings.mcpServerIDs {
            projectMCPMode = ids.isEmpty ? .none : .selected
            projectMCPServerIDs = Set(ids)
        } else {
            projectMCPMode = .inherit
            projectMCPServerIDs = []
        }
        projectEnvironmentRows = settings.environmentVariables
            .sorted { $0.key < $1.key }
            .map { ProjectEnvironmentRow(key: $0.key, value: $0.value) }
    }

    private func synchronizeProjectCatalogName() {
        projectCatalogNameDraft = agentViewModel.selectedSession.map {
            agentViewModel.projectDisplayName(for: $0)
        } ?? ""
    }

    private func normalizedProjectDraft() throws -> AgentProjectSettings {
        var normalized = projectDraft
        if agentViewModel.selectedSession?.projectID != nil {
            normalized.displayName = nil
        }
        normalized.displayName = normalized.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.displayName?.isEmpty == true { normalized.displayName = nil }
        normalized.preferredModel = normalized.preferredModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.preferredModel?.isEmpty == true { normalized.preferredModel = nil }
        normalized.allowedCommands = normalizedCommandLines(projectAllowedCommandsText)
        normalized.deniedCommands = normalizedCommandLines(projectDeniedCommandsText)
        switch projectMCPMode {
        case .inherit:
            normalized.mcpServerIDs = nil
        case .none:
            normalized.mcpServerIDs = []
        case .selected:
            let configuredIDs = Set(agentViewModel.mcpServers.map(\.id))
            normalized.mcpServerIDs = projectMCPServerIDs
                .intersection(configuredIDs)
                .sorted {
                $0.uuidString < $1.uuidString
            }
        }

        var environment: [String: String] = [:]
        for row in projectEnvironmentRows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                if row.value.isEmpty { continue }
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Environment Variable 有 Value 但缺少 Key。"
                )
            }
            guard environment[key] == nil else {
                throw AgentProjectSettingsError.invalidConfiguration(
                    "Environment Variable key「\(key)」重複。"
                )
            }
            environment[key] = row.value
        }
        normalized.environmentVariables = environment
        normalized.systemPrompt = normalized.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.systemPrompt?.isEmpty == true { normalized.systemPrompt = nil }
        try AgentProjectSettingsValidation.validate(normalized)
        return normalized
    }

    private func normalizedCommandLines(_ value: String) -> [String] {
        value.split(whereSeparator: \Character.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func contextLabel(_ value: Int) -> String {
        value >= 1_024 ? "\(value / 1_024)K" : value.formatted()
    }

    private func selectConfiguration(
        provider: ProviderKind,
        backend: ModelBackendKind,
        endpoint: String
    ) {
        draft.provider = provider
        draft.backend = backend
        draft.endpoint = endpoint
        draft.selectedModel = ""
        credentialScope = KeychainStore.account(for: draft)
        apiKey = viewModel.storedAPIKey(for: draft)
        draftModels = []
        testResult = nil
        testSucceeded = nil
    }

    private func resetCredentialIfScopeChanged() {
        let newScope = KeychainStore.account(for: draft)
        guard newScope != credentialScope else { return }
        activeProbeID = UUID()
        apiKey = viewModel.storedAPIKey(for: draft)
        credentialScope = newScope
        draftModels = []
        testResult = EndpointNormalizer.isValid(draft.endpoint) ? "等待自動檢查…" : "網址尚未完整"
        testSucceeded = nil
    }

    private func resetPullRequestCredentialIfScopeChanged() {
        var candidate = pullRequestProviderDraft
        candidate.providerID = "github"
        guard let normalized = try? candidate.normalized(),
              let newScope = try? PullRequestCredentialStore.account(
                  configuration: normalized
              ) else {
            pullRequestToken = ""
            pullRequestCredentialScope = ""
            return
        }
        guard newScope != pullRequestCredentialScope else { return }
        pullRequestToken = agentViewModel.storedPullRequestToken(for: normalized)
        pullRequestCredentialScope = newScope
    }

    private func loadProfile(_ profile: ConnectionProfile) {
        draft.provider = profile.provider
        draft.backend = profile.resolvedBackend
        draft.endpoint = profile.endpoint
        draft.selectedModel = profile.selectedModel
        draft.activeProfileID = profile.id
        profileName = profile.displayName
        credentialScope = KeychainStore.account(for: profile)
        apiKey = viewModel.storedAPIKey(for: profile)
        draftModels = []
        testResult = "等待自動檢查…"
        testSucceeded = nil
    }

    private func saveCurrentProfile() {
        guard let endpoint = EndpointNormalizer.normalized(draft.endpoint) else {
            testResult = ChatError.invalidEndpoint.localizedDescription
            testSucceeded = false
            return
        }
        draft.endpoint = endpoint
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = draft.connectionProfiles.firstIndex(where: { $0.id == draft.activeProfileID }) {
            draft.connectionProfiles[index].name = name
            draft.connectionProfiles[index].provider = draft.provider
            draft.connectionProfiles[index].backend = draft.resolvedBackend
            draft.connectionProfiles[index].endpoint = endpoint
            draft.connectionProfiles[index].selectedModel = draft.selectedModel
            profileName = draft.connectionProfiles[index].displayName
        } else {
            let profile = ConnectionProfile(
                name: name,
                provider: draft.provider,
                backend: draft.resolvedBackend,
                endpoint: endpoint,
                selectedModel: draft.selectedModel
            )
            draft.connectionProfiles.append(profile)
            draft.activeProfileID = profile.id
            profileName = profile.displayName
        }
    }

    private func removeProfile(_ profile: ConnectionProfile) {
        guard draft.connectionProfiles.count > 1 else { return }
        draft.connectionProfiles.removeAll { $0.id == profile.id }
        if draft.activeProfileID == profile.id, let replacement = draft.connectionProfiles.first {
            loadProfile(replacement)
        }
    }

    private func runConnectionProbe(after delay: Duration? = nil) async {
        let probeID = UUID()
        activeProbeID = probeID
        isTesting = true
        testSucceeded = nil
        testResult = delay == nil ? "正在檢查連線與模型…" : "等待自動檢查…"

        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, activeProbeID == probeID else { return }
        guard EndpointNormalizer.isValid(draft.endpoint) else {
            testResult = ChatError.invalidEndpoint.localizedDescription
            testSucceeded = false
            isTesting = false
            return
        }

        let candidate = draft
        let candidateKey = apiKey
        testResult = "正在檢查連線與模型…"
        let result = await viewModel.testConnection(settings: candidate, apiKey: candidateKey)
        guard !Task.isCancelled, activeProbeID == probeID else { return }
        testResult = result.message
        testSucceeded = result.succeeded
        draftModels = result.models
        if result.succeeded,
           (draft.selectedModel.isEmpty || !result.models.contains(draft.selectedModel)) {
            draft.selectedModel = result.models.first ?? draft.selectedModel
        }
        isTesting = false
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
    }
}
