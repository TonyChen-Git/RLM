import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AttachmentAndProjectSafetyTests: XCTestCase {
    func testUnknownRegularFileCanBeDraggedAsGenericAttachment() async throws {
        let runtimeRoot = URL(fileURLWithPath: "/Volumes/SD/Code/RLM/tmp/test-app-support", isDirectory: true)
        let sourceRoot = URL(fileURLWithPath: "/Volumes/SD/Code/RLM/tmp/test-inputs", isDirectory: true)
        try? FileManager.default.removeItem(at: runtimeRoot)
        try? FileManager.default.removeItem(at: sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        setenv("LUMACHAT_APP_SUPPORT_PATH", runtimeRoot.path, 1)
        defer {
            try? FileManager.default.removeItem(at: runtimeRoot)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let source = sourceRoot.appendingPathComponent("sample.unknown-binary")
        try Data([0, 1, 2, 3, 4, 5]).write(to: source)
        let conversationID = UUID()
        let prepared = try await AttachmentService().prepare(urls: [source], for: conversationID)

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.attachment.kind, .file)
        XCTAssertEqual(prepared.first?.attachment.mimeType, "application/octet-stream")
        XCTAssertNotNil(prepared.first?.attachment.relativePath)
    }

    func testProjectDestinationCannotEscapeRootOrUseSymlink() throws {
        let base = URL(fileURLWithPath: "/Volumes/SD/Code/RLM/tmp/project-path-tests", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertThrowsError(
            try ProjectService.validatedDestination(outside.appendingPathComponent("escape.txt"), within: root)
        )

        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outsideFile)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try ProjectService.validatedDestination(link, within: root))

        let valid = try ProjectService.validatedDestination(root.appendingPathComponent("safe.txt"), within: root)
        XCTAssertEqual(valid.lastPathComponent, "safe.txt")
    }
}
