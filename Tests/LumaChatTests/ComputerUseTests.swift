import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import LumaChat

private actor ComputerUseMockService: ComputerUseServicing {
    private let status: ComputerUsePermissionStatus
    private let screenshot: ComputerUseScreenshot
    private let semanticElementID = UUID()
    private var lastCaptureAllowedBundleIdentifiers: Set<String>?
    private var lastCaptureWindowID: UInt32?

    init(
        status: ComputerUsePermissionStatus = ComputerUsePermissionStatus(
            screenRecordingGranted: true,
            accessibilityGranted: true
        ),
        screenshot: ComputerUseScreenshot
    ) {
        self.status = status
        self.screenshot = screenshot
    }

    func permissionStatus() async -> ComputerUsePermissionStatus {
        status
    }

    func listApplications(
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseApplication] {
        [
            ComputerUseApplication(
                name: screenshot.applicationName,
                bundleIdentifier: screenshot.bundleIdentifier,
                processIdentifier: screenshot.processIdentifier,
                isFrontmost: true,
                visibleWindowCount: 1
            )
        ]
    }

    func listWindows(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>
    ) async throws -> [ComputerUseWindow] {
        [
            ComputerUseWindow(
                applicationName: screenshot.applicationName,
                bundleIdentifier: screenshot.bundleIdentifier,
                processIdentifier: screenshot.processIdentifier,
                windowID: screenshot.windowID,
                title: screenshot.windowTitle,
                x: 10,
                y: 20,
                width: 800,
                height: 600,
                isFrontmostApplication: true
            )
        ]
    }

    func capture(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        windowID: UInt32?
    ) async throws -> ComputerUseScreenshot {
        lastCaptureAllowedBundleIdentifiers = allowedBundleIdentifiers
        lastCaptureWindowID = windowID
        return screenshot
    }


    func accessibilitySnapshot(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseAccessibilitySnapshot {
        ComputerUseAccessibilitySnapshot(
            captureID: captureID,
            windowID: windowID,
            elements: [
                ComputerUseAccessibilityElement(
                    elementID: semanticElementID,
                    role: kAXButtonRole,
                    subrole: nil,
                    label: "Save",
                    identifier: "save-button",
                    enabled: true,
                    focused: false,
                    selected: nil,
                    actions: ["press"],
                    frameX: 1,
                    frameY: 1,
                    frameWidth: 1,
                    frameHeight: 1
                )
            ],
            truncated: false
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
        verification(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            elementID: elementID
        )
    }

    func performSemanticAction(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        elementID: UUID,
        action: String
    ) async throws -> ComputerUseBackgroundVerification {
        verification(
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            elementID: elementID
        )
    }

    func activate(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32
    ) async throws -> ComputerUseApplication {
        ComputerUseApplication(
            name: screenshot.applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: screenshot.processIdentifier,
            isFrontmost: true,
            visibleWindowCount: 1
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
    ) async throws {}

    func typeText(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        text: String
    ) async throws {}

    func pressKey(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        key: String,
        modifiers: [String]
    ) async throws {}

    func scroll(
        bundleIdentifier: String,
        allowedBundleIdentifiers: Set<String>,
        sessionID: UUID,
        captureID: UUID,
        windowID: UInt32,
        deltaX: Int,
        deltaY: Int
    ) async throws {}

    func capturedAllowedBundleIdentifiers() -> Set<String>? {
        lastCaptureAllowedBundleIdentifiers
    }


    func capturedWindowID() -> UInt32? {
        lastCaptureWindowID
    }

    func fixtureSemanticElementID() -> UUID {
        semanticElementID
    }

    private func verification(
        bundleIdentifier: String,
        windowID: UInt32,
        elementID: UUID?
    ) -> ComputerUseBackgroundVerification {
        ComputerUseBackgroundVerification(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: screenshot.processIdentifier,
            windowID: windowID,
            targetIsFrontmost: false,
            frontmostApplicationUnchanged: true,
            windowGeometryUnchanged: true,
            elementID: elementID,
            elementStillMatches: elementID.map { _ in true }
        )
    }
}

final class ComputerUseTests: XCTestCase {
    private let allowedBundleIdentifier = "com.example.fixture-editor"

    func testPolicyRequiresExactAllowListEntryAndRejectsBlockedApplications() throws {
        XCTAssertEqual(
            try ComputerUsePolicy.validateTarget(
                bundleIdentifier: "  \(allowedBundleIdentifier)\n",
                allowedBundleIdentifiers: [allowedBundleIdentifier]
            ),
            allowedBundleIdentifier
        )

        XCTAssertThrowsError(
            try ComputerUsePolicy.validateTarget(
                bundleIdentifier: allowedBundleIdentifier,
                allowedBundleIdentifiers: [allowedBundleIdentifier.uppercased()]
            )
        ) { error in
            XCTAssertEqual(
                error as? ComputerUseError,
                .applicationNotAllowed(self.allowedBundleIdentifier)
            )
        }

        let blockedIdentifiers = [
            "com.lumachat.desktop",
            "com.openai.Codex",
            "com.apple.Terminal",
            "com.apple.systemsettings",
            "com.apple.SecurityAgent",
            "com.apple.keychainaccess"
        ]
        for identifier in blockedIdentifiers {
            XCTAssertTrue(ComputerUsePolicy.isBlocked(bundleIdentifier: identifier))
            XCTAssertThrowsError(
                try ComputerUsePolicy.validateTarget(
                    bundleIdentifier: identifier,
                    allowedBundleIdentifiers: [identifier]
                )
            ) { error in
                XCTAssertEqual(
                    error as? ComputerUseError,
                    .blockedApplication(identifier)
                )
            }
        }

        XCTAssertTrue(ComputerUsePolicy.isValidScrollDelta(x: -10_000, y: 10_000))
        XCTAssertFalse(ComputerUsePolicy.isValidScrollDelta(x: 0, y: 0))
        XCTAssertFalse(ComputerUsePolicy.isValidScrollDelta(x: .min, y: 1))
        XCTAssertFalse(ComputerUsePolicy.isValidScrollDelta(x: .max, y: -1))
    }

    func testSemanticRoleAndScopedAlwaysAllowPoliciesFailClosed() throws {
        XCTAssertTrue(
            ComputerUsePolicy.supportsSemanticPress(
                role: kAXButtonRole,
                subrole: nil
            )
        )
        XCTAssertFalse(
            ComputerUsePolicy.supportsSemanticFocus(
                role: kAXTextFieldRole,
                subrole: kAXSecureTextFieldSubrole
            )
        )
        XCTAssertFalse(
            ComputerUsePolicy.supportsSemanticPress(
                role: kAXWindowRole,
                subrole: nil
            )
        )
        XCTAssertTrue(
            ComputerUsePolicy.supportsTextEntry(
                role: kAXTextAreaRole,
                subrole: nil
            )
        )
        XCTAssertFalse(
            ComputerUsePolicy.supportsTextEntry(
                role: kAXTextFieldRole,
                subrole: kAXSecureTextFieldSubrole
            )
        )
        XCTAssertFalse(
            ComputerUsePolicy.supportsTextEntry(
                role: kAXButtonRole,
                subrole: nil
            )
        )

        let captureID = UUID()
        let elementID = UUID()
        let arguments: JSONValue = .object([
            "bundle_identifier": .string(allowedBundleIdentifier),
            "capture_id": .string(captureID.uuidString),
            "window_id": .number(73),
            "element_id": .string(elementID.uuidString),
            // A model-provided flag is deliberately ignored by host policy.
            "always_allow": .bool(true)
        ])
        let semantic = try XCTUnwrap(
            ComputerUseScopedApprovalPolicy.scope(
                toolName: "computer_semantic_action",
                arguments: arguments
            )
        )
        XCTAssertEqual(semantic.bundleIdentifier, allowedBundleIdentifier)
        XCTAssertEqual(semantic.windowID, 73)
        XCTAssertEqual(semantic.elementID, elementID)
        XCTAssertFalse(semantic.isAlwaysAllowEligible)

        let verification = try XCTUnwrap(
            ComputerUseScopedApprovalPolicy.scope(
                toolName: "computer_verify_state",
                arguments: arguments
            )
        )
        XCTAssertTrue(verification.isAlwaysAllowEligible)
        let malformedVerification = try XCTUnwrap(
            ComputerUseScopedApprovalPolicy.scope(
                toolName: "computer_verify_state",
                arguments: .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string("not-a-uuid"),
                    "window_id": .number(0)
                ])
            )
        )
        XCTAssertFalse(malformedVerification.isAlwaysAllowEligible)
        XCTAssertNil(
            ComputerUseScopedApprovalPolicy.scope(
                toolName: "write_file",
                arguments: arguments
            )
        )
    }

    func testComputerUseSessionAllowanceIsObservationOnlyExactArgumentAndNotPersisted() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let manager = PermissionManager()
        let context = makeContext(
            root: fixture.scratch,
            mode: .agent,
            enabled: true
        )
        let observation = ToolMetadata(
            id: "builtin.computer_list_windows",
            name: "computer_list_windows",
            displayName: "List App Windows",
            category: .system,
            permissionLevel: .read,
            requiresNetwork: true,
            supportsParallelExecution: false
        )
        let approved = AgentToolCall(
            name: observation.name,
            arguments: .object([
                "bundle_identifier": .string(allowedBundleIdentifier)
            ])
        )
        await manager.allowForSession(
            metadata: observation,
            context: context,
            effectiveLevel: .network,
            call: approved
        )

        XCTAssertEqual(
            await manager.authorize(
                metadata: observation,
                call: approved,
                context: context,
                permissionMode: .askEveryTime,
                networkAccess: false
            ),
            .allow
        )
        let differentArguments = await manager.authorize(
            metadata: observation,
            call: AgentToolCall(
                name: observation.name,
                arguments: .object([
                    "bundle_identifier": .string("com.example.other")
                ])
            ),
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        guard case .requireApproval(let level, _) = differentArguments else {
            return XCTFail("Computer Use allowance crossed its exact argument scope.")
        }
        XCTAssertEqual(level, .network)
        XCTAssertTrue(await manager.persistedAllowances(for: context.sessionID).isEmpty)

        let mutation = ToolMetadata(
            id: "builtin.computer_semantic_action",
            name: "computer_semantic_action",
            displayName: "Act on Semantic Element",
            category: .system,
            permissionLevel: .write,
            requiresNetwork: false,
            supportsParallelExecution: false
        )
        let mutationCall = AgentToolCall(
            name: mutation.name,
            arguments: .object([
                "bundle_identifier": .string(allowedBundleIdentifier),
                "capture_id": .string(UUID().uuidString),
                "window_id": .number(73),
                "element_id": .string(UUID().uuidString),
                "action": .string("press"),
                "reason": .string("Save")
            ])
        )
        await manager.allowForSession(
            metadata: mutation,
            context: context,
            effectiveLevel: .write,
            call: mutationCall
        )
        let mutationAuthorization = await manager.authorize(
            metadata: mutation,
            call: mutationCall,
            context: context,
            permissionMode: .askEveryTime,
            networkAccess: false
        )
        guard case .requireApproval(let mutationLevel, _) = mutationAuthorization else {
            return XCTFail("A Computer Use mutation received a session allowance.")
        }
        XCTAssertEqual(mutationLevel, .write)
    }

    func testToolsAreOptInAndPlanOnlyExposesReadOperations() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let service = try makeService()
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: service,
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )

        let disabledDefinitions = await registry.definitions(
            for: .agent,
            context: makeContext(root: fixture.scratch, mode: .agent, enabled: false)
        )
        XCTAssertEqual(disabledDefinitions, [])

        let allToolNames = Set(
            await registry.definitions(
                for: .agent,
                context: makeContext(root: fixture.scratch, mode: .agent, enabled: true)
            ).map(\.name)
        )
        XCTAssertEqual(
            allToolNames,
            [
                "computer_permission_status",
                "computer_list_apps",
                "computer_list_windows",
                "computer_screenshot",
                "computer_accessibility_snapshot",
                "computer_verify_state",
                "computer_semantic_action",
                "computer_activate_app",
                "computer_click",
                "computer_type_text",
                "computer_press_key",
                "computer_scroll"
            ]
        )

        let planToolNames = Set(
            await registry.definitions(
                for: .plan,
                context: makeContext(root: fixture.scratch, mode: .plan, enabled: true)
            ).map(\.name)
        )
        XCTAssertEqual(
            planToolNames,
            [
                "computer_permission_status",
                "computer_list_apps",
                "computer_list_windows",
                "computer_screenshot",
                "computer_accessibility_snapshot",
                "computer_verify_state"
            ]
        )
    }

    func testToolPermissionMetadataMatchesObservationAndActionRisk() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: try makeService(),
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )

        let expected: [String: (AgentPermissionLevel, Bool)] = [
            "computer_permission_status": (.read, true),
            "computer_list_apps": (.read, true),
            "computer_list_windows": (.read, true),
            "computer_screenshot": (.read, false),
            "computer_accessibility_snapshot": (.read, false),
            "computer_verify_state": (.read, false),
            "computer_semantic_action": (.dangerous, false),
            "computer_activate_app": (.dangerous, false),
            "computer_click": (.dangerous, false),
            "computer_type_text": (.dangerous, false),
            "computer_press_key": (.dangerous, false),
            "computer_scroll": (.dangerous, false)
        ]
        let metadata = await registry.allMetadata()
        XCTAssertEqual(Set(metadata.map(\.name)), Set(expected.keys))

        for value in metadata {
            let expectedValue = try XCTUnwrap(expected[value.name])
            XCTAssertEqual(value.id, "builtin.\(value.name)")
            XCTAssertEqual(value.category, .system)
            XCTAssertEqual(value.permissionLevel, expectedValue.0)
            XCTAssertEqual(value.supportsParallelExecution, expectedValue.1)
            XCTAssertFalse(value.requiresNetwork)
        }

        for name in [
            "computer_semantic_action", "computer_activate_app", "computer_click", "computer_type_text",
            "computer_press_key", "computer_scroll"
        ] {
            let registeredTool = await registry.tool(named: name)
            let tool = try XCTUnwrap(registeredTool)
            let required = Set(
                tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            XCTAssertTrue(
                required.isSuperset(of: [
                    "bundle_identifier", "capture_id", "window_id", "reason"
                ]),
                "\(name) must be bound to a fresh capture and user-visible reason."
            )
        }

        let registeredScrollTool = await registry.tool(named: "computer_scroll")
        let scrollTool = try XCTUnwrap(registeredScrollTool)
        XCTAssertEqual(scrollTool.inputSchema["properties"]?["delta_x"]?["minimum"]?.intValue, -10_000)
        XCTAssertEqual(scrollTool.inputSchema["properties"]?["delta_x"]?["maximum"]?.intValue, 10_000)
    }

    func testScreenshotToolPersistsMockPNGAndReturnsReloadableAttachment() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let png = try makePNG()
        let captureID = UUID()
        let service = ComputerUseMockService(
            screenshot: ComputerUseScreenshot(
                captureID: captureID,
                applicationName: "Fixture Editor",
                bundleIdentifier: allowedBundleIdentifier,
                processIdentifier: 4242,
                windowID: 73,
                windowTitle: "Mock document",
                imageWidth: 2,
                imageHeight: 2,
                pngData: png
            )
        )
        let store = AgentImageAttachmentStore(sessionsRoot: fixture.sessionsRoot)
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: service,
                imageAttachmentStore: store
            )
        )
        let registeredTool = await registry.tool(named: "computer_screenshot")
        let tool = try XCTUnwrap(registeredTool)
        let sessionID = UUID()
        let result = try await tool.execute(
            arguments: .object([
                "bundle_identifier": .string(allowedBundleIdentifier),
                "window_id": .number(73)
            ]),
            context: makeContext(
                sessionID: sessionID,
                root: fixture.scratch,
                mode: .agent,
                enabled: true
            )
        )

        let reference = try XCTUnwrap(result.imageAttachments.first)
        XCTAssertEqual(result.imageAttachments.count, 1)
        XCTAssertEqual(reference.mimeType, "image/png")
        XCTAssertEqual(reference.pixelWidth, 2)
        XCTAssertEqual(reference.pixelHeight, 2)
        XCTAssertEqual(reference.byteCount, png.count)
        XCTAssertEqual(result.data?["window_id"]?.intValue, 73)
        XCTAssertEqual(result.data?["image_width"]?.intValue, 2)
        XCTAssertEqual(result.data?["image_height"]?.intValue, 2)
        XCTAssertEqual(result.data?["window_title"]?.stringValue, "Mock document")
        XCTAssertEqual(
            result.data?["capture_id"]?.stringValue,
            captureID.uuidString.lowercased()
        )
        XCTAssertTrue(result.content.contains(captureID.uuidString.lowercased()))
        XCTAssertFalse(result.content.contains(png.base64EncodedString()))
        XCTAssertEqual(
            try store.loadPayload(for: reference, sessionID: sessionID).data,
            png
        )
        let capturedAllowList = await service.capturedAllowedBundleIdentifiers()
        XCTAssertEqual(capturedAllowList, [allowedBundleIdentifier])
        let capturedWindowID = await service.capturedWindowID()
        XCTAssertEqual(capturedWindowID, 73)
    }

    func testAccessibilitySnapshotReturnsOpaqueBoundedTargetsWithoutValues() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let service = try makeService()
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: service,
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )
        let registeredTool = await registry.tool(named: "computer_accessibility_snapshot")
        let tool = try XCTUnwrap(registeredTool)
        let captureID = UUID()
        let result = try await tool.execute(
            arguments: .object([
                "bundle_identifier": .string(allowedBundleIdentifier),
                "capture_id": .string(captureID.uuidString),
                "window_id": .number(73)
            ]),
            context: makeContext(
                root: fixture.scratch,
                mode: .agent,
                enabled: true
            )
        )

        let element = try XCTUnwrap(result.data?["elements"]?.arrayValue?.first)
        XCTAssertEqual(element["role"]?.stringValue, kAXButtonRole)
        XCTAssertEqual(element["label"]?.stringValue, "Save")
        XCTAssertNil(element["value"])
        let fixtureElementID = await service.fixtureSemanticElementID()
        XCTAssertEqual(
            element["element_id"]?.stringValue,
            fixtureElementID.uuidString.lowercased()
        )
    }

    func testBackgroundVerificationIsReadOnlyAndSemanticMutationStaysDangerous() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let service = try makeService()
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: service,
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )
        let registeredVerify = await registry.tool(named: "computer_verify_state")
        let registeredSemantic = await registry.tool(named: "computer_semantic_action")
        let verify = try XCTUnwrap(registeredVerify)
        let semantic = try XCTUnwrap(registeredSemantic)
        XCTAssertEqual(verify.permissionLevel, .read)
        XCTAssertEqual(semantic.permissionLevel, .dangerous)
        let required = Set(
            semantic.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        XCTAssertTrue(
            required.isSuperset(of: [
                "bundle_identifier", "capture_id", "window_id",
                "element_id", "action", "reason"
            ])
        )

        let captureID = UUID()
        let result = try await verify.execute(
            arguments: .object([
                "bundle_identifier": .string(allowedBundleIdentifier),
                "capture_id": .string(captureID.uuidString),
                "window_id": .number(73)
            ]),
            context: makeContext(
                root: fixture.scratch,
                mode: .agent,
                enabled: true
            )
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.data?["background_safe"]?.boolValue, true)
        XCTAssertEqual(
            result.data?["frontmost_application_unchanged"]?.boolValue,
            true
        )
    }

    func testTypeToolRejectsSecretLikeTextBeforeCallingComputerService() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: try makeService(),
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )
        let registeredTool = await registry.tool(named: "computer_type_text")
        let tool = try XCTUnwrap(registeredTool)

        do {
            _ = try await tool.execute(
                arguments: .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(UUID().uuidString),
                    "window_id": .number(73),
                    "reason": .string("Fill a field"),
                    "text": .string("password=ordinary-password-12345")
                ]),
                context: makeContext(
                    root: fixture.scratch,
                    mode: .agent,
                    enabled: true
                )
            )
            XCTFail("Secret-like Computer Use text should be rejected.")
        } catch {
            XCTAssertEqual(error as? ComputerUseError, .sensitiveText)
        }
    }

    func testMutationsRequireBoundedReasonAndDeclareNonUndoableExternalSideEffect() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let service = try makeService()
        let registry = ToolRegistry()
        try await registry.register(
            ComputerUseToolFactory.makeTools(
                service: service,
                imageAttachmentStore: AgentImageAttachmentStore(
                    sessionsRoot: fixture.sessionsRoot
                )
            )
        )
        let context = makeContext(
            root: fixture.scratch,
            mode: .agent,
            enabled: true
        )
        let captureID = UUID().uuidString
        let elementID = await service.fixtureSemanticElementID().uuidString
        let calls: [(String, JSONValue)] = [
            (
                "computer_semantic_action",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "element_id": .string(elementID),
                    "action": .string("press"),
                    "reason": .string("Save the document")
                ])
            ),
            (
                "computer_activate_app",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("Show the selected window")
                ])
            ),
            (
                "computer_click",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("Choose the item"),
                    "x": .number(1),
                    "y": .number(1),
                    "screenshot_width": .number(2),
                    "screenshot_height": .number(2)
                ])
            ),
            (
                "computer_type_text",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("Enter public text"),
                    "text": .string("hello")
                ])
            ),
            (
                "computer_press_key",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("Move to the next field"),
                    "key": .string("tab")
                ])
            ),
            (
                "computer_scroll",
                .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("Reveal the next section"),
                    "delta_y": .number(-120)
                ])
            )
        ]

        for (name, arguments) in calls {
            let registered = await registry.tool(named: name)
            let tool = try XCTUnwrap(registered)
            let result = try await tool.execute(arguments: arguments, context: context)
            XCTAssertTrue(result.mayHaveChangedWorkspace, name)
            XCTAssertEqual(result.data?["external_side_effect"]?.boolValue, true, name)
            XCTAssertEqual(result.data?["undo_available"]?.boolValue, false, name)
            XCTAssertTrue(result.content.localizedCaseInsensitiveContains("not undoable"), name)
        }

        let registeredActivate = await registry.tool(named: "computer_activate_app")
        let activate = try XCTUnwrap(registeredActivate)
        XCTAssertEqual(
            activate.inputSchema["properties"]?["reason"]?["minLength"]?.intValue,
            1
        )
        XCTAssertEqual(
            activate.inputSchema["properties"]?["reason"]?["maxLength"]?.intValue,
            512
        )
        do {
            _ = try await activate.execute(
                arguments: .object([
                    "bundle_identifier": .string(allowedBundleIdentifier),
                    "capture_id": .string(captureID),
                    "window_id": .number(73),
                    "reason": .string("  ")
                ]),
                context: context
            )
            XCTFail("A blank Computer Use approval reason must fail closed.")
        } catch {
            guard case AgentRuntimeError.invalidArguments = error else {
                return XCTFail("Unexpected blank-reason error: \(error)")
            }
        }
    }

    private struct Fixture {
        var scratch: URL
        var sessionsRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let scratch = AppPaths.projectTemporaryRoot
            .appendingPathComponent("computer-use-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = scratch.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Fixture(scratch: scratch, sessionsRoot: sessionsRoot)
    }

    private func makeContext(
        sessionID: UUID = UUID(),
        root: URL,
        mode: AppMode,
        enabled: Bool
    ) -> AgentToolContext {
        AgentToolContext(
            sessionID: sessionID,
            mode: mode,
            workspace: AgentWorkspace(
                name: "Computer Use Tests",
                rootPath: root.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            ),
            computerUseEnabled: enabled,
            computerUseAllowedBundleIdentifiers: [allowedBundleIdentifier]
        )
    }

    private func makeService() throws -> ComputerUseMockService {
        ComputerUseMockService(
            screenshot: ComputerUseScreenshot(
                captureID: UUID(),
                applicationName: "Fixture Editor",
                bundleIdentifier: allowedBundleIdentifier,
                processIdentifier: 4242,
                windowID: 73,
                windowTitle: "Mock document",
                imageWidth: 2,
                imageHeight: 2,
                pngData: try makePNG()
            )
        )
    }

    private func makePNG() throws -> Data {
        let pixels = Data([
            0x00, 0x7A, 0xFF, 0xFF, 0xFF, 0x3B, 0x30, 0xFF,
            0x34, 0xC7, 0x59, 0xFF, 0xAF, 0x52, 0xDE, 0xFF
        ])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: 2,
                  height: 2,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: 8,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw AgentImageAttachmentError.invalidImage("無法建立測試影像")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw AgentImageAttachmentError.invalidImage("無法編碼測試 PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AgentImageAttachmentError.invalidImage("無法完成測試 PNG")
        }
        return output as Data
    }
}
