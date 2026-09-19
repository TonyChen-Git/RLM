import Foundation

#if os(macOS) && canImport(UserNotifications)
@preconcurrency import UserNotifications

final class SystemAgentNotificationBackend: NSObject, AgentNotificationBackend, @unchecked Sendable {
    private let center: UNUserNotificationCenter?
    private let interactionHandlerLock = NSLock()
    private var interactionHandler: (@Sendable (AgentNotificationInteraction) async -> Void)?

    init(center: UNUserNotificationCenter? = nil) {
        // UserNotifications raises an Objective-C exception when accessed from
        // an unbundled executable such as xctest or `swift run`. Only resolve
        // the process-wide center when LumaChat is actually inside an app bundle.
        let resolvedCenter = center ?? (
            Bundle.main.bundleURL.pathExtension == "app"
                ? UNUserNotificationCenter.current()
                : nil
        )
        self.center = resolvedCenter
        super.init()
        guard let resolvedCenter else { return }
        resolvedCenter.delegate = self
        let categories = Set(AgentNotificationKind.allCases.map {
            UNNotificationCategory(
                identifier: $0.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        })
        resolvedCenter.setNotificationCategories(categories)
    }

    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        @unknown default:
            .unavailable
        }
    }

    /// This is intentionally the sole system adapter entry point that can
    /// display a macOS authorization prompt.
    func requestAuthorization() async throws -> AgentNotificationAuthorizationStatus {
        guard let center else { return .unavailable }
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    func deliver(_ request: AgentNotificationRequest) async throws {
        guard let center else {
            throw AgentNotificationServiceError.backendUnavailable
        }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.subtitle = request.subtitle ?? ""
        content.body = request.body
        content.categoryIdentifier = request.categoryIdentifier
        content.threadIdentifier = request.threadIdentifier ?? ""
        content.sound = .default
        var userInfo: [AnyHashable: Any] = [:]
        for (key, value) in request.userInfo {
            userInfo[AnyHashable(key)] = value
        }
        content.userInfo = userInfo

        let systemRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(systemRequest)
    }

    func setInteractionHandler(
        _ handler: (@Sendable (AgentNotificationInteraction) async -> Void)?
    ) async {
        storeInteractionHandler(handler)
    }

    private func storeInteractionHandler(
        _ handler: (@Sendable (AgentNotificationInteraction) async -> Void)?
    ) {
        interactionHandlerLock.lock()
        interactionHandler = handler
        interactionHandlerLock.unlock()
    }

    private func currentInteractionHandler()
        -> (@Sendable (AgentNotificationInteraction) async -> Void)? {
        interactionHandlerLock.lock()
        defer { interactionHandlerLock.unlock() }
        return interactionHandler
    }
}

extension SystemAgentNotificationBackend: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        var userInfo: [String: String] = [:]
        for (rawKey, rawValue) in response.notification.request.content.userInfo {
            guard let key = rawKey.base as? String,
                  let value = rawValue as? String else { continue }
            userInfo[key] = value
        }
        let interaction = AgentNotificationInteraction(
            requestIdentifier: response.notification.request.identifier,
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        )
        if let handler = currentInteractionHandler() {
            Task {
                await handler(interaction)
            }
        }
        completionHandler()
    }
}
#else
/// Cross-platform composition fallback. Other platforms can inject their own
/// backend without conditionals in Agent/automation code.
actor SystemAgentNotificationBackend: AgentNotificationBackend {
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        .unavailable
    }

    func requestAuthorization() async throws -> AgentNotificationAuthorizationStatus {
        .unavailable
    }

    func deliver(_: AgentNotificationRequest) async throws {
        throw AgentNotificationServiceError.backendUnavailable
    }

    func setInteractionHandler(
        _: (@Sendable (AgentNotificationInteraction) async -> Void)?
    ) async {}
}
#endif
