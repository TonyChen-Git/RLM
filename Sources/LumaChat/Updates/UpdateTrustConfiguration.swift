import Foundation
import LumaUpdateCore

struct LumaUpdateTrustConfiguration: Equatable, Sendable {
    static let publicKeyInfoKey = "LumaChatUpdatePublicKey"
    static let feedURLInfoKey = "LumaChatUpdateFeedURL"
    static let teamIdentifierInfoKey = "LumaChatUpdateTeamIdentifier"

    var feedURL: URL
    var publicKeyBase64: String
    var teamIdentifier: String
    var bundleIdentifier: String

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let feedValue = bundle.object(forInfoDictionaryKey: feedURLInfoKey) as? String,
              let keyValue = bundle.object(forInfoDictionaryKey: publicKeyInfoKey) as? String,
              let teamValue = bundle.object(forInfoDictionaryKey: teamIdentifierInfoKey) as? String,
              let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier == "com.lumachat.desktop",
              !keyValue.isEmpty,
              !teamValue.isEmpty else {
            throw LumaUpdateError.invalidPublicKey
        }
        let feedURL = try LumaUpdateManifestVerifier.secureURL(feedValue)
        guard let keyData = Data(base64Encoded: keyValue), keyData.count == 32 else {
            throw LumaUpdateError.invalidPublicKey
        }
        guard teamValue == teamValue.trimmingCharacters(in: .whitespacesAndNewlines),
              teamValue.utf8.count <= 64,
              teamValue.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            throw LumaUpdateError.invalidTeamIdentifier
        }
        return Self(
            feedURL: feedURL,
            publicKeyBase64: keyValue,
            teamIdentifier: teamValue,
            bundleIdentifier: bundleIdentifier
        )
    }
}
