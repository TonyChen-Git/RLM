import SwiftUI

/// A side chat exists only while its sheet is open. The parent is a value
/// snapshot and is never handed to the text-only generation path as a runtime.
struct SideChatConfiguration: Identifiable {
    let id = UUID()
    let parent: AgentSession
    let route: AppSettings
    let apiKey: String?
}

struct SideChatPane: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var agentViewModel: AgentViewModel
    @StateObject private var sideChat: SideChatSession

    init(configuration: SideChatConfiguration, agentViewModel: AgentViewModel) {
        self.agentViewModel = agentViewModel
        _sideChat = StateObject(
            wrappedValue: SideChatSession(
                parent: configuration.parent,
                route: configuration.route,
                apiKey: configuration.apiKey
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(LumaTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Side chat")
                        .font(.title3.weight(.semibold))
                    Text(sideChat.parentTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("原 Task：\(parentStatusLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("關閉") { dismiss() }
            }
            .padding(18)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                Text("唯讀暫存對話。只能依開啟時的 Task 文字摘要回答；不會使用工具、讀取檔案、核准操作或修改原 Task。關閉後對話會清除。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if sideChat.messages.isEmpty {
                            Text("向 Side chat 詢問這個 Task 的背景或進度。")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        ForEach(sideChat.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == .user ? "你" : "Side chat")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(message.content.isEmpty && sideChat.isGenerating
                                     ? "正在回覆…" : message.content)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(
                                message.role == .user
                                    ? LumaTheme.accent.opacity(0.10)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: sideChat.messages.count) { _, _ in
                    guard let id = sideChat.messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            if let error = sideChat.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("詢問這個 Task…", text: $sideChat.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .disabled(sideChat.isGenerating)
                if sideChat.isGenerating {
                    Button("停止") { sideChat.cancel() }
                } else {
                    Button("傳送") { sideChat.send() }
                        .disabled(!sideChat.canSend)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(18)
        }
        .frame(minWidth: 500, minHeight: 480)
        .onDisappear { sideChat.close() }
    }

    private var parentStatusLabel: String {
        if agentViewModel.isRunning(sessionID: sideChat.parentTaskID) { return "執行中" }
        guard let parent = agentViewModel.sessions.first(where: {
            $0.id == sideChat.parentTaskID
        }) else { return "已移除" }
        switch parent.state {
        case .idle: return "待命"
        case .running: return "執行中"
        case .awaitingApproval: return "等待核准"
        case .paused: return "已暫停"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "失敗"
        case .stepLimit: return "已達步數上限"
        }
    }
}
