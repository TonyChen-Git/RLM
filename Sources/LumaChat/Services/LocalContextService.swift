import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A local application whose visible or selected text can be attached to a chat.
///
/// `LocalContextService` never captures any of these sources automatically. The
/// caller should invoke `capture(_:)` only as the direct result of a user action.
enum LocalContextSource: String, CaseIterable, Identifiable, Sendable {
    case currentSelection
    case terminal
    case notes
    case textEdit
    case visualStudioCode
    case xcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSelection: "目前選取內容"
        case .terminal: "Terminal"
        case .notes: "備忘錄"
        case .textEdit: "文字編輯"
        case .visualStudioCode: "Visual Studio Code"
        case .xcode: "Xcode"
        }
    }

    var subtitle: String {
        switch self {
        case .currentSelection: "擷取上一個使用中 App 的選取文字"
        case .terminal: "僅擷取目前畫面；不允許連接或修改"
        case .notes: "即時讀取目前備忘錄；為保留格式，不覆寫全文"
        case .textEdit: "即時讀取；純文字文件可直接修改，Rich Text 僅讀取"
        case .visualStudioCode: "即時讀取目前程式碼文件，可直接修改"
        case .xcode: "即時讀取目前程式碼文件，可直接修改"
        }
    }

    var systemImage: String {
        switch self {
        case .currentSelection: "selection.pin.in.out"
        case .terminal: "terminal"
        case .notes: "note.text"
        case .textEdit: "doc.plaintext"
        case .visualStudioCode: "chevron.left.forwardslash.chevron.right"
        case .xcode: "hammer"
        }
    }

    /// Writing is intentionally limited to text editors with a real selection.
    /// `currentSelection` is checked again at runtime so it cannot target a terminal.
    var isWritable: Bool {
        self != .terminal
    }

    /// Live document access is deliberately allow-listed. `currentSelection`
    /// can refer to an arbitrary application, so it remains selection-only.
    var supportsLiveDocumentAccess: Bool {
        switch self {
        case .notes, .textEdit, .visualStudioCode, .xcode: true
        case .currentSelection, .terminal: false
        }
    }

    /// Whole-document replacement is intentionally narrower than live reads.
    /// Notes bodies are rich documents that may contain formatting, checklists,
    /// links, drawings, and attachments; replacing their AXValue with a String
    /// would irreversibly flatten those objects. Notes remains readable and its
    /// explicit text selection can still be replaced.
    var supportsGuardedDocumentWrite: Bool {
        switch self {
        case .textEdit, .visualStudioCode, .xcode: true
        case .currentSelection, .terminal, .notes: false
        }
    }

    /// IDE accessibility trees may expose only the visible viewport as AXValue
    /// while reporting a matching character count, and can omit the final line
    /// ending. Their guarded read path therefore always uses Select All + Copy,
    /// with document identity checks before and after the operation.
    var requiresLosslessClipboardDocumentRead: Bool {
        switch self {
        case .visualStudioCode, .xcode: true
        case .currentSelection, .terminal, .notes, .textEdit: false
        }
    }

    fileprivate var bundleIdentifiers: [String] {
        switch self {
        case .currentSelection: []
        case .terminal:
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
                "com.mitchellh.ghostty",
                "org.alacritty",
                "net.kovidgoyal.kitty",
                "com.github.wez.wezterm"
            ]
        case .notes: ["com.apple.Notes"]
        case .textEdit: ["com.apple.TextEdit"]
        case .visualStudioCode:
            ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .xcode: ["com.apple.dt.Xcode"]
        }
    }
}

/// A lightweight identity for a running, allow-listed editor. The connection
/// stores no document contents: every read resolves the process again and asks
/// the target application for its currently focused document.
struct LocalAppConnection: Identifiable, Hashable, Sendable {
    let source: LocalContextSource
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let applicationName: String

    var id: String {
        "\(bundleIdentifier):\(processIdentifier)"
    }
}

/// Identity of the actual document that was read, not just its host app. A
/// stable identifier is normally a file URL/path (editors), a Notes object ID,
/// or TextEdit's document path. `isStable` is false when macOS exposes only a
/// window title; guarded writes refuse such an identity.
struct LocalDocumentIdentity: Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let identifier: String
    let isStable: Bool
}

/// An in-memory, point-in-time view of the connected app's active document.
/// It is never persisted by `LocalContextService`.
struct LocalDocumentSnapshot: Sendable {
    let connection: LocalAppConnection
    let identity: LocalDocumentIdentity
    let documentTitle: String?
    let text: String
    let contentDigest: String
    let capturedAt: Date

    var characterCount: Int { text.count }

    /// A request-only, in-memory attachment. `relativePath` and `data` are nil,
    /// so no context file is created. The caller should regenerate this from a
    /// freshly read snapshot for each model request instead of storing it.
    var requestAttachment: PreparedAttachment {
        let trimmedTitle = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmedTitle?.isEmpty == false ? trimmedTitle! : connection.source.title)
            + " · 即時文件"
        let attachment = ChatAttachment(
            name: name,
            relativePath: nil,
            mimeType: "text/plain; charset=utf-8",
            kind: .capturedContext,
            byteCount: Int64(text.utf8.count),
            extractedText: text,
            sourceLabel: "\(connection.applicationName) · 即時文件"
        )
        return PreparedAttachment(attachment: attachment, data: nil)
    }
}

enum LocalContextError: LocalizedError, Sendable {
    case applicationNotRunning(String)
    case noPreviousApplication
    case noReadableContent(String)
    case nothingSelected(String)
    case accessibilityPermissionRequired
    case automationPermissionRequired(String)
    case appleScriptFailed(String, String)
    case clipboardCopyFailed(String)
    case sourceNotWritable(String)
    case selectionReplacementFailed(String)
    case liveDocumentAccessUnsupported(String)
    case connectionLost(String)
    case documentNotFocused(String)
    case documentTooLarge(String, actual: Int, limit: Int)
    case replacementTooLarge(actual: Int, limit: Int)
    case invalidReplacement
    case documentReplacementFailed(String)
    case documentIdentityUnavailable(String)
    case documentChanged(String)
    case wholeDocumentWriteUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotRunning(let application):
            "找不到正在執行的 \(application)。請先開啟 App 後再試一次。"
        case .noPreviousApplication:
            "找不到上一個使用中的 App。請先在其他 App 選取文字，再回來擷取。"
        case .noReadableContent(let source):
            "無法從 \(source) 讀到文字內容。請確認文件或視窗已開啟，並將游標留在要讀取的位置。"
        case .nothingSelected(let application):
            "\(application) 目前沒有可擷取的選取文字。請先選取內容後再試一次。"
        case .accessibilityPermissionRequired:
            "需要「輔助使用」權限才能讀取選取內容。請到「系統設定 > 隱私權與安全性 > 輔助使用」允許 LumaChat，然後重試。"
        case .automationPermissionRequired(let application):
            "需要「自動化」權限才能讀取 \(application)。請到「系統設定 > 隱私權與安全性 > 自動化」允許 LumaChat，然後重試。"
        case .appleScriptFailed(let application, let detail):
            "無法讀取 \(application)：\(detail)"
        case .clipboardCopyFailed(let application):
            "無法從 \(application) 複製選取文字；原本的剪貼簿內容已還原。"
        case .sourceNotWritable(let application):
            "基於安全考量，LumaChat 不會修改 \(application) 的內容。請改用備忘錄、TextEdit、VS Code 或 Xcode 的文字選取範圍。"
        case .selectionReplacementFailed(let application):
            "無法取代 \(application) 的選取文字；原本的剪貼簿內容已還原。請確認文字仍被選取後再試一次。"
        case .liveDocumentAccessUnsupported(let application):
            "\(application) 不支援即時文件連接。即時讀寫僅限備忘錄、TextEdit、Visual Studio Code 與 Xcode；Terminal 永遠不允許修改。"
        case .connectionLost(let application):
            "與 \(application) 的連接已中斷。請確認 App 仍在執行，然後重新連接。"
        case .documentNotFocused(let application):
            "找不到 \(application) 目前作用中的可編輯文件。請先在文件或程式碼編輯區點一下，再回到 LumaChat 重試。"
        case .documentTooLarge(let application, let actual, let limit):
            "\(application) 的目前文件有 \(actual) 個字元，超過即時讀取上限 \(limit)；為避免截斷後誤寫，這次沒有讀取。"
        case .replacementTooLarge(let actual, let limit):
            "要寫入的內容有 \(actual) 個字元，超過安全上限 \(limit)，因此沒有修改原文件。"
        case .invalidReplacement:
            "要寫入的內容包含不支援的空字元，因此沒有修改原文件。"
        case .documentReplacementFailed(let application):
            "無法直接修改 \(application) 的目前文件；原本的剪貼簿內容已還原。請確認游標位於文件編輯區，且文件不是唯讀。"
        case .documentIdentityUnavailable(let application):
            "macOS 沒有提供 \(application) 目前文件的穩定識別資訊。為避免修改到另一份文件，這次沒有寫入；請先儲存文件後再試一次。"
        case .documentChanged(let application):
            "\(application) 的目前文件或內容在讀取後已經變更。為避免覆蓋新內容，這次沒有寫入；請重新讀取後再套用。"
        case .wholeDocumentWriteUnsupported(let application):
            "為避免破壞格式、核取方塊或附件，LumaChat 不會整份覆寫 \(application) 文件；仍可即時讀取，或只取代明確選取的文字。"
        }
    }
}

/// Captures text from a local macOS application after an explicit user action.
///
/// Captured text is returned as an in-memory `.capturedContext` attachment. No
/// temporary file is created. When Command-C is needed as a fallback, every
/// pasteboard item is snapshotted and restored before this method returns.
@MainActor
final class LocalContextService {
    let maximumCharacterCount: Int
    let maximumLiveDocumentCharacterCount: Int
    let maximumReplacementCharacterCount: Int

    private var lastExternalApplication: NSRunningApplication?
    private var workspaceObservers: [ObserverToken] = []

    init(
        maximumCharacterCount: Int = 32_000,
        maximumLiveDocumentCharacterCount: Int = 1_000_000,
        maximumReplacementCharacterCount: Int = 1_000_000,
        observeWorkspaceActivations: Bool = true
    ) {
        self.maximumCharacterCount = max(512, maximumCharacterCount)
        self.maximumLiveDocumentCharacterCount = max(512, maximumLiveDocumentCharacterCount)
        self.maximumReplacementCharacterCount = max(512, maximumReplacementCharacterCount)

        guard observeWorkspaceActivations else { return }

        let workspace = NSWorkspace.shared
        if let frontmost = workspace.frontmostApplication,
           !Self.isCurrentProcess(frontmost) {
            lastExternalApplication = frontmost
        }

        let center = workspace.notificationCenter
        let activated = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let processIdentifier = application.processIdentifier
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(processIdentifier: processIdentifier)
            }
        }
        let deactivated = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let processIdentifier = application.processIdentifier
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(processIdentifier: processIdentifier)
            }
        }
        workspaceObservers = [ObserverToken(activated), ObserverToken(deactivated)]
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer.value)
        }
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system Accessibility consent prompt when permission is absent.
    /// The user may need to return to the app and retry after granting access.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        // Use the documented key value directly. In Swift 6 the SDK exposes
        // kAXTrustedCheckOptionPrompt as mutable global state, which cannot be
        // referenced from actor-isolated code under strict concurrency.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Live document connections

    /// Connects to an allow-listed editor process without capturing or caching
    /// document contents. A connection remains valid only for this process
    /// launch; reopening the app requires a new connection.
    func connect(to source: LocalContextSource) throws -> LocalAppConnection {
        guard source.supportsLiveDocumentAccess else {
            throw LocalContextError.liveDocumentAccessUnsupported(source.title)
        }

        try requireAccessibilityPermissionIfNeeded()
        let application = try runningApplication(for: source)
        let applicationName = application.localizedName ?? source.title
        let bundleIdentifier = application.bundleIdentifier ?? ""

        guard !LocalContextSource.terminal.bundleIdentifiers.contains(bundleIdentifier) else {
            throw LocalContextError.sourceNotWritable(applicationName)
        }

        return LocalAppConnection(
            source: source,
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName
        )
    }

    /// Reads the active document directly from the connected app each time it
    /// is called. The returned value exists only in memory and is never written
    /// to a temporary attachment or file by this service.
    func readCurrentDocument(from connection: LocalAppConnection) async throws -> LocalDocumentSnapshot {
        let application = try connectedApplication(for: connection)
        try requireAccessibilityPermissionIfNeeded()
        let identityBeforeRead = documentIdentity(for: application, connection: connection)

        let text: String
        if connection.source.requiresLosslessClipboardDocumentRead {
            text = try await copyCurrentDocumentPreservingPasteboard(
                from: application,
                applicationName: connection.applicationName,
                connection: connection
            )
        } else if let accessibilityValue = accessibilityDocumentText(
            from: application,
            source: connection.source
        ) {
            text = accessibilityValue
        } else {
            switch connection.source {
            case .notes:
                let html = try executeAppleScriptAllowingEmpty(
                    Self.notesBodyScript,
                    applicationName: connection.applicationName
                )
                text = plainText(fromPossiblyHTML: html)
            case .textEdit:
                text = try executeAppleScriptAllowingEmpty(
                    Self.textEditScript,
                    applicationName: connection.applicationName
                )
            case .visualStudioCode, .xcode:
                // Handled before AXValue so IDE viewport values can never be
                // mistaken for a lossless whole-document read.
                throw LocalContextError.noReadableContent(connection.applicationName)
            case .currentSelection, .terminal:
                throw LocalContextError.liveDocumentAccessUnsupported(connection.applicationName)
            }
        }

        let count = text.count
        guard count <= maximumLiveDocumentCharacterCount else {
            throw LocalContextError.documentTooLarge(
                connection.applicationName,
                actual: count,
                limit: maximumLiveDocumentCharacterCount
            )
        }

        let identityAfterRead = documentIdentity(for: application, connection: connection)
        guard identityBeforeRead == identityAfterRead else {
            throw LocalContextError.documentChanged(connection.applicationName)
        }

        return LocalDocumentSnapshot(
            connection: connection,
            identity: identityAfterRead,
            documentTitle: focusedWindowTitle(for: application),
            text: text,
            contentDigest: Self.digest(of: text),
            capturedAt: Date()
        )
    }

    /// Convenience form for one-shot callers. Repeated callers should retain
    /// the returned `LocalAppConnection`, not a document snapshot.
    func readCurrentDocument(in source: LocalContextSource) async throws -> LocalDocumentSnapshot {
        let connection = try connect(to: source)
        return try await readCurrentDocument(from: connection)
    }

    /// Reads the active document now and exposes it through the existing chat
    /// attachment pipeline without creating a file. Call this again before each
    /// request to refresh the model's view of the document.
    func captureLiveDocument(_ source: LocalContextSource) async throws -> PreparedAttachment {
        let snapshot = try await readCurrentDocument(in: source)
        return snapshot.requestAttachment
    }

    /// Replaces a supported editor's complete active document in place. Notes
    /// is intentionally read/selection-only to preserve rich content. This does
    /// not create or save an intermediate text file. The caller remains
    /// responsible for explicit user confirmation before invoking this method.
    func replaceCurrentDocument(
        with replacement: String,
        using connection: LocalAppConnection
    ) async throws {
        try await performDocumentReplacement(
            with: replacement,
            using: connection,
            matching: nil
        )
    }

    /// Convenience form that resolves the currently running instance first.
    func replaceCurrentDocument(
        with replacement: String,
        in source: LocalContextSource
    ) async throws {
        let connection = try connect(to: source)
        try await replaceCurrentDocument(with: replacement, using: connection)
    }

    /// Short convenience name used by the chat action UI.
    func replaceDocument(
        with replacement: String,
        in source: LocalContextSource
    ) async throws {
        try await replaceCurrentDocument(with: replacement, in: source)
    }

    /// Compare-and-replace form for generated edits. It refuses to write if
    /// the user switched documents or the live contents changed since the model
    /// request was prepared.
    func replaceDocument(
        with replacement: String,
        matching snapshot: LocalDocumentSnapshot
    ) async throws {
        try validateReplacement(replacement)
        guard snapshot.identity.isStable else {
            throw LocalContextError.documentIdentityUnavailable(
                snapshot.connection.applicationName
            )
        }

        try await performDocumentReplacement(
            with: replacement,
            using: snapshot.connection,
            matching: snapshot
        )
    }

    /// Selection replacement for an existing live connection. This still
    /// requires a nonempty selection and never falls back to whole-document
    /// replacement.
    func replaceSelection(
        with replacement: String,
        using connection: LocalAppConnection
    ) async throws {
        try validateReplacement(replacement)
        let application = try connectedApplication(for: connection)
        try requireAccessibilityPermissionIfNeeded()
        try await replaceSelectionPreservingPasteboard(
            with: replacement,
            in: application,
            applicationName: connection.applicationName,
            requestedSource: connection.source
        )
    }

    private func performDocumentReplacement(
        with replacement: String,
        using connection: LocalAppConnection,
        matching expectedSnapshot: LocalDocumentSnapshot?
    ) async throws {
        try validateReplacement(replacement)
        guard connection.source.supportsGuardedDocumentWrite else {
            throw LocalContextError.wholeDocumentWriteUnsupported(
                connection.applicationName
            )
        }
        let application = try connectedApplication(for: connection)
        try requireAccessibilityPermissionIfNeeded()

        let baseline: LocalDocumentSnapshot
        if let expectedSnapshot {
            let current = try await readCurrentDocument(from: connection)
            guard current.identity.isStable,
                  current.identity == expectedSnapshot.identity,
                  current.contentDigest == expectedSnapshot.contentDigest else {
                throw LocalContextError.documentChanged(connection.applicationName)
            }
            baseline = expectedSnapshot
        } else {
            baseline = try await readCurrentDocument(from: connection)
            guard baseline.identity.isStable else {
                throw LocalContextError.documentIdentityUnavailable(
                    connection.applicationName
                )
            }
        }

        if connection.source == .textEdit,
           !isPlainTextDocument(baseline) {
            throw LocalContextError.wholeDocumentWriteUnsupported(
                connection.applicationName
            )
        }

        if let writtenContext = replaceTextEditDocument(
            with: replacement,
            in: application,
            matching: baseline
        ) {
            try await verifyReplacementOrUndo(
                replacement,
                baseline: baseline,
                application: application,
                writtenContext: writtenContext
            )
            return
        }

        try await replaceCurrentDocumentPreservingPasteboard(
            with: replacement,
            in: application,
            applicationName: connection.applicationName,
            connection: connection,
            expectedSnapshot: baseline
        )
    }

    private func verifyReplacementOrUndo(
        _ replacement: String,
        baseline: LocalDocumentSnapshot,
        application: NSRunningApplication,
        writtenContext: FocusedDocumentContext
    ) async throws {
        do {
            let current = try await readCurrentDocument(from: baseline.connection)
            guard current.identity == baseline.identity,
                  current.contentDigest == Self.digest(of: replacement) else {
                throw LocalContextError.documentReplacementFailed(
                    baseline.connection.applicationName
                )
            }
            return
        } catch {
            await rollbackDocumentIfSafe(
                to: baseline,
                afterWriting: replacement,
                in: application,
                lockedContext: writtenContext
            )
            throw LocalContextError.documentReplacementFailed(
                baseline.connection.applicationName
            )
        }
    }

    /// Captures a source only when called, returning an attachment that never
    /// writes its contents to a temporary or persistent file.
    func capture(_ source: LocalContextSource) async throws -> PreparedAttachment {
        let result: CaptureResult

        switch source {
        case .currentSelection:
            let application = try applicationForCurrentSelection()
            result = try await captureSelection(
                from: application,
                sourceName: application.localizedName ?? source.title
            )

        case .visualStudioCode, .xcode:
            let application = try runningApplication(for: source)
            result = try await captureSelection(from: application, sourceName: source.title)

        case .terminal:
            let application = try runningApplication(for: source)
            if let text = accessibilityText(from: application, includeFocusedValue: true) {
                result = CaptureResult(text: text, sourceLabel: application.localizedName ?? source.title)
            } else if application.bundleIdentifier == "com.apple.Terminal" {
                let text = try executeAppleScript(Self.terminalScript, applicationName: source.title)
                result = CaptureResult(text: text, sourceLabel: source.title)
            } else {
                try requireAccessibilityPermissionIfNeeded()
                throw LocalContextError.noReadableContent(application.localizedName ?? source.title)
            }

        case .notes:
            let application = try runningApplication(for: source)
            if let text = accessibilityText(from: application, includeFocusedValue: true) {
                result = CaptureResult(text: text, sourceLabel: source.title)
            } else {
                let html = try executeAppleScript(Self.notesScript, applicationName: source.title)
                result = CaptureResult(text: plainText(fromPossiblyHTML: html), sourceLabel: source.title)
            }

        case .textEdit:
            let application = try runningApplication(for: source)
            if let text = accessibilityText(from: application, includeFocusedValue: true) {
                result = CaptureResult(text: text, sourceLabel: source.title)
            } else {
                let text = try executeAppleScript(Self.textEditScript, applicationName: source.title)
                result = CaptureResult(text: text, sourceLabel: source.title)
            }
        }

        return try preparedAttachment(from: result, source: source)
    }

    /// Replaces a nonempty text selection as the direct result of an explicit
    /// user action. This method never runs during capture or generation, never
    /// modifies Terminal, and never interpolates replacement text into a script.
    /// Native Accessibility replacement is preferred; a Command-V fallback
    /// snapshots and restores every pasteboard item before returning.
    func replaceSelection(with replacement: String, in source: LocalContextSource) async throws {
        guard source.isWritable else {
            throw LocalContextError.sourceNotWritable(source.title)
        }
        try validateReplacement(replacement)

        let application: NSRunningApplication
        switch source {
        case .currentSelection:
            application = try applicationForCurrentSelection()
        case .notes, .textEdit, .visualStudioCode, .xcode:
            application = try runningApplication(for: source)
        case .terminal:
            throw LocalContextError.sourceNotWritable(source.title)
        }

        let applicationName = application.localizedName ?? source.title
        if LocalContextSource.terminal.bundleIdentifiers.contains(application.bundleIdentifier ?? "") {
            throw LocalContextError.sourceNotWritable(applicationName)
        }

        try requireAccessibilityPermissionIfNeeded()
        try await replaceSelectionPreservingPasteboard(
            with: replacement,
            in: application,
            applicationName: applicationName,
            requestedSource: source
        )
    }

    // MARK: - Application discovery

    private func rememberExternalApplication(processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !Self.isCurrentProcess(application),
              application.activationPolicy == .regular else { return }
        lastExternalApplication = application
    }

    private static func isCurrentProcess(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func runningApplication(for source: LocalContextSource) throws -> NSRunningApplication {
        let workspace = NSWorkspace.shared
        if let frontmost = workspace.frontmostApplication,
           source.bundleIdentifiers.contains(frontmost.bundleIdentifier ?? "") {
            return frontmost
        }

        if let remembered = lastExternalApplication,
           !remembered.isTerminated,
           source.bundleIdentifiers.contains(remembered.bundleIdentifier ?? "") {
            return remembered
        }

        if let application = workspace.runningApplications.first(where: {
            !$0.isTerminated && source.bundleIdentifiers.contains($0.bundleIdentifier ?? "")
        }) {
            return application
        }

        throw LocalContextError.applicationNotRunning(source.title)
    }

    private func connectedApplication(
        for connection: LocalAppConnection
    ) throws -> NSRunningApplication {
        guard connection.source.supportsLiveDocumentAccess,
              connection.source.bundleIdentifiers.contains(connection.bundleIdentifier),
              !LocalContextSource.terminal.bundleIdentifiers.contains(connection.bundleIdentifier),
              let application = NSRunningApplication(
                processIdentifier: connection.processIdentifier
              ),
              !application.isTerminated,
              application.bundleIdentifier == connection.bundleIdentifier else {
            throw LocalContextError.connectionLost(connection.applicationName)
        }
        return application
    }

    private func applicationForCurrentSelection() throws -> NSRunningApplication {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !Self.isCurrentProcess(frontmost),
           frontmost.activationPolicy == .regular {
            return frontmost
        }

        if let remembered = lastExternalApplication,
           !remembered.isTerminated {
            return remembered
        }

        if let application = applicationBehindCurrentApp() {
            return application
        }

        throw LocalContextError.noPreviousApplication
    }

    /// Window Server ordering gives us a useful final fallback if the service
    /// was initialized after LumaChat had already become frontmost.
    private func applicationBehindCurrentApp() -> NSRunningApplication? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windowInfo {
            guard (window[kCGWindowLayer] as? Int) == 0,
                  let rawPID = window[kCGWindowOwnerPID] as? Int,
                  rawPID != Int(ownPID),
                  let application = NSRunningApplication(processIdentifier: pid_t(rawPID)),
                  application.activationPolicy == .regular,
                  !application.isTerminated else { continue }
            return application
        }
        return nil
    }

    // MARK: - Accessibility

    private func accessibilityText(
        from application: NSRunningApplication,
        includeFocusedValue: Bool
    ) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let elements = focusedElementChain(for: application)

        // A real selection is always preferable to a full control value.
        for element in elements {
            if let selectedText = stringAttribute(kAXSelectedTextAttribute, from: element),
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return selectedText
            }
        }

        guard includeFocusedValue else { return nil }
        for element in elements.prefix(3) {
            if let value = stringAttribute(kAXValueAttribute, from: element),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Returns the complete value of the focused document editor, including an
    /// empty string for a valid empty document. Search fields and sidebars are
    /// deliberately excluded by requiring the macOS text-area role.
    private func accessibilityDocumentText(
        from application: NSRunningApplication,
        source: LocalContextSource
    ) -> String? {
        guard AXIsProcessTrusted(),
              let context = focusedDocumentContext(for: application, source: source),
              let value = stringAttribute(kAXValueAttribute, from: context.element),
              let characterCount = integerAttribute(
                "AXNumberOfCharacters",
                from: context.element
              ),
              characterCount == (value as NSString).length else {
            return nil
        }
        return value
    }

    private func focusedDocumentContext(
        for application: NSRunningApplication,
        source: LocalContextSource
    ) -> FocusedDocumentContext? {
        let chain = focusedElementChain(for: application)
        guard let editorIndex = chain.firstIndex(where: { element in
                stringAttribute(kAXRoleAttribute, from: element) == kAXTextAreaRole
              }) else { return nil }

        let editor = chain[editorIndex]
        switch source {
        case .notes, .textEdit:
            return FocusedDocumentContext(element: editor, localFileURL: nil)
        case .visualStudioCode, .xcode:
            // Only attributes on the focused editor's own accessibility chain
            // are considered. Stop before windows, applications, and web areas
            // so workspace/webview URLs cannot masquerade as the active file.
            var editorChain: [AXUIElement] = []
            for element in chain[editorIndex...] {
                let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
                if role == kAXWindowRole || role == kAXApplicationRole || role == "AXWebArea" {
                    break
                }
                editorChain.append(element)
            }
            let fileURL: URL
            if let editorURL = localRegularFileURL(in: editorChain) {
                fileURL = editorURL
            } else {
                // Recent VS Code builds expose the active file URL only on the
                // focused native window, while the Monaco editor itself carries
                // the file name. Accept that layout only when both independent
                // signals point to the same local regular file. Integrated
                // terminals/search/output panes are already rejected above.
                guard let windowURL = focusedWindowLocalFileURL(for: application),
                      editorContext(
                        editor,
                        matches: windowURL,
                        windowTitle: focusedWindowTitle(for: application)
                ) else { return nil }
                fileURL = windowURL
            }
            guard !hasExcludedEditorContext(
                in: chain,
                ignoringFileName: fileURL.lastPathComponent
            ) else { return nil }
            return FocusedDocumentContext(element: editor, localFileURL: fileURL)
        case .currentSelection, .terminal:
            return nil
        }
    }

    private func sameDocumentContext(
        _ lhs: FocusedDocumentContext,
        _ rhs: FocusedDocumentContext
    ) -> Bool {
        CFEqual(lhs.element, rhs.element)
            && lhs.localFileURL?.standardizedFileURL
                == rhs.localFileURL?.standardizedFileURL
    }

    private func hasExcludedEditorContext(
        in chain: [AXUIElement],
        ignoringFileName: String
    ) -> Bool {
        let attributes = [
            kAXIdentifierAttribute,
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXHelpAttribute,
            kAXRoleDescriptionAttribute,
            kAXSubroleAttribute,
            "AXDOMIdentifier"
        ]
        let deniedEnglishTokens: Set<String> = [
            "terminal", "console", "debug", "search", "output", "repl", "problems"
        ]
        let deniedCJKTokens = [
            "終端機", "終端", "主控台", "偵錯", "搜尋", "輸出", "問題",
            "终端", "控制台", "调试", "搜索", "输出", "问题"
        ]
        let lowercasedFileName = ignoringFileName.lowercased()

        for element in chain {
            for attribute in attributes {
                guard var value = textLikeAttribute(attribute, from: element)?
                    .lowercased() else { continue }

                // Accessibility titles commonly include the active file name.
                // Remove that exact name before classifying pane labels so
                // legitimate files such as Debug.swift or OutputParser.ts are
                // not confused with VS Code's Debug Console / Output panes.
                if !lowercasedFileName.isEmpty {
                    value = value.replacingOccurrences(
                        of: lowercasedFileName,
                        with: " "
                    )
                }

                let englishTokens = value
                    .split { !$0.isLetter && !$0.isNumber }
                    .map(String.init)
                if englishTokens.contains(where: deniedEnglishTokens.contains) {
                    return true
                }
                if deniedCJKTokens.contains(where: value.contains) { return true }
            }
        }
        return false
    }

    private func localRegularFileURL(in elements: [AXUIElement]) -> URL? {
        for element in elements {
            for attribute in ["AXDocument", "AXURL"] {
                guard let rawValue = textLikeAttribute(attribute, from: element),
                      let url = Self.localRegularFileURL(from: rawValue) else { continue }
                return url
            }
        }
        return nil
    }

    private func focusedWindowLocalFileURL(
        for application: NSRunningApplication
    ) -> URL? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, from: appElement) else {
            return nil
        }
        return localRegularFileURL(in: [window])
    }

    private func editorContext(
        _ editor: AXUIElement,
        matches fileURL: URL,
        windowTitle: String?
    ) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        guard !fileName.isEmpty,
              windowTitle?.lowercased().contains(fileName) == true else {
            return false
        }

        let attributes = [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXHelpAttribute,
            kAXIdentifierAttribute,
            kAXRoleDescriptionAttribute,
            "AXDOMIdentifier"
        ]
        // The file name must be exposed by the focused text area itself. A
        // generic "Code Editor" label on a shared ancestor is not sufficient:
        // that ancestor remains present while VS Code's terminal/console panel
        // has focus and could otherwise turn a stale window URL into a write
        // capability for executable input.
        return attributes.contains { attribute in
            guard let rawValue = textLikeAttribute(attribute, from: editor) else {
                return false
            }
            let value = rawValue.lowercased()
            guard let range = value.range(of: fileName) else { return false }
            let hasValidStart = range.lowerBound == value.startIndex
                || !value[value.index(before: range.lowerBound)].isLetter
                    && !value[value.index(before: range.lowerBound)].isNumber
            let hasValidEnd = range.upperBound == value.endIndex
                || !value[range.upperBound].isLetter
                    && !value[range.upperBound].isNumber
            return hasValidStart && hasValidEnd
        }
    }

    private static func localRegularFileURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: URL
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            guard parsed.isFileURL else { return nil }
            candidate = parsed
        } else {
            guard trimmed.hasPrefix("/") else { return nil }
            candidate = URL(fileURLWithPath: trimmed)
        }

        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard let values = try? canonical.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey]
        ),
        values.isRegularFile == true,
        values.isDirectory != true else { return nil }
        return canonical
    }

    private func focusedWindowTitle(for application: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = elementAttribute(kAXFocusedWindowAttribute, from: appElement),
              let title = stringAttribute(kAXTitleAttribute, from: window)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    private func documentIdentity(
        for application: NSRunningApplication,
        connection: LocalAppConnection
    ) -> LocalDocumentIdentity {
        let stableIdentifier: String?
        switch connection.source {
        case .notes:
            // Notes identity is exclusively the selected note's immutable ID.
            // Never accept a link/window URL from its accessibility hierarchy.
            stableIdentifier = try? executeAppleScriptAllowingEmpty(
                Self.notesIdentityScript,
                applicationName: connection.applicationName
            )
        case .textEdit:
            // TextEdit identity is exclusively the front document's saved path.
            let path = try? executeAppleScriptAllowingEmpty(
                    Self.textEditIdentityScript,
                    applicationName: connection.applicationName
                )
            stableIdentifier = path
                .flatMap(Self.localRegularFileURL(from:))?
                .absoluteString
        case .visualStudioCode, .xcode:
            stableIdentifier = focusedDocumentContext(
                for: application,
                source: connection.source
            )?.localFileURL?.absoluteString
        case .currentSelection, .terminal:
            stableIdentifier = nil
        }

        if let identifier = stableIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty {
            return LocalDocumentIdentity(
                processIdentifier: connection.processIdentifier,
                bundleIdentifier: connection.bundleIdentifier,
                identifier: identifier,
                isStable: true
            )
        }

        // Display-only fallback. Guarded writes always reject this identity.
        let title = focusedWindowTitle(for: application) ?? "unknown-document"
        return LocalDocumentIdentity(
            processIdentifier: connection.processIdentifier,
            bundleIdentifier: connection.bundleIdentifier,
            identifier: "unverified:\(connection.source.rawValue):\(title)",
            isStable: false
        )
    }

    /// Returns `false` only when Accessibility explicitly reports a zero-length
    /// selection. This prevents editors such as VS Code from copying the whole
    /// current line when Command-C is pressed with merely a caret present.
    private func hasNonemptyAccessibilitySelection(
        in application: NSRunningApplication
    ) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }

        for element in focusedElementChain(for: application) {
            var rawValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &rawValue
            ) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXValueGetTypeID() else { continue }

            let axValue = rawValue as! AXValue
            guard AXValueGetType(axValue) == .cfRange else { continue }
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else { continue }
            return range.length > 0
        }
        return nil
    }

    private func focusedElementChain(for application: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement) else {
            return []
        }

        var elements: [AXUIElement] = []
        var current: AXUIElement? = focusedElement
        for _ in 0..<6 {
            guard let element = current else { break }
            elements.append(element)
            current = elementAttribute(kAXParentAttribute, from: element)
        }
        return elements
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
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
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == CFArrayGetTypeID() else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue else { return nil }

        if let string = rawValue as? String {
            return string
        }
        if let attributedString = rawValue as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func textLikeAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue else { return nil }

        if let string = rawValue as? String { return string }
        if let url = rawValue as? URL { return url.absoluteString }
        return nil
    }

    private func integerAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let number = rawValue as? NSNumber else { return nil }
        return number.intValue
    }

    private func booleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let number = rawValue as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func validateReplacement(_ replacement: String) throws {
        let count = replacement.count
        guard count <= maximumReplacementCharacterCount else {
            throw LocalContextError.replacementTooLarge(
                actual: count,
                limit: maximumReplacementCharacterCount
            )
        }
        guard !replacement.contains("\0") else {
            throw LocalContextError.invalidReplacement
        }
    }

    private func requireAccessibilityPermissionIfNeeded() throws {
        guard !AXIsProcessTrusted() else { return }
        _ = requestAccessibilityPermission()
        throw LocalContextError.accessibilityPermissionRequired
    }

    private func activateForInteraction(
        _ application: NSRunningApplication
    ) async -> Bool {
        if application.isActive,
           NSWorkspace.shared.frontmostApplication?.processIdentifier
            == application.processIdentifier {
            return true
        }

        let requested = application.activate(options: [.activateAllWindows])
        guard requested else { return false }

        for _ in 0..<20 {
            if application.isActive,
               NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    // MARK: - Selection copy fallback

    private func captureSelection(
        from application: NSRunningApplication,
        sourceName: String
    ) async throws -> CaptureResult {
        if let selectedText = accessibilityText(from: application, includeFocusedValue: false) {
            return CaptureResult(
                text: selectedText,
                sourceLabel: "\(sourceName) · 選取內容"
            )
        }

        try requireAccessibilityPermissionIfNeeded()
        if hasNonemptyAccessibilitySelection(in: application) == false {
            throw LocalContextError.nothingSelected(sourceName)
        }
        let text = try await copySelectionPreservingPasteboard(
            from: application,
            applicationName: sourceName
        )
        return CaptureResult(text: text, sourceLabel: "\(sourceName) · 選取內容")
    }

    private func copySelectionPreservingPasteboard(
        from application: NSRunningApplication,
        applicationName: String
    ) async throws -> String {
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        var didActivateApplication = false

        defer {
            if didActivateApplication,
               let originalFrontmost,
               originalFrontmost.processIdentifier != application.processIdentifier,
               !originalFrontmost.isTerminated {
                originalFrontmost.activate(options: [.activateAllWindows])
            }
        }

        if !requiresTargetedMenuCommands(application),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard await activateForInteraction(application) else {
                throw LocalContextError.clipboardCopyFailed(applicationName)
            }
            didActivateApplication = true
        }

        // Snapshot only after activation. Otherwise a clipboard update that
        // occurs while macOS is switching apps could be overwritten with a
        // stale, pre-activation value during cleanup.
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        var ownedPasteboardChangeCount: Int?
        defer {
            snapshot.restore(
                to: pasteboard,
                ifUnchangedSince: ownedPasteboardChangeCount
            )
        }

        guard let selectedTextEvidence = accessibilityText(
                from: application,
                includeFocusedValue: false
              ),
              !selectedTextEvidence.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            throw LocalContextError.nothingSelected(applicationName)
        }
        let sentinel = "LumaChat-selection-sentinel-\(UUID().uuidString)"
        pasteboard.clearContents()
        ownedPasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.setString(sentinel, forType: .string) else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }
        ownedPasteboardChangeCount = pasteboard.changeCount
        let initialChangeCount = pasteboard.changeCount
        let copyResult = performEditCommand(.copy, in: application)
        guard copyResult.wasAttempted else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }

        var copiedChangeCount: Int?
        let attempts = requiresTargetedMenuCommands(application) ? 1 : 17
        for attempt in 0..<attempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            let observedChangeCount = pasteboard.changeCount
            if observedChangeCount != initialChangeCount {
                copiedChangeCount = observedChangeCount
                break
            }
        }

        guard let copiedChangeCount else {
            throw LocalContextError.nothingSelected(applicationName)
        }
        guard let text = pasteboard.string(forType: .string),
              pasteboard.changeCount == copiedChangeCount,
              text != sentinel,
              selectedTextEvidence == text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalContextError.nothingSelected(applicationName)
        }
        ownedPasteboardChangeCount = copiedChangeCount
        return text
    }

    /// Keyboard fallback for editors whose accessibility tree exposes a text
    /// area but not its complete AXValue. The original selection/caret and every
    /// pasteboard representation are restored before returning.
    private func copyCurrentDocumentPreservingPasteboard(
        from application: NSRunningApplication,
        applicationName: String,
        connection: LocalAppConnection
    ) async throws -> String {
        let pasteboard = NSPasteboard.general
        let pasteboardSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        var selectionSnapshot: AccessibilitySelectionSnapshot?
        var didSelectAll = false
        var didRestoreSelection = false
        var didActivateApplication = false
        var ownedPasteboardChangeCount: Int?

        defer {
            if didSelectAll, !didRestoreSelection, let selectionSnapshot {
                _ = restoreAccessibilitySelection(selectionSnapshot)
            }
            pasteboardSnapshot.restore(
                to: pasteboard,
                ifUnchangedSince: ownedPasteboardChangeCount
            )
            if didActivateApplication,
               let originalFrontmost,
               originalFrontmost.processIdentifier != application.processIdentifier,
               !originalFrontmost.isTerminated {
                originalFrontmost.activate(options: [.activateAllWindows])
            }
        }

        if !requiresTargetedMenuCommands(application),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard await activateForInteraction(application) else {
                throw LocalContextError.clipboardCopyFailed(applicationName)
            }
            didActivateApplication = true
        }

        guard let context = focusedDocumentContext(
                for: application,
                source: connection.source
              ) else {
            throw LocalContextError.documentNotFocused(applicationName)
        }
        guard let originalSelection = accessibilitySelectionSnapshot(
                for: context.element
              ),
              isAccessibilitySelectionSettable(for: context.element) else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }
        selectionSnapshot = originalSelection
        let identityBeforeSelection = documentIdentity(
            for: application,
            connection: connection
        )
        guard identityBeforeSelection.isStable else {
            throw LocalContextError.documentIdentityUnavailable(applicationName)
        }

        let sentinel = "LumaChat-clipboard-sentinel-\(UUID().uuidString)"
        pasteboard.clearContents()
        ownedPasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.setString(sentinel, forType: .string) else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }
        ownedPasteboardChangeCount = pasteboard.changeCount
        let selectAllResult = performEditCommand(.selectAll, in: application)
        didSelectAll = selectAllResult.wasAttempted
        guard selectAllResult.wasAttempted else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }
        try await Task.sleep(for: .milliseconds(60))

        guard let contextAfterSelection = focusedDocumentContext(
                for: application,
                source: connection.source
              ),
              sameDocumentContext(context, contextAfterSelection),
              documentIdentity(for: application, connection: connection)
                == identityBeforeSelection,
              accessibilitySelectionCoversDocument(
                in: contextAfterSelection.element
              ) else {
            throw LocalContextError.documentChanged(applicationName)
        }
        let selectedTextEvidence = stringAttribute(
            kAXSelectedTextAttribute,
            from: contextAfterSelection.element
        )

        let initialChangeCount = pasteboard.changeCount
        let copyResult = performEditCommand(.copy, in: application)
        guard copyResult.wasAttempted else {
            throw LocalContextError.clipboardCopyFailed(applicationName)
        }

        for attempt in 0..<20 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            let copiedChangeCount = pasteboard.changeCount
            if copiedChangeCount != initialChangeCount,
               let text = pasteboard.string(forType: .string),
               pasteboard.changeCount == copiedChangeCount,
               text != sentinel,
               let contextAfterCopy = focusedDocumentContext(
                for: application,
                source: connection.source
               ),
               sameDocumentContext(context, contextAfterCopy),
               documentIdentity(for: application, connection: connection)
                == identityBeforeSelection,
               copiedDocumentText(
                text,
                matches: contextAfterCopy.element,
                selectedTextEvidence: selectedTextEvidence
               ) {
                ownedPasteboardChangeCount = copiedChangeCount
                guard restoreAccessibilitySelection(originalSelection) else {
                    throw LocalContextError.clipboardCopyFailed(applicationName)
                }
                didRestoreSelection = true
                return text
            }
        }

        // A targeted Copy that leaves the sentinel unchanged is not sufficient
        // evidence of an empty IDE buffer: Electron's AXValue/count can both
        // omit a sole trailing line ending. Fail closed instead of silently
        // treating a newline-only document (or a failed Copy) as empty.
        throw LocalContextError.clipboardCopyFailed(applicationName)
    }

    private func copiedDocumentText(
        _ text: String,
        matches editor: AXUIElement,
        selectedTextEvidence: String?
    ) -> Bool {
        var evidence = [String]()
        if let selectedTextEvidence { evidence.append(selectedTextEvidence) }
        if let value = stringAttribute(kAXValueAttribute, from: editor) {
            evidence.append(value)
        }

        // VS Code/Xcode can hide one final line ending in AXValue and
        // AXSelectedText even though targeted Command-C includes it. No other
        // difference is accepted, so an unrelated concurrent pasteboard write
        // cannot silently become document data.
        return evidence.contains { candidate in
            text == candidate || text == candidate + "\n"
        }
    }

    private func replaceSelectionPreservingPasteboard(
        with replacement: String,
        in application: NSRunningApplication,
        applicationName: String,
        requestedSource: LocalContextSource
    ) async throws {
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        var didActivateApplication = false
        defer {
            if didActivateApplication,
               let originalFrontmost,
               originalFrontmost.processIdentifier != application.processIdentifier,
               !originalFrontmost.isTerminated {
                originalFrontmost.activate(options: [.activateAllWindows])
            }
        }

        if !requiresTargetedMenuCommands(application),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard await activateForInteraction(application) else {
                throw LocalContextError.selectionReplacementFailed(applicationName)
            }
            didActivateApplication = true
        }

        let guardedEditorSource = guardedEditorSource(
            for: application,
            requestedSource: requestedSource
        )
        let expectedEditorContext: FocusedDocumentContext?
        if let guardedEditorSource {
            guard let context = focusedDocumentContext(
                    for: application,
                    source: guardedEditorSource
                  ) else {
                throw LocalContextError.documentNotFocused(applicationName)
            }
            expectedEditorContext = context
        } else {
            expectedEditorContext = nil
        }

        // Bind the operation to one exact, nonempty AX selection. A caret-only
        // editor is never accepted because some IDEs paste/Copy the current line
        // even when there is no real selection.
        guard let selectionTarget = accessibilitySelectionTarget(
                in: application,
                expectedElement: expectedEditorContext?.element
              ) else {
            throw LocalContextError.nothingSelected(applicationName)
        }

        if let guardedEditorSource,
           let expectedEditorContext {
            guard let currentContext = focusedDocumentContext(
                    for: application,
                    source: guardedEditorSource
                  ),
                  sameDocumentContext(
                    expectedEditorContext,
                    currentContext
                  ),
                  accessibilitySelectionStillMatches(
                    selectionTarget,
                    in: application
                  ) else {
                throw LocalContextError.documentNotFocused(applicationName)
            }
        } else if !accessibilitySelectionStillMatches(
            selectionTarget,
            in: application
        ) {
            throw LocalContextError.nothingSelected(applicationName)
        }

        if replaceAccessibilitySelection(
            with: replacement,
            in: application,
            expectedTarget: selectionTarget
        ) {
            return
        }

        // VS Code/Xcode AX menu actions can time out after being dispatched.
        // Without a lossless selection-level transaction there is no safe way
        // to distinguish a delayed Paste from a failed one, so IDE selection
        // writes are limited to the exact AX setter above. Whole-document edits
        // remain available through the guarded snapshot/CAS path.
        if guardedEditorSource != nil {
            throw LocalContextError.selectionReplacementFailed(applicationName)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        var ownedPasteboardChangeCount: Int?
        defer {
            snapshot.restore(
                to: pasteboard,
                ifUnchangedSince: ownedPasteboardChangeCount
            )
        }

        pasteboard.clearContents()
        ownedPasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.setString(replacement, forType: .string) else {
            throw LocalContextError.selectionReplacementFailed(applicationName)
        }
        ownedPasteboardChangeCount = pasteboard.changeCount

        guard let expectedPasteboardChangeCount = ownedPasteboardChangeCount,
              pasteboard.changeCount == expectedPasteboardChangeCount,
              pasteboard.string(forType: .string) == replacement,
              accessibilitySelectionStillMatches(
                selectionTarget,
                in: application
              ) else {
            throw LocalContextError.selectionReplacementFailed(applicationName)
        }
        let pasteResult = performEditCommand(.paste, in: application)
        guard pasteResult.wasAttempted else {
            throw LocalContextError.selectionReplacementFailed(applicationName)
        }

        // CGEvent has no completion callback. Give the target enough time to read
        // the pasteboard before restoring it, while keeping the operation bounded.
        try await Task.sleep(for: .milliseconds(250))
    }

    private func replaceCurrentDocumentPreservingPasteboard(
        with replacement: String,
        in application: NSRunningApplication,
        applicationName: String,
        connection: LocalAppConnection,
        expectedSnapshot: LocalDocumentSnapshot
    ) async throws {
        let originalFrontmost = NSWorkspace.shared.frontmostApplication
        var didActivateApplication = false
        defer {
            if didActivateApplication,
               let originalFrontmost,
               originalFrontmost.processIdentifier != application.processIdentifier,
               !originalFrontmost.isTerminated {
                originalFrontmost.activate(options: [.activateAllWindows])
            }
        }

        if !requiresTargetedMenuCommands(application),
           NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard await activateForInteraction(application) else {
                throw LocalContextError.documentReplacementFailed(applicationName)
            }
            didActivateApplication = true
        }

        // Activation is an await boundary and some editors can restore a
        // different tab while coming to the foreground. Re-check both target
        // identity and live contents immediately after activation, before the
        // first destructive key event.
        let current = try await readCurrentDocument(from: connection)
        guard current.identity.isStable,
              current.identity == expectedSnapshot.identity,
              current.contentDigest == expectedSnapshot.contentDigest else {
            throw LocalContextError.documentChanged(applicationName)
        }

        // Resolve the concrete AX editor only after the awaited reread. IDEs
        // may rebuild the text-area element while keeping the same file open.
        guard let editorContext = focusedDocumentContext(
            for: application,
            source: connection.source
        ) else {
            throw LocalContextError.documentNotFocused(applicationName)
        }
        guard let originalSelection = accessibilitySelectionSnapshot(
                for: editorContext.element
              ),
              isAccessibilitySelectionSettable(for: editorContext.element) else {
            throw LocalContextError.documentReplacementFailed(applicationName)
        }
        var didVerifyReplacement = false
        defer {
            if !didVerifyReplacement {
                _ = restoreAccessibilitySelection(originalSelection)
            }
        }
        let selectAllResult = performEditCommand(.selectAll, in: application)
        guard selectAllResult.wasAttempted else {
            throw LocalContextError.documentReplacementFailed(applicationName)
        }
        try await Task.sleep(for: .milliseconds(60))

        // Bind the paste to the exact AX editor element selected above. The
        // identity check also catches editors that recreate their AX element
        // while switching tabs.
        guard let contextBeforePaste = focusedDocumentContext(
                for: application,
                source: connection.source
              ),
              sameDocumentContext(editorContext, contextBeforePaste),
              documentIdentity(for: application, connection: connection)
                == expectedSnapshot.identity,
              accessibilitySelectionCoversDocument(
                in: contextBeforePaste.element,
                expectedText: expectedSnapshot.text
              ) else {
            throw LocalContextError.documentChanged(applicationName)
        }

        // Snapshot and replace the pasteboard only after the final editor and
        // document guards. If the user copies something before Paste, abort and
        // leave their new clipboard untouched.
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        var ownedPasteboardChangeCount: Int?
        defer {
            snapshot.restore(
                to: pasteboard,
                ifUnchangedSince: ownedPasteboardChangeCount
            )
        }

        pasteboard.clearContents()
        ownedPasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.setString(replacement, forType: .string) else {
            throw LocalContextError.documentReplacementFailed(applicationName)
        }
        ownedPasteboardChangeCount = pasteboard.changeCount

        guard let finalContext = focusedDocumentContext(
                for: application,
                source: connection.source
              ),
              sameDocumentContext(editorContext, finalContext),
              documentIdentity(for: application, connection: connection)
                == expectedSnapshot.identity,
              accessibilitySelectionCoversDocument(
                in: finalContext.element,
                expectedText: expectedSnapshot.text
              ),
              let expectedPasteboardChangeCount = ownedPasteboardChangeCount,
              pasteboard.changeCount == expectedPasteboardChangeCount,
              pasteboard.string(forType: .string) == replacement else {
            throw LocalContextError.documentReplacementFailed(applicationName)
        }
        let pasteResult = performEditCommand(.paste, in: application)

        // Keep the replacement available until a live reread proves that the
        // target consumed exactly this text. A fixed delay alone is not treated
        // as success, particularly for Electron editors under load.
        try await Task.sleep(for: .milliseconds(180))
        do {
            let verified = try await readCurrentDocument(from: connection)
            guard verified.identity == expectedSnapshot.identity,
                  verified.contentDigest == Self.digest(of: replacement) else {
                throw LocalContextError.documentReplacementFailed(applicationName)
            }
            guard pasteResult.wasAttempted else {
                // A command that was never submitted cannot legitimately be
                // credited for an already-matching buffer.
                throw LocalContextError.documentReplacementFailed(applicationName)
            }
            didVerifyReplacement = true
            if pasteboard.string(forType: .string) == replacement {
                ownedPasteboardChangeCount = pasteboard.changeCount
            }
        } catch {
            if pasteResult.wasAttempted {
                await rollbackDocumentIfSafe(
                    to: expectedSnapshot,
                    afterWriting: replacement,
                    in: application,
                    lockedContext: editorContext
                )
            }
            if pasteboard.string(forType: .string) == replacement {
                ownedPasteboardChangeCount = pasteboard.changeCount
            }
            throw LocalContextError.documentReplacementFailed(applicationName)
        }
    }

    /// Best-effort rollback used only after a guarded write fails verification.
    /// It never guesses: Undo/restore is allowed only while a fresh reread proves
    /// that the exact same document still contains exactly LumaChat's replacement.
    private func rollbackDocumentIfSafe(
        to baseline: LocalDocumentSnapshot,
        afterWriting replacement: String,
        in application: NSRunningApplication,
        lockedContext: FocusedDocumentContext
    ) async {
        let current: LocalDocumentSnapshot
        do {
            current = try await readCurrentDocument(from: baseline.connection)
        } catch {
            return
        }

        guard current.identity == baseline.identity else { return }
        if current.contentDigest == baseline.contentDigest { return }
        guard current.contentDigest == Self.digest(of: replacement),
              let currentContext = focusedDocumentContext(
                for: application,
                source: baseline.connection.source
              ),
              documentIdentity(for: application, connection: baseline.connection)
                == baseline.identity else { return }

        let didRestore: Bool
        if baseline.connection.source == .textEdit {
            didRestore = replaceTextEditDocumentValue(
                with: baseline.text,
                in: application,
                matching: baseline,
                expectedCurrentDigest: Self.digest(of: replacement),
                lockedContext: lockedContext
            )
        } else {
            guard sameDocumentContext(lockedContext, currentContext),
                  let finalContext = focusedDocumentContext(
                    for: application,
                    source: baseline.connection.source
                  ),
                  sameDocumentContext(lockedContext, finalContext),
                  documentIdentity(
                    for: application,
                    connection: baseline.connection
                  ) == baseline.identity else { return }
            didRestore = performEditCommand(
                .undo,
                in: application
            ).wasAttempted
        }
        guard didRestore else { return }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func replaceAccessibilitySelection(
        with replacement: String,
        in application: NSRunningApplication,
        expectedTarget: AccessibilitySelectionTarget
    ) -> Bool {
        guard AXIsProcessTrusted(),
              accessibilitySelectionStillMatches(
                expectedTarget,
                in: application
              ) else { return false }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            expectedTarget.element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue,
        // Recheck the exact range/text immediately before the cross-process
        // setter. This is the narrowest achievable guard without an editor
        // extension offering an atomic versioned-edit API.
        accessibilitySelectionStillMatches(
            expectedTarget,
            in: application
        ) else { return false }

        return AXUIElementSetAttributeValue(
            expectedTarget.element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success
    }

    private func replaceTextEditDocument(
        with replacement: String,
        in application: NSRunningApplication,
        matching baseline: LocalDocumentSnapshot
    ) -> FocusedDocumentContext? {
        guard baseline.connection.source == .textEdit,
              isPlainTextDocument(baseline),
              AXIsProcessTrusted(),
              let context = focusedDocumentContext(
                for: application,
                source: .textEdit
              ),
              documentIdentity(
                for: application,
                connection: baseline.connection
              ) == baseline.identity,
              stringAttribute(
                kAXValueAttribute,
                from: context.element
              ).map({ Self.digest(of: $0) }) == baseline.contentDigest else {
            return nil
        }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            context.element,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue,
        let finalContext = focusedDocumentContext(
            for: application,
            source: .textEdit
        ),
        sameDocumentContext(context, finalContext),
        documentIdentity(
            for: application,
            connection: baseline.connection
        ) == baseline.identity,
        stringAttribute(
            kAXValueAttribute,
            from: finalContext.element
        ).map({ Self.digest(of: $0) }) == baseline.contentDigest else { return nil }

        guard AXUIElementSetAttributeValue(
            finalContext.element,
            kAXValueAttribute as CFString,
            replacement as CFString
        ) == .success else { return nil }
        return finalContext
    }

    private func replaceTextEditDocumentValue(
        with replacement: String,
        in application: NSRunningApplication,
        matching baseline: LocalDocumentSnapshot,
        expectedCurrentDigest: String,
        lockedContext: FocusedDocumentContext
    ) -> Bool {
        guard baseline.connection.source == .textEdit,
              isPlainTextDocument(baseline),
              AXIsProcessTrusted(),
              let currentContext = focusedDocumentContext(
                for: application,
                source: .textEdit
              ),
              sameDocumentContext(lockedContext, currentContext),
              documentIdentity(
                for: application,
                connection: baseline.connection
              ) == baseline.identity,
              stringAttribute(
                kAXValueAttribute,
                from: currentContext.element
              ).map({ Self.digest(of: $0) }) == expectedCurrentDigest else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            currentContext.element,
            kAXValueAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue,
        let finalContext = focusedDocumentContext(
            for: application,
            source: .textEdit
        ),
        sameDocumentContext(lockedContext, finalContext),
        documentIdentity(
            for: application,
            connection: baseline.connection
        ) == baseline.identity,
        stringAttribute(
            kAXValueAttribute,
            from: finalContext.element
        ).map({ Self.digest(of: $0) }) == expectedCurrentDigest else { return false }

        return AXUIElementSetAttributeValue(
            finalContext.element,
            kAXValueAttribute as CFString,
            replacement as CFString
        ) == .success
    }

    private func isPlainTextDocument(
        _ snapshot: LocalDocumentSnapshot
    ) -> Bool {
        guard snapshot.connection.source == .textEdit,
              snapshot.identity.isStable,
              let url = URL(string: snapshot.identity.identifier),
              url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = values.contentType else { return false }
        return contentType.conforms(to: .plainText)
    }

    private func accessibilitySelectionSnapshot(
        for element: AXUIElement
    ) -> AccessibilitySelectionSnapshot? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }

        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return AccessibilitySelectionSnapshot(element: element, range: range)
    }

    private func accessibilitySelectionTarget(
        in application: NSRunningApplication,
        expectedElement: AXUIElement?
    ) -> AccessibilitySelectionTarget? {
        let candidates = expectedElement.map { [$0] }
            ?? focusedElementChain(for: application)
        for element in candidates {
            guard let snapshot = accessibilitySelectionSnapshot(for: element),
                  snapshot.range.length > 0,
                  let selectedText = stringAttribute(
                    kAXSelectedTextAttribute,
                    from: element
                  ),
                  !selectedText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else { continue }
            return AccessibilitySelectionTarget(
                element: element,
                range: snapshot.range,
                text: selectedText
            )
        }
        return nil
    }

    private func accessibilitySelectionStillMatches(
        _ target: AccessibilitySelectionTarget,
        in application: NSRunningApplication
    ) -> Bool {
        guard focusedElementChain(for: application).contains(where: {
                CFEqual($0, target.element)
              }),
              let current = accessibilitySelectionSnapshot(for: target.element),
              current.range.location == target.range.location,
              current.range.length == target.range.length,
              stringAttribute(
                kAXSelectedTextAttribute,
                from: target.element
              ) == target.text else { return false }
        return true
    }

    /// Confirms that Select All actually covered the editor rather than merely
    /// trusting the AX menu call's return value. IDEs may omit one final line
    /// ending from AXValue/AXSelectedText, so that single known difference is
    /// accepted; arbitrary partial selections are not.
    private func accessibilitySelectionCoversDocument(
        in element: AXUIElement,
        expectedText: String? = nil
    ) -> Bool {
        guard let selection = accessibilitySelectionSnapshot(for: element),
              selection.range.location == 0,
              selection.range.length > 0,
              let selectedText = stringAttribute(
                kAXSelectedTextAttribute,
                from: element
              ),
              let documentValue = stringAttribute(
                kAXValueAttribute,
                from: element
              ) else { return false }

        guard selectedText == documentValue
                || selectedText == documentValue + "\n"
                || selectedText + "\n" == documentValue else {
            return false
        }

        guard let expectedText else { return true }
        let candidates = [selectedText, documentValue]
        guard candidates.allSatisfy({ candidate in
            candidate == expectedText
                || candidate + "\n" == expectedText
        }) else { return false }

        let expectedLength = (expectedText as NSString).length
        var permittedLengths: Set<Int> = [expectedLength]
        if expectedText.hasSuffix("\n"), expectedLength > 0 {
            permittedLengths.insert(expectedLength - 1)
        }
        return permittedLengths.contains(selection.range.length)
    }

    private func isAccessibilitySelectionSettable(
        for element: AXUIElement
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    private func restoreAccessibilitySelection(
        _ snapshot: AccessibilitySelectionSnapshot
    ) -> Bool {
        var range = snapshot.range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        guard AXUIElementSetAttributeValue(
            snapshot.element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success,
        let restored = accessibilitySelectionSnapshot(for: snapshot.element) else {
            return false
        }
        return restored.range.location == snapshot.range.location
            && restored.range.length == snapshot.range.length
    }

    private enum EditMenuCommand {
        case selectAll
        case copy
        case paste
        case undo

        var keyCode: CGKeyCode {
            switch self {
            case .selectAll: CGKeyCode(0)
            case .copy: CGKeyCode(8)
            case .paste: CGKeyCode(9)
            case .undo: CGKeyCode(6)
            }
        }

        var commandCharacter: String {
            switch self {
            case .selectAll: "a"
            case .copy: "c"
            case .paste: "v"
            case .undo: "z"
            }
        }
    }

    private enum EditCommandResult {
        /// The target API confirmed that it accepted the action.
        case performed
        /// The target API was invoked but returned a timeout/ambiguous error.
        /// The action may still have run, so callers must inspect live state.
        case indeterminate
        /// No target action was submitted.
        case unavailable

        var wasAttempted: Bool {
            self != .unavailable
        }
    }

    private func performEditCommand(
        _ command: EditMenuCommand,
        in application: NSRunningApplication
    ) -> EditCommandResult {
        if requiresTargetedMenuCommands(application) {
            return pressEditMenuCommand(command, in: application)
        }
        guard application.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier else {
            return .unavailable
        }
        return postCommandKey(
            command.keyCode,
            to: application.processIdentifier
        ) ? .performed : .unavailable
    }

    /// Electron does not reliably process Command shortcuts posted to its PID.
    /// Destructive global HID events are deliberately avoided because another
    /// app could win focus between a check and WindowServer dispatch. Pressing
    /// the target app's own AX menu item keeps Copy/Paste/Undo bound to that app.
    private func requiresTargetedMenuCommands(
        _ application: NSRunningApplication
    ) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        return LocalContextSource.visualStudioCode.bundleIdentifiers.contains(bundleIdentifier)
            || LocalContextSource.xcode.bundleIdentifiers.contains(bundleIdentifier)
    }

    /// Applies the IDE document-pane policy even when the caller used the
    /// generic `currentSelection` source. This prevents a VS Code/Xcode
    /// integrated terminal, console, search box, or output pane from becoming
    /// a writable selection merely because it shares the editor app's bundle.
    private func guardedEditorSource(
        for application: NSRunningApplication,
        requestedSource: LocalContextSource
    ) -> LocalContextSource? {
        let bundleIdentifier = application.bundleIdentifier ?? ""
        if requestedSource == .visualStudioCode
            || LocalContextSource.visualStudioCode.bundleIdentifiers
                .contains(bundleIdentifier) {
            return .visualStudioCode
        }
        if requestedSource == .xcode
            || LocalContextSource.xcode.bundleIdentifiers.contains(bundleIdentifier) {
            return .xcode
        }
        return nil
    }

    private func pressEditMenuCommand(
        _ command: EditMenuCommand,
        in application: NSRunningApplication
    ) -> EditCommandResult {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar = elementAttribute(kAXMenuBarAttribute, from: appElement) else {
            return .unavailable
        }

        var queue = [menuBar]
        var cursor = 0
        while cursor < queue.count, cursor < 512 {
            let element = queue[cursor]
            cursor += 1

            if stringAttribute(kAXRoleAttribute, from: element) == kAXMenuItemRole {
                let virtualKey = integerAttribute(
                    kAXMenuItemCmdVirtualKeyAttribute,
                    from: element
                )
                let commandCharacter = stringAttribute(
                    kAXMenuItemCmdCharAttribute,
                    from: element
                )?.lowercased()
                let modifiers = integerAttribute(
                    kAXMenuItemCmdModifiersAttribute,
                    from: element
                ) ?? 0
                let isEnabled = booleanAttribute(kAXEnabledAttribute, from: element) ?? true

                if modifiers == 0,
                   isEnabled,
                   virtualKey == Int(command.keyCode)
                    || commandCharacter == command.commandCharacter {
                    let result = AXUIElementPerformAction(
                        element,
                        kAXPressAction as CFString
                    )
                    return result == .success ? .performed : .indeterminate
                }
            }

            queue.append(contentsOf: elementArrayAttribute(
                kAXChildrenAttribute,
                from: element
            ))
        }

        return .unavailable
    }

    private func postCommandKey(
        _ keyCode: CGKeyCode,
        to processIdentifier: pid_t
    ) -> Bool {
        postKey(keyCode, flags: .maskCommand, to: processIdentifier)
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags,
        to processIdentifier: pid_t
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              ) else { return false }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    // MARK: - AppleScript fallbacks

    private func executeAppleScript(_ source: String, applicationName: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw LocalContextError.appleScriptFailed(applicationName, "無法建立讀取指令。")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo["NSAppleScriptErrorNumber"] as? Int
            if number == -1743 {
                throw LocalContextError.automationPermissionRequired(applicationName)
            }
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? "AppleScript 錯誤 \(number.map(String.init) ?? "未知")"
            throw LocalContextError.appleScriptFailed(applicationName, message)
        }

        guard let text = result.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalContextError.noReadableContent(applicationName)
        }
        return text
    }

    /// Read-only AppleScript helper used for empty documents and identity
    /// lookups. Replacement text is never interpolated into or passed through
    /// AppleScript.
    private func executeAppleScriptAllowingEmpty(
        _ source: String,
        applicationName: String
    ) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw LocalContextError.appleScriptFailed(applicationName, "無法建立讀取指令。")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo["NSAppleScriptErrorNumber"] as? Int
            if number == -1743 {
                throw LocalContextError.automationPermissionRequired(applicationName)
            }
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? "AppleScript 錯誤 \(number.map(String.init) ?? "未知")"
            throw LocalContextError.appleScriptFailed(applicationName, message)
        }
        return result.stringValue ?? ""
    }

    private static let terminalScript = """
        tell application "Terminal"
            if not running then return ""
            if (count of windows) is 0 then return ""
            return contents of selected tab of front window
        end tell
        """

    private static let notesScript = """
        tell application "Notes"
            if not running then return ""
            set selectedNotes to selection
            if (count of selectedNotes) is 0 then return ""
            set selectedNote to item 1 of selectedNotes
            return (name of selectedNote as text) & linefeed & (body of selectedNote as text)
        end tell
        """

    private static let notesBodyScript = """
        tell application "Notes"
            if not running then return ""
            set selectedNotes to selection
            if (count of selectedNotes) is 0 then return ""
            return body of item 1 of selectedNotes as text
        end tell
        """

    private static let notesIdentityScript = """
        tell application "Notes"
            if not running then return ""
            set selectedNotes to selection
            if (count of selectedNotes) is 0 then return ""
            return id of item 1 of selectedNotes as text
        end tell
        """

    private static let textEditScript = """
        tell application "TextEdit"
            if not running then return ""
            if (count of documents) is 0 then return ""
            return text of front document
        end tell
        """

    private static let textEditIdentityScript = """
        tell application "TextEdit"
            if not running then return ""
            if (count of documents) is 0 then return ""
            try
                return POSIX path of (file of front document as alias)
            on error
                return ""
            end try
        end tell
        """

    // MARK: - Attachment preparation

    private func preparedAttachment(
        from result: CaptureResult,
        source: LocalContextSource
    ) throws -> PreparedAttachment {
        let normalized = normalizeAndLimit(result.text)
        guard !normalized.isEmpty else {
            throw LocalContextError.noReadableContent(result.sourceLabel)
        }

        let attachment = ChatAttachment(
            name: "\(source.title) · 一次性內容",
            relativePath: nil,
            mimeType: "text/plain; charset=utf-8",
            kind: .capturedContext,
            byteCount: Int64(normalized.utf8.count),
            extractedText: normalized,
            sourceLabel: result.sourceLabel
        )
        return PreparedAttachment(attachment: attachment, data: nil)
    }

    private func normalizeAndLimit(_ input: String) -> String {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count > maximumCharacterCount else { return normalized }
        let marker = "\n\n…（內容已截斷；原始共 \(normalized.count) 字元）"
        let prefixLength = max(1, maximumCharacterCount - marker.count)
        return String(normalized.prefix(prefixLength)) + marker
    }

    private func plainText(fromPossiblyHTML value: String) -> String {
        guard value.range(of: "<[^>]+>", options: .regularExpression) != nil,
              let data = value.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else { return value }
        return attributed.string
    }
}

/// NotificationCenter tokens are opaque Objective-C objects. Removal is
/// thread-safe, so this small Sendable wrapper lets Swift 6 clean them up from
/// the class's nonisolated deinitializer without weakening the service itself.
private final class ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol

    init(_ value: NSObjectProtocol) {
        self.value = value
    }
}

private struct CaptureResult {
    let text: String
    let sourceLabel: String
}

private struct AccessibilitySelectionSnapshot {
    let element: AXUIElement
    let range: CFRange
}

private struct AccessibilitySelectionTarget {
    let element: AXUIElement
    let range: CFRange
    let text: String
}

private struct FocusedDocumentContext {
    let element: AXUIElement
    let localFileURL: URL?
}

@MainActor
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
    }

    /// Restores only while the pasteboard still contains the last value owned
    /// by this operation. A user copy or clipboard-sync update that happened
    /// during an await wins and is never overwritten by cleanup.
    func restore(
        to pasteboard: NSPasteboard,
        ifUnchangedSince ownedChangeCount: Int?
    ) {
        guard let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount else { return }
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems: [NSPasteboardItem] = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
