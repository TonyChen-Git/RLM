import CryptoKit
import Foundation

enum GitHubWebhookIngressError: Error, Equatable, Sendable {
    case unavailable
    case invalidEnvelope
    case invalidSignature
}

/// Validates the original HTTP body before projecting a small allowlisted
/// payload into Automation. No webhook field is executable authority.
enum GitHubWebhookIngress {
    static let maximumBodyBytes = 1 * 1_024 * 1_024

    static func event(
        headers: [String: String], body: Data, secret: String
    ) throws -> AutomationEvent {
        guard secret.utf8.count >= 16, secret.utf8.count <= 4_096 else {
            throw GitHubWebhookIngressError.unavailable
        }
        guard !body.isEmpty, body.count <= maximumBodyBytes,
              let delivery = headers["x-github-delivery"],
              UUID(uuidString: delivery) != nil,
              let kind = headers["x-github-event"],
              ["push", "pull_request", "issues", "issue_comment",
               "check_run", "workflow_run"].contains(kind),
              let signature = headers["x-hub-signature-256"],
              signature.hasPrefix("sha256="), signature.utf8.count == 71,
              let received = Data(hex: String(signature.dropFirst(7))) else {
            throw GitHubWebhookIngressError.invalidEnvelope
        }
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: body, using: key))
        guard constantTimeEqual(received, expected) else {
            throw GitHubWebhookIngressError.invalidSignature
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let repository = object["repository"] as? [String: Any],
              let repositoryName = repository["full_name"] as? String,
              repositoryName.utf8.count <= 256,
              repositoryName.split(separator: "/").count == 2,
              signedPayloadKind(object) == kind else {
            throw GitHubWebhookIngressError.invalidEnvelope
        }
        var payload = ["repository": repositoryName, "event": kind]
        if let action = object["action"] as? String {
            guard !action.isEmpty, action.utf8.count <= 64,
                  action.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
                  }) else { throw GitHubWebhookIngressError.invalidEnvelope }
            payload["action"] = action
        }
        if let sender = object["sender"] as? [String: Any],
           let login = sender["login"] as? String, login.utf8.count <= 256 {
            payload["sender"] = login
        }
        if let pull = object["pull_request"] as? [String: Any],
           let number = pull["number"] as? Int, number > 0 {
            payload["pull_request_number"] = String(number)
        }
        if let commit = object["after"] as? String,
           commit.utf8.count <= 64,
           commit.utf8.allSatisfy({ byte in
               (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
           }) {
            payload["after"] = commit
        }
        return AutomationEvent(
            // GitHub signs only the body. Delivery and event headers are not
            // authenticated, so a changed delivery UUID must not bypass replay
            // protection and an event header must agree with the signed shape.
            id: "github-body:" + SHA256.hash(data: body)
                .map { String(format: "%02x", $0) }.joined(),
            name: "github.\(kind)",
            payload: payload
        )
    }

    private static func signedPayloadKind(_ object: [String: Any]) -> String? {
        let markers = ["pull_request", "check_run", "workflow_run"].filter {
            object[$0] as? [String: Any] != nil
        }
        if markers.count == 1, object["issue"] == nil, object["comment"] == nil {
            return markers[0]
        }
        guard markers.isEmpty else { return nil }
        if object["issue"] as? [String: Any] != nil {
            return object["comment"] as? [String: Any] != nil ? "issue_comment" : "issues"
        }
        guard object["comment"] == nil,
              object["ref"] is String,
              object["before"] is String,
              object["after"] is String else { return nil }
        return "push"
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        var difference = lhs.count ^ rhs.count
        let a = Array(lhs), b = Array(rhs)
        for index in 0..<max(a.count, b.count) {
            difference |= Int((index < a.count ? a[index] : 0)
                ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.utf8.count / 2)
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let upper = high.hexNibble, let lower = low.hexNibble else { return nil }
            bytes.append((upper << 4) | lower)
        }
        self.init(bytes)
    }
}

private extension UInt8 {
    var hexNibble: UInt8? {
        switch self {
        case 48...57: self - 48
        case 65...70: self - 55
        case 97...102: self - 87
        default: nil
        }
    }
}
