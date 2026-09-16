import Foundation
import XCTest
@testable import LumaChat

private final class WebToolStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Action {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(URL)
    }

    struct Snapshot {
        var request: URLRequest
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) -> Action)?
    nonisolated(unsafe) private static var recorded: [Snapshot] = []

    static func install(_ handler: @escaping (URLRequest) -> Action) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    static func snapshots() -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        Self.recorded.append(Snapshot(request: request, body: body))
        let handler = Self.handler
        Self.lock.unlock()

        switch handler?(request) ?? .response(status: 500, headers: [:], chunks: []) {
        case .response(let status, let headers, let chunks):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: destination),
                redirectResponse: response
            )
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private actor WebSearchProviderProbe: AgentWebSearchProvider {
    struct Call: Equatable, Sendable {
        var query: String
        var maximumResults: Int
    }

    private let results: [AgentWebSearchResult]
    private var calls: [Call] = []

    init(results: [AgentWebSearchResult]) {
        self.results = results
    }

    func search(query: String, maximumResults: Int) async throws -> [AgentWebSearchResult] {
        calls.append(Call(query: query, maximumResults: maximumResults))
        return results
    }

    func recordedCalls() -> [Call] { calls }
}

final class WebToolTests: XCTestCase {
    override func tearDown() {
        WebToolStubURLProtocol.reset()
        super.tearDown()
    }

    func testFetchURLReturnsReadableHTMLText() async throws {
        WebToolStubURLProtocol.install { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                chunks: [Data(#"""
                <html><head><style>.hidden { color: red }</style></head>
                <body><h1>Hello &amp; world</h1><script>doNotExpose()</script><p>Second line</p></body></html>
                """#.utf8)]
            )
        }
        let fetch = try tool(named: "fetch_url")

        let result = try await fetch.execute(
            arguments: .object(["url": .string("https://web.example.test/page")]),
            context: context
        )

        XCTAssertTrue(result.content.contains("Hello & world"), result.content)
        XCTAssertTrue(result.content.contains("Second line"), result.content)
        XCTAssertFalse(result.content.contains("doNotExpose"), result.content)
        XCTAssertFalse(result.content.contains("hidden"), result.content)
        XCTAssertEqual(result.data?["status"]?.intValue, 200)
    }

    func testResponseSizeCapAllowsBoundedChunksAndRejectsOverflow() async throws {
        WebToolStubURLProtocol.install { request in
            let chunks = request.url?.path == "/within"
                ? [Data(repeating: 65, count: 600), Data(repeating: 66, count: 400)]
                : [Data(repeating: 65, count: 600), Data(repeating: 66, count: 500)]
            return .response(
                status: 200,
                headers: ["Content-Type": "text/plain"],
                chunks: chunks
            )
        }
        let fetch = try tool(named: "fetch_url")
        let limit: JSONValue = .number(1_024)

        let within = try await fetch.execute(
            arguments: .object([
                "url": .string("https://web.example.test/within"),
                "max_bytes": limit
            ]),
            context: context
        )
        XCTAssertEqual(within.data?["byte_count"]?.intValue, 1_000)

        await assertExecutionFails(containing: "1024-byte limit") {
            try await fetch.execute(
                arguments: .object([
                    "url": .string("https://web.example.test/overflow"),
                    "max_bytes": limit
                ]),
                context: self.context
            )
        }
    }

    func testRedirectIsRefusedWithoutFollowingDestination() async throws {
        let destination = URL(string: "https://destination.example.test/final")!
        WebToolStubURLProtocol.install { request in
            request.url == destination
                ? .response(status: 200, headers: ["Content-Type": "text/plain"], chunks: [Data("followed".utf8)])
                : .redirect(destination)
        }
        let fetch = try tool(named: "fetch_url")

        await assertExecutionFails(containing: "HTTP redirects are refused") {
            try await fetch.execute(
                arguments: .object(["url": .string("https://source.example.test/redirect")]),
                context: self.context
            )
        }
        XCTAssertEqual(WebToolStubURLProtocol.snapshots().map(\.request.url?.host), ["source.example.test"])
    }

    func testCloudMetadataEndpointsAreRejectedBeforeTransport() async throws {
        WebToolStubURLProtocol.install { _ in
            .response(status: 200, headers: ["Content-Type": "text/plain"], chunks: [Data("secret".utf8)])
        }
        let fetch = try tool(named: "fetch_url")

        for url in [
            "http://169.254.169.254/latest/meta-data",
            "http://169.254.1.10/metadata",
            "http://metadata.google.internal/computeMetadata/v1/",
            "http://[fd00:ec2::254]/latest/meta-data"
        ] {
            await assertExecutionFails(containing: "cloud metadata endpoints are forbidden") {
                try await fetch.execute(
                    arguments: .object(["url": .string(url)]),
                    context: self.context
                )
            }
        }
        XCTAssertTrue(WebToolStubURLProtocol.snapshots().isEmpty)
    }

    func testHeaderInjectionAndReservedFramingHeadersAreRejected() async throws {
        WebToolStubURLProtocol.install { _ in
            .response(status: 200, headers: ["Content-Type": "text/plain"], chunks: [Data("ok".utf8)])
        }
        let request = try tool(named: "http_request")

        for headers: JSONValue in [
            .object(["X-Safe": .string("value\r\nX-Injected: yes")]),
            .object(["X-Control": .string("value\u{0000}suffix")]),
            .object(["Host": .string("metadata.google.internal")])
        ] {
            await assertExecutionFails(containing: "invalid or unsafe HTTP header") {
                try await request.execute(
                    arguments: .object([
                        "url": .string("https://web.example.test/headers"),
                        "method": .string("GET"),
                        "headers": headers
                    ]),
                    context: self.context
                )
            }
        }
        XCTAssertTrue(WebToolStubURLProtocol.snapshots().isEmpty)
    }

    func testHTTPRequestForwardsMethodHeadersAndUTF8Body() async throws {
        WebToolStubURLProtocol.install { _ in
            .response(
                status: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(#"{"ok":true}"#.utf8)]
            )
        }
        let request = try tool(named: "http_request")

        let result = try await request.execute(
            arguments: .object([
                "url": .string("https://web.example.test/items"),
                "method": .string("POST"),
                "headers": .object(["X-Trace": .string("trace-123")]),
                "body": .string("payload-台灣")
            ]),
            context: context
        )

        let sent = try XCTUnwrap(WebToolStubURLProtocol.snapshots().last)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Trace"), "trace-123")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(String(data: sent.body, encoding: .utf8), "payload-台灣")
        XCTAssertTrue(result.content.contains(#"{"ok":true}"#), result.content)
    }

    func testWebToolsDeclareNetworkAndMutationRisk() throws {
        let fetch = try tool(named: "fetch_url")
        let request = try tool(named: "http_request")

        XCTAssertTrue(fetch.requiresNetwork)
        XCTAssertTrue(request.requiresNetwork)
        XCTAssertEqual(fetch.permissionLevel, .read)
        XCTAssertEqual(request.permissionLevel, .dangerous)
        XCTAssertTrue(fetch.supportsParallelExecution)
        XCTAssertFalse(request.supportsParallelExecution)
    }

    func testWebSearchIsDisabledWithoutProviderAndUsesInjectedProvider() async throws {
        XCTAssertNil(WebToolFactory.makeTools().first { $0.name == "web_search" })
        let provider = WebSearchProviderProbe(results: [
            AgentWebSearchResult(
                title: "Luma result",
                url: "https://search.example.test/result",
                snippet: "A bounded search snippet."
            )
        ])
        let search = try XCTUnwrap(
            WebToolFactory.makeTools(searchProvider: provider)
                .first { $0.name == "web_search" }
        )

        let result = try await search.execute(
            arguments: .object([
                "query": .string("coding agent"),
                "max_results": .number(3)
            ]),
            context: context
        )

        let calls = await provider.recordedCalls()
        XCTAssertEqual(calls, [.init(query: "coding agent", maximumResults: 3)])
        XCTAssertTrue(result.content.contains("Luma result"))
        XCTAssertEqual(
            result.data?["results"]?.arrayValue?.first?["url"]?.stringValue,
            "https://search.example.test/result"
        )
        XCTAssertTrue(search.requiresNetwork)
        XCTAssertEqual(search.permissionLevel, .read)
        XCTAssertTrue(search.supportsParallelExecution)
    }

    func testWebSearchRejectsUnsafeProviderResultURL() async throws {
        let provider = WebSearchProviderProbe(results: [
            AgentWebSearchResult(
                title: "Unsafe",
                url: "file:///etc/passwd",
                snippet: "must not cross the web result boundary"
            )
        ])
        let search = try XCTUnwrap(
            WebToolFactory.makeTools(searchProvider: provider)
                .first { $0.name == "web_search" }
        )
        await assertExecutionFails(containing: "valid HTTP response") {
            try await search.execute(
                arguments: .object(["query": .string("unsafe")]),
                context: self.context
            )
        }
    }

    private var context: AgentToolContext {
        let root = AppPaths.projectTemporaryRoot
        return AgentToolContext(
            sessionID: UUID(),
            mode: .agent,
            workspace: AgentWorkspace(
                name: "Web Tool Tests",
                rootPath: root.path,
                allowedPaths: [],
                bookmarkData: nil,
                gitRepository: false,
                branch: nil
            ),
            temporaryRoot: root,
            commandTimeout: 5
        )
    }

    private func tool(named name: String) throws -> any AgentTool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebToolStubURLProtocol.self]
        return try XCTUnwrap(
            WebToolFactory.makeTools(configuration: configuration).first { $0.name == name }
        )
    }

    private func assertExecutionFails(
        containing expected: String,
        operation: () async throws -> AgentToolResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected web tool execution to fail.", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(expected),
                "Unexpected error: \(error.localizedDescription)",
                file: file,
                line: line
            )
        }
    }
}
