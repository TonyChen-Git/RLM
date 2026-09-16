import Foundation

/// Extracts an explicitly user-opened Pull Request destination from a completed
/// built-in tool step. Provider prose is intentionally ignored: only the
/// structured `url` field from an exact, allow-listed tool name is considered.
enum PullRequestToolResultLink {
    private static let supportedToolNames: Set<String> = [
        "pull_request_get",
        "pull_request_context",
        "pull_request_create"
    ]
    private static let maximumURLBytes = 4_096

    static func destination(for step: AgentStep) -> URL? {
        guard step.status == .completed,
              let toolName = step.toolCall?.name,
              supportedToolNames.contains(toolName),
              let result = step.toolResult,
              !result.isError,
              case .object(let data)? = result.data,
              case .string(let rawURL)? = data["url"] else {
            return nil
        }
        return validatedHTTPSURL(rawURL)
    }

    private static func validatedHTTPSURL(_ rawURL: String) -> URL? {
        guard !rawURL.isEmpty,
              rawURL.utf8.count <= maximumURLBytes,
              rawURL == rawURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parsedURL = URL(string: rawURL, encodingInvalidCharacters: false),
              var components = URLComponents(
                url: parsedURL,
                resolvingAgainstBaseURL: false
              ),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil,
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true else {
            return nil
        }

        // Normalize only scheme and host casing. Returning URLComponents' URL
        // avoids accepting a value that Foundation could not round-trip.
        components.scheme = "https"
        components.host = components.host?.lowercased()
        guard let normalizedURL = components.url,
              normalizedURL.absoluteString.utf8.count <= maximumURLBytes else {
            return nil
        }
        return normalizedURL
    }
}
