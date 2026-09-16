import Foundation
import XCTest
@testable import LumaChat

final class AtomicFileWriterTests: XCTestCase {
    func testDurableReplacementAndSymlinkDirectoryRefusal() throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("atomic-file-writer-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("state.json")

        try AtomicFileWriter.write(Data("first".utf8), to: destination)
        try AtomicFileWriter.write(Data("second".utf8), to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".temporary-") }
        )

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: linkedDirectory.path,
            withDestinationPath: outside.path
        )
        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("must not escape".utf8),
                to: linkedDirectory.appendingPathComponent("escaped.json")
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("escaped.json").path
            )
        )
    }
}
