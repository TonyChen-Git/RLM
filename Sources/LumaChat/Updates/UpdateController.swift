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
    private var blockingPersistenceWarning: String?

    init(
        store: LumaUpdateStateStore = LumaUpdateStateStore(),
        configuration: LumaUpdateTrustConfiguration? = try? LumaUpdateTrustConfiguration.load()
    ) {
        self.store = store
        var startupFailures: [String] = []
        let preferences: LumaUpdatePreferences
        do {
            preferences = try store.loadPreferences()
        } catch {
            // A damaged preference document must not silently re-enable
            // automatic network activity.
            preferences = LumaUpdatePreferences(automaticallyChecksForUpdates: false)
            startupFailures.append("偏好設定：\(error.localizedDescription)")
        }
        let state: LumaUpdatePersistentState
        do {
            state = try store.loadState()
        } catch {
            state = LumaUpdatePersistentState()
            startupFailures.append("更新狀態：\(error.localizedDescription)")
        }
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
        if !startupFailures.isEmpty {
            let warning = "更新資料損壞，已停止所有更新操作：\(startupFailures.joined(separator: "；"))"
            blockingPersistenceWarning = warning
            activity = .failed
            statusMessage = warning
        }
        suppressPreferenceWrite = false
    }

    var isBusy: Bool {
        activity == .checking || activity == .downloading || activity == .launchingHelper
    }

    var canCheck: Bool { service != nil && blockingPersistenceWarning == nil && !isBusy }
    var canPrepare: Bool {
        service != nil && blockingPersistenceWarning == nil && availableRelease != nil && !isBusy
    }
    var canInstall: Bool {
        service != nil && blockingPersistenceWarning == nil && preparedUpdate != nil && !isBusy
    }
    var canRollback: Bool {
        service != nil && blockingPersistenceWarning == nil && lastKnownGood != nil && !isBusy
    }

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
                try refreshPersistedState()
                statusMessage = "新版本已啟動；上一版保留為 Last Known Good"
                activity = .idle
            } catch {
                presentFailure("更新啟動確認失敗", error: error)
                return
            }
        } else {
            surfaceInterruptedTransactionIfNeeded()
        }

        guard blockingPersistenceWarning == nil,
              automaticallyChecksForUpdates,
              service != nil else { return }
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < 6 * 60 * 60 {
            return
        }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard let service, blockingPersistenceWarning == nil, !isBusy else { return }
        activity = .checking
        statusMessage = "正在讀取並驗證簽名 update feed…"
        do {
            let result = try await service.check()
            try recordCheckDate()
            try refreshPersistedState()
            switch result {
            case .current:
                activity = .idle
                statusMessage = "目前已是最新版本"
            case .available(let release):
                activity = .idle
                statusMessage = "可更新至 \(release.version)（build \(release.build)）"
            }
        } catch {
            presentFailure("更新檢查失敗", error: error)
        }
    }

    func downloadAndPrepare() async {
        guard let service, blockingPersistenceWarning == nil, !isBusy else { return }
        activity = .downloading
        statusMessage = "正在下載、驗證雜湊、簽章與 notarization…"
        do {
            let prepared = try await service.downloadAndPrepare()
            try refreshPersistedState()
            preparedUpdate = prepared
            activity = .ready
            statusMessage = "\(prepared.release.version) 已驗證，可安全安裝"
        } catch {
            presentFailure("更新準備失敗", error: error)
        }
    }

    func launchInstall() async -> Bool {
        guard let service, blockingPersistenceWarning == nil, !isBusy else { return false }
        activity = .launchingHelper
        statusMessage = "正在啟動獨立 updater；LumaChat 將安全關閉…"
        do {
            _ = try await service.launchPreparedInstall()
            return true
        } catch {
            presentFailure("無法啟動 updater", error: error)
            return false
        }
    }

    func launchRollback() async -> Bool {
        guard let service, blockingPersistenceWarning == nil, !isBusy else { return false }
        activity = .launchingHelper
        statusMessage = "正在驗證 Last Known Good 並啟動回滾…"
        do {
            _ = try await service.launchRollback()
            return true
        } catch {
            presentFailure("無法回滾", error: error)
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
            presentFailure(
                "自動更新偏好無法保存",
                error: error,
                forceBlocking: true
            )
        }
    }

    private func recordCheckDate() throws {
        var preferences = try store.loadPreferences()
        preferences.lastCheckedAt = Date()
        try store.savePreferences(preferences)
        lastCheckedAt = preferences.lastCheckedAt
    }

    private func refreshPersistedState() throws {
        let state = try store.loadState()
        availableRelease = state.availableRelease
        preparedUpdate = state.preparedUpdate
        lastKnownGood = state.lastKnownGood
    }

    private func presentFailure(
        _ prefix: String,
        error: Error,
        forceBlocking: Bool = false
    ) {
        let message = "\(prefix)：\(error.localizedDescription)"
        if forceBlocking || Self.requiresPersistenceRepair(error) {
            blockingPersistenceWarning = message
        }
        activity = .failed
        statusMessage = message
    }

    private static func requiresPersistenceRepair(_ error: Error) -> Bool {
        guard let updateError = error as? LumaUpdateError else { return false }
        switch updateError {
        case .persistenceFailure, .unsupportedSchema, .transactionInProgress:
            return true
        default:
            return false
        }
    }

    private func surfaceInterruptedTransactionIfNeeded() {
        if blockingPersistenceWarning != nil { return }
        let journal: LumaUpdateJournal
        do {
            guard let stored = try store.loadJournal() else { return }
            journal = stored
        } catch {
            let warning = "更新 transaction journal 損壞，已停止所有更新操作：\(error.localizedDescription)"
            blockingPersistenceWarning = warning
            activity = .failed
            statusMessage = warning
            return
        }
        switch journal.stage {
        case .confirmed:
            statusMessage = "上次更新已確認；Last Known Good 可供手動回滾"
        case .rolledBack:
            activity = .failed
            statusMessage = "上次更新未能確認啟動，已自動回復上一版"
        case .failed:
            blockingPersistenceWarning =
                "上次更新中斷且需要人工檢查：\(journal.failure ?? "未知原因")"
            activity = .failed
            statusMessage = blockingPersistenceWarning!
        case .planned, .prepared, .helperLaunched, .backupCreated, .swapped, .launchRequested:
            blockingPersistenceWarning =
                "偵測到未完成的更新交易；檔案與 journal 已保留，未猜測覆寫"
            activity = .failed
            statusMessage = blockingPersistenceWarning!
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
