import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var pendingDelete: Conversation?

    private var filteredConversations: [Conversation] {
        let query = viewModel.sidebarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.conversations }
        return viewModel.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 31)
                Text("Luma Chat")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Button { viewModel.createConversation() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("新增對話 ⌘N")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            SearchField(text: $viewModel.sidebarSearch)
                .padding(.horizontal, 11)
                .padding(.bottom, 10)

            if filteredConversations.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: viewModel.sidebarSearch.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(viewModel.sidebarSearch.isEmpty ? "開始第一段對話" : "找不到對話")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(selection: $viewModel.selectedConversationID) {
                    Section("最近對話") {
                        ForEach(filteredConversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isGenerating: viewModel.isConversationGenerating(conversation.id)
                            )
                                .tag(conversation.id)
                                .contextMenu {
                                    Button("刪除對話…", role: .destructive) {
                                        pendingDelete = conversation
                                    }
                                }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.55)
            HStack(spacing: 9) {
                ConnectionDot(state: viewModel.connectionState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.settings.provider.title)
                        .font(.caption.weight(.medium))
                    Text(viewModel.connectionState.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { viewModel.isShowingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help("連線與模型設定")
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "永久刪除「\(pendingDelete?.title ?? "此對話")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("刪除訊息與附件", role: .destructive) {
                guard let id = pendingDelete?.id else { return }
                pendingDelete = nil
                Task { await viewModel.deleteConversation(id: id) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("儲存的訊息與附件會一起移除，無法復原。")
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isGenerating: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LumaTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(conversation.model.isEmpty ? conversation.provider.title : conversation.model)
                        .lineLimit(1)
                    Text("·")
                    Text(conversation.updatedAt.conversationTimestamp)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .help("對話在背景產生回覆")
                    .accessibilityLabel("背景產生回覆中")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋對話", text: $text)
                .textFieldStyle(.plain)
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
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct BrandMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(LumaTheme.brandGradient)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.47, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: LumaTheme.accent.opacity(0.28), radius: 7, y: 3)
    }
}

struct ConnectionDot: View {
    let state: ConnectionState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
            .shadow(color: state.color.opacity(0.55), radius: 4)
    }
}
