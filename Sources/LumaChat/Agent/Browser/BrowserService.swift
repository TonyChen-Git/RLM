import CryptoKit
import Darwin
import Foundation
import ImageIO

protocol BrowserServicing: Sendable {
    func start(configuration: BrowserLaunchConfiguration) async throws -> BrowserSession
    func attach(
        existingDebugEndpoint: URL,
        repositoryRoot: URL,
        commandTimeout: TimeInterval
    ) async throws -> BrowserSession
    func listSessions() async -> [BrowserSession]
    func stop(sessionID: UUID) async throws
    func stopAll() async
    func deletePersistentProfile(repositoryRoot: URL, name: String) async throws

    func listTabs(sessionID: UUID) async throws -> [BrowserTab]
    func createTab(sessionID: UUID, url: URL) async throws -> BrowserTab
    func closeTab(sessionID: UUID, tabID: String) async throws
    func navigate(
        sessionID: UUID,
        tabID: String,
        url: URL,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult
    func goBack(
        sessionID: UUID,
        tabID: String,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult
    func goForward(
        sessionID: UUID,
        tabID: String,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult
    func reload(
        sessionID: UUID,
        tabID: String,
        ignoreCache: Bool,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult

    func domSnapshot(sessionID: UUID, tabID: String) async throws -> BrowserDOMSnapshot
    func screenshot(
        sessionID: UUID,
        tabID: String,
        fullPage: Bool
    ) async throws -> BrowserScreenshot
    func consoleEntries(
        sessionID: UUID,
        tabID: String,
        afterSequence: UInt64?,
        limit: Int,
        clear: Bool
    ) async throws -> [BrowserConsoleEntry]
    func networkEntries(
        sessionID: UUID,
        tabID: String,
        afterSequence: UInt64?,
        limit: Int,
        clear: Bool
    ) async throws -> [BrowserNetworkEntry]
    func performanceMetrics(
        sessionID: UUID,
        tabID: String
    ) async throws -> [BrowserPerformanceMetric]
    func download(
        sessionID: UUID,
        tabID: String,
        url: URL,
        timeout: TimeInterval,
        maximumBytes: Int
    ) async throws -> BrowserDownload

    func cookies(
        sessionID: UUID,
        tabID: String,
        urls: [URL]
    ) async throws -> [BrowserCookie]
    func setCookies(
        sessionID: UUID,
        tabID: String,
        cookies: [BrowserCookieInput]
    ) async throws
    func deleteCookie(
        sessionID: UUID,
        tabID: String,
        name: String,
        url: URL?,
        domain: String?,
        path: String?
    ) async throws
    func clearCookies(sessionID: UUID, tabID: String) async throws

    func evaluateJavaScript(
        sessionID: UUID,
        tabID: String,
        expression: String,
        awaitPromise: Bool,
        timeout: TimeInterval
    ) async throws -> BrowserJavaScriptResult
}

private final class BrowserManagedProcess: @unchecked Sendable {
    private let process: Process
    private let cleanupProfile: BrowserProfile

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    private init(process: Process, cleanupProfile: BrowserProfile) {
        self.process = process
        self.cleanupProfile = cleanupProfile
    }

    static func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        cleanupProfile: BrowserProfile
    ) throws -> BrowserManagedProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw BrowserError.launchFailed(error.localizedDescription)
        }
        return BrowserManagedProcess(process: process, cleanupProfile: cleanupProfile)
    }

    func stop() async {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning, ContinuousClock.now < gracefulDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning, process.processIdentifier > 0 {
            Darwin.kill(process.processIdentifier, SIGKILL)
            let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < forcedDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    deinit {
        if process.isRunning, process.processIdentifier > 0 {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        try? cleanupProfile.removeEphemeralData()
    }
}

private final class BrowserSessionRuntime {
    let session: BrowserSession
    let debugWebSocketEndpoint: URL
    let browserConnection: CDPWebSocketConnection
    let process: BrowserManagedProcess?
    let commandTimeout: TimeInterval
    let downloadDirectory: URL?
    var tabConnections: [String: CDPWebSocketConnection] = [:]

    init(
        session: BrowserSession,
        debugWebSocketEndpoint: URL,
        browserConnection: CDPWebSocketConnection,
        process: BrowserManagedProcess?,
        commandTimeout: TimeInterval,
        downloadDirectory: URL?
    ) {
        self.session = session
        self.debugWebSocketEndpoint = debugWebSocketEndpoint
        self.browserConnection = browserConnection
        self.process = process
        self.commandTimeout = commandTimeout
        self.downloadDirectory = downloadDirectory
    }
}

actor BrowserService: BrowserServicing {
    private static let browserEventMethods: Set<String> = [
        "Runtime.consoleAPICalled",
        "Runtime.exceptionThrown",
        "Log.entryAdded"
    ]
    private static let networkEventMethods: Set<String> = [
        "Network.requestWillBeSent",
        "Network.responseReceived",
        "Network.loadingFailed",
        "Network.loadingFinished"
    ]

    private var runtimes: [UUID: BrowserSessionRuntime] = [:]
    private var startingSessionIDs: Set<UUID> = []
    private var activeProfilePaths: Set<String> = []
    private var activeAttachedEndpoints: Set<String> = []
    private var lifecycleGeneration: UInt64 = 0
    private var stopAllInProgress = false

    func start(configuration: BrowserLaunchConfiguration) async throws -> BrowserSession {
        try Self.validate(configuration)
        guard !stopAllInProgress else {
            throw BrowserError.invalidConfiguration("Browser shutdown is in progress.")
        }
        guard runtimes.count + startingSessionIDs.count < BrowserBounds.maximumSessions else {
            throw BrowserError.sessionLimitReached(BrowserBounds.maximumSessions)
        }
        let startingGeneration = lifecycleGeneration

        let executableURL = try Self.resolveBrowserExecutable(configuration.executableURL)
        let profile = try BrowserProfile.create(
            repositoryRoot: configuration.repositoryRoot,
            persistence: configuration.profilePersistence
        )
        let profilePath = profile.dataDirectory.standardizedFileURL.path
        guard !activeProfilePaths.contains(profilePath) else {
            try? profile.removeEphemeralData()
            throw BrowserError.profileInUse
        }

        let sessionID = UUID()
        let downloadDirectory: URL
        do {
            downloadDirectory = try Self.createDownloadDirectory(
                runtimeRoot: profile.runtimeRoot,
                sessionID: sessionID
            )
        } catch {
            try? profile.removeEphemeralData()
            throw error
        }
        startingSessionIDs.insert(sessionID)
        activeProfilePaths.insert(profilePath)
        var managedProcess: BrowserManagedProcess?
        var browserConnection: CDPWebSocketConnection?
        var succeeded = false
        defer {
            startingSessionIDs.remove(sessionID)
            if !succeeded { activeProfilePaths.remove(profilePath) }
        }

        do {
            let temporaryDirectory = profile.dataDirectory
                .appendingPathComponent("Temp", isDirectory: true)
            let diskCacheDirectory = profile.dataDirectory
                .appendingPathComponent("Cache", isDirectory: true)
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: diskCacheDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var environment = ProcessInfo.processInfo.environment
            environment["TMPDIR"] = temporaryDirectory.path
            environment.removeValue(forKey: "CHROME_LOG_FILE")

            let arguments = Self.launchArguments(
                configuration: configuration,
                profile: profile,
                diskCacheDirectory: diskCacheDirectory
            )
            let process = try BrowserManagedProcess.launch(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: profile.repositoryRoot,
                cleanupProfile: profile
            )
            managedProcess = process

            let endpoint = try await Self.waitForDevToolsEndpoint(
                profile: profile,
                process: process,
                timeout: configuration.startupTimeout
            )
            let connection = try CDPWebSocketConnection(endpoint: endpoint)
            browserConnection = connection
            try await connection.start()
            _ = try await connection.command(
                "Browser.setDownloadBehavior",
                params: .object([
                    "behavior": .string("allowAndName"),
                    "downloadPath": .string(downloadDirectory.path),
                    "eventsEnabled": .bool(true)
                ]),
                timeout: configuration.commandTimeout
            )
            let version = try await connection.command(
                "Browser.getVersion",
                timeout: configuration.commandTimeout
            )
            let versionFields = try Self.browserVersionFields(version)
            guard process.isRunning else {
                throw BrowserError.browserExited(process.exitStatus ?? -1)
            }
            guard !stopAllInProgress, lifecycleGeneration == startingGeneration else {
                throw BrowserError.sessionClosed(sessionID)
            }

            let session = BrowserSession(
                id: sessionID,
                source: .launched(
                    profile: profile,
                    executableURL: executableURL,
                    processIdentifier: process.processIdentifier
                ),
                browserProduct: versionFields.product,
                protocolVersion: versionFields.protocolVersion,
                headless: configuration.headless,
                startedAt: Date()
            )
            runtimes[sessionID] = BrowserSessionRuntime(
                session: session,
                debugWebSocketEndpoint: endpoint,
                browserConnection: connection,
                process: process,
                commandTimeout: configuration.commandTimeout,
                downloadDirectory: downloadDirectory
            )
            succeeded = true
            return session
        } catch {
            if let browserConnection { await browserConnection.close() }
            if let managedProcess { await managedProcess.stop() }
            try? profile.removeEphemeralData()
            try? FileManager.default.removeItem(at: downloadDirectory)
            throw error
        }
    }

    func attach(
        existingDebugEndpoint: URL,
        repositoryRoot: URL,
        commandTimeout: TimeInterval = 10
    ) async throws -> BrowserSession {
        guard !stopAllInProgress else {
            throw BrowserError.invalidConfiguration("Browser shutdown is in progress.")
        }
        guard runtimes.count + startingSessionIDs.count < BrowserBounds.maximumSessions else {
            throw BrowserError.sessionLimitReached(BrowserBounds.maximumSessions)
        }
        let startingGeneration = lifecycleGeneration
        let timeout = try BrowserBounds.validatedTimeout(
            commandTimeout,
            minimum: BrowserBounds.minimumCommandTimeout,
            maximum: BrowserBounds.maximumCommandTimeout
        )
        let canonicalRepository = try Self.validatedRepositoryRoot(repositoryRoot)
        let sessionID = UUID()
        startingSessionIDs.insert(sessionID)
        defer { startingSessionIDs.remove(sessionID) }

        let endpoint = try await Self.resolveExistingDebugEndpoint(
            existingDebugEndpoint,
            timeout: timeout
        )
        let endpointKey = endpoint.absoluteString
        guard !activeAttachedEndpoints.contains(endpointKey) else {
            throw BrowserError.debugEndpointInUse
        }
        activeAttachedEndpoints.insert(endpointKey)
        var connection: CDPWebSocketConnection?
        var succeeded = false
        defer {
            if !succeeded { activeAttachedEndpoints.remove(endpointKey) }
        }

        do {
            let browserConnection = try CDPWebSocketConnection(endpoint: endpoint)
            connection = browserConnection
            try await browserConnection.start()
            let version = try await browserConnection.command(
                "Browser.getVersion",
                timeout: timeout
            )
            let versionFields = try Self.browserVersionFields(version)
            guard !stopAllInProgress, lifecycleGeneration == startingGeneration else {
                throw BrowserError.sessionClosed(sessionID)
            }
            let session = BrowserSession(
                id: sessionID,
                source: .attached(
                    debugEndpoint: endpoint,
                    repositoryRoot: canonicalRepository
                ),
                browserProduct: versionFields.product,
                protocolVersion: versionFields.protocolVersion,
                headless: nil,
                startedAt: Date()
            )
            runtimes[sessionID] = BrowserSessionRuntime(
                session: session,
                debugWebSocketEndpoint: endpoint,
                browserConnection: browserConnection,
                process: nil,
                commandTimeout: timeout,
                downloadDirectory: nil
            )
            succeeded = true
            return session
        } catch {
            if let connection { await connection.close() }
            throw error
        }
    }

    func listSessions() async -> [BrowserSession] {
        let stoppedIDs = runtimes.compactMap { id, runtime in
            if let process = runtime.process, !process.isRunning { return id }
            return nil
        }
        for id in stoppedIDs { try? await stop(sessionID: id) }
        return runtimes.values
            .map(\.session)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func stop(sessionID: UUID) async throws {
        guard let runtime = runtimes.removeValue(forKey: sessionID) else {
            throw BrowserError.sessionNotFound(sessionID)
        }
        if let profile = runtime.session.profile {
            activeProfilePaths.remove(profile.dataDirectory.standardizedFileURL.path)
        }
        if case .attached(let endpoint, _) = runtime.session.source {
            activeAttachedEndpoints.remove(endpoint.absoluteString)
        }

        let pageConnections = Array(runtime.tabConnections.values)
        runtime.tabConnections.removeAll()
        for connection in pageConnections { await connection.close() }
        await runtime.browserConnection.close()
        if let process = runtime.process { await process.stop() }
        if let profile = runtime.session.profile { try profile.removeEphemeralData() }
    }

    func stopAll() async {
        lifecycleGeneration &+= 1
        let stoppingGeneration = lifecycleGeneration
        stopAllInProgress = true
        for sessionID in Array(runtimes.keys) {
            try? await stop(sessionID: sessionID)
        }
        if lifecycleGeneration == stoppingGeneration {
            stopAllInProgress = false
        }
    }

    func deletePersistentProfile(repositoryRoot: URL, name: String) async throws {
        let candidate = try BrowserProfile.persistentDataDirectory(
            repositoryRoot: repositoryRoot,
            name: name
        ).standardizedFileURL
        guard !activeProfilePaths.contains(candidate.path) else {
            throw BrowserError.persistentProfileInUse
        }
        try BrowserProfile.removePersistentData(
            repositoryRoot: repositoryRoot,
            name: name
        )
    }

    func listTabs(sessionID: UUID) async throws -> [BrowserTab] {
        let runtime = try await activeRuntime(sessionID)
        let tabs = try await fetchTabs(runtime)
        let currentIDs = Set(tabs.map(\.id))
        let staleIDs = runtime.tabConnections.keys.filter { !currentIDs.contains($0) }
        for id in staleIDs {
            if let stale = runtime.tabConnections.removeValue(forKey: id) {
                await stale.close()
            }
        }
        return tabs
    }

    func createTab(sessionID: UUID, url: URL) async throws -> BrowserTab {
        let destination = try BrowserBounds.validatedNavigationURL(url)
        let runtime = try await activeRuntime(sessionID)
        let existing = try await fetchTabs(runtime)
        guard existing.count < BrowserBounds.maximumTabsPerSession else {
            throw BrowserError.tabLimitReached(BrowserBounds.maximumTabsPerSession)
        }
        let result = try await runtime.browserConnection.command(
            "Target.createTarget",
            params: .object([
                "url": .string(destination.absoluteString),
                "newWindow": .bool(false),
                "background": .bool(false)
            ]),
            timeout: runtime.commandTimeout
        )
        guard let rawID = result["targetId"]?.stringValue else {
            throw BrowserError.protocolViolation("Target.createTarget omitted targetId.")
        }
        let targetID = try BrowserBounds.validatedTargetIdentifier(rawID)
        for _ in 0..<20 {
            if let tab = try await fetchTabs(runtime).first(where: { $0.id == targetID }) {
                return tab
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserError.tabNotFound(targetID)
    }

    func closeTab(sessionID: UUID, tabID: String) async throws {
        let targetID = try BrowserBounds.validatedTargetIdentifier(tabID)
        let runtime = try await activeRuntime(sessionID)
        try await requireTab(targetID, in: runtime)
        let result = try await runtime.browserConnection.command(
            "Target.closeTarget",
            params: .object(["targetId": .string(targetID)]),
            timeout: runtime.commandTimeout
        )
        guard result["success"]?.boolValue == true else {
            throw BrowserError.tabNotFound(targetID)
        }
        if let connection = runtime.tabConnections.removeValue(forKey: targetID) {
            await connection.close()
        }
    }

    private func activeRuntime(_ sessionID: UUID) async throws -> BrowserSessionRuntime {
        guard let runtime = runtimes[sessionID] else {
            throw BrowserError.sessionNotFound(sessionID)
        }
        if let process = runtime.process, !process.isRunning {
            try? await stop(sessionID: sessionID)
            throw BrowserError.sessionClosed(sessionID)
        }
        return runtime
    }

    private func fetchTabs(_ runtime: BrowserSessionRuntime) async throws -> [BrowserTab] {
        let result = try await runtime.browserConnection.command(
            "Target.getTargets",
            timeout: runtime.commandTimeout
        )
        guard let infos = result["targetInfos"]?.arrayValue else {
            throw BrowserError.protocolViolation("Target.getTargets omitted targetInfos.")
        }
        var tabs: [BrowserTab] = []
        tabs.reserveCapacity(min(infos.count, BrowserBounds.maximumTabsPerSession))
        for value in infos {
            guard value["type"]?.stringValue == "page" else { continue }
            guard let rawID = value["targetId"]?.stringValue else {
                throw BrowserError.protocolViolation("A page target omitted targetId.")
            }
            let id = try BrowserBounds.validatedTargetIdentifier(rawID)
            let boundedTitle = BrowserBounds.boundedUTF8(
                value["title"]?.stringValue ?? "",
                maximumBytes: BrowserBounds.maximumTitleBytes
            )
            let boundedURL = Self.boundedSanitizedURL(
                value["url"]?.stringValue ?? ""
            )
            tabs.append(
                BrowserTab(
                    id: id,
                    title: boundedTitle.0,
                    url: boundedURL.value,
                    isAttached: value["attached"]?.boolValue ?? false,
                    titleWasTruncated: boundedTitle.1,
                    urlWasTruncated: boundedURL.truncated
                )
            )
            guard tabs.count < BrowserBounds.maximumTabsPerSession else { break }
        }
        return tabs.sorted { $0.id < $1.id }
    }

    private func requireTab(_ tabID: String, in runtime: BrowserSessionRuntime) async throws {
        guard try await fetchTabs(runtime).contains(where: { $0.id == tabID }) else {
            throw BrowserError.tabNotFound(tabID)
        }
    }

    private func pageConnection(
        sessionID: UUID,
        tabID rawTabID: String
    ) async throws -> (BrowserSessionRuntime, CDPWebSocketConnection) {
        let tabID = try BrowserBounds.validatedTargetIdentifier(rawTabID)
        let runtime = try await activeRuntime(sessionID)
        if let connection = runtime.tabConnections[tabID] {
            if await connection.isOpen() {
                return (runtime, connection)
            }
            runtime.tabConnections.removeValue(forKey: tabID)
            await connection.close()
        }
        try await requireTab(tabID, in: runtime)

        let endpoint = try Self.pageEndpoint(
            browserEndpoint: runtime.debugWebSocketEndpoint,
            targetID: tabID
        )
        let connection = try CDPWebSocketConnection(endpoint: endpoint)
        do {
            try await connection.start()
            _ = try await connection.command("Page.enable", timeout: runtime.commandTimeout)
            _ = try await connection.command("Runtime.enable", timeout: runtime.commandTimeout)
            _ = try await connection.command("Log.enable", timeout: runtime.commandTimeout)
            _ = try await connection.command("Performance.enable", timeout: runtime.commandTimeout)
            _ = try await connection.command(
                "Network.enable",
                params: .object([
                    "maxTotalBufferSize": .number(2 * 1_024 * 1_024),
                    "maxResourceBufferSize": .number(512 * 1_024),
                    "maxPostDataSize": .number(64 * 1_024)
                ]),
                timeout: runtime.commandTimeout
            )
            _ = try await connection.command(
                "Network.setBlockedURLs",
                params: .object([
                    "urls": .array([
                        "*://169.254.*/*", "*://100.100.100.200/*",
                        "*://metadata.google.internal/*", "*://metadata.azure.internal/*",
                        "*://metadata.aws.internal/*", "*://[fd00:ec2::254]/*"
                    ].map(JSONValue.string))
                ]),
                timeout: runtime.commandTimeout
            )
        } catch {
            await connection.close()
            throw error
        }

        guard runtimes[sessionID] === runtime else {
            await connection.close()
            throw BrowserError.sessionClosed(sessionID)
        }
        if let racedConnection = runtime.tabConnections[tabID] {
            await connection.close()
            return (runtime, racedConnection)
        }
        runtime.tabConnections[tabID] = connection
        return (runtime, connection)
    }
}

extension BrowserService {
    func navigate(
        sessionID: UUID,
        tabID: String,
        url: URL,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult {
        let destination = try BrowserBounds.validatedNavigationURL(url)
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumNavigationTimeout,
            maximum: BrowserBounds.maximumNavigationTimeout
        )
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let commandTimeout = min(runtime.commandTimeout, boundedTimeout)
        let result = try await connection.command(
            "Page.navigate",
            params: .object(["url": .string(destination.absoluteString)]),
            timeout: commandTimeout
        )
        if let errorText = result["errorText"]?.stringValue, !errorText.isEmpty {
            throw BrowserError.protocolViolation(
                BrowserBounds.boundedUTF8(errorText, maximumBytes: 4_096).0
            )
        }
        if result["isDownload"]?.boolValue == true {
            throw BrowserError.protocolViolation("Navigation became a download.")
        }
        return try await waitForDocumentReady(
            runtime: runtime,
            connection: connection,
            tabID: tabID,
            timeout: boundedTimeout,
            frameID: result["frameId"]?.stringValue,
            loaderID: result["loaderId"]?.stringValue,
            requireInitialDelay: false
        )
    }

    func goBack(
        sessionID: UUID,
        tabID: String,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult {
        try await navigateHistory(
            sessionID: sessionID,
            tabID: tabID,
            offset: -1,
            timeout: timeout
        )
    }

    func goForward(
        sessionID: UUID,
        tabID: String,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult {
        try await navigateHistory(
            sessionID: sessionID,
            tabID: tabID,
            offset: 1,
            timeout: timeout
        )
    }

    func reload(
        sessionID: UUID,
        tabID: String,
        ignoreCache: Bool = false,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult {
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumNavigationTimeout,
            maximum: BrowserBounds.maximumNavigationTimeout
        )
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        _ = try await connection.command(
            "Page.reload",
            params: .object(["ignoreCache": .bool(ignoreCache)]),
            timeout: min(runtime.commandTimeout, boundedTimeout)
        )
        return try await waitForDocumentReady(
            runtime: runtime,
            connection: connection,
            tabID: tabID,
            timeout: boundedTimeout,
            frameID: nil,
            loaderID: nil,
            requireInitialDelay: true
        )
    }

    private func navigateHistory(
        sessionID: UUID,
        tabID: String,
        offset: Int,
        timeout: TimeInterval
    ) async throws -> BrowserNavigationResult {
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumNavigationTimeout,
            maximum: BrowserBounds.maximumNavigationTimeout
        )
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let history = try await connection.command(
            "Page.getNavigationHistory",
            timeout: min(runtime.commandTimeout, boundedTimeout)
        )
        guard let currentIndex = history["currentIndex"]?.intValue,
              let entries = history["entries"]?.arrayValue else {
            throw BrowserError.protocolViolation("Page.getNavigationHistory returned an invalid history.")
        }
        let destinationIndex = currentIndex + offset
        guard entries.indices.contains(destinationIndex) else {
            return try await currentNavigationResult(
                connection: connection,
                tabID: tabID,
                timeout: min(runtime.commandTimeout, boundedTimeout),
                frameID: nil,
                loaderID: nil
            )
        }
        guard let entryID = entries[destinationIndex]["id"]?.intValue else {
            throw BrowserError.protocolViolation("Navigation history entry omitted its id.")
        }
        _ = try await connection.command(
            "Page.navigateToHistoryEntry",
            params: .object(["entryId": .number(Double(entryID))]),
            timeout: min(runtime.commandTimeout, boundedTimeout)
        )
        return try await waitForDocumentReady(
            runtime: runtime,
            connection: connection,
            tabID: tabID,
            timeout: boundedTimeout,
            frameID: nil,
            loaderID: nil,
            requireInitialDelay: true
        )
    }

    private func waitForDocumentReady(
        runtime: BrowserSessionRuntime,
        connection: CDPWebSocketConnection,
        tabID: String,
        timeout: TimeInterval,
        frameID: String?,
        loaderID: String?,
        requireInitialDelay: Bool
    ) async throws -> BrowserNavigationResult {
        let deadline = Date().addingTimeInterval(timeout)
        if requireInitialDelay { try? await Task.sleep(for: .milliseconds(50)) }
        var lastReadyState = "loading"

        while Date() < deadline {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= BrowserBounds.minimumCommandTimeout else { break }
            do {
                let current = try await currentNavigationResult(
                    connection: connection,
                    tabID: tabID,
                    timeout: min(runtime.commandTimeout, remaining),
                    frameID: frameID,
                    loaderID: loaderID
                )
                lastReadyState = current.readyState
                if current.readyState == "complete" { return current }
            } catch let error as BrowserError {
                switch error {
                case .protocolError, .commandTimedOut:
                    break
                default:
                    throw error
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw BrowserError.commandTimedOut("Page navigation (last state: \(lastReadyState))")
    }

    private func currentNavigationResult(
        connection: CDPWebSocketConnection,
        tabID: String,
        timeout: TimeInterval,
        frameID: String?,
        loaderID: String?
    ) async throws -> BrowserNavigationResult {
        let result = try await connection.command(
            "Runtime.evaluate",
            params: .object([
                "expression": .string(
                    "({readyState: document.readyState, url: location.href, title: document.title})"
                ),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(false),
                "userGesture": .bool(false)
            ]),
            timeout: timeout
        )
        if let exception = result["exceptionDetails"] {
            throw BrowserError.javaScriptException(Self.exceptionDescription(exception))
        }
        guard let object = result["result"]?["value"]?.objectValue,
              let readyState = object["readyState"]?.stringValue,
              let rawURL = object["url"]?.stringValue,
              let rawTitle = object["title"]?.stringValue else {
            throw BrowserError.protocolViolation("Runtime.evaluate returned invalid page metadata.")
        }
        guard let pageURL = URL(string: rawURL) else { throw BrowserError.invalidURL }
        do {
            _ = try BrowserBounds.validatedNavigationURL(pageURL)
        } catch {
            _ = try? await connection.command(
                "Page.navigate",
                params: .object(["url": .string("about:blank")]),
                timeout: timeout
            )
            throw error
        }
        let url = Self.boundedSanitizedURL(rawURL).value
        let title = BrowserBounds.boundedUTF8(
            rawTitle,
            maximumBytes: BrowserBounds.maximumTitleBytes
        ).0
        return BrowserNavigationResult(
            tabID: tabID,
            url: url,
            title: title,
            frameID: frameID,
            loaderID: loaderID,
            readyState: BrowserBounds.boundedUTF8(readyState, maximumBytes: 32).0
        )
    }

    func domSnapshot(sessionID: UUID, tabID: String) async throws -> BrowserDOMSnapshot {
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let rawDOMSnapshot = try await connection.command(
            "DOMSnapshot.captureSnapshot",
            params: .object([
                "computedStyles": .array([]),
                "includePaintOrder": .bool(false),
                "includeDOMRects": .bool(true),
                "includeBlendedBackgroundColors": .bool(false),
                "includeTextColorOpacities": .bool(false)
            ]),
            timeout: runtime.commandTimeout
        )
        let rawAccessibilityTree = try await connection.command(
            "Accessibility.getFullAXTree",
            timeout: runtime.commandTimeout
        )
        guard let rawDocuments = rawDOMSnapshot["documents"]?.arrayValue else {
            throw BrowserError.protocolViolation(
                "DOMSnapshot.captureSnapshot omitted documents."
            )
        }
        let projectionResult = try await connection.command(
            "Runtime.evaluate",
            params: .object([
                "expression": .string(Self.safeDOMProjectionExpression),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(false),
                "generatePreview": .bool(false),
                "userGesture": .bool(false)
            ]),
            timeout: runtime.commandTimeout
        )
        if let exception = projectionResult["exceptionDetails"] {
            throw BrowserError.javaScriptException(Self.exceptionDescription(exception))
        }
        guard let safeDOM = projectionResult["result"]?["value"] else {
            throw BrowserError.protocolViolation("Runtime.evaluate omitted the DOM projection.")
        }
        let nodeCount = rawDocuments.reduce(0) { total, document in
            total + (document["nodes"]?["nodeName"]?.arrayValue?.count ?? 0)
        }
        let layoutNodeCount = rawDocuments.reduce(0) { total, document in
            total + (document["layout"]?["nodeIndex"]?.arrayValue?.count ?? 0)
        }
        let snapshot = BrowserSecuritySanitizer.untrustedJSON(.object([
            "dom": safeDOM,
            "accessibility": try Self.sanitizedAccessibilityTree(rawAccessibilityTree),
            "layout_summary": .object([
                "document_count": .number(Double(rawDocuments.count)),
                "node_count": .number(Double(nodeCount)),
                "layout_node_count": .number(Double(layoutNodeCount)),
                "rects_captured": .bool(true)
            ]),
            "trust": .string("untrusted"),
            "sensitive_form_values_omitted": .bool(true)
        ]))
        let byteCount = try BrowserBounds.encodedSize(of: snapshot)
        guard byteCount <= BrowserBounds.maximumDOMSnapshotBytes else {
            throw BrowserError.domSnapshotTooLarge(BrowserBounds.maximumDOMSnapshotBytes)
        }
        let metadata = try await currentNavigationResult(
            connection: connection,
            tabID: tabID,
            timeout: runtime.commandTimeout,
            frameID: nil,
            loaderID: nil
        )
        return BrowserDOMSnapshot(
            tabID: tabID,
            url: metadata.url,
            title: metadata.title,
            snapshot: snapshot,
            encodedByteCount: byteCount
        )
    }

    func screenshot(
        sessionID: UUID,
        tabID: String,
        fullPage: Bool = false
    ) async throws -> BrowserScreenshot {
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let metrics = try await connection.command(
            "Page.getLayoutMetrics",
            timeout: runtime.commandTimeout
        )
        let dimensions = try Self.screenshotDimensions(metrics, fullPage: fullPage)
        var capture: [String: JSONValue] = [
            "format": .string("png"),
            "fromSurface": .bool(true),
            "captureBeyondViewport": .bool(fullPage),
            "optimizeForSpeed": .bool(true)
        ]
        if fullPage {
            capture["clip"] = .object([
                "x": .number(0),
                "y": .number(0),
                "width": .number(Double(dimensions.width)),
                "height": .number(Double(dimensions.height)),
                "scale": .number(1)
            ])
        }
        let result = try await connection.command(
            "Page.captureScreenshot",
            params: .object(capture),
            timeout: runtime.commandTimeout
        )
        guard let encoded = result["data"]?.stringValue,
              encoded.utf8.count <= ((BrowserBounds.maximumScreenshotBytes + 2) / 3 * 4) + 16,
              let data = Data(base64Encoded: encoded),
              data.count <= BrowserBounds.maximumScreenshotBytes else {
            throw BrowserError.screenshotTooLarge(BrowserBounds.maximumScreenshotBytes)
        }
        let actual = try Self.pngDimensions(data)
        try Self.validateScreenshotDimensions(width: actual.width, height: actual.height)
        return BrowserScreenshot(
            tabID: tabID,
            mimeType: "image/png",
            width: actual.width,
            height: actual.height,
            data: data
        )
    }

    func consoleEntries(
        sessionID: UUID,
        tabID: String,
        afterSequence: UInt64? = nil,
        limit: Int = 100,
        clear: Bool = false
    ) async throws -> [BrowserConsoleEntry] {
        let (_, connection) = try await pageConnection(sessionID: sessionID, tabID: tabID)
        let events = try await connection.recentEvents(
            methods: Self.browserEventMethods,
            afterSequence: afterSequence,
            limit: limit
        )
        let entries = events.compactMap(Self.consoleEntry)
        if clear { await connection.clearEvents(methods: Self.browserEventMethods) }
        return entries
    }

    func networkEntries(
        sessionID: UUID,
        tabID: String,
        afterSequence: UInt64? = nil,
        limit: Int = 100,
        clear: Bool = false
    ) async throws -> [BrowserNetworkEntry] {
        let (_, connection) = try await pageConnection(sessionID: sessionID, tabID: tabID)
        let events = try await connection.recentEvents(
            methods: Self.networkEventMethods,
            afterSequence: afterSequence,
            limit: limit
        )
        let entries = events.compactMap(Self.networkEntry)
        if clear { await connection.clearEvents(methods: Self.networkEventMethods) }
        return entries
    }

    func performanceMetrics(
        sessionID: UUID,
        tabID: String
    ) async throws -> [BrowserPerformanceMetric] {
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let result = try await connection.command(
            "Performance.getMetrics",
            timeout: runtime.commandTimeout
        )
        guard let rawMetrics = result["metrics"]?.arrayValue else {
            throw BrowserError.protocolViolation("Performance.getMetrics omitted metrics.")
        }
        guard rawMetrics.count <= 256 else {
            throw BrowserError.responseTooLarge(BrowserBounds.maximumJavaScriptResultBytes)
        }
        return try rawMetrics.map { metric in
            guard let rawName = metric["name"]?.stringValue,
                  !rawName.isEmpty,
                  rawName.utf8.count <= 128,
                  let value = Self.number(metric["value"]),
                  value.isFinite else {
                throw BrowserError.protocolViolation("Performance metric is invalid.")
            }
            return BrowserPerformanceMetric(name: rawName, value: value)
        }
    }

    func download(
        sessionID: UUID,
        tabID: String,
        url: URL,
        timeout: TimeInterval,
        maximumBytes: Int
    ) async throws -> BrowserDownload {
        let destination = try BrowserBounds.validatedNavigationURL(url)
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumNavigationTimeout,
            maximum: BrowserBounds.maximumNavigationTimeout
        )
        guard (1...BrowserBounds.maximumDownloadBytes).contains(maximumBytes) else {
            throw BrowserError.invalidLimit
        }
        let (runtime, pageConnection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        guard let downloadDirectory = runtime.downloadDirectory else {
            throw BrowserError.downloadUnavailableForAttachedSession
        }
        let eventMethods: Set<String> = [
            "Browser.downloadWillBegin", "Browser.downloadProgress"
        ]
        let baseline = await runtime.browserConnection.latestEventSequence()
        let navigation = try await pageConnection.command(
            "Page.navigate",
            params: .object(["url": .string(destination.absoluteString)]),
            timeout: min(runtime.commandTimeout, boundedTimeout)
        )
        guard navigation["isDownload"]?.boolValue == true else {
            throw BrowserError.navigationWasNotDownload
        }
        let expectedFrameID = navigation["frameId"]?.stringValue
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64((boundedTimeout * 1_000).rounded(.up)))
        )
        var guid: String?
        var suggestedFilename = "download"
        var sanitizedURL = BrowserSecuritySanitizer.url(destination.absoluteString).value
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let events = try await runtime.browserConnection.recentEvents(
                    methods: eventMethods,
                    afterSequence: baseline,
                    limit: BrowserBounds.maximumReturnedEntries
                )
                for event in events {
                    if event.method == "Browser.downloadWillBegin" {
                        if let expectedFrameID,
                           let frameID = event.params["frameId"]?.stringValue,
                           frameID != expectedFrameID {
                            continue
                        }
                        guard let rawGUID = event.params["guid"]?.stringValue else { continue }
                        guid = try BrowserBounds.validatedTargetIdentifier(rawGUID)
                        if let rawFilename = event.params["suggestedFilename"]?.stringValue {
                            suggestedFilename = Self.sanitizedDownloadFilename(rawFilename)
                        }
                        if let rawURL = event.params["url"]?.stringValue {
                            sanitizedURL = BrowserSecuritySanitizer.url(rawURL).value
                        }
                    } else if event.method == "Browser.downloadProgress",
                              let activeGUID = guid,
                              event.params["guid"]?.stringValue == activeGUID {
                        let total = Self.number(event.params["totalBytes"])
                        let received = Self.number(event.params["receivedBytes"])
                        if total.map({ $0 > Double(maximumBytes) }) == true
                            || received.map({ $0 > Double(maximumBytes) }) == true {
                            try? await runtime.browserConnection.command(
                                "Browser.cancelDownload",
                                params: .object(["guid": .string(activeGUID)]),
                                timeout: runtime.commandTimeout
                            )
                            throw BrowserError.downloadTooLarge(maximumBytes)
                        }
                        switch event.params["state"]?.stringValue {
                        case "completed":
                            let file = downloadDirectory.appendingPathComponent(
                                activeGUID,
                                isDirectory: false
                            )
                            if FileManager.default.fileExists(atPath: file.path) {
                                let inspected = try Self.inspectDownloadedFile(
                                    file,
                                    directory: downloadDirectory,
                                    maximumBytes: maximumBytes
                                )
                                let rootPrefix = runtime.session.repositoryRoot.path + "/"
                                guard file.path.hasPrefix(rootPrefix) else {
                                    throw BrowserError.profilePathEscapedRuntimeRoot
                                }
                                return BrowserDownload(
                                    guid: activeGUID,
                                    sanitizedURL: sanitizedURL,
                                    suggestedFilename: suggestedFilename,
                                    byteCount: inspected.byteCount,
                                    sha256: inspected.sha256,
                                    relativePath: String(file.path.dropFirst(rootPrefix.count)),
                                    fileURL: file
                                )
                            }
                        case "canceled":
                            throw BrowserError.downloadFailed("Chromium cancelled the transfer.")
                        default:
                            break
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if let guid {
                try? await runtime.browserConnection.command(
                    "Browser.cancelDownload",
                    params: .object(["guid": .string(guid)]),
                    timeout: runtime.commandTimeout
                )
                Self.removePartialDownload(guid: guid, directory: downloadDirectory)
            }
            throw error
        }
        if let guid {
            try? await runtime.browserConnection.command(
                "Browser.cancelDownload",
                params: .object(["guid": .string(guid)]),
                timeout: runtime.commandTimeout
            )
            Self.removePartialDownload(guid: guid, directory: downloadDirectory)
        }
        throw BrowserError.commandTimedOut("Browser download")
    }

    func cookies(
        sessionID: UUID,
        tabID: String,
        urls: [URL] = []
    ) async throws -> [BrowserCookie] {
        guard urls.count <= BrowserBounds.maximumCookiesPerOperation else {
            throw BrowserError.invalidLimit
        }
        let validatedURLs = try urls.map {
            try BrowserBounds.validatedNavigationURL($0).absoluteString
        }
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        var params: [String: JSONValue] = [:]
        if !validatedURLs.isEmpty {
            params["urls"] = .array(validatedURLs.map(JSONValue.string))
        }
        let result = try await connection.command(
            "Network.getCookies",
            params: .object(params),
            timeout: runtime.commandTimeout
        )
        guard let rawCookies = result["cookies"]?.arrayValue else {
            throw BrowserError.protocolViolation("Network.getCookies omitted cookies.")
        }
        guard rawCookies.count <= BrowserBounds.maximumCookiesPerOperation else {
            throw BrowserError.responseTooLarge(BrowserBounds.maximumJavaScriptResultBytes)
        }
        return try rawCookies.map(Self.cookie)
    }

    func setCookies(
        sessionID: UUID,
        tabID: String,
        cookies: [BrowserCookieInput]
    ) async throws {
        guard !cookies.isEmpty,
              cookies.count <= BrowserBounds.maximumCookiesPerOperation else {
            throw BrowserError.invalidLimit
        }
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let parameters = try cookies.map(Self.cookieParameters)
        let result = try await connection.command(
            "Network.setCookies",
            params: .object(["cookies": .array(parameters.map(JSONValue.object))]),
            timeout: runtime.commandTimeout
        )
        // New Chromium returns an empty result for success. Some older builds
        // expose a boolean; treat an explicit false as failure.
        if result["success"]?.boolValue == false {
            throw BrowserError.invalidCookie("Chromium rejected the cookie set.")
        }
    }

    func deleteCookie(
        sessionID: UUID,
        tabID: String,
        name: String,
        url: URL? = nil,
        domain: String? = nil,
        path: String? = nil
    ) async throws {
        let validatedName = try Self.validatedCookieName(name)
        guard url != nil || domain?.isEmpty == false else {
            throw BrowserError.invalidCookie("Either url or domain is required for deletion.")
        }
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        var params: [String: JSONValue] = ["name": .string(validatedName)]
        if let url {
            params["url"] = .string(
                try BrowserBounds.validatedNavigationURL(url).absoluteString
            )
        }
        if let domain { params["domain"] = .string(try Self.validatedCookieDomain(domain)) }
        if let path { params["path"] = .string(try Self.validatedCookiePath(path)) }
        _ = try await connection.command(
            "Network.deleteCookies",
            params: .object(params),
            timeout: runtime.commandTimeout
        )
    }

    func clearCookies(sessionID: UUID, tabID: String) async throws {
        let (runtime, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        _ = try await connection.command(
            "Network.clearBrowserCookies",
            timeout: runtime.commandTimeout
        )
    }

    func evaluateJavaScript(
        sessionID: UUID,
        tabID: String,
        expression: String,
        awaitPromise: Bool = true,
        timeout: TimeInterval
    ) async throws -> BrowserJavaScriptResult {
        guard !expression.isEmpty,
              expression.utf8.count <= BrowserBounds.maximumJavaScriptBytes,
              !expression.contains("\0") else {
            throw BrowserError.javaScriptTooLarge(BrowserBounds.maximumJavaScriptBytes)
        }
        let boundedTimeout = try BrowserBounds.validatedTimeout(
            timeout,
            minimum: BrowserBounds.minimumCommandTimeout,
            maximum: BrowserBounds.maximumCommandTimeout
        )
        let (_, connection) = try await pageConnection(
            sessionID: sessionID,
            tabID: tabID
        )
        let result = try await connection.command(
            "Runtime.evaluate",
            params: .object([
                "expression": .string(expression),
                "awaitPromise": .bool(awaitPromise),
                "returnByValue": .bool(true),
                "generatePreview": .bool(false),
                "userGesture": .bool(false),
                "replMode": .bool(false)
            ]),
            timeout: boundedTimeout
        )
        if let exception = result["exceptionDetails"] {
            throw BrowserError.javaScriptException(Self.exceptionDescription(exception))
        }
        guard let remoteObject = result["result"]?.objectValue,
              let type = remoteObject["type"]?.stringValue else {
            throw BrowserError.protocolViolation("Runtime.evaluate omitted its remote object.")
        }
        let value = remoteObject["value"]
        if let value {
            try BrowserBounds.validateJSON(
                value,
                maximumDepth: 64,
                maximumValues: 100_000,
                maximumStringBytes: BrowserBounds.maximumJavaScriptResultBytes
            )
            guard try BrowserBounds.encodedSize(of: value)
                    <= BrowserBounds.maximumJavaScriptResultBytes else {
                throw BrowserError.responseTooLarge(BrowserBounds.maximumJavaScriptResultBytes)
            }
        }
        let description = remoteObject["description"]?.stringValue.map {
            BrowserBounds.boundedUTF8($0, maximumBytes: 16 * 1_024).0
        }
        return BrowserJavaScriptResult(
            type: BrowserBounds.boundedUTF8(type, maximumBytes: 64).0,
            subtype: remoteObject["subtype"]?.stringValue.map {
                BrowserBounds.boundedUTF8($0, maximumBytes: 64).0
            },
            value: value,
            description: description
        )
    }
}

private extension BrowserService {
    static let safeDOMProjectionExpression = """
    (() => {
      const maximum = 300;
      const maximumCharacters = 48000;
      let usedCharacters = 0;
      let wasTruncated = false;
      const candidates = Array.from(document.querySelectorAll('body *')).slice(0, 10000);
      const elements = [];
      const omittedTags = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','META','LINK']);
      const sensitiveAutocomplete = /password|current-password|new-password|one-time-code|cc-number|cc-csc/i;
      for (const element of candidates) {
        if (elements.length >= maximum) { wasTruncated = true; break; }
        if (omittedTags.has(element.tagName)) continue;
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        if (rect.width <= 0 || rect.height <= 0 || style.visibility === 'hidden' || style.display === 'none') continue;
        const inputType = String(element.type || '').toLowerCase();
        const autocomplete = String(element.autocomplete || '');
        if (inputType === 'password' || sensitiveAutocomplete.test(autocomplete)) continue;
        const role = roleOf(element);
        const name = nameOf(element).slice(0, 512);
        const text = String(element.innerText || element.textContent || '').trim().slice(0, 1024);
        const interactive = Boolean(role || element.tabIndex >= 0 || /^(A|BUTTON|INPUT|SELECT|TEXTAREA)$/.test(element.tagName));
        if (!interactive && !text) continue;
        const attributes = {};
        for (const attribute of ['id','class','name','type','role','aria-label','aria-labelledby','placeholder','title','alt','href','for']) {
          if (element.hasAttribute(attribute)) attributes[attribute] = String(element.getAttribute(attribute)).slice(0, 512);
        }
        const summary = {
          tag: element.tagName.toLowerCase(), role, name, text,
          selector_hint: selectorHint(element), attributes,
          bounds: {x:rect.x,y:rect.y,width:rect.width,height:rect.height},
          enabled: !element.disabled, editable: Boolean(element.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(element.tagName))
        };
        const summaryCharacters = JSON.stringify(summary).length;
        if (usedCharacters + summaryCharacters > maximumCharacters) { wasTruncated = true; break; }
        elements.push(summary); usedCharacters += summaryCharacters;
      }
      return {url: location.href, title: document.title, elements, truncated: wasTruncated, sensitive_form_values_omitted: true};
      function roleOf(e) {
        return e.getAttribute('role') || ({BUTTON:'button',A:'link',SELECT:'combobox',TEXTAREA:'textbox'}[e.tagName] || (e.tagName === 'INPUT' ? (e.type === 'checkbox' ? 'checkbox' : e.type === 'radio' ? 'radio' : 'textbox') : ''));
      }
      function nameOf(e) {
        const labels = e.labels ? Array.from(e.labels).map(label => label.innerText || label.textContent || '').join(' ') : '';
        return e.getAttribute('aria-label') || labels || e.getAttribute('title') || e.getAttribute('alt') || e.innerText || e.textContent || e.getAttribute('placeholder') || '';
      }
      function selectorHint(e) {
        if (e.id) return '#' + CSS.escape(e.id);
        const parts = [];
        let current = e;
        while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 8) {
          let part = current.tagName.toLowerCase();
          if (current.id) { parts.unshift('#' + CSS.escape(current.id)); break; }
          if (current.parentElement) {
            const peers = Array.from(current.parentElement.children).filter(peer => peer.tagName === current.tagName);
            if (peers.length > 1) part += ':nth-of-type(' + (peers.indexOf(current) + 1) + ')';
          }
          parts.unshift(part); current = current.parentElement;
        }
        return parts.join(' > ').slice(0, 2048);
      }
    })()
    """

    struct BrowserVersionFields {
        let product: String
        let protocolVersion: String?
    }

    static func createDownloadDirectory(runtimeRoot: URL, sessionID: UUID) throws -> URL {
        let canonicalRuntime = runtimeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let downloadsRoot = canonicalRuntime
            .appendingPathComponent("downloads", isDirectory: true)
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: downloadsRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BrowserError.profileDirectoryUnavailable
        }
        try validateDownloadDirectory(downloadsRoot, parent: canonicalRuntime)

        let sessionDirectory = downloadsRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: sessionDirectory.path) else {
            throw BrowserError.profileDirectoryCollision
        }
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw BrowserError.profileDirectoryUnavailable
        }
        do {
            try validateDownloadDirectory(sessionDirectory, parent: downloadsRoot)
        } catch {
            try? FileManager.default.removeItem(at: sessionDirectory)
            throw error
        }
        return sessionDirectory
    }

    static func validateDownloadDirectory(_ directory: URL, parent: URL) throws {
        let standardized = directory.standardizedFileURL
        let canonicalParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let values = try standardized.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        let resolved = standardized.resolvingSymlinksInPath()
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              resolved.path == standardized.path,
              resolved.path.hasPrefix(canonicalParent.path + "/") else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        let descriptor = Darwin.open(
            standardized.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw BrowserError.profileDirectoryUnavailable }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid() else {
            throw BrowserError.profileDirectoryUnavailable
        }
        if metadata.st_mode & 0o077 != 0 {
            guard Darwin.fchmod(descriptor, 0o700) == 0 else {
                throw BrowserError.profileDirectoryUnavailable
            }
        }
    }

    static func removePartialDownload(guid: String, directory: URL) {
        guard (try? BrowserBounds.validatedTargetIdentifier(guid)) != nil else { return }
        for name in [guid, "\(guid).crdownload"] where !name.hasPrefix("._") {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            guard candidate.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    static func sanitizedDownloadFilename(_ rawValue: String) -> String {
        let component = URL(fileURLWithPath: rawValue).lastPathComponent
        var filtered = ""
        for scalar in component.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0 {
                filtered.append("_")
            } else {
                filtered.unicodeScalars.append(scalar)
            }
        }
        let bounded = BrowserBounds.boundedUTF8(filtered, maximumBytes: 255).0
        return bounded.isEmpty || bounded == "." || bounded == ".." ? "download" : bounded
    }

    static func inspectDownloadedFile(
        _ file: URL,
        directory: URL,
        maximumBytes: Int
    ) throws -> (byteCount: Int, sha256: String) {
        let candidate = file.standardizedFileURL
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().path == parent.path else {
            throw BrowserError.profilePathEscapedRuntimeRoot
        }
        let descriptor = Darwin.open(
            candidate.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw BrowserError.downloadFailed("The completed file could not be opened safely.")
        }
        defer { Darwin.close(descriptor) }
        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            if metadata.st_size > maximumBytes {
                throw BrowserError.downloadTooLarge(maximumBytes)
            }
            throw BrowserError.downloadFailed("The completed path is not a bounded regular file.")
        }
        let expectedBytes = Int(metadata.st_size)
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw BrowserError.downloadFailed("The completed file could not be read safely.")
            }
            total += count
            guard total <= maximumBytes else {
                throw BrowserError.downloadTooLarge(maximumBytes)
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard total == expectedBytes else {
            throw BrowserError.downloadFailed("The completed file changed while being verified.")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (total, digest)
    }

    static func validate(_ configuration: BrowserLaunchConfiguration) throws {
        _ = try validatedRepositoryRoot(configuration.repositoryRoot)
        _ = try BrowserBounds.validatedNavigationURL(configuration.initialURL)
        _ = try BrowserBounds.validatedTimeout(
            configuration.startupTimeout,
            minimum: BrowserBounds.minimumStartupTimeout,
            maximum: BrowserBounds.maximumStartupTimeout
        )
        _ = try BrowserBounds.validatedTimeout(
            configuration.commandTimeout,
            minimum: BrowserBounds.minimumCommandTimeout,
            maximum: BrowserBounds.maximumCommandTimeout
        )
        guard (320...BrowserBounds.maximumScreenshotDimension).contains(
            configuration.viewportWidth
        ), (240...BrowserBounds.maximumScreenshotDimension).contains(
            configuration.viewportHeight
        ) else {
            throw BrowserError.invalidConfiguration("Viewport dimensions are out of bounds.")
        }
        let pixels = configuration.viewportWidth.multipliedReportingOverflow(
            by: configuration.viewportHeight
        )
        guard !pixels.overflow, pixels.partialValue <= BrowserBounds.maximumScreenshotPixels else {
            throw BrowserError.invalidConfiguration("Viewport pixel count is out of bounds.")
        }
        if case .persistent(let name) = configuration.profilePersistence {
            _ = try BrowserProfile.validatedPersistentName(name)
        }
    }

    static func validatedRepositoryRoot(_ repositoryRoot: URL) throws -> URL {
        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.path != "/",
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BrowserError.invalidRepositoryRoot
        }
        return root
    }

    static func resolveBrowserExecutable(_ explicitURL: URL?) throws -> URL {
        if let explicitURL {
            return try validatedBrowserExecutable(explicitURL)
        }

        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let applicationCandidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            homeApplications.appendingPathComponent(
                "Google Chrome.app/Contents/MacOS/Google Chrome"
            ).path,
            homeApplications.appendingPathComponent(
                "Chromium.app/Contents/MacOS/Chromium"
            ).path
        ]

        var candidates = applicationCandidates.map { URL(fileURLWithPath: $0) }
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        let commandNames = [
            "chromium", "chromium-browser", "google-chrome", "google-chrome-stable"
        ]
        for directory in pathDirectories where directory.hasPrefix("/") {
            for name in commandNames {
                candidates.append(
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(name, isDirectory: false)
                )
            }
        }
        for candidate in candidates {
            if let executable = try? validatedBrowserExecutable(candidate) { return executable }
        }
        throw BrowserError.browserExecutableNotFound
    }

    static func validatedBrowserExecutable(_ rawURL: URL) throws -> URL {
        let standardized = rawURL.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw BrowserError.invalidBrowserExecutable
        }
        let resolved = standardized.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw BrowserError.invalidBrowserExecutable
        }
        return resolved
    }

    static func launchArguments(
        configuration: BrowserLaunchConfiguration,
        profile: BrowserProfile,
        diskCacheDirectory: URL
    ) -> [String] {
        var arguments = [
            "--user-data-dir=\(profile.dataDirectory.path)",
            "--disk-cache-dir=\(diskCacheDirectory.path)",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
            "--no-service-autorun",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-default-apps",
            "--disable-extensions",
            "--disable-sync",
            "--disable-breakpad",
            "--disable-crash-reporter",
            "--disable-search-engine-choice-screen",
            "--host-resolver-rules=MAP metadata.google.internal ~NOTFOUND, MAP metadata.azure.internal ~NOTFOUND, MAP metadata.aws.internal ~NOTFOUND",
            "--metrics-recording-only",
            "--password-store=basic",
            "--use-mock-keychain",
            "--enable-automation",
            "--window-size=\(configuration.viewportWidth),\(configuration.viewportHeight)"
        ]
        if configuration.headless {
            arguments.append("--headless=new")
            arguments.append("--hide-scrollbars")
        }
        arguments.append(configuration.initialURL.absoluteString)
        return arguments
    }

    static func waitForDevToolsEndpoint(
        profile: BrowserProfile,
        process: BrowserManagedProcess,
        timeout: TimeInterval
    ) async throws -> URL {
        let marker = profile.dataDirectory.appendingPathComponent(
            "DevToolsActivePort",
            isDirectory: false
        )
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int64((timeout * 1_000).rounded(.up)))
        )
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw BrowserError.browserExited(process.exitStatus ?? -1)
            }
            if FileManager.default.fileExists(atPath: marker.path) {
                let values = try marker.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw BrowserError.invalidDevToolsEndpoint
                }
                guard (values.fileSize ?? 0) <= 4_096 else {
                    throw BrowserError.invalidDevToolsEndpoint
                }
                let data = try Data(contentsOf: marker, options: .mappedIfSafe)
                guard data.count <= 4_096 else { throw BrowserError.invalidDevToolsEndpoint }
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.split(
                        whereSeparator: \Character.isNewline
                    ).map(String.init)
                    if lines.count == 2,
                       let port = Int(lines[0]),
                       (1...65_535).contains(port),
                       lines[1].hasPrefix("/devtools/browser/"),
                       lines[1].utf8.count <= 1_024,
                       !lines[1].unicodeScalars.contains(
                           where: CharacterSet.controlCharacters.contains
                       ) {
                        var components = URLComponents()
                        components.scheme = "ws"
                        components.host = "127.0.0.1"
                        components.port = port
                        components.path = lines[1]
                        if let endpoint = components.url { return endpoint }
                        throw BrowserError.invalidDevToolsEndpoint
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserError.startupTimedOut
    }

    static func resolveExistingDebugEndpoint(
        _ rawEndpoint: URL,
        timeout: TimeInterval
    ) async throws -> URL {
        let endpoint = rawEndpoint.standardized
        guard AgentHTTPOrigin.isLoopback(endpoint.host),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              let port = endpoint.port,
              (1...65_535).contains(port) else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        let scheme = endpoint.scheme?.lowercased()
        if scheme == "ws" {
            guard endpoint.path.hasPrefix("/devtools/browser/"),
                  endpoint.path.utf8.count <= 1_024 else {
                throw BrowserError.invalidDevToolsEndpoint
            }
            return endpoint
        }
        guard scheme == "http",
              endpoint.path.isEmpty || endpoint.path == "/" || endpoint.path == "/json/version" else {
            throw BrowserError.invalidDevToolsEndpoint
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/json/version"
        guard let versionURL = components?.url else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(
            configuration: configuration,
            delegate: RejectingRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: versionURL)
        request.timeoutInterval = timeout
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              AgentHTTPOrigin.isSameOrigin(http.url, versionURL) else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        var data = Data()
        data.reserveCapacity(8 * 1_024)
        for try await byte in bytes {
            guard data.count < 64 * 1_024 else {
                throw BrowserError.responseTooLarge(64 * 1_024)
            }
            data.append(byte)
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw BrowserError.invalidDevToolsEndpoint
        }
        guard let rawWebSocket = value["webSocketDebuggerUrl"]?.stringValue,
              rawWebSocket.utf8.count <= 2_048,
              let webSocket = URL(string: rawWebSocket),
              webSocket.scheme?.lowercased() == "ws",
              AgentHTTPOrigin.isLoopback(webSocket.host),
              webSocket.port == port,
              webSocket.user == nil,
              webSocket.password == nil,
              webSocket.query == nil,
              webSocket.fragment == nil,
              webSocket.path.hasPrefix("/devtools/browser/") else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        return webSocket
    }

    static func pageEndpoint(browserEndpoint: URL, targetID: String) throws -> URL {
        let id = try BrowserBounds.validatedTargetIdentifier(targetID)
        var components = URLComponents(url: browserEndpoint, resolvingAgainstBaseURL: false)
        components?.path = "/devtools/page/\(id)"
        components?.query = nil
        components?.fragment = nil
        guard let endpoint = components?.url,
              endpoint.scheme?.lowercased() == "ws",
              AgentHTTPOrigin.isLoopback(endpoint.host) else {
            throw BrowserError.invalidDevToolsEndpoint
        }
        return endpoint
    }

    static func browserVersionFields(_ value: JSONValue) throws -> BrowserVersionFields {
        guard let rawProduct = value["product"]?.stringValue, !rawProduct.isEmpty else {
            throw BrowserError.protocolViolation("Browser.getVersion omitted product.")
        }
        let product = BrowserBounds.boundedUTF8(rawProduct, maximumBytes: 256).0
        let protocolVersion = value["protocolVersion"]?.stringValue.map {
            BrowserBounds.boundedUTF8($0, maximumBytes: 64).0
        }
        return BrowserVersionFields(product: product, protocolVersion: protocolVersion)
    }

    static func screenshotDimensions(
        _ metrics: JSONValue,
        fullPage: Bool
    ) throws -> (width: Int, height: Int) {
        let source = fullPage
            ? metrics["cssContentSize"] ?? metrics["contentSize"]
            : metrics["cssVisualViewport"]
                ?? metrics["visualViewport"]
                ?? metrics["cssLayoutViewport"]
                ?? metrics["layoutViewport"]
        guard let widthValue = number(source?["width"] ?? source?["clientWidth"]),
              let heightValue = number(source?["height"] ?? source?["clientHeight"]),
              widthValue.isFinite,
              heightValue.isFinite,
              widthValue > 0,
              heightValue > 0,
              widthValue <= Double(Int.max),
              heightValue <= Double(Int.max) else {
            throw BrowserError.invalidScreenshot
        }
        let width = Int(widthValue.rounded(.up))
        let height = Int(heightValue.rounded(.up))
        try validateScreenshotDimensions(width: width, height: height)
        return (width, height)
    }

    static func validateScreenshotDimensions(width: Int, height: Int) throws {
        guard (1...BrowserBounds.maximumScreenshotDimension).contains(width),
              (1...BrowserBounds.maximumScreenshotDimension).contains(height) else {
            throw BrowserError.screenshotTooLarge(BrowserBounds.maximumScreenshotBytes)
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= BrowserBounds.maximumScreenshotPixels else {
            throw BrowserError.screenshotTooLarge(BrowserBounds.maximumScreenshotBytes)
        }
    }

    static func pngDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard data.count >= 24,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw BrowserError.invalidScreenshot
        }
        return (width, height)
    }

    static func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value, number.isFinite else { return nil }
        return number
    }

    static func exceptionDescription(_ value: JSONValue) -> String {
        var components: [String] = []
        if let text = value["text"]?.stringValue { components.append(text) }
        if let description = value["exception"]?["description"]?.stringValue {
            components.append(description)
        }
        let joined = components.isEmpty ? "Unknown page exception" : components.joined(separator: ": ")
        let redacted = SecretRedactor().redact(joined)
        return BrowserBounds.boundedUTF8(redacted, maximumBytes: 16 * 1_024).0
    }
}

private extension BrowserService {
    static func consoleEntry(_ event: BrowserCDPEvent) -> BrowserConsoleEntry? {
        let redactor = SecretRedactor()
        switch event.method {
        case "Runtime.consoleAPICalled":
            let type = event.params["type"]?.stringValue ?? "log"
            let rawParts = event.params["args"]?.arrayValue?.map(renderedRemoteObject) ?? []
            let rawText = rawParts.joined(separator: " ")
            let sanitized = BrowserBounds.boundedUTF8(
                redactor.redact(rawText),
                maximumBytes: BrowserBounds.maximumConsoleTextBytes
            )
            let firstFrame = event.params["stackTrace"]?["callFrames"]?.arrayValue?.first
            let source = firstFrame?["url"]?.stringValue.map(sanitizedURL)
            return BrowserConsoleEntry(
                sequence: event.sequence,
                kind: consoleKind(type),
                text: sanitized.0,
                sourceURL: source,
                lineNumber: firstFrame?["lineNumber"]?.intValue,
                timestamp: number(event.params["timestamp"]),
                wasTruncated: sanitized.1
            )
        case "Log.entryAdded":
            guard let entry = event.params["entry"] else { return nil }
            let rawText = entry["text"]?.stringValue ?? ""
            let sanitized = BrowserBounds.boundedUTF8(
                redactor.redact(rawText),
                maximumBytes: BrowserBounds.maximumConsoleTextBytes
            )
            return BrowserConsoleEntry(
                sequence: event.sequence,
                kind: consoleKind(entry["level"]?.stringValue ?? "log"),
                text: sanitized.0,
                sourceURL: entry["url"]?.stringValue.map(sanitizedURL),
                lineNumber: entry["lineNumber"]?.intValue,
                timestamp: number(entry["timestamp"]),
                wasTruncated: sanitized.1
            )
        case "Runtime.exceptionThrown":
            guard let details = event.params["exceptionDetails"] else { return nil }
            let description = exceptionDescription(details)
            return BrowserConsoleEntry(
                sequence: event.sequence,
                kind: .exception,
                text: description,
                sourceURL: details["url"]?.stringValue.map(sanitizedURL),
                lineNumber: details["lineNumber"]?.intValue,
                timestamp: number(event.params["timestamp"]),
                wasTruncated: description.utf8.count >= BrowserBounds.maximumConsoleTextBytes
            )
        default:
            return nil
        }
    }

    static func consoleKind(_ rawValue: String) -> BrowserConsoleEntryKind {
        switch rawValue.lowercased() {
        case "debug", "verbose": .debug
        case "info": .info
        case "warning", "warn": .warning
        case "error", "assert": .error
        case "exception": .exception
        default: .log
        }
    }

    static func renderedRemoteObject(_ object: JSONValue) -> String {
        if let value = object["value"] {
            if case .string(let string) = value { return string }
            if let data = try? JSONEncoder().encode(value),
               data.count <= BrowserBounds.maximumConsoleTextBytes,
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        }
        if let description = object["description"]?.stringValue { return description }
        if let unserializable = object["unserializableValue"]?.stringValue { return unserializable }
        return object["type"]?.stringValue ?? "undefined"
    }

    static func networkEntry(_ event: BrowserCDPEvent) -> BrowserNetworkEntry? {
        guard let rawRequestID = event.params["requestId"]?.stringValue,
              !rawRequestID.isEmpty,
              !rawRequestID.unicodeScalars.contains(
                  where: CharacterSet.controlCharacters.contains
              ) else { return nil }
        let requestID = BrowserBounds.boundedUTF8(rawRequestID, maximumBytes: 256).0
        let timestamp = number(event.params["timestamp"])
        let resourceType = event.params["type"]?.stringValue.map {
            BrowserBounds.boundedUTF8($0, maximumBytes: 64).0
        }

        switch event.method {
        case "Network.requestWillBeSent":
            guard let request = event.params["request"] else { return nil }
            let rawURL = request["url"]?.stringValue ?? ""
            let boundedURL = boundedSanitizedURL(rawURL)
            let redirect = event.params["redirectResponse"]
            let redirectedURL = redirect?["url"]?.stringValue.map(boundedSanitizedURL)
            return BrowserNetworkEntry(
                sequence: event.sequence,
                kind: .request,
                requestID: requestID,
                url: boundedURL.value,
                method: request["method"]?.stringValue.map {
                    BrowserBounds.boundedUTF8($0, maximumBytes: 32).0
                },
                status: nil,
                mimeType: nil,
                resourceType: resourceType,
                protocolName: nil,
                headers: sanitizedHeaders(request["headers"]),
                encodedDataLength: nil,
                durationMilliseconds: nil,
                redirectedFromURL: redirectedURL?.value,
                redirectStatus: number(redirect?["status"]).flatMap { Int(exactly: $0) },
                failure: nil,
                timestamp: timestamp,
                wasTruncated: boundedURL.truncated || redirectedURL?.truncated == true
            )
        case "Network.responseReceived":
            guard let response = event.params["response"] else { return nil }
            let rawURL = response["url"]?.stringValue ?? ""
            let boundedURL = boundedSanitizedURL(rawURL)
            let status = number(response["status"]).flatMap { Int(exactly: $0) }
            let duration = number(response["timing"]?["receiveHeadersEnd"]).flatMap {
                $0 >= 0 ? $0 : nil
            }
            return BrowserNetworkEntry(
                sequence: event.sequence,
                kind: .response,
                requestID: requestID,
                url: boundedURL.value,
                method: nil,
                status: status,
                mimeType: response["mimeType"]?.stringValue.map {
                    BrowserBounds.boundedUTF8($0, maximumBytes: 256).0
                },
                resourceType: resourceType,
                protocolName: response["protocol"]?.stringValue.map {
                    BrowserBounds.boundedUTF8($0, maximumBytes: 64).0
                },
                headers: sanitizedHeaders(response["headers"]),
                encodedDataLength: number(response["encodedDataLength"]),
                durationMilliseconds: duration,
                redirectedFromURL: nil,
                redirectStatus: nil,
                failure: nil,
                timestamp: timestamp,
                wasTruncated: boundedURL.truncated
            )
        case "Network.loadingFailed":
            let rawFailure = event.params["errorText"]?.stringValue ?? "Loading failed"
            let failure = BrowserBounds.boundedUTF8(
                SecretRedactor().redact(rawFailure),
                maximumBytes: BrowserBounds.maximumNetworkFailureBytes
            )
            return BrowserNetworkEntry(
                sequence: event.sequence,
                kind: .loadingFailed,
                requestID: requestID,
                url: "",
                method: nil,
                status: nil,
                mimeType: nil,
                resourceType: resourceType,
                protocolName: nil,
                headers: [:],
                encodedDataLength: nil,
                durationMilliseconds: nil,
                redirectedFromURL: nil,
                redirectStatus: nil,
                failure: failure.0,
                timestamp: timestamp,
                wasTruncated: failure.1
            )
        case "Network.loadingFinished":
            return BrowserNetworkEntry(
                sequence: event.sequence,
                kind: .loadingFinished,
                requestID: requestID,
                url: "",
                method: nil,
                status: nil,
                mimeType: nil,
                resourceType: resourceType,
                protocolName: nil,
                headers: [:],
                encodedDataLength: number(event.params["encodedDataLength"]),
                durationMilliseconds: nil,
                redirectedFromURL: nil,
                redirectStatus: nil,
                failure: nil,
                timestamp: timestamp,
                wasTruncated: false
            )
        default:
            return nil
        }
    }

    static func sanitizedHeaders(_ value: JSONValue?) -> [String: String] {
        BrowserSecuritySanitizer.headers(value)
    }

    static func boundedSanitizedURL(_ rawValue: String) -> (value: String, truncated: Bool) {
        BrowserSecuritySanitizer.url(rawValue)
    }

    static func sanitizedAccessibilityTree(_ response: JSONValue) throws -> JSONValue {
        guard let rawNodes = response["nodes"]?.arrayValue else {
            throw BrowserError.protocolViolation(
                "Accessibility.getFullAXTree omitted nodes."
            )
        }
        let maximumNodes = 5_000
        let allowedProperties: Set<String> = [
            "busy", "checked", "disabled", "editable", "expanded", "focusable",
            "focused", "invalid", "level", "modal", "multiline", "multiselectable",
            "orientation", "pressed", "readonly", "required", "selected"
        ]
        let redactor = SecretRedactor()
        let safeNodes: [JSONValue] = rawNodes.prefix(maximumNodes).compactMap { rawNode in
            guard let rawNodeID = rawNode["nodeId"]?.stringValue, !rawNodeID.isEmpty else {
                return nil
            }
            var node: [String: JSONValue] = [
                "node_id": .string(
                    BrowserBounds.boundedUTF8(rawNodeID, maximumBytes: 256).0
                ),
                "ignored": .bool(rawNode["ignored"]?.boolValue ?? false)
            ]
            if let backendDOMNodeID = rawNode["backendDOMNodeId"]?.intValue,
               backendDOMNodeID >= 0 {
                node["backend_dom_node_id"] = .number(Double(backendDOMNodeID))
            }
            for (source, destination, maximumBytes) in [
                ("role", "role", 256),
                ("name", "name", 4_096),
                ("description", "description", 4_096)
            ] {
                if let raw = rawNode[source]?["value"]?.stringValue {
                    node[destination] = .string(
                        BrowserBounds.boundedUTF8(
                            redactor.redact(raw), maximumBytes: maximumBytes
                        ).0
                    )
                }
            }
            if let rawChildren = rawNode["childIds"]?.arrayValue {
                node["child_ids"] = .array(
                    rawChildren.prefix(512).compactMap { child in
                        guard let value = child.stringValue, !value.isEmpty else { return nil }
                        return .string(BrowserBounds.boundedUTF8(value, maximumBytes: 256).0)
                    }
                )
            }
            if let rawProperties = rawNode["properties"]?.arrayValue {
                var properties: [String: JSONValue] = [:]
                for property in rawProperties.prefix(128) {
                    guard let name = property["name"]?.stringValue,
                          allowedProperties.contains(name),
                          let rawValue = property["value"]?["value"] else { continue }
                    switch rawValue {
                    case .bool, .number:
                        properties[name] = rawValue
                    case .string(let string):
                        properties[name] = .string(
                            BrowserBounds.boundedUTF8(
                                redactor.redact(string), maximumBytes: 1_024
                            ).0
                        )
                    case .array, .object, .null:
                        continue
                    }
                }
                if !properties.isEmpty { node["properties"] = .object(properties) }
            }
            return .object(node)
        }
        return .object([
            "nodes": .array(safeNodes),
            "truncated": .bool(rawNodes.count > maximumNodes),
            "sensitive_values_omitted": .bool(true),
            "trust": .string("untrusted")
        ])
    }

    static func sanitizedURL(_ rawValue: String) -> String {
        boundedSanitizedURL(rawValue).value
    }

    static func cookie(_ value: JSONValue) throws -> BrowserCookie {
        guard let name = value["name"]?.stringValue,
              let rawValue = value["value"]?.stringValue,
              let domain = value["domain"]?.stringValue,
              let path = value["path"]?.stringValue else {
            throw BrowserError.protocolViolation("Chromium returned an invalid cookie.")
        }
        _ = try validatedCookieName(name)
        guard rawValue.utf8.count <= BrowserBounds.maximumCookieValueBytes else {
            throw BrowserError.responseTooLarge(BrowserBounds.maximumCookieValueBytes)
        }
        let safeDomain = try validatedCookieDomain(domain)
        let safePath = try validatedCookiePath(path)
        let sameSite = value["sameSite"]?.stringValue.flatMap(BrowserCookieSameSite.init(rawValue:))
        let rawExpiry = number(value["expires"])
        return BrowserCookie(
            name: name,
            // Cookie contents are authentication material surprisingly often.
            // The core never returns them to an Agent/tool result.
            value: "[REDACTED]",
            domain: safeDomain,
            path: safePath,
            expires: rawExpiry.flatMap { $0 > 0 ? $0 : nil },
            size: value["size"]?.intValue,
            httpOnly: value["httpOnly"]?.boolValue ?? false,
            secure: value["secure"]?.boolValue ?? false,
            session: value["session"]?.boolValue ?? false,
            sameSite: sameSite
        )
    }

    static func cookieParameters(_ cookie: BrowserCookieInput) throws -> [String: JSONValue] {
        let name = try validatedCookieName(cookie.name)
        guard cookie.value.utf8.count <= BrowserBounds.maximumCookieValueBytes,
              !cookie.value.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0 || scalar.value == 10 || scalar.value == 13
              }) else {
            throw BrowserError.invalidCookie("Value is too large or contains a line break/NUL.")
        }
        guard cookie.url != nil || cookie.domain?.isEmpty == false else {
            throw BrowserError.invalidCookie("Either url or domain is required.")
        }
        if cookie.sameSite == BrowserCookieSameSite.none, !cookie.secure {
            throw BrowserError.invalidCookie("SameSite=None requires Secure.")
        }

        var params: [String: JSONValue] = [
            "name": .string(name),
            "value": .string(cookie.value),
            "secure": .bool(cookie.secure),
            "httpOnly": .bool(cookie.httpOnly)
        ]
        if let url = cookie.url {
            params["url"] = .string(
                try BrowserBounds.validatedNavigationURL(url).absoluteString
            )
        }
        if let domain = cookie.domain {
            params["domain"] = .string(try validatedCookieDomain(domain))
        }
        if let path = cookie.path {
            params["path"] = .string(try validatedCookiePath(path))
        }
        if let sameSite = cookie.sameSite { params["sameSite"] = .string(sameSite.rawValue) }
        if let expires = cookie.expires {
            guard expires.isFinite, expires > 0 else {
                throw BrowserError.invalidCookie("Expiry must be a finite positive Unix timestamp.")
            }
            params["expires"] = .number(expires)
        }
        return params
    }

    static func validatedCookieName(_ name: String) throws -> String {
        guard !name.isEmpty,
              name.utf8.count <= BrowserBounds.maximumCookieNameBytes,
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21
                      && scalar.value <= 0x7e
                      && !"()<>@,;:\\\"/[]?={} ".unicodeScalars.contains(scalar)
              }) else {
            throw BrowserError.invalidCookie("Name is empty, too large, or contains a separator.")
        }
        return name
    }

    static func validatedCookieDomain(_ domain: String) throws -> String {
        guard !domain.isEmpty,
              domain.utf8.count <= 255,
              !domain.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      || CharacterSet.whitespaces.contains(scalar)
                      || scalar.value == 47
              }) else {
            throw BrowserError.invalidCookie("Domain is invalid.")
        }
        return domain
    }

    static func validatedCookiePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"),
              path.utf8.count <= 2_048,
              !path.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0 || scalar.value == 10 || scalar.value == 13
              }) else {
            throw BrowserError.invalidCookie("Path is invalid.")
        }
        return path
    }
}
