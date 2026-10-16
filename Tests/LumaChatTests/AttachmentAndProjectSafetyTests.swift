import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class AttachmentAndProjectSafetyTests: XCTestCase {
    func testUnknownRegularFileCanBeDraggedAsGenericAttachment() async throws {
        let sourceRoot = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "attachment-inputs-\(UUID().uuidString)", isDirectory: true
        )
        let conversationID = UUID()
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: AppPaths.conversationDirectory(conversationID))
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let source = sourceRoot.appendingPathComponent("sample.unknown-binary")
        try Data([0, 1, 2, 3, 4, 5]).write(to: source)
        let prepared = try await AttachmentService().prepare(urls: [source], for: conversationID)

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.attachment.kind, .file)
        XCTAssertEqual(prepared.first?.attachment.mimeType, "application/octet-stream")
        XCTAssertNotNil(prepared.first?.attachment.relativePath)
    }

    func testProjectDestinationCannotEscapeRootOrUseSymlink() throws {
        let base = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "project-path-tests-\(UUID().uuidString)", isDirectory: true
        )
        let root = base.appendingPathComponent("root", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

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
