import Foundation

/// A validated, canonical identity for an HTTP(S) endpoint.
///
/// The identity intentionally excludes query and fragment components because the
/// LLM client does not use them when constructing API routes.
struct EndpointIdentity: Hashable, Sendable, CustomStringConvertible {
    let normalized: String

    var description: String { normalized }

    init?(_ endpoint: String) {
        guard let identity = EndpointNormalizer.validatedIdentity(for: endpoint) else {
            return nil
        }
        self = identity
    }

    fileprivate init(normalized: String) {
        self.normalized = normalized
    }
}

/// Produces one stable identity for equivalent endpoint spellings.
enum EndpointNormalizer {
    /// Returns a canonical endpoint, or `nil` when the value is not a valid
    /// HTTP(S) endpoint with a host.
    static func normalized(_ endpoint: String) -> String? {
        validatedIdentity(for: endpoint)?.normalized
    }

    /// Validates and canonicalizes an endpoint for comparisons and storage keys.
    static func validatedIdentity(for endpoint: String) -> EndpointIdentity? {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://") {
            value = "http://" + value
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()

        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil

        guard let normalized = components.string,
              URL(string: normalized) != nil else {
            return nil
        }
        return EndpointIdentity(normalized: normalized)
    }

    static func isValid(_ endpoint: String) -> Bool {
        validatedIdentity(for: endpoint) != nil
    }

    static func haveSameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = validatedIdentity(for: lhs),
              let right = validatedIdentity(for: rhs) else {
            return false
        }
        return left == right
    }
}
