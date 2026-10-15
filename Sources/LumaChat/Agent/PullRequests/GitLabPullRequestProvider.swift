import Foundation

struct GitLabPullRequestProvider: PullRequestProvider, Sendable {
    static let providerID = "gitlab"
    static let defaultAPIBaseURL = URL(string: "https://gitlab.com/api/v4")!
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
        let normalized = try PullRequestProviderConfiguration(
            providerID: Self.providerID, apiEndpoint: apiBaseURL.absoluteString
        ).normalized()
        guard let url = URL(string: normalized.apiEndpoint),
              url.path.hasSuffix("/api/v4") else {
            throw PullRequestProviderError.invalidEndpoint
        }
        self.apiBaseURL = url
        self.token = try token.map(PullRequestCredentialStore.normalizedToken)
        self.transport = transport
        self.now = now
    }

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary {
        guard token != nil else { throw PullRequestProviderError.authenticationRequired }
        let repository = try validatedRepository(request.repositoryID)
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 256,
              (request.body?.utf8.count ?? 0) <= 65_536 else {
            throw PullRequestProviderError.invalidRequest("title or body exceeds its bound")
        }
        let source = try validatedBranch(request.headBranch)
        let target = try validatedBranch(request.baseBranch)
        let payload = GitLabCreateMergeRequest(
            sourceBranch: source, targetBranch: target,
            title: request.isDraft && !title.lowercased().hasPrefix("draft:")
                ? "Draft: \(title)" : title,
            description: request.body
        )
        var http = try authenticatedRequest(
            endpoint(repository: repository, suffix: ["merge_requests"]), method: "POST"
        )
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        http.httpBody = try encoder.encode(payload)
        let response = try await transport.send(http, maximumResponseBytes: 2 * 1_024 * 1_024)
        try validate(response)
        return try summary(decode(GitLabMergeRequest.self, response.body), repository: repository)
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        let (repository, iid) = try validated(reference)
        let request = try authenticatedRequest(
            endpoint(repository: repository, suffix: ["merge_requests", iid]), method: "GET"
        )
        let response = try await transport.send(request, maximumResponseBytes: 2 * 1_024 * 1_024)
        try validate(response)
        return try summary(decode(GitLabMergeRequest.self, response.body), repository: repository)
    }

    func context(for reference: PullRequestReference, maximumFiles: Int) async throws -> PullRequestContext {
        guard (1...3_000).contains(maximumFiles) else {
            throw PullRequestProviderError.invalidRequest("maximumFiles must be 1...3000")
        }
        let (repository, iid) = try validated(reference)
        let pull = try await pullRequest(reference)
        var files: [PullRequestFile] = []
        var page = 1
        var truncated = false
        var remainingBytes = 32 * 1_024 * 1_024
        while files.count < maximumFiles {
            try Task.checkCancellation()
            guard page <= 50 else {
                throw PullRequestProviderError.malformedResponse("diff pagination exceeds 50 pages")
            }
            let pageSize = min(100, maximumFiles - files.count)
            var url = URLComponents(
                url: endpoint(repository: repository, suffix: ["merge_requests", iid, "diffs"]),
                resolvingAgainstBaseURL: false
            )!
            url.queryItems = [URLQueryItem(name: "page", value: String(page)),
                              URLQueryItem(name: "per_page", value: String(pageSize))]
            guard let pageURL = url.url else { throw PullRequestProviderError.invalidEndpoint }
            let response = try await transport.send(
                authenticatedRequest(pageURL, method: "GET"),
                maximumResponseBytes: 8 * 1_024 * 1_024
            )
            try validate(response)
            guard response.body.count <= remainingBytes else {
                throw PullRequestProviderError.malformedResponse("diff context exceeds 32 MiB")
            }
            remainingBytes -= response.body.count
            let wire = try decode([GitLabMergeRequestDiff].self, response.body)
            guard wire.count <= pageSize else {
                throw PullRequestProviderError.malformedResponse("diff page exceeds requested bound")
            }
            files += try wire.map(file)
            if let next = response.headers["x-next-page"], !next.isEmpty {
                guard !wire.isEmpty, Int(next) == page + 1 else {
                    throw PullRequestProviderError.malformedResponse("invalid diff pagination")
                }
                if files.count >= maximumFiles { truncated = true; break }
                page += 1
            } else {
                // GitLab can omit next-page on a full final page. Be conservative.
                truncated = wire.count == pageSize && files.count >= maximumFiles
                break
            }
        }
        return PullRequestContext(
            summary: pull, files: files,
            filesTruncated: truncated || files.contains(where: \.isPatchUnavailable)
                || (pull.changedFileCount.map { $0 > files.count } ?? false),
            fetchedAt: now()
        )
    }

    private func validated(_ reference: PullRequestReference) throws -> (String, String) {
        guard reference.providerID == id else {
            throw PullRequestProviderError.providerUnavailable(reference.providerID)
        }
        let repository = try validatedRepository(reference.repositoryID)
        guard let iid = Int(reference.pullRequestID), iid > 0, iid <= Int(Int32.max),
              String(iid) == reference.pullRequestID else {
            throw PullRequestProviderError.invalidPullRequestID(reference.pullRequestID)
        }
        return (repository, String(iid))
    }

    private func validatedRepository(_ value: String) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.utf8.count <= 256, (2...16).contains(parts.count),
              parts.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".."
                      && part.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw PullRequestProviderError.invalidRepositoryID(value)
        }
        return value
    }

    private func validatedBranch(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PullRequestProviderError.invalidRequest("branch is malformed")
        }
        return value
    }

    private func endpoint(repository: String, suffix: [String]) -> URL {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        let encoded = repository.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        components.percentEncodedPath += "/projects/\(encoded)"
        for part in suffix {
            components.percentEncodedPath += "/\(part)"
        }
        return components.url!
    }

    private func authenticatedRequest(_ url: URL, method: String) throws -> URLRequest {
        guard AgentHTTPOrigin.isSameOrigin(apiBaseURL, url) else {
            throw PullRequestProviderError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LumaChat", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN") }
        return request
    }

    private func validate(_ response: PullRequestHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw PullRequestProviderError.authenticationRequired
        case 403: throw PullRequestProviderError.permissionDenied
        case 404: throw PullRequestProviderError.notFound
        case 429: throw PullRequestProviderError.rateLimited
        default: throw PullRequestProviderError.rejected(
            statusCode: response.statusCode, message: nil
        )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(type, from: data) }
        catch { throw PullRequestProviderError.malformedResponse("invalid GitLab response") }
    }

    private func summary(_ wire: GitLabMergeRequest, repository: String) throws -> PullRequestSummary {
        guard wire.iid > 0, let url = URL(string: wire.webUrl),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            throw PullRequestProviderError.malformedResponse("invalid merge request URL or IID")
        }
        let state: PullRequestState = wire.state == "merged" ? .merged
            : (wire.state == "opened" ? .open : .closed)
        return PullRequestSummary(
            reference: PullRequestReference(providerID: id, repositoryID: repository,
                                            pullRequestID: String(wire.iid)),
            title: String(wire.title.prefix(2_000)),
            body: wire.description.map { String($0.prefix(65_536)) },
            webURL: url, state: state,
            isDraft: wire.draft ?? wire.title.lowercased().hasPrefix("draft:"),
            baseBranch: String(wire.targetBranch.prefix(512)),
            headBranch: String(wire.sourceBranch.prefix(512)),
            author: wire.author?.username.map { String($0.prefix(256)) },
            mergeable: wire.mergeStatus.map { $0 == "can_be_merged" },
            changedFileCount: wire.changesCount.flatMap(Int.init)
        )
    }

    private func file(_ wire: GitLabMergeRequestDiff) throws -> PullRequestFile {
        let path = try validatedPath(wire.newPath)
        let previous = wire.renamedFile == true ? try validatedPath(wire.oldPath) : nil
        let status: PullRequestFileStatus = wire.newFile == true ? .added
            : (wire.deletedFile == true ? .removed
               : (wire.renamedFile == true ? .renamed : .modified))
        let patch = wire.diff.flatMap { $0.utf8.count <= 1_024 * 1_024 ? $0 : nil }
        let additions = patch?.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count ?? 0
        let deletions = patch?.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count ?? 0
        return PullRequestFile(
            path: path, previousPath: previous, status: status,
            additions: additions, deletions: deletions, changes: additions + deletions,
            patch: patch,
            isPatchUnavailable: patch == nil || wire.collapsed == true || wire.tooLarge == true
        )
    }

    private func validatedPath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
              !NSString(string: path).pathComponents.contains("..") else {
            throw PullRequestProviderError.malformedResponse("unsafe diff path")
        }
        return path
    }
}

private struct GitLabCreateMergeRequest: Encodable {
    let sourceBranch: String
    let targetBranch: String
    let title: String
    let description: String?
}

private struct GitLabMergeRequest: Decodable {
    struct Author: Decodable { let username: String? }
    let iid: Int
    let title: String
    let description: String?
    let webUrl: String
    let state: String
    let draft: Bool?
    let sourceBranch: String
    let targetBranch: String
    let author: Author?
    let mergeStatus: String?
    let changesCount: String?
}

private struct GitLabMergeRequestDiff: Decodable {
    let oldPath: String
    let newPath: String
    let diff: String?
    let newFile: Bool?
    let deletedFile: Bool?
    let renamedFile: Bool?
    let collapsed: Bool?
    let tooLarge: Bool?
}
