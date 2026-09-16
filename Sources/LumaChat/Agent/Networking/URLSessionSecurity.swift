import Foundation
import Darwin

/// Authentication-bearing Agent requests never forward automatically across a
/// redirect. Callers surface the 3xx response and require the configured endpoint
/// to be changed explicitly, preventing credential forwarding to another origin.
final class RejectingRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum AgentHTTPOrigin {
    static func isLoopback(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" { return true }

        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return bytes.first == 127
        }

        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let isIPv6Loopback = bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
            let isMappedIPv4Loopback = bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            return isIPv6Loopback || isMappedIPv4Loopback
        }

        // URL parsers may preserve the single-integer IPv4 notation accepted
        // by some networking stacks (for example 2130706433 == 127.0.0.1).
        if let numeric = UInt64(host), numeric <= UInt64(UInt32.max) {
            return UInt32(numeric) >> 24 == 127
        }
        return false
    }

    static func isSameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
