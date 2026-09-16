import Foundation

public enum LumaUpdateOperation: String, Codable, Sendable {
    case install
    case rollback
}

public enum LumaUpdateJournalStage: String, Codable, Sendable {
    case planned
    case prepared
    case helperLaunched
    case backupCreated
    case swapped
    case launchRequested
    case confirmed
    case rolledBack
    case failed
}

/// The signed feed wraps the exact payload bytes instead of relying on an
/// implementation-specific JSON canonicalizer. `payload` and `signature` are
/// standard padded Base64 strings. Only the decoded payload is trusted.
public struct LumaUpdateManifestEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var payload: String
    public var signature: String

    public init(schemaVersion: Int = 1, payload: String, signature: String) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.signature = signature
    }
}

public struct LumaUpdateRelease: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var releaseID: UUID
    public var version: String
    public var build: Int
    public var publishedAt: String
    public var minimumSystemVersion: String
    public var archiveURL: String
    public var archiveSHA256: String
    public var archiveSize: Int64
    public var applicationSHA256: String
    public var bundleIdentifier: String
    public var teamIdentifier: String
    public var architectures: [String]
    public var notarized: Bool
    public var releaseNotesURL: String?

    public init(
        schemaVersion: Int = 1,
        releaseID: UUID,
        version: String,
        build: Int,
        publishedAt: String,
        minimumSystemVersion: String,
        archiveURL: String,
        archiveSHA256: String,
        archiveSize: Int64,
        applicationSHA256: String,
        bundleIdentifier: String,
        teamIdentifier: String,
        architectures: [String],
        notarized: Bool,
        releaseNotesURL: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.releaseID = releaseID
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.archiveURL = archiveURL
        self.archiveSHA256 = archiveSHA256
        self.archiveSize = archiveSize
        self.applicationSHA256 = applicationSHA256
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.architectures = architectures
        self.notarized = notarized
        self.releaseNotesURL = releaseNotesURL
    }
}

public struct LumaVerifiedUpdate: Equatable, Sendable {
    public var release: LumaUpdateRelease
    public var envelopeData: Data
    public var payloadData: Data

    public init(release: LumaUpdateRelease, envelopeData: Data, payloadData: Data) {
        self.release = release
        self.envelopeData = envelopeData
        self.payloadData = payloadData
    }
}

public struct LumaUpdateInstallRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var operation: LumaUpdateOperation
    public var installationID: UUID
    public var parentProcessIdentifier: Int32
    public var currentApplicationPath: String
    public var candidateApplicationPath: String
    public var backupApplicationPath: String
    public var journalPath: String
    public var confirmationPath: String
    public var manifestEnvelopeBase64: String?
    public var expectedBundleIdentifier: String
    public var expectedTeamIdentifier: String
    public var expectedVersion: String
    public var expectedBuild: Int
    public var createdAt: Date

    public init(
        schemaVersion: Int = 1,
        operation: LumaUpdateOperation,
        installationID: UUID,
        parentProcessIdentifier: Int32,
        currentApplicationPath: String,
        candidateApplicationPath: String,
        backupApplicationPath: String,
        journalPath: String,
        confirmationPath: String,
        manifestEnvelopeBase64: String?,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        expectedVersion: String,
        expectedBuild: Int,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.installationID = installationID
        self.parentProcessIdentifier = parentProcessIdentifier
        self.currentApplicationPath = currentApplicationPath
        self.candidateApplicationPath = candidateApplicationPath
        self.backupApplicationPath = backupApplicationPath
        self.journalPath = journalPath
        self.confirmationPath = confirmationPath
        self.manifestEnvelopeBase64 = manifestEnvelopeBase64
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedVersion = expectedVersion
        self.expectedBuild = expectedBuild
        self.createdAt = createdAt
    }
}

public struct LumaUpdateJournal: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var operation: LumaUpdateOperation
    public var installationID: UUID
    public var stage: LumaUpdateJournalStage
    public var fromVersion: String
    public var fromBuild: Int
    public var toVersion: String
    public var toBuild: Int
    public var currentApplicationPath: String
    public var candidateApplicationPath: String
    public var backupApplicationPath: String
    public var confirmationPath: String
    public var expectedBundleIdentifier: String
    public var expectedTeamIdentifier: String
    public var startedAt: Date
    public var updatedAt: Date
    public var failure: String?

    public init(
        schemaVersion: Int = 1,
        operation: LumaUpdateOperation,
        installationID: UUID,
        stage: LumaUpdateJournalStage,
        fromVersion: String,
        fromBuild: Int,
        toVersion: String,
        toBuild: Int,
        currentApplicationPath: String,
        candidateApplicationPath: String,
        backupApplicationPath: String,
        confirmationPath: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        failure: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.installationID = installationID
        self.stage = stage
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        self.toVersion = toVersion
        self.toBuild = toBuild
        self.currentApplicationPath = currentApplicationPath
        self.candidateApplicationPath = candidateApplicationPath
        self.backupApplicationPath = backupApplicationPath
        self.confirmationPath = confirmationPath
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.failure = failure
    }
}

public struct LumaSemanticVersion: Comparable, Equatable, Sendable {
    public let components: [Int]

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 64 else {
            throw LumaUpdateError.invalidVersion
        }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(pieces.count) else { throw LumaUpdateError.invalidVersion }
        var parsed: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.allSatisfy({ $0.isNumber }),
                  (piece == "0" || !piece.hasPrefix("0")),
                  let number = Int(piece),
                  (0...999_999).contains(number) else {
                throw LumaUpdateError.invalidVersion
            }
            parsed.append(number)
        }
        components = parsed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public enum LumaUpdateError: LocalizedError, Equatable, Sendable {
    case invalidEnvelope
    case unsupportedSchema
    case invalidBase64
    case invalidPublicKey
    case invalidSignature
    case invalidPayload
    case invalidVersion
    case invalidBuild
    case invalidPublishedDate
    case invalidURL
    case invalidArchiveHash
    case invalidArchiveSize
    case invalidBundleIdentifier
    case invalidTeamIdentifier
    case invalidArchitecture
    case updateNotNotarized
    case incompatibleSystem
    case untrustedApplication(String)
    case invalidInstallRequest
    case unsafePath(String)
    case processFailure(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope: "The update envelope is malformed or contains unknown fields."
        case .unsupportedSchema: "The update schema version is unsupported."
        case .invalidBase64: "The update payload or signature is not valid Base64."
        case .invalidPublicKey: "The embedded update public key is missing or invalid."
        case .invalidSignature: "The update signature is invalid."
        case .invalidPayload: "The signed update payload is malformed or contains unknown fields."
        case .invalidVersion: "The update version is not a supported numeric version."
        case .invalidBuild: "The update build number is invalid."
        case .invalidPublishedDate: "The update publication timestamp is invalid."
        case .invalidURL: "The update URL must be credential-free HTTPS."
        case .invalidArchiveHash: "The update SHA-256 value is invalid."
        case .invalidArchiveSize: "The update archive size is invalid."
        case .invalidBundleIdentifier: "The update bundle identifier does not match LumaChat."
        case .invalidTeamIdentifier: "The update signing Team ID is invalid."
        case .invalidArchitecture: "The update does not support this architecture."
        case .updateNotNotarized: "The update feed does not require a notarized application."
        case .incompatibleSystem: "The update requires a newer macOS version."
        case .untrustedApplication(let detail): "The application signature is not trusted: \(detail)"
        case .invalidInstallRequest: "The update helper request is invalid."
        case .unsafePath(let path): "The update path is unsafe: \(path)"
        case .processFailure(let detail): "An update verification process failed: \(detail)"
        case .persistenceFailure(let detail): "Update state could not be persisted: \(detail)"
        }
    }
}
