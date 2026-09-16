import AppKit
import SwiftUI

@MainActor
private final class LumaApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor @Sendable () async -> Void)?
    private var isFinishingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler, !isFinishingTermination else { return .terminateNow }
        isFinishingTermination = true
        Task { @MainActor in
            await shutdownHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct LumaChatApp: App {
    @NSApplicationDelegateAdaptor(LumaApplicationDelegate.self) private var applicationDelegate
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var agentViewModel = AgentViewModel()
    @StateObject private var updateController = LumaUpdateController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(agentViewModel)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    applicationDelegate.shutdownHandler = { [weak agentViewModel] in
                        await agentViewModel?.shutdown()
                    }
                }
                .task {
                    await updateController.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(agentViewModel.activeMode == .chat ? "新增對話" : "新增 Codex 任務") {
                    if agentViewModel.activeMode == .chat {
                        viewModel.createConversation()
                    } else {
                        agentViewModel.createSession(route: viewModel.settings)
                    }
                }
                    .keyboardShortcut("n")

                Button("加入 Project（不建立 Task）…") {
                    Task { await agentViewModel.createProject() }
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(
                        !agentViewModel.activeMode.usesAgentRuntime
                            || agentViewModel.isMutatingProject
                    )
            }
            CommandMenu("對話") {
                Button("停止目前工作") {
                    if agentViewModel.activeMode == .chat,
                       viewModel.selectedConversationIsGenerating {
                        viewModel.stopGenerating()
                    } else if agentViewModel.activeMode.usesAgentRuntime,
                              agentViewModel.selectedSessionIsRunning {
                        agentViewModel.stop()
                    }
                }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(
                        agentViewModel.activeMode == .chat
                            ? !viewModel.selectedConversationIsGenerating
                            : !agentViewModel.selectedSessionIsRunning
                    )
                Divider()
                Button("連線設定…") { viewModel.isShowingSettings = true }
                    .keyboardShortcut(",")
            }
        }
    }
}
