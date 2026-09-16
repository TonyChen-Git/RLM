import Foundation

/// Ephemeral authentication material for one already-validated Git HTTPS
/// command. This value is deliberately neither Codable nor printable: the
/// authorization header exists only in the child environment and the raw
/// credential is retained solely so TerminalSession can redact hostile output.
struct GitRemoteCommandAuthentication: Sendable {
    static let authorizationEnvironmentKey = "LUMACHAT_GIT_HTTP_AUTHORIZATION"

    let gitGlobalArguments: [String]
    let environment: [String: String]
    let redactionSecrets: [String]

    init(token: String, remoteURL: String) {
        let header = "Authorization: Bearer \(token)"
        let scope = "http.\(remoteURL)"
        gitGlobalArguments = [
            "-c", "http.extraHeader=",
            "-c", "http.followRedirects=false",
            "-c", "http.sslVerify=true",
            "-c", "http.proxy=",
            "-c", "http.sslCAInfo=",
            "-c", "http.sslCAPath=",
            "-c", "http.cookieFile=",
            "-c", "\(scope).followRedirects=false",
            "-c", "\(scope).sslVerify=true",
            "-c", "\(scope).proxy=",
            "--config-env=\(scope).extraHeader=\(Self.authorizationEnvironmentKey)"
        ]
        environment = [Self.authorizationEnvironmentKey: header]
        // Include both forms. A malicious server may reflect either the full
        // header or only its credential value in stderr.
        redactionSecrets = [header, token]
    }
}

/// Host-owned bridge from the PR provider credential store to Git smart HTTP.
/// The model can select only a previously validated remote name; this resolver
/// independently proves that its URL belongs to the configured GitHub origin
/// before consulting Keychain.
struct GitRemoteCredentialResolver: Sendable {
    var resolve: @Sendable (
        _ remoteURL: String,
        _ configuration: PullRequestProviderConfiguration
    ) throws -> GitRemoteCommandAuthentication?

    static let disabled = Self { _, _ in nil }

    static func configured(
        credentialStore: any PullRequestCredentialStorage = PullRequestCredentialStore()
    ) -> Self {
        Self { remoteURL, rawConfiguration in
            let configuration = try rawConfiguration.normalized()
            guard configuration.providerID == GitHubPullRequestProvider.providerID,
                  try authorizes(
                    remoteURL: remoteURL,
                    providerConfiguration: configuration
                  ) else {
                return nil
            }
            guard let token = try credentialStore.loadToken(configuration: configuration) else {
                return nil
            }
            return GitRemoteCommandAuthentication(token: token, remoteURL: remoteURL)
        }
    }

    /// GitHub.com API credentials may be sent only to github.com. For GHES,
    /// the HTTPS Git origin must match the configured API host and effective
    /// port exactly. SSH, local/file, cleartext, credential-bearing, queried,
    /// fragmented, and loopback remotes never receive the PR token.
    static func authorizes(
        remoteURL rawRemoteURL: String,
        providerConfiguration: PullRequestProviderConfiguration
    ) throws -> Bool {
        let configuration = try providerConfiguration.normalized()
        guard configuration.providerID == GitHubPullRequestProvider.providerID,
              let apiURL = URL(
                string: configuration.apiEndpoint,
                encodingInvalidCharacters: false
              ),
              apiURL.scheme?.lowercased() == "https",
              let apiHost = apiURL.host?.lowercased(),
              !AgentHTTPOrigin.isLoopback(apiHost),
              let remoteURL = URL(
                string: rawRemoteURL,
                encodingInvalidCharacters: false
              ),
              remoteURL.scheme?.lowercased() == "https",
              let remoteHost = remoteURL.host?.lowercased(),
              !AgentHTTPOrigin.isLoopback(remoteHost),
              remoteURL.user == nil,
              remoteURL.password == nil,
              remoteURL.query == nil,
              remoteURL.fragment == nil else {
            return false
        }

        if apiHost == "api.github.com", effectiveHTTPSPort(apiURL) == 443 {
            return remoteHost == "github.com" && effectiveHTTPSPort(remoteURL) == 443
        }
        return remoteHost == apiHost
            && effectiveHTTPSPort(remoteURL) == effectiveHTTPSPort(apiURL)
    }

    private static func effectiveHTTPSPort(_ url: URL) -> Int {
        url.port ?? 443
    }
}
