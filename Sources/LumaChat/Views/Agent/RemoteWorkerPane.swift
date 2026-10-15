import AppKit
import SwiftUI

struct RemoteWorkerPane: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agentViewModel: AgentViewModel
    let sessionID: UUID

    @State private var executable = "swift"
    @State private var arguments = "test"
    @State private var allowNetwork = false

    private var binding: AgentWorkerJobBinding? {
        agentViewModel.workerBindingsBySession[sessionID]
    }

    private var job: SelfManagedWorkerJob? {
        agentViewModel.workerJobsBySession[sessionID]
    }

    private var isBusy: Bool { agentViewModel.workerBusySessionIDs.contains(sessionID) }

    private var authorityMatches: Bool {
        guard let binding, let session = agentViewModel.sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        return AgentViewModel.remoteWorkerAuthorityMatches(
            binding, session: session, settings: agentViewModel.settings
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("自管遠端 Worker", systemImage: "server.rack")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("關閉") { dismiss() }
            }
            Text("使用此 Task 的 SSH 主機身分與憑證。Worker 在遠端建立獨立 Git worktree；連線由本機主動發起，不開放 inbound port。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let binding {
                Text("Job：\(binding.jobID.uuidString) · \(job?.status ?? "待重新連線核對")")
                    .font(.caption.monospaced())
                if !authorityMatches {
                    Text("Task 權限或工作區已變更；此連線已封鎖。請在自管主機核對舊 Job，並以新的 SSH Task 啟動新工作。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("重新連線 / 重新整理") {
                        Task { await agentViewModel.refreshRemoteWorkerJob(sessionID: sessionID) }
                    }
                    .disabled(!authorityMatches)
                    Button("取消遠端 Job", role: .destructive) {
                        Task { await agentViewModel.cancelRemoteWorkerJob(sessionID: sessionID) }
                    }
                    .disabled(!authorityMatches || (job.map { ["completed", "failed", "cancelled"].contains($0.status) } ?? false))
                }
                if let job {
                    Text("Commit：\(job.commit) · 心跳：\(job.heartbeatAt.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let logs = agentViewModel.workerLogsBySession[sessionID], !logs.isEmpty {
                    Text("Logs").font(.headline)
                    ScrollView {
                        Text(logs).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
                if let diff = agentViewModel.workerDiffsBySession[sessionID], !diff.isEmpty {
                    HStack {
                        Text("Review diff").font(.headline)
                        Spacer()
                        if agentViewModel.sessions.first(where: { $0.id == sessionID })?
                            .localWorkspace?.gitRepository == true,
                           let job,
                           ["completed", "failed", "cancelled", "interrupted"]
                            .contains(job.status) {
                            Button("在本機隔離 Task 接手") {
                                Task {
                                    if await agentViewModel.takeOverRemoteWorkerJob(
                                        sessionID: sessionID
                                    ) {
                                        dismiss()
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!authorityMatches)
                        }
                        Button("複製 patch 以便本機接手") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diff, forType: .string)
                        }
                    }
                    ScrollView {
                        Text(diff).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 150)
                }
            } else {
                Text("執行檔")
                    .font(.caption.weight(.semibold))
                TextField("swift", text: $executable)
                    .textFieldStyle(.roundedBorder)
                Text("參數（每行一個，依原樣傳遞；不經 shell）")
                    .font(.caption.weight(.semibold))
                TextEditor(text: $arguments)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                Toggle("允許此 Job 使用遠端網路", isOn: $allowNetwork)
                    .disabled(!agentViewModel.settings.networkAccess)
                if !agentViewModel.settings.networkAccess {
                    Text("Agent 網路權限關閉；此 Job 必須使用網路隔離。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("預設要求 Linux network namespace。若遠端無法強制隔離，Job 將拒絕啟動。程式與輸出由自管主機處理，不會送到 LumaChat 託管服務。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("在獨立 Worktree 啟動") {
                    let argv = [executable.trimmingCharacters(in: .whitespacesAndNewlines)]
                        + arguments.split(separator: "\n", omittingEmptySubsequences: true)
                            .map(String.init)
                    Task {
                        _ = await agentViewModel.startRemoteWorkerJob(
                            sessionID: sessionID,
                            argv: argv,
                            network: allowNetwork ? "allow" : "deny"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isBusy { ProgressView("正在核對遠端 Job…").controlSize(.small) }
            if let error = agentViewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 510)
        .disabled(isBusy)
        .onAppear {
            if binding != nil {
                Task { await agentViewModel.refreshRemoteWorkerJob(sessionID: sessionID) }
            }
        }
    }
}
