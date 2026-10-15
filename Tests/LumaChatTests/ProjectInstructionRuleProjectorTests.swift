import XCTest
@testable import LumaChat

final class ProjectInstructionRuleProjectorTests: XCTestCase {
    func testScopeAndManualActivationArePreserved() {
        let rules = [
            rule("always", .always),
            rule("swift", .files(["Sources/**/*.swift"])),
            rule("manual", .manual),
            rule("requested", .agentRequested("Review naming"))
        ]
        let projector = ProjectInstructionRuleProjector()
        let unrelated = projector.project(
            rules: rules,
            messages: [AgentMessage(role: .user, content: "Review README.md")]
        )?.content ?? ""
        XCTAssertTrue(unrelated.contains("always"))
        XCTAssertFalse(unrelated.contains("swift"))
        XCTAssertFalse(unrelated.contains("manual"))
        XCTAssertFalse(unrelated.contains("requested"))

        let relevant = projector.project(
            rules: rules,
            messages: [AgentMessage(role: .user,
                                    content: "Edit Sources/LumaChat/Agent/Core/AgentRuntime.swift using @manual")]
        )?.content ?? ""
        XCTAssertTrue(relevant.contains("always"))
        XCTAssertTrue(relevant.contains("swift"))
        XCTAssertTrue(relevant.contains("manual"))
        XCTAssertFalse(relevant.contains("requested"))
    }

    func testToolDiscoveredPathActivatesOnSubsequentTurn() {
        let projector = ProjectInstructionRuleProjector()
        let rule = rule("swift", .files(["Sources/**/*.swift"]))
        XCTAssertNil(projector.project(rules: [rule],
                                       messages: [AgentMessage(role: .user, content: "Inspect the code")]))
        XCTAssertNotNil(projector.project(rules: [rule], messages: [
            AgentMessage(role: .user, content: "Inspect the code"),
            AgentMessage(role: .tool, content: "Sources/LumaChat/Views/SettingsView.swift")
        ]))
    }

    func testContextBudgetIncludesHeadersAndSectionSeparators() throws {
        let projector = ProjectInstructionRuleProjector()
        let oversized = ProjectInstructionImportComponent(
            relativePath: "large.mdc",
            redactedContent: String(repeating: "x", count: ProjectInstructionRuleProjector.maximumProjectionBytes - 30),
            sourceByteCount: ProjectInstructionRuleProjector.maximumProjectionBytes - 30,
            scope: .always
        )
        XCTAssertNil(projector.project(rules: [oversized], messages: []))
        let rules = (0..<32).map { index in
            ProjectInstructionImportComponent(
                relativePath: "rule-\(index).mdc",
                redactedContent: String(repeating: "x", count: 1_003),
                sourceByteCount: 1_003,
                scope: .always
            )
        }
        let projection = try XCTUnwrap(projector.project(rules: rules, messages: []))
        XCTAssertLessThanOrEqual(projection.content.utf8.count,
                                 ProjectInstructionRuleProjector.maximumProjectionBytes)
    }

    private func rule(_ name: String, _ scope: ProjectInstructionImportScope)
        -> ProjectInstructionImportComponent {
        ProjectInstructionImportComponent(
            relativePath: ".cursor/rules/\(name).mdc",
            redactedContent: "\(name) instruction",
            sourceByteCount: 32,
            scope: scope
        )
    }
}
