import Foundation

/// Internal negotiation signals. They never authorize replay of an operation.
enum MCPCompatibilityError: Error {
    case legacyHTTPServer
    case unsupportedVersion([String])
    case requestTimedOut
}

struct MCPDiscoverResult: Decodable {
    var supportedVersions: [String]
    var capabilities: JSONValue
    var instructions: String?
    var metadata: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case supportedVersions, capabilities, instructions
        case metadata = "_meta"
    }
}
