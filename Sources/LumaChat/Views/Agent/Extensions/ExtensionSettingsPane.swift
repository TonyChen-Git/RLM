import AppKit
import SwiftUI

private enum ExtensionSettingsTab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case available = "Available"
    case updates = "Updates"
    case permissions = "Permissions"

    var id: String { rawValue }
}

private enum RemotePluginSourceKind: String, CaseIterable, Identifiable {
    case git = "Git repository"
    case manifest = "Manifest URL"
    case registry = "Registry"

    var id: String { rawValue }
}

private struct OAuthEditorItem: Identifiable {
    var id = UUID()
    var configuration: OAuthConnectorConfiguration?
}

private struct PendingOAuthFlow: Identifiable {
    var id: UUID { connectorID }
    var connectorID: UUID
    var connectorName: String
    var request: OAuthAuthorizationRequest
}

struct ExtensionSettingsPane: View {
    @ObservedObject var agentViewModel: AgentViewModel

    @State private var selectedTab = ExtensionSettingsTab.installed
    @State private var remoteKind = RemotePluginSourceKind.git
    @State private var sourceURL = ""
    @State private var registryPluginID = ""
    @State private var gitRevision = ""
    @State private var candidate: PluginCandidate?
    @State private var grantedPermissions: Set<ExtensionPermission> = []
    @State private var pendingUninstallID: String?
    @State private var pendingOAuthDeleteID: UUID?
    @State private var oauthEditor: OAuthEditorItem?
    @State private var pendingOAuthFlow: PendingOAuthFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Extensions", selection: $selectedTab) {
                ForEach(ExtensionSettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .installed:
                installedPane
            case .available:
                availablePane
            case .updates:
                updatesPane
            case .permissions:
                permissionsPane
            }
        }
        .task { await agentViewModel.refreshAvailableSkills() }
        .onDisappear {
            guard let stagedCandidate = candidate else { return }
            candidate = nil
            Task { await agentViewModel.discardPluginCandidate(stagedCandidate) }
        }
        .confirmationDialog(
            "移除這個 Plugin？",
            isPresented: Binding(
                get: { pendingUninstallID != nil },
                set: { if !$0 { pendingUninstallID = nil } }
            )
        ) {
            Button("移除 Plugin", role: .destructive) {
                guard let id = pendingUninstallID else { return }
                pendingUninstallID = nil
                Task { await agentViewModel.uninstallPlugin(pluginID: id) }
            }
            Button("取消", role: .cancel) { pendingUninstallID = nil }
        } message: {
            Text("Plugin 的安裝副本及其 managed tools、Skills、Hooks 與 MCP 宣告會一併移除；原始來源不受影響。")
        }
        .confirmationDialog(
            "刪除這個 OAuth Connector？",
            isPresented: Binding(
                get: { pendingOAuthDeleteID != nil },
                set: { if !$0 { pendingOAuthDeleteID = nil } }
            )
        ) {
            Button("刪除 Connector 與 Keychain Token", role: .destructive) {
                guard let id = pendingOAuthDeleteID else { return }
                pendingOAuthDeleteID = nil
                Task { await agentViewModel.deleteOAuthConnector(id: id) }
            }
            Button("取消", role: .cancel) { pendingOAuthDeleteID = nil }
        } message: {
            Text("非秘密設定與這個 Connector 對應的 Keychain credential 都會移除。")
        }
        .sheet(item: $oauthEditor) { item in
            OAuthConnectorEditor(
                initial: item.configuration,
                onSave: { configuration in
                    await agentViewModel.saveOAuthConnector(configuration)
                }
            )
        }
        .sheet(item: $pendingOAuthFlow) { flow in
            OAuthCodeCompletionSheet(
                flow: flow,
                onComplete: { code, verifier, state, accountLabel in
                    await agentViewModel.completeOAuthAuthorization(
                        connectorID: flow.connectorID,
                        code: code,
                        codeVerifier: verifier,
                        state: state,
                        accountLabel: accountLabel
                    )
                }
            )
        }
    }

    private var installedPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            extensionHeader(
                "Installed Plugins",
                detail: "啟停或移除會同步更新 ToolRegistry、Plugin-owned MCP 與 Skill discovery。"
            )
            if agentViewModel.installedPlugins.isEmpty {
                emptyState("尚未安裝 Plugin", icon: "puzzlepiece.extension")
            } else {
                ForEach(agentViewModel.installedPlugins) { plugin in
                    pluginRow(plugin, showsUpdate: false)
                }
            }
            if !agentViewModel.canMutateExtensions {
                Label("有 Task 正在執行；為保持 run snapshot 穩定，Plugin 變更暫時鎖定。", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var availablePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            extensionHeader(
                "Included Workflow Pack",
                detail: "PDF、文件、試算表、簡報、圖片、視覺化與網站工作流；仍會經過標準 Plugin 檢查、權限核准與安裝保存。"
            )
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title2)
                    .foregroundStyle(LumaTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LumaChat Artifact Workflows")
                        .font(.callout.weight(.semibold))
                    Text("7 個可按需載入的 Skills；不會在未選取時注入 Agent context。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(bundledArtifactPackInstalled ? "檢查內建更新" : "檢查並安裝") {
                    inspectBundledArtifactWorkflows()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!agentViewModel.canMutateExtensions)
            }
            .padding(11)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))

            Divider()

            extensionHeader(
                "Install a Plugin",
                detail: "Marketplace 與 runtime 分離；可檢查 local directory、Git、HTTPS manifest 或 registry。安裝前一定先顯示權限。"
            )
            Button {
                inspectLocalDirectory()
            } label: {
                Label("選擇 Local Plugin Directory…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agentViewModel.canMutateExtensions)

            Divider()

            Picker("Remote source", selection: $remoteKind) {
                ForEach(RemotePluginSourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            TextField(remotePlaceholder, text: $sourceURL)
                .textFieldStyle(.roundedBorder)
            if remoteKind == .git {
                TextField("Revision（選填）", text: $gitRevision)
                    .textFieldStyle(.roundedBorder)
            } else if remoteKind == .registry {
                TextField("Plugin ID", text: $registryPluginID)
                    .textFieldStyle(.roundedBorder)
            }
            Button("檢查來源與權限") {
                inspectRemoteSource()
            }
            .buttonStyle(.bordered)
            .disabled(!agentViewModel.canMutateExtensions || sourceURL.trimmed.isEmpty)

            if let candidate {
                candidateCard(candidate)
            }
        }
    }

    private var updatesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            extensionHeader(
                "Plugin Updates",
                detail: "更新會重新 stage、驗證完整 package，並再次要求核准 manifest 的完整權限集合。"
            )
            if agentViewModel.installedPlugins.isEmpty {
                emptyState("沒有可檢查的 Plugin", icon: "arrow.triangle.2.circlepath")
            } else {
                ForEach(agentViewModel.installedPlugins) { plugin in
                    pluginRow(plugin, showsUpdate: true)
                }
            }
            if let candidate {
                candidateCard(candidate)
            }
        }
    }

    private var permissionsPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            DisclosureGroup("Discovered Skills（\(agentViewModel.availableSkills.count)）") {
                VStack(alignment: .leading, spacing: 8) {
                    if agentViewModel.availableSkills.isEmpty {
                        Text("目前 scope 沒有可用 Skill。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(agentViewModel.availableSkills) { skill in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(skill.invocation).font(.callout.monospaced().weight(.semibold))
                                Text(skill.source.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(LumaTheme.accent)
                                Spacer()
                                Text(permissionSummary(skill.permissions))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(9)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("OAuth Connectors（\(agentViewModel.oauthConnectors.count)）") {
                oauthConnectorsPane.padding(.top, 8)
            }

            DisclosureGroup("Lifecycle Hook History（\(agentViewModel.lifecycleHookHistory.count)）") {
                hookHistoryPane.padding(.top, 8)
            }
        }
    }

    private var oauthConnectorsPane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("非秘密設定存在 Application Support；access/refresh token 只進 Keychain。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { oauthEditor = OAuthEditorItem(configuration: nil) } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ForEach(agentViewModel.oauthConnectors) { connector in
                let isConnected = connector.connectedAt != nil
                let statusSymbol = isConnected ? "checkmark.shield.fill" : "link.badge.plus"
                HStack(spacing: 9) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(isConnected ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.name).font(.callout.weight(.medium))
                        Text(connector.accountLabel ?? connector.kind.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { connector.enabled },
                        set: { enabled in
                            Task {
                                await agentViewModel.setOAuthConnectorEnabled(
                                    id: connector.id,
                                    enabled: enabled
                                )
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Button("編輯") {
                        oauthEditor = OAuthEditorItem(configuration: connector)
                    }
                    .controlSize(.small)
                    if !isConnected {
                        Button("連線") { beginOAuth(connector) }
                            .controlSize(.small)
                            .disabled(!connector.enabled)
                    } else {
                        Button("中斷") {
                            Task { await agentViewModel.disconnectOAuthConnector(id: connector.id) }
                        }
                        .controlSize(.small)
                    }
                    Button(role: .destructive) {
                        pendingOAuthDeleteID = connector.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
                .padding(9)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var hookHistoryPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            if agentViewModel.lifecycleHookHistory.isEmpty {
                Text("尚無 hook 執行紀錄。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(agentViewModel.lifecycleHookHistory.suffix(50).reversed()) { record in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(record.succeeded ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.event.rawValue) · \(record.pluginID)")
                            .font(.caption.weight(.semibold))
                        Text(record.output.isEmpty ? "No output" : record.output)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    Text(record.failurePolicy.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pluginRow(_ plugin: InstalledPlugin, showsUpdate: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: plugin.enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                .foregroundStyle(plugin.enabled ? LumaTheme.accent : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(plugin.manifest.name).font(.callout.weight(.semibold))
                    Text("v\(plugin.manifest.version)").font(.caption2).foregroundStyle(.secondary)
                }
                Text(plugin.manifest.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(plugin.source.label) · \(permissionSummary(plugin.grantedPermissions))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                if let error = plugin.lastError, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if showsUpdate {
                Button("檢查") {
                    Task {
                        if let inspected = await agentViewModel.inspectPlugin(source: plugin.source) {
                            await acceptCandidate(inspected)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(!agentViewModel.canMutateExtensions)
            } else {
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { enabled in
                        Task {
                            await agentViewModel.setPluginEnabled(
                                pluginID: plugin.id,
                                enabled: enabled
                            )
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!agentViewModel.canMutateExtensions)
                Button(role: .destructive) { pendingUninstallID = plugin.id } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(!agentViewModel.canMutateExtensions)
            }
        }
        .padding(11)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private func candidateCard(_ candidate: PluginCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.manifest.name) · v\(candidate.manifest.version)")
                        .font(.headline)
                    Text(candidate.manifest.author).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("關閉") {
                    let discarded = self.candidate
                    self.candidate = nil
                    if let discarded {
                        Task { await agentViewModel.discardPluginCandidate(discarded) }
                    }
                }
                .buttonStyle(.plain)
            }
            Text(candidate.manifest.description).font(.caption)
            if let minimum = candidate.manifest.minimumLumaChatVersion {
                Text("Requires LumaChat \(minimum)+")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Required permissions")
                .font(.caption.weight(.semibold))
            if candidate.manifest.permissions.isEmpty {
                Text("None").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(candidate.manifest.permissions) { permission in
                    Toggle(permission.title, isOn: Binding(
                        get: { grantedPermissions.contains(permission) },
                        set: { allowed in
                            if allowed { grantedPermissions.insert(permission) }
                            else { grantedPermissions.remove(permission) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Label("\(candidate.manifest.tools.count) tools", systemImage: "wrench.and.screwdriver")
                Label("\(candidate.manifest.skills.count) skills", systemImage: "text.book.closed")
                Label("\(candidate.manifest.hooks.count) hooks", systemImage: "bolt.horizontal")
                Label("\(candidate.manifest.mcpServers.count) MCP", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button("核准並安裝") {
                Task {
                    if await agentViewModel.installPlugin(
                        candidate,
                        grantedPermissions: grantedPermissions
                    ) {
                        self.candidate = nil
                        selectedTab = .installed
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !agentViewModel.canMutateExtensions
                    || !Set(candidate.manifest.permissions).isSubset(of: grantedPermissions)
            )
        }
        .padding(13)
        .background(LumaTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(LumaTheme.accent.opacity(0.25))
        }
    }

    private func extensionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func emptyState(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var remotePlaceholder: String {
        switch remoteKind {
        case .git: "https://host/owner/plugin.git"
        case .manifest: "https://host/plugin.json"
        case .registry: "https://host/registry.json"
        }
    }

    private var bundledArtifactPackInstalled: Bool {
        agentViewModel.installedPlugins.contains {
            $0.id == BundledPluginCatalog.artifactWorkflowsID
        }
    }

    private func inspectBundledArtifactWorkflows() {
        Task {
            if let inspected = await agentViewModel.inspectBundledArtifactWorkflows() {
                await acceptCandidate(inspected)
            }
        }
    }

    private func inspectLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "檢查 Plugin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let inspected = await agentViewModel.inspectPlugin(
                source: .localDirectory(path: url.path)
            ) {
                await acceptCandidate(inspected)
            }
        }
    }

    private func inspectRemoteSource() {
        let normalizedURL = sourceURL.trimmed
        guard let url = URL(string: normalizedURL) else {
            agentViewModel.errorMessage = "Plugin source URL 無效。"
            return
        }
        let source: PluginSource
        switch remoteKind {
        case .git:
            source = .git(repository: url, revision: gitRevision.trimmed.nilIfBlank)
        case .manifest:
            source = .manifest(url: url)
        case .registry:
            guard let pluginID = registryPluginID.trimmed.nilIfBlank else {
                agentViewModel.errorMessage = "Registry source 需要 Plugin ID。"
                return
            }
            source = .registry(index: url, pluginID: pluginID)
        }
        Task {
            if let inspected = await agentViewModel.inspectPlugin(source: source) {
                await acceptCandidate(inspected)
            }
        }
    }

    @MainActor
    private func acceptCandidate(_ inspected: PluginCandidate) async {
        if let previous = candidate, previous.stagedPath != inspected.stagedPath {
            await agentViewModel.discardPluginCandidate(previous)
        }
        candidate = inspected
        grantedPermissions = Set(inspected.manifest.permissions)
    }

    private func beginOAuth(_ connector: OAuthConnectorConfiguration) {
        Task {
            guard let request = await agentViewModel.oauthAuthorizationRequest(for: connector.id)
            else { return }
            pendingOAuthFlow = PendingOAuthFlow(
                connectorID: connector.id,
                connectorName: connector.name,
                request: request
            )
            NSWorkspace.shared.open(request.url)
        }
    }

    private func permissionSummary(_ permissions: [ExtensionPermission]) -> String {
        permissions.isEmpty ? "No permissions" : permissions.map(\.title).joined(separator: ", ")
    }
}

private struct OAuthConnectorEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (OAuthConnectorConfiguration) async -> Bool

    @State private var id: UUID
    @State private var name: String
    @State private var kind: OAuthConnectorKind
    @State private var authorizationEndpoint: String
    @State private var tokenEndpoint: String
    @State private var clientID: String
    @State private var scopes: String
    @State private var redirectURI: String
    @State private var enabled: Bool
    @State private var connectedAt: Date?
    @State private var accountLabel: String?
    @State private var isSaving = false

    init(
        initial: OAuthConnectorConfiguration?,
        onSave: @escaping (OAuthConnectorConfiguration) async -> Bool
    ) {
        self.onSave = onSave
        let value = initial ?? OAuthConnectorConfiguration(
            name: "",
            kind: .custom,
            authorizationEndpoint: URL(string: "https://example.invalid/oauth/authorize")!,
            tokenEndpoint: URL(string: "https://example.invalid/oauth/token")!,
            clientID: "",
            scopes: [],
            redirectURI: URL(string: "http://127.0.0.1/callback")!
        )
        _id = State(initialValue: value.id)
        _name = State(initialValue: value.name)
        _kind = State(initialValue: value.kind)
        _authorizationEndpoint = State(initialValue: value.authorizationEndpoint.absoluteString)
        _tokenEndpoint = State(initialValue: value.tokenEndpoint.absoluteString)
        _clientID = State(initialValue: value.clientID)
        _scopes = State(initialValue: value.scopes.joined(separator: " "))
        _redirectURI = State(initialValue: value.redirectURI.absoluteString)
        _enabled = State(initialValue: value.enabled)
        _connectedAt = State(initialValue: value.connectedAt)
        _accountLabel = State(initialValue: value.accountLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("OAuth Connector").font(.title3.weight(.semibold))
            TextField("名稱", text: $name).textFieldStyle(.roundedBorder)
            Picker("類型", selection: $kind) {
                ForEach(OAuthConnectorKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            TextField("Authorization endpoint（HTTPS）", text: $authorizationEndpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Token endpoint（HTTPS）", text: $tokenEndpoint)
                .textFieldStyle(.roundedBorder)
            TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
            TextField("Scopes（空白分隔）", text: $scopes).textFieldStyle(.roundedBorder)
            TextField("Redirect URI", text: $redirectURI).textFieldStyle(.roundedBorder)
            Toggle("啟用", isOn: $enabled)
            Text("Client secret 不會寫入此設定。此流程使用 OAuth Authorization Code + PKCE；Token response 僅存入 Keychain。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || configuration == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var configuration: OAuthConnectorConfiguration? {
        guard let authorizationEndpoint = URL(string: authorizationEndpoint.trimmed),
              let tokenEndpoint = URL(string: tokenEndpoint.trimmed),
              let redirectURI = URL(string: redirectURI.trimmed),
              !name.trimmed.isEmpty,
              !clientID.trimmed.isEmpty,
              authorizationEndpoint.host?.hasSuffix(".invalid") != true,
              tokenEndpoint.host?.hasSuffix(".invalid") != true else { return nil }
        return OAuthConnectorConfiguration(
            id: id,
            name: name.trimmed,
            kind: kind,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID.trimmed,
            scopes: scopes.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            redirectURI: redirectURI,
            enabled: enabled,
            connectedAt: connectedAt,
            accountLabel: accountLabel
        )
    }

    private func save() {
        guard let configuration else { return }
        isSaving = true
        Task {
            if await onSave(configuration) { dismiss() }
            isSaving = false
        }
    }
}

private struct OAuthCodeCompletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let flow: PendingOAuthFlow
    let onComplete: (String, String, String, String?) async -> Bool

    @State private var code = ""
    @State private var returnedState = ""
    @State private var accountLabel = ""
    @State private var isCompleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("完成 \(flow.connectorName) 授權").font(.title3.weight(.semibold))
            Text("瀏覽器完成授權後，貼上 callback 的 code 與 state。只有 state 完全相符才會交換 Token。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Authorization code", text: $code).textFieldStyle(.roundedBorder)
            TextField("Returned state", text: $returnedState).textFieldStyle(.roundedBorder)
            TextField("帳號標籤（選填）", text: $accountLabel).textFieldStyle(.roundedBorder)
            if !returnedState.isEmpty && returnedState != flow.request.state {
                Label("State 不相符，已拒絕交換 Token。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("交換 Token") { complete() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isCompleting
                            || code.trimmed.isEmpty
                            || returnedState != flow.request.state
                    )
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func complete() {
        isCompleting = true
        Task {
            if await onComplete(
                code.trimmed,
                flow.request.codeVerifier,
                returnedState,
                accountLabel.trimmed.nilIfBlank
            ) {
                dismiss()
            }
            isCompleting = false
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : trimmed }
}
