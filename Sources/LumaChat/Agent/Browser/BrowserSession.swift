import Foundation

enum BrowserError: LocalizedError, Equatable, Sendable {
    case invalidRepositoryRoot
    case invalidPersistentProfileName
    case profileDirectoryUnavailable
    case profileDirectoryCollision
    case profilePathEscapedRuntimeRoot
    case profileInUse
    case persistentProfileInUse
    case debugEndpointInUse
    case browserExecutableNotFound
    case invalidBrowserExecutable
    case invalidConfiguration(String)
    case launchFailed(String)
    case browserExited(Int32)
    case startupTimedOut
    case invalidDevToolsEndpoint
    case sessionLimitReached(Int)
    case sessionNotFound(UUID)
    case sessionClosed(UUID)
    case tabLimitReached(Int)
    case tabNotFound(String)
    case invalidTargetIdentifier
    case invalidURL
    case unsupportedURLScheme(String)
    case credentialedURL
    case blockedNetworkTarget
    case invalidTimeout
    case invalidLimit
    case invalidCookie(String)
    case javaScriptTooLarge(Int)
    case javaScriptException(String)
    case responseTooLarge(Int)
    case domSnapshotTooLarge(Int)
    case screenshotTooLarge(Int)
    case invalidScreenshot
    case downloadUnavailableForAttachedSession
    case navigationWasNotDownload
    case downloadTooLarge(Int)
    case downloadFailed(String)
    case websocketClosed
    case commandTimedOut(String)
    case tooManyPendingCommands(Int)
    case protocolViolation(String)
    case protocolError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryRoot:
            "Browser repository root does not exist or is not a directory."
        case .invalidPersistentProfileName:
            "Persistent browser profile names must be 1–64 bytes and contain only letters, numbers, '.', '_' or '-'."
        case .profileDirectoryUnavailable:
            "The isolated browser profile directory is unavailable."
        case .profileDirectoryCollision:
            "A newly generated ephemeral browser profile unexpectedly already exists."
        case .profilePathEscapedRuntimeRoot:
            "Browser profile data must remain inside the repository tmp/browser directory."
        case .profileInUse:
            "This browser profile is already in use by another active session."
        case .persistentProfileInUse:
            "The persistent browser profile cannot be removed while it is active."
        case .debugEndpointInUse:
            "This Chrome DevTools endpoint is already attached to an active session."
        case .browserExecutableNotFound:
            "No supported Chromium or Google Chrome executable was found."
        case .invalidBrowserExecutable:
            "The configured browser executable is not an executable regular file."
        case .invalidConfiguration(let detail):
            "Invalid browser configuration: \(detail)"
        case .launchFailed(let detail):
            "Unable to launch Chromium: \(detail)"
        case .browserExited(let status):
            "Chromium exited before the operation completed (status \(status))."
        case .startupTimedOut:
            "Chromium did not publish its DevTools endpoint before the startup timeout."
        case .invalidDevToolsEndpoint:
            "Chromium published an invalid or non-loopback DevTools endpoint."
        case .sessionLimitReached(let maximum):
            "At most \(maximum) browser sessions may run at once."
        case .sessionNotFound(let id):
            "Browser session \(id.uuidString) was not found."
        case .sessionClosed(let id):
            "Browser session \(id.uuidString) is no longer running."
        case .tabLimitReached(let maximum):
            "At most \(maximum) tabs may be open in one browser session."
        case .tabNotFound(let id):
            "Browser tab \(id) was not found."
        case .invalidTargetIdentifier:
            "The Chromium target identifier is invalid."
        case .invalidURL:
            "The browser URL is invalid or exceeds its size limit."
        case .unsupportedURLScheme(let scheme):
            "Browser navigation does not allow the \(scheme) URL scheme."
        case .credentialedURL:
            "Browser URLs may not contain embedded user credentials."
        case .blockedNetworkTarget:
            "Browser navigation to cloud-metadata and link-local service endpoints is blocked."
        case .invalidTimeout:
            "The browser timeout is outside the supported range."
        case .invalidLimit:
            "The requested browser result limit is outside the supported range."
        case .invalidCookie(let detail):
            "Invalid browser cookie: \(detail)"
        case .javaScriptTooLarge(let maximum):
            "JavaScript must be non-empty and no larger than \(maximum) UTF-8 bytes."
        case .javaScriptException(let detail):
            "JavaScript evaluation failed: \(detail)"
        case .responseTooLarge(let maximum):
            "The Chrome DevTools response exceeds the \(maximum)-byte limit."
        case .domSnapshotTooLarge(let maximum):
            "The DOM snapshot exceeds the \(maximum)-byte limit."
        case .screenshotTooLarge(let maximum):
            "The screenshot exceeds the \(maximum)-byte or pixel bounds."
        case .invalidScreenshot:
            "Chromium returned an invalid PNG screenshot."
        case .downloadUnavailableForAttachedSession:
            "Downloads are disabled for attached browser sessions because CDP download policy is browser-global."
        case .navigationWasNotDownload:
            "The requested URL rendered as a page instead of producing a download."
        case .downloadTooLarge(let maximum):
            "The browser download exceeds the \(maximum)-byte limit and was cancelled."
        case .downloadFailed(let detail):
            "The browser download failed: \(detail)"
        case .websocketClosed:
            "The Chrome DevTools WebSocket is closed."
        case .commandTimedOut(let method):
            "Chrome DevTools command \(method) timed out."
        case .tooManyPendingCommands(let maximum):
            "At most \(maximum) Chrome DevTools commands may be pending."
        case .protocolViolation(let detail):
            "Invalid Chrome DevTools message: \(detail)"
        case .protocolError(let code, let message):
            "Chrome DevTools error \(code): \(message)"
        }
    }
}

enum BrowserBounds {
    static let maximumSessions = 4
    static let maximumTabsPerSession = 32
    static let maximumTargetIdentifierBytes = 256
    static let maximumURLBytes = 8 * 1_024
    static let maximumTitleBytes = 4 * 1_024
    static let maximumJavaScriptBytes = 64 * 1_024
    static let maximumJavaScriptResultBytes = 1 * 1_024 * 1_024
    static let maximumDOMSnapshotBytes = 4 * 1_024 * 1_024
    static let maximumScreenshotBytes = 8 * 1_024 * 1_024
    static let maximumScreenshotDimension = 4_096
    static let maximumScreenshotPixels = 16_777_216
    static let maximumCDPMessageBytes = 16 * 1_024 * 1_024
    static let maximumStoredEventBytes = 256 * 1_024
    static let maximumStoredEventsBytes = 4 * 1_024 * 1_024
    static let maximumStoredEvents = 2_048
    static let maximumPendingCommands = 128
    static let maximumConsoleTextBytes = 16 * 1_024
    static let maximumNetworkFailureBytes = 4 * 1_024
    static let maximumCookieNameBytes = 1_024
    static let maximumCookieValueBytes = 16 * 1_024
    static let maximumCookiesPerOperation = 256
    static let maximumReturnedEntries = 500
    static let maximumDownloadBytes = 64 * 1_024 * 1_024

    static let minimumCommandTimeout: TimeInterval = 0.25
    static let maximumCommandTimeout: TimeInterval = 30
    static let minimumNavigationTimeout: TimeInterval = 0.25
    static let maximumNavigationTimeout: TimeInterval = 60
    static let minimumStartupTimeout: TimeInterval = 1
    static let maximumStartupTimeout: TimeInterval = 30

    static func validatedTargetIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumTargetIdentifierBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 95:
                      true
                  default:
                      false
                  }
              }) else {
            throw BrowserError.invalidTargetIdentifier
        }
        return value
    }

    static func validatedNavigationURL(_ url: URL, allowAboutBlank: Bool = true) throws -> URL {
        let absolute = url.absoluteString
        guard !absolute.isEmpty,
              absolute.utf8.count <= maximumURLBytes,
              !absolute.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let scheme = url.scheme?.lowercased() else {
            throw BrowserError.invalidURL
        }
        if allowAboutBlank, absolute == "about:blank" { return url }
        guard scheme == "http" || scheme == "https" else {
            throw BrowserError.unsupportedURLScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else { throw BrowserError.invalidURL }
        guard url.user == nil, url.password == nil else { throw BrowserError.credentialedURL }
        guard !isBlockedNetworkTarget(host) else { throw BrowserError.blockedNetworkTarget }
        return url
    }

    static func isBlockedNetworkTarget(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        if [
            "metadata.google.internal", "metadata.azure.internal", "metadata.aws.internal",
            "169.254.169.254", "169.254.170.2", "100.100.100.200", "fd00:ec2::254"
        ].contains(host) {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { UInt8($0) }
        if octets.count == 4, octets[0] == 169, octets[1] == 254 { return true }
        let numeric: UInt32?
        if host.hasPrefix("0x") {
            numeric = UInt32(host.dropFirst(2), radix: 16)
        } else {
            numeric = UInt32(host)
        }
        if let numeric {
            if numeric & 0xffff_0000 == 0xa9fe_0000
                || numeric == 0x6464_64c8 {
                return true
            }
        }
        guard host.contains(":") else { return false }
        return host.hasPrefix("fe8") || host.hasPrefix("fe9")
            || host.hasPrefix("fea") || host.hasPrefix("feb")
    }

    static func validatedTimeout(
        _ value: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) throws -> TimeInterval {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw BrowserError.invalidTimeout
        }
        return value
    }

    static func validatedResultLimit(_ value: Int) throws -> Int {
        guard (1...maximumReturnedEntries).contains(value) else {
            throw BrowserError.invalidLimit
        }
        return value
    }

    static func boundedUTF8(_ value: String, maximumBytes: Int) -> (String, Bool) {
        guard value.utf8.count > maximumBytes else { return (value, false) }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for character in value {
            let count = String(character).utf8.count
            guard used + count <= maximumBytes else { break }
            result.append(character)
            used += count
        }
        return (result, true)
    }

    static func encodedSize(of value: JSONValue) throws -> Int {
        try JSONEncoder().encode(value).count
    }

    static func validateJSON(
        _ value: JSONValue,
        maximumDepth: Int = 64,
        maximumValues: Int = 200_000,
        maximumStringBytes: Int = maximumCDPMessageBytes
    ) throws {
        var stack: [(JSONValue, Int)] = [(value, 0)]
        var count = 0
        while let (current, depth) = stack.popLast() {
            count += 1
            guard depth <= maximumDepth, count <= maximumValues else {
                throw BrowserError.protocolViolation("JSON nesting or value count exceeded its bound.")
            }
            switch current {
            case .object(let object):
                guard object.keys.allSatisfy({ $0.utf8.count <= 4_096 }) else {
                    throw BrowserError.protocolViolation("JSON object key exceeded its bound.")
                }
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            case .array(let array):
                stack.append(contentsOf: array.map { ($0, depth + 1) })
            case .string(let string):
                guard string.utf8.count <= maximumStringBytes else {
                    throw BrowserError.responseTooLarge(maximumStringBytes)
                }
            case .number(let number):
                guard number.isFinite else {
                    throw BrowserError.protocolViolation("JSON contains a non-finite number.")
                }
            case .bool, .null:
                break
            }
        }
    }
}

struct BrowserLaunchConfiguration: Equatable, Sendable {
    var repositoryRoot: URL
    var profilePersistence: BrowserProfilePersistence
    var executableURL: URL?
    var headless: Bool
    var initialURL: URL
    var viewportWidth: Int
    var viewportHeight: Int
    var startupTimeout: TimeInterval
    var commandTimeout: TimeInterval

    init(
        repositoryRoot: URL,
        profilePersistence: BrowserProfilePersistence = .ephemeral,
        executableURL: URL? = nil,
        headless: Bool = true,
        initialURL: URL = URL(string: "about:blank")!,
        viewportWidth: Int = 1_280,
        viewportHeight: Int = 800,
        startupTimeout: TimeInterval = 10,
        commandTimeout: TimeInterval = 10
    ) {
        self.repositoryRoot = repositoryRoot
        self.profilePersistence = profilePersistence
        self.executableURL = executableURL
        self.headless = headless
        self.initialURL = initialURL
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.startupTimeout = startupTimeout
        self.commandTimeout = commandTimeout
    }
}

enum BrowserSessionSource: Equatable, Sendable {
    case launched(
        profile: BrowserProfile,
        executableURL: URL,
        processIdentifier: Int32
    )
    case attached(
        debugEndpoint: URL,
        repositoryRoot: URL
    )
}

struct BrowserSession: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: BrowserSessionSource
    let browserProduct: String
    let protocolVersion: String?
    let headless: Bool?
    let startedAt: Date

    var profile: BrowserProfile? {
        guard case .launched(let profile, _, _) = source else { return nil }
        return profile
    }

    var processIdentifier: Int32? {
        guard case .launched(_, _, let processIdentifier) = source else { return nil }
        return processIdentifier
    }

    var executableURL: URL? {
        guard case .launched(_, let executableURL, _) = source else { return nil }
        return executableURL
    }

    var repositoryRoot: URL {
        switch source {
        case .launched(let profile, _, _): profile.repositoryRoot
        case .attached(_, let repositoryRoot): repositoryRoot
        }
    }
}

struct BrowserTab: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: String
    let isAttached: Bool
    let titleWasTruncated: Bool
    let urlWasTruncated: Bool
}

struct BrowserNavigationResult: Equatable, Sendable {
    let tabID: String
    let url: String
    let title: String
    let frameID: String?
    let loaderID: String?
    let readyState: String
}

struct BrowserDOMSnapshot: Equatable, Sendable {
    let tabID: String
    let url: String
    let title: String
    let snapshot: JSONValue
    let encodedByteCount: Int
}

struct BrowserScreenshot: Equatable, Sendable {
    let tabID: String
    let mimeType: String
    let width: Int
    let height: Int
    let data: Data
}

enum BrowserConsoleEntryKind: String, Codable, Equatable, Sendable {
    case log
    case debug
    case info
    case warning
    case error
    case exception
}

struct BrowserConsoleEntry: Codable, Equatable, Sendable {
    let sequence: UInt64
    let kind: BrowserConsoleEntryKind
    let text: String
    let sourceURL: String?
    let lineNumber: Int?
    let timestamp: Double?
    let wasTruncated: Bool
}

enum BrowserNetworkEntryKind: String, Codable, Equatable, Sendable {
    case request
    case response
    case loadingFailed = "loading_failed"
    case loadingFinished = "loading_finished"
}

struct BrowserNetworkEntry: Codable, Equatable, Sendable {
    let sequence: UInt64
    let kind: BrowserNetworkEntryKind
    let requestID: String
    let url: String
    let method: String?
    let status: Int?
    let mimeType: String?
    let resourceType: String?
    let protocolName: String?
    let headers: [String: String]
    let encodedDataLength: Double?
    let durationMilliseconds: Double?
    let redirectedFromURL: String?
    let redirectStatus: Int?
    let failure: String?
    let timestamp: Double?
    let wasTruncated: Bool
}

struct BrowserPerformanceMetric: Codable, Equatable, Sendable {
    let name: String
    let value: Double
}

struct BrowserDownload: Equatable, Sendable {
    let guid: String
    let sanitizedURL: String
    let suggestedFilename: String
    let byteCount: Int
    let sha256: String
    let relativePath: String
    let fileURL: URL
}

enum BrowserCookieSameSite: String, Codable, CaseIterable, Sendable {
    case strict = "Strict"
    case lax = "Lax"
    case none = "None"
}

struct BrowserCookie: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Double?
    let size: Int?
    let httpOnly: Bool
    let secure: Bool
    let session: Bool
    let sameSite: BrowserCookieSameSite?
}

struct BrowserCookieInput: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var url: URL?
    var domain: String?
    var path: String?
    var secure: Bool
    var httpOnly: Bool
    var sameSite: BrowserCookieSameSite?
    var expires: Double?

    init(
        name: String,
        value: String,
        url: URL? = nil,
        domain: String? = nil,
        path: String? = nil,
        secure: Bool = false,
        httpOnly: Bool = false,
        sameSite: BrowserCookieSameSite? = nil,
        expires: Double? = nil
    ) {
        self.name = name
        self.value = value
        self.url = url
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.expires = expires
    }
}

struct BrowserJavaScriptResult: Equatable, Sendable {
    let type: String
    let subtype: String?
    let value: JSONValue?
    let description: String?
}
