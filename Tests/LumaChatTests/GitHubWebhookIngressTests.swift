import CryptoKit
import Foundation
import XCTest
@testable import LumaChat

final class GitHubWebhookIngressTests: XCTestCase {
    func testSignedPayloadProjectsOnlyAllowlistedFields() throws {
        let secret = "test-webhook-secret-123456789"
        let body = Data(#"{"repository":{"full_name":"acme/luma"},"action":"opened","sender":{"login":"octocat"},"pull_request":{"number":9},"unsafe_command":"rm -rf /"}"#.utf8)
        let signature = HMAC<SHA256>.authenticationCode(
            for: body, using: SymmetricKey(data: Data(secret.utf8))
        ).map { String(format: "%02x", $0) }.joined()
        let headers = [
            "x-github-delivery": "ffca1b24-bc15-4430-abcc-3f4697533a38",
            "x-github-event": "pull_request",
            "x-hub-signature-256": "sha256=\(signature)"
        ]
        let event = try GitHubWebhookIngress.event(headers: headers, body: body, secret: secret)
        XCTAssertEqual(event.id, "github-body:" + SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(event.name, "github.pull_request")
        XCTAssertEqual(event.payload["pull_request_number"], "9")
        XCTAssertNil(event.payload["unsafe_command"])
        XCTAssertThrowsError(try GitHubWebhookIngress.event(
            headers: headers, body: Data("{}".utf8), secret: secret
        ))
        var replayHeaders = headers
        replayHeaders["x-github-delivery"] = UUID().uuidString
        let replay = try GitHubWebhookIngress.event(
            headers: replayHeaders, body: body, secret: secret
        )
        XCTAssertEqual(replay.id, event.id, "Unsigned delivery IDs cannot bypass replay protection")
        replayHeaders["x-github-event"] = "issues"
        XCTAssertThrowsError(try GitHubWebhookIngress.event(
            headers: replayHeaders, body: body, secret: secret
        ), "Unsigned event names must match the authenticated payload")
    }
}
