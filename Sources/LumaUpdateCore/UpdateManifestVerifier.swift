import CryptoKit
import Foundation

public enum LumaUpdateManifestVerifier {
    public static let maximumEnvelopeBytes = 64 * 1_024
    public static let maximumPayloadBytes = 32 * 1_024
    public static let maximumArchiveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    public static func verify(
        envelopeData: Data,
        publicKeyBase64: String,
        expectedBundleIdentifier: String,
        currentArchitecture: String,
        currentSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> LumaVerifiedUpdate {
        guard !envelopeData.isEmpty, envelopeData.count <= maximumEnvelopeBytes else {
            throw LumaUpdateError.invalidEnvelope
        }
        try requireExactKeys(
            data: envelopeData,
            required: ["schemaVersion", "payload", "signature"],
            optional: []
        )
        let decoder = JSONDecoder()
        let envelope: LumaUpdateManifestEnvelope
        do {
            envelope = try decoder.decode(LumaUpdateManifestEnvelope.self, from: envelopeData)
        } catch {
            throw LumaUpdateError.invalidEnvelope
        }
        guard envelope.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        guard let payloadData = Data(base64Encoded: envelope.payload),
              !payloadData.isEmpty,
              payloadData.count <= maximumPayloadBytes,
              let signatureData = Data(base64Encoded: envelope.signature),
              signatureData.count == 64 else {
            throw LumaUpdateError.invalidBase64
        }
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw LumaUpdateError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw LumaUpdateError.invalidSignature
        }

        try requireExactKeys(
            data: payloadData,
            required: [
                "schemaVersion", "releaseID", "version", "build", "publishedAt",
                "minimumSystemVersion", "archiveURL", "archiveSHA256", "archiveSize",
                "applicationSHA256", "bundleIdentifier", "teamIdentifier", "architectures",
                "notarized"
            ],
            optional: ["releaseNotesURL"]
        )
        let release: LumaUpdateRelease
        do {
            release = try decoder.decode(LumaUpdateRelease.self, from: payloadData)
        } catch {
            throw LumaUpdateError.invalidPayload
        }
        try validate(
            release,
            expectedBundleIdentifier: expectedBundleIdentifier,
            currentArchitecture: currentArchitecture,
            currentSystemVersion: currentSystemVersion
        )
        return LumaVerifiedUpdate(
            release: release,
            envelopeData: envelopeData,
            payloadData: payloadData
        )
    }

    public static func secureURL(_ value: String) throws -> URL {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            throw LumaUpdateError.invalidURL
        }
        return url
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(
        _ release: LumaUpdateRelease,
        expectedBundleIdentifier: String,
        currentArchitecture: String,
        currentSystemVersion: OperatingSystemVersion
    ) throws {
        guard release.schemaVersion == 1 else { throw LumaUpdateError.unsupportedSchema }
        _ = try LumaSemanticVersion(release.version)
        _ = try LumaSemanticVersion(release.minimumSystemVersion)
        guard (1...Int(Int32.max)).contains(release.build) else {
            throw LumaUpdateError.invalidBuild
        }
        guard ISO8601DateFormatter().date(from: release.publishedAt) != nil else {
            throw LumaUpdateError.invalidPublishedDate
        }
        _ = try secureURL(release.archiveURL)
        if let notes = release.releaseNotesURL { _ = try secureURL(notes) }
        guard release.archiveSHA256.count == 64,
              release.archiveSHA256 == release.archiveSHA256.lowercased(),
              release.archiveSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw LumaUpdateError.invalidArchiveHash
        }
        guard release.applicationSHA256.count == 64,
              release.applicationSHA256 == release.applicationSHA256.lowercased(),
              release.applicationSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw LumaUpdateError.invalidArchiveHash
        }
        guard (1...maximumArchiveBytes).contains(release.archiveSize) else {
            throw LumaUpdateError.invalidArchiveSize
        }
        guard release.bundleIdentifier == expectedBundleIdentifier,
              !expectedBundleIdentifier.isEmpty else {
            throw LumaUpdateError.invalidBundleIdentifier
        }
        guard isExactIdentifier(release.teamIdentifier, maximumBytes: 64) else {
            throw LumaUpdateError.invalidTeamIdentifier
        }
        guard (1...8).contains(release.architectures.count),
              Set(release.architectures).count == release.architectures.count,
              release.architectures.allSatisfy({ isExactIdentifier($0, maximumBytes: 32) }),
              release.architectures.contains(currentArchitecture)
                || release.architectures.contains("universal") else {
            throw LumaUpdateError.invalidArchitecture
        }
        guard release.notarized else { throw LumaUpdateError.updateNotNotarized }

        let minimum = try LumaSemanticVersion(release.minimumSystemVersion)
        let current = try LumaSemanticVersion(
            "\(currentSystemVersion.majorVersion).\(currentSystemVersion.minorVersion).\(max(0, currentSystemVersion.patchVersion))"
        )
        guard current >= minimum else { throw LumaUpdateError.incompatibleSystem }
    }

    private static func isExactIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
    }

    private static func requireExactKeys(
        data: Data,
        required: Set<String>,
        optional: Set<String>
    ) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw LumaUpdateError.invalidPayload
        }
        guard let object = value as? [String: Any],
              required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else {
            throw LumaUpdateError.invalidPayload
        }
    }
}
