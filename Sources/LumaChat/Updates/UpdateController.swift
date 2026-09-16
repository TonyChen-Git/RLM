import AppKit
import Combine
import CryptoKit
import Foundation
import LumaUpdateCore

@MainActor
final class LumaUpdateController: ObservableObject {
    enum Activity: Equatable {
        case idle
        case checking
        case downloading
        case ready
        case launchingHelper
        case disabled
        case failed
    }

    static let shared = LumaUpdateController()

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var statusMessage = "尚未檢查更新"
    @Published private(set) var availableRelease: LumaUpdateRelease?
    @Published private(set) var preparedUpdate: LumaPreparedUpdate?
    @Published private(set) var lastKnownGood: LumaLastKnownGoodApplication?
    @Published private(set) var lastCheckedAt: Date?
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { persistAutomaticPreferenceIfNeeded() }
    }

    let feedDisplay: String
    let publicKeyFingerprint: String?

    private let store: LumaUpdateStateStore
    private let service: LumaUpdateService?
    private var isStarting = false
    private var suppressPreferenceWrite = true

    init(
        store: LumaUpdateStateStore = LumaUpdateStateStore(),
        configuration: LumaUpdateTrustConfiguration? = try? LumaUpdateTrustConfiguration.load()
    ) {
        self.store = store
        let preferences = (try? store.loadPreferences()) ?? LumaUpdatePreferences()
        let state = (try? store.loadState()) ?? LumaUpdatePersistentState()
        automaticallyChecksForUpdates = preferences.automaticallyChecksForUpdates
        lastCheckedAt = preferences.lastCheckedAt
        availableRelease = state.availableRelease
        preparedUpdate = state.preparedUpdate
        lastKnownGood = state.lastKnownGood
        if let configuration {
            feedDisplay = configuration.feedURL.absoluteString
            let keyData = Data(base64Encoded: configuration.publicKeyBase64) ?? Data()
            publicKeyFingerprint = SHA256.hash(data: keyData)
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            service = LumaUpdateService(configuration: configuration, stateStore: store)
            if state.preparedUpdate != nil {
                activity = .ready
                statusMessage = "更新已完成下載與信任驗證"
            }
        } else {
            feedDisplay = "此 build 未配置簽名 update feed"
            publicKeyFingerprint = nil
            service = nil
            activity = .disabled
            statusMessage = "更新已停用：缺少 release 注入的 HTTPS feed、Ed25519 公鑰或 Team ID"
        }
        suppressPreferenceWrite = false
    }

    var isBusy: Bool {
        activity == .checking || activity == .downloading || activity == .launchingHelper
    }

    var canCheck: Bool { service != nil && !isBusy }
    var canPrepare: Bool { service != nil && availableRelease != nil && !isBusy }
    var canInstall: Bool { service != nil && preparedUpdate != nil && !isBusy }
    var canRollback: Bool { service != nil && lastKnownGood != nil && !isBusy }

    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        if let installationID = Self.requestedInstallationID {
            do {
                // Confirm only after the main run loop and root view remained
                // alive briefly. The external helper automatically restores the
                // prior app if this receipt never appears.
                try await Task.sleep(for: .seconds(3))
                try store.confirmLaunch(installationID: installationID)
                refreshPersistedState()
                statusMessage = "新版本已啟動；上一版保留為 Last Known Good"
                activity = .idle
            } catch {
                activity = .failed
                statusMessage = "更新啟動確認失敗：\(error.localizedDescription)"
                return
            }
        } else {
            surfaceInterruptedTransactionIfNeeded()
        }

        guard automaticallyChecksForUpdates, service != nil else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 6 * 60 * 60 {
            return
        }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard let service, !isBusy else { return }
        activity = .checking
        statusMessage = "正在讀取並驗證簽名 update feed…"
        do {
            let result = try await service.check()
            recordCheckDate()
            refreshPersistedState()
            switch result {
            case .current:
                activity = .idle
                statusMessage = "目前已是最新版本"
            case .available(let release):
                activity = .idle
                statusMessage = "可更新至 \(release.version)（build \(release.build)）"
            }
        } catch {
            activity = .failed
            statusMessage = "更新檢查失敗：\(error.localizedDescription)"
        }
    }

    func downloadAndPrepare() async {
        guard let service, !isBusy else { return }
        activity = .downloading
        statusMessage = "正在下載、驗證雜湊、簽章與 notarization…"
        do {
            let prepared = try await service.downloadAndPrepare()
            refreshPersistedState()
            preparedUpdate = prepared
            activity = .ready
            statusMessage = "\(prepared.release.version) 已驗證，可安全安裝"
        } catch {
            activity = .failed
            statusMessage = "更新準備失敗：\(error.localizedDescription)"
        }
    }

    func launchInstall() async -> Bool {
        guard let service, !isBusy else { return false }
        activity = .launchingHelper
        statusMessage = "正在啟動獨立 updater；LumaChat 將安全關閉…"
        do {
            _ = try await service.launchPreparedInstall()
            return true
        } catch {
            activity = .failed
            statusMessage = "無法啟動 updater：\(error.localizedDescription)"
            return false
        }
    }

    func launchRollback() async -> Bool {
        guard let service, !isBusy else { return false }
        activity = .launchingHelper
        statusMessage = "正在驗證 Last Known Good 並啟動回滾…"
        do {
            _ = try await service.launchRollback()
            return true
        } catch {
            activity = .failed
            statusMessage = "無法回滾：\(error.localizedDescription)"
            return false
        }
    }

    private func persistAutomaticPreferenceIfNeeded() {
        guard !suppressPreferenceWrite else { return }
        do {
            var preferences = try store.loadPreferences()
            preferences.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            try store.savePreferences(preferences)
        } catch {
            activity = .failed
            statusMessage = "自動更新偏好無法保存：\(error.localizedDescription)"
        }
    }

    private func recordCheckDate() {
        do {
            var preferences = try store.loadPreferences()
            preferences.lastCheckedAt = Date()
            try store.savePreferences(preferences)
            lastCheckedAt = preferences.lastCheckedAt
        } catch {
            activity = .failed
            statusMessage = "更新檢查時間無法保存：\(error.localizedDescription)"
        }
    }

    private func refreshPersistedState() {
        guard let state = try? store.loadState() else { return }
        availableRelease = state.availableRelease
        preparedUpdate = state.preparedUpdate
        lastKnownGood = state.lastKnownGood
    }

    private func surfaceInterruptedTransactionIfNeeded() {
        guard let journal = try? store.loadJournal() else { return }
        switch journal.stage {
        case .confirmed:
            statusMessage = "上次更新已確認；Last Known Good 可供手動回滾"
        case .rolledBack:
            activity = .failed
            statusMessage = "上次更新未能確認啟動，已自動回復上一版"
        case .failed:
            activity = .failed
            statusMessage = "上次更新中斷且需要人工檢查：\(journal.failure ?? "未知原因")"
        case .planned, .prepared, .helperLaunched, .backupCreated, .swapped, .launchRequested:
            activity = .failed
            statusMessage = "偵測到未完成的更新交易；檔案與 journal 已保留，未猜測覆寫"
        }
    }

    private static var requestedInstallationID: UUID? {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--update-install-id"),
              index + 1 < arguments.count,
              arguments.filter({ $0 == "--update-install-id" }).count == 1 else {
            return nil
        }
        return UUID(uuidString: arguments[index + 1])
    }
}
