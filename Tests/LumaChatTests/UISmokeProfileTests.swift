import Foundation
import XCTest

@testable import LumaChat

final class UISmokeProfileTests: XCTestCase {
    func testPackagedUISmokeRequiresAnExplicitMarkedProfile() throws {
        let root = AppPaths.projectTemporaryRoot.appendingPathComponent(
            "ui-smoke-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("ui-smoke-profile.example", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        XCTAssertNil(AppPaths.validatedUISmokeProfile(at: profile.path))

        let marker = profile.appendingPathComponent(AppPaths.uiSmokeProfileMarker)
        try AppPaths.uiSmokeProfileMarkerContents.write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(AppPaths.validatedUISmokeProfile(at: profile.path), profile)
        XCTAssertNil(AppPaths.validatedUISmokeProfile(at: "relative/path"))
        XCTAssertNil(AppPaths.validatedUISmokeProfile(at: "\(profile.path) "))

        let unmarkedParent = root.appendingPathComponent("other", isDirectory: true)
            .appendingPathComponent("ui-smoke-profile.example", isDirectory: true)
        try FileManager.default.createDirectory(at: unmarkedParent, withIntermediateDirectories: true)
        try AppPaths.uiSmokeProfileMarkerContents.write(
            to: unmarkedParent.appendingPathComponent(AppPaths.uiSmokeProfileMarker),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertNil(AppPaths.validatedUISmokeProfile(at: unmarkedParent.path))

        try FileManager.default.removeItem(at: marker)
        try "wrong marker\n".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertNil(AppPaths.validatedUISmokeProfile(at: profile.path))
    }
}
