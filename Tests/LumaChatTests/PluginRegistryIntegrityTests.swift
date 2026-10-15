import Foundation
import XCTest
@testable import LumaChat

private final class RegistryFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var documents: [String: Data] = [:]

    static func put(_ data: Data, path: String) {
        lock.lock()
        documents[path] = data
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.documents[request.url?.path ?? ""]
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: data == nil ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PluginRegistryIntegrityTests: XCTestCase {
    func testRegistryRequiresMatchingPackageDigest() async throws {
        let root = AppPaths.projectTemporaryRoot
            .appendingPathComponent("registry-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryFixtureProtocol.self]
        let manager = PluginManager(
            recordsFile: root.appendingPathComponent("records.json"),
            installRoot: root.appendingPathComponent("installed"),
            scratchRoot: root.appendingPathComponent("scratch"),
            session: URLSession(configuration: config)
        )
        let manifestURL = URL(string: "https://registry.example.test/plugin.json")!
        let indexURL = URL(string: "https://registry.example.test/index.json")!
        let manifest = PluginManifest(
            id: "com.example.registry", name: "Registry fixture", version: "1.0",
            author: "Fixture", description: "Digest contract"
        )
        RegistryFixtureProtocol.put(try JSONEncoder().encode(manifest), path: "/plugin.json")
        let inspected = try await manager.inspect(source: .manifest(url: manifestURL))
        let source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PluginSource.manifest(url: manifestURL)
        ))
        func index(_ digest: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["plugins": [[
                "id": manifest.id, "source": source, "sha256": digest
            ]]])
        }
        RegistryFixtureProtocol.put(try index(String(repeating: "0", count: 64)), path: "/index.json")
        do {
            _ = try await manager.inspect(source: .registry(index: indexURL, pluginID: manifest.id))
            XCTFail("Expected digest mismatch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
        }
        RegistryFixtureProtocol.put(try index(inspected.packageSHA256), path: "/index.json")
        let verified = try await manager.inspect(source: .registry(index: indexURL, pluginID: manifest.id))
        XCTAssertEqual(verified.packageSHA256, inspected.packageSHA256)
        XCTAssertEqual(verified.registryIndexSHA256?.count, 64)
        _ = try await manager.install(verified, grantedPermissions: [])
        let installed = await manager.installed()
        XCTAssertEqual(installed.first?.packageSHA256, inspected.packageSHA256)
    }
}
