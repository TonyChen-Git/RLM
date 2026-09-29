import SwiftUI

/// Manual, review-first project memory controls. Text is proposed by the user,
/// then separately approved before a future run may send it to a provider.
struct AgentLocalMemoryPane: View {
    @EnvironmentObject private var agentViewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var proposedText = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @State private var isConfirmingClear = false

    private var session: AgentSession? { agentViewModel.selectedSession }
    private var snapshot: AgentLocalMemorySnapshot {
        agentViewModel.selectedLocalMemorySnapshot
    }
    private var canConfigure: Bool {
        agentViewModel.settings.memoriesEnabled && session?.projectID != nil
    }
    private var canContribute: Bool {
        canConfigure && snapshot.enabled
            && session?.memoryContributionEnabled == true
    }
    private var taskPolicyIsMutating: Bool {
        session.map { agentViewModel.memoryPolicyMutationSessionIDs.contains($0.id) } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本機記憶").font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("記憶依 Project 儲存在本機。只有您核准的內容，才會在下一次已啟用記憶的 Task 執行時傳給目前選用的模型供應商。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if !agentViewModel.settings.memoriesEnabled {
                        Label("請先在 Agent 設定中啟用本機記憶。", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    } else if session?.projectID == nil {
                        Label("此 Task 尚未連結 Project。", systemImage: "folder.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }

                    Toggle("啟用此 Project 的本機記憶", isOn: Binding(
                        get: { snapshot.enabled },
                        set: { enabled in
                            Task { await agentViewModel.setSelectedProjectMemoryEnabled(enabled) }
                        }
                    ))
                    .disabled(!canConfigure)

                    Toggle("此 Task 在執行時使用已核准記憶", isOn: Binding(
                        get: { session?.memoryUseEnabled == true },
                        set: { enabled in
                            Task {
                                await agentViewModel.setSelectedTaskMemoryPolicy(
                                    useEnabled: enabled
                                )
                            }
                        }
                    ))
                    .disabled(!canConfigure || !snapshot.enabled
                        || agentViewModel.selectedSessionIsRunning || taskPolicyIsMutating)

                    Toggle("允許此 Task 提交記憶提案", isOn: Binding(
                        get: { session?.memoryContributionEnabled == true },
                        set: { enabled in
                            Task {
                                await agentViewModel.setSelectedTaskMemoryPolicy(
                                    contributionEnabled: enabled
                                )
                            }
                        }
                    ))
                    .disabled(!canConfigure || !snapshot.enabled
                        || agentViewModel.selectedSessionIsRunning || taskPolicyIsMutating)

                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("新增提案").font(.headline)
                        Text("請輸入值得下次沿用的偏好或專案事實。提案儲存後仍須另行核准。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $proposedText)
                            .frame(minHeight: 75)
                            .padding(7)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Spacer()
                            Button("儲存提案") {
                                let text = proposedText
                                Task {
                                    if await agentViewModel.proposeSelectedLocalMemory(text) {
                                        proposedText = ""
                                    }
                                }
                            }
                            .disabled(!canContribute
                                || proposedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Divider()
                    HStack {
                        Text("Project 記憶").font(.headline)
                        Spacer()
                        if !snapshot.entries.isEmpty {
                            Button("全部清除", role: .destructive) {
                                isConfirmingClear = true
                            }
                        }
                    }
                    if snapshot.entries.isEmpty {
                        Text("尚無記憶。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.entries.reversed()) { entry in
                            memoryRow(entry)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 560, minHeight: 580)
        .task(id: session?.projectID) {
            await agentViewModel.refreshSelectedLocalMemories()
        }
        .alert("清除所有 Project 記憶？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) {
                Task { await agentViewModel.clearSelectedLocalMemories() }
            }
        } message: {
            Text("此操作會移除已核准內容與待審提案。")
        }
    }

    private func memoryRow(_ entry: AgentLocalMemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    entry.status == .approved ? "已核准" : "待審核",
                    systemImage: entry.status == .approved ? "checkmark.seal" : "clock"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.status == .approved ? .green : .orange)
                Spacer()
                Button("編輯") {
                    editingID = entry.id
                    editingText = entry.text
                }
                Button("刪除", role: .destructive) {
                    Task { await agentViewModel.removeSelectedLocalMemory(id: entry.id) }
                }
            }
            if editingID == entry.id {
                TextEditor(text: $editingText)
                    .frame(minHeight: 65)
                HStack {
                    Button("取消") { editingID = nil }
                    Button("儲存修改") {
                        let text = editingText
                        Task {
                            if await agentViewModel.updateSelectedLocalMemory(
                                id: entry.id, text: text
                            ) {
                                editingID = nil
                            }
                        }
                    }
                    .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("修改後會回到待審核狀態。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
                if entry.status == .proposed {
                    Button("核准供下次執行使用") {
                        Task { await agentViewModel.approveSelectedLocalMemory(id: entry.id) }
                    }
                    .disabled(!canConfigure || !snapshot.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}
