import AppKit
import SwiftUI

struct UpdateSettingsPane: View {
    @ObservedObject var controller: LumaUpdateController
    @State private var confirmsInstall = false
    @State private var confirmsRollback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(
                title: "簽名更新",
                subtitle: "只接受 release 內建 Ed25519 公鑰簽署、Developer ID Team 相符且已 stapled notarization 的完整 App。"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        "啟動後自動檢查更新（每 6 小時最多一次）",
                        isOn: $controller.automaticallyChecksForUpdates
                    )
                    .disabled(controller.activity == .disabled)

                    labeledValue("Feed", controller.feedDisplay)
                    labeledValue(
                        "Public key fingerprint",
                        controller.publicKeyFingerprint ?? "未配置"
                    )
                    if let checked = controller.lastCheckedAt {
                        labeledValue("最近檢查", checked.formatted(date: .abbreviated, time: .standard))
                    }

                    HStack(spacing: 8) {
                        if controller.isBusy { ProgressView().controlSize(.small) }
                        Text(controller.statusMessage)
                            .font(.callout)
                            .foregroundStyle(controller.activity == .failed ? .red : .secondary)
                        Spacer()
                    }

                    HStack(spacing: 9) {
                        Button("檢查更新") {
                            Task { await controller.checkForUpdates() }
                        }
                        .disabled(!controller.canCheck)

                        Button("下載並驗證") {
                            Task { await controller.downloadAndPrepare() }
                        }
                        .disabled(!controller.canPrepare)

                        Button("安裝並重新啟動") { confirmsInstall = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!controller.canInstall)
                    }
                }
            }

            if let release = controller.availableRelease {
                SettingsSection(title: "可用版本", subtitle: "Feed payload 已通過簽章與相容性驗證。") {
                    labeledValue("版本", "\(release.version)（build \(release.build)）")
                    labeledValue("最低 macOS", release.minimumSystemVersion)
                    labeledValue("架構", release.architectures.joined(separator: ", "))
                    labeledValue("SHA-256", release.archiveSHA256)
                }
            }

            SettingsSection(
                title: "Rollback",
                subtitle: "只有上一次成功更新時保存且重新驗證 Developer ID、Team、bundle、版本與 notarization 的 Last Known Good 可回滾。"
            ) {
                if let backup = controller.lastKnownGood {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(backup.version)（build \(backup.build)）")
                                .font(.callout.weight(.medium))
                            Text("保存於受控 update backup；不會由模型或 feed 指定路徑。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("回滾並重新啟動…", role: .destructive) {
                            confirmsRollback = true
                        }
                        .disabled(!controller.canRollback)
                    }
                } else {
                    Label("目前沒有已驗證的 Last Known Good。", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("安裝已驗證的更新？", isPresented: $confirmsInstall) {
            Button("關閉 LumaChat 並安裝") {
                Task {
                    if await controller.launchInstall() { NSApp.terminate(nil) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("獨立 updater 會原子交換 App、重新驗證並等待新版本確認；120 秒內未確認會自動換回上一版。")
        }
        .confirmationDialog("回滾至 Last Known Good？", isPresented: $confirmsRollback) {
            Button("關閉 LumaChat 並回滾", role: .destructive) {
                Task {
                    if await controller.launchRollback() { NSApp.terminate(nil) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回滾仍會重新檢查 Developer ID、Team、bundle 與 notarization，且保留目前版本作為安全備份。")
        }
    }

    @ViewBuilder
    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).frame(width: 128, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }
}
