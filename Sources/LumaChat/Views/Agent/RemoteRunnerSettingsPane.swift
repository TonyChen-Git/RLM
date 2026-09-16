import Foundation
import SwiftUI

struct RemoteRunnerSettingsPane: View {
    @ObservedObject var agentViewModel: AgentViewModel
    @State private var editor: RemoteRunnerEditorDraft?
    @State private var pendingDeletion: RemoteRunnerSummary?
    @State private var verifiedRunnerIDs = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            runnerList
            securityNotes
        }
        .task {
            await agentViewModel.refreshRemoteRunners()
        }
        .sheet(item: $editor) { draft in
            RemoteRunnerEditorSheet(
                draft: draft,
                onCancel: { editor = nil },
                onSave: { configuration, credential in
                    let succeeded = await agentViewModel.upsertRemoteRunner(
                        configuration,
                        credential: credential
                    )
                    if succeeded {
                        verifiedRunnerIDs.remove(configuration.id)
                        editor = nil
                    }
                    return succeeded
                }
            )
        }
        .confirmationDialog(
            "刪除 Remote Runner？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { summary in
            Button("刪除 \(summary.configuration.name)", role: .destructive) {
                pendingDeletion = nil
                verifiedRunnerIDs.remove(summary.id)
                Task { await agentViewModel.deleteRemoteRunner(id: summary.id) }
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { summary in
            Text("非秘密設定與此 runner 的 Keychain 私鑰都會刪除。仍有 Task 綁定時，LumaChat 會拒絕刪除。")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH Remote Runners")
                    .font(.headline)
                Text("每個 Task 以 runner UUID 綁定；執行前會驗證 host receipt，且不會把 SSH 工具假裝成本機工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editor = RemoteRunnerEditorDraft()
            } label: {
                Label("新增", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(agentViewModel.remoteRunnerSummaries.count >= RemoteRunnerLimits.maximumRunners)
        }
    }

    @ViewBuilder
    private var runnerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已儲存的 Runner")
                .font(.headline)

            if agentViewModel.remoteRunnerSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("尚未設定 Remote Runner", systemImage: "network.slash")
                        .font(.callout.weight(.medium))
                    Text("新增後仍須明確把 Task handoff 到該 runner；建立設定本身不會連線或搬移檔案。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            } else {
                ForEach(agentViewModel.remoteRunnerSummaries) { summary in
                    runnerRow(summary)
                }
            }
        }
    }

    private func runnerRow(_ summary: RemoteRunnerSummary) -> some View {
        let configuration = summary.configuration
        let isBusy = agentViewModel.remoteRunnerIsInUse(summary.id)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 11) {
                Toggle("", isOn: Binding(
                    get: { configuration.enabled },
                    set: { enabled in
                        verifiedRunnerIDs.remove(summary.id)
                        Task {
                            await agentViewModel.setRemoteRunnerEnabled(
                                id: summary.id,
                                enabled: enabled
                            )
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBusy)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(configuration.name)
                            .font(.callout.weight(.semibold))
                        if verifiedRunnerIDs.contains(summary.id) {
                            Label("已驗證", systemImage: "checkmark.shield.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        } else if !configuration.enabled {
                            Text("已停用")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(configuration.username)@\(configuration.host):\(configuration.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(configuration.workspaceRoot)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("測試連線") {
                    verifiedRunnerIDs.remove(summary.id)
                    Task {
                        if await agentViewModel.verifyRemoteRunner(id: summary.id) {
                            verifiedRunnerIDs.insert(summary.id)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy || !configuration.enabled || !summary.hasCredential)

                Button {
                    editor = RemoteRunnerEditorDraft(summary)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("編輯 runner；既有私鑰不會載入設定頁")
                .disabled(isBusy)

                Button(role: .destructive) {
                    pendingDeletion = summary
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("刪除 runner 與 Keychain credential")
                .disabled(isBusy)
            }

            HStack(spacing: 12) {
                Label(configuration.authentication.displayTitle, systemImage: authenticationIcon(configuration.authentication))
                Label(
                    credentialStatusText(summary),
                    systemImage: credentialStatusIcon(summary)
                )
                Text("Connect \(formatSeconds(configuration.connectTimeout))s")
                Text("Command \(formatSeconds(configuration.commandTimeout))s")
                Text("Output \(ByteCountFormatter.string(fromByteCount: Int64(configuration.maximumOutputBytes), countStyle: .file))")
            }
            .font(.caption2)
            .foregroundStyle(isMissingPrivateKey(summary) ? Color.orange : Color.secondary)

            Text("known_hosts: \(configuration.knownHostsFile)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }

    private var securityNotes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("安全與連線語意")
                .font(.headline)
            Label("known_hosts 必須是本機絕對檔案路徑；SSH 會使用 strict host-key checking。", systemImage: "checkmark.shield")
            Label("Keychain 私鑰只在執行時短暫物化到專案 tmp，且不會寫入 runner JSON 或 Task。", systemImage: "key.fill")
            Label("連線測試只驗證目前設定；編輯、停用或重新啟動後需再次測試。", systemImage: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func authenticationIcon(_ authentication: RemoteSSHAuthentication) -> String {
        switch authentication {
        case .systemAgent: "person.crop.circle.badge.checkmark"
        case .keychainPrivateKey: "key.fill"
        }
    }

    private func credentialStatusText(_ summary: RemoteRunnerSummary) -> String {
        switch summary.configuration.authentication {
        case .systemAgent: "使用 SSH_AUTH_SOCK"
        case .keychainPrivateKey:
            summary.hasCredential ? "Keychain credential ready" : "缺少私鑰"
        }
    }

    private func credentialStatusIcon(_ summary: RemoteRunnerSummary) -> String {
        switch summary.configuration.authentication {
        case .systemAgent: "link"
        case .keychainPrivateKey: summary.hasCredential ? "key.fill" : "key.slash"
        }
    }

    private func isMissingPrivateKey(_ summary: RemoteRunnerSummary) -> Bool {
        summary.configuration.authentication == .keychainPrivateKey && !summary.hasCredential
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct RemoteRunnerEditorDraft: Identifiable {
    let id = UUID()
    var configurationID = UUID()
    var isExisting = false
    var hadStoredPrivateKey = false
    var name = ""
    var enabled = true
    var host = ""
    var port = "22"
    var username = NSUserName()
    var workspaceRoot = ""
    var knownHostsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh", isDirectory: true)
        .appendingPathComponent("known_hosts", isDirectory: false)
        .path
    var authentication = RemoteSSHAuthentication.keychainPrivateKey
    var connectTimeout = "15"
    var commandTimeout = "120"
    var maximumOutputBytes = String(1 * 1_024 * 1_024)

    init() {}

    init(_ summary: RemoteRunnerSummary) {
        let configuration = summary.configuration
        configurationID = configuration.id
        isExisting = true
        hadStoredPrivateKey = configuration.authentication == .keychainPrivateKey
            && summary.hasCredential
        name = configuration.name
        enabled = configuration.enabled
        host = configuration.host
        port = String(configuration.port)
        username = configuration.username
        workspaceRoot = configuration.workspaceRoot
        knownHostsFile = configuration.knownHostsFile
        authentication = configuration.authentication
        connectTimeout = RemoteRunnerEditorDraft.numberString(configuration.connectTimeout)
        commandTimeout = RemoteRunnerEditorDraft.numberString(configuration.commandTimeout)
        maximumOutputBytes = String(configuration.maximumOutputBytes)
    }

    private static func numberString(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct RemoteRunnerEditorSheet: View {
    @State private var draft: RemoteRunnerEditorDraft
    @State private var privateKey = ""
    @State private var validationError: String?
    @State private var isSubmitting = false

    let onCancel: () -> Void
    let onSave: @MainActor (
        RemoteRunnerConfiguration,
        RemoteRunnerCredentialUpdate
    ) async -> Bool

    init(
        draft: RemoteRunnerEditorDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping @MainActor (
            RemoteRunnerConfiguration,
            RemoteRunnerCredentialUpdate
        ) async -> Bool
    ) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.isExisting ? "編輯 Remote Runner" : "新增 Remote Runner")
                        .font(.title3.weight(.semibold))
                    Text("非秘密設定會永久保存；私鑰只寫入 macOS Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { cancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            .padding(20)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSection
                    authenticationSection
                    limitsSection
                }
                .padding(22)
            }

            Divider().opacity(0.5)

            HStack {
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消") { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(draft.isExisting ? "儲存變更" : "新增 Runner") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(width: 620, height: 650)
        .onChange(of: draft.authentication) { _, authentication in
            if authentication == .systemAgent {
                // Minimize the lifetime of pasted secret material once it is no
                // longer relevant to the selected authentication mechanism.
                privateKey = ""
            }
            validationError = nil
        }
    }

    private var connectionSection: some View {
        editorSection(
            title: "連線與 Workspace",
            subtitle: "所有路徑皆會先經過絕對路徑與 workspace containment 驗證。"
        ) {
            VStack(spacing: 11) {
                editorField("名稱", placeholder: "Build Server", text: $draft.name)
                HStack(spacing: 12) {
                    editorField("Host", placeholder: "builder.example.com", text: $draft.host)
                    editorField("Port", placeholder: "22", text: $draft.port, width: 95)
                }
                editorField("User", placeholder: "runner", text: $draft.username)
                editorField("Remote workspace root", placeholder: "/srv/lumachat/project", text: $draft.workspaceRoot)
                editorField("Local known_hosts file", placeholder: "/Users/me/.ssh/known_hosts", text: $draft.knownHostsFile)
                Toggle("啟用此 runner", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var authenticationSection: some View {
        editorSection(
            title: "Authentication",
            subtitle: "LumaChat 不會從 Keychain 讀回私鑰到這個表單。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("方式", selection: $draft.authentication) {
                    ForEach(RemoteSSHAuthentication.allCases, id: \.self) { authentication in
                        Text(authentication.displayTitle).tag(authentication)
                    }
                }
                .pickerStyle(.segmented)

                switch draft.authentication {
                case .systemAgent:
                    Label("使用本機 ssh-agent 完成外層連線；不會啟用 agent forwarding。儲存後會移除這個 runner 原有的 Keychain 私鑰。", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .keychainPrivateKey:
                    SecureField(privateKeyPlaceholder, text: $privateKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text(privateKeyHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var limitsSection: some View {
        editorSection(
            title: "Timeout 與輸出上限",
            subtitle: "Connect 1–60 秒；Command 1–3600 秒；Output 4 KiB–8 MiB。"
        ) {
            VStack(spacing: 11) {
                HStack(spacing: 12) {
                    editorField("Connect seconds", placeholder: "15", text: $draft.connectTimeout)
                    editorField("Command seconds", placeholder: "120", text: $draft.commandTimeout)
                }
                editorField(
                    "Maximum output bytes",
                    placeholder: "1048576",
                    text: $draft.maximumOutputBytes
                )
            }
        }
    }

    private var privateKeyPlaceholder: String {
        draft.hadStoredPrivateKey
            ? "留空以保留 Keychain 中的既有私鑰"
            : "貼上完整 PEM 私鑰（儲存後不會回顯）"
    }

    private var privateKeyHelp: String {
        if draft.hadStoredPrivateKey {
            return "既有私鑰保持隱藏；只有輸入新內容才會取代它。"
        }
        return "這個 runner 尚無私鑰；Keychain Private Key 模式必須提供完整 PEM 才能儲存。"
    }

    private func editorSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func editorField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    @MainActor
    private func submit() async {
        validationError = nil
        do {
            guard let port = Int(draft.port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteRunnerEditorError.invalidNumber("Port 必須是整數。")
            }
            guard let connectTimeout = TimeInterval(
                draft.connectTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw RemoteRunnerEditorError.invalidNumber("Connect timeout 必須是數字。")
            }
            guard let commandTimeout = TimeInterval(
                draft.commandTimeout.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw RemoteRunnerEditorError.invalidNumber("Command timeout 必須是數字。")
            }
            guard let maximumOutputBytes = Int(
                draft.maximumOutputBytes.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw RemoteRunnerEditorError.invalidNumber("Output limit 必須是整數 bytes。")
            }

            let configuration = try RemoteRunnerConfiguration(
                id: draft.configurationID,
                name: draft.name,
                enabled: draft.enabled,
                host: draft.host,
                port: port,
                username: draft.username,
                workspaceRoot: draft.workspaceRoot,
                knownHostsFile: draft.knownHostsFile,
                authentication: draft.authentication,
                connectTimeout: connectTimeout,
                commandTimeout: commandTimeout,
                maximumOutputBytes: maximumOutputBytes
            ).validated()

            let credential: RemoteRunnerCredentialUpdate
            switch draft.authentication {
            case .systemAgent:
                credential = .remove
            case .keychainPrivateKey:
                if privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard draft.hadStoredPrivateKey else {
                        throw RemoteRunnerEditorError.privateKeyRequired
                    }
                    credential = .unchanged
                } else {
                    credential = .replace(try RemoteRunnerCredential(privateKey: privateKey).validated())
                }
            }

            isSubmitting = true
            // Drop the editor's reference before handing the validated value to
            // the Keychain-owning service. The value survives only in the update
            // passed to that service and is never copied into configuration state.
            privateKey = ""
            let succeeded = await onSave(configuration, credential)
            if !succeeded {
                validationError = "儲存未完成；私鑰已從表單清除，重試時請重新貼上。"
            }
            isSubmitting = false
        } catch {
            validationError = error.localizedDescription
            isSubmitting = false
        }
    }

    private func cancel() {
        privateKey = ""
        onCancel()
    }
}

private enum RemoteRunnerEditorError: LocalizedError {
    case invalidNumber(String)
    case privateKeyRequired

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let message): message
        case .privateKeyRequired:
            "Keychain Private Key 模式必須輸入完整 PEM 私鑰。"
        }
    }
}

private extension RemoteSSHAuthentication {
    var displayTitle: String {
        switch self {
        case .systemAgent: "System ssh-agent"
        case .keychainPrivateKey: "Keychain Private Key"
        }
    }
}
