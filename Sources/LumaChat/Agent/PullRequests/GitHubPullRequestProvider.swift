import Foundation

struct GitHubPullRequestProvider: PullRequestProvider, Sendable {
    static let providerID = "github"
    static let defaultAPIBaseURL = URL(string: "https://api.github.com")!
    static let apiVersion = "2026-03-10"

    let id = Self.providerID

    private let apiBaseURL: URL
    private let token: String?
    private let transport: any PullRequestHTTPTransport
    private let now: @Sendable () -> Date

    init(
        apiBaseURL: URL = Self.defaultAPIBaseURL,
        token: String? = nil,
        transport: any PullRequestHTTPTransport = URLSessionPullRequestHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let scheme = apiBaseURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && AgentHTTPOrigin.isLoopback(apiBaseURL.host)),
              apiBaseURL.host?.isEmpty == false,
              apiBaseURL.user == nil,
              apiBaseURL.password == nil,
              apiBaseURL.query == nil,
              apiBaseURL.fragment == nil else {
            throw PullRequestProviderError.invalidEndpoint
        }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedToken, !normalizedToken.isEmpty {
            guard normalizedToken.utf8.count <= 4_096,
                  normalizedToken.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw PullRequestProviderError.invalidRequest("credential is malformed")
            }
            self.token = normalizedToken
        } else {
            self.token = nil
        }
        self.apiBaseURL = apiBaseURL
        self.transport = transport
        self.now = now
    }

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary {
        guard token != nil else { throw PullRequestProviderError.authenticationRequired }
        let repository = try repositoryComponents(request.repositoryID)
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256 else {
            throw PullRequestProviderError.invalidRequest(
                "title must contain between 1 and 256 UTF-8 bytes"
            )
        }
        if let body = request.body, body.utf8.count > 65_536 {
            throw PullRequestProviderError.invalidRequest("body exceeds 65536 UTF-8 bytes")
        }
        let head = try validatedBranch(request.headBranch, label: "headBranch")
        let base = try validatedBranch(request.baseBranch, label: "baseBranch")

        let payload = GitHubCreatePullRequest(
            title: title,
            body: request.body,
            head: head,
            base: base,
            draft: request.isDraft
        )
        var urlRequest = try authenticatedRequest(
            url: endpoint(repository: repository, suffix: ["pulls"]),
            method: "POST"
        )
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(payload)
        let response = try await transport.send(urlRequest, maximumResponseBytes: 2 * 1_024 * 1_024)
        try validate(response)
        let pull = try decode(GitHubPullRequest.self, from: response.body)
        return try summary(pull, repositoryID: request.repositoryID)
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        let identifiers = try validated(reference)
        let request = try authenticatedRequest(
            url: endpoint(
                repository: identifiers.repository,
                suffix: ["pulls", identifiers.pullRequestID]
            ),
            method: "GET"
        )
        let response = try await transport.send(request, maximumResponseBytes: 2 * 1_024 * 1_024)
        try validate(response)
        return try summary(
            decode(GitHubPullRequest.self, from: response.body),
            repositoryID: reference.repositoryID
        )
    }

    func context(
        for reference: PullRequestReference,
        maximumFiles: Int
    ) async throws -> PullRequestContext {
        guard (1...3_000).contains(maximumFiles) else {
            throw PullRequestProviderError.invalidRequest(
                "maximumFiles must be between 1 and 3000"
            )
        }
        let identifiers = try validated(reference)
        let pull = try await pullRequest(reference)
        var files: [PullRequestFile] = []
        var page = 1
        var finalPageWasFull = false

        while files.count < maximumFiles {
            try Task.checkCancellation()
            let pageSize = min(100, maximumFiles - files.count)
            var components = URLComponents(
                url: endpoint(
                    repository: identifiers.repository,
                    suffix: ["pulls", identifiers.pullRequestID, "files"]
                ),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "per_page", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page))
            ]
            guard let url = components?.url else {
                throw PullRequestProviderError.invalidEndpoint
            }
            let request = try authenticatedRequest(url: url, method: "GET")
            let response = try await transport.send(
                request,
                maximumResponseBytes: 8 * 1_024 * 1_024
            )
            try validate(response)
            let wireFiles = try decode([GitHubPullRequestFile].self, from: response.body)
            guard wireFiles.count <= pageSize else {
                throw PullRequestProviderError.malformedResponse(
                    "files page exceeded its requested bound"
                )
            }
            for wireFile in wireFiles {
                files.append(try file(wireFile))
            }
            finalPageWasFull = wireFiles.count == pageSize
            if wireFiles.count < pageSize { break }
            page += 1
        }

        let countProvesTruncation = pull.changedFileCount.map { $0 > files.count } ?? false
        return PullRequestContext(
            summary: pull,
            files: files,
            filesTruncated: countProvesTruncation
                || (files.count == maximumFiles && finalPageWasFull),
            fetchedAt: now()
        )
    }

    private func validated(
        _ reference: PullRequestReference
    ) throws -> (repository: (owner: String, name: String), pullRequestID: String) {
        guard reference.providerID == id else {
            throw PullRequestProviderError.providerUnavailable(reference.providerID)
        }
        let repository = try repositoryComponents(reference.repositoryID)
        guard let number = Int(reference.pullRequestID),
              (1...Int(Int32.max)).contains(number),
              String(number) == reference.pullRequestID else {
            throw PullRequestProviderError.invalidPullRequestID(reference.pullRequestID)
        }
        return (repository, String(number))
    }

    private func repositoryComponents(
        _ identifier: String
    ) throws -> (owner: String, name: String) {
        guard identifier.utf8.count <= 256 else {
            throw PullRequestProviderError.invalidRepositoryID(identifier)
        }
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw PullRequestProviderError.invalidRepositoryID(identifier)
        }
        let owner = String(parts[0])
        let name = String(parts[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !owner.isEmpty, !name.isEmpty,
              owner != ".", owner != "..", name != ".", name != "..",
              !name.lowercased().hasSuffix(".git"),
              owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PullRequestProviderError.invalidRepositoryID(identifier)
        }
        return (owner, name)
    }

    private func validatedBranch(_ value: String, label: String) throws -> String {
        let branch = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty,
              branch.utf8.count <= 512,
              !branch.contains("\n"),
              !branch.contains("\r"),
              !branch.contains("\0") else {
            throw PullRequestProviderError.invalidRequest("\(label) is malformed")
        }
        return branch
    }

    private func endpoint(
        repository: (owner: String, name: String),
        suffix: [String]
    ) -> URL {
        (["repos", repository.owner, repository.name] + suffix).reduce(apiBaseURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    private func authenticatedRequest(url: URL, method: String) throws -> URLRequest {
        guard AgentHTTPOrigin.isSameOrigin(apiBaseURL, url) else {
            throw PullRequestProviderError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LumaChat", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(_ response: PullRequestHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(
                GitHubErrorEnvelope.self,
                from: response.body
            ))?.message.prefix(2_000).description
            switch response.statusCode {
            case 401:
                throw PullRequestProviderError.authenticationRequired
            case 403 where response.headers["x-ratelimit-remaining"] == "0":
                throw PullRequestProviderError.rateLimited
            case 403:
                throw PullRequestProviderError.permissionDenied
            case 404:
                throw PullRequestProviderError.notFound
            case 429:
                throw PullRequestProviderError.rateLimited
            default:
                throw PullRequestProviderError.rejected(
                    statusCode: response.statusCode,
                    message: message
                )
            }
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PullRequestProviderError.malformedResponse(
                String(error.localizedDescription.prefix(1_000))
            )
        }
    }

    private func summary(
        _ pull: GitHubPullRequest,
        repositoryID: String
    ) throws -> PullRequestSummary {
        guard pull.number > 0 else {
            throw PullRequestProviderError.malformedResponse("invalid Pull Request number")
        }
        guard let webURL = URL(string: pull.htmlURL),
              webURL.scheme?.lowercased() == "https",
              webURL.host?.isEmpty == false,
              webURL.user == nil,
              webURL.password == nil else {
            throw PullRequestProviderError.malformedResponse("invalid web URL")
        }
        let state: PullRequestState
        if pull.merged == true {
            state = .merged
        } else if pull.state.lowercased() == "open" {
            state = .open
        } else {
            state = .closed
        }
        return PullRequestSummary(
            reference: PullRequestReference(
                providerID: id,
                repositoryID: repositoryID,
                pullRequestID: String(pull.number)
            ),
            title: String(pull.title.prefix(2_000)),
            body: pull.body.map { String($0.prefix(65_536)) },
            webURL: webURL,
            state: state,
            isDraft: pull.draft ?? false,
            baseBranch: String(pull.base.ref.prefix(512)),
            headBranch: String(pull.head.ref.prefix(512)),
            author: pull.user?.login.map { String($0.prefix(256)) },
            mergeable: pull.mergeable,
            changedFileCount: pull.changedFiles
        )
    }

    private func file(_ wire: GitHubPullRequestFile) throws -> PullRequestFile {
        let path = try validatedPath(wire.filename)
        let previousPath = try wire.previousFilename.map(validatedPath)
        let rawStatus = PullRequestFileStatus(rawValue: wire.status.lowercased()) ?? .unknown
        let patch: String?
        if let value = wire.patch, value.utf8.count <= 1 * 1_024 * 1_024 {
            patch = value
        } else {
            patch = nil
        }
        return PullRequestFile(
            path: path,
            previousPath: previousPath,
            status: rawStatus,
            additions: max(0, wire.additions),
            deletions: max(0, wire.deletions),
            changes: max(0, wire.changes),
            patch: patch,
            isPatchUnavailable: wire.changes > 0 && patch == nil
        )
    }

    private func validatedPath(_ path: String) throws -> String {
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r"),
              !NSString(string: path).pathComponents.contains("..") else {
            throw PullRequestProviderError.malformedResponse("unsafe file path")
        }
        return path
    }
}

private struct GitHubCreatePullRequest: Encodable {
    var title: String
    var body: String?
    var head: String
    var base: String
    var draft: Bool
}

private struct GitHubPullRequest: Decodable {
    struct User: Decodable { var login: String? }
    struct Branch: Decodable { var ref: String }

    var number: Int
    var title: String
    var body: String?
    var htmlURL: String
    var state: String
    var draft: Bool?
    var merged: Bool?
    var mergeable: Bool?
    var changedFiles: Int?
    var user: User?
    var head: Branch
    var base: Branch

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, draft, merged, mergeable, user, head, base
        case htmlURL = "html_url"
        case changedFiles = "changed_files"
    }
}

private struct GitHubPullRequestFile: Decodable {
    var filename: String
    var previousFilename: String?
    var status: String
    var additions: Int
    var deletions: Int
    var changes: Int
    var patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, changes, patch
        case previousFilename = "previous_filename"
    }
}

private struct GitHubErrorEnvelope: Decodable {
    var message: String
}
