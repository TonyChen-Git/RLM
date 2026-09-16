import Foundation

enum AgentNotificationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case taskCompleted = "task_completed"
    case approvalRequired = "approval_required"
    case automationCompleted = "automation_completed"
    case automationFailed = "automation_failed"
    case subagentBlocked = "subagent_blocked"
    case remoteAgentWaiting = "remote_agent_waiting"

    var defaultTitle: String {
        switch self {
        case .taskCompleted:
            "Task completed"
        case .approvalRequired:
            "Approval required"
        case .automationCompleted:
            "Automation completed"
        case .automationFailed:
            "Automation failed"
        case .subagentBlocked:
            "Subagent blocked"
        case .remoteAgentWaiting:
            "Remote Agent waiting"
        }
    }

    var categoryIdentifier: String {
        "com.lumachat.notification.\(rawValue)"
    }
}

enum AgentNotificationAuthorizationStatus: String, Codable, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unavailable

    var permitsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied, .unavailable:
            false
        }
    }
}

struct AgentNotificationEvent: Equatable, Sendable {
    var kind: AgentNotificationKind
    var title: String
    var subtitle: String?
    var body: String
    var taskID: UUID?
    var deepLink: URL?
    var metadata: [String: String]
    var deduplicationKey: String?

    init(
        kind: AgentNotificationKind,
        title: String? = nil,
        subtitle: String? = nil,
        body: String,
        taskID: UUID? = nil,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        self.kind = kind
        self.title = title ?? kind.defaultTitle
        self.subtitle = subtitle
        self.body = body
        self.taskID = taskID
        self.deepLink = deepLink
        self.metadata = metadata
        self.deduplicationKey = deduplicationKey
    }

    static func taskCompleted(
        taskID: UUID,
        taskTitle: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .taskCompleted,
            subtitle: taskTitle,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }

    static func approvalRequired(
        taskID: UUID,
        taskTitle: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .approvalRequired,
            subtitle: taskTitle,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }

    static func automationCompleted(
        taskID: UUID? = nil,
        automationTitle: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .automationCompleted,
            subtitle: automationTitle,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }

    static func automationFailed(
        taskID: UUID? = nil,
        automationTitle: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .automationFailed,
            subtitle: automationTitle,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }

    static func subagentBlocked(
        taskID: UUID,
        subagentName: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .subagentBlocked,
            subtitle: subagentName,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }

    static func remoteAgentWaiting(
        taskID: UUID,
        remoteName: String? = nil,
        body: String,
        deepLink: URL? = nil,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) -> Self {
        Self(
            kind: .remoteAgentWaiting,
            subtitle: remoteName,
            body: body,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata,
            deduplicationKey: deduplicationKey
        )
    }
}

struct AgentNotificationRequest: Equatable, Sendable {
    let identifier: String
    let kind: AgentNotificationKind
    let title: String
    let subtitle: String?
    let body: String
    let taskID: UUID?
    let deepLink: URL?
    let metadata: [String: String]
    let categoryIdentifier: String
    let threadIdentifier: String?
    let userInfo: [String: String]
}

struct AgentNotificationInteraction: Equatable, Sendable {
    let requestIdentifier: String
    let actionIdentifier: String
    let userInfo: [String: String]
}

struct AgentNotificationRoute: Equatable, Sendable {
    let requestIdentifier: String
    let actionIdentifier: String
    let kind: AgentNotificationKind
    let taskID: UUID?
    let deepLink: URL?
    let metadata: [String: String]

    static func taskDeepLink(for taskID: UUID) -> URL {
        // A typed in-process router can consume this today. Registering the URL
        // scheme and mapping it to selection state remains an App composition
        // concern, not a responsibility of the notification backend.
        URL(string: "lumachat://task/\(taskID.uuidString.lowercased())")!
    }
}

enum AgentNotificationDeliveryResult: Equatable, Sendable {
    case scheduled(identifier: String)
    case duplicate(originalIdentifier: String)
    case notAuthorized(AgentNotificationAuthorizationStatus)
}

struct AgentNotificationPolicy: Equatable, Sendable {
    static let standard = AgentNotificationPolicy()

    var deduplicationWindow: TimeInterval
    var maximumRecentDeliveries: Int
    var maximumTitleBytes: Int
    var maximumSubtitleBytes: Int
    var maximumBodyBytes: Int
    var maximumMetadataEntries: Int
    var maximumMetadataKeyBytes: Int
    var maximumMetadataValueBytes: Int
    var maximumMetadataTotalBytes: Int
    var maximumDeepLinkBytes: Int
    var maximumDeduplicationKeyBytes: Int
    var maximumRequestIdentifierBytes: Int
    var maximumActionIdentifierBytes: Int
    var allowedDeepLinkSchemes: Set<String>

    init(
        deduplicationWindow: TimeInterval = 30,
        maximumRecentDeliveries: Int = 256,
        maximumTitleBytes: Int = 160,
        maximumSubtitleBytes: Int = 512,
        maximumBodyBytes: Int = 8_192,
        maximumMetadataEntries: Int = 16,
        maximumMetadataKeyBytes: Int = 64,
        maximumMetadataValueBytes: Int = 512,
        maximumMetadataTotalBytes: Int = 4_096,
        maximumDeepLinkBytes: Int = 2_048,
        maximumDeduplicationKeyBytes: Int = 256,
        maximumRequestIdentifierBytes: Int = 256,
        maximumActionIdentifierBytes: Int = 256,
        allowedDeepLinkSchemes: Set<String> = ["lumachat"]
    ) {
        precondition(deduplicationWindow >= 0 && deduplicationWindow.isFinite)
        precondition(maximumRecentDeliveries > 0)
        precondition(maximumTitleBytes > 0)
        precondition(maximumSubtitleBytes > 0)
        precondition(maximumBodyBytes > 0)
        precondition(maximumMetadataEntries >= 0)
        precondition(maximumMetadataKeyBytes > 0)
        precondition(maximumMetadataValueBytes > 0)
        precondition(maximumMetadataTotalBytes > 0)
        precondition(maximumDeepLinkBytes > 0)
        precondition(maximumDeduplicationKeyBytes > 0)
        precondition(maximumRequestIdentifierBytes > 0)
        precondition(maximumActionIdentifierBytes > 0)
        precondition(!allowedDeepLinkSchemes.isEmpty)

        self.deduplicationWindow = deduplicationWindow
        self.maximumRecentDeliveries = maximumRecentDeliveries
        self.maximumTitleBytes = maximumTitleBytes
        self.maximumSubtitleBytes = maximumSubtitleBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumMetadataEntries = maximumMetadataEntries
        self.maximumMetadataKeyBytes = maximumMetadataKeyBytes
        self.maximumMetadataValueBytes = maximumMetadataValueBytes
        self.maximumMetadataTotalBytes = maximumMetadataTotalBytes
        self.maximumDeepLinkBytes = maximumDeepLinkBytes
        self.maximumDeduplicationKeyBytes = maximumDeduplicationKeyBytes
        self.maximumRequestIdentifierBytes = maximumRequestIdentifierBytes
        self.maximumActionIdentifierBytes = maximumActionIdentifierBytes
        self.allowedDeepLinkSchemes = Set(
            allowedDeepLinkSchemes.map { $0.lowercased() }
        )
    }
}

enum AgentNotificationServiceError: LocalizedError, Equatable, Sendable {
    case invalidTitle
    case titleTooLarge(Int)
    case subtitleTooLarge(Int)
    case invalidBody
    case bodyTooLarge(Int)
    case tooManyMetadataEntries(Int)
    case invalidMetadataKey(String)
    case metadataKeyTooLarge(Int)
    case invalidMetadataValue(String)
    case metadataValueTooLarge(Int)
    case metadataTooLarge(Int)
    case invalidDeepLink
    case unsupportedDeepLinkScheme(String)
    case invalidDeduplicationKey
    case deduplicationKeyTooLarge(Int)
    case invalidRequestIdentifier
    case invalidInteraction
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Notification title is empty or contains control characters."
        case .titleTooLarge(let maximum):
            "Notification title exceeds the \(maximum)-byte limit."
        case .subtitleTooLarge(let maximum):
            "Notification subtitle exceeds the \(maximum)-byte limit."
        case .invalidBody:
            "Notification body is empty or contains unsupported control characters."
        case .bodyTooLarge(let maximum):
            "Notification body exceeds the \(maximum)-byte limit."
        case .tooManyMetadataEntries(let maximum):
            "Notification metadata exceeds the \(maximum)-entry limit."
        case .invalidMetadataKey(let key):
            "Notification metadata key is invalid: \(key)"
        case .metadataKeyTooLarge(let maximum):
            "Notification metadata key exceeds the \(maximum)-byte limit."
        case .invalidMetadataValue(let key):
            "Notification metadata value is invalid for key: \(key)"
        case .metadataValueTooLarge(let maximum):
            "Notification metadata value exceeds the \(maximum)-byte limit."
        case .metadataTooLarge(let maximum):
            "Notification metadata exceeds the \(maximum)-byte total limit."
        case .invalidDeepLink:
            "Notification deep link is not a valid absolute URL."
        case .unsupportedDeepLinkScheme(let scheme):
            "Notification deep-link scheme is not allowed: \(scheme)"
        case .invalidDeduplicationKey:
            "Notification deduplication key is empty or contains control characters."
        case .deduplicationKeyTooLarge(let maximum):
            "Notification deduplication key exceeds the \(maximum)-byte limit."
        case .invalidRequestIdentifier:
            "Notification request identifier is invalid."
        case .invalidInteraction:
            "Notification interaction metadata is invalid."
        case .backendUnavailable:
            "System notifications are unavailable on this platform."
        }
    }
}

protocol AgentNotificationBackend: Sendable {
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus
    func requestAuthorization() async throws -> AgentNotificationAuthorizationStatus
    func deliver(_ request: AgentNotificationRequest) async throws
    func setInteractionHandler(
        _ handler: (@Sendable (AgentNotificationInteraction) async -> Void)?
    ) async
}

protocol AgentNotificationRouting: Sendable {
    func route(_ notification: AgentNotificationRoute) async
}

struct ClosureAgentNotificationRouter: AgentNotificationRouting, Sendable {
    typealias Handler = @Sendable (AgentNotificationRoute) async -> Void

    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func route(_ notification: AgentNotificationRoute) async {
        await handler(notification)
    }
}

struct IgnoringAgentNotificationRouter: AgentNotificationRouting, Sendable {
    func route(_: AgentNotificationRoute) async {}
}

protocol AgentNotificationServicing: Sendable {
    func authorizationStatus() async -> AgentNotificationAuthorizationStatus
    func requestAuthorization() async throws -> AgentNotificationAuthorizationStatus
    @discardableResult
    func post(_ event: AgentNotificationEvent) async throws -> AgentNotificationDeliveryResult
    func startClickRouting() async
    func stopClickRouting() async
}

struct AgentNotificationDiagnostics: Equatable, Sendable {
    let recentDeliveryCount: Int
    let maximumRecentDeliveries: Int
    let clickRoutingActive: Bool
}

actor AgentNotificationService: AgentNotificationServicing {
    typealias IdentifierGenerator = @Sendable () -> String
    typealias Clock = @Sendable () -> Date

    private struct RecentDelivery: Sendable {
        let requestIdentifier: String
        let deliveredAt: Date
    }

    private enum UserInfoKey {
        static let prefix = "com.lumachat.notification."
        static let version = prefix + "version"
        static let kind = prefix + "kind"
        static let taskID = prefix + "task_id"
        static let deepLink = prefix + "deep_link"
        static let metadataPrefix = prefix + "metadata."
    }

    private let backend: any AgentNotificationBackend
    private let router: any AgentNotificationRouting
    private let policy: AgentNotificationPolicy
    private let identifierGenerator: IdentifierGenerator
    private let clock: Clock
    private var recentDeliveries: [String: RecentDelivery] = [:]
    private var recentDeliveryOrder: [String] = []
    private var clickRoutingActive = false

    init(
        backend: any AgentNotificationBackend,
        router: any AgentNotificationRouting = IgnoringAgentNotificationRouter(),
        policy: AgentNotificationPolicy = .standard,
        identifierGenerator: @escaping IdentifierGenerator = { UUID().uuidString },
        clock: @escaping Clock = { Date() }
    ) {
        self.backend = backend
        self.router = router
        self.policy = policy
        self.identifierGenerator = identifierGenerator
        self.clock = clock
    }

    func authorizationStatus() async -> AgentNotificationAuthorizationStatus {
        await startClickRouting()
        return await backend.authorizationStatus()
    }

    /// The only service operation allowed to trigger the platform permission
    /// prompt. Reading status and posting never request authority implicitly.
    func requestAuthorization() async throws -> AgentNotificationAuthorizationStatus {
        await startClickRouting()
        return try await backend.requestAuthorization()
    }

    @discardableResult
    func post(_ event: AgentNotificationEvent) async throws -> AgentNotificationDeliveryResult {
        await startClickRouting()
        let event = try validated(event)
        let status = await backend.authorizationStatus()
        guard status.permitsDelivery else {
            return .notAuthorized(status)
        }

        let now = clock()
        pruneRecentDeliveries(at: now)
        let deduplicationKey = canonicalDeduplicationKey(for: event)
        if policy.deduplicationWindow > 0,
           let recent = recentDeliveries[deduplicationKey] {
            return .duplicate(originalIdentifier: recent.requestIdentifier)
        }

        let requestIdentifier = identifierGenerator()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSingleLine(requestIdentifier),
              requestIdentifier.utf8.count <= policy.maximumRequestIdentifierBytes else {
            throw AgentNotificationServiceError.invalidRequestIdentifier
        }

        let request = AgentNotificationRequest(
            identifier: requestIdentifier,
            kind: event.kind,
            title: event.title,
            subtitle: event.subtitle,
            body: event.body,
            taskID: event.taskID,
            deepLink: event.deepLink,
            metadata: event.metadata,
            categoryIdentifier: event.kind.categoryIdentifier,
            threadIdentifier: event.taskID?.uuidString.lowercased(),
            userInfo: encodedUserInfo(for: event)
        )
        try await backend.deliver(request)
        recordDelivery(
            key: deduplicationKey,
            identifier: requestIdentifier,
            deliveredAt: now
        )
        return .scheduled(identifier: requestIdentifier)
    }

    func startClickRouting() async {
        guard !clickRoutingActive else { return }
        clickRoutingActive = true
        await backend.setInteractionHandler { [weak self] interaction in
            await self?.handle(interaction)
        }
    }

    func stopClickRouting() async {
        guard clickRoutingActive else { return }
        clickRoutingActive = false
        await backend.setInteractionHandler(nil)
    }

    func diagnostics() -> AgentNotificationDiagnostics {
        AgentNotificationDiagnostics(
            recentDeliveryCount: recentDeliveries.count,
            maximumRecentDeliveries: policy.maximumRecentDeliveries,
            clickRoutingActive: clickRoutingActive
        )
    }

    private func handle(_ interaction: AgentNotificationInteraction) async {
        guard clickRoutingActive,
              let route = try? decodedRoute(from: interaction) else { return }
        await router.route(route)
    }

    private func validated(_ event: AgentNotificationEvent) throws -> AgentNotificationEvent {
        var value = event
        value.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSingleLine(value.title) else {
            throw AgentNotificationServiceError.invalidTitle
        }
        guard value.title.utf8.count <= policy.maximumTitleBytes else {
            throw AgentNotificationServiceError.titleTooLarge(policy.maximumTitleBytes)
        }

        if let subtitle = event.subtitle {
            let normalized = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty || isValidSingleLine(normalized) else {
                throw AgentNotificationServiceError.invalidTitle
            }
            guard normalized.utf8.count <= policy.maximumSubtitleBytes else {
                throw AgentNotificationServiceError.subtitleTooLarge(policy.maximumSubtitleBytes)
            }
            value.subtitle = normalized.isEmpty ? nil : normalized
        }

        value.body = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.body.isEmpty,
              !value.body.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentNotificationServiceError.invalidBody
        }
        guard value.body.utf8.count <= policy.maximumBodyBytes else {
            throw AgentNotificationServiceError.bodyTooLarge(policy.maximumBodyBytes)
        }

        guard value.metadata.count <= policy.maximumMetadataEntries else {
            throw AgentNotificationServiceError.tooManyMetadataEntries(
                policy.maximumMetadataEntries
            )
        }
        var metadataBytes = 0
        for (key, metadataValue) in value.metadata {
            guard isValidSingleLine(key) else {
                throw AgentNotificationServiceError.invalidMetadataKey(key)
            }
            guard key.utf8.count <= policy.maximumMetadataKeyBytes else {
                throw AgentNotificationServiceError.metadataKeyTooLarge(
                    policy.maximumMetadataKeyBytes
                )
            }
            guard !metadataValue.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw AgentNotificationServiceError.invalidMetadataValue(key)
            }
            guard metadataValue.utf8.count <= policy.maximumMetadataValueBytes else {
                throw AgentNotificationServiceError.metadataValueTooLarge(
                    policy.maximumMetadataValueBytes
                )
            }
            metadataBytes += key.utf8.count + metadataValue.utf8.count
        }
        guard metadataBytes <= policy.maximumMetadataTotalBytes else {
            throw AgentNotificationServiceError.metadataTooLarge(
                policy.maximumMetadataTotalBytes
            )
        }

        if value.deepLink == nil, let taskID = value.taskID {
            value.deepLink = AgentNotificationRoute.taskDeepLink(for: taskID)
        }
        if let deepLink = value.deepLink {
            try validate(deepLink: deepLink)
        }

        if let key = value.deduplicationKey {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidSingleLine(normalized) else {
                throw AgentNotificationServiceError.invalidDeduplicationKey
            }
            guard normalized.utf8.count <= policy.maximumDeduplicationKeyBytes else {
                throw AgentNotificationServiceError.deduplicationKeyTooLarge(
                    policy.maximumDeduplicationKeyBytes
                )
            }
            value.deduplicationKey = normalized
        }
        return value
    }

    private func validate(deepLink: URL) throws {
        let raw = deepLink.absoluteString
        guard !raw.isEmpty,
              raw.utf8.count <= policy.maximumDeepLinkBytes,
              let scheme = deepLink.scheme?.lowercased(),
              !scheme.isEmpty,
              deepLink.user == nil,
              deepLink.password == nil else {
            throw AgentNotificationServiceError.invalidDeepLink
        }
        guard policy.allowedDeepLinkSchemes.contains(scheme) else {
            throw AgentNotificationServiceError.unsupportedDeepLinkScheme(scheme)
        }
    }

    private func isValidSingleLine(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }

    private func canonicalDeduplicationKey(for event: AgentNotificationEvent) -> String {
        if let explicit = event.deduplicationKey {
            return "explicit:\(explicit)"
        }
        var components = [
            event.kind.rawValue,
            event.taskID?.uuidString.lowercased() ?? "",
            event.title,
            event.subtitle ?? "",
            event.body,
            event.deepLink?.absoluteString ?? ""
        ]
        for (key, value) in event.metadata.sorted(by: { $0.key < $1.key }) {
            components.append(key)
            components.append(value)
        }
        return "event:" + components.map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "|")
    }

    private func encodedUserInfo(for event: AgentNotificationEvent) -> [String: String] {
        var userInfo = [
            UserInfoKey.version: "1",
            UserInfoKey.kind: event.kind.rawValue
        ]
        if let taskID = event.taskID {
            userInfo[UserInfoKey.taskID] = taskID.uuidString.lowercased()
        }
        if let deepLink = event.deepLink {
            userInfo[UserInfoKey.deepLink] = deepLink.absoluteString
        }
        for (key, value) in event.metadata {
            userInfo[UserInfoKey.metadataPrefix + key] = value
        }
        return userInfo
    }

    private func decodedRoute(
        from interaction: AgentNotificationInteraction
    ) throws -> AgentNotificationRoute {
        guard isValidSingleLine(interaction.requestIdentifier),
              interaction.requestIdentifier.utf8.count <= policy.maximumRequestIdentifierBytes,
              isValidSingleLine(interaction.actionIdentifier),
              interaction.actionIdentifier.utf8.count <= policy.maximumActionIdentifierBytes,
              interaction.userInfo.count <= policy.maximumMetadataEntries + 4,
              interaction.userInfo[UserInfoKey.version] == "1",
              let kindValue = interaction.userInfo[UserInfoKey.kind],
              let kind = AgentNotificationKind(rawValue: kindValue) else {
            throw AgentNotificationServiceError.invalidInteraction
        }

        let taskID: UUID?
        if let value = interaction.userInfo[UserInfoKey.taskID] {
            guard let parsed = UUID(uuidString: value) else {
                throw AgentNotificationServiceError.invalidInteraction
            }
            taskID = parsed
        } else {
            taskID = nil
        }

        let deepLink: URL?
        if let value = interaction.userInfo[UserInfoKey.deepLink] {
            guard let parsed = URL(string: value) else {
                throw AgentNotificationServiceError.invalidInteraction
            }
            try validate(deepLink: parsed)
            deepLink = parsed
        } else {
            deepLink = nil
        }

        var metadata: [String: String] = [:]
        for (key, value) in interaction.userInfo where key.hasPrefix(UserInfoKey.metadataPrefix) {
            let metadataKey = String(key.dropFirst(UserInfoKey.metadataPrefix.count))
            metadata[metadataKey] = value
        }
        let routeEvent = AgentNotificationEvent(
            kind: kind,
            body: "routing metadata",
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata
        )
        _ = try validated(routeEvent)

        return AgentNotificationRoute(
            requestIdentifier: interaction.requestIdentifier,
            actionIdentifier: interaction.actionIdentifier,
            kind: kind,
            taskID: taskID,
            deepLink: deepLink,
            metadata: metadata
        )
    }

    private func pruneRecentDeliveries(at now: Date) {
        guard policy.deduplicationWindow > 0 else {
            recentDeliveries.removeAll(keepingCapacity: true)
            recentDeliveryOrder.removeAll(keepingCapacity: true)
            return
        }
        while let key = recentDeliveryOrder.first,
              let delivery = recentDeliveries[key],
              now.timeIntervalSince(delivery.deliveredAt) >= policy.deduplicationWindow {
            recentDeliveryOrder.removeFirst()
            recentDeliveries.removeValue(forKey: key)
        }
    }

    private func recordDelivery(
        key: String,
        identifier: String,
        deliveredAt: Date
    ) {
        guard policy.deduplicationWindow > 0 else { return }
        while recentDeliveryOrder.count >= policy.maximumRecentDeliveries,
              let oldest = recentDeliveryOrder.first {
            recentDeliveryOrder.removeFirst()
            recentDeliveries.removeValue(forKey: oldest)
        }
        recentDeliveryOrder.append(key)
        recentDeliveries[key] = RecentDelivery(
            requestIdentifier: identifier,
            deliveredAt: deliveredAt
        )
    }
}
