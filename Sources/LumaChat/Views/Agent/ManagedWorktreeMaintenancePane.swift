import SwiftUI

struct ManagedWorktreeMaintenancePane: View {
    @ObservedObject var agentViewModel: AgentViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCleanup = false
    @State private var confirmRepair = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Managed Worktrees")
                        .font(.title3.weight(.semibold))
                    Text("檢查 Task checkout；清理只會移除七天以上、未租用且乾淨的項目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls

                    if let error = agentViewModel.managedWorktreeMaintenanceError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let report = agentViewModel.managedWorktreeMaintenanceReport {
                        reportView(report)
                    }

                    if agentViewModel.managedWorktreeRecords.isEmpty {
                        ContentUnavailableView(
                            "沒有 Managed Worktree",
                            systemImage: "arrow.triangle.branch",
                            description: Text("建立或移動 Task 到 Managed Worktree 後會顯示在這裡。")
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(agentViewModel.managedWorktreeRecords) { record in
                            worktreeRow(record)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .task { await agentViewModel.refreshManagedWorktrees() }
        .confirmationDialog(
            "清理舊的乾淨 Worktree？",
            isPresented: $confirmCleanup
        ) {
            Button("清理符合條件的 Worktree", role: .destructive) {
                Task { await agentViewModel.cleanupManagedWorktrees() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Task 閒置時，只清理七天以上、未租用且重新檢查為乾淨的 checkout。Git branch 會保留；有變更的檔案不會刪除。")
        }
        .confirmationDialog(
            "修復 Worktree registry？",
            isPresented: $confirmRepair
        ) {
            Button("修復 registry") {
                Task { await agentViewModel.repairManagedWorktrees() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新檢查已登錄的 checkout，修復可證明的 Git metadata，並完成先前待移除的乾淨 checkout。執行中的 Task 會阻止此操作。")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("\(agentViewModel.managedWorktreeRecords.count) 個已登錄")
                .font(.callout.weight(.medium))
            Spacer()
            if agentViewModel.isMaintainingManagedWorktrees {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await agentViewModel.refreshManagedWorktrees() }
            } label: {
                Label("重新載入", systemImage: "arrow.clockwise")
            }
            .disabled(agentViewModel.isMaintainingManagedWorktrees)

            Button("清理舊項目") { confirmCleanup = true }
                .disabled(!agentViewModel.canRunManagedWorktreeMaintenance)

            Button("修復 registry") { confirmRepair = true }
                .disabled(!agentViewModel.canRunManagedWorktreeMaintenance)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func worktreeRow(_ record: ManagedWorktreeRecord) -> some View {
        let inspection = agentViewModel.managedWorktreeInspections[record.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.branchName ?? "Detached HEAD")
                    .font(.callout.weight(.semibold))
                Text(record.state.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record.state == .ready ? Color.green : Color.orange)
                Spacer()
                Button("檢查") {
                    Task { await agentViewModel.inspectManagedWorktree(id: record.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(agentViewModel.isMaintainingManagedWorktrees)
            }

            Text(record.worktreePath)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Text("來源：\(record.repositoryRootPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            HStack(spacing: 12) {
                if let lease = record.lease {
                    Label("Task \(lease.taskID.uuidString.prefix(8)) 使用中", systemImage: "lock.fill")
                } else {
                    Label("未租用", systemImage: "lock.open")
                }
                Text("更新：\(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let inspection {
                HStack(spacing: 10) {
                    Label(inspection.exists ? "Checkout 存在" : "Checkout 遺失",
                          systemImage: inspection.exists ? "checkmark.circle" : "exclamationmark.circle")
                    Text(cleanlinessLabel(inspection.isClean))
                    if !inspection.issues.isEmpty {
                        Text(inspection.issues.map(\.rawValue).joined(separator: "、"))
                    }
                    Text("檢查：\(inspection.inspectedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(inspection.state == .ready ? Color.secondary : Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reportView(_ report: WorktreeMaintenanceReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("最近一次維護")
                .font(.callout.weight(.semibold))
            Text("移除 \(report.removedIDs.count) · 修復 \(report.repairedIDs.count) · 接管 \(report.adoptedIDs.count) · 遺失 \(report.missingIDs.count) · 無效 \(report.invalidIDs.count) · 略過 \(report.skippedIDs.count) · 失敗 \(report.failures.count)")
                .font(.caption)
            ForEach(report.failures.indices, id: \.self) { index in
                let failure = report.failures[index]
                Text("\(failure.operation)：\(failure.detail)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cleanlinessLabel(_ clean: Bool?) -> String {
        switch clean {
        case true: "乾淨"
        case false: "有變更；不會清理"
        case nil: "無法判定是否乾淨"
        }
    }
}
