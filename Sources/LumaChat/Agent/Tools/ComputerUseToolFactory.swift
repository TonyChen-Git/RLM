import Foundation

private struct ComputerUseAgentTool: AgentTool {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let inputSchema: JSONValue
    let permissionLevel: AgentPermissionLevel
    let supportsParallelExecution: Bool
    let category: AgentToolCategory = .system
    let operation: @Sendable (JSONValue, AgentToolContext) async throws -> AgentToolResult

    func isAvailable(in context: AgentToolContext) -> Bool {
        context.computerUseEnabled
            && (context.executionLocation.kind == .local
                || context.executionLocation.kind == .worktree)
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard isAvailable(in: context) else { throw ComputerUseError.disabled }
        return try await operation(arguments, context)
    }
}

enum ComputerUseToolFactory {
    static func makeTools(
        service: any ComputerUseServicing = MacComputerUseService(),
        imageAttachmentStore: AgentImageAttachmentStore = AgentImageAttachmentStore()
    ) -> [any AgentTool] {
        [
            tool(
                "computer_permission_status",
                "Computer Use Permissions",
                "Report whether macOS Screen Recording and Accessibility permissions are granted. This never opens or approves a system permission prompt.",
                permission: .read,
                parallel: true
            ) { _, context in
                let status = await service.permissionStatus()
                let allowedCount = context.computerUseAllowedBundleIdentifiers.count
                return AgentToolResult(
                    content: "Computer Use permissions: screen_recording=\(status.screenRecordingGranted), accessibility=\(status.accessibilityGranted), ready=\(status.isReady), configured_apps=\(allowedCount).",
                    data: .object([
                        "screen_recording_granted": .bool(status.screenRecordingGranted),
                        "accessibility_granted": .bool(status.accessibilityGranted),
                        "ready": .bool(status.isReady),
                        "configured_app_count": .number(Double(allowedCount))
                    ])
                )
            },
            tool(
                "computer_list_apps",
                "List Allowed Apps",
                "List only running regular Mac apps whose exact bundle identifiers are already in the user's Computer Use allow-list. Blocked security, terminal, and agent apps are omitted.",
                permission: .read,
                parallel: true
            ) { _, context in
                let applications = try await service.listApplications(
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers
                )
                let rendered = applications.isEmpty
                    ? "No allow-listed Computer Use apps are currently running."
                    : applications.map { application in
                        "\(application.name) — \(application.bundleIdentifier) (pid \(application.processIdentifier), windows \(application.visibleWindowCount), frontmost \(application.isFrontmost))"
                    }.joined(separator: "\n")
                return AgentToolResult(
                    content: rendered,
                    data: .object([
                        "applications": .array(applications.map(applicationJSON))
                    ])
                )
            },
            tool(
                "computer_list_windows",
                "List App Windows",
                "List bounded, on-screen layer-zero windows for one exact allow-listed running app. Use the returned window_id to select a target when the app has multiple windows.",
                permission: .read,
                parallel: true,
                properties: targetProperties,
                required: ["bundle_identifier"]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                let windows = try await service.listWindows(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers
                )
                let rendered = windows.isEmpty
                    ? "No safe visible windows are available for this app."
                    : windows.map { window in
                        let title = window.title.map { " — \($0)" } ?? ""
                        return "window \(window.windowID)\(title) (\(Int(window.width))×\(Int(window.height)))"
                    }.joined(separator: "\n")
                return AgentToolResult(
                    content: rendered,
                    data: .object([
                        "windows": .array(windows.map(windowJSON))
                    ])
                )
            },
            tool(
                "computer_screenshot",
                "Capture App Window",
                "Capture one explicitly selected safe window of an allow-listed Mac app. Omit window_id only when the app has exactly one visible window. Multiple matching processes still fail closed. The returned PNG is attached to the next model request; every UI action must use its fresh capture_id and exact window_id.",
                permission: .read,
                parallel: false,
                properties: windowSelectionProperties,
                required: ["bundle_identifier"]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                let screenshot = try await service.capture(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    windowID: try values.optionalUInt32("window_id")
                )
                try Task.checkCancellation()
                let safeName = screenshot.applicationName
                    .replacingOccurrences(of: "/", with: "-")
                    .prefix(120)
                let reference = try imageAttachmentStore.importGeneratedPNG(
                    screenshot.pngData,
                    name: "\(safeName)-computer-use.png",
                    sessionID: context.sessionID
                )
                var data: [String: JSONValue] = [
                    "capture_id": .string(screenshot.captureID.uuidString.lowercased()),
                    "attachment_id": .string(reference.id.uuidString.lowercased()),
                    "application_name": .string(screenshot.applicationName),
                    "bundle_identifier": .string(screenshot.bundleIdentifier),
                    "window_id": .number(Double(screenshot.windowID)),
                    "image_width": .number(Double(screenshot.imageWidth)),
                    "image_height": .number(Double(screenshot.imageHeight)),
                    "byte_count": .number(Double(reference.byteCount))
                ]
                if let title = screenshot.windowTitle { data["window_title"] = .string(title) }
                let captureID = screenshot.captureID.uuidString.lowercased()
                return try AgentToolResult(
                    content: """
                    Captured \(screenshot.applicationName) as an attached PNG.
                    bundle_identifier: \(screenshot.bundleIdentifier)
                    capture_id: \(captureID)
                    window_id: \(screenshot.windowID)
                    image_width: \(screenshot.imageWidth)
                    image_height: \(screenshot.imageHeight)
                    Every UI action must use this capture_id and window_id. Coordinates for computer_click are relative to this image. capture_id is single-use and expires after 30 seconds.
                    """,
                    data: .object(data),
                    imageAttachments: [reference]
                )
            },
            tool(
                "computer_accessibility_snapshot",
                "Inspect Window Semantics",
                "Read a bounded set of pressable or focusable Accessibility elements from the exact freshly captured window. Values from text fields are never returned. Opaque element_id values are capture-bound and cannot be reused after an action.",
                permission: .read,
                parallel: false,
                properties: capturedTargetProperties,
                required: capturedTargetRequired
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                let snapshot = try await service.accessibilitySnapshot(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id")
                )
                let bounded = boundedAccessibilitySnapshotJSON(
                    snapshot,
                    maximumBytes: context.maximumToolResultCharacters
                )
                return AgentToolResult(
                    content: bounded.count == 0
                        ? "No background-safe semantic targets were found in the captured window."
                        : "Found \(bounded.count) capture-bound semantic targets. truncated=\(bounded.truncated).",
                    data: bounded.data
                )
            },
            tool(
                "computer_verify_state",
                "Verify Captured State",
                "Verify the capture-bound app, selected window geometry, and optional semantic element without activating the app or posting input. This read does not consume capture_id and reports whether the foreground app stayed unchanged.",
                permission: .read,
                parallel: false,
                properties: capturedTargetProperties.merging([
                    "element_id": .stringSchema(
                        description: "Optional element_id returned by computer_accessibility_snapshot"
                    )
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: capturedTargetRequired
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                let verification = try await service.verifyState(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    elementID: try values.optionalUUID("element_id")
                )
                return AgentToolResult(
                    content: verification.isBackgroundSafe
                        ? "Verified the captured target without changing the foreground app."
                        : "Target verification completed but background-safety state changed; recapture before acting.",
                    data: verificationJSON(verification),
                    isError: !verification.isBackgroundSafe
                )
            },
            tool(
                "computer_semantic_action",
                "Act on Semantic Element",
                "Press or focus one opaque Accessibility element in the selected captured window without first activating the app. Only a small host-owned role/action allow-list is accepted. This may change external state and always requires a fresh capture plus explicit one-time approval; model arguments can never enable Always Allow.",
                permission: .dangerous,
                properties: capturedActionProperties.merging([
                    "element_id": .stringSchema(
                        description: "Fresh element_id returned by computer_accessibility_snapshot"
                    ),
                    "action": enumSchema(["press", "focus"])
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: capturedActionRequired + ["element_id", "action"]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                let action = try values.requiredString("action")
                let verification = try await service.performSemanticAction(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    elementID: try values.requiredUUID("element_id"),
                    action: action
                )
                return AgentToolResult(
                    content: verification.isBackgroundSafe
                        ? "Performed the approved semantic \(action) without changing the foreground app. Capture consumed."
                        : "Performed the approved semantic \(action), but post-action background verification changed. Capture consumed; observe again before continuing.",
                    data: externalSideEffectJSON(verificationJSON(verification)),
                    mayHaveChangedWorkspace: true
                )
            },
            tool(
                "computer_activate_app",
                "Activate Selected Window",
                "Bring the exact selected allow-listed window to the foreground using a fresh target-window capture. Computer Use never launches apps automatically, and this always requires explicit one-time approval.",
                permission: .dangerous,
                properties: capturedActionProperties,
                required: capturedActionRequired
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                let application = try await service.activate(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id")
                )
                return AgentToolResult(
                    content: "External side effect (not undoable): activated \(application.name) (\(application.bundleIdentifier)).",
                    data: externalSideEffectJSON(applicationJSON(application)),
                    mayHaveChangedWorkspace: true
                )
            },
            tool(
                "computer_click",
                "Click App Window",
                "Click inside the exact allow-listed app window from computer_screenshot. A single-use capture ID plus the window ID, dimensions, owner, and unchanged geometry prevent stale coordinates from silently moving to another target. This always requires explicit approval.",
                permission: .dangerous,
                properties: capturedActionProperties.merging([
                    "x": numberSchema("Horizontal pixel coordinate in the attached screenshot", minimum: 0),
                    "y": numberSchema("Vertical pixel coordinate in the attached screenshot", minimum: 0),
                    "screenshot_width": integerSchema("image_width returned by computer_screenshot", minimum: 1),
                    "screenshot_height": integerSchema("image_height returned by computer_screenshot", minimum: 1),
                    "button": enumSchema(["left", "right"]),
                    "click_count": integerSchema("1 for click, 2 for double-click", minimum: 1, maximum: 2)
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: [
                    "bundle_identifier", "capture_id", "window_id", "reason", "x", "y",
                    "screenshot_width", "screenshot_height"
                ]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                try await service.click(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    x: try values.requiredNumber("x"),
                    y: try values.requiredNumber("y"),
                    screenshotWidth: try values.requiredInteger("screenshot_width"),
                    screenshotHeight: try values.requiredInteger("screenshot_height"),
                    button: values.string("button") ?? "left",
                    clickCount: values.integer("click_count") ?? 1
                )
                return AgentToolResult(
                    content: "External side effect (not undoable): clicked the approved app window.",
                    data: externalSideEffectJSON(),
                    mayHaveChangedWorkspace: true
                )
            },
            tool(
                "computer_type_text",
                "Type in App",
                "Type bounded Unicode text into the focused control of one allow-listed app without using the clipboard. This can submit forms or change external state and always requires explicit approval.",
                permission: .dangerous,
                properties: capturedActionProperties.merging([
                    "text": .stringSchema(description: "UTF-8 text, at most 16 KiB; NUL is rejected")
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: capturedActionRequired + ["text"]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                let text = try values.requiredString("text", allowEmpty: false)
                guard SecretRedactor().redact(text) == text else {
                    throw ComputerUseError.sensitiveText
                }
                try await service.typeText(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    text: text
                )
                return AgentToolResult(
                    content: "External side effect (not undoable): typed \(text.count) characters into the approved app.",
                    data: externalSideEffectJSON(),
                    mayHaveChangedWorkspace: true
                )
            },
            tool(
                "computer_press_key",
                "Press App Key",
                "Press one bounded navigation/editing key in an allow-listed app, optionally with command/shift/option/control. This always requires explicit approval.",
                permission: .dangerous,
                properties: capturedActionProperties.merging([
                    "key": enumSchema([
                        "return", "tab", "space", "delete", "forward_delete",
                        "escape", "home", "end", "page_up", "page_down",
                        "left", "right", "up", "down"
                    ]),
                    "modifiers": stringArraySchema(
                        "Optional unique modifiers: command, shift, option, control"
                    )
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: capturedActionRequired + ["key"]
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                try await service.pressKey(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    key: try values.requiredString("key"),
                    modifiers: try values.stringArray("modifiers")
                )
                return AgentToolResult(
                    content: "External side effect (not undoable): pressed the approved key in the approved app.",
                    data: externalSideEffectJSON(),
                    mayHaveChangedWorkspace: true
                )
            },
            tool(
                "computer_scroll",
                "Scroll App",
                "Scroll the exact freshly captured window of an allow-listed app by bounded pixel deltas. Positive delta_y scrolls up and negative scrolls down. This always requires explicit one-time approval.",
                permission: .dangerous,
                properties: capturedActionProperties.merging([
                    "delta_x": integerSchema("Horizontal pixel delta", minimum: -10_000, maximum: 10_000),
                    "delta_y": integerSchema("Vertical pixel delta", minimum: -10_000, maximum: 10_000)
                ], uniquingKeysWith: { _, rhs in rhs }),
                required: capturedActionRequired
            ) { arguments, context in
                let values = try ComputerUseToolArguments(arguments)
                _ = try values.requiredReason()
                let deltaX = values.integer("delta_x") ?? 0
                let deltaY = values.integer("delta_y") ?? 0
                try await service.scroll(
                    bundleIdentifier: try values.requiredString("bundle_identifier"),
                    allowedBundleIdentifiers: context.computerUseAllowedBundleIdentifiers,
                    sessionID: context.sessionID,
                    captureID: try values.requiredUUID("capture_id"),
                    windowID: try values.requiredUInt32("window_id"),
                    deltaX: deltaX,
                    deltaY: deltaY
                )
                return AgentToolResult(
                    content: "External side effect (not undoable): scrolled the approved app by (\(deltaX), \(deltaY)).",
                    data: externalSideEffectJSON(),
                    mayHaveChangedWorkspace: true
                )
            }
        ]
    }

    private static let targetProperties: [String: JSONValue] = [
        "bundle_identifier": .stringSchema(
            description: "Exact bundle identifier already present in the user's allow-list"
        )
    ]

    private static let windowSelectionProperties: [String: JSONValue] =
        targetProperties.merging([
            "window_id": integerSchema(
                "Exact window_id from computer_list_windows; required when multiple windows are visible",
                minimum: 1
            )
        ], uniquingKeysWith: { _, rhs in rhs })

    private static let capturedTargetProperties: [String: JSONValue] =
        targetProperties.merging([
            "capture_id": .stringSchema(
                description: "Fresh single-use capture_id returned by computer_screenshot"
            ),
            "window_id": integerSchema(
                "Exact window_id returned with that capture_id",
                minimum: 1
            )
        ], uniquingKeysWith: { _, rhs in rhs })

    private static let capturedTargetRequired = [
        "bundle_identifier", "capture_id", "window_id"
    ]

    private static let capturedActionProperties: [String: JSONValue] =
        capturedTargetProperties.merging([
            "reason": .object([
                "type": .string("string"),
                "description": .string("Short, single-line user-visible reason for this UI action"),
                "minLength": .number(1),
                "maxLength": .number(512)
            ])
        ], uniquingKeysWith: { _, rhs in rhs })

    private static let capturedActionRequired = [
        "bundle_identifier", "capture_id", "window_id", "reason"
    ]

    private static func tool(
        _ name: String,
        _ displayName: String,
        _ description: String,
        permission: AgentPermissionLevel,
        parallel: Bool = false,
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        operation: @escaping @Sendable (
            JSONValue,
            AgentToolContext
        ) async throws -> AgentToolResult
    ) -> any AgentTool {
        ComputerUseAgentTool(
            id: "builtin.\(name)",
            name: name,
            displayName: displayName,
            description: description,
            inputSchema: .objectSchema(properties: properties, required: required),
            permissionLevel: permission,
            supportsParallelExecution: parallel,
            operation: operation
        )
    }

    private static func applicationJSON(_ application: ComputerUseApplication) -> JSONValue {
        .object([
            "name": .string(application.name),
            "bundle_identifier": .string(application.bundleIdentifier),
            "process_identifier": .number(Double(application.processIdentifier)),
            "is_frontmost": .bool(application.isFrontmost),
            "visible_window_count": .number(Double(application.visibleWindowCount))
        ])
    }

    private static func windowJSON(_ window: ComputerUseWindow) -> JSONValue {
        var values: [String: JSONValue] = [
            "application_name": .string(window.applicationName),
            "bundle_identifier": .string(window.bundleIdentifier),
            "process_identifier": .number(Double(window.processIdentifier)),
            "window_id": .number(Double(window.windowID)),
            "x": .number(window.x),
            "y": .number(window.y),
            "width": .number(window.width),
            "height": .number(window.height),
            "is_frontmost_application": .bool(window.isFrontmostApplication)
        ]
        if let title = window.title { values["title"] = .string(title) }
        return .object(values)
    }

    private static func accessibilityElementJSON(
        _ element: ComputerUseAccessibilityElement
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "element_id": .string(element.elementID.uuidString.lowercased()),
            "role": .string(element.role),
            "enabled": .bool(element.enabled),
            "focused": .bool(element.focused),
            "actions": .array(element.actions.map(JSONValue.string))
        ]
        if let subrole = element.subrole { values["subrole"] = .string(subrole) }
        if let label = element.label { values["label"] = .string(label) }
        if let identifier = element.identifier { values["identifier"] = .string(identifier) }
        if let selected = element.selected { values["selected"] = .bool(selected) }
        if let value = element.frameX { values["x"] = .number(value) }
        if let value = element.frameY { values["y"] = .number(value) }
        if let value = element.frameWidth { values["width"] = .number(value) }
        if let value = element.frameHeight { values["height"] = .number(value) }
        return .object(values)
    }

    private static func boundedAccessibilitySnapshotJSON(
        _ snapshot: ComputerUseAccessibilitySnapshot,
        maximumBytes: Int
    ) -> (data: JSONValue, count: Int, truncated: Bool) {
        var elements = snapshot.elements.map(accessibilityElementJSON)
        var truncated = snapshot.truncated
        let encoder = JSONEncoder()
        let ceiling = max(512, maximumBytes - 512)

        func payload() -> JSONValue {
            .object([
                "capture_id": .string(snapshot.captureID.uuidString.lowercased()),
                "window_id": .number(Double(snapshot.windowID)),
                "truncated": .bool(truncated),
                "elements": .array(elements)
            ])
        }

        while !elements.isEmpty,
              (try? encoder.encode(payload()).count).map({ $0 > ceiling }) ?? true {
            elements.removeLast()
            truncated = true
        }
        return (payload(), elements.count, truncated)
    }

    private static func verificationJSON(
        _ verification: ComputerUseBackgroundVerification
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "bundle_identifier": .string(verification.bundleIdentifier),
            "process_identifier": .number(Double(verification.processIdentifier)),
            "window_id": .number(Double(verification.windowID)),
            "target_is_frontmost": .bool(verification.targetIsFrontmost),
            "frontmost_application_unchanged": .bool(
                verification.frontmostApplicationUnchanged
            ),
            "window_geometry_unchanged": .bool(verification.windowGeometryUnchanged),
            "background_safe": .bool(verification.isBackgroundSafe)
        ]
        if let elementID = verification.elementID {
            values["element_id"] = .string(elementID.uuidString.lowercased())
        }
        if let matches = verification.elementStillMatches {
            values["element_still_matches"] = .bool(matches)
        }
        return .object(values)
    }

    private static func externalSideEffectJSON(_ base: JSONValue? = nil) -> JSONValue {
        var values = base?.objectValue ?? [:]
        values["external_side_effect"] = .bool(true)
        values["undo_available"] = .bool(false)
        return .object(values)
    }

    private static func numberSchema(
        _ description: String,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let minimum { values["minimum"] = .number(minimum) }
        if let maximum { values["maximum"] = .number(maximum) }
        return .object(values)
    }

    private static func integerSchema(
        _ description: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum { values["minimum"] = .number(Double(minimum)) }
        if let maximum { values["maximum"] = .number(Double(maximum)) }
        return .object(values)
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func stringArraySchema(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
            "maxItems": .number(4),
            "uniqueItems": .bool(true)
        ])
    }
}

private struct ComputerUseToolArguments {
    private let values: [String: JSONValue]

    init(_ value: JSONValue) throws {
        guard let values = value.objectValue else {
            throw AgentRuntimeError.invalidArguments(
                "Computer Use arguments must be a JSON object."
            )
        }
        self.values = values
    }

    func string(_ name: String) -> String? {
        values[name]?.stringValue
    }

    func requiredString(_ name: String, allowEmpty: Bool = false) throws -> String {
        guard let value = string(name), allowEmpty || !value.isEmpty else {
            throw AgentRuntimeError.invalidArguments("Computer Use requires \(name).")
        }
        return value
    }

    func requiredReason() throws -> String {
        let value = try requiredString("reason")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AgentRuntimeError.invalidArguments(
                "Computer Use reason must be a non-empty single line of at most 512 UTF-8 bytes."
            )
        }
        return value
    }

    func integer(_ name: String) -> Int? {
        values[name]?.intValue
    }

    func requiredInteger(_ name: String) throws -> Int {
        guard let value = integer(name) else {
            throw AgentRuntimeError.invalidArguments("Computer Use requires integer \(name).")
        }
        return value
    }

    func requiredUInt32(_ name: String) throws -> UInt32 {
        let value = try requiredInteger(name)
        guard let result = UInt32(exactly: value), result > 0 else {
            throw AgentRuntimeError.invalidArguments("Computer Use \(name) is out of range.")
        }
        return result
    }

    func optionalUInt32(_ name: String) throws -> UInt32? {
        guard values[name] != nil else { return nil }
        return try requiredUInt32(name)
    }

    func requiredUUID(_ name: String) throws -> UUID {
        guard let raw = string(name), let value = UUID(uuidString: raw) else {
            throw AgentRuntimeError.invalidArguments("Computer Use requires UUID \(name).")
        }
        return value
    }

    func optionalUUID(_ name: String) throws -> UUID? {
        guard values[name] != nil else { return nil }
        return try requiredUUID(name)
    }

    func requiredNumber(_ name: String) throws -> Double {
        guard case .number(let value) = values[name], value.isFinite else {
            throw AgentRuntimeError.invalidArguments("Computer Use requires finite number \(name).")
        }
        return value
    }

    func stringArray(_ name: String) throws -> [String] {
        guard let value = values[name] else { return [] }
        guard let array = value.arrayValue, array.count <= 4 else {
            throw AgentRuntimeError.invalidArguments("Computer Use \(name) must be an array of at most 4 strings.")
        }
        return try array.map { item in
            guard let string = item.stringValue else {
                throw AgentRuntimeError.invalidArguments("Computer Use \(name) must contain only strings.")
            }
            return string
        }
    }
}
