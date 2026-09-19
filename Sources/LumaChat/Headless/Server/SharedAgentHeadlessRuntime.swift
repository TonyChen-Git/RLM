import Foundation
import LumaChatSDK

/// Production App Server bridge. It owns one normal `AgentViewModel` and routes
/// every operation through that model's task-scoped APIs, so headless clients
/// share AgentRuntime, tools, permissions, workspaces, MCP, Skills, and durable
/// session storage with the desktop implementation.
@MainActor
final class SharedAgentHeadlessRuntime: LumaChatHeadlessRuntimeFacade, @unchecked Sendable {
    typealias BackendProbe = @Sendable (AppSettings, String?) async throws -> [String]

    private struct MessageProjection: Equatable {
        var content: String
        var reasoning: String?
    }

    private enum CachedMutationResponse {
        case task(LumaChatTaskSnapshot)
        case operation(LumaChatAcceptedOperation)
    }

    private struct CachedMutation {
        var signature: Data
        var response: CachedMutationResponse
    }

    private struct ConfiguredRoute {
        var identifier: String
        var settings: AppSettings
    }

    static let maximumRetainedMutations = 1_024

    let agentViewModel: AgentViewModel
    private let settingsStore: SettingsStore
    private let keychainStore: KeychainStore
    private let backendProbe: BackendProbe
    private let redactor = SecretRedactor()
    private let eventBroker: LumaChatHeadlessEventBroker
    /// Per-task tails serialize MainActor runtime projections before they enter
    /// the broker actor. This keeps SSE sequence order identical to runtime
    /// observation order even when several events arrive in one loop turn.
    private var eventDeliveryTails: [UUID: Task<Void, Never>] = [:]
    private var runtimeObserverIDs: [UUID: UUID] = [:]
    private var messageProjections: [UUID: [UUID: MessageProjection]] = [:]
    private var mutationCache: [UUID: CachedMutation] = [:]
    private var mutationOrder: [UUID] = []
    private var didStart = false

    init(
        agentViewModel: AgentViewModel,
        settingsStore: SettingsStore,
        keychainStore: KeychainStore = KeychainStore(),
        eventBroker: LumaChatHeadlessEventBroker = LumaChatHeadlessEventBroker(),
        backendProbe: @escaping BackendProbe = { settings, apiKey in
            try await LLMClient().fetchModels(settings: settings, apiKey: apiKey)
        }
    ) {
        self.agentViewModel = agentViewModel
        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.eventBroker = eventBroker
        self.backendProbe = backendProbe
    }

    static func live() -> SharedAgentHeadlessRuntime {
        let settingsStore = SettingsStore()
        return SharedAgentHeadlessRuntime(
            agentViewModel: AgentViewModel(classicSettingsStore: settingsStore),
            settingsStore: settingsStore
        )
    }

    func start() async throws {
        guard !didStart else { return }
        guard settingsStore.loadError == nil else {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "LumaChat configuration is unavailable."
            )
        }
        await agentViewModel.start()
        guard agentViewModel.headlessRuntimeIsReady else {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "The shared Agent host failed to start."
            )
        }
        didStart = true
    }

    func shutdown() async {
        let observedTaskIDs = Array(runtimeObserverIDs.keys)
        for (taskID, observerID) in runtimeObserverIDs {
            agentViewModel.removeHeadlessEventObserver(
                sessionID: taskID,
                observerID: observerID
            )
        }
        runtimeObserverIDs.removeAll()
        for tail in eventDeliveryTails.values {
            await tail.value
        }
        for taskID in observedTaskIDs {
            await eventBroker.finish(taskID: taskID)
        }
        eventDeliveryTails.removeAll()
        await agentViewModel.shutdown()
        didStart = false
    }

    func listTasks() async throws -> [LumaChatTaskSnapshot] {
        try requireStarted()
        return agentViewModel.headlessSessions().map(snapshot)
    }

    /// Resolves CLI omissions to the configured default while preserving every
    /// explicitly supplied backend/model exactly. A shorthand that would need
    /// canonicalization is rejected instead of silently selecting another
    /// profile-qualified route.
    func resolveCLIBackendSelection(
        _ selection: LumaCLIBackendSelection
    ) async throws -> LumaCLIBackendSelection {
        try requireStarted()
        let routes = try configuredRoutes(modelOverride: selection.modelID)
        let requestedBackend = selection.backendID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedRoute: ConfiguredRoute
        if let requestedBackend, !requestedBackend.isEmpty {
            let normalized = requestedBackend.lowercased()
            let exact = routes.filter { route in
                let profileID = route.settings.activeProfileID?.uuidString.lowercased()
                return route.identifier.lowercased() == normalized
                    || profileID == normalized
                    || profileID.map { "profile:\($0)" == normalized } == true
            }
            guard exact.count == 1, let match = exact.first else {
                throw LumaCLIError.backendUnavailable(
                    "Selected backend '\(requestedBackend)' is unavailable or ambiguous; fallback is disabled."
                )
            }
            guard match.identifier == requestedBackend else {
                throw LumaCLIError.backendUnavailable(
                    "Use the canonical backend ID '\(match.identifier)'; fallback is disabled."
                )
            }
            selectedRoute = match
        } else if let activeID = settingsStore.settings.activeProfileID,
                  let active = routes.first(where: { $0.settings.activeProfileID == activeID }) {
            selectedRoute = active
        } else if let direct = routes.last(where: { $0.settings.activeProfileID == nil }) {
            selectedRoute = direct
        } else {
            throw LumaCLIError.configuration("No default backend is configured.")
        }

        let model = selection.modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? selectedRoute.settings.selectedModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw LumaCLIError.configuration("No default model is configured for this backend.")
        }
        let resolved = try resolveConfiguredRoute(
            backendID: selectedRoute.identifier,
            modelID: model
        )
        do {
            try await requireAvailable(resolved.settings, modelID: model)
        } catch {
            throw LumaCLIError.backendUnavailable(
                "Selected backend/model is unavailable; fallback is disabled."
            )
        }
        return LumaCLIBackendSelection(
            backendID: resolved.identifier,
            modelID: model
        )
    }

    func runCLIChat(
        request: LumaCLIChatRequest,
        eventHandler: @escaping LumaCLIEventHandler
    ) async throws -> LumaCLIHostResult {
        try requireStarted()
        let configured = try resolveConfiguredRoute(
            backendID: request.backendID,
            modelID: request.modelID
        )
        do {
            try await requireAvailable(configured.settings, modelID: request.modelID)
        } catch {
            throw LumaCLIError.backendUnavailable(
                "Selected backend/model is unavailable; fallback is disabled."
            )
        }
        let key: String
        do {
            key = try apiKey(for: configured.settings)
        } catch {
            throw LumaCLIError.backendUnavailable(
                "Selected backend credential is unavailable."
            )
        }
        let parameters = ModelParameterRecommendationEngine.effectiveProfile(
            for: ModelParameterRoute(
                settings: configured.settings,
                useCase: .chat,
                modelID: request.modelID
            ),
            profiles: configured.settings.modelParameterProfiles
        )
        let prompt = request.prompt
        let route = configured.settings
        let timeout = request.timeoutSeconds
        let client = LLMClient()

        return try await withThrowingTaskGroup(of: LumaCLIHostResult.self) { group in
            group.addTask {
                var content = ""
                var reasoning = ""
                var contentBytes = 0
                var reasoningBytes = 0
                var contentTruncated = false
                var reasoningTruncated = false
                let maximumContentBytes = 1_048_576
                let maximumReasoningBytes = 262_144
                let stream = client.stream(
                    messages: [ChatMessage(role: .user, content: prompt)],
                    settings: route,
                    parameters: parameters,
                    apiKey: key.isEmpty ? nil : key,
                    attachmentLoader: { _ in nil }
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    switch delta {
                    case .content(let value):
                        let remaining = max(0, maximumContentBytes - contentBytes)
                        let retained = Self.boundedUTF8(value, maximumBytes: remaining)
                        content += retained
                        contentBytes += retained.utf8.count
                        contentTruncated = contentTruncated || retained.utf8.count < value.utf8.count
                        await eventHandler(LumaCLIEvent(
                            kind: .content,
                            message: Self.boundedUTF8(value, maximumBytes: 131_072)
                        ))
                    case .reasoning(let value):
                        let remaining = max(0, maximumReasoningBytes - reasoningBytes)
                        let retained = Self.boundedUTF8(value, maximumBytes: remaining)
                        reasoning += retained
                        reasoningBytes += retained.utf8.count
                        reasoningTruncated = reasoningTruncated
                            || retained.utf8.count < value.utf8.count
                        await eventHandler(LumaCLIEvent(
                            kind: .reasoning,
                            message: Self.boundedUTF8(value, maximumBytes: 65_536)
                        ))
                    }
                }
                var payload: [String: JSONValue] = [
                    "content": .string(content),
                    "contentTruncated": .bool(contentTruncated)
                ]
                if !reasoning.isEmpty {
                    payload["reasoning"] = .string(reasoning)
                    payload["reasoningTruncated"] = .bool(reasoningTruncated)
                }
                return LumaCLIHostResult(
                    summary: content.isEmpty ? "Chat completed without text output." : "",
                    backendID: configured.identifier,
                    modelID: request.modelID,
                    payload: .object(payload)
                )
            }
            if let timeout {
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw LumaCLIError.timedOut("Chat timed out after \(timeout) seconds.")
                }
            }
            guard let result = try await group.next() else {
                throw LumaCLIError.executionFailed("Chat ended without a result.")
            }
            group.cancelAll()
            return result
        }
    }

    func cliEventCursor(taskID: UUID) async throws -> UInt64 {
        try requireStarted()
        guard let session = agentViewModel.headlessSession(id: taskID) else {
            throw LumaCLIError.notFound("Task not found.")
        }
        installRuntimeObserverIfNeeded(taskID: taskID, initialSession: session)
        await eventDeliveryTails[taskID]?.value
        return await eventBroker.latestSequence(taskID: taskID)
    }

    func createTask(
        _ request: LumaChatTaskCreateRequest
    ) async throws -> LumaChatTaskSnapshot {
        try requireStarted()
        let requestID = request.requestID ?? UUID()
        let signature = try mutationSignature(action: "create", taskID: nil, value: request)
        if let cached = try cachedMutation(id: requestID, matching: signature) {
            guard case .task(let snapshot) = cached else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The request ID was already used for another operation."
                )
            }
            return snapshot
        }

        guard request.mode != .chat else {
            throw LumaChatHeadlessRuntimeFailure(
                status: 400,
                code: .invalidRequest,
                message: "Task creation supports plan or agent mode."
            )
        }
        let mode: AppMode = request.mode == .plan ? .plan : .agent
        let route = try resolveConfiguredRoute(
            backendID: request.backendID,
            modelID: request.modelID
        )
        try await requireAvailable(route.settings, modelID: request.modelID)

        do {
            let session = try await agentViewModel.createHeadlessSession(
                mode: mode,
                title: request.title,
                workspacePath: request.workspacePath,
                route: route.settings,
                modelID: request.modelID
            )
            let result = snapshot(session)
            installRuntimeObserverIfNeeded(taskID: session.id, initialSession: session)
            recordMutation(
                id: requestID,
                signature: signature,
                response: .task(result)
            )
            return result
        } catch {
            throw mapAccessFailure(error, operation: "create")
        }
    }

    func task(id: UUID) async throws -> LumaChatTaskSnapshot {
        try requireStarted()
        guard let session = agentViewModel.headlessSession(id: id) else {
            throw LumaChatHeadlessRuntimeFailure.notFound()
        }
        return snapshot(session)
    }

    func sendMessage(
        taskID: UUID,
        request: LumaChatMessageRequest
    ) async throws -> LumaChatAcceptedOperation {
        try requireStarted()
        let requestID = request.requestID ?? UUID()
        let signature = try mutationSignature(
            action: "message",
            taskID: taskID,
            value: request
        )
        if let cached = try cachedMutation(id: requestID, matching: signature) {
            guard case .operation(let operation) = cached else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The request ID was already used for another operation."
                )
            }
            return operation
        }
        guard let session = agentViewModel.headlessSession(id: taskID) else {
            throw LumaChatHeadlessRuntimeFailure.notFound()
        }
        let route = try route(for: session)
        try await requireAvailable(route, modelID: session.model)
        installRuntimeObserverIfNeeded(taskID: taskID, initialSession: session)
        do {
            try agentViewModel.sendHeadlessMessage(
                sessionID: taskID,
                content: request.content,
                route: route,
                apiKey: apiKey(for: route)
            )
            let operation = LumaChatAcceptedOperation(
                requestID: requestID,
                taskID: taskID,
                status: .running
            )
            publish(
                taskID: taskID,
                kind: .stateChanged,
                payload: .object(["status": .string(LumaChatTaskState.running.rawValue)]),
                reopensStream: true
            )
            recordMutation(
                id: requestID,
                signature: signature,
                response: .operation(operation)
            )
            return operation
        } catch {
            throw mapAccessFailure(error, operation: "message")
        }
    }

    func events(
        taskID: UUID,
        afterSequence: UInt64?
    ) async throws -> AsyncThrowingStream<LumaChatTaskEvent, Error> {
        try requireStarted()
        guard let session = agentViewModel.headlessSession(id: taskID) else {
            throw LumaChatHeadlessRuntimeFailure.notFound()
        }
        installRuntimeObserverIfNeeded(taskID: taskID, initialSession: session)
        await eventDeliveryTails[taskID]?.value
        return try await eventBroker.stream(
            taskID: taskID,
            afterSequence: afterSequence
        )
    }

    func approve(
        taskID: UUID,
        request: LumaChatApprovalDecisionRequest
    ) async throws -> LumaChatAcceptedOperation {
        try requireStarted()
        let requestID = request.requestID ?? UUID()
        let signature = try mutationSignature(
            action: "approve",
            taskID: taskID,
            value: request
        )
        if let cached = try cachedMutation(id: requestID, matching: signature) {
            guard case .operation(let operation) = cached else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The request ID was already used for another operation."
                )
            }
            return operation
        }
        let decision: AgentApprovalDecision
        switch request.decision {
        case .allowOnce: decision = .allowOnce
        case .allowForTask: decision = .allowForSession
        case .deny: decision = .deny
        }
        do {
            try agentViewModel.resolveHeadlessApproval(
                decision,
                sessionID: taskID,
                requestID: request.approvalID
            )
            let operation = LumaChatAcceptedOperation(
                requestID: requestID,
                taskID: taskID,
                status: .running
            )
            recordMutation(
                id: requestID,
                signature: signature,
                response: .operation(operation)
            )
            return operation
        } catch {
            throw mapAccessFailure(error, operation: "approve")
        }
    }

    func pause(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation {
        try await control(
            taskID: taskID,
            requestID: request.requestID,
            action: "pause",
            requestedState: .paused,
            value: request
        ) {
            try self.agentViewModel.pauseHeadlessSession(id: taskID)
        }
    }

    func resume(
        taskID: UUID,
        request: LumaChatResumeRequest
    ) async throws -> LumaChatAcceptedOperation {
        try requireStarted()
        let requestID = request.requestID ?? UUID()
        let signature = try mutationSignature(
            action: "resume",
            taskID: taskID,
            value: request
        )
        if let cached = try cachedMutation(id: requestID, matching: signature) {
            guard case .operation(let operation) = cached else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The request ID was already used for another operation."
                )
            }
            return operation
        }
        guard let session = agentViewModel.headlessSession(id: taskID) else {
            throw LumaChatHeadlessRuntimeFailure.notFound()
        }
        let route = try route(for: session)
        try await requireAvailable(route, modelID: session.model)
        installRuntimeObserverIfNeeded(taskID: taskID, initialSession: session)
        do {
            try agentViewModel.resumeHeadlessSession(
                sessionID: taskID,
                content: request.content,
                route: route,
                apiKey: apiKey(for: route)
            )
            let operation = LumaChatAcceptedOperation(
                requestID: requestID,
                taskID: taskID,
                status: .running
            )
            publish(
                taskID: taskID,
                kind: .stateChanged,
                payload: .object(["status": .string(LumaChatTaskState.running.rawValue)]),
                reopensStream: true
            )
            recordMutation(
                id: requestID,
                signature: signature,
                response: .operation(operation)
            )
            return operation
        } catch {
            throw mapAccessFailure(error, operation: "resume")
        }
    }

    func stop(
        taskID: UUID,
        request: LumaChatControlRequest
    ) async throws -> LumaChatAcceptedOperation {
        try await control(
            taskID: taskID,
            requestID: request.requestID,
            action: "stop",
            requestedState: .cancelled,
            value: request
        ) {
            try self.agentViewModel.stopHeadlessSession(id: taskID)
        }
    }

    func diff(taskID: UUID) async throws -> LumaChatTaskDiff {
        try requireStarted()
        guard agentViewModel.headlessSession(id: taskID) != nil else {
            throw LumaChatHeadlessRuntimeFailure.notFound()
        }
        do {
            let diff = try await agentViewModel.headlessDiff(sessionID: taskID)
            return LumaChatTaskDiff(
                taskID: taskID,
                diff: diff.text,
                baseFingerprint: diff.baseFingerprint,
                changedPaths: diff.changedPaths,
                truncated: diff.truncated,
                generatedAt: diff.generatedAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LumaChatHeadlessRuntimeFailure.conflict(
                "Diff is unavailable for this task in its current state."
            )
        }
    }

    private func control<Value: Encodable>(
        taskID: UUID,
        requestID optionalRequestID: UUID?,
        action: String,
        requestedState: LumaChatTaskState,
        value: Value,
        operation: () throws -> Bool
    ) async throws -> LumaChatAcceptedOperation {
        try requireStarted()
        let requestID = optionalRequestID ?? UUID()
        let signature = try mutationSignature(
            action: action,
            taskID: taskID,
            value: value
        )
        if let cached = try cachedMutation(id: requestID, matching: signature) {
            guard case .operation(let result) = cached else {
                throw LumaChatHeadlessRuntimeFailure.conflict(
                    "The request ID was already used for another operation."
                )
            }
            return result
        }
        do {
            _ = try operation()
            let result = LumaChatAcceptedOperation(
                requestID: requestID,
                taskID: taskID,
                status: requestedState
            )
            publish(
                taskID: taskID,
                kind: .stateChanged,
                payload: .object(["status": .string(requestedState.rawValue)])
            )
            recordMutation(
                id: requestID,
                signature: signature,
                response: .operation(result)
            )
            return result
        } catch {
            throw mapAccessFailure(error, operation: action)
        }
    }

    private func requireStarted() throws {
        guard didStart else {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "The shared Agent host is not running."
            )
        }
    }

    private func resolveConfiguredRoute(
        backendID rawBackendID: String,
        modelID rawModelID: String
    ) throws -> ConfiguredRoute {
        let backendID = rawBackendID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !backendID.isEmpty, !modelID.isEmpty else {
            throw LumaChatHeadlessRuntimeFailure(
                status: 400,
                code: .invalidRequest,
                message: "backendID and modelID are required."
            )
        }
        guard rawBackendID == backendID, rawModelID == modelID else {
            throw LumaChatHeadlessRuntimeFailure(
                status: 400,
                code: .invalidRequest,
                message: "backendID and modelID must use their exact canonical values."
            )
        }

        let routes = try configuredRoutes(modelOverride: modelID)

        let exact = routes.filter { $0.identifier == backendID }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            throw LumaChatHeadlessRuntimeFailure.conflict("backendID is ambiguous.")
        }
        throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
            "Selected backend ID is not configured; fallback and alias resolution are disabled."
        )
    }

    private func configuredRoutes(modelOverride: String?) throws -> [ConfiguredRoute] {
        do {
            try settingsStore.load()
        } catch {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "LumaChat configuration is unavailable."
            )
        }
        var routes: [ConfiguredRoute] = settingsStore.settings.connectionProfiles.map {
            profile in
            var route = settingsStore.settings
            route.provider = profile.provider
            route.backend = profile.resolvedBackend
            route.endpoint = profile.endpoint
            route.selectedModel = modelOverride ?? profile.selectedModel
            route.activeProfileID = profile.id
            return ConfiguredRoute(
                identifier: Self.backendIdentifier(
                    backend: profile.resolvedBackend,
                    profileID: profile.id
                ),
                settings: route
            )
        }
        if settingsStore.settings.activeProfileID == nil
            || !settingsStore.settings.connectionProfiles.contains(where: {
                $0.id == settingsStore.settings.activeProfileID
            }) {
            var route = settingsStore.settings
            if let modelOverride { route.selectedModel = modelOverride }
            route.activeProfileID = nil
            routes.append(ConfiguredRoute(
                identifier: Self.backendIdentifier(
                    backend: route.resolvedBackend,
                    profileID: nil
                ),
                settings: route
            ))
        }
        return routes
    }

    private func route(for session: AgentSession) throws -> AppSettings {
        do {
            try settingsStore.load()
        } catch {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "LumaChat configuration is unavailable."
            )
        }
        guard let connection = session.connection,
              !session.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "Task does not have a complete immutable backend route."
            )
        }
        return connection.providerSettings(
            model: session.model,
            modelParameterProfiles: settingsStore.settings.modelParameterProfiles
        )
    }

    private func requireAvailable(_ route: AppSettings, modelID: String) async throws {
        let key: String
        do {
            key = try keychainStore.loadAPIKey(for: route) ?? ""
        } catch {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable()
        }
        if route.provider.requiresAPIKey && key.isEmpty {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "Selected backend credential is unavailable."
            )
        }
        var boundedRoute = route
        boundedRoute.requestTimeout = min(max(route.requestTimeout, 1), 30)
        let models: [String]
        do {
            models = try await backendProbe(boundedRoute, key.isEmpty ? nil : key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable()
        }
        guard models.contains(modelID) else {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "Selected model is unavailable on the configured backend."
            )
        }
    }

    private func apiKey(for route: AppSettings) throws -> String {
        do {
            return try keychainStore.loadAPIKey(for: route) ?? ""
        } catch {
            throw LumaChatHeadlessRuntimeFailure.backendUnavailable(
                "Selected backend credential is unavailable."
            )
        }
    }

    private func snapshot(_ session: AgentSession) -> LumaChatTaskSnapshot {
        let pending = agentViewModel.pendingApprovalsBySession[session.id].map(approval)
        let status = Self.taskState(session.state)
        let terminalResult: LumaChatTaskResult?
        if Self.isTerminal(status),
           let message = session.messages.last(where: { $0.role == .assistant }) {
            terminalResult = LumaChatTaskResult(
                content: Self.boundedUTF8(message.content, maximumBytes: 262_144),
                reasoningSummary: message.reasoningSummary.map {
                    Self.boundedUTF8($0, maximumBytes: 65_536)
                }
            )
        } else {
            terminalResult = nil
        }
        return LumaChatTaskSnapshot(
            id: session.id,
            title: Self.boundedUTF8(session.title, maximumBytes: 512),
            mode: Self.taskMode(session.mode),
            status: status,
            backendID: Self.sessionBackendIdentifier(session),
            modelID: session.model,
            workspacePath: session.workspace?.rootPath ?? "",
            executionKind: Self.executionKind(session.resolvedExecutionLocation.kind),
            pendingApproval: pending,
            result: terminalResult,
            lastError: session.lastError.map {
                Self.boundedUTF8(redactor.redact($0), maximumBytes: 8_192)
            },
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
    }

    private func approval(_ request: AgentApprovalRequest) -> LumaChatApproval {
        LumaChatApproval(
            id: request.id,
            toolName: Self.boundedUTF8(request.toolName, maximumBytes: 512),
            displayName: Self.boundedUTF8(request.displayName, maximumBytes: 512),
            permissionLevel: request.permissionLevel.rawValue,
            reason: request.reason.map { Self.boundedUTF8($0, maximumBytes: 8_192) },
            command: request.command.map { Self.boundedUTF8($0, maximumBytes: 65_536) },
            workingDirectory: request.workingDirectory.map {
                Self.boundedUTF8($0, maximumBytes: 4_096)
            },
            riskReasons: request.riskReasons.prefix(64).map {
                Self.boundedUTF8($0, maximumBytes: 2_048)
            },
            diffPreview: request.diffPreview.map {
                Self.boundedUTF8($0, maximumBytes: 131_072)
            }
        )
    }

    private func installRuntimeObserverIfNeeded(
        taskID: UUID,
        initialSession: AgentSession
    ) {
        guard runtimeObserverIDs[taskID] == nil else { return }
        seedMessageProjection(initialSession)
        publish(
            taskID: taskID,
            kind: .snapshot,
            payload: snapshotPayload(snapshot(initialSession)),
            terminal: Self.isTerminal(Self.taskState(initialSession.state))
        )
        do {
            runtimeObserverIDs[taskID] = try agentViewModel.addHeadlessEventObserver(
                sessionID: taskID
            ) { [weak self] event in
                self?.consume(event, taskID: taskID)
            }
        } catch {
            Task {
                await eventBroker.finish(
                    taskID: taskID,
                    failure: .invalidState("Task event observer is unavailable.")
                )
            }
        }
    }

    private func consume(_ event: AgentEvent, taskID: UUID) {
        switch event {
        case .sessionUpdated(let session), .finished(let session):
            publishMessageDeltas(session)
            let value = snapshot(session)
            publish(
                taskID: taskID,
                kind: .snapshot,
                payload: snapshotPayload(value),
                terminal: Self.isTerminal(value.status)
            )
        case .toolProgress(_, let stepID, let progress):
            publish(
                taskID: taskID,
                kind: .step,
                payload: .object([
                    "stepID": .string(stepID.uuidString.lowercased()),
                    "stdout": .string(Self.boundedUTF8(progress.stdout, maximumBytes: 65_536)),
                    "stderr": .string(Self.boundedUTF8(progress.stderr, maximumBytes: 65_536)),
                    "stdoutTotalBytes": .number(Double(progress.stdoutTotalBytes)),
                    "stderrTotalBytes": .number(Double(progress.stderrTotalBytes)),
                    "truncated": .bool(progress.truncated)
                ])
            )
        case .approvalRequired(let request):
            publish(
                taskID: taskID,
                kind: .approvalRequired,
                payload: approvalPayload(approval(request))
            )
        case .modelStarted:
            publish(
                taskID: taskID,
                kind: .stateChanged,
                payload: .object(["phase": .string("model_started")])
            )
        case .modelFinished(let usage, let latency):
            var payload: [String: LumaChatJSONValue] = [
                "phase": .string("model_finished"),
                "latencySeconds": .number(latency)
            ]
            if let usage {
                if let value = usage.inputTokens { payload["inputTokens"] = .number(Double(value)) }
                if let value = usage.outputTokens { payload["outputTokens"] = .number(Double(value)) }
                if let value = usage.totalTokens { payload["totalTokens"] = .number(Double(value)) }
            }
            publish(taskID: taskID, kind: .step, payload: .object(payload))
        case .failed(let message):
            publish(
                taskID: taskID,
                kind: .error,
                payload: .object([
                    "message": .string(Self.boundedUTF8(
                        redactor.redact(message),
                        maximumBytes: 8_192
                    ))
                ])
            )
        }
    }

    private func seedMessageProjection(_ session: AgentSession) {
        messageProjections[session.id] = Dictionary(uniqueKeysWithValues:
            session.messages.filter { $0.role == .assistant }.map {
                ($0.id, MessageProjection(content: $0.content, reasoning: $0.reasoningSummary))
            }
        )
    }

    private func publishMessageDeltas(_ session: AgentSession) {
        var projections = messageProjections[session.id] ?? [:]
        for message in session.messages where message.role == .assistant {
            let previous = projections[message.id] ?? MessageProjection(content: "", reasoning: nil)
            if message.content.hasPrefix(previous.content), message.content.count > previous.content.count {
                let delta = String(message.content.dropFirst(previous.content.count))
                publish(
                    taskID: session.id,
                    kind: .messageDelta,
                    payload: .object([
                        "messageID": .string(message.id.uuidString.lowercased()),
                        "delta": .string(Self.boundedUTF8(delta, maximumBytes: 131_072))
                    ])
                )
            }
            let oldReasoning = previous.reasoning ?? ""
            let newReasoning = message.reasoningSummary ?? ""
            if newReasoning.hasPrefix(oldReasoning), newReasoning.count > oldReasoning.count {
                let delta = String(newReasoning.dropFirst(oldReasoning.count))
                publish(
                    taskID: session.id,
                    kind: .reasoningDelta,
                    payload: .object([
                        "messageID": .string(message.id.uuidString.lowercased()),
                        "delta": .string(Self.boundedUTF8(delta, maximumBytes: 65_536))
                    ])
                )
            }
            projections[message.id] = MessageProjection(
                content: message.content,
                reasoning: message.reasoningSummary
            )
        }
        messageProjections[session.id] = projections
    }

    private func publish(
        taskID: UUID,
        kind: LumaChatTaskEventKind,
        payload: LumaChatJSONValue,
        terminal: Bool = false,
        reopensStream: Bool = false
    ) {
        let previous = eventDeliveryTails[taskID]
        let broker = eventBroker
        let delivery = Task {
            await previous?.value
            do {
                _ = try await broker.publish(
                    taskID: taskID,
                    kind: kind,
                    payload: payload,
                    reopenFinishedStream: reopensStream
                )
                if terminal { await broker.finish(taskID: taskID) }
            } catch {
                await broker.finish(
                    taskID: taskID,
                    failure: .eventCursorExpired(
                        "Task event projection exceeded its bounded channel."
                    )
                )
            }
        }
        eventDeliveryTails[taskID] = delivery
    }

    private func snapshotPayload(_ value: LumaChatTaskSnapshot) -> LumaChatJSONValue {
        var object: [String: LumaChatJSONValue] = [
            "id": .string(value.id.uuidString.lowercased()),
            "title": .string(value.title),
            "mode": .string(value.mode.rawValue),
            "status": .string(value.status.rawValue),
            "backendID": .string(value.backendID),
            "modelID": .string(value.modelID),
            "workspacePath": .string(value.workspacePath),
            "executionKind": .string(value.executionKind.rawValue),
            "updatedAt": .string(Self.iso8601(value.updatedAt))
        ]
        if let pendingApproval = value.pendingApproval {
            object["pendingApproval"] = approvalPayload(pendingApproval)
        }
        if let result = value.result {
            var resultObject: [String: LumaChatJSONValue] = ["content": .string(result.content)]
            if let reasoning = result.reasoningSummary {
                resultObject["reasoningSummary"] = .string(reasoning)
            }
            object["result"] = .object(resultObject)
        }
        if let lastError = value.lastError { object["lastError"] = .string(lastError) }
        return .object(object)
    }

    private func approvalPayload(_ value: LumaChatApproval) -> LumaChatJSONValue {
        var object: [String: LumaChatJSONValue] = [
            "id": .string(value.id.uuidString.lowercased()),
            "toolName": .string(value.toolName),
            "displayName": .string(value.displayName),
            "permissionLevel": .string(value.permissionLevel),
            "riskReasons": .array(value.riskReasons.map(LumaChatJSONValue.string))
        ]
        if let reason = value.reason { object["reason"] = .string(reason) }
        if let command = value.command { object["command"] = .string(command) }
        if let directory = value.workingDirectory {
            object["workingDirectory"] = .string(directory)
        }
        if let preview = value.diffPreview { object["diffPreview"] = .string(preview) }
        return .object(object)
    }

    private func mutationSignature<Value: Encodable>(
        action: String,
        taskID: UUID?,
        value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var signature = Data(action.utf8)
        signature.append(0)
        signature.append(Data((taskID?.uuidString.lowercased() ?? "-").utf8))
        signature.append(0)
        do {
            signature.append(try encoder.encode(value))
        } catch {
            throw LumaChatHeadlessRuntimeFailure(
                status: 400,
                code: .invalidRequest,
                message: "Request cannot be encoded."
            )
        }
        return signature
    }

    private func cachedMutation(
        id: UUID,
        matching signature: Data
    ) throws -> CachedMutationResponse? {
        guard let cached = mutationCache[id] else { return nil }
        guard cached.signature == signature else {
            throw LumaChatHeadlessRuntimeFailure.conflict(
                "The request ID was reused with a different payload."
            )
        }
        return cached.response
    }

    private func recordMutation(
        id: UUID,
        signature: Data,
        response: CachedMutationResponse
    ) {
        if mutationCache[id] == nil { mutationOrder.append(id) }
        mutationCache[id] = CachedMutation(signature: signature, response: response)
        if mutationOrder.count > Self.maximumRetainedMutations {
            let expirationCount = mutationOrder.count - Self.maximumRetainedMutations
            let expired = Array(mutationOrder.prefix(expirationCount))
            mutationOrder.removeFirst(expirationCount)
            expired.forEach { mutationCache.removeValue(forKey: $0) }
        }
    }

    private func mapAccessFailure(_ error: Error, operation: String) -> Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? LumaChatHeadlessRuntimeFailure { return failure }
        if let failure = error as? AgentHeadlessAccessError {
            switch failure {
            case .taskNotFound:
                return LumaChatHeadlessRuntimeFailure.notFound()
            case .approvalNotFound:
                return LumaChatHeadlessRuntimeFailure.approvalNotFound()
            case .notStarted:
                return LumaChatHeadlessRuntimeFailure.backendUnavailable(
                    "The shared Agent host is unavailable."
                )
            case .invalidRequest:
                return LumaChatHeadlessRuntimeFailure(
                    status: 400,
                    code: .invalidRequest,
                    message: "Invalid \(operation) request."
                )
            case .invalidState:
                return LumaChatHeadlessRuntimeFailure.invalidState(
                    "Task cannot perform \(operation) in its current state."
                )
            }
        }
        return LumaChatHeadlessRuntimeFailure.invalidState(
            "Task cannot perform \(operation) in its current state."
        )
    }

    private static func taskMode(_ mode: AppMode) -> LumaChatTaskMode {
        switch mode {
        case .chat: .chat
        case .plan: .plan
        case .agent: .agent
        }
    }

    private static func taskState(_ state: AgentRunState) -> LumaChatTaskState {
        switch state {
        case .idle: .idle
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .paused: .paused
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        case .stepLimit: .stepLimit
        }
    }

    private static func executionKind(
        _ kind: AgentExecutionLocationKind
    ) -> LumaChatExecutionKind {
        switch kind {
        case .local: .local
        case .worktree: .worktree
        case .ssh: .ssh
        case .futureCloud: .futureCloud
        }
    }

    private static func isTerminal(_ state: LumaChatTaskState) -> Bool {
        switch state {
        case .paused, .completed, .cancelled, .failed, .stepLimit:
            true
        case .idle, .running, .awaitingApproval:
            false
        }
    }

    private static func sessionBackendIdentifier(_ session: AgentSession) -> String {
        let backend: ModelBackendKind
        if let connection = session.connection {
            backend = connection.resolvedBackend
        } else {
            switch session.provider {
            case .ollama: backend = .ollama
            case .anthropic: backend = .anthropic
            case .openAICompatible: backend = .openAICompatible
            }
        }
        return backendIdentifier(backend: backend, profileID: session.profileID)
    }

    private static func backendIdentifier(
        backend: ModelBackendKind,
        profileID: UUID?
    ) -> String {
        guard let profileID else { return backendSlug(backend) }
        return "\(backendSlug(backend))/\(profileID.uuidString.lowercased())"
    }

    private static func backendSlug(_ backend: ModelBackendKind) -> String {
        switch backend {
        case .ollama: "ollama"
        case .mlx: "mlx"
        case .lmStudio: "lm-studio"
        case .openAI: "openai"
        case .openAICompatible: "openai-compatible"
        case .anthropic: "anthropic"
        }
    }

    nonisolated private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else { return value }
        var length = max(0, min(maximumBytes, data.count))
        while length > 0 {
            if let result = String(data: data.prefix(length), encoding: .utf8) {
                return result
            }
            length -= 1
        }
        return ""
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
