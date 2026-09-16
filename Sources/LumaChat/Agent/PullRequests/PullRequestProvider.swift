import Foundation

protocol PullRequestProvider: Sendable {
    var id: String { get }

    func create(_ request: PullRequestCreateRequest) async throws -> PullRequestSummary
    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary
    func context(
        for reference: PullRequestReference,
        maximumFiles: Int
    ) async throws -> PullRequestContext
}

actor PullRequestService {
    private let providers: [String: any PullRequestProvider]

    init(providers: [any PullRequestProvider]) throws {
        var indexed: [String: any PullRequestProvider] = [:]
        for provider in providers {
            let identifier = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier.utf8.count <= 64 else {
                throw PullRequestProviderError.providerUnavailable(provider.id)
            }
            guard indexed[identifier] == nil else {
                throw PullRequestProviderError.duplicateProvider(identifier)
            }
            indexed[identifier] = provider
        }
        self.providers = indexed
    }

    func availableProviderIDs() -> [String] {
        providers.keys.sorted()
    }

    func create(
        providerID: String,
        request: PullRequestCreateRequest
    ) async throws -> PullRequestSummary {
        try await provider(providerID).create(request)
    }

    func pullRequest(_ reference: PullRequestReference) async throws -> PullRequestSummary {
        try await provider(reference.providerID).pullRequest(reference)
    }

    func context(
        for reference: PullRequestReference,
        maximumFiles: Int = 1_000
    ) async throws -> PullRequestContext {
        guard (1...3_000).contains(maximumFiles) else {
            throw PullRequestProviderError.invalidRequest(
                "maximumFiles must be between 1 and 3000"
            )
        }
        return try await provider(reference.providerID).context(
            for: reference,
            maximumFiles: maximumFiles
        )
    }

    private func provider(_ identifier: String) throws -> any PullRequestProvider {
        guard let provider = providers[identifier] else {
            throw PullRequestProviderError.providerUnavailable(identifier)
        }
        return provider
    }
}

struct PullRequestHTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
    var finalURL: URL?
}

protocol PullRequestHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> PullRequestHTTPResponse
}

struct URLSessionPullRequestHTTPTransport: PullRequestHTTPTransport, Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: RejectingRedirectURLSessionDelegate(),
                delegateQueue: nil
            )
        }
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> PullRequestHTTPResponse {
        guard maximumResponseBytes > 0 else {
            throw PullRequestProviderError.invalidRequest(
                "maximumResponseBytes must be positive"
            )
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw PullRequestProviderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PullRequestProviderError.malformedResponse("missing HTTP response")
        }
        guard AgentHTTPOrigin.isSameOrigin(request.url, http.url) else {
            throw PullRequestProviderError.redirectRejected
        }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            throw PullRequestProviderError.responseTooLarge(maximumResponseBytes)
        }

        var body = Data()
        if http.expectedContentLength > 0 {
            body.reserveCapacity(min(maximumResponseBytes, Int(http.expectedContentLength)))
        }
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumResponseBytes else {
                    throw PullRequestProviderError.responseTooLarge(maximumResponseBytes)
                }
                body.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PullRequestProviderError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw PullRequestProviderError.network(error.localizedDescription)
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = String(describing: value)
        }
        return PullRequestHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: body,
            finalURL: http.url
        )
    }
}
