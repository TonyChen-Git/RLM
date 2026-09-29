import SwiftUI
import UniformTypeIdentifiers

struct MCPSettingsPane: View {
    @ObservedObject var agentViewModel: AgentViewModel

    @State private var selectedServerID: UUID?
    @State private var draft = MCPServerDraft.newSTDIO()
    @State private var isImporting = false
    @State private var pendingDeleteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP Servers").font(.headline)
                    Text("連接後會 initialize 並探索 Tools、Resources 與 Prompts；Tools 會動態加入 Agent registry。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { isImporting = true } label: {
                    Label("匯入 JSON", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                Menu {
                    Button("STDIO Server") { beginNew(kind: .stdio) }
                    Button("Streamable HTTP Server") { beginNew(kind: .streamableHTTP) }
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(alignment: .top, spacing: 14) {
                serverList
                Divider()
                editor
            }
            .frame(minHeight: 430)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if await agentViewModel.importMCPServers(from: data) {
                        selectedServerID = agentViewModel.mcpServers.first?.id
                        loadSelection()
                    }
                } catch {
                    agentViewModel.errorMessage = "MCP JSON 無法讀取：\(error.localizedDescription)"
                }
            }
        }
        .confirmationDialog(
            "刪除這個 MCP Server？",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )
        ) {
            Button("刪除設定", role: .destructive) {
                guard let id = pendingDeleteID else { return }
                pendingDeleteID = nil
                Task {
                    await agentViewModel.deleteMCPServer(id: id)
                    selectedServerID = agentViewModel.mcpServers.first?.id
                    if selectedServerID == nil { draft = .newSTDIO() }
                    else { loadSelection() }
                }
            }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        }
        .onAppear {
            if selectedServerID == nil { selectedServerID = agentViewModel.mcpServers.first?.id }
            loadSelection()
        }
        .onChange(of: selectedServerID) { loadSelection() }
    }

    private var serverList: some View {
        VStack(spacing: 9) {
            if agentViewModel.mcpServers.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("尚未設定 MCP Server")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(agentViewModel.mcpServers) { server in
                    Button {
                        selectedServerID = server.id
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(stateColor(server.id))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(serverSubtitle(server))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if server.ownerPluginID != nil {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if agentViewModel.mcpBusyServerIDs.contains(server.id) {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .padding(9)
                        .background(
                            server.id == selectedServerID ? LumaTheme.accent.opacity(0.12) : .primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 190)
    }

    @ViewBuilder
    private var editor: some View {
        if let server = selectedServerID.flatMap({ id in
            agentViewModel.mcpServers.first(where: { $0.id == id })
        }), server.ownerPluginID != nil {
            pluginManagedEditor(server)
        } else {
            VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Server 名稱", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                Toggle("啟用", isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            Picker("Transport", selection: $draft.kind) {
                Text("STDIO").tag(MCPTransportKind.stdio)
                Text("Streamable HTTP").tag(MCPTransportKind.streamableHTTP)
            }
            .pickerStyle(.segmented)

            if draft.kind == .stdio {
                labeledField("Command", placeholder: "/opt/homebrew/bin/npx", text: $draft.command)
                labeledField(
                    "Working Directory（選填）",
                    placeholder: "留空＝專案 tmp 內的隔離 runtime",
                    text: $draft.workingDirectory
                )
                labeledEditor("Arguments（每行一個）", text: $draft.argumentsText, height: 72)
                labeledEditor("Environment（每行 KEY=value）", text: $draft.environmentText, height: 82)
            } else {
                labeledField("URL", placeholder: "https://example.com/mcp", text: $draft.url)
                labeledEditor("Headers（每行 NAME=value）", text: $draft.headersText, height: 92)
            }

            Picker("Tool 最低權限", selection: $draft.permissionLevel) {
                Text("依 transport / tool annotation 自動判斷").tag(nil as AgentPermissionLevel?)
                ForEach(AgentPermissionLevel.allCases, id: \.rawValue) { level in
                    Text(level.rawValue.uppercased()).tag(level as AgentPermissionLevel?)
                }
            }

            Picker("Scope", selection: $draft.scope) {
                ForEach(MCPServerScope.allCases, id: \.rawValue) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            if draft.scope == .projectOnly {
                Text(
                    draft.projectPath.map { "只在 Workspace：\($0)" }
                        ?? "儲存時會綁定目前開啟的 Workspace"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Text("STDIO 會啟動本機擴充程序，HTTP 會連線到指定服務。新設定預設停用；請確認命令、工作目錄與權限後再啟用。STDIO 至少是 EXECUTE，HTTP 至少是 NETWORK；Server annotations 只能提高、不能降低權限。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Label("HTTP headers 與敏感 environment values 只存入 macOS Keychain。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            connectionHealth
            discovery

            Spacer(minLength: 0)
            HStack {
                if selectedServerID != nil {
                    Button("刪除", role: .destructive) { pendingDeleteID = selectedServerID }
                    connectionControls
                }
                Spacer()
                Button("儲存 Server") {
                    Task { await saveDraft() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pluginManagedEditor(_ server: MCPServerConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(server.name, systemImage: "puzzlepiece.extension.fill")
                .font(.headline)
                .foregroundStyle(LumaTheme.accent)
            Text("這個 Server 由 Plugin「\(server.ownerPluginID ?? "")」宣告。Transport、權限與啟停狀態由已核准的 manifest 管理，避免 MCP 頁面產生第二份互相衝突的設定。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Transport", value: server.transport.kind == .stdio ? "STDIO" : "Streamable HTTP")
            LabeledContent(
                "Permission",
                value: server.permissionLevel?.rawValue.uppercased() ?? "AUTO"
            )
            connectionHealth
            discovery
            Spacer(minLength: 0)
            HStack {
                connectionControls
                Spacer()
                Label("請在 Extensions 頁面管理", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var connectionHealth: some View {
        if let id = selectedServerID {
            let snapshot = agentViewModel.mcpSnapshot(serverID: id)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(stateColor(id))
                        .frame(width: 8, height: 8)
                    Text("連線狀態：\(healthLabel(for: snapshot))")
                        .font(.caption.weight(.semibold))
                    if agentViewModel.mcpBusyServerIDs.contains(id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let info = snapshot?.serverInfo {
                    Text("Server：\(info.name) \(info.version) · Protocol：\(snapshot?.negotiatedProtocolVersion ?? "未知")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error = snapshot?.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var discovery: some View {
        if let id = selectedServerID, let snapshot = agentViewModel.mcpSnapshot(serverID: id) {
            DisclosureGroup("Discovery · \(snapshot.tools.count) Tools · \(snapshot.resources.count) Resources · \(snapshot.prompts.count) Prompts") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.tools, id: \.name) { tool in
                        Label(tool.title ?? tool.name, systemImage: "hammer")
                    }
                    ForEach(snapshot.resources, id: \.uri) { resource in
                        Label(resource.title ?? resource.name, systemImage: "doc")
                    }
                    ForEach(snapshot.prompts, id: \.name) { prompt in
                        Label(prompt.title ?? prompt.name, systemImage: "text.bubble")
                    }
                }
                .font(.caption)
                .padding(.top, 7)
            }
            DisclosureGroup("Logs · \((snapshot.logs ?? []).count)") {
                VStack(alignment: .leading, spacing: 5) {
                    if (snapshot.logs ?? []).isEmpty {
                        Text("No lifecycle logs yet.").foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.logs ?? []) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue.uppercased())
                                .foregroundStyle(entry.level == .error ? .orange : .secondary)
                            Text(entry.message).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption2.monospaced())
                .padding(.top, 7)
            }
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        if let id = selectedServerID {
            let connected = agentViewModel.mcpSnapshot(serverID: id)?.state == .connected
            let busy = agentViewModel.mcpBusyServerIDs.contains(id)
            let enabled = agentViewModel.mcpServers.first(where: { $0.id == id })?.enabled == true
            Button(connected ? "Disconnect" : "Connect") {
                Task {
                    if connected { await agentViewModel.disconnectMCP(serverID: id) }
                    else { await agentViewModel.connectMCP(serverID: id) }
                }
            }
            .disabled(busy || (!connected && !enabled))
            if connected {
                Button("Reconnect") {
                    Task { await agentViewModel.reconnectMCP(serverID: id) }
                }
                .disabled(busy)
                Button("Refresh Discovery") {
                    Task { await agentViewModel.refreshMCPDiscovery(serverID: id) }
                }
                .disabled(busy)
            }
        }
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func labeledEditor(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: height)
                .padding(7)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func beginNew(kind: MCPTransportKind) {
        selectedServerID = nil
        draft = kind == .stdio ? .newSTDIO() : .newHTTP()
    }

    private func loadSelection() {
        guard let id = selectedServerID,
              let configuration = agentViewModel.mcpServers.first(where: { $0.id == id }) else { return }
        draft = MCPServerDraft(configuration)
    }

    private func saveDraft() async {
        do {
            if draft.scope == .projectOnly, draft.projectPath == nil {
                draft.projectPath = agentViewModel.selectedHostSettingsWorkspace?.rootPath
            }
            let configuration = try draft.configuration()
            if await agentViewModel.saveMCPServer(configuration) {
                selectedServerID = configuration.id
                loadSelection()
            }
        } catch {
            agentViewModel.errorMessage = error.localizedDescription
        }
    }

    private func stateColor(_ id: UUID) -> Color {
        let snapshot = agentViewModel.mcpSnapshot(serverID: id)
        switch snapshot?.state {
        case .connected: return snapshot?.lastError == nil ? Color.green : Color.orange
        case .connecting: return LumaTheme.accent
        case .failed: return Color.orange
        case .disconnected, .none: return Color.secondary.opacity(0.55)
        }
    }

    private func serverSubtitle(_ server: MCPServerConfiguration) -> String {
        let snapshot = agentViewModel.mcpSnapshot(serverID: server.id)
        let state = healthLabel(for: snapshot)
        let tools = snapshot?.tools.count ?? 0
        return tools > 0 ? "\(state) · \(tools) tools" : state
    }

    private func healthLabel(for snapshot: MCPServerSnapshot?) -> String {
        guard let snapshot else { return "Disconnected" }
        if snapshot.state == .connected, snapshot.lastError != nil { return "Connected · Warning" }
        return snapshot.state.rawValue.capitalized
    }
}

private struct MCPServerDraft {
    var id: UUID
    var name: String
    var enabled: Bool
    var kind: MCPTransportKind
    var permissionLevel: AgentPermissionLevel?
    var scope: MCPServerScope
    var projectPath: String?
    var command: String
    var argumentsText: String
    var environmentText: String
    var workingDirectory: String
    var url: String
    var headersText: String

    static func newSTDIO() -> Self {
        .init(
            id: UUID(), name: "", enabled: false, kind: .stdio, permissionLevel: nil,
            scope: .global, projectPath: nil,
            command: "", argumentsText: "", environmentText: "", workingDirectory: "",
            url: "", headersText: ""
        )
    }

    static func newHTTP() -> Self {
        var value = newSTDIO()
        value.kind = .streamableHTTP
        return value
    }

    init(_ configuration: MCPServerConfiguration) {
        id = configuration.id
        name = configuration.name
        enabled = configuration.enabled
        permissionLevel = configuration.permissionLevel
        scope = configuration.scope
        projectPath = configuration.projectPath
        switch configuration.transport {
        case .stdio(let stdio):
            kind = .stdio
            command = stdio.command
            argumentsText = stdio.arguments.joined(separator: "\n")
            environmentText = Self.render(stdio.environment)
            workingDirectory = stdio.workingDirectory ?? ""
            url = ""
            headersText = ""
        case .streamableHTTP(let http):
            kind = .streamableHTTP
            command = ""
            argumentsText = ""
            environmentText = ""
            workingDirectory = ""
            url = http.endpoint.absoluteString
            headersText = Self.render(http.headers)
        }
    }

    private init(
        id: UUID,
        name: String,
        enabled: Bool,
        kind: MCPTransportKind,
        permissionLevel: AgentPermissionLevel?,
        scope: MCPServerScope,
        projectPath: String?,
        command: String,
        argumentsText: String,
        environmentText: String,
        workingDirectory: String,
        url: String,
        headersText: String
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.permissionLevel = permissionLevel
        self.scope = scope
        self.projectPath = projectPath
        self.command = command
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.workingDirectory = workingDirectory
        self.url = url
        self.headersText = headersText
    }

    func configuration() throws -> MCPServerConfiguration {
        if scope == .projectOnly, Self.optional(projectPath ?? "") == nil {
            throw MCPError.invalidConfiguration("Project Only server 需要先開啟一個 Workspace。")
        }
        let transport: MCPTransportConfiguration
        switch kind {
        case .stdio:
            transport = .stdio(
                MCPStdioConfiguration(
                    command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                    arguments: Self.lines(argumentsText),
                    environment: Self.keyValues(environmentText),
                    workingDirectory: Self.optional(workingDirectory)
                )
            )
        case .streamableHTTP:
            guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw MCPError.invalidConfiguration("HTTP URL 無效。")
            }
            transport = .streamableHTTP(
                MCPStreamableHTTPConfiguration(endpoint: endpoint, headers: Self.keyValues(headersText))
            )
        }
        return MCPServerConfiguration(
            id: id,
            name: name,
            enabled: enabled,
            permissionLevel: permissionLevel,
            scope: scope,
            projectPath: scope == .projectOnly ? Self.optional(projectPath ?? "") : nil,
            transport: transport
        )
    }

    private static func lines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func keyValues(_ value: String) -> [String: String] {
        lines(value).reduce(into: [:]) { values, line in
            guard let separator = line.firstIndex(of: "=") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            values[key] = String(line[line.index(after: separator)...])
        }
    }

    private static func render(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "\n")
    }

    private static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
