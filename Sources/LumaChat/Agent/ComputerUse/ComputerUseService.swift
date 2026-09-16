import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ComputerUsePermissionStatus: Codable, Equatable, Sendable {
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool

    var isReady: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    static func current() -> Self {
        Self(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }
}

enum ComputerUsePolicy {
    static let maximumListedApplications = 64
    static let maximumListedWindows = 32
    static let maximumAccessibilityElements = 128
    static let maximumAccessibilityVisitedElements = 512
    static let maximumAccessibilityDepth = 12
    static let maximumAccessibilityTextBytes = 512
    static let maximumScreenshotDimension = 2_560
    static let maximumScreenshotBytes = AgentImageAttachmentLimits.maximumFileBytes
    static let maximumTypedTextBytes = 16 * 1_024
    static let maximumScrollMagnitude = 10_000

    private static let blockedBundleIdentifiers: Set<String> = [
        // Never let an Agent drive its own approval or settings surface.
        "com.lumachat.desktop",
        "com.openai.chat",
        "com.openai.codex",

        // Terminal automation could bypass the Agent's shell sandbox and
        // command approval path.
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",

        // Computer Use must not grant its own OS authority, authenticate as an
        // administrator, or inspect password/keychain stores.
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.loginwindow",
        "com.apple.securityagent",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.apple.installer"
    ]

    static func isBlocked(bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        return blockedBundleIdentifiers.contains(normalized)
    }

    static func validateTarget(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>
    ) throws -> String {
        let candidate = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.utf8.count <= AgentComputerUseSettingsLimits.maximumBundleIdentifierBytes,
              !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ComputerUseError.invalidBundleIdentifier
        }
        guard !isBlocked(bundleIdentifier: candidate) else {
            throw ComputerUseError.blockedApplication(candidate)
        }
        guard allowedBundleIdentifiers.contains(candidate) else {
            throw ComputerUseError.applicationNotAllowed(candidate)
        }
        return candidate
    }

    static func isValidScrollDelta(x: Int, y: Int) -> Bool {
        let allowed = -maximumScrollMagnitude ... maximumScrollMagnitude
        return allowed.contains(x) && allowed.contains(y) && (x != 0 || y != 0)
    }

    /// Background semantic actions deliberately expose a much smaller surface
    /// than arbitrary Accessibility actions. In particular, secure text fields,
    /// menus, windows, application objects, and model-selected AX action names
    /// can never reach `AXUIElementPerformAction`.
    static func supportsSemanticPress(role: String, subrole: String?) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        return [
            kAXButtonRole,
            kAXCheckBoxRole,
            kAXRadioButtonRole,
            kAXDisclosureTriangleRole,
            kAXLinkRole,
            kAXPopUpButtonRole
        ].contains(role)
    }

    static func supportsSemanticFocus(role: String, subrole: String?) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        return [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ].contains(role)
    }

    /// Keyboard text injection is intentionally narrower than general key
    /// input. A fresh capture may select the right window while the focused
    /// control changes after approval, so the service rechecks a small editable
    /// role allow-list and always refuses macOS secure text fields immediately
    /// before posting any Unicode events.
    static func supportsTextEntry(role: String, subrole: String?) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        return [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole
        ].contains(role)
    }
}

enum ComputerUseError: LocalizedError, Equatable, Sendable {
    case disabled
    case noAllowedApplications
    case invalidBundleIdentifier
    case applicationNotAllowed(String)
    case blockedApplication(String)
    case applicationNotRunning(String)
    case ambiguousApplication(String)
    case screenRecordingPermissionRequired
    case accessibilityPermissionRequired
    case noVisibleWindow(String)
    case ambiguousVisibleWindows(String, Int)
    case windowNotFound(UInt32)
    case staleWindow
    case invalidCoordinates
    case invalidScreenshotGeometry
    case invalidClick
    case invalidText
    case sensitiveText
    case unsupportedKey(String)
    case invalidModifiers
    case screenshotFailed
    case screenshotTooLarge(Int)
    case activationFailed(String)
    case eventCreationFailed
    case accessibilitySnapshotFailed
    case semanticElementNotFound
    case staleSemanticElement
    case unsupportedSemanticAction(String)
    case unsafeSemanticElement
    case unsafeTypingTarget

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Computer Use 尚未在 Agent 設定中啟用。"
        case .noAllowedApplications:
            "Computer Use 沒有允許的 App；請先在設定中加入完整 bundle identifier。"
        case .invalidBundleIdentifier:
            "Computer Use 的 bundle identifier 無效。"
        case .applicationNotAllowed(let identifier):
            "App「\(identifier)」不在 Computer Use 白名單中。"
        case .blockedApplication(let identifier):
            "基於安全限制，Computer Use 不會操作「\(identifier)」。"
        case .applicationNotRunning(let identifier):
            "找不到正在執行的「\(identifier)」。請先自行開啟 App。"
        case .ambiguousApplication(let identifier):
            "同時找到多個「\(identifier)」程序；為避免操作錯誤目標而拒絕。請只保留一個程序後重試。"
        case .screenRecordingPermissionRequired:
            "Computer Use 需要 macOS「螢幕錄製」權限才能觀察 App。請在系統設定授權 Luma Chat 後重試。"
        case .accessibilityPermissionRequired:
            "Computer Use 需要 macOS「輔助使用」權限才能操作 App。請在系統設定授權 Luma Chat 後重試。"
        case .noVisibleWindow(let application):
            "找不到「\(application)」可安全擷取的可見視窗。"
        case .ambiguousVisibleWindows(let application, let count):
            "「\(application)」有 \(count) 個可見視窗；請先列出視窗並使用明確的 window_id。"
        case .windowNotFound(let windowID):
            "找不到可安全操作的視窗 \(windowID)；請重新列出視窗。"
        case .staleWindow:
            "截圖已過期／使用過，或目標視窗已關閉、移動、縮放或屬於另一個 App；請重新擷取畫面。"
        case .invalidCoordinates:
            "點擊座標必須位於剛擷取的目標視窗畫面內。"
        case .invalidScreenshotGeometry:
            "點擊所附的 screenshot 尺寸無效；請重新擷取畫面。"
        case .invalidClick:
            "只支援左鍵或右鍵的一次／兩次點擊。"
        case .invalidText:
            "輸入文字為空、過大或含有不支援的 NUL 字元。"
        case .sensitiveText:
            "Computer Use 不會代替使用者輸入疑似密碼、Token 或其他秘密；請自行接管輸入。"
        case .unsupportedKey(let key):
            "Computer Use 不支援按鍵「\(key)」。"
        case .invalidModifiers:
            "Computer Use 的 modifier 只支援 command、shift、option、control。"
        case .screenshotFailed:
            "macOS 無法擷取目標視窗畫面。"
        case .screenshotTooLarge(let maximum):
            "擷取畫面超過 \(maximum) bytes 的安全上限。"
        case .activationFailed(let application):
            "無法安全切換到「\(application)」。"
        case .eventCreationFailed:
            "macOS 無法建立 Computer Use 輸入事件。"
        case .accessibilitySnapshotFailed:
            "無法安全讀取目標視窗的輔助使用語意結構。"
        case .semanticElementNotFound:
            "找不到指定的輔助使用元素；請重新讀取語意結構。"
        case .staleSemanticElement:
            "目標輔助使用元素已改變或移動；請重新擷取並讀取語意結構。"
        case .unsupportedSemanticAction(let action):
            "Computer Use 不支援輔助使用動作「\(action)」。"
        case .unsafeSemanticElement:
            "這個輔助使用元素不在 Computer Use 的背景安全角色白名單中。"
        case .unsafeTypingTarget:
            "Computer Use 只會輸入到所選視窗內目前聚焦、非密碼型的可編輯控制項；請重新擷取畫面或自行接管輸入。"
        }
    }
}

struct ComputerUseApplication: Codable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let isFrontmost: Bool
    let visibleWindowCount: Int
}

struct ComputerUseWindow: Codable, Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let windowID: UInt32
    let title: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isFrontmostApplication: Bool
}

struct ComputerUseAccessibilityElement: Codable, Equatable, Sendable {
    let elementID: UUID
    let role: String
    let subrole: String?
    let label: String?
    let identifier: String?
    let enabled: Bool
    let focused: Bool
    let selected: Bool?
    let actions: [String]
    let frameX: Double?
    let frameY: Double?
    let frameWidth: Double?
    let frameHeight: Double?
}

struct ComputerUseAccessibilitySnapshot: Codable, Equatable, Sendable {
    let captureID: UUID
    let windowID: UInt32
    let elements: [ComputerUseAccessibilityElement]
    let truncated: Bool
}

struct ComputerUseBackgroundVerification: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let windowID: UInt32
    let targetIsFrontmost: Bool
    let frontmostApplicationUnchanged: Bool
    let windowGeometryUnchanged: Bool
    let elementID: UUID?
    let elementStillMatches: Bool?

    var isBackgroundSafe: Bool {
        frontmostApplicationUnchanged && windowGeometryUnchanged
            && (elementStillMatches ?? true)
    }
}

/// A host-owned explanation of the narrow scope represented by an approval.
/// The model cannot opt a mutation into Always Allow by adding an argument:
/// eligibility is derived exclusively from a fixed tool-name allow-list.
struct ComputerUseApprovalScope: Equatable, Sendable {
    let bundleIdentifier: String?
    let windowID: UInt32?
    let elementID: UUID?
    let operation: String
    let isAlwaysAllowEligible: Bool

    var summary: String {
        var parts = [bundleIdentifier ?? "Computer Use"]
        if let windowID { parts.append("window \(windowID)") }
        if let elementID { parts.append("element \(elementID.uuidString.lowercased())") }
        parts.append(operation)
        return parts.joined(separator: " · ")
    }
}

enum ComputerUseScopedApprovalPolicy {
    private static let observationTools: Set<String> = [
        "computer_permission_status",
        "computer_list_apps",
        "computer_list_windows",
        "computer_screenshot",
        "computer_accessibility_snapshot",
        "computer_verify_state"
    ]
    private static let mutationTools: Set<String> = [
        "computer_semantic_action",
        "computer_activate_app",
        "computer_click",
        "computer_type_text",
        "computer_press_key",
        "computer_scroll"
    ]

    static func recognizes(toolName: String) -> Bool {
        observationTools.contains(toolName) || mutationTools.contains(toolName)
    }

    static func scope(
        toolName: String,
        arguments: JSONValue
    ) -> ComputerUseApprovalScope? {
        guard recognizes(toolName: toolName) else {
            return nil
        }
        let bundleIdentifier = arguments["bundle_identifier"]?.stringValue.flatMap {
            let candidate = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.utf8.count <= AgentComputerUseSettingsLimits.maximumBundleIdentifierBytes,
                  !candidate.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return nil
            }
            return candidate
        }
        let rawWindowID = arguments["window_id"]?.intValue
        let windowID = rawWindowID.flatMap(UInt32.init(exactly:))
        let elementID = arguments["element_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let captureID = arguments["capture_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let hasValidObservationScope: Bool
        switch toolName {
        case "computer_permission_status", "computer_list_apps":
            hasValidObservationScope = true
        case "computer_list_windows", "computer_screenshot":
            hasValidObservationScope = bundleIdentifier != nil
                && (rawWindowID == nil || windowID != nil)
        case "computer_accessibility_snapshot":
            hasValidObservationScope = bundleIdentifier != nil
                && captureID != nil
                && windowID != nil
        case "computer_verify_state":
            hasValidObservationScope = bundleIdentifier != nil
                && captureID != nil
                && windowID != nil
                && (arguments["element_id"] == nil || elementID != nil)
        default:
            hasValidObservationScope = false
        }
        return ComputerUseApprovalScope(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            elementID: elementID,
            operation: toolName.replacingOccurrences(of: "computer_", with: ""),
            isAlwaysAllowEligible: observationTools.contains(toolName)
                && hasValidObservationScope
        )
    }
}

struct ComputerUseScreenshot: Equatable, Sendable {
    let captureID: UUID
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let windowID: UInt32
    let windowTitle: String?
    let imageWidth: Int
    let imageHeight: Int
    let pngData: Data
}

protocol ComputerUseServicing: Sendable {
    func permissionStatus() async -> ComputerUsePermissionStatus
    func listApplications(
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseApplication]
    func listWindows(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseWindow]
    func capture(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        windowID: UInt32?
    ) async throws -> ComputerUseScreenshot
    func accessibilitySnapshot(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseAccessibilitySnapshot
    func verifyState(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        elementID: UUID?
    ) async throws -> ComputerUseBackgroundVerification
    func performSemanticAction(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        elementID: UUID,
        action: String
    ) async throws -> ComputerUseBackgroundVerification
    func activate(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseApplication
    func click(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        x: Double,
        y: Double,
        screenshotWidth: Int,
        screenshotHeight: Int,
        button: String,
        clickCount: Int
    ) async throws
    func typeText(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        text: String
    ) async throws
    func pressKey(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        key: String,
        modifiers: [String]
    ) async throws
    func scroll(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        deltaX: Int,
        deltaY: Int
    ) async throws
}

actor MacComputerUseService: ComputerUseServicing {
    private struct CaptureBinding: Sendable {
        let sessionID: UUID
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let windowID: CGWindowID
        let windowBounds: CGRect
        let imageWidth: Int
        let imageHeight: Int
        let createdAt: ContinuousClock.Instant
        var accessibilityElements: [UUID: AccessibilityBinding]
    }

    private struct AccessibilityBinding: Equatable, Sendable {
        let path: [Int]
        let role: String
        let subrole: String?
        let label: String?
        let identifier: String?
        let frame: CGRect?
        let actions: Set<String>
    }

    private struct AccessibilityTraversalItem {
        let element: AXUIElement
        let path: [Int]
        let depth: Int
    }

    private struct RunningTarget: Sendable {
        let name: String
        let bundleIdentifier: String
        let processIdentifier: pid_t
        let isFrontmost: Bool
    }

    private struct WindowTarget: Sendable {
        let id: CGWindowID
        let processIdentifier: pid_t
        let title: String?
        let bounds: CGRect
    }

    private var captureBindings: [UUID: CaptureBinding] = [:]

    func permissionStatus() -> ComputerUsePermissionStatus {
        .current()
    }

    func listApplications(
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseApplication] {
        guard !allowedBundleIdentifiers.isEmpty else {
            throw ComputerUseError.noAllowedApplications
        }
        let applications: [RunningTarget] = await MainActor.run { () -> [RunningTarget] in
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.activationPolicy == .regular,
                      application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      let identifier = application.bundleIdentifier,
                      allowedBundleIdentifiers.contains(identifier),
                      !ComputerUsePolicy.isBlocked(bundleIdentifier: identifier) else {
                    return nil
                }
                return RunningTarget(
                    name: application.localizedName ?? identifier,
                    bundleIdentifier: identifier,
                    processIdentifier: application.processIdentifier,
                    isFrontmost: application.processIdentifier == frontmostPID
                )
            }
        }
        let counts = visibleWindowCounts()
        return applications
            .prefix(ComputerUsePolicy.maximumListedApplications)
            .map { application in
                ComputerUseApplication(
                    name: application.name,
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    isFrontmost: application.isFrontmost,
                    visibleWindowCount: counts[application.processIdentifier, default: 0]
                )
            }
            .sorted {
                if $0.isFrontmost != $1.isFrontmost { return $0.isFrontmost }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func listWindows(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseWindow] {
        guard ComputerUsePermissionStatus.current().screenRecordingGranted else {
            throw ComputerUseError.screenRecordingPermissionRequired
        }
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        return visibleWindows(processIdentifier: application.processIdentifier)
            .prefix(ComputerUsePolicy.maximumListedWindows)
            .map { window in
                ComputerUseWindow(
                    applicationName: application.name,
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    windowID: window.id,
                    title: window.title,
                    x: Double(window.bounds.minX),
                    y: Double(window.bounds.minY),
                    width: Double(window.bounds.width),
                    height: Double(window.bounds.height),
                    isFrontmostApplication: application.isFrontmost
                )
            }
    }

    func capture(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        windowID requestedWindowID: UInt32?
    ) async throws -> ComputerUseScreenshot {
        guard ComputerUsePermissionStatus.current().screenRecordingGranted else {
            throw ComputerUseError.screenRecordingPermissionRequired
        }
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let windows = visibleWindows(processIdentifier: application.processIdentifier)
        guard !windows.isEmpty else {
            throw ComputerUseError.noVisibleWindow(application.name)
        }
        let window: WindowTarget
        if let requestedWindowID {
            guard let selected = windows.first(where: { $0.id == requestedWindowID }) else {
                throw ComputerUseError.windowNotFound(requestedWindowID)
            }
            window = selected
        } else {
            guard windows.count == 1, let selected = windows.first else {
                throw ComputerUseError.ambiguousVisibleWindows(application.name, windows.count)
            }
            window = selected
        }
        try Task.checkCancellation()
        let rawImage = try await captureImage(
            windowID: window.id,
            processIdentifier: application.processIdentifier
        )
        let image = try scaledImage(rawImage)
        let data = try pngData(image)
        guard data.count <= ComputerUsePolicy.maximumScreenshotBytes else {
            throw ComputerUseError.screenshotTooLarge(ComputerUsePolicy.maximumScreenshotBytes)
        }
        let captureID = UUID()
        retainCapture(
            id: captureID,
            binding: CaptureBinding(
                sessionID: sessionID,
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: application.processIdentifier,
                windowID: window.id,
                windowBounds: window.bounds,
                imageWidth: image.width,
                imageHeight: image.height,
                createdAt: ContinuousClock.now,
                accessibilityElements: [:]
            )
        )
        return ComputerUseScreenshot(
            captureID: captureID,
            applicationName: application.name,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowID: window.id,
            windowTitle: window.title,
            imageWidth: image.width,
            imageHeight: image.height,
            pngData: data
        )
    }

    func accessibilitySnapshot(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseAccessibilitySnapshot {
        try requireObservationAndAccessibility()
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        _ = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard var capture = validCaptureBinding(id: captureID) else {
            throw ComputerUseError.staleWindow
        }
        let accessibilityWindow = try accessibilityWindow(
            processIdentifier: application.processIdentifier,
            expectedBounds: capture.windowBounds,
            expectedTitle: visibleWindow(
                processIdentifier: application.processIdentifier,
                windowID: windowID
            )?.title
        )
        let snapshot = accessibilityElements(
            in: accessibilityWindow,
            capture: capture
        )
        _ = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard validCaptureBinding(id: captureID) != nil else {
            throw ComputerUseError.staleWindow
        }
        capture.accessibilityElements = snapshot.bindings
        captureBindings[captureID] = capture
        return ComputerUseAccessibilitySnapshot(
            captureID: captureID,
            windowID: windowID,
            elements: snapshot.elements,
            truncated: snapshot.truncated
        )
    }

    func verifyState(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        elementID: UUID?
    ) async throws -> ComputerUseBackgroundVerification {
        try requireObservationAndAccessibility()
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let frontmostBefore = await frontmostProcessIdentifier()
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        var semanticBinding: AccessibilityBinding?
        if let elementID {
            guard let capture = validCaptureBinding(id: captureID),
                  let binding = capture.accessibilityElements[elementID] else {
                throw ComputerUseError.semanticElementNotFound
            }
            let accessibilityWindow = try accessibilityWindow(
                processIdentifier: application.processIdentifier,
                expectedBounds: window.bounds,
                expectedTitle: window.title
            )
            _ = try resolveAccessibilityElement(
                binding,
                in: accessibilityWindow
            )
            semanticBinding = binding
        }
        try Task.checkCancellation()
        let frontmostAfter = await frontmostProcessIdentifier()
        let currentWindow = try? validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        let geometryUnchanged = currentWindow != nil
        var elementStillMatches: Bool?
        if let semanticBinding {
            guard let currentWindow else {
                elementStillMatches = false
                return ComputerUseBackgroundVerification(
                    bundleIdentifier: application.bundleIdentifier,
                    processIdentifier: application.processIdentifier,
                    windowID: windowID,
                    targetIsFrontmost: frontmostAfter == application.processIdentifier,
                    frontmostApplicationUnchanged: frontmostBefore == frontmostAfter,
                    windowGeometryUnchanged: false,
                    elementID: elementID,
                    elementStillMatches: false
                )
            }
            let currentAXWindow = try? accessibilityWindow(
                processIdentifier: application.processIdentifier,
                expectedBounds: currentWindow.bounds,
                expectedTitle: currentWindow.title
            )
            elementStillMatches = currentAXWindow.flatMap {
                try? resolveAccessibilityElement(semanticBinding, in: $0)
            } != nil
        }
        return ComputerUseBackgroundVerification(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowID: windowID,
            targetIsFrontmost: frontmostAfter == application.processIdentifier,
            frontmostApplicationUnchanged: frontmostBefore == frontmostAfter,
            windowGeometryUnchanged: geometryUnchanged,
            elementID: elementID,
            elementStillMatches: elementStillMatches
        )
    }

    func performSemanticAction(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        elementID: UUID,
        action rawAction: String
    ) async throws -> ComputerUseBackgroundVerification {
        try requireObservationAndAccessibility()
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard let capture = validCaptureBinding(id: captureID),
              let binding = capture.accessibilityElements[elementID] else {
            throw ComputerUseError.semanticElementNotFound
        }
        let accessibilityWindow = try accessibilityWindow(
            processIdentifier: application.processIdentifier,
            expectedBounds: window.bounds,
            expectedTitle: window.title
        )
        _ = try resolveAccessibilityElement(binding, in: accessibilityWindow)
        let action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let frontmostBefore = await frontmostProcessIdentifier()
        let revalidatedWindow = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard let currentCapture = validCaptureBinding(id: captureID),
              currentCapture.accessibilityElements[elementID] == binding else {
            throw ComputerUseError.staleSemanticElement
        }
        let currentAXWindow = try accessibilityWindow(
            processIdentifier: application.processIdentifier,
            expectedBounds: revalidatedWindow.bounds,
            expectedTitle: revalidatedWindow.title
        )
        let element = try resolveAccessibilityElement(binding, in: currentAXWindow)
        guard booleanAttribute(kAXEnabledAttribute, from: element) ?? true else {
            throw ComputerUseError.staleSemanticElement
        }
        let result: AXError
        switch action {
        case "press":
            guard ComputerUsePolicy.supportsSemanticPress(
                role: binding.role,
                subrole: binding.subrole
            ), binding.actions.contains("press"),
            accessibilityActionNames(element).contains(kAXPressAction as String) else {
                throw ComputerUseError.unsafeSemanticElement
            }
            result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case "focus":
            guard ComputerUsePolicy.supportsSemanticFocus(
                role: binding.role,
                subrole: binding.subrole
            ), binding.actions.contains("focus"),
            isAttributeSettable(kAXFocusedAttribute, on: element) else {
                throw ComputerUseError.unsafeSemanticElement
            }
            result = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        default:
            throw ComputerUseError.unsupportedSemanticAction(rawAction)
        }
        // Consume before yielding. Even a failed AX call may have reached the
        // target process, so retry requires a new observation and approval.
        captureBindings.removeValue(forKey: captureID)
        guard result == .success else { throw ComputerUseError.staleSemanticElement }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(80))

        let frontmostAfter = await frontmostProcessIdentifier()
        let currentWindow = visibleWindow(
            processIdentifier: application.processIdentifier,
            windowID: windowID
        )
        let geometryUnchanged = currentWindow.map {
            approximatelyEqual(window.bounds, $0.bounds)
        } ?? false
        var elementMatches = false
        if geometryUnchanged,
           let currentWindow,
           let currentAXWindow = try? accessibilityWindow(
               processIdentifier: application.processIdentifier,
               expectedBounds: currentWindow.bounds,
               expectedTitle: currentWindow.title
           ),
           (try? resolveAccessibilityElement(binding, in: currentAXWindow)) != nil {
            elementMatches = true
        }
        return ComputerUseBackgroundVerification(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            windowID: windowID,
            targetIsFrontmost: frontmostAfter == application.processIdentifier,
            frontmostApplicationUnchanged: frontmostBefore == frontmostAfter,
            windowGeometryUnchanged: geometryUnchanged,
            elementID: elementID,
            elementStillMatches: elementMatches
        )
    }

    func activate(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseApplication {
        try requireObservationAndAccessibility()
        let target = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: target,
            windowID: windowID
        )
        try await activate(target, window: window)
        _ = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: target,
            windowID: windowID
        )
        captureBindings.removeValue(forKey: captureID)
        return ComputerUseApplication(
            name: target.name,
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            isFrontmost: true,
            visibleWindowCount: visibleWindowCounts()[target.processIdentifier, default: 0]
        )
    }

    func click(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        x: Double,
        y: Double,
        screenshotWidth: Int,
        screenshotHeight: Int,
        button: String,
        clickCount: Int
    ) async throws {
        try requireObservationAndAccessibility()
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        guard screenshotWidth > 0, screenshotHeight > 0,
              screenshotWidth <= AgentImageAttachmentLimits.maximumDimension,
              screenshotHeight <= AgentImageAttachmentLimits.maximumDimension else {
            throw ComputerUseError.invalidScreenshotGeometry
        }
        guard x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < Double(screenshotWidth), y < Double(screenshotHeight) else {
            throw ComputerUseError.invalidCoordinates
        }
        let capturedWindow = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID,
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight
        )
        let normalizedButton = button.lowercased()
        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch normalizedButton {
        case "left":
            mouseButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case "right":
            mouseButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        default:
            throw ComputerUseError.invalidClick
        }
        guard (1 ... 2).contains(clickCount) else { throw ComputerUseError.invalidClick }
        try await activate(application, window: capturedWindow)
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID,
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight
        )
        let point = CGPoint(
            x: window.bounds.minX + x / Double(screenshotWidth) * window.bounds.width,
            y: window.bounds.minY + y / Double(screenshotHeight) * window.bounds.height
        )
        guard window.bounds.contains(point),
              let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                  mouseEventSource: source,
                  mouseType: downType,
                  mouseCursorPosition: point,
                  mouseButton: mouseButton
              ),
              let mouseUp = CGEvent(
                  mouseEventSource: source,
                  mouseType: upType,
                  mouseCursorPosition: point,
                  mouseButton: mouseButton
              ) else {
            throw ComputerUseError.eventCreationFailed
        }
        mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        try Task.checkCancellation()
        // A coordinate-bearing capture is single-use. Every subsequent click
        // must be based on a fresh observation of the target window.
        captureBindings.removeValue(forKey: captureID)
        mouseDown.postToPid(application.processIdentifier)
        mouseUp.postToPid(application.processIdentifier)
    }

    func typeText(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        text: String
    ) async throws {
        try requireObservationAndAccessibility()
        guard !text.isEmpty,
              text.utf8.count <= ComputerUsePolicy.maximumTypedTextBytes,
              !text.contains("\0") else {
            throw ComputerUseError.invalidText
        }
        guard SecretRedactor().redact(text) == text else {
            throw ComputerUseError.sensitiveText
        }
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        try await activate(application, window: window)
        _ = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        try requireSafeFocusedTypingTarget(
            processIdentifier: application.processIdentifier,
            expectedWindow: window
        )
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.eventCreationFailed
        }
        captureBindings.removeValue(forKey: captureID)
        for chunk in unicodeChunks(text, maximumUTF16Units: 32) {
            try Task.checkCancellation()
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                throw ComputerUseError.eventCreationFailed
            }
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.postToPid(application.processIdentifier)
            keyUp.postToPid(application.processIdentifier)
        }
    }

    func pressKey(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        key: String,
        modifiers: [String]
    ) async throws {
        try requireObservationAndAccessibility()
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let keyCode = try virtualKeyCode(key)
        let flags = try eventFlags(modifiers)
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        try await activate(application, window: window)
        _ = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: true
              ), let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: false
              ) else {
            throw ComputerUseError.eventCreationFailed
        }
        keyDown.flags = flags
        keyUp.flags = flags
        try Task.checkCancellation()
        captureBindings.removeValue(forKey: captureID)
        keyDown.postToPid(application.processIdentifier)
        keyUp.postToPid(application.processIdentifier)
    }

    func scroll(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        deltaX: Int,
        deltaY: Int
    ) async throws {
        try requireObservationAndAccessibility()
        guard ComputerUsePolicy.isValidScrollDelta(x: deltaX, y: deltaY) else {
            throw ComputerUseError.invalidCoordinates
        }
        let application = try await runningTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let capturedWindow = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        try await activate(application, window: capturedWindow)
        let window = try validateCapture(
            sessionID: sessionID,
            captureID: captureID,
            application: application,
            windowID: windowID
        )
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .pixel,
                  wheelCount: 2,
                  wheel1: Int32(clamping: deltaY),
                  wheel2: Int32(clamping: deltaX),
                  wheel3: 0
              ) else {
            throw ComputerUseError.eventCreationFailed
        }
        event.location = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        try Task.checkCancellation()
        captureBindings.removeValue(forKey: captureID)
        event.postToPid(application.processIdentifier)
    }

    private func runningTarget(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>
    ) async throws -> RunningTarget {
        let identifier = try ComputerUsePolicy.validateTarget(
            bundleIdentifier: bundleIdentifier,
            allowedBundleIdentifiers: allowedBundleIdentifiers
        )
        let targets: [RunningTarget] = await MainActor.run {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == identifier
                    && $0.activationPolicy == .regular
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }.map { application in
                RunningTarget(
                    name: application.localizedName ?? identifier,
                    bundleIdentifier: identifier,
                    processIdentifier: application.processIdentifier,
                    isFrontmost: application.processIdentifier == frontmostPID
                )
            }
        }
        guard let target = targets.first else {
            throw ComputerUseError.applicationNotRunning(identifier)
        }
        guard targets.count == 1 else {
            throw ComputerUseError.ambiguousApplication(identifier)
        }
        return target
    }

    private func activate(_ target: RunningTarget, window: WindowTarget) async throws {
        try Task.checkCancellation()
        let accessibilityWindow = try accessibilityWindow(
            processIdentifier: target.processIdentifier,
            expectedBounds: window.bounds,
            expectedTitle: window.title
        )
        guard AXUIElementPerformAction(
            accessibilityWindow,
            kAXRaiseAction as CFString
        ) == .success else {
            throw ComputerUseError.activationFailed(target.name)
        }
        let requested = await MainActor.run {
            guard let application = NSRunningApplication(
                processIdentifier: target.processIdentifier
            ), application.bundleIdentifier == target.bundleIdentifier else {
                return false
            }
            return application.activate(options: [])
        }
        guard requested else { throw ComputerUseError.activationFailed(target.name) }
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        let isFrontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier
        }
        guard isFrontmost else { throw ComputerUseError.activationFailed(target.name) }
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: applicationElement
        ), let focusedBounds = accessibilityFrame(focusedWindow),
              approximatelyEqual(focusedBounds, window.bounds) else {
            throw ComputerUseError.activationFailed(target.name)
        }
    }

    private func frontmostProcessIdentifier() async -> pid_t? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    }

    private func requireSafeFocusedTypingTarget(
        processIdentifier: pid_t,
        expectedWindow: WindowTarget
    ) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let focusedWindow = elementAttribute(
                  kAXFocusedWindowAttribute,
                  from: application
              ),
              let focusedWindowBounds = accessibilityFrame(focusedWindow),
              approximatelyEqual(focusedWindowBounds, expectedWindow.bounds),
              let focusedElement = elementAttribute(
                  kAXFocusedUIElementAttribute,
                  from: application
              ) else {
            throw ComputerUseError.unsafeTypingTarget
        }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &focusedPID) == .success,
              focusedPID == processIdentifier else {
            throw ComputerUseError.unsafeTypingTarget
        }
        let role = stringAttribute(kAXRoleAttribute, from: focusedElement) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: focusedElement)
        guard ComputerUsePolicy.supportsTextEntry(role: role, subrole: subrole),
              let frame = accessibilityFrame(focusedElement),
              !frame.isEmpty,
              frame.intersects(expectedWindow.bounds) else {
            throw ComputerUseError.unsafeTypingTarget
        }
    }

    private func requireObservationAndAccessibility() throws {
        let status = ComputerUsePermissionStatus.current()
        guard status.screenRecordingGranted else {
            captureBindings.removeAll()
            throw ComputerUseError.screenRecordingPermissionRequired
        }
        guard status.accessibilityGranted else {
            captureBindings.removeAll()
            throw ComputerUseError.accessibilityPermissionRequired
        }
    }

    private func windowInfo() -> [[CFString: Any]] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }
        return raw
    }

    private func visibleWindowCounts() -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for item in windowInfo() {
            guard let target = windowTarget(item), target.bounds.width >= 40,
                  target.bounds.height >= 40 else { continue }
            counts[target.processIdentifier, default: 0] += 1
        }
        return counts
    }

    private func visibleWindows(processIdentifier: pid_t) -> [WindowTarget] {
        windowInfo()
            .compactMap(windowTarget)
            .filter {
                $0.processIdentifier == processIdentifier
                    && $0.bounds.width >= 40
                    && $0.bounds.height >= 40
            }
    }

    private func visibleWindow(
        processIdentifier: pid_t,
        windowID: CGWindowID
    ) -> WindowTarget? {
        visibleWindows(processIdentifier: processIdentifier).first {
            $0.id == windowID
        }
    }

    private func accessibilityWindow(
        processIdentifier: pid_t,
        expectedBounds: CGRect,
        expectedTitle: String?
    ) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        let windows = elementArrayAttribute(kAXWindowsAttribute, from: application)
        var candidates = windows.filter {
            guard let frame = accessibilityFrame($0) else { return false }
            return approximatelyEqual(frame, expectedBounds)
        }
        if candidates.count > 1, let expectedTitle {
            candidates = candidates.filter {
                stringAttribute(kAXTitleAttribute, from: $0) == expectedTitle
            }
        }
        guard candidates.count == 1, let window = candidates.first else {
            throw ComputerUseError.accessibilitySnapshotFailed
        }
        return window
    }

    private func accessibilityElements(
        in window: AXUIElement,
        capture: CaptureBinding
    ) -> (
        elements: [ComputerUseAccessibilityElement],
        bindings: [UUID: AccessibilityBinding],
        truncated: Bool
    ) {
        var elements: [ComputerUseAccessibilityElement] = []
        var bindings: [UUID: AccessibilityBinding] = [:]
        var queue = [AccessibilityTraversalItem(element: window, path: [], depth: 0)]
        var cursor = 0
        var visited = Set<CFHashCode>()
        var truncated = false
        let maximumVisited = ComputerUsePolicy.maximumAccessibilityVisitedElements

        while cursor < queue.count,
              cursor < maximumVisited,
              elements.count < ComputerUsePolicy.maximumAccessibilityElements {
            let item = queue[cursor]
            cursor += 1
            guard visited.insert(CFHash(item.element)).inserted else { continue }

            let role = stringAttribute(kAXRoleAttribute, from: item.element) ?? ""
            let subrole = stringAttribute(kAXSubroleAttribute, from: item.element)
            let frame = accessibilityFrame(item.element)
            let rawActions = accessibilityActionNames(item.element)
            var actions: [String] = []
            if rawActions.contains(kAXPressAction as String),
               ComputerUsePolicy.supportsSemanticPress(role: role, subrole: subrole) {
                actions.append("press")
            }
            if isAttributeSettable(kAXFocusedAttribute, on: item.element),
               ComputerUsePolicy.supportsSemanticFocus(role: role, subrole: subrole) {
                actions.append("focus")
            }

            let isInsideWindow = frame.map {
                !$0.isEmpty && $0.intersects(capture.windowBounds)
            } ?? false
            if !actions.isEmpty, isInsideWindow {
                let id = UUID()
                let label = semanticLabel(item.element)
                let identifier = boundedAccessibilityText(
                    stringAttribute(kAXIdentifierAttribute, from: item.element)
                )
                let relativeFrame = frame.map {
                    CGRect(
                        x: ($0.minX - capture.windowBounds.minX)
                            / capture.windowBounds.width * CGFloat(capture.imageWidth),
                        y: ($0.minY - capture.windowBounds.minY)
                            / capture.windowBounds.height * CGFloat(capture.imageHeight),
                        width: $0.width / capture.windowBounds.width
                            * CGFloat(capture.imageWidth),
                        height: $0.height / capture.windowBounds.height
                            * CGFloat(capture.imageHeight)
                    )
                }
                let normalizedActions = actions.sorted()
                elements.append(
                    ComputerUseAccessibilityElement(
                        elementID: id,
                        role: role,
                        subrole: subrole,
                        label: label,
                        identifier: identifier,
                        enabled: booleanAttribute(
                            kAXEnabledAttribute,
                            from: item.element
                        ) ?? true,
                        focused: booleanAttribute(
                            kAXFocusedAttribute,
                            from: item.element
                        ) ?? false,
                        selected: booleanAttribute(
                            kAXSelectedAttribute,
                            from: item.element
                        ),
                        actions: normalizedActions,
                        frameX: relativeFrame.map { Double($0.minX) },
                        frameY: relativeFrame.map { Double($0.minY) },
                        frameWidth: relativeFrame.map { Double($0.width) },
                        frameHeight: relativeFrame.map { Double($0.height) }
                    )
                )
                bindings[id] = AccessibilityBinding(
                    path: item.path,
                    role: role,
                    subrole: subrole,
                    label: label,
                    identifier: identifier,
                    frame: frame,
                    actions: Set(normalizedActions)
                )
            }

            guard item.depth < ComputerUsePolicy.maximumAccessibilityDepth else {
                if !elementArrayAttribute(kAXChildrenAttribute, from: item.element).isEmpty {
                    truncated = true
                }
                continue
            }
            let children = elementArrayAttribute(kAXChildrenAttribute, from: item.element)
            if children.count > 128 { truncated = true }
            for (index, child) in children.prefix(128).enumerated() {
                queue.append(
                    AccessibilityTraversalItem(
                        element: child,
                        path: item.path + [index],
                        depth: item.depth + 1
                    )
                )
            }
        }
        if cursor < queue.count { truncated = true }
        return (elements, bindings, truncated)
    }

    private func resolveAccessibilityElement(
        _ binding: AccessibilityBinding,
        in window: AXUIElement
    ) throws -> AXUIElement {
        var element = window
        for index in binding.path {
            let children = elementArrayAttribute(kAXChildrenAttribute, from: element)
            guard children.indices.contains(index) else {
                throw ComputerUseError.staleSemanticElement
            }
            element = children[index]
        }
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let identifier = boundedAccessibilityText(
            stringAttribute(kAXIdentifierAttribute, from: element)
        )
        let label = semanticLabel(element)
        let frame = accessibilityFrame(element)
        guard role == binding.role,
              subrole == binding.subrole,
              identifier == binding.identifier,
              label == binding.label,
              framesMatch(frame, binding.frame) else {
            throw ComputerUseError.staleSemanticElement
        }
        return element
    }

    private func framesMatch(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): approximatelyEqual(lhs, rhs)
        default: false
        }
    }

    private func semanticLabel(_ element: AXUIElement) -> String? {
        for attribute in [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXRoleDescriptionAttribute
        ] {
            if let value = boundedAccessibilityText(
                stringAttribute(attribute, from: element)
            ), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func boundedAccessibilityText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        var result = ""
        var byteCount = 0
        for scalar in rawValue.unicodeScalars.prefix(
            ComputerUsePolicy.maximumAccessibilityTextBytes * 2
        ) {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let value = String(scalar)
            let bytes = value.utf8.count
            guard byteCount + bytes <= ComputerUsePolicy.maximumAccessibilityTextBytes else {
                break
            }
            result.append(value)
            byteCount += bytes
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private func elementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    private func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private func booleanAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return (rawValue as? NSNumber)?.boolValue
    }

    private func accessibilityActionNames(_ element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let values = names as? [String] else {
            return []
        }
        return Set(values)
    }

    private func isAttributeSettable(
        _ attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &rawSize
        ) == .success,
        let rawPosition,
        let rawSize,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func retainCapture(id: UUID, binding: CaptureBinding) {
        pruneCaptureBindings()
        // The provider sends only a bounded number of recent images. Keep one
        // authoritative observation per Agent session so a visible old token
        // can never outlive the image bytes it described.
        captureBindings = captureBindings.filter { $0.value.sessionID != binding.sessionID }
        captureBindings[id] = binding
    }

    private func validCaptureBinding(id: UUID) -> CaptureBinding? {
        pruneCaptureBindings()
        return captureBindings[id]
    }

    private func pruneCaptureBindings() {
        let now = ContinuousClock.now
        captureBindings = captureBindings.filter {
            $0.value.createdAt.duration(to: now) <= .seconds(30)
        }
    }

    private func validateCapture(
        sessionID: UUID,
        captureID: UUID,
        application: RunningTarget,
        windowID: CGWindowID,
        screenshotWidth: Int? = nil,
        screenshotHeight: Int? = nil
    ) throws -> WindowTarget {
        guard let binding = validCaptureBinding(id: captureID),
              binding.sessionID == sessionID,
              binding.bundleIdentifier == application.bundleIdentifier,
              binding.processIdentifier == application.processIdentifier,
              binding.windowID == windowID,
              screenshotWidth.map({ $0 == binding.imageWidth }) ?? true,
              screenshotHeight.map({ $0 == binding.imageHeight }) ?? true else {
            throw ComputerUseError.staleWindow
        }
        guard let window = visibleWindow(
                  processIdentifier: application.processIdentifier,
                  windowID: windowID
              ),
              approximatelyEqual(binding.windowBounds, window.bounds) else {
            throw ComputerUseError.staleWindow
        }
        return window
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private func captureImage(
        windowID: CGWindowID,
        processIdentifier: pid_t
    ) async throws -> CGImage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            try Task.checkCancellation()
            guard let window = content.windows.first(where: {
                $0.windowID == windowID
                    && $0.owningApplication?.processID == processIdentifier
                    && $0.isOnScreen
                    && $0.windowLayer == 0
            }) else {
                throw ComputerUseError.staleWindow
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let nativeWidth = max(
                1,
                Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let nativeHeight = max(
                1,
                Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded(.up))
            )
            let longest = max(nativeWidth, nativeHeight)
            let scale = min(
                1,
                Double(ComputerUsePolicy.maximumScreenshotDimension) / Double(longest)
            )
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((Double(nativeWidth) * scale).rounded(.down)))
            configuration.height = max(1, Int((Double(nativeHeight) * scale).rounded(.down)))
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ComputerUseError {
            throw error
        } catch {
            throw ComputerUseError.screenshotFailed
        }
    }

    private func windowTarget(_ item: [CFString: Any]) -> WindowTarget? {
        guard (item[kCGWindowLayer] as? NSNumber)?.intValue == 0,
              (item[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1 > 0,
              let rawPID = (item[kCGWindowOwnerPID] as? NSNumber)?.intValue,
              let rawID = (item[kCGWindowNumber] as? NSNumber)?.uint32Value,
              let rawBounds = item[kCGWindowBounds] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
              bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let rawTitle = (item[kCGWindowName] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.map {
            String(
                $0.unicodeScalars
                    .filter { !CharacterSet.controlCharacters.contains($0) }
                    .map(String.init)
                    .joined()
                    .prefix(512)
            )
        }
        return WindowTarget(
            id: rawID,
            processIdentifier: pid_t(rawPID),
            title: title?.isEmpty == false ? title : nil,
            bounds: bounds
        )
    }

    private func scaledImage(_ image: CGImage) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > ComputerUsePolicy.maximumScreenshotDimension else { return image }
        let scale = Double(ComputerUsePolicy.maximumScreenshotDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ComputerUseError.screenshotFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw ComputerUseError.screenshotFailed
        }
        return output
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ComputerUseError.screenshotFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ComputerUseError.screenshotFailed
        }
        return mutable as Data
    }

    private func unicodeChunks(
        _ text: String,
        maximumUTF16Units: Int
    ) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maximumUTF16Units {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func virtualKeyCode(_ rawKey: String) throws -> CGKeyCode {
        switch rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "return", "enter": 36
        case "tab": 48
        case "space": 49
        case "delete", "backspace": 51
        case "escape", "esc": 53
        case "home": 115
        case "page_up", "pageup": 116
        case "forward_delete": 117
        case "end": 119
        case "page_down", "pagedown": 121
        case "left": 123
        case "right": 124
        case "down": 125
        case "up": 126
        default: throw ComputerUseError.unsupportedKey(rawKey)
        }
    }

    private func eventFlags(_ modifiers: [String]) throws -> CGEventFlags {
        guard modifiers.count <= 4 else { throw ComputerUseError.invalidModifiers }
        var flags: CGEventFlags = []
        var seen = Set<String>()
        for rawModifier in modifiers {
            let modifier = rawModifier.lowercased()
            guard seen.insert(modifier).inserted else { continue }
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            default: throw ComputerUseError.invalidModifiers
            }
        }
        return flags
    }
}
