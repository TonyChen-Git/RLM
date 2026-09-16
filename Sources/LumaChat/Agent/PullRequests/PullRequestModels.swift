import Foundation

struct PullRequestProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    var providerID: String
    var apiEndpoint: String

    var id: String { providerID }

    static let github = Self(
        providerID: "github",
        apiEndpoint: "https://api.github.com"
    )

    func normalized() throws -> Self {
        let provider = providerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !provider.isEmpty,
              provider.utf8.count <= 64,
              provider.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "._-"))
                      .contains($0)
              }) else {
            throw PullRequestProviderError.invalidRequest("providerID is malformed")
        }

        let candidate = apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.utf8.count <= 4_096,
              !candidate.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let strictURL = URL(
                  string: candidate,
                  encodingInvalidCharacters: false
              ),
              var components = URLComponents(
                  url: strictURL,
                  resolvingAgainstBaseURL: false
              ),
              let scheme = components.scheme?.lowercased(),
              scheme == "https"
                  || (scheme == "http" && AgentHTTPOrigin.isLoopback(components.host)),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw PullRequestProviderError.invalidEndpoint
        }
        components.scheme = scheme
        components.host = host
        if components.path == "/" {
            components.path = ""
        } else {
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        guard let endpoint = components.url?.absoluteString,
              endpoint.utf8.count <= 4_096 else {
            throw PullRequestProviderError.invalidEndpoint
        }
        return Self(providerID: provider, apiEndpoint: endpoint)
    }
}

struct PullRequestReference: Codable, Equatable, Hashable, Sendable {
    var providerID: String
    var repositoryID: String
    var pullRequestID: String
}

struct PullRequestCreateRequest: Codable, Equatable, Sendable {
    var repositoryID: String
    var title: String
    var body: String?
    var headBranch: String
    var baseBranch: String
    var isDraft: Bool
}

enum PullRequestState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case merged
}

struct PullRequestSummary: Codable, Equatable, Sendable {
    var reference: PullRequestReference
    var title: String
    var body: String?
    var webURL: URL
    var state: PullRequestState
    var isDraft: Bool
    var baseBranch: String
    var headBranch: String
    var author: String?
    var mergeable: Bool?
    var changedFileCount: Int?
}

enum PullRequestFileStatus: String, Codable, Equatable, Sendable {
    case added
    case modified
    case removed
    case renamed
    case copied
    case changed
    case unchanged
    case unknown
}

struct PullRequestFile: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var previousPath: String?
    var status: PullRequestFileStatus
    var additions: Int
    var deletions: Int
    var changes: Int
    var patch: String?
    var isPatchUnavailable: Bool

    var id: String { path }
}

struct PullRequestContext: Codable, Equatable, Sendable {
    var summary: PullRequestSummary
    var files: [PullRequestFile]
    var filesTruncated: Bool
    var fetchedAt: Date
}

enum PullRequestProviderError: LocalizedError, Equatable, Sendable {
    case duplicateProvider(String)
    case providerUnavailable(String)
    case invalidEndpoint
    case invalidRepositoryID(String)
    case invalidPullRequestID(String)
    case invalidRequest(String)
    case authenticationRequired
    case permissionDenied
    case notFound
    case rateLimited
    case rejected(statusCode: Int, message: String?)
    case redirectRejected
    case responseTooLarge(Int)
    case malformedResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .duplicateProvider(let provider):
            "Pull Request provider is registered more than once: \(provider)"
        case .providerUnavailable(let provider):
            "Pull Request provider is unavailable: \(provider)"
        case .invalidEndpoint:
            "Pull Request provider endpoint must be a credential-free HTTPS origin."
        case .invalidRepositoryID(let value):
            "Invalid repository identifier: \(value)"
        case .invalidPullRequestID(let value):
            "Invalid Pull Request identifier: \(value)"
        case .invalidRequest(let detail):
            "Invalid Pull Request request: \(detail)"
        case .authenticationRequired:
            "The Pull Request provider requires authentication."
        case .permissionDenied:
            "The Pull Request provider denied this operation."
        case .notFound:
            "The Pull Request or repository was not found."
        case .rateLimited:
            "The Pull Request provider rate limit was reached."
        case .rejected(let statusCode, let message):
            if let message, !message.isEmpty {
                "Pull Request provider returned HTTP \(statusCode): \(message)"
            } else {
                "Pull Request provider returned HTTP \(statusCode)."
            }
        case .redirectRejected:
            "Pull Request provider redirects are not followed."
        case .responseTooLarge(let limit):
            "Pull Request provider response exceeded \(limit) bytes."
        case .malformedResponse(let detail):
            "Malformed Pull Request provider response: \(detail)"
        case .network(let detail):
            "Pull Request provider network error: \(detail)"
        }
    }
}
