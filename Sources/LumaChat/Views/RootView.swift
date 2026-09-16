import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if agentViewModel.activeMode == .chat {
                    SidebarView()
                } else {
                    AgentSidebarView()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if agentViewModel.activeMode == .chat {
                ChatDetailView()
            } else {
                AgentDetailView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(LumaTheme.accent)
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(viewModel: viewModel, agentViewModel: agentViewModel)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if let message = viewModel.errorMessage {
                    LumaNoticeBanner(
                        title: "Chat",
                        message: message,
                        style: .error,
                        dismiss: {
                            if viewModel.errorMessage == message {
                                viewModel.errorMessage = nil
                            }
                        }
                    )
                }
                if let message = agentViewModel.errorMessage {
                    LumaNoticeBanner(
                        title: "Codex",
                        message: message,
                        style: .error,
                        dismiss: {
                            if agentViewModel.errorMessage == message {
                                agentViewModel.errorMessage = nil
                            }
                        }
                    )
                }
                if let message = viewModel.statusMessage {
                    LumaNoticeBanner(
                        title: "Chat",
                        message: message,
                        style: .status,
                        dismiss: {
                            if viewModel.statusMessage == message {
                                viewModel.statusMessage = nil
                            }
                        }
                    )
                }
                if let message = agentViewModel.statusMessage {
                    LumaNoticeBanner(
                        title: "Codex",
                        message: message,
                        style: .status,
                        dismiss: {
                            if agentViewModel.statusMessage == message {
                                agentViewModel.statusMessage = nil
                            }
                        }
                    )
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)
        .animation(.easeInOut(duration: 0.2), value: agentViewModel.errorMessage)
        .animation(.easeInOut(duration: 0.2), value: agentViewModel.statusMessage)
        .task {
            async let chatStart: Void = viewModel.start()
            async let agentStart: Void = agentViewModel.start()
            _ = await (chatStart, agentStart)
        }
    }
}

private struct LumaNoticeBanner: View {
    enum Style: Equatable {
        case error
        case status

        var icon: String {
            switch self {
            case .error: "exclamationmark.triangle.fill"
            case .status: "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .error: .orange
            case .status: LumaTheme.accent
            }
        }

        var autoDismisses: Bool { self == .status }
    }

    let title: String
    let message: String
    let style: Style
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("關閉提示")
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(style.color.opacity(0.28))
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
        .task(id: message) {
            guard style.autoDismisses else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
